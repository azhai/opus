package web

import "core:time"

/*
Cookie is an RFC 6265 cookie.

`expires` doubles as the "is set" flag: the zero time omits the Expires
attribute. `same_site` defaults to `Unset`, which omits the attribute.
*/
Cookie :: struct {
	name:        string,
	value:       string,
	path:        string,    // Path=...      (empty -> omitted)
	domain:      string,    // Domain=...    (empty -> omitted)
	expires:     time.Time, // Expires=...   (zero  -> omitted)
	max_age_secs: int,      // Max-Age=...   (0     -> omitted)
	secure:      bool,      // Secure
	http_only:   bool,      // HttpOnly
	same_site:   Same_Site, // SameSite=...  (Unset -> omitted)
}

Same_Site :: enum {
	Unset,
	None,
	Lax,
	Strict,
}

same_site_string :: proc(s: Same_Site) -> string {
	switch s {
	case .None:
		return "None"
	case .Lax:
		return "Lax"
	case .Strict:
		return "Strict"
	case .Unset:
		return ""
	}
	return ""
}

// cookie_string serializes a cookie into a Set-Cookie attribute value,
// e.g. "session=abc; Path=/; HttpOnly; SameSite=Lax". An empty name
// serializes to the empty string.
cookie_string :: proc(c: Cookie, allocator := context.allocator) -> string {
	if len(c.name) == 0 {
		return ""
	}
	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)
	buf_append_string(&b, c.name)
	buf_append_byte(&b, '=')
	buf_append_string(&b, c.value)
	if len(c.path) > 0 {
		buf_append_string(&b, "; Path=")
		buf_append_string(&b, c.path)
	}
	if len(c.domain) > 0 {
		buf_append_string(&b, "; Domain=")
		buf_append_string(&b, c.domain)
	}
	if c.expires != (time.Time{}) {
		buf_append_string(&b, "; Expires=")
		buf_append_string(&b, http_date(c.expires, allocator))
	}
	if c.max_age_secs != 0 {
		buf_append_string(&b, "; Max-Age=")
		buf_append_string(&b, int_to_string(i64(c.max_age_secs), allocator))
	}
	if c.secure {
		buf_append_string(&b, "; Secure")
	}
	if c.http_only {
		buf_append_string(&b, "; HttpOnly")
	}
	if s := same_site_string(c.same_site); len(s) > 0 {
		buf_append_string(&b, "; SameSite=")
		buf_append_string(&b, s)
	}
	return clone_string(string(buf_slice(&b)), allocator)
}

// response_set_cookie appends a Set-Cookie header. Unlike
// response_set_header this never replaces: each cookie gets its own
// header line, as Set-Cookie does not fold (RFC 6265 section 3.4).
response_set_cookie :: proc(w: ^Response, c: Cookie) {
	alloc := context.allocator
	if w.conn != nil {
		alloc = conn_scratch(w.conn)
	}
	s := cookie_string(c, alloc)
	if len(s) == 0 {
		return
	}
	response_add_header(w, "Set-Cookie", s)
}

// request_cookie returns the value of the named cookie from the request's
// Cookie header(s). Allocation-free: the value is a view into the head
// buffer. Surrounding double quotes are stripped.
request_cookie :: proc(r: ^Request, name: string) -> (string, bool) {
	for h in r.headers {
		if !eq_ignore_case(h.key, "Cookie") {
			continue
		}
		v := h.value
		for len(v) > 0 {
			end := string_index_byte(v, ';')
			pair := v
			if end >= 0 {
				pair = v[:end]
				v = v[end + 1:]
			} else {
				v = ""
			}
			pair = trim_ows(pair)
			eq := string_index_byte(pair, '=')
			if eq < 0 {
				continue
			}
			if trim_ows(pair[:eq]) == name {
				return cookie_unquote(trim_ows(pair[eq + 1:])), true
			}
		}
	}
	return "", false
}

// request_cookies parses every Cookie header into name/value pairs.
// Storage lives on the connection scratch arena (freed with the request).
request_cookies :: proc(r: ^Request) -> [dynamic]Cookie {
	alloc := context.allocator
	if r.conn != nil {
		alloc = conn_scratch(r.conn)
	}
	out := make([dynamic]Cookie, alloc)
	for h in r.headers {
		if !eq_ignore_case(h.key, "Cookie") {
			continue
		}
		v := h.value
		for len(v) > 0 {
			end := string_index_byte(v, ';')
			pair := v
			if end >= 0 {
				pair = v[:end]
				v = v[end + 1:]
			} else {
				v = ""
			}
			pair = trim_ows(pair)
			eq := string_index_byte(pair, '=')
			if eq < 0 {
				continue
			}
			name := trim_ows(pair[:eq])
			value := cookie_unquote(trim_ows(pair[eq + 1:]))
			append(&out, Cookie{name = name, value = value})
		}
	}
	return out
}

cookie_unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}
