package web

// Tests for the small helpers: URI encode/decode, path cleaning,
// MIME lookup, status text, request query/form accessors and the
// response shortcuts.

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
// URI / request / response helpers
// ---------------------------------------------------------------------------

@(test)
test_url_decode_encode :: proc(t: ^testing.T) {
	// decoding allocates for escaped input; keep it in an arena like a request
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	testing.expect_value(t, url_decode("a+b%20c%2Fd"), "a b c/d")
	testing.expect_value(t, url_decode("100%25"), "100%")
	testing.expect_value(t, url_decode("bad%zz"), "bad%zz") // malformed escape stays literal
	testing.expect_value(t, url_decode("trunc%2"), "trunc%2")
	testing.expect_value(t, url_encode("a b/c?d=e~"), "a+b%2Fc%3Fd%3De~")
}

@(test)
test_url_path_clean :: proc(t: ^testing.T) {
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	Case :: struct {
		raw:   string,
		want:  string,
		state: Path_State,
	}
	cases := []Case{
		{"/", "/", .Ok},
		{"/a//b/./c", "/a/b/c", .Ok},
		{"/a/b/?q=1#f", "/a/b", .Ok},
		{"/a%2Fb", "/a/b", .Ok},
		{"/a/%2e%2e/b", "", .Escaping},
		{"/../etc/passwd", "", .Escaping},
		{"/a%zz", "", .Bad},
		{"/a%00b", "", .Bad},
		{"no-slash", "", .Bad},
	}
	for c in cases {
		got, state := url_path_clean(c.raw)
		testing.expectf(t, state == c.state, "%s: state %v, want %v", c.raw, state, c.state)
		if state == .Ok {
			testing.expect_value(t, got, c.want)
		}
	}
}

@(test)
test_request_query_and_form :: proc(t: ^testing.T) {
	backing: [8192]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	r := Request{query = "name=odin+lang&empty=&flag&x=%41&name=second"}
	v, ok := request_query(&r, "name")
	testing.expect(t, ok)
	testing.expect_value(t, v, "odin lang")

	x, okx := request_query(&r, "x")
	testing.expect(t, okx)
	testing.expect_value(t, x, "A")

	_, ok_missing := request_query(&r, "missing")
	testing.expect(t, !ok_missing)

	all := request_query_all(&r, "name")
	testing.expect_value(t, len(all), 2)
	if len(all) == 2 {
		testing.expect_value(t, all[1], "second")
	}

	r.body = tb("username=root&password=a+b&note=%2Ftmp")
	form := request_form(&r)
	testing.expect_value(t, len(form), 3)
	pw, _ := request_form_value(&r, "password")
	testing.expect_value(t, pw, "a b")
	note, _ := param_get(form, "note")
	testing.expect_value(t, note, "/tmp")

	flag_req := Request{body = tb("flag")}
	flag, ok_flag := request_form_value(&flag_req, "flag")
	testing.expect(t, ok_flag)
	testing.expect_value(t, flag, "")
}

@(test)
test_response_helpers :: proc(t: ^testing.T) {
	w: Response
	response_init(&w, nil, context.allocator)
	defer {
		delete(w.headers)
		buf_destroy(&w.body)
	}

	response_text(&w, .Created, "hi")
	testing.expect_value(t, w.status, Status.Created)
	ct, ok := response_header(&w, "content-type")
	testing.expect(t, ok)
	testing.expect_value(t, ct, "text/plain; charset=utf-8")
	testing.expect_value(t, string(buf_slice(&w.body)), "hi")

	response_html(&w, .OK, "<b>x</b>")
	ct2, _ := response_header(&w, "Content-Type")
	testing.expect_value(t, ct2, "text/html; charset=utf-8")
	testing.expect_value(t, string(buf_slice(&w.body)), "hi<b>x</b>")

	response_no_content(&w)
	testing.expect_value(t, w.status, Status.No_Content)
	testing.expect_value(t, buf_len(&w.body), 0)
}

@(test)
test_html_escape :: proc(t: ^testing.T) {
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	testing.expect_value(t, html_escape("plain text"), "plain text")
	testing.expect_value(t, html_escape(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
}

@(test)
test_method_round_trip :: proc(t: ^testing.T) {
	cases := []struct {
		text:   string,
		method: Method,
	} {
		{"GET", .Get},
		{"HEAD", .Head},
		{"POST", .Post},
		{"PUT", .Put},
		{"DELETE", .Delete},
		{"OPTIONS", .Options},
		{"PATCH", .Patch},
		{"TRACE", .Trace},
		{"CONNECT", .Connect},
	}
	for c in cases {
		testing.expect_value(t, method_from_string(c.text), c.method)
		testing.expect_value(t, method_string(c.method), c.text)
	}

	// unknown verbs and lowercase input are not coerced
	testing.expect_value(t, method_from_string("PROPFIND"), Method.Unknown)
	testing.expect_value(t, method_from_string("get"), Method.Unknown)
	testing.expect_value(t, method_string(.Unknown), "UNKNOWN")
	// .All exists only in the route table; it stringifies as a label
	testing.expect_value(t, method_string(.All), "ALL")
}

@(test)
test_http_date :: proc(t: ^testing.T) {
	stamp, ok := time.datetime_to_time(1994, 11, 6, 8, 49, 37, 0)
	testing.expect(t, ok)
	first := http_date(stamp, context.allocator)
	defer delete(first, context.allocator)
	testing.expect_value(t, first, "Sun, 06 Nov 1994 08:49:37 GMT")

	// a second date pins zero padding on day and time, and the month table
	stamp2, ok2 := time.datetime_to_time(2026, 1, 5, 0, 0, 0, 0)
	testing.expect(t, ok2)
	second := http_date(stamp2, context.allocator)
	defer delete(second, context.allocator)
	testing.expect_value(t, second, "Mon, 05 Jan 2026 00:00:00 GMT")
}

/*
test_server_date_cache: the Date header is formatted once per second per
server and shared by every response in that second. Two things have to hold -
the cached text must equal what the uncached formatter produces, and it must
roll over when the second changes.
*/
@(test)
test_server_date_cache :: proc(t: ^testing.T) {
	srv: Server
	testing.expect(t, server_init(&srv, "127.0.0.1:0"))
	defer server_destroy(&srv)

	base := time.unix(1_700_000_000, 0)
	first := server_date(&srv, base)
	testing.expect_value(t, len(first), HTTP_DATE_LEN)
	testing.expect_value(t, first, http_date(base, context.temp_allocator))

	// a later instant inside the same second is the same string; the value is
	// copied because `first` is a view into the cache the next call rewrites
	snapshot := strings.clone(first, context.temp_allocator)
	same := server_date(&srv, time.time_add(base, 900 * time.Millisecond))
	testing.expect_value(t, same, snapshot)

	// the next second is a different string
	next := server_date(&srv, time.time_add(base, 1000 * time.Millisecond))
	testing.expectf(t, next != snapshot, "the date did not roll over: %q", next)
	testing.expect_value(t, next, http_date(time.time_add(base, time.Second), context.temp_allocator))

	// an invalid time yields nothing rather than a garbage header
	testing.expect_value(t, http_date_buf(time.Time{}, make([]byte, 8, context.temp_allocator)), 0)
}
