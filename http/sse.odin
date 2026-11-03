package http

import "../buffer"

/*
The wire format of `text/event-stream` (the Server-Sent Events chapter of the
WHATWG HTML standard), as pure formatting.

Everything here appends to a buffer and returns; nothing owns a socket. That
is the point of the split: `web.sse_*` writes these payloads to a hijacked
connection for a stream one handler generates, `web.Hub` queues them for
subscribers that are fed from elsewhere, and both must produce byte-identical
frames or a client would see two different protocols.
*/

// SSE_MEDIA_TYPE is the media type a stream must be served as. It is also what
// makes a proxy stop buffering, in combination with the no-transform header.
SSE_MEDIA_TYPE :: "text/event-stream"

// sse_event_payload appends one event: an optional `event:` name, an optional
// `id:` cursor, then one `data:` line per line of `data`, then the blank line
// that ends the event.
//
// Splitting multi-line data is required, not cosmetic: a raw '\n' inside the
// payload would end the event early.
sse_event_payload :: proc(p: ^buffer.Buf, data: string, event := "", id := "") {
	if len(event) > 0 {
		buffer.buf_append_string(p, "event: ")
		buffer.buf_append_string(p, event)
		buffer.buf_append_byte(p, '\n')
	}
	if len(id) > 0 {
		buffer.buf_append_string(p, "id: ")
		buffer.buf_append_string(p, id)
		buffer.buf_append_byte(p, '\n')
	}
	rest := data
	for {
		nl := string_index_byte(rest, '\n')
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		buffer.buf_append_string(p, "data: ")
		buffer.buf_append_string(p, line)
		buffer.buf_append_byte(p, '\n')
		if nl < 0 {
			break
		}
	}
	buffer.buf_append_byte(p, '\n')
}

// sse_comment_payload appends a comment. Clients ignore it; it is the keep-alive
// that stops an idle proxy from dropping a quiet stream.
sse_comment_payload :: proc(p: ^buffer.Buf, text: string) {
	buffer.buf_append_string(p, ": ")
	buffer.buf_append_string(p, text)
	buffer.buf_append_string(p, "\n\n")
}

// sse_retry_payload tells the client how long to wait before reconnecting,
// which overrides the browser's own backoff for this stream.
sse_retry_payload :: proc(p: ^buffer.Buf, milliseconds: int) {
	buffer.buf_append_string(p, "retry: ")
	// formatted in place: int_to_string would hand back a string nobody frees,
	// once per keep-alive annotation
	num: [24]byte
	buffer.buf_append(p, num[:buffer.i64_to_buf(num[:], i64(milliseconds))])
	buffer.buf_append_string(p, "\n\n")
}
