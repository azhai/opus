package web

import "../buffer"
import "../http"

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

/*
Chunked_Filter frames an in-memory response body as a single HTTP/1.1
chunk followed by the terminating chunk. It is a no-op unless the response
opted into chunked encoding and has no file body.

The decoding half of the transfer coding is `http.chunked_decode` (http/
chunked.odin): the request parser uses it, this filter never sees it.
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
	body := buffer.buf_slice(&w.body)
	tmp: buffer.Buf
	buffer.buf_init(&tmp, conn_scratch(c))
	buffer.write_hex(&tmp, len(body))
	buffer.buf_append_string(&tmp, "\r\n")
	buffer.buf_append(&tmp, body)
	buffer.buf_append_string(&tmp, "\r\n0\r\n\r\n")
	w.body = tmp
}
