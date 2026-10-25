package web

/*
Filter is the pluggable stage of the response pipeline (lighttpd2's
stream/filter idea, expressed as an Odin procedure chain).

A filter receives the connection after the request handler has run and
may rewrite the response body / headers in place. Filters are chained via
`next` and applied in registration order, before the response head is
serialized. TLS, gzip/deflate and on-disk buffering are natural filters;
chunked transfer encoding ships built in.
*/
Filter :: struct {
	next:  ^Filter,
	apply: proc(f: ^Filter, c: ^Conn),
	ud:    rawptr,
}

filter_add :: proc(s: ^Server, f: ^Filter) {
	assert(f.next == nil)
	if s.filters == nil {
		s.filters = f
		return
	}
	last := s.filters
	for last.next != nil {
		last = last.next
	}
	last.next = f
}

filter_apply_all :: proc(s: ^Server, c: ^Conn) {
	f := s.filters
	for f != nil {
		f.apply(f, c)
		f = f.next
	}
}

MAX_CHUNK_SIZE :: 16 << 20

/*
Chunked_Filter frames an in-memory response body as a single HTTP/1.1
chunk followed by the terminating chunk. It is a no-op unless the response
opted into chunked encoding and has no file body.
*/
Chunked_Filter :: struct {
	using filter: Filter,
}

filter_chunked_init :: proc(f: ^Chunked_Filter) {
	f.apply = chunked_apply
}

chunked_apply :: proc(f: ^Filter, c: ^Conn) {
	w := &c.res
	if !w.chunked {
		return
	}
	if file_pending(w) {
		// A streamed file body cannot be re-framed; fall back to a
		// plain Content-Length response.
		w.chunked = false
		return
	}
	if _, ok := response_header(w, "Transfer-Encoding"); ok {
		return
	}
	body := buf_slice(&w.body)
	tmp: Buf
	buf_init(&tmp, conn_scratch(c))
	write_hex(&tmp, len(body))
	buf_append_string(&tmp, "\r\n")
	buf_append(&tmp, body)
	buf_append_string(&tmp, "\r\n0\r\n\r\n")
	w.body = tmp
}

/*
chunked_try_decode decodes a chunked request body from `in`, appending the
decoded bytes to `out` and reporting how many bytes of `in` were consumed.

Returns:
   1  the body is complete
   0  more data is needed (without a consumer, partial output is rolled back
      by the caller via the buffer mark taken before the call)
  -1  the framing is malformed
  -2  `emit` refused a chunk (a streaming consumer said no)

The `consumed` output is only meaningful when the status is 1, unless `emit`
is given: a streaming consumer releases each complete chunk as it is decoded,
so on status 0 `consumed` reports how much of `src` was already released and
the caller *must* drop those bytes - otherwise the next call would decode and
emit them a second time.
*/
Chunk_Emit :: #type proc(ud: rawptr, chunk: []byte) -> bool

chunked_try_decode :: proc(
	src: []byte,
	out: ^Buf,
	emit: Chunk_Emit = nil,
	ud: rawptr = nil,
) -> (status: int, consumed: int) {
	// stall is the "need more data" exit. It reports the processed prefix as
	// consumed when chunks have already been handed out.
	stall :: proc(pos: int, emit: Chunk_Emit) -> (int, int) {
		if emit != nil {
			return 0, pos
		}
		return 0, 0
	}

	pos := 0
	for {
		// line_start is where this chunk's size line begins. A stall while the
		// chunk *data* is still incomplete must report this position, not the
		// data start: the caller drops what was reported, and re-entering at
		// the data start would read the first CRLF inside the payload as the
		// next size line.
		line_start := pos
		nl := bytes_index(src[pos:], "\r\n")
		if nl < 0 {
			return stall(pos, emit)
		}
		size_line := string(src[pos : pos + nl])
		semi := string_index_byte(size_line, ';')
		size_str := size_line
		if semi >= 0 {
			size_str = size_line[:semi]
		}
		if len(size_str) == 0 {
			return -1, 0
		}
		size := 0
		for i in 0..<len(size_str) {
			d := hex_nibble(size_str[i])
			if d < 0 {
				return -1, 0
			}
			size = size * 16 + d
			if size > MAX_CHUNK_SIZE {
				return -1, 0
			}
		}
		pos += nl + 2

		if size == 0 {
			// trailer section, terminated by a blank line
			for {
				nl2 := bytes_index(src[pos:], "\r\n")
				if nl2 < 0 {
					return stall(line_start, emit)
				}
				if nl2 == 0 {
					return 1, pos + 2
				}
				pos += nl2 + 2
				if pos > len(src) {
					return stall(line_start, emit)
				}
			}
		}

		if pos + size + 2 > len(src) {
			return stall(line_start, emit)
		}
		if src[pos + size] != '\r' || src[pos + size + 1] != '\n' {
			return -1, 0
		}
		if emit != nil {
			if !emit(ud, src[pos : pos + size]) {
				return -2, pos
			}
		} else {
			buf_append(out, src[pos : pos + size])
		}
		pos += size + 2
	}
}
