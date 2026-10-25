package web

// Tests for cookies: Set-Cookie serialization, request parsing and
// the wire form.

import "base:intrinsics"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
// ---------------------------------------------------------------------------
// cookies
// ---------------------------------------------------------------------------

@(test)
test_cookie_serialize :: proc(t: ^testing.T) {
	// serialize on a stack arena: cookie_string allocates per attribute
	arena_buf: [8 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	// minimal: name=value only
	minimal := cookie_string(Cookie{name = "a", value = "b"}, alloc)
	testing.expect(t, minimal == "a=b")

	// full attribute set
	full := cookie_string(Cookie{
		name         = "session",
		value        = "abc",
		path         = "/app",
		domain       = "example.com",
		expires      = time.unix(784111777, 0), // 1994-11-06 08:49:37 UTC
		max_age_secs = 3600,
		secure       = true,
		http_only    = true,
		same_site    = .Lax,
	}, alloc)
	testing.expect(t, strings.has_prefix(full, "session=abc; "))
	testing.expect(t, strings.contains(full, "Path=/app"))
	testing.expect(t, strings.contains(full, "Domain=example.com"))
	testing.expect(t, strings.contains(full, "Expires=Sun, 06 Nov 1994 08:49:37 GMT"))
	testing.expect(t, strings.contains(full, "Max-Age=3600"))
	testing.expect(t, strings.contains(full, "Secure"))
	testing.expect(t, strings.contains(full, "HttpOnly"))
	testing.expect(t, strings.contains(full, "SameSite=Lax"))
	testing.expect(t, strings.has_suffix(full, "SameSite=Lax"))

	// zero expires / unset same-site are omitted
	bare := cookie_string(Cookie{name = "x", value = "y"}, alloc)
	testing.expect(t, !strings.contains(bare, "Expires"))
	testing.expect(t, !strings.contains(bare, "SameSite"))
	testing.expect(t, !strings.contains(bare, "Max-Age"))

	// empty name serializes to nothing
	testing.expect(t, cookie_string(Cookie{value = "v"}, alloc) == "")

	// strict / none variants
	strict := cookie_string(Cookie{name = "a", value = "b", same_site = .Strict}, alloc)
	testing.expect(t, strings.has_suffix(strict, "SameSite=Strict"))
	none := cookie_string(Cookie{name = "a", value = "b", same_site = .None}, alloc)
	testing.expect(t, strings.has_suffix(none, "SameSite=None"))
}

@(test)
test_cookie_request_parse :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	req := &c.req
	req.method = .Get
	req.conn = c

	head := "GET / HTTP/1.1\r\nHost: x\r\nCookie: token=xyz; theme=\"dark\"; flag\r\n\r\n"
	perr := parse_request(req, head, conn_scratch(c))
	testing.expect(t, perr == .None)

	v, ok := request_cookie(req, "token")
	testing.expect(t, ok)
	testing.expect(t, v == "xyz")

	// quoted values are unquoted
	theme, ok2 := request_cookie(req, "theme")
	testing.expect(t, ok2)
	testing.expect(t, theme == "dark")

	// valueless pair: no match, no crash
	_, ok3 := request_cookie(req, "flag")
	testing.expect(t, !ok3)

	// unknown name
	_, ok4 := request_cookie(req, "nope")
	testing.expect(t, !ok4)

	// no Cookie header at all
	req.headers = nil
	_, ok5 := request_cookie(req, "token")
	testing.expect(t, !ok5)

	// multiple Cookie headers are scanned
	req.headers = nil
	head2 := "GET / HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n"
	testing.expect(t, parse_request(req, head2, conn_scratch(c)) == .None)
	av, _ := request_cookie(req, "a")
	bv, _ := request_cookie(req, "b")
	testing.expect(t, av == "1")
	testing.expect(t, bv == "2")

	// request_cookies parses all pairs
	cookies := request_cookies(req)
	testing.expect(t, len(cookies) == 2)
	testing.expect(t, cookies[0].name == "a" && cookies[0].value == "1")
	testing.expect(t, cookies[1].name == "b" && cookies[1].value == "2")
}

@(test)
test_cookie_response_build :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	w := &c.res
	response_set_cookie(w, Cookie{name = "session", value = "abc123", path = "/", http_only = true, same_site = .Lax})
	response_set_cookie(w, Cookie{name = "theme", value = "dark", max_age_secs = 3600})

	out: Buf
	buf_init(&out, context.allocator)
	defer buf_destroy(&out)
	response_build(w, &out, conn_scratch(c))

	resp := string(buf_slice(&out))
	// Set-Cookie does not fold: one header line per cookie
	testing.expect(t, strings.contains(resp, "Set-Cookie: session=abc123; Path=/; HttpOnly; SameSite=Lax\r\n"))
	testing.expect(t, strings.contains(resp, "Set-Cookie: theme=dark; Max-Age=3600\r\n"))
}
