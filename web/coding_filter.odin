package web

import "../buffer"
import "../codecs"
import "../http"

// MIN_CODING_SIZE is the default body size below which content coding is
// skipped: the headers cost more than the savings.
MIN_CODING_SIZE :: 512

/*
Coding_Filter applies the content coding the client asked for - the one place
in the library where a coding decision meets a live connection.

The decision itself is not made here. `http.negotiate_coding` owns the
`Accept-Encoding` rules (q values, `*`, explicit refusal) and
`http.content_type_compressible` owns "is this media type worth coding";
`coding` owns the encoder. This file only supplies what those cannot see: the
`Conn`, its scratch allocator, and whether the body is a stream, a file or
already coded.

Registration order matters: it must run before the chunked filter so the body
is coded first and framed second (content codings apply before transfer
codings).

	srv.coding_filter.min_size = 1024   // optional tuning

The filter is enabled by default; set `allow_gzip = false, allow_deflate = false`
to switch it off. Per-response control comes from `Response.coding` and
`Response.coding_min_size`, which is what the route-level middleware in
`middlewares/coding` writes.
*/
Coding_Filter :: struct {
	using filter: Filter,
	allow_gzip:    bool,
	allow_deflate: bool,
	min_size:      int,
	// scratch is the match-finder table, reused across responses (see
	// codecs.Deflate_State). Allocated on the first compressed response.
	scratch: ^codecs.Deflate_State,
}

filter_coding_init :: proc(f: ^Coding_Filter) {
	f.apply = coding_apply
	f.allow_gzip = true
	f.allow_deflate = true
	f.min_size = MIN_CODING_SIZE
}

coding_apply :: proc(f: ^Filter, c: ^Conn) {
	cf := cast(^Coding_Filter) f
	w := &c.res
	if !cf.allow_gzip && !cf.allow_deflate {
		return
	}
	if file_pending(w) {
		// a streamed file body keeps its zero-copy path
		return
	}
	if c.req.method == .Head {
		return // no body is ever sent
	}
	if w.status == .No_Content || w.status == .Not_Modified {
		return
	}
	// .Deny is the route-level "never code this" (streams, pre-coded assets)
	if w.coding == .Deny {
		return
	}
	force := w.coding == .Force
	min_size := cf.min_size
	if w.coding_min_size > 0 {
		min_size = w.coding_min_size
	}
	if !force && len(w.body.data) < min_size {
		return
	}
	if _, ok := response_header(w, "Content-Encoding"); ok {
		return // already coded: never double-code
	}
	ct, has_ct := response_header(w, "Content-Type")
	if !force && (!has_ct || !http.content_type_compressible(ct)) {
		return
	}
	ae, ok := request_header(&c.req, "Accept-Encoding")
	if !ok {
		return
	}

	// The body of this response now depends on Accept-Encoding, so a shared
	// cache has to key on it - whether or not this particular request ends
	// up coded. Adding it before the decision is what keeps an identity
	// response from being served to a client that would have got gzip.
	if !response_has_vary(w, "Accept-Encoding") {
		response_add_header(w, "Vary", "Accept-Encoding")
	}

	enc := http.negotiate_coding(ae, cf.allow_gzip, cf.allow_deflate)
	if enc == .Identity {
		return
	}

	raw := buffer.buf_slice(&w.body)
	if cf.scratch == nil {
		cf.scratch = codecs.deflate_state_create()
	}
	scratch := conn_scratch(c)
	compressed: []byte
	switch enc {
	case .Gzip:
		compressed = codecs.gzip_compress(raw, scratch, cf.scratch)
	case .Deflate:
		compressed = codecs.deflate_compress(raw, scratch, cf.scratch)
	case .Identity:
		return
	}
	if len(compressed) >= len(raw) {
		return // no gain: identity is the better answer
	}

	buffer.buf_reset(&w.body)
	buffer.buf_append(&w.body, compressed)
	// the body changed length: any handler-set Content-Length is stale
	response_remove_header(w, "Content-Length")
	response_set_header(w, "Content-Encoding", http.coding_name(enc))
}
