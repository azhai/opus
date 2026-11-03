package http

// The SSE wire format, byte for byte. A client either parses these frames or
// silently drops them, so "close enough" is not a thing here.

import "core:testing"
import "../buffer"

@(test)
test_sse_event_payload :: proc(t: ^testing.T) {
	Case :: struct {
		data, event, id, want: string,
	}
	cases := []Case {
		// a bare event is one data line plus the blank line that ends it
		{"hi", "", "", "data: hi\n\n"},
		{"hi", "tick", "", "event: tick\ndata: hi\n\n"},
		{"hi", "", "7", "id: 7\ndata: hi\n\n"},
		// event comes before id comes before data
		{"hi", "tick", "7", "event: tick\nid: 7\ndata: hi\n\n"},
		// every line of a multi-line payload is its own data: line
		{"a\nb", "", "", "data: a\ndata: b\n\n"},
		// a trailing newline yields an empty last line rather than vanishing
		{"a\n", "", "", "data: a\ndata: \n\n"},
		{"", "", "", "data: \n\n"},
	}
	for cse in cases {
		b: buffer.Buf
		buffer.buf_init(&b, context.allocator)
		defer buffer.buf_destroy(&b)

		sse_event_payload(&b, cse.data, cse.event, cse.id)
		got := string(buffer.buf_slice(&b))
		testing.expectf(t, got == cse.want, "data %q event %q id %q: expected %q, got %q", cse.data, cse.event, cse.id, cse.want, got)
	}
}

@(test)
test_sse_comment_and_retry :: proc(t: ^testing.T) {
	b: buffer.Buf
	buffer.buf_init(&b, context.allocator)
	defer buffer.buf_destroy(&b)

	sse_comment_payload(&b, "keep-alive")
	testing.expect(t, string(buffer.buf_slice(&b)) == ": keep-alive\n\n")

	buffer.buf_reset(&b)
	sse_retry_payload(&b, 3000)
	testing.expect(t, string(buffer.buf_slice(&b)) == "retry: 3000\n\n")

	// the number is formatted in place: no temporary string to leak
	buffer.buf_reset(&b)
	sse_retry_payload(&b, 0)
	testing.expect(t, string(buffer.buf_slice(&b)) == "retry: 0\n\n")
}

@(test)
test_chunked_frame :: proc(t: ^testing.T) {
	b: buffer.Buf
	buffer.buf_init(&b, context.allocator)
	defer buffer.buf_destroy(&b)

	chunked_frame(&b, transmute([]byte)string("hello"))
	testing.expect(t, string(buffer.buf_slice(&b)) == "5\r\nhello\r\n")

	// two frames back to back, then the terminator: what a chunked body looks
	// like on the wire
	chunked_frame(&b, transmute([]byte)string("a"))
	buffer.buf_append_string(&b, CHUNKED_TERMINATOR)
	testing.expect(t, string(buffer.buf_slice(&b)) == "5\r\nhello\r\n1\r\na\r\n0\r\n\r\n")

	// an empty frame is still a frame (a zero-length chunk is legal and is not
	// the terminator until the trailer section follows)
	buffer.buf_reset(&b)
	chunked_frame(&b, nil)
	testing.expect(t, string(buffer.buf_slice(&b)) == "0\r\n\r\n")
}
