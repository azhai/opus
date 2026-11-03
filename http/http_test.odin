package http

// Tests for the protocol layer: URI decoding and path cleaning, the method
// table, and the IMF-fixdate formatter.

import "core:mem"
import "core:testing"
import "core:time"

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
