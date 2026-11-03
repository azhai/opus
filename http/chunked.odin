package http

import "../buffer"

/*
Chunked transfer-coding (RFC 9112 section 7.1): the framing, both directions.

Decoding is pure - bytes in, bytes out - so it sits here next to the other
rules, and the request parser, the response filter and the tests all share it
without a connection. Encoding a whole response body is `web.Chunked_Filter`'s
job (the decision "this body is chunked" belongs to the pipeline), but the
frame itself is `chunked_frame` here, because SSE and the hub write frames too
and three copies of "hex length, CRLF, data, CRLF" is two too many.
*/

// MAX_CHUNK_SIZE is the largest single chunk either side will accept. A peer
// that announces a bigger one is not sending us something we want to buffer.
MAX_CHUNK_SIZE :: 16 << 20

// CHUNKED_TERMINATOR ends a chunked body: a zero-length chunk, then the empty
// trailer section.
CHUNKED_TERMINATOR :: "0\r\n\r\n"

// chunked_frame appends one chunk to `b`: the size in hex, CRLF, the payload,
// CRLF. Frames nest, so a payload that is itself a frame is fine.
chunked_frame :: proc(b: ^buffer.Buf, payload: []byte) {
	buffer.write_hex(b, len(payload))
	buffer.buf_append_string(b, "\r\n")
	buffer.buf_append(b, payload)
	buffer.buf_append_string(b, "\r\n")
}

/*
chunked_decode decodes a chunked request body from `in`, appending the
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

chunked_decode :: proc(
	src: []byte,
	out: ^buffer.Buf,
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
		nl := buffer.bytes_index(src[pos:], "\r\n")
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
				nl2 := buffer.bytes_index(src[pos:], "\r\n")
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
			buffer.buf_append(out, src[pos : pos + size])
		}
		pos += size + 2
	}
}
