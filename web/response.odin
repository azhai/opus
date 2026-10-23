package web

import "core:mem"
import "core:nbio"
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
	file_path:   string,

	chunked:   bool,
	keep_alive: bool,
	built:     bool,
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
	w.file_path = ""
	w.chunked = false
	w.keep_alive = false
	w.built = false
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

response_write :: proc(w: ^Response, data: []byte) {
	if file_pending(w) {
		return
	}
	buf_append(&w.body, data)
}

response_write_string :: proc(w: ^Response, s: string) {
	response_write(w, transmute([]byte)s)
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

response_redirect :: proc(w: ^Response, location: string, code: Status = .Found) {
	w.status = code
	response_set_header(w, "Location", location)
	response_write_string(w, "redirecting to ")
	response_write_string(w, location)
	response_write_string(w, "\n")
}

file_pending :: proc(w: ^Response) -> bool {
	return w.file_open
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
