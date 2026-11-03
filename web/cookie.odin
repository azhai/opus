package web

// Cookie accessors on the request and response: the parsing and serialization
// rules themselves (Cookie, cookie_string) live in ../http.

import "core:mem"
import "../buffer"
import "../http"

// response_set_cookie appends a Set-Cookie header. Unlike
// response_set_header this never replaces: each cookie gets its own
// header line, as Set-Cookie does not fold (RFC 6265 section 3.4).
response_set_cookie :: proc(w: ^Response, c: http.Cookie) {
	s := http.cookie_string(c, response_allocator(w))
	if len(s) == 0 {
		return
	}
	response_add_header(w, "Set-Cookie", s)
}

// response_clear_cookie expires a cookie: empty value, Max-Age=0 and an
// Expires in the past, which is the only combination every browser honours
// (Echo's c.ClearCookie). `path` must match the cookie being removed.
response_clear_cookie :: proc(w: ^Response, name: string, path := "/") {
	if len(name) == 0 {
		return
	}
	alloc := response_allocator(w)
	b: buffer.Buf
	buffer.buf_init(&b, alloc)
	defer buffer.buf_destroy(&b)
	buffer.buf_append_string(&b, name)
	buffer.buf_append_string(&b, "=; Path=")
	buffer.buf_append_string(&b, path)
	buffer.buf_append_string(&b, "; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT")
	response_add_header(w, "Set-Cookie", buffer.clone_string(string(buffer.buf_slice(&b)), alloc))
}

// request_cookie returns the value of the named cookie from the request's
// Cookie header(s). Allocation-free: the value is a view into the head
// buffer. Surrounding double quotes are stripped.
request_cookie :: proc(r: ^Request, name: string) -> (string, bool) {
	for h in r.headers {
		if !http.eq_ignore_case(h.key, "Cookie") {
			continue
		}
		v := h.value
		for len(v) > 0 {
			end := http.string_index_byte(v, ';')
			pair := v
			if end >= 0 {
				pair = v[:end]
				v = v[end + 1:]
			} else {
				v = ""
			}
			pair = http.trim_ows(pair)
			eq := http.string_index_byte(pair, '=')
			if eq < 0 {
				continue
			}
			if http.trim_ows(pair[:eq]) == name {
				return http.cookie_unquote(http.trim_ows(pair[eq + 1:])), true
			}
		}
	}
	return "", false
}

// request_cookies parses every Cookie header into name/value pairs.
// Storage lives on the connection scratch arena (freed with the request).
request_cookies :: proc(r: ^Request) -> [dynamic]http.Cookie {
	alloc := context.allocator
	if r.conn != nil {
		alloc = conn_scratch(r.conn)
	}
	out := make([dynamic]http.Cookie, alloc)
	for h in r.headers {
		if !http.eq_ignore_case(h.key, "Cookie") {
			continue
		}
		v := h.value
		for len(v) > 0 {
			end := http.string_index_byte(v, ';')
			pair := v
			if end >= 0 {
				pair = v[:end]
				v = v[end + 1:]
			} else {
				v = ""
			}
			pair = http.trim_ows(pair)
			eq := http.string_index_byte(pair, '=')
			if eq < 0 {
				continue
			}
			name := http.trim_ows(pair[:eq])
			value := http.cookie_unquote(http.trim_ows(pair[eq + 1:]))
			append(&out, http.Cookie{name = name, value = value})
		}
	}
	return out
}
