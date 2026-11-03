package http

// The decoder on its own: complete bodies, bodies that stop mid-chunk, and
// framing that cannot be right. What a *connection* does with each status is
// tested in web/(parser|integration)_test.odin.

import "core:testing"
import "../buffer"

// ---------------------------------------------------------------------------
// chunked decoding (the encoder is web.Chunked_Filter)
// ---------------------------------------------------------------------------

@(test)
test_chunked_decode_complete :: proc(t: ^testing.T) {
	body: buffer.Buf
	buffer.buf_init(&body, context.allocator)
	defer buffer.buf_destroy(&body)

	input := "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
	status, consumed := chunked_decode(transmute([]byte)input, &body)
	testing.expect(t, status == 1)
	testing.expect(t, consumed == len(input))
	testing.expect(t, string(buffer.buf_slice(&body)) == "hello world")
}

@(test)
test_chunked_decode_partial :: proc(t: ^testing.T) {
	body: buffer.Buf
	buffer.buf_init(&body, context.allocator)
	defer buffer.buf_destroy(&body)

	input := "5\r\nhel"
	status, _ := chunked_decode(transmute([]byte)input, &body)
	testing.expect(t, status == 0)
	testing.expect(t, buffer.buf_len(&body) == 0)
}

@(test)
test_chunked_decode_malformed :: proc(t: ^testing.T) {
	body: buffer.Buf
	buffer.buf_init(&body, context.allocator)
	defer buffer.buf_destroy(&body)

	status, _ := chunked_decode(transmute([]byte)string("zz\r\nnope\r\n"), &body)
	testing.expect(t, status == -1)
}
