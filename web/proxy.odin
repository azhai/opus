package web

import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

/*
Proxy forwards requests to upstream HTTP/1.1 servers and relays the
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

  - Every proxied request opens a fresh upstream connection and sends it
    `Connection: close`, so no upstream keep-alive pool is needed. The
    upstream socket's lifetime is exactly one request.
  - The upstream response is fully buffered on the connection, then
    relayed through the normal Write path. Large responses therefore cost
    memory proportional to their size (bounded by max_body_size); a future
    streaming mode can reuse the send_phase machinery.
  - Hop-by-hop headers are dropped in both directions. `Host` is rewritten
    to the upstream, and `X-Forwarded-For` / `X-Forwarded-Proto` / `Via`
    are added on the way out.
  - Upstream framing is relayed faithfully: Content-Length passes through,
    a chunked body is passed through with its framing intact (completeness
    is decided by walking the chunk sizes, not by decoding), and a body
    with neither is buffered until upstream EOF and re-framed with a
    Content-Length of the proxy's own.
  - Multiple upstreams are load balanced round-robin.

Errors: connect/send/read failures become 502, upstream read timeouts
become 504, and the client connection is closed after an error response.
*/

Proxy :: struct {
	upstreams:    [dynamic]net.Endpoint,
	hosts:        [dynamic]string, // "host:port" per upstream, for the Host header
	next:         int,             // round-robin cursor
	strip_prefix: string,          // "/api" is stripped from the client path
	timeout:      time.Duration,   // per upstream operation (dial/send/recv)
	allocator:    mem.Allocator,
}

// proxy_init parses the upstream addresses ("127.0.0.1:9000", "[::1]:9000").
// It returns false (and logs) if any address is invalid.
proxy_init :: proc(p: ^Proxy, upstreams: []string, allocator := context.allocator) -> bool {
	p.allocator = allocator
	p.timeout = 10 * time.Second
	p.upstreams = make([dynamic]net.Endpoint, allocator)
	p.hosts = make([dynamic]string, allocator)
	for u in upstreams {
		ep, ok := net.parse_endpoint(u)
		if !ok {
			log_error("web: invalid upstream address: %q", u)
			return false
		}
		append(&p.upstreams, ep)
		append(&p.hosts, clone_string(u, allocator))
	}
	return true
}

proxy_destroy :: proc(p: ^Proxy) {
	if p.upstreams != nil {
		delete(p.upstreams)
		p.upstreams = nil
	}
	if p.hosts != nil {
		for h in p.hosts {
			delete(h, p.allocator)
		}
		delete(p.hosts)
		p.hosts = nil
	}
}

// proxy_next_upstream picks the next upstream round-robin.
proxy_next_upstream :: proc(p: ^Proxy) -> (net.Endpoint, string) {
	i := p.next % len(p.upstreams)
	p.next = (p.next + 1) % len(p.upstreams)
	return p.upstreams[i], p.hosts[i]
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

// proxy_serve_root is proxy_serve with an explicit proxy; use it when a
// router (not the server) owns the proxy state.
//
// On entry the connection is in Process with a fresh Response. This either
// writes a complete error response (no upstream configured) and returns,
// or serializes the upstream request, moves the connection to .Proxy and
// returns; the upstream callbacks then relay the response.
proxy_serve_root :: proc(p: ^Proxy, req: ^Request, res: ^Response) {
	c := req.conn
	if len(p.upstreams) == 0 {
		res.status = .Bad_Gateway
		response_write_string(res, "502 no upstream configured\n")
		return
	}
	c.proxy_cfg = p
	up, host := proxy_next_upstream(p)

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

	// one upstream connection per request keeps the lifecycle trivial
	buf_append_string(b, "Connection: close\r\n")
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
	c.proxy_head_len = 0
	c.proxy_remaining = 0
	c.state = .Proxy
	c.proxy_op = nbio.dial_poly(up, c, on_proxy_dial, timeout = p.timeout)
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
		if is_dial_timeout(op.dial.err) {
			proxy_fail(c, .Gateway_Timeout, "504 upstream connect timeout\n")
		} else {
			proxy_fail(c, .Bad_Gateway, "502 upstream connect failed\n")
		}
		return
	}
	c.proxy_sock = op.dial.socket
	c.proxy_open = true
	net.set_option(c.proxy_sock, .TCP_Nodelay, true)
	c.proxy_op = nbio.send_poly(
		c.proxy_sock,
		[][]byte{buf_slice(&c.proxy_req)},
		c,
		on_proxy_sent,
		all = true,
		timeout = c.proxy_cfg.timeout,
	)
}

on_proxy_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.proxy_op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: proxy send failed: %v", op.send.err)
		if se, ok := op.send.err.(net.TCP_Send_Error); ok && se == .Timeout {
			proxy_fail(c, .Gateway_Timeout, "504 upstream write timeout\n")
		} else {
			proxy_fail(c, .Bad_Gateway, "502 upstream write failed\n")
		}
		return
	}
	proxy_recv_arm(c)
}

proxy_recv_arm :: proc(c: ^Conn) {
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
			proxy_fail(c, .Gateway_Timeout, "504 upstream timeout\n")
			return
		}
		// a reset mid-stream is only acceptable for close-delimited
		// bodies that already have a head
		if c.proxy_state == .Until_Close && buf_len(&c.proxy_buf) > 0 {
			proxy_complete(c)
			return
		}
		log_debug("web: proxy recv failed: %v", op.recv.err)
		proxy_fail(c, .Bad_Gateway, "502 upstream read failed\n")
		return
	}
	n := op.recv.received
	if n == 0 {
		// upstream closed its write side: the body ends here for
		// close-delimited responses, anything else is a short read
		if c.proxy_state == .Until_Close {
			proxy_complete(c)
			return
		}
		proxy_fail(c, .Bad_Gateway, "502 upstream closed early\n")
		return
	}
	buf_append(&c.proxy_buf, c.rbuf[:n])
	proxy_advance(c)
	if c.state == .Proxy {
		// response still incomplete: keep reading. proxy_complete /
		// proxy_fail move the machine out of .Proxy when done.
		proxy_recv_arm(c)
	}
}

// proxy_advance parses the upstream head once available, then decides
// whether the body is complete. Incomplete states leave a recv armed by
// the caller's loop.
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
	}

	switch c.proxy_state {
	case .Done:
		// no body expected (204/304, or a HEAD request)
		proxy_complete(c)
	case .Content_Length:
		if buf_len(&c.proxy_buf) >= c.proxy_head_len + c.proxy_remaining {
			proxy_complete(c)
		}
	case .Chunked:
		body := buf_slice(&c.proxy_buf)[c.proxy_head_len:]
		if complete, _ := proxy_chunked_complete(body); complete {
			proxy_complete(c)
		}
	case .Until_Close:
		// wait for upstream EOF
	case .Head, .None:
		// need more data
	}
}

// proxy_complete relays the buffered upstream response to the client and
// re-enters the Write state.
proxy_complete :: proc(c: ^Conn) {
	if c.proxy_open {
		nbio.close(c.proxy_sock)
		c.proxy_open = false
	}

	w := &c.res
	body_start := c.proxy_head_len
	#partial switch c.proxy_state {
	case .Content_Length:
		body_end := body_start + c.proxy_remaining
		if body_end > buf_len(&c.proxy_buf) {
			body_end = buf_len(&c.proxy_buf)
		}
		buf_append(&w.body, buf_slice(&c.proxy_buf)[body_start:body_end])
	case .Chunked:
		// relay the framing bytes verbatim; completeness was decided by
		// walking the chunk sizes in proxy_advance
		body := buf_slice(&c.proxy_buf)[body_start:]
		_, length := proxy_chunked_complete(body)
		if length > len(body) {
			length = len(body)
		}
		buf_append(&w.body, body[:length])
	case .Until_Close:
		buf_append(&w.body, buf_slice(&c.proxy_buf)[body_start:])
	case .Done:
		// no body
	}

	filter_apply_all(c.server, c)
	response_build(w, &c.out, conn_scratch(c))
	c.state = .Write
	conn_drive(c)
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

Proxy_State :: enum {
	None,          // not proxying
	Head,          // accumulating the upstream response head
	Content_Length,// body length known
	Chunked,       // chunked body, relayed with framing intact
	Until_Close,   // body delimited by upstream EOF
	Done,          // head complete, no body expected
}

Head_Parse_Result :: enum {
	Ok,
	Skip,     // 1xx informational head, keep looking for the real one
	Malformed,
}

// proxy_parse_head parses one upstream response head into the connection's
// response: status (with the upstream reason phrase), headers (hop-by-hop
// dropped, Content-Length/Transfer-Encoding passed through), and the body
// framing decision in c.proxy_state / c.proxy_remaining.
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
	te_chunked := false
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
			if contains_ignore_case(value, "chunked") {
				te_chunked = true
			}
		} else if is_hop_by_hop_header(key) {
			continue
		} else if eq_ignore_case(key, "Content-Length") {
			if n, cok := parse_int(value); cok && n >= 0 {
				c.proxy_remaining = n
				has_cl = true
			}
			// pass the header through verbatim
		}
		append(&w.headers, Header{key = key, value = value})
		count += 1
		if count > MAX_HEADERS {
			return .Malformed
		}
	}

	// body framing decision
	if code == 204 || code == 304 {
		c.proxy_state = .Done
	} else if c.req.method == .Head {
		// a HEAD response carries the framing the GET would have had,
		// but no body ever follows
		c.proxy_state = .Done
	} else if has_cl {
		c.proxy_state = .Content_Length
	} else if te_chunked {
		c.proxy_state = .Chunked
	} else {
		c.proxy_state = .Until_Close
		// the upstream delimited its body with EOF; the proxy buffers it
		// and re-frames it with a Content-Length of its own, so the
		// client connection keeps its negotiated keep-alive semantics
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

// proxy_chunked_complete walks the chunked framing in src without decoding.
// Returns whether the body (terminating chunk + trailer section) is fully
// present, and its raw byte length including the terminator.
proxy_chunked_complete :: proc(src: []byte) -> (complete: bool, length: int) {
	pos := 0
	for {
		nl := bytes_index(src[pos:], "\r\n")
		if nl < 0 {
			return false, 0
		}
		size_line := string(src[pos : pos + nl])
		semi := string_index_byte(size_line, ';')
		size_str := size_line
		if semi >= 0 {
			size_str = size_line[:semi]
		}
		if len(size_str) == 0 {
			return false, 0
		}
		size := 0
		for i in 0..<len(size_str) {
			d := hex_nibble(size_str[i])
			if d < 0 {
				return false, 0
			}
			size = size * 16 + d
			if size > MAX_CHUNK_SIZE {
				return false, 0
			}
		}
		pos += nl + 2

		if size == 0 {
			// trailer section, terminated by a blank line
			for {
				nl2 := bytes_index(src[pos:], "\r\n")
				if nl2 < 0 {
					return false, 0
				}
				if nl2 == 0 {
					return true, pos + 2
				}
				pos += nl2 + 2
			}
		}

		if pos + size + 2 > len(src) {
			return false, 0
		}
		if src[pos + size] != '\r' || src[pos + size + 1] != '\n' {
			return false, 0
		}
		pos += size + 2
	}
}

// is_dial_timeout recognizes a dial timeout inside the Network_Error
// union (the dial operation mixes Create_Socket_Error and Dial_Error).
is_dial_timeout :: proc(err: net.Network_Error) -> bool {
	if de, ok := err.(net.Dial_Error); ok && de == .Timeout {
		return true
	}
	return false
}
