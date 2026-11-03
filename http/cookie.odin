package http

import "core:time"
import "../buffer"

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
	b: buffer.Buf
	buffer.buf_init(&b, allocator)
	defer buffer.buf_destroy(&b)
	buffer.buf_append_string(&b, c.name)
	buffer.buf_append_byte(&b, '=')
	buffer.buf_append_string(&b, c.value)
	if len(c.path) > 0 {
		buffer.buf_append_string(&b, "; Path=")
		buffer.buf_append_string(&b, c.path)
	}
	if len(c.domain) > 0 {
		buffer.buf_append_string(&b, "; Domain=")
		buffer.buf_append_string(&b, c.domain)
	}
	if c.expires != (time.Time{}) {
		buffer.buf_append_string(&b, "; Expires=")
		buffer.buf_append_string(&b, http_date(c.expires, allocator))
	}
	if c.max_age_secs != 0 {
		buffer.buf_append_string(&b, "; Max-Age=")
		// formatted in place: int_to_string would hand back a string that
		// nothing frees, once per Set-Cookie
		num: [24]byte
		buffer.buf_append(&b, num[:buffer.i64_to_buf(num[:], i64(c.max_age_secs))])
	}
	if c.secure {
		buffer.buf_append_string(&b, "; Secure")
	}
	if c.http_only {
		buffer.buf_append_string(&b, "; HttpOnly")
	}
	if s := same_site_string(c.same_site); len(s) > 0 {
		buffer.buf_append_string(&b, "; SameSite=")
		buffer.buf_append_string(&b, s)
	}
	return buffer.clone_string(string(buffer.buf_slice(&b)), allocator)
}





cookie_unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}
