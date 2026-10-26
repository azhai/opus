package middlewares

import ".."
import "core:mem"


/*
`middleware_range` gives ordinary handlers the two conditional-response
behaviours they almost never implement and clients always ask for:

  - Range: a single byte range of a buffered body becomes a 206 with
    `Content-Range`, an unsatisfiable one becomes a 416 carrying the full
    length, several ranges are ignored (RFC 7233 lets a server do that) and
    the client gets the whole representation.
  - ETag: with `etag = true` the body gets a content hash tag, and
    `If-None-Match` short-circuits to a bodyless 304.

The middleware runs *after* the handler, on whatever it produced, so a
handler needs no range code at all:

	router_use(&router, middleware_range, &Range_Config{etag = true})
	router_get(&router, "/report.csv", func(req: ^Request, res: ^Response) {
		response_write_string(res, csv)
	})

File responses are left alone: the static handler and `response_download`
already answer ranges zero-copy with a `sendfile` offset, and re-slicing an
in-memory buffer would defeat that. Chunked responses are left alone too,
since their length is not known when the middleware looks.

The ETag here is a content hash (FNV-1a 64 of the bytes), not a
modification time: correct for a generated body, cheap enough to compute on
every response, and stable across restarts. It is strong, so a byte-range
request against it is safe.

One interaction worth knowing: the tag is computed before the compress
filter runs, so a gzip and an identity response share it. That is fine for
caches (the compress filter adds `Vary: Accept-Encoding`, so the variants
are keyed separately) but a strictly per-coding tag would need the filter
chain to re-tag after coding, which this library does not do.
*/

// Range_Config configures middleware_range. A nil config serves ranges
// without adding ETags.
Range_Config :: struct {
	etag: bool,
}

middleware_range :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	web.router_next(r, idx + 1, final, req, res)

	cfg := cast(^Range_Config) m.ud
	want_etag := cfg != nil && cfg.etag

	if res.status != .OK || res.file_open || res.chunked {
		return // nothing buffered to slice, or someone else already framed it
	}
	if req.method != .Get && req.method != .Head {
		return
	}
	if _, already := web.response_header(res, "Content-Range"); already {
		return // a handler answered the range itself
	}
	if len(res.body.data) == 0 {
		return
	}

	rng, has_range := web.request_header(req, "Range")
	alloc := web.response_allocator(res)

	// ---- ETag / If-None-Match ----
	etag := ""
	if want_etag {
		if existing, ok := web.response_header(res, "ETag"); ok {
			etag = existing
		} else {
			etag = content_etag(web.buf_slice(&res.body), alloc)
			web.response_set_header(res, "ETag", etag)
		}
		if inm, ok := web.request_header(req, "If-None-Match"); ok && etag_list_matches(inm, etag) {
			// 304 must not carry a body or a Content-Type (RFC 7232 4.1);
			// the validators stay so the next request can revalidate.
			web.response_remove_header(res, "Content-Length")
			web.response_remove_header(res, "Content-Type")
			web.buf_reset(&res.body)
			res.status = .Not_Modified
			return
		}
	}

	if !has_range {
		if want_etag {
			web.response_set_header(res, "Accept-Ranges", "bytes")
		}
		return
	}

	// If-Range: honour the range only when the client's validator still
	// describes this representation (entity tag form; this server has no
	// date validator).
	if ir, ok := web.request_header(req, "If-Range"); ok {
		if len(etag) == 0 || !etag_matches(ir, etag) {
			web.response_set_header(res, "Accept-Ranges", "bytes")
			return // stale validator: send the full representation (200)
		}
	}

	size := i64(len(res.body.data))
	ranges, count, decision := web.parse_byte_ranges(rng, size)
	switch decision {
	case .Single:
		r := ranges[0]
		slice := res.body.data[int(r.start):int(r.start + r.length)]
		// Copy before resetting: the slice points into the buffer being
		// replaced, and `reset` may reallocate on the next append.
		copied := web.clone_bytes(slice, alloc)
		web.buf_reset(&res.body)
		web.buf_append(&res.body, copied)
		web.response_remove_header(res, "Content-Length")
		web.response_set_header(res, "Accept-Ranges", "bytes")
		web.response_set_header(res, "Content-Range", web.content_range_value(r.start, r.start + r.length - 1, size, alloc))
		res.status = .Partial_Content
	case .Unsatisfiable:
		web.buf_reset(&res.body)
		web.response_remove_header(res, "Content-Length")
		web.response_set_header(res, "Accept-Ranges", "bytes")
		web.response_set_header(res, "Content-Range", web.unsatisfiable_content_range(size, alloc))
		web.response_error(res, .Range_Not_Satisfiable, "")
	case .Multi, .Ignore:
		// The representation is small enough to send whole: RFC 7233 3.1
		// allows a server to ignore Range. Answer 200 with the full body.
		web.response_set_header(res, "Accept-Ranges", "bytes")
	}
}

// content_etag renders a strong entity tag from the body: FNV-1a 64, as
// 16 lowercase hex digits in quotes (the quoted form every validator uses).
content_etag :: proc(body: []byte, allocator: mem.Allocator) -> string {
	h: u64 = 0xcbf29ce484222325
	for i := 0; i < len(body); i += 1 {
		h = (h ~ u64(body[i])) * 0x100000001b3
	}
	out := make([]byte, 18, allocator)
	out[0] = '"'
	out[17] = '"'
	digits := "0123456789abcdef"
	for i := 16; i >= 1; i -= 1 {
		out[i] = digits[h & 0xf]
		h >>= 4
	}
	return string(out)
}

// etag_list_matches reports whether an If-None-Match header list matches
// `etag`: "*" matches anything, and the weak prefix "W/" is ignored because
// If-None-Match uses weak comparison.
etag_list_matches :: proc(header, etag: string) -> bool {
	rest := header
	for len(rest) > 0 {
		comma := web.string_index_byte(rest, ',')
		item := rest
		if comma >= 0 {
			item = rest[:comma]
			rest = rest[comma + 1:]
		} else {
			rest = ""
		}
		item = web.trim_ows(item)
		if item == "*" {
			return true
		}
		if etag_matches(item, etag) {
			return true
		}
	}
	return false
}

// etag_matches compares one entity tag with a configured one, ignoring a
// leading weak marker on either side.
etag_matches :: proc(candidate, etag: string) -> bool {
	a := candidate
	if len(a) > 2 && a[0] == 'W' && a[1] == '/' {
		a = a[2:]
	}
	b := etag
	if len(b) > 2 && b[0] == 'W' && b[1] == '/' {
		b = b[2:]
	}
	return len(a) > 0 && a == b
}
