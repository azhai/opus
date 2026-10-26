package web

import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

/*
Proxy forwards requests to upstream HTTP/1.1 servers and streams the
responses back to the client (Mongoose's reverse proxy, wired into the
nbio event loop).

Usage:

	proxy: web.Proxy
	web.proxy_init(&proxy, {"127.0.0.1:9000"})
	proxy.strip_prefix = "/api"
	srv.user_ptr = &proxy
	srv.handler = web.proxy_serve

Or behind a router, where the router owns the proxy state - register a
catch-all route under a prefix that forwards into the proxy (the catch-all
pattern is a lone star segment, see path_match):

	api_proxy :: proc(req: ^web.Request, res: ^web.Response) {
		web.proxy_serve_root(&proxy, req, res)
	}
	web.router_get(&router, "/api/" + "*", api_proxy)

Model:

  - The response head is relayed as soon as the upstream head arrives, and
    the body is then streamed: bytes move upstream -> client in recv-sized
    pieces, with at most one piece buffered per direction. Memory no longer
    grows with the response size, and the client starts receiving before
    the upstream has finished.
  - Upstream connections are kept alive and reused from a small per-host
    pool (`keep_alive`, on by default). Only a connection that finished its
    response cleanly goes into the pool: a `Connection: close`, an HTTP/1.0
    peer that did not ask for keep-alive, and a body cut short by a reset or
    a malformed chunk all close it instead. A pooled connection that turns
    out to be stale is retried once on a fresh connection for idempotent
    methods.
  - Hop-by-hop headers are dropped in both directions. `Host` is rewritten
    to the upstream, and `X-Forwarded-For` / `X-Forwarded-Proto` / `Via`
    are added on the way out.
  - Upstream framing is relayed faithfully: Content-Length passes through
    and is counted down as the body streams, a chunked body is passed
    through with its framing intact (an incremental scanner decides when
    the terminating chunk has gone by), and a body with neither is
    re-framed as chunked on the way out so the client connection keeps its
    keep-alive semantics (HTTP/1.0 clients get a close-delimited body
    instead, since they cannot read chunked).
  - Multiple upstreams are load balanced round-robin.

Errors: connect/send/read failures become 502, upstream timeouts become
504, and the client connection is closed after an error response. Once the
head has reached the client the only honest signal left is a truncated
body, so the connection is closed instead of appending an error page.

The pool holds sockets created on this thread's event loop, so one Proxy
belongs to one Server (and therefore one thread); give each acceptor
thread its own Proxy when running several.
*/

Proxy :: struct {
	upstreams:    [dynamic]Upstream, // endpoints, weights and health
	strip_prefix: string,            // "/api" is stripped from the client path
	timeout:      time.Duration,     // per upstream operation (dial/send/recv)
	allocator:    mem.Allocator,

	// upstream connection reuse
	keep_alive:        bool,
	max_idle_per_host: int,
	idle_timeout:      time.Duration,
	pool:              [dynamic]Pool_Conn,

	// health (see proxy_health.odin): failures eject, successes restore
	health: Health_Config,

	// counters, useful in /stats style handlers
	pool_hits:          u64,
	pool_misses:        u64,
	upstreams_ejected:  int, // currently ejected
	probes:             u64,
	probe_failures:     u64,
}

// Pool_Conn is one idle upstream connection waiting to be reused.
Pool_Conn :: struct {
	sock:       net.TCP_Socket,
	upstream:   int,
	idle_since: time.Time,
}

// proxy_init parses the upstream addresses ("127.0.0.1:9000", "[::]:9000").
// It returns false (and logs) if any address is invalid.
//
// Every upstream starts healthy with weight 1, with the default health
// policy (PROXY_HEALTH_DEFAULT). Tune it by assigning `p.health` and calling
// `proxy_set_weight` before the server starts.
proxy_init :: proc(p: ^Proxy, upstreams: []string, allocator := context.allocator) -> bool {
	p.allocator = allocator
	p.timeout = 10 * time.Second
	p.keep_alive = true
	p.max_idle_per_host = 16
	p.idle_timeout = 30 * time.Second
	p.health = PROXY_HEALTH_DEFAULT
	p.pool = make([dynamic]Pool_Conn, allocator)
	p.upstreams = make([dynamic]Upstream, allocator)
	for u in upstreams {
		ep, ok := net.parse_endpoint(u)
		if !ok {
			log_error("web: invalid upstream address: %q", u)
			return false
		}
		append(&p.upstreams, Upstream {
			endpoint = ep,
			host     = clone_string(u, allocator),
			weight   = 1,
			state    = .Healthy,
		})
	}
	return true
}

/*
proxy_close_idle drops every idle upstream connection.

Pooled sockets belong to the event loop, so this must run on the loop thread
- typically from `Server.on_stop`, which the server calls once its loop has
stopped but while nbio calls are still valid:

	srv.on_stop = proc(s: ^web.Server) {
		web.proxy_close_idle(cast(^web.Proxy) s.user_ptr)
	}
*/
proxy_close_idle :: proc(p: ^Proxy) {
	proxy_pool_close_all(p)
}

/*
proxy_destroy releases the proxy's memory. It deliberately does not touch
the pooled upstream sockets: those belong to the event loop and closing
them from another thread (or after the loop is gone) is not safe. Release
them first with `proxy_close_idle` from `Server.on_stop`; a leftover pool
is reported here so the omission is noticeable.
*/
proxy_destroy :: proc(p: ^Proxy) {
	if p.pool != nil && len(p.pool) > 0 {
		log_error("web: proxy_destroy with %v idle upstream connection(s); call proxy_close_idle on the event loop thread", len(p.pool))
	}
	if p.pool != nil {
		delete(p.pool)
		p.pool = nil
	}
	if p.upstreams != nil {
		for u in p.upstreams {
			delete(u.host, p.allocator)
		}
		delete(p.upstreams)
		p.upstreams = nil
	}
}

// ---------------------------------------------------------------------------
// idle upstream pool
// ---------------------------------------------------------------------------

proxy_pool_take :: proc(p: ^Proxy, upstream: int) -> (net.TCP_Socket, bool) {
	now := nbio.now()
	for i := 0; i < len(p.pool); i += 1 {
		e := p.pool[i]
		if e.upstream != upstream {
			continue
		}
		unordered_remove(&p.pool, i)
		i -= 1
		if now != {} && time.diff(e.idle_since, now) > p.idle_timeout {
			// sat too long: the peer may well be gone, do not gamble
			nbio.close(e.sock)
			continue
		}
		p.pool_hits += 1
		return e.sock, true
	}
	p.pool_misses += 1
	return {}, false
}

proxy_pool_put :: proc(p: ^Proxy, upstream: int, sock: net.TCP_Socket) {
	if !p.keep_alive {
		nbio.close(sock)
		return
	}
	count := 0
	for e in p.pool {
		if e.upstream == upstream {
			count += 1
		}
	}
	if count >= p.max_idle_per_host {
		nbio.close(sock)
		return
	}
	append(&p.pool, Pool_Conn{sock = sock, upstream = upstream, idle_since = nbio.now()})
}

proxy_pool_close_all :: proc(p: ^Proxy) {
	if p.pool == nil {
		return
	}
	for e in p.pool {
		nbio.close(e.sock)
	}
	clear(&p.pool)
}

// proxy_pool_close_upstream drops the idle connections of one upstream: an
// ejected backend's sockets are not worth keeping, and handing one out would
// charge the failure to a connection that may already be dead.
proxy_pool_close_upstream :: proc(p: ^Proxy, upstream: int) {
	if p.pool == nil {
		return
	}
	for i := 0; i < len(p.pool); i += 1 {
		if p.pool[i].upstream != upstream {
			continue
		}
		nbio.close(p.pool[i].sock)
		unordered_remove(&p.pool, i)
		i -= 1
	}
}

// proxy_serve is a `Handler` for `server.user_ptr = ^Proxy`.
proxy_serve :: proc(req: ^Request, res: ^Response) {
	s := req.conn.server
	p := cast(^Proxy) s.user_ptr
	if p == nil {
		res.status = .Internal_Error
		response_write_string(res, "500 proxy not configured\n")
		return
	}
	proxy_serve_root(p, req, res)
}

// proxy_method_retryable reports whether a request may be replayed on a
// fresh connection when a pooled one turns out to be dead. Only methods
// without side effects qualify.
proxy_method_retryable :: proc(m: Method) -> bool {
	return m == .Get || m == .Head || m == .Options
}

// proxy_serve_root is proxy_serve with an explicit proxy; use it when a
// router (not the server) owns the proxy state.
//
// On entry the connection is in Process with a fresh Response. This either
// writes a complete error response (no upstream configured) and returns,
// or serializes the upstream request, moves the connection to .Proxy and
// returns; the upstream callbacks then relay the response.
proxy_serve_root :: proc(p: ^Proxy, req: ^Request, res: ^Response) {
	c := req.conn
	index := proxy_next_upstream(p)
	if index < 0 {
		res.status = .Bad_Gateway
		response_write_string(res, "502 no upstream configured\n")
		return
	}
	up := p.upstreams[index].endpoint
	host := p.upstreams[index].host
	c.proxy_cfg = p
	c.proxy_upstream = index

	// target path: strip the configured prefix (on a segment boundary)
	target := req.path
	if len(p.strip_prefix) > 0 {
		n := len(p.strip_prefix)
		if len(target) >= n && target[:n] == p.strip_prefix {
			rest := target[n:]
			if len(rest) == 0 || rest[0] == '/' {
				target = rest
			}
		}
	}
	if len(target) == 0 {
		target = "/"
	}

	b := &c.proxy_req
	buf_reset(b)
	buf_append_string(b, method_string(req.method))
	buf_append_byte(b, ' ')
	buf_append_string(b, target)
	if len(req.query) > 0 {
		buf_append_byte(b, '?')
		buf_append_string(b, req.query)
	}
	buf_append_string(b, " HTTP/1.1\r\n")

	// Host is rewritten to the upstream
	buf_append_string(b, "Host: ")
	buf_append_string(b, host)
	buf_append_string(b, "\r\n")

	// pass client headers through, minus hop-by-hop and framing headers
	// (Content-Length is re-emitted below if there is a body)
	xff, has_xff := request_header(req, "X-Forwarded-For")
	for h in req.headers {
		if is_hop_by_hop_header(h.key) {
			continue
		}
		if eq_ignore_case(h.key, "Host") ||
			eq_ignore_case(h.key, "Content-Length") ||
			eq_ignore_case(h.key, "X-Forwarded-For") {
			continue
		}
		buf_append_string(b, h.key)
		buf_append_string(b, ": ")
		buf_append_string(b, h.value)
		buf_append_string(b, "\r\n")
	}

	client_ip := net.address_to_string_allocator(c.remote.address, conn_scratch(c))
	buf_append_string(b, "X-Forwarded-For: ")
	if has_xff {
		buf_append_string(b, xff)
		buf_append_string(b, ", ")
	}
	buf_append_string(b, client_ip)
	buf_append_string(b, "\r\n")
	buf_append_string(b, "X-Forwarded-Proto: http\r\n")
	buf_append_string(b, "Via: 1.1 ")
	buf_append_string(b, SERVER_NAME)
	buf_append_string(b, "\r\n")

	if p.keep_alive {
		buf_append_string(b, "Connection: keep-alive\r\n")
	} else {
		buf_append_string(b, "Connection: close\r\n")
	}
	if len(req.body) > 0 {
		buf_append_string(b, "Content-Length: ")
		buf_append_string(b, int_to_string(i64(len(req.body)), conn_scratch(c)))
		buf_append_string(b, "\r\n")
	}
	buf_append_string(b, "\r\n")
	if len(req.body) > 0 {
		buf_append(b, req.body)
	}

	buf_reset(&c.proxy_buf)
	c.proxy_state = .Head
	c.proxy_framing = .None
	c.proxy_scan = {}
	c.proxy_head_len = 0
	c.proxy_remaining = 0
	c.proxy_body_done = false
	c.proxy_body_broken = false
	c.proxy_client_started = false
	c.proxy_upstream_close = false
	c.proxy_retryable = false
	c.state = .Proxy

	if p.keep_alive {
		if sock, ok := proxy_pool_take(p, index); ok {
			c.proxy_sock = sock
			c.proxy_open = true
			c.proxy_pooled = true
			c.proxy_retryable = proxy_method_retryable(req.method)
			proxy_send_request(c)
			return
		}
	}
	c.proxy_pooled = false
	proxy_start_dial(c, up)
}

proxy_start_dial :: proc(c: ^Conn, up: net.Endpoint) {
	c.proxy_op = nbio.dial_poly(up, c, on_proxy_dial, timeout = c.proxy_cfg.timeout)
}

proxy_send_request :: proc(c: ^Conn) {
	c.proxy_op = nbio.send_poly(
		c.proxy_sock,
		[][]byte{buf_slice(&c.proxy_req)},
		c,
		on_proxy_sent,
		all = true,
		timeout = c.proxy_cfg.timeout,
	)
}

// ---------------------------------------------------------------------------
// upstream callbacks (all run on the server's event loop thread)
// ---------------------------------------------------------------------------

on_proxy_dial :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.proxy_op = nil
	if c.closed {
		return
	}
	if op.dial.err != nil {
		log_debug("web: proxy dial failed: %v", op.dial.err)
		if c.proxy_cfg != nil {
			proxy_note_failure(c.proxy_cfg, c.proxy_upstream)
		}
		if is_dial_timeout(op.dial.err) {
			proxy_fail(c, .Gateway_Timeout, "504 upstream connect timeout\n")
		} else {
			proxy_fail(c, .Bad_Gateway, "502 upstream connect failed\n")
		}
		return
	}
	c.proxy_sock = op.dial.socket
	c.proxy_open = true
	c.proxy_pooled = false
	net.set_option(c.proxy_sock, .TCP_Nodelay, true)
	proxy_send_request(c)
}

on_proxy_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.proxy_op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: proxy send failed: %v", op.send.err)
		if se, ok := op.send.err.(net.TCP_Send_Error); ok && se == .Timeout {
			proxy_upstream_failed(c, .Gateway_Timeout, "504 upstream write timeout\n")
		} else {
			proxy_upstream_failed(c, .Bad_Gateway, "502 upstream write failed\n")
		}
		return
	}
	proxy_recv_arm(c)
}

proxy_recv_arm :: proc(c: ^Conn) {
	if c.proxy_cfg == nil {
		// Defensive: every caller should be inside an active proxy request,
		// but arming a read needs the proxy config for its timeout, so a
		// late callback from a finished request must not reach nbio.
		log_debug("web: proxy_recv_arm without an active request; closing")
		conn_close(c)
		return
	}
	c.proxy_op = nbio.recv_poly(
		c.proxy_sock,
		[][]byte{c.rbuf[:]},
		c,
		on_proxy_recv,
		all = false,
		timeout = c.proxy_cfg.timeout,
	)
}

on_proxy_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.proxy_op = nil
	if c.closed {
		return
	}
	if op.recv.err != nil {
		if re, ok := op.recv.err.(net.TCP_Recv_Error); ok && re == .Timeout {
			if c.proxy_client_started {
				// the client already has a partial body: all we can do is
				// cut the connection so it sees a truncated response
				log_debug("web: proxy upstream timed out mid-stream")
				conn_close(c)
				return
			}
			proxy_upstream_failed(c, .Gateway_Timeout, "504 upstream timeout\n")
			return
		}
		if c.proxy_framing == .Raw_To_Close || c.proxy_framing == .Reframe_Chunked {
			// a reset mid-stream is only acceptable for close-delimited
			// bodies that already have a head
			if c.proxy_state == .Body {
				proxy_body_cut(c)
				return
			}
		}
		log_debug("web: proxy recv failed: %v", op.recv.err)
		proxy_upstream_failed(c, .Bad_Gateway, "502 upstream read failed\n")
		return
	}
	n := op.recv.received
	if n == 0 {
		// upstream closed its write side: the body ends here for
		// close-delimited responses, anything else is a short read
		if c.proxy_framing == .Raw_To_Close || c.proxy_framing == .Reframe_Chunked {
			c.proxy_upstream_close = true
			if c.proxy_state == .Body {
				proxy_body_finish(c)
				return
			}
		}
		proxy_upstream_failed(c, .Bad_Gateway, "502 upstream closed early\n")
		return
	}
	buf_append(&c.proxy_buf, c.rbuf[:n])
	proxy_advance(c)
}

// proxy_upstream_failed tears the upstream down and either retries on a
// fresh connection (a pooled one that was already dead) or answers 502/504.
proxy_upstream_failed :: proc(c: ^Conn, status: Status, msg: string) {
	if c.proxy_cfg != nil {
		// passive health: every failed attempt counts, including the one that
		// triggers the retry below - a retry that succeeds clears the streak
		// again, so a healthy upstream is never ejected by one stale socket
		proxy_note_failure(c.proxy_cfg, c.proxy_upstream)
	}
	if c.proxy_open {
		nbio.close(c.proxy_sock)
		c.proxy_open = false
	}
	if c.proxy_retryable && !c.proxy_client_started && buf_len(&c.proxy_buf) == 0 {
		// nothing of the response made it out: a stale keep-alive
		// connection is the likely culprit, so dial once for real
		c.proxy_retryable = false
		log_debug("web: proxy retrying %v on a fresh connection", c.req.path)
		proxy_start_dial(c, c.proxy_cfg.upstreams[c.proxy_upstream].endpoint)
		return
	}
	if c.proxy_client_started {
		conn_close(c)
		return
	}
	proxy_fail(c, status, msg)
}

// proxy_advance feeds buffered upstream bytes through the state machine.
proxy_advance :: proc(c: ^Conn) {
	if c.proxy_state == .Head {
		for {
			data := buf_slice(&c.proxy_buf)
			idx := bytes_index(data, "\r\n\r\n")
			if idx < 0 {
				if buf_len(&c.proxy_buf) >= c.server.max_header_size {
					proxy_fail(c, .Bad_Gateway, "502 upstream head too large\n")
				}
				return // need more data
			}
			head_len := idx + 4
			switch proxy_parse_head(c, string(data[:head_len])) {
			case .Ok:
				c.proxy_head_len = head_len
			case .Skip:
				// 1xx informational response: drop it and keep looking
				buf_consume(&c.proxy_buf, head_len)
				continue
			case .Malformed:
				proxy_fail(c, .Bad_Gateway, "502 malformed upstream response\n")
				return
			}
			break
		}
		proxy_stream_begin(c)
		return
	}

	proxy_pump(c)
}

// proxy_stream_begin relays the response head and starts the body stream.
proxy_stream_begin :: proc(c: ^Conn) {
	w := &c.res
	c.proxy_state = .Body

	switch c.proxy_framing {
	case .None:
		c.proxy_body_done = true
	case .Until_Close:
		// the upstream delimited its body with EOF. Re-frame it so the
		// client connection keeps its keep-alive semantics - unless it
		// speaks HTTP/1.0, which cannot read chunked framing.
		if c.req.version.major == 1 && c.req.version.minor == 0 {
			c.proxy_framing = .Raw_To_Close
			w.keep_alive = false
		} else {
			c.proxy_framing = .Reframe_Chunked
			w.chunked = true
			response_set_header(w, "Transfer-Encoding", "chunked")
		}
	case .Content_Length, .Chunked:
		// framing already relayed from the upstream head
	case .Reframe_Chunked, .Raw_To_Close:
		// only ever set just above; nothing to relay
	}

	// the head goes out immediately; the body follows as it arrives.
	// Serialize first, then drop the head bytes: header values are views
	// into proxy_buf and only survive until response_build has copied them.
	response_build(w, &c.out, conn_scratch(c))
	buf_consume(&c.proxy_buf, c.proxy_head_len)
	c.proxy_client_started = true
	proxy_send_out(c)
}

proxy_send_out :: proc(c: ^Conn) {
	// conn_flush_out encrypts when the client connection is TLS-wrapped and
	// tells us whether it actually queued a send
	if !conn_flush_out(c, on_proxy_stream_sent) {
		proxy_pump(c)
	}
}

on_proxy_stream_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: proxy client send failed: %v", op.send.err)
		conn_close(c)
		return
	}
	conn_after_send(c, op.send.sent)
	proxy_pump(c)
}

/*
proxy_pump alternates between pushing buffered body bytes at the client
and pulling more from the upstream. Exactly one direction is in flight at
a time, which is what keeps the buffers bounded.

Both guards are load-bearing:

  - `state != .Proxy`: a pump can finish the response, and the finish path
    hands the connection back to the normal write/keep-alive machine, which
    resets the per-request state. A send callback that pumps afterwards
    would otherwise re-enter the proxy with `proxy_cfg` already cleared.

  - `op != nil`: a client send is already in flight. Draining more body
    into `c.out` now would (a) append behind bytes that are mid-send and
    (b) arm a second send that overwrites `c.op`, so the first completion
    would reset the buffer the second send still points at.
*/
proxy_pump :: proc(c: ^Conn) {
	if c.closed || c.state != .Proxy || c.op != nil {
		return
	}
	proxy_drain_body(c)
	if buf_len(&c.out) > 0 {
		proxy_send_out(c)
		return
	}
	if c.proxy_body_done {
		if c.proxy_body_broken {
			proxy_body_cut(c)
		} else {
			proxy_body_finish(c)
		}
		return
	}
	proxy_recv_arm(c)
}

// proxy_drain_body moves whatever body bytes are buffered into the client
// output buffer, tracking the framing so completion is detected exactly.
proxy_drain_body :: proc(c: ^Conn) {
	for buf_len(&c.proxy_buf) > 0 && !c.proxy_body_done {
		data := buf_slice(&c.proxy_buf)
		switch c.proxy_framing {
		case .Content_Length:
			n := len(data)
			if n > c.proxy_remaining {
				n = c.proxy_remaining
			}
			buf_append(&c.out, data[:n])
			buf_consume(&c.proxy_buf, n)
			c.proxy_remaining -= n
			if c.proxy_remaining <= 0 {
				c.proxy_body_done = true
			}
		case .Chunked:
			// relay the framing bytes verbatim; the scanner only counts
			consumed, done, bad := proxy_chunk_scan_step(&c.proxy_scan, data)
			if consumed > 0 {
				buf_append(&c.out, data[:consumed])
				buf_consume(&c.proxy_buf, consumed)
			}
			if done {
				c.proxy_body_done = true
			}
			if bad {
				// the upstream framing went bad mid-body: stop relaying
				// here and let the connection close, so the client sees a
				// truncation instead of a silently short body
				c.proxy_body_broken = true
				c.proxy_body_done = true
				c.proxy_upstream_close = true
				c.res.keep_alive = false
			}
			if consumed == 0 {
				return // need more data
			}
		case .Reframe_Chunked:
			write_hex(&c.out, len(data))
			buf_append_string(&c.out, "\r\n")
			buf_append(&c.out, data)
			buf_append_string(&c.out, "\r\n")
			buf_consume(&c.proxy_buf, len(data))
		case .Raw_To_Close:
			buf_append(&c.out, data)
			buf_consume(&c.proxy_buf, len(data))
		case .None, .Until_Close:
			c.proxy_body_done = true
		}
	}
}

// proxy_body_finish closes out a complete response: terminal chunk, upstream
// release, and back into the normal write/keep-alive path.
proxy_body_finish :: proc(c: ^Conn) {
	if c.proxy_framing == .Reframe_Chunked {
		buf_append_string(&c.out, "0\r\n\r\n")
	}
	if c.proxy_cfg != nil {
		proxy_note_success(c.proxy_cfg, c.proxy_upstream)
	}
	proxy_response_end(c)
}

/*
proxy_body_cut ends a response whose upstream went away before the body was
complete. What already reached the client stays, but:

  - the socket is closed instead of pooled: it is either dead or still
    mid-message, and the next request must not inherit it;
  - the client connection is closed after the last relayed byte, so a
    close-delimited body is visibly truncated and a re-framed (chunked) one
    is missing its terminal chunk. Writing that chunk here would tell the
    client the short body is the whole response;
  - the upstream is charged with the failure, exactly like a pre-head error.
*/
proxy_body_cut :: proc(c: ^Conn) {
	if c.proxy_cfg != nil {
		proxy_note_failure(c.proxy_cfg, c.proxy_upstream)
	}
	c.proxy_upstream_close = true
	c.res.keep_alive = false
	proxy_response_end(c)
}

proxy_response_end :: proc(c: ^Conn) {
	proxy_release_upstream(c)
	c.proxy_state = .Done
	c.state = .Write
	conn_drive(c)
}

// proxy_release_upstream either parks the upstream connection in the pool
// or closes it.
proxy_release_upstream :: proc(c: ^Conn) {
	if !c.proxy_open {
		return
	}
	c.proxy_open = false
	if c.proxy_upstream_close || !c.proxy_cfg.keep_alive {
		nbio.close(c.proxy_sock)
		return
	}
	proxy_pool_put(c.proxy_cfg, c.proxy_upstream, c.proxy_sock)
}

// proxy_fail answers the client with a gateway error and closes the
// connection after the write.
proxy_fail :: proc(c: ^Conn, status: Status, msg: string) {
	if c.proxy_open {
		nbio.close(c.proxy_sock)
		c.proxy_open = false
	}
	w := &c.res
	response_reset(w, c, conn_scratch(c))
	w.status = status
	w.keep_alive = false
	response_write_string(w, msg)
	response_build(w, &c.out, conn_scratch(c))
	c.state = .Write
	conn_drive(c)
}

// ---------------------------------------------------------------------------
// upstream response parsing
// ---------------------------------------------------------------------------

// Proxy_State is the relay's coarse phase: reading the head, streaming the
// body, done. The body framing itself lives in Proxy_Framing.
Proxy_State :: enum {
	None, // not proxying
	Head, // accumulating the upstream response head
	Body, // head relayed, body streaming
	Done, // response complete
}

// Proxy_Framing is how the upstream delimited its body, and therefore how
// the proxy relays it.
Proxy_Framing :: enum {
	None,            // no body expected
	Content_Length,  // counted down as bytes pass
	Chunked,         // relayed verbatim, scanner finds the end
	Until_Close,     // upstream EOF, needs re-framing before it is relayed
	Reframe_Chunked, // outgoing chunked coding, added by the proxy
	Raw_To_Close,    // outgoing close-delimited body (HTTP/1.0 clients)
}

Head_Parse_Result :: enum {
	Ok,
	Skip,     // 1xx informational head, keep looking for the real one
	Malformed,
}

// proxy_parse_head parses one upstream response head into the connection's
// response: status (with the upstream reason phrase), headers (hop-by-hop
// dropped, Content-Length/Transfer-Encoding passed through), and the body
// framing decision in c.proxy_framing / c.proxy_remaining.
//
// Header values are zero-copy views into the head buffer, which must stay
// alive until the response is written (the connection's proxy_buf does).
proxy_parse_head :: proc(c: ^Conn, head: string) -> Head_Parse_Result {
	w := &c.res

	line_end := string_index(head, "\r\n")
	if line_end <= 0 {
		return .Malformed
	}
	line := head[:line_end]

	sp1 := string_index_byte(line, ' ')
	if sp1 <= 0 {
		return .Malformed
	}
	// HTTP/1.0 has no implicit keep-alive: unless the response asks for it,
	// the peer closes when this response ends, so pooling the socket would
	// hand the next request a connection that is already going away.
	version_10 := eq_ignore_case(line[:sp1], "HTTP/1.0")
	sp2 := string_index_byte_from(line, ' ', sp1 + 1)
	code_str := ""
	reason := ""
	if sp2 < 0 {
		code_str = line[sp1 + 1:]
	} else {
		code_str = line[sp1 + 1:sp2]
		reason = line[sp2 + 1:]
	}
	code, ok := parse_status_code(code_str)
	if !ok {
		return .Malformed
	}
	if code >= 100 && code < 200 {
		return .Skip
	}

	w.status = Status(u16(code))
	w.reason = reason

	rest := head[line_end + 2:]
	count := 0
	has_cl := false
	cl_value := ""
	te_count := 0
	te_chunked := false
	peer_keep_alive := false
	for len(rest) > 0 {
		// blank line terminates the head
		if len(rest) >= 2 && rest[0] == '\r' && rest[1] == '\n' {
			break
		}
		nl := string_index(rest, "\r\n")
		if nl < 0 {
			return .Malformed
		}
		hdr := rest[:nl]
		rest = rest[nl + 2:]
		colon := string_index_byte(hdr, ':')
		if colon <= 0 {
			return .Malformed
		}
		key := hdr[:colon]
		value := trim_ows(hdr[colon + 1:])

		if eq_ignore_case(key, "Transfer-Encoding") {
			// checked before the hop-by-hop filter: the upstream framing
			// is relayed verbatim, so its TE header must survive
			te_count += 1
			te_chunked = te_chunked || contains_ignore_case(value, "chunked")
		} else if eq_ignore_case(key, "Connection") {
			// dropped, but remembered: a peer that wants to close will
			// not be reused from the pool, and an HTTP/1.0 peer has to ask
			// for keep-alive explicitly
			if contains_ignore_case(value, "close") {
				c.proxy_upstream_close = true
			} else if contains_ignore_case(value, "keep-alive") {
				peer_keep_alive = true
			}
			continue
		} else if is_hop_by_hop_header(key) {
			continue
		} else if eq_ignore_case(key, "Content-Length") {
			if has_cl && value != cl_value {
				return .Malformed // conflicting Content-Length
			}
			if string_index_byte(value, ',') >= 0 {
				return .Malformed // list-valued: ambiguous
			}
			if n, cok := parse_int(value); cok && n >= 0 {
				c.proxy_remaining = n
				has_cl = true
				cl_value = value
			}
			// pass the header through verbatim
		}
		append(&w.headers, Header{key = key, value = value})
		count += 1
		if count > MAX_HEADERS {
			return .Malformed
		}
	}

	// strict framing (RFC 7230 section 3.3.3): an upstream that sends both
	// TE and CL, or a TE whose final coding is not chunked, is a smuggling
	// vector and is not relayed
	if has_cl && te_count > 0 {
		return .Malformed
	}
	if te_count > 0 && !te_chunked {
		return .Malformed
	}
	if version_10 && !peer_keep_alive {
		c.proxy_upstream_close = true
	}

	// body framing decision
	if code == 204 || code == 304 {
		c.proxy_framing = .None
	} else if c.req.method == .Head {
		// a HEAD response carries the framing the GET would have had,
		// but no body ever follows
		c.proxy_framing = .None
	} else if has_cl {
		c.proxy_framing = .Content_Length
		if c.proxy_remaining == 0 {
			c.proxy_framing = .None
		}
	} else if te_chunked {
		c.proxy_framing = .Chunked
	} else {
		c.proxy_framing = .Until_Close
	}
	return .Ok
}

parse_status_code :: proc(s: string) -> (int, bool) {
	if len(s) != 3 {
		return 0, false
	}
	v := 0
	for i in 0..<3 {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		v = v * 10 + int(ch - '0')
	}
	return v, true
}

// is_hop_by_hop_header reports headers that must not be relayed in either
// direction (RFC 7230 section 6.1, minus the Connection-listed ones which
// are dropped with Connection itself).
is_hop_by_hop_header :: proc(key: string) -> bool {
	return eq_ignore_case(key, "Connection") ||
		eq_ignore_case(key, "Keep-Alive") ||
		eq_ignore_case(key, "Proxy-Connection") ||
		eq_ignore_case(key, "Proxy-Authenticate") ||
		eq_ignore_case(key, "Proxy-Authorization") ||
		eq_ignore_case(key, "Te") ||
		eq_ignore_case(key, "Trailer") ||
		eq_ignore_case(key, "Transfer-Encoding") ||
		eq_ignore_case(key, "Upgrade")
}

// ---------------------------------------------------------------------------
// incremental chunked scanner
// ---------------------------------------------------------------------------

// proxy_chunked_complete walks chunked framing in one shot, reporting
// whether the body is fully present and its raw length. The relay itself
// uses the incremental scanner below; this is the whole-buffer form.
proxy_chunked_complete :: proc(src: []byte) -> (complete: bool, length: int) {
	scan: Chunk_Scan
	consumed, done, bad := proxy_chunk_scan_step(&scan, src)
	if !done || bad {
		return false, 0
	}
	return true, consumed
}

// Chunk_Scan walks a chunked body byte by byte so the relay knows when the
// terminating chunk (and its trailer section) has gone past, without ever
// buffering the body itself.
Chunk_Scan :: struct {
	phase:    Chunk_Phase,
	remaining: int, // bytes left in the current chunk
	digits:   int,  // hex digits seen in the current size line
	trail_pos: int, // 0 at line start, 1 after CR, 2 mid-line
	finished: bool, // terminal chunk seen
}

Chunk_Phase :: enum {
	Size,      // reading the hex size line
	Size_CR,   // saw CR, expect LF
	Data,      // inside chunk data
	Data_CR,   // saw data, expect CR
	Data_LF,   // saw CR, expect LF
	Trailer,   // trailer section lines until a blank line
}

/*
proxy_chunk_scan_step advances the scanner over `data` and reports how many
bytes belong to the body so far (they are relayed verbatim) and whether the
whole message is complete. A malformed size line stops the scan and reports
completion, which ends the relay; the client then sees a truncated body
rather than a silently corrupted one.
*/
proxy_chunk_scan_step :: proc(s: ^Chunk_Scan, data: []byte) -> (consumed: int, done: bool, bad: bool) {
	for consumed < len(data) {
		ch := data[consumed]
		consumed += 1
		switch s.phase {
		case .Size:
			switch {
			case ch == '\r':
				s.phase = .Size_CR
			case ch == '\n':
				// tolerate a bare LF
				if s.remaining == 0 {
					s.phase = .Trailer
					s.trail_pos = 0
				} else {
					s.phase = .Data
				}
			case ch == ';':
				// chunk extension: ignore until the line ends
			case ch >= '0' && ch <= '9':
				s.remaining = s.remaining * 16 + int(ch - '0')
				s.digits += 1
			case ch >= 'a' && ch <= 'f':
				s.remaining = s.remaining * 16 + int(ch - 'a') + 10
				s.digits += 1
			case ch >= 'A' && ch <= 'F':
				s.remaining = s.remaining * 16 + int(ch - 'A') + 10
				s.digits += 1
			case:
				// malformed: stop here, the body ends truncated
				s.finished = true
				return consumed, true, true
			}
			if s.remaining > MAX_CHUNK_SIZE {
				s.finished = true
				return consumed, true, true
			}
		case .Size_CR:
			if ch != '\n' {
				s.finished = true
				return consumed, true, true
			}
			if s.remaining == 0 {
				s.phase = .Trailer
				s.trail_pos = 0
			} else {
				s.phase = .Data
			}
		case .Data:
			step := len(data) - (consumed - 1)
			if step > s.remaining {
				step = s.remaining
			}
			consumed += step - 1
			s.remaining -= step
			if s.remaining == 0 {
				s.phase = .Data_CR
			}
		case .Data_CR:
			if ch == '\r' {
				s.phase = .Data_LF
			} else {
				s.finished = true
				return consumed, true, true
			}
		case .Data_LF:
			if ch != '\n' {
				s.finished = true
				return consumed, true, true
			}
			s.phase = .Size
			s.remaining = 0
			s.digits = 0
		case .Trailer:
			// only an empty line ends the trailer section, so the state
			// has to remember whether the line seen so far had content
			switch s.trail_pos {
			case 0: // at line start
				if ch == '\r' {
					s.trail_pos = 1 // maybe an empty line
				} else if ch == '\n' {
					s.finished = true
					return consumed, true, false
				} else {
					s.trail_pos = 2 // line has content
				}
			case 1: // CR right at line start: an empty line ends the body
				if ch == '\n' {
					s.finished = true
					return consumed, true, false
				}
				s.trail_pos = 2
			case 2: // mid-line
				if ch == '\r' {
					s.trail_pos = 3
				}
			case: // CR at the end of a non-empty line
				if ch == '\n' {
					s.trail_pos = 0 // next line starts fresh
				} else {
					s.trail_pos = 2
				}
			}
		}
	}
	if s.phase == .Trailer && s.finished {
		return consumed, true, false
	}
	return consumed, false, false
}

// is_dial_timeout recognizes a dial timeout inside the Network_Error
// union (the dial operation mixes Create_Socket_Error and Dial_Error).
is_dial_timeout :: proc(err: net.Network_Error) -> bool {
	if de, ok := err.(net.Dial_Error); ok && de == .Timeout {
		return true
	}
	return false
}
