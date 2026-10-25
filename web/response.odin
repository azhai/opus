package web

import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

SERVER_NAME :: "web-odin/0.1"

/*
Response is the write side of a request.

Handlers mutate it through the `response_*` procedures; `response_build`
serializes the head (and the in-memory body, if any) into the connection's
output buffer. For file responses only the head is serialized; the body is
streamed with zero-copy `sendfile` afterwards.
*/
Response :: struct {
	conn:   ^Conn,
	status: Status,

	// reason overrides the reason phrase derived from `status` when
	// non-empty. The proxy uses it to relay upstream phrases for status
	// codes outside the Status enum.
	reason: string,

	headers: [dynamic]Header, // allocated on the connection scratch arena
	body:    Buf,             // allocated on the connection scratch arena

	file_handle: nbio.Handle,
	file_open:   bool,
	file_size:   i64,
	file_offset: int, // first byte of the file to send (Range requests)
	file_path:   string,

	chunked:   bool,
	keep_alive: bool,
	built:     bool,

	// compress is the per-response override for the gzip/deflate filter.
	// Handlers and middleware set it: .Force compresses even a small or
	// untyped body, .Deny keeps a body identity (a stream, a pre-coded
	// asset). .Default leaves the decision to the filter's own rules.
	compress: Compress_Mode,
	// compress_min overrides the filter's min_size for this response; 0
	// means "use the filter default".
	compress_min: int,
}

/*
Compress_Mode is a per-response override for content coding.

	Default - let the filter decide (size threshold + content type)
	Force   - code it regardless of size and type (a route knows best)
	Deny    - never code it (streams, pre-compressed assets,Range bodies)
*/
Compress_Mode :: enum u8 {
	Default,
	Force,
	Deny,
}

response_init :: proc(w: ^Response, c: ^Conn, allocator: mem.Allocator) {
	w.conn = c
	w.status = .OK
	w.headers = make([dynamic]Header, allocator)
	buf_init(&w.body, allocator)
}

// response_reset prepares the response for a new request on the same
// connection. Header/body storage is dropped wholesale: it lives on the
// connection scratch arena, which was just reset.
response_reset :: proc(w: ^Response, c: ^Conn, allocator: mem.Allocator) {
	w.conn = c
	w.status = .OK
	w.reason = ""
	w.headers = nil
	w.body = {}
	w.file_open = false
	w.file_size = 0
	w.file_offset = 0
	w.file_path = ""
	w.chunked = false
	w.keep_alive = false
	w.built = false
	w.compress = .Default
	w.compress_min = 0
	w.headers = make([dynamic]Header, allocator)
	buf_init(&w.body, allocator)
}

response_status :: proc(w: ^Response, s: Status) {
	w.status = s
}

response_set_header :: proc(w: ^Response, key, value: string) {
	for &h in w.headers {
		if eq_ignore_case(h.key, key) {
			h.value = value
			return
		}
	}
	append(&w.headers, Header{key = key, value = value})
}

response_header :: proc(w: ^Response, key: string) -> (string, bool) {
	for h in w.headers {
		if eq_ignore_case(h.key, key) {
			return h.value, true
		}
	}
	return "", false
}

// response_add_header appends a header without deduplicating. Use it for
// headers that legitimately repeat (Set-Cookie); response_set_header
// replaces instead.
response_add_header :: proc(w: ^Response, key, value: string) {
	append(&w.headers, Header{key = key, value = value})
}

// response_set_content_type is response_set_header("Content-Type", ct) with
// an empty value treated as "no header at all".
response_set_content_type :: proc(w: ^Response, content_type: string) {
	if len(content_type) == 0 {
		response_remove_header(w, "Content-Type")
		return
	}
	response_set_header(w, "Content-Type", content_type)
}

// response_allocator is where a header value that outlives the handler call
// has to be allocated: the connection arena for a live response (headers are
// serialized after the handler returns), context.allocator otherwise
// (synthetic responses in tests).
response_allocator :: proc(w: ^Response) -> mem.Allocator {
	if w.conn != nil {
		return conn_scratch(w.conn)
	}
	return context.allocator
}

response_write :: proc(w: ^Response, data: []byte) {
	if file_pending(w) {
		return
	}
	buf_append(&w.body, data)
}

response_write_string :: proc(w: ^Response, s: string) {
	response_write(w, transmute([]byte)s)
}

// response_send writes status, an optional Content-Type and the body in one
// call (Echo's c.Blob shape). The body is copied into the response buffer;
// the Content-Type is stored by reference, so it must outlive the handler
// call (a literal, or storage from the request/connection arena).
response_send :: proc(w: ^Response, status: Status, content_type, body: string) {
	w.status = status
	if content_type != "" {
		response_set_header(w, "Content-Type", content_type)
	}
	response_write_string(w, body)
}

// response_text writes a text/plain; charset=utf-8 body (Echo's c.String).
response_text :: proc(w: ^Response, status: Status, body: string) {
	response_send(w, status, "text/plain; charset=utf-8", body)
}

// response_html writes a text/html; charset=utf-8 body (Echo's c.HTML).
response_html :: proc(w: ^Response, status: Status, body: string) {
	response_send(w, status, "text/html; charset=utf-8", body)
}

// response_no_content sends a bodyless response (Echo's c.NoContent).
response_no_content :: proc(w: ^Response, status: Status = .No_Content) {
	w.status = status
	buf_reset(&w.body)
	w.file_open = false
}

// response_send_file switches the response to zero-copy file streaming.
// The file is opened synchronously (metadata may be cached by the static
// handler); contents are sent with `sendfile` once the head is written.
response_send_file :: proc(w: ^Response, path: string) -> bool {
	if file_pending(w) {
		return false
	}
	fi, err := os.stat(path, context.allocator)
	if err != nil {
		os.file_info_delete(fi, context.allocator)
		return false
	}
	size := fi.size
	is_regular := fi.type == .Regular
	os.file_info_delete(fi, context.allocator)
	if !is_regular {
		return false
	}
	handle, ferr := nbio.open_sync(path)
	if ferr != nil {
		return false
	}
	w.file_handle = handle
	w.file_open = true
	w.file_size = size
	w.file_path = path
	buf_reset(&w.body)
	return true
}

// response_send_file_range streams a byte range of a file: `offset` bytes
// are skipped and `length` bytes are sent (sendfile with an offset, still
// zero-copy). Used by the static handler for single-range 206 responses.
response_send_file_range :: proc(w: ^Response, path: string, offset, length: i64) -> bool {
	if file_pending(w) || offset < 0 || length < 0 {
		return false
	}
	handle, ferr := nbio.open_sync(path)
	if ferr != nil {
		return false
	}
	w.file_handle = handle
	w.file_open = true
	w.file_size = length
	w.file_offset = int(offset)
	w.file_path = path
	buf_reset(&w.body)
	return true
}

response_redirect :: proc(w: ^Response, location: string, code: Status = .Found) {
	w.status = code
	response_set_header(w, "Location", location)
	response_write_string(w, "redirecting to ")
	response_write_string(w, location)
	response_write_string(w, "\n")
}

// response_error writes a plain-text error body: the status text when
// `message` is empty (Echo's c.NoContent + HTTPError shape, without the JSON
// envelope). The status is set for the caller.
response_error :: proc(w: ^Response, status: Status, message := "") {
	w.status = status
	response_set_content_type(w, "text/plain; charset=utf-8")
	if len(message) > 0 {
		response_write_string(w, message)
	} else {
		response_write_string(w, status_text(status))
	}
	response_write_string(w, "\n")
}

// response_error_for_conn answers an error before a Request exists in a
// handler's hands - specifically from `Server.on_head`, where a hook may
// reject the request (a bad upload body) without ever reaching a handler.
// It is the same body response_error would have written.
response_error_for_conn :: proc(c: ^Conn, status: Status, message := "") {
	msg := message
	if len(msg) == 0 {
		msg = status_text(status)
	}
	conn_error(c, status, msg)
}

// response_body_size reports what the response will actually carry: the
// in-memory body, or the file size for a sendfile response. Middleware that
// logs or accounts for bytes uses this instead of poking at `body`.
response_body_size :: proc(w: ^Response) -> i64 {
	if file_pending(w) {
		return w.file_size
	}
	return i64(buf_len(&w.body))
}

Disposition :: enum {
	Inline,
	Attachment,
}

disposition_string :: proc(d: Disposition) -> string {
	switch d {
	case .Inline:
		return "inline"
	case .Attachment:
		return "attachment"
	}
	return "attachment"
}

// response_set_disposition sets Content-Disposition. The filename is quoted
// and its '"' / '\' characters escaped; non-ASCII names are emitted as-is
// (RFC 6266 allows raw UTF-8 in the quoted form).
response_set_disposition :: proc(w: ^Response, kind: Disposition, filename: string) {
	if len(filename) == 0 {
		response_set_header(w, "Content-Disposition", disposition_string(kind))
		return
	}
	alloc := response_allocator(w)
	b: Buf
	buf_init(&b, alloc)
	defer buf_destroy(&b)
	buf_append_string(&b, disposition_string(kind))
	buf_append_string(&b, "; filename=\"")
	for i in 0..<len(filename) {
		c := filename[i]
		if c == '"' || c == '\\' {
			buf_append_byte(&b, '\\')
		}
		buf_append_byte(&b, c)
	}
	buf_append_byte(&b, '"')
	// clone: the header outlives this call and buf_destroy may release the
	// scratch (the pattern every header value in this file follows)
	response_set_header(w, "Content-Disposition", clone_string(string(buf_slice(&b)), alloc))
}

// response_download sends a file as a download: Content-Type from the name,
// Content-Disposition: attachment, then the zero-copy file body (Echo's
// c.Attachment). Returns false after answering 500 when the file cannot be
// streamed.
response_download :: proc(w: ^Response, path, filename: string) -> bool {
	name := filename
	if len(name) == 0 {
		name = path
	}
	response_set_content_type(w, mime_type(name))
	response_set_disposition(w, .Attachment, name)
	if !response_send_file(w, path) {
		response_remove_header(w, "Content-Disposition")
		response_error(w, .Internal_Error, "")
		return false
	}
	return true
}

file_pending :: proc(w: ^Response) -> bool {
	return w.file_open
}

/*
response_hijack hands the connection's socket to the handler and detaches
the connection from the server: no response is built, no further bytes are
read, and the server will not close it. `false` means the connection is
already gone (or was never owned by a server, e.g. in unit tests).

The escape hatch exists for long-lived streaming responses (SSE) that
cannot be produced inside a single handler call. Ownership of the socket
moves to the caller, which must close it; the request/response buffers are
freed when the handler returns, so anything that must outlive the call has
to be copied first.
*/
response_hijack :: proc(w: ^Response) -> (socket: net.TCP_Socket, ok: bool) {
	c := w.conn
	if c == nil || c.closed || c.server == nil {
		return {}, false
	}
	s := c.server
	if c.op != nil {
		nbio.remove(c.op)
		c.op = nil
	}
	for i in 0..<len(s.conns) {
		if s.conns[i] == c {
			unordered_remove(&s.conns, i)
			break
		}
	}
	s.stats.conns_active = len(s.conns)

	socket = c.socket
	c.socket = {}
	c.closing = true
	c.closed = true
	c.state = .Closed
	return socket, true
}

// response_build serializes status line + headers (and the body, unless a
// file body will be streamed) into `out`.
response_build :: proc(w: ^Response, out: ^Buf, allocator: mem.Allocator) {
	w.built = true

	is_head := w.conn != nil && w.conn.req.method == .Head
	body_less := is_head || w.status == .No_Content || w.status == .Not_Modified
	_, has_length := response_header(w, "Content-Length")
	_, has_te := response_header(w, "Transfer-Encoding")

	if file_pending(w) && w.file_size == 0 {
		// nothing to stream: reply with an empty body
		nbio.close(w.file_handle)
		w.file_open = false
		w.file_path = ""
		response_set_header(w, "Content-Length", "0")
	} else if file_pending(w) {
		response_set_header(w, "Content-Length", int_to_string(w.file_size, allocator))
	} else if !has_length && !has_te {
		// A HEAD response carries the length the GET would have had
		// (RFC 7231 section 4.3.2); 204/304 carry no body at all.
		if w.chunked && !body_less {
			response_set_header(w, "Transfer-Encoding", "chunked")
		} else if !body_less || is_head {
			response_set_header(w, "Content-Length", int_to_string(i64(len(w.body.data)), allocator))
		}
	}

	if _, ok := response_header(w, "Connection"); !ok {
		if w.keep_alive {
			response_set_header(w, "Connection", "keep-alive")
		} else {
			response_set_header(w, "Connection", "close")
		}
	}
	if _, ok := response_header(w, "Server"); !ok {
		response_set_header(w, "Server", SERVER_NAME)
	}
	if _, ok := response_header(w, "Date"); !ok {
		now := nbio.now()
		if now == {} {
			now = time.now()
		}
		response_set_header(w, "Date", http_date(now, allocator))
	}

	// status line
	buf_append_string(out, "HTTP/1.1 ")
	write_padded_i64(out, i64(w.status), 3)
	buf_append_byte(out, ' ')
	reason := status_text(w.status)
	if len(w.reason) > 0 {
		reason = w.reason
	}
	buf_append_string(out, reason)
	buf_append_string(out, "\r\n")

	for h in w.headers {
		buf_append_string(out, h.key)
		buf_append_string(out, ": ")
		buf_append_string(out, h.value)
		buf_append_string(out, "\r\n")
	}
	buf_append_string(out, "\r\n")

	if file_pending(w) || body_less {
		return
	}
	buf_append(out, buf_slice(&w.body))
}

int_to_string :: proc(v: i64, allocator: mem.Allocator) -> string {
	digits := "0123456789"
	neg := v < 0
	mag := v
	if neg {
		mag = -mag
	}
	tmp: [24]byte
	n := 0
	if mag == 0 {
		tmp[0] = '0'
		n = 1
	}
	for mag > 0 {
		tmp[n] = digits[mag % 10]
		mag /= 10
		n += 1
	}
	total := n
	if neg {
		total += 1
	}
	out := make([]byte, total, allocator)
	i := 0
	if neg {
		out[0] = '-'
		i = 1
	}
	for j := n - 1; j >= 0; j -= 1 {
		out[i] = tmp[j]
		i += 1
	}
	return string(out)
}
