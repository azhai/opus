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
	Write,
	Closed,
}

Send_Phase :: enum {
	None,
	File,
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
	proxy_buf:      Buf, // upstream response accumulator
	proxy_sock:     net.TCP_Socket,
	proxy_open:     bool,
	proxy_op:       ^nbio.Operation,
	proxy_cfg:      ^Proxy,
	proxy_state:    Proxy_State,
	proxy_head_len: int,
	proxy_remaining: int,

	req: Request,
	res: Response,

	body_remaining: int,
	chunked:        bool,
	requests:       int,

	idle_since: time.Time,

	file_handle: nbio.Handle,
	send_phase:  Send_Phase,

	op:      ^nbio.Operation,
	closing: bool,
	closed:  bool,
}

conn_scratch :: proc(c: ^Conn) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&c.scratch)
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
		case .Proxy:
			// parked: an upstream request is in flight; its callbacks
			// drive the machine onwards
			return
		case .Write:
			conn_begin_write(c)
			return
		case .Closed:
			return
		}
	}
}

conn_recv_arm :: proc(c: ^Conn, timeout: time.Duration) {
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
	data := buf_slice(&c.inbuf)
	idx := bytes_index(data, "\r\n\r\n")
	if idx < 0 {
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
	if !path_is_safe(req.path) {
		conn_error(c, .Bad_Request, "400 bad request\n")
		return true
	}
	buf_consume(&c.inbuf, head_len)

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

	// request body
	te, has_te := request_header(req, "Transfer-Encoding")
	if has_te && contains_ignore_case(te, "chunked") {
		c.chunked = true
		c.state = .Read_Body
		return true
	}
	if cl, has_cl := request_header(req, "Content-Length"); has_cl {
		n, ok := parse_int(cl)
		if !ok || n < 0 {
			conn_error(c, .Bad_Request, "400 bad request\n")
			return true
		}
		if n > c.server.max_body_size {
			conn_error(c, .Payload_Too_Large, "413 payload too large\n")
			return true
		}
		if n == 0 {
			c.state = .Process
			return true
		}
		if buf_len(&c.inbuf) >= n {
			c.req.body = clone_bytes(buf_slice(&c.inbuf)[:n], conn_scratch(c))
			buf_consume(&c.inbuf, n)
			c.state = .Process
			return true
		}
		c.body_remaining = n
		c.state = .Read_Body
		return true
	}

	c.state = .Process
	return true
}

// conn_try_body accumulates the request body. Returns true when the machine
// advanced; false when more data is needed and a recv was armed.
conn_try_body :: proc(c: ^Conn) -> bool {
	if c.chunked {
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

conn_process :: proc(c: ^Conn) {
	w := &c.res
	if c.server.handler != nil {
		c.server.handler(&c.req, w)
	} else {
		w.status = .Not_Found
		response_write_string(w, "404 page not found\n")
	}

	if c.state == .Proxy {
		// the handler hijacked the connection into proxy mode; the
		// upstream callbacks take it from here
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
			offset = 0,
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

conn_request_reset :: proc(c: ^Conn) {
	// NOTE: `in` is deliberately not reset here: it may already hold the
	// head of a pipelined request. It is drained by the head/body parser.
	mem.dynamic_arena_reset(&c.scratch)
	buf_reset(&c.out)
	buf_reset(&c.body_buf)
	buf_reset(&c.proxy_req)
	buf_reset(&c.proxy_buf)
	c.req = {}
	c.res = {}
	c.body_remaining = 0
	c.chunked = false
	c.send_phase = .None
	c.idle_since = {}
	c.proxy_state = .None
	c.proxy_head_len = 0
	c.proxy_remaining = 0
	c.proxy_cfg = nil
}

// conn_error emits a minimal error response and closes the connection
// once it has been written.
conn_error :: proc(c: ^Conn, status: Status, msg: string) {
	log_debug("web: conn %v error %v", c.remote, status)
	buf_reset(&c.out)
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
	if len(p) == 0 || p[0] != '/' {
		return false
	}
	if string_index(p, "..") >= 0 {
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
