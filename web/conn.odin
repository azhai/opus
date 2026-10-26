package web

import "base:intrinsics"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

RECV_BUF_SIZE :: 16 << 10

/*
Conn_State is the connection-level state machine (lighttpd2's outer state
machine). One TCP connection walks it once per pipelined request:

	Read_Head -> (Read_Body) -> Process -> Write -> Read_Head -> ...

The request-level parser states live inside parse_request / the body
reader; keeping the two layers separate is what makes keep-alive and
pipelining tractable.

`Proxy` is a detour taken when the handler is a reverse proxy: the
connection parks there while an upstream request is in flight, and the
upstream response is relayed back through the normal Write path.
*/
Conn_State :: enum {
	Read_Head,
	Read_Body,
	Process,
	Proxy,
	Async, // handler deferred; a continuation owns the rest (see async.odin)
	Write,
	Closed,
}

Send_Phase :: enum {
	None,
	File,
}

/*
Body_Sink consumes a request body as it arrives instead of accumulating it in
`Request.body`. It exists so an upload can be written out while it is being
received: the alternative - buffer the whole body, then hand it to a handler -
makes a large upload cost as much RAM as it is large.

A sink is installed before the body is read (see `Server.on_head` /
`upload_sink_attach`) and is called with

  - `write` for each chunk, in order. Returning false aborts the request with
    a 400 and leaves the reason in the sink;
  - `finish` once, after the last byte. Returning false also aborts;
  - `teardown` exactly once, from `conn_close` or from the keep-alive reset -
    whatever the sink created (temp files) is released here.

The zero Body_Sink means "no sink": the body is buffered as before.
*/
Body_Sink :: struct {
	write:    proc(ud: rawptr, chunk: []byte) -> bool,
	finish:   proc(ud: rawptr) -> bool,
	teardown: proc(ud: rawptr),
	ud:       rawptr,
}

/*
Conn is one client connection: socket, buffers, the in-flight request and
response, and the per-connection arena. All per-request scratch memory
(head clone, header table, decoded path, response body) is allocated from
`scratch` and released in one shot between keep-alive requests.
*/
Conn :: struct {
	server: ^Server,
	socket: net.TCP_Socket,
	remote: net.Endpoint,
	state:  Conn_State,

	scratch: mem.Dynamic_Arena,

	rbuf:     [RECV_BUF_SIZE]byte,
	inbuf: Buf, // raw bytes not yet consumed (head + body + pipelined)
	out:      Buf, // response head (and body) pending write
	body_buf: Buf, // chunked request body staging

	// proxy state (see proxy.odin); only live while state == .Proxy
	proxy_req:      Buf, // serialized upstream request
	proxy_buf:      Buf, // upstream bytes not yet relayed
	proxy_sock:     net.TCP_Socket,
	proxy_open:     bool,
	proxy_op:       ^nbio.Operation,
	proxy_cfg:      ^Proxy,
	proxy_state:    Proxy_State,
	proxy_framing:  Proxy_Framing,
	proxy_scan:     Chunk_Scan,
	proxy_head_len: int,
	proxy_remaining: int,

	proxy_upstream:       int,  // index into proxy_cfg.upstreams
	proxy_pooled:         bool, // the upstream socket came from the pool
	proxy_retryable:      bool, // may be replayed on a fresh connection
	proxy_client_started: bool, // response head reached the client
	proxy_upstream_close: bool, // upstream asked for Connection: close
	proxy_body_done:      bool, // upstream body fully relayed
	proxy_body_broken:    bool, // relay stopped early (reset, bad chunk)

	// TLS state (see tls.odin); nil on a plaintext connection
	tls:            ^Tls_Session,
	tls_net:        []byte, // ciphertext received from the socket
	tls_out:        Buf,    // ciphertext waiting to be sent
	tls_file_buf:   []byte, // plaintext chunk of a file body
	tls_file_offset: i64,

	req: Request,
	res: Response,

	// body_sink diverts the request body as it arrives (upload.odin);
	// `Request.body` stays empty when one is installed
	body_sink: Body_Sink,

	body_remaining: int,
	chunked:        bool,
	requests:       int,

	// head_scanned is how far into `inbuf` the CRLFCRLF search has already
	// looked. Without it, a head that arrives in pieces is rescanned from
	// byte 0 after every recv: 8 KiB of headers delivered in 512-byte
	// segments costs 16 scans of a growing buffer instead of one pass.
	head_scanned: int,

	// batch_ok says the request that just finished consumed its head and
	// nothing else, so `inbuf` now starts exactly at the next pipelined
	// request. Only then may the write path defer its flush (see
	// conn_batch_next): with a body still buffered, scanning for the next
	// head would find a terminator inside that body.
	batch_ok: bool,

	// out_mark is where the current request's output starts inside `c.out`.
	// An error response truncates back to it instead of clearing the buffer,
	// because in a pipeline batch `c.out` already holds the responses of the
	// requests that came before - and a bad request in the middle must not
	// erase them.
	out_mark: int,

	idle_since: time.Time,

	file_handle: nbio.Handle,
	send_phase:  Send_Phase,

	op:      ^nbio.Operation,

	// async parking (see async.odin): a deferred response keeps the request
	// alive across event loop turns, and async_op watches the peer while it
	// waits (a separate slot because c.op is then used by the stream's writes)
	async:    Async_State,
	async_op: ^nbio.Operation,

	closing: bool,
	closed:  bool,
}

conn_scratch :: proc(c: ^Conn) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&c.scratch)
}

/*
conn_allocator exposes the connection's scratch allocator. The response is
serialized *after* the handler returns, so header strings a handler hands
over must outlive the handler call; clone them with this allocator (it is
released when the request is done, together with the rest of the scratch).
*/
conn_allocator :: proc(c: ^Conn) -> mem.Allocator {
	return conn_scratch(c)
}

/*
conn_set_body_sink installs a consumer for the request body. It must be called
before the body is read - in practice from `Server.on_head` - and it replaces
the buffering behaviour for this request: `Request.body` stays empty and the
sink sees the bytes instead. `upload.odin` is the only user today.

Installing a second sink (or one after the body was read) is refused.
*/
conn_set_body_sink :: proc(c: ^Conn, sink: Body_Sink) -> bool {
	if c == nil || c.closed || c.body_sink.write != nil || sink.write == nil {
		return false
	}
	switch c.state {
	case .Read_Head, .Read_Body:
	case .Process, .Proxy, .Async, .Write, .Closed:
		return false
	}
	c.body_sink = sink
	return true
}

// conn_body_sink_teardown releases whatever the sink created. Called once per
// request, from the keep-alive reset or from conn_close.
conn_body_sink_teardown :: proc(c: ^Conn) {
	sink := c.body_sink
	c.body_sink = {}
	if sink.teardown != nil {
		sink.teardown(sink.ud)
	}
}

conn_new :: proc(s: ^Server, socket: net.TCP_Socket, remote: net.Endpoint) -> ^Conn {
	c := new(Conn, s.allocator)
	c.server = s
	c.socket = socket
	c.remote = remote
	c.state = .Read_Head
	mem.dynamic_arena_init(&c.scratch, s.allocator)
	buf_init(&c.inbuf, s.allocator)
	buf_init(&c.out, s.allocator)
	buf_init(&c.body_buf, s.allocator)
	buf_init(&c.proxy_req, s.allocator)
	buf_init(&c.proxy_buf, s.allocator)
	buf_init(&c.tls_out, s.allocator)
	append(&s.conns, c)
	s.stats.conns_opened += 1
	s.stats.conns_active = len(s.conns)
	log_debug("web: conn %v opened", remote)
	if s.on_conn_open != nil {
		s.on_conn_open(s, c)
	}
	return c
}

conn_destroy :: proc(c: ^Conn) {
	if c.res.file_open {
		nbio.close(c.res.file_handle)
		c.res.file_open = false
	}
	// defensive: conn_close normally tears the upstream down first
	if c.proxy_open {
		nbio.close(c.proxy_sock)
		c.proxy_open = false
	}
	buf_destroy(&c.inbuf)
	buf_destroy(&c.out)
	buf_destroy(&c.body_buf)
	buf_destroy(&c.proxy_req)
	buf_destroy(&c.proxy_buf)
	buf_destroy(&c.tls_out)
	tls_destroy(c)
	mem.dynamic_arena_destroy(&c.scratch)
	alloc := c.server.allocator
	free(c, alloc)
}

// conn_close tears the connection down. Any in-flight nbio operation is
// cancelled first so its callback can never touch freed memory; the socket
// itself is closed asynchronously and the Conn is freed from that callback.
conn_close :: proc(c: ^Conn) {
	if c.closed {
		return
	}
	c.closed = true
	c.state = .Closed

	s := c.server
	for i in 0..<len(s.conns) {
		if s.conns[i] == c {
			unordered_remove(&s.conns, i)
			break
		}
	}
	s.stats.conns_active = len(s.conns)

	if c.op != nil {
		nbio.remove(c.op)
		c.op = nil
	}
	// the continuation must be told before the connection memory is reused:
	// a stream subscriber removes itself from its hub here
	conn_async_detach(c)
	// likewise for a streaming body: temp files outlive the socket unless the
	// request got the chance to release them
	conn_body_sink_teardown(c)
	// cancel any in-flight upstream operation before its socket goes away
	if c.proxy_op != nil {
		nbio.remove(c.proxy_op)
		c.proxy_op = nil
	}
	if c.proxy_open {
		nbio.close(c.proxy_sock)
		c.proxy_open = false
	}
	if s.on_conn_close != nil {
		s.on_conn_close(s, c)
	}
	log_debug("web: conn %v closed after %v request(s)", c.remote, c.requests)
	nbio.close_poly(c.socket, c, on_socket_closed)
}

on_socket_closed :: proc(op: ^nbio.Operation, c: ^Conn) {
	conn_destroy(c)
}

/*
WRITE_BATCH_BYTES caps how much pipelined response data may pile up in `c.out`
before it is flushed.

A pipelining client writes N requests in one go; without batching the server
answers with N send operations - N syscalls, N packets, and N wakeups on the
client. Coalescing up to 16 KiB of responses into a single write turns the
per-request cost of a pipeline from a syscall into a memcpy, which is where the
whole difference lives: the serialization itself is a few hundred nanoseconds
(see bench/), while one send operation is measured in microseconds.
*/
WRITE_BATCH_BYTES :: 16 << 10

/*
conn_batch_next decides whether the response that was just serialized can wait
in `c.out` while the next pipelined request is handled.

It is conservative on purpose. Batching is refused when the connection is
closing, when the response carries a file body (sendfile has its own send),
when TLS is in play (`c.out` is not what reaches the socket), and - the one
that matters - unless the *next* request head is already buffered. Deferring a
flush while waiting for more input would deadlock a client that is itself
waiting for the responses before it sends more.
*/
conn_batch_next :: proc(c: ^Conn) -> bool {
	if !c.res.keep_alive || c.closing || c.closed || c.op != nil {
		return false
	}
	if c.tls != nil || file_pending(&c.res) || !c.batch_ok {
		return false
	}
	if buf_len(&c.out) >= WRITE_BATCH_BYTES {
		return false
	}
	data := buf_slice(&c.inbuf)
	if len(data) == 0 {
		return false
	}
	// batch_ok means `data` starts at a request head, so the first terminator
	// found belongs to that head and not to a body left in the buffer
	return bytes_index(data, "\r\n\r\n") >= 0
}

// conn_drive advances the connection state machine as far as it can go
// without blocking. Every state that needs more data arms a recv and stops;
// the Write state is always asynchronous and returns.
conn_drive :: proc(c: ^Conn) {
	for {
		log_debug("DRIVE state=%v in=%v out=%v reqs=%v", c.state, buf_len(&c.inbuf), buf_len(&c.out), c.requests)
		switch c.state {
		case .Read_Head:
			if !conn_try_head(c) {
				return
			}
		case .Read_Body:
			if !conn_try_body(c) {
				return
			}
		case .Process:
			conn_process(c)
			if c.state == .Closed {
				// the handler released the connection (response_hijack):
				// the socket is no longer ours and nothing is left to
				// drive, so free the Conn here — the loop must not touch
				// it again
				conn_destroy(c)
				return
			}
		case .Proxy:
			// parked: an upstream request is in flight; its callbacks
			// drive the machine onwards
			return
		case .Async:
			// parked: a deferred handler will resume this connection
			return
		case .Write:
			if conn_batch_next(c) {
				// responses stay in c.out: reset the request half of the
				// connection, keep the bytes, and parse the next request
				conn_request_reset(c, keep_output = true)
				c.state = .Read_Head
				continue
			}
			conn_begin_write(c)
			return
		case .Closed:
			return
		}
	}
}

conn_recv_arm :: proc(c: ^Conn, timeout: time.Duration) {
	if c.tls != nil {
		tls_recv_arm(c, timeout)
		return
	}
	c.op = nbio.recv_poly(c.socket, [][]byte{c.rbuf[:]}, c, on_recv, all = false, timeout = timeout)
}

on_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.recv.err != nil {
		log_debug("web: conn %v recv error: %v", c.remote, op.recv.err)
		conn_close(c)
		return
	}
	n := op.recv.received
	if n == 0 {
		// peer closed the write side
		conn_close(c)
		return
	}
	c.server.stats.bytes_in += u64(n)
	buf_append(&c.inbuf, c.rbuf[:n])
	conn_drive(c)
}

// conn_try_head parses a request head from the input buffer.
// Returns true when the machine advanced (head parsed, or an error response
// was queued); false when more data is needed and a recv was armed.
conn_try_head :: proc(c: ^Conn) -> bool {
	// anything already in `out` belongs to an earlier request in this pipeline
	// batch: an error from here on may only discard what this request writes
	c.out_mark = buf_len(&c.out)
	data := buf_slice(&c.inbuf)
	// resume where the last scan stopped; a terminator can straddle the
	// boundary, so back up by its length minus one
	from := c.head_scanned - 3
	if from < 0 {
		from = 0
	}
	if from > len(data) {
		from = len(data)
	}
	idx := -1
	if rel := bytes_index(data[from:], "\r\n\r\n"); rel >= 0 {
		idx = from + rel
	}
	if idx < 0 {
		c.head_scanned = len(data)
		if buf_len(&c.inbuf) >= c.server.max_header_size {
			conn_error(c, .Header_Too_Large, "431 request header fields too large\n")
			return true
		}
		conn_recv_arm(c, c.server.header_timeout)
		return false
	}
	head_len := idx + 4
	head := clone_string(string(data[:head_len]), conn_scratch(c))

	req := &c.req
	req^ = {}
	req.conn = c
	perr := parse_request(req, head, conn_scratch(c))
	if perr != .None {
		conn_error(c, parse_error_status(perr), "400 bad request\n")
		return true
	}

	decoded, _ := url_decode_path(req.path, conn_scratch(c))
	req.path = decoded
	if !path_prefix_ok(req.path) {
		conn_error(c, .Bad_Request, "400 bad request\n")
		return true
	}
	buf_consume(&c.inbuf, head_len)
	c.head_scanned = 0

	// the previous response's storage lived on the scratch arena, which was
	// reset after the last request: re-arm it for this one
	response_reset(&c.res, c, conn_scratch(c))

	c.requests += 1
	c.server.stats.requests += 1

	// keep-alive negotiation (RFC 7230 section 6.3)
	conn_hdr, has_conn := request_header(req, "Connection")
	if req.version.major == 1 && req.version.minor == 0 {
		c.res.keep_alive = has_conn && eq_ignore_case(conn_hdr, "keep-alive")
	} else {
		c.res.keep_alive = c.server.keep_alive
		if has_conn && eq_ignore_case(conn_hdr, "close") {
			c.res.keep_alive = false
		}
	}
	if c.requests >= c.server.max_requests_per_conn {
		c.res.keep_alive = false
	}

	// request body framing, strict per RFC 7230 section 3.3.3
	c.batch_ok = false
	kind, blen, ferr := request_framing(req)
	if ferr != .None {
		conn_error(c, .Bad_Request, framing_error_message(ferr))
		return true
	}

	// last chance to see the request before its body is consumed: this is
	// where a body sink is installed (Server.on_head), and the length is
	// already known here so a hook can decide based on it
	if c.server.on_head != nil && !c.server.on_head(c.server, c, c.server.on_head_ud) {
		// the hook answered the request itself; whatever state it left is
		// the one the drive loop must continue from
		return c.state == .Write
	}

	switch kind {
	case .Chunked:
		c.chunked = true
		c.state = .Read_Body
		return true
	case .Length:
		// With a body sink installed the size limit belongs to the sink: the
		// whole point of streaming is that the body is never held, so
		// `max_body_size` (a memory bound) would be the wrong ceiling. The sink
		// enforces its own per-part limit and answers 413 itself.
		if c.body_sink.write == nil && blen > c.server.max_body_size {
			conn_error(c, .Payload_Too_Large, "413 payload too large\n")
			return true
		}
		if c.body_sink.write != nil {
			// a sink streams: never take the "whole body is already
			// buffered" shortcut, or it would never see a byte
			c.body_remaining = blen
			c.state = .Read_Body
			return true
		}
		if blen == 0 {
			c.batch_ok = true
			c.state = .Process
			return true
		}
		if buf_len(&c.inbuf) >= blen {
			c.req.body = clone_bytes(buf_slice(&c.inbuf)[:blen], conn_scratch(c))
			buf_consume(&c.inbuf, blen)
			c.state = .Process
			return true
		}
		c.body_remaining = blen
		c.state = .Read_Body
		return true
	case .None:
		c.batch_ok = true
	}

	c.state = .Process
	return true
}

// ---------------------------------------------------------------------------
// strict request framing (RFC 7230 section 3.3.3)
// ---------------------------------------------------------------------------

// Body_Kind classifies how a request body is delimited after the strict
// checks passed.
Body_Kind :: enum {
	None,    // no body
	Length,  // Content-Length framing
	Chunked, // Transfer-Encoding: chunked framing
}

// Framing_Error names why a request head was rejected.
Framing_Error :: enum {
	None,
	TE_And_CL,      // Transfer-Encoding and Content-Length both present
	TE_Unsupported, // final transfer coding is not chunked
	CL_Conflict,    // duplicate or list-valued Content-Length
	CL_Invalid,     // non-numeric or negative Content-Length
}

/*
request_framing decides the request body framing, rejecting the ambiguous
combinations that enable HTTP request smuggling (RFC 7230 section 3.3.3):

  - Transfer-Encoding together with Content-Length: a middlebox reading
    one header and the origin reading the other desynchronizes the
    message stream. Rejected outright (nginx and lighttpd do the same).
  - Transfer-Encoding whose final coding is not chunked: the library
    relays only chunked framing, so anything else has no defined length.
  - Duplicate or comma-listed Content-Length: RFC 7230 section 3.3.2
    allows identical duplicates to collapse, but conflicting values are
    a smuggling vector.
*/
request_framing :: proc(r: ^Request) -> (kind: Body_Kind, length: int, err: Framing_Error) {
	te_count := 0
	te_last := ""
	cl_count := 0
	cl_value := ""
	for h in r.headers {
		if eq_ignore_case(h.key, "Transfer-Encoding") {
			te_count += 1
			te_last = h.value
		} else if eq_ignore_case(h.key, "Content-Length") {
			cl_count += 1
			if cl_count == 1 {
				cl_value = h.value
			} else if h.value != cl_value {
				return .None, 0, .CL_Conflict
			}
			if string_index_byte(h.value, ',') >= 0 {
				// a list in one header line: ambiguous, treat as conflict
				return .None, 0, .CL_Conflict
			}
		}
	}

	if te_count > 0 {
		if cl_count > 0 {
			return .None, 0, .TE_And_CL
		}
		// the final coding must be chunked (RFC 7230 section 3.3.1)
		last := te_last
		for i := len(te_last) - 1; i >= 0; i -= 1 {
			if te_last[i] == ',' {
				last = te_last[i + 1:]
				break
			}
		}
		if !eq_ignore_case(trim_ows(last), "chunked") {
			return .None, 0, .TE_Unsupported
		}
		return .Chunked, 0, .None
	}

	if cl_count == 0 {
		return .None, 0, .None
	}
	n, ok := parse_int(cl_value)
	if !ok || n < 0 {
		return .None, 0, .CL_Invalid
	}
	return .Length, n, .None
}

framing_error_message :: proc(e: Framing_Error) -> string {
	switch e {
	case .TE_And_CL:
		return "400 transfer-encoding and content-length conflict\n"
	case .TE_Unsupported:
		return "400 unsupported transfer-encoding\n"
	case .CL_Conflict:
		return "400 conflicting content-length\n"
	case .CL_Invalid:
		return "400 invalid content-length\n"
	case .None:
	}
	return "400 bad request\n"
}

// conn_try_body accumulates the request body. Returns true when the machine
// advanced; false when more data is needed and a recv was armed.
conn_try_body :: proc(c: ^Conn) -> bool {
	if c.chunked {
		if c.body_sink.write != nil {
			// streaming: release each complete chunk instead of accumulating,
			// and drop the bytes the decoder already released
			status, consumed := chunked_try_decode(buf_slice(&c.inbuf), &c.body_buf, conn_chunk_emit, c)
			if consumed > 0 {
				buf_consume(&c.inbuf, consumed)
			}
			switch status {
			case 1:
				c.chunked = false
				if !conn_body_sink_finish(c) {
					return true
				}
				c.state = .Process
				return true
			case 0:
				if buf_len(&c.inbuf) >= c.server.max_body_size {
					conn_error(c, .Payload_Too_Large, "413 payload too large\n")
					return true
				}
				conn_recv_arm(c, c.server.header_timeout)
				return false
			case:
				c.body_sink = {}
				conn_body_sink_error(c)
				return true
			}
		}

		mark := buf_len(&c.body_buf)
		status, consumed := chunked_try_decode(buf_slice(&c.inbuf), &c.body_buf)
		if status < 0 {
			conn_error(c, .Bad_Request, "400 malformed chunked body\n")
			return true
		}
		if status == 0 {
			buf_truncate(&c.body_buf, mark)
			if buf_len(&c.inbuf) >= c.server.max_body_size {
				conn_error(c, .Payload_Too_Large, "413 payload too large\n")
				return true
			}
			conn_recv_arm(c, c.server.header_timeout)
			return false
		}
		c.req.body = clone_bytes(buf_slice(&c.body_buf), conn_scratch(c))
		buf_reset(&c.body_buf)
		buf_consume(&c.inbuf, consumed)
		c.chunked = false
		c.state = .Process
		return true
	}

	if c.body_sink.write != nil {
		// Stream what has arrived and let it go: the point of a sink is that
		// the body never has to fit in `inbuf`. A pipelined request behind
		// this one stays in `inbuf` untouched, because `body_remaining` is
		// what bounds the slice taken.
		avail := buf_len(&c.inbuf)
		if avail > 0 {
			n := avail
			if n > c.body_remaining {
				n = c.body_remaining
			}
			if !c.body_sink.write(c.body_sink.ud, buf_slice(&c.inbuf)[:n]) {
				c.body_sink = {}
				conn_body_sink_error(c)
				return true
			}
			buf_consume(&c.inbuf, n)
			c.body_remaining -= n
		}
		if c.body_remaining > 0 {
			conn_recv_arm(c, c.server.header_timeout)
			return false
		}
		if !conn_body_sink_finish(c) {
			return true
		}
		c.state = .Process
		return true
	}

	if buf_len(&c.inbuf) < c.body_remaining {
		if buf_len(&c.inbuf) > c.server.max_body_size {
			conn_error(c, .Payload_Too_Large, "413 payload too large\n")
			return true
		}
		conn_recv_arm(c, c.server.header_timeout)
		return false
	}
	c.req.body = clone_bytes(buf_slice(&c.inbuf)[:c.body_remaining], conn_scratch(c))
	buf_consume(&c.inbuf, c.body_remaining)
	c.body_remaining = 0
	c.state = .Process
	return true
}

// conn_chunk_emit is the Chunk_Emit adapter for a chunked body delivered to a
// body sink: the decoder calls it once per complete chunk.
@(private)
conn_chunk_emit :: proc(ud: rawptr, chunk: []byte) -> bool {
	c := cast(^Conn) ud
	if c.body_sink.write == nil {
		return true
	}
	return c.body_sink.write(c.body_sink.ud, chunk)
}

// conn_body_sink_finish closes out the streamed body; false means the reply
// is already queued as an error.
@(private)
conn_body_sink_finish :: proc(c: ^Conn) -> bool {
	if c.body_sink.write == nil {
		return true
	}
	sink := c.body_sink
	if sink.finish != nil && !sink.finish(sink.ud) {
		c.body_sink = {}
		conn_body_sink_error(c)
		return false
	}
	return true
}

/*
conn_body_sink_error answers a request whose body the sink refused. The status
comes from `Request.form_state`, which the sink sets: a limit it enforced is a
413 (the client should send less), anything else is a body the framing claimed
and did not deliver, so 400.
*/
@(private)
conn_body_sink_error :: proc(c: ^Conn) {
	if c.req.form_state == .Too_Large {
		conn_error(c, .Payload_Too_Large, "413 payload too large\n")
		return
	}
	conn_error(c, .Bad_Request, "400 malformed request body\n")
}

conn_process :: proc(c: ^Conn) {
	w := &c.res
	if c.server.handler != nil {
		c.server.handler(&c.req, w)
	} else {
		w.status = .Not_Found
		response_write_string(w, "404 page not found\n")
	}
	conn_process_tail(c)
}

/*
conn_process_tail finishes a request: it is the half of conn_process that runs
after the handler (or after an async continuation) has produced the response.

Split out so a deferred response goes through *exactly* the same path as a
synchronous one - header negotiation, filters, serialization - instead of a
second implementation that would drift.
*/
conn_process_tail :: proc(c: ^Conn) {
	w := &c.res
	if c.state == .Proxy || c.state == .Closed || c.state == .Async {
		// Proxy: the handler hijacked the connection into proxy mode; the
		// upstream callbacks take it from here.
		// Closed: the handler released the connection (response_hijack) and
		// owns the socket now; nothing is serialized on this Conn.
		// Async: a continuation owns the response and will call back in.
		return
	}

	// an explicit Connection header from the handler wins over negotiation
	if v, ok := response_header(w, "Connection"); ok {
		if eq_ignore_case(v, "close") {
			w.keep_alive = false
		} else if eq_ignore_case(v, "keep-alive") {
			w.keep_alive = true
		}
	}

	filter_apply_all(c.server, c)
	response_build(w, &c.out, conn_scratch(c))
	c.state = .Write
}

conn_begin_write :: proc(c: ^Conn) {
	if c.tls != nil {
		tls_write_loop(c)
		return
	}
	if buf_len(&c.out) == 0 {
		conn_after_write(c)
		return
	}
	c.op = nbio.send_poly(
		c.socket,
		[][]byte{buf_slice(&c.out)},
		c,
		on_sent,
		all = true,
		timeout = c.server.write_timeout,
	)
}

/*
conn_flush_out sends whatever is buffered in c.out, encrypting it first when
the connection is wrapped in TLS. It returns false when there was nothing to
send, so callers can continue synchronously.
*/
conn_flush_out :: proc(c: ^Conn, cb: proc(op: ^nbio.Operation, c: ^Conn)) -> bool {
	if c.tls != nil {
		if buf_len(&c.out) > 0 {
			if !tls_encrypt(c, buf_slice(&c.out)) {
				conn_close(c)
				return true
			}
			buf_reset(&c.out)
		}
		if buf_len(&c.tls_out) == 0 {
			return false
		}
		c.op = nbio.send_poly(
			c.socket,
			[][]byte{buf_slice(&c.tls_out)},
			c,
			cb,
			all = true,
			timeout = c.server.write_timeout,
		)
		return true
	}
	if buf_len(&c.out) == 0 {
		return false
	}
	c.op = nbio.send_poly(
		c.socket,
		[][]byte{buf_slice(&c.out)},
		c,
		cb,
		all = true,
		timeout = c.server.write_timeout,
	)
	return true
}

// conn_after_send releases the buffer a completed send was reading from.
conn_after_send :: proc(c: ^Conn, sent: int) {
	c.server.stats.bytes_out += u64(sent)
	if c.tls != nil {
		buf_reset(&c.tls_out)
		return
	}
	buf_reset(&c.out)
}

on_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: conn %v send error: %v", c.remote, op.send.err)
		conn_close(c)
		return
	}
	c.server.stats.bytes_out += u64(op.send.sent)
	buf_reset(&c.out)

	w := &c.res
	if file_pending(w) && c.send_phase != .File {
		// head is on the wire; stream the file body zero-copy
		c.send_phase = .File
		c.op = nbio.sendfile_poly(
			c.socket,
			w.file_handle,
			c,
			on_file_sent,
			offset = w.file_offset,
			nbytes = int(w.file_size),
			timeout = c.server.write_timeout,
		)
		return
	}
	conn_after_write(c)
}

on_file_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.res.file_open {
		nbio.close(c.res.file_handle)
		c.res.file_open = false
	}
	if c.closed {
		return
	}
	if op.sendfile.err != nil {
		log_debug("web: conn %v sendfile error: %v", c.remote, op.sendfile.err)
		conn_close(c)
		return
	}
	c.server.stats.bytes_out += u64(op.sendfile.sent)
	conn_after_write(c)
}

// conn_after_write either starts the next pipelined request or parks the
// connection in keep-alive idle.
conn_after_write :: proc(c: ^Conn) {
	log_debug("AFTER_WRITE closed=%v keep_alive=%v closing=%v in=%v", c.closed, c.res.keep_alive, c.closing, buf_len(&c.inbuf))
	if c.closed {
		return
	}
	if !c.res.keep_alive || c.closing {
		conn_close(c)
		return
	}

	conn_request_reset(c)
	c.state = .Read_Head

	// pipelined bytes may already be buffered
	if buf_len(&c.inbuf) > 0 {
		conn_drive(c)
		return
	}
	c.idle_since = nbio.now()
	conn_recv_arm(c, c.server.idle_timeout)
}

conn_request_reset :: proc(c: ^Conn, keep_output := false) {
	// NOTE: `in` is deliberately not reset here: it may already hold the
	// head of a pipelined request. It is drained by the head/body parser.
	conn_body_sink_teardown(c)
	if !keep_output {
		// Both the arena and c.out are left alone while a pipeline batch is
		// still accumulating: the buffered responses live in arena memory, and
		// rewinding the arena would hand their bytes to the next request.
		mem.dynamic_arena_reset(&c.scratch)
		buf_reset(&c.out)
	}
	buf_reset(&c.body_buf)
	buf_reset(&c.proxy_req)
	buf_reset(&c.proxy_buf)
	c.req = {}
	c.res = {}
	c.body_remaining = 0
	c.chunked = false
	c.head_scanned = 0
	c.send_phase = .None
	c.idle_since = {}
	c.proxy_state = .None
	c.proxy_framing = .None
	c.proxy_scan = {}
	c.proxy_head_len = 0
	c.proxy_remaining = 0
	c.proxy_upstream = 0
	c.proxy_pooled = false
	c.proxy_retryable = false
	c.proxy_client_started = false
	c.proxy_upstream_close = false
	c.proxy_body_done = false
	c.proxy_body_broken = false
	c.proxy_cfg = nil
	c.async = {}
}

// conn_error emits a minimal error response and closes the connection
// once it has been written.
conn_error :: proc(c: ^Conn, status: Status, msg: string) {
	log_debug("web: conn %v error %v", c.remote, status)
	// truncate, not reset: responses for earlier requests in the same pipeline
	// batch are already sitting in `c.out` and their client is waiting for them
	buf_truncate(&c.out, c.out_mark)
	w := &c.res
	response_reset(w, c, conn_scratch(c))
	w.status = status
	w.keep_alive = false
	response_write_string(w, msg)
	response_build(w, &c.out, conn_scratch(c))
	c.state = .Write
	c.closing = true
}

parse_error_status :: proc(e: Parse_Error) -> Status {
	#partial switch e {
	case .URI_Too_Long:
		return .URI_Too_Long
	case .Header_Too_Large:
		return .Header_Too_Large
	}
	return .Bad_Request
}

path_is_safe :: proc(p: string) -> bool {
	if !path_prefix_ok(p) {
		return false
	}
	if string_index(p, "..") >= 0 {
		return false
	}
	return true
}

// path_prefix_ok rejects what every request must satisfy regardless of how it
// will be routed: a leading slash and no control characters (a decoded NUL
// would truncate filesystem paths). Traversal ("..") is a *filesystem* policy
// and is enforced where paths are actually mapped onto files
// (static_resolve_path) — application handlers see the decoded path and can
// reject it with their own status, which is what molly's URI layer does.
path_prefix_ok :: proc(p: string) -> bool {
	if len(p) == 0 || p[0] != '/' {
		return false
	}
	for i in 0..<len(p) {
		if p[i] < 0x20 || p[i] == 0x7f {
			return false
		}
	}
	return true
}

contains_ignore_case :: proc(s, sub: string) -> bool {
	if len(sub) == 0 {
		return true
	}
	if len(s) < len(sub) {
		return false
	}
	for i in 0..=len(s) - len(sub) {
		match := true
		for j in 0..<len(sub) {
			if lower_ascii(s[i + j]) != lower_ascii(sub[j]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

lower_ascii :: proc(c: byte) -> byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

parse_int :: proc(s: string) -> (int, bool) {
	if len(s) == 0 || len(s) > 18 {
		return 0, false
	}
	v := 0
	for i in 0..<len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + int(c - '0')
	}
	return v, true
}
