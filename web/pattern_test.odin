package web

// Tests for the Lua-pattern route subset.

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
// pattern routing
// ---------------------------------------------------------------------------

noop_handler :: proc(req: ^Request, res: ^Response) {}

@(test)
test_pattern_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern: string,
		path:    string,
		match:   bool,
		caps:    []string,
	}
	cases := []Case{
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/42", true, {"john", "42"}},
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/4x", false, nil},
		{"/x/(%d+)", "/x/42", true, {"42"}},
		{"/x/(%d+)", "/x/abc", false, nil},
		{"/static/(.-)%.html", "/static/a/b.html", true, {"a/b"}},
		{"/x/[a-c]+", "/x/abc", true, nil},
		{"/x/[a-c]+", "/x/abcd", false, nil},
		{"/x/[^0-9]+", "/x/abc", true, nil},
		{"/x/[^0-9]+", "/x/ab1", false, nil},
		{"^/api/(%w+)$", "/api/hello", true, {"hello"}},
		{"/x/(%w+)", "/x/a/b", false, nil}, // anchored to the whole path
		{"/x/(%w*)", "/x/", true, {""}},    // zero-width capture
		{"/x/(", "/x/a", false, nil},       // malformed pattern
		{"/x/(a)(b)", "/x/ab", true, {"a", "b"}},
		{"/x/(a)+", "/x/aaa", true, {"a"}}, // group quantifier keeps the last rep
		{"/x/(a)*", "/x/aaa", true, {"a"}},
		{"/x/(a)?", "/x/", true, {""}},
		{"/x/(a)?", "/x/a", true, {"a"}},
		{"/x/(.-)end", "/x/aaaend", true, {"aaa"}}, // lazy
		{"/x/(%d+)1", "/x/121", true, {"12"}},      // backtracking inside a class
		{"/a.b", "/axb", true, nil},                // pattern mode: '.' is any char
		{"/a%.b", "/a.b", true, nil},               // '%' opts into pattern mode
		{"/a%.b", "/axb", false, nil},
		{"/v1.0/status", "/v1.0/status", true, nil}, // segment mode, literal dot
	}
	for cse in cases {
		captures: [dynamic]string
		defer delete(captures)
		got := pattern_match(cse.pattern, cse.path, &captures)
		testing.expectf(t, got == cse.match, "pattern %q vs %q: expected %v, got %v", cse.pattern, cse.path, cse.match, got)
		if got && cse.match {
			testing.expectf(t, len(captures) == len(cse.caps), "pattern %q vs %q: expected %v captures, got %v", cse.pattern, cse.path, len(cse.caps), len(captures))
			for i in 0..<len(cse.caps) {
				if i < len(captures) {
					testing.expectf(t, captures[i] == cse.caps[i], "pattern %q vs %q: capture %d expected %q, got %q", cse.pattern, cse.path, i + 1, cse.caps[i], captures[i])
				}
			}
		}
	}
}

@(test)
test_pattern_route :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_get(&r, "/users/(%d+)/posts/(%w+)", noop_handler)
	router_get(&r, "/files/(.-)%.html", noop_handler)
	// old-style patterns keep working next to pattern routes
	router_get(&r, "/legacy/:name", noop_handler)
	router_get(&r, "/wild/*", noop_handler)

	req := Request{method = .Get, path = "/users/42/posts/hello"}
	route, ok := router_match(&r, &req, alloc)
	testing.expect(t, ok)
	testing.expect(t, route != nil)
	c1, ok1 := request_capture(&req, 1)
	c2, ok2 := request_capture(&req, 2)
	testing.expect(t, ok1 && c1 == "42")
	testing.expect(t, ok2 && c2 == "hello")
	// request_capture is 1-based and bounds-checked
	_, ok3 := request_capture(&req, 0)
	testing.expect(t, !ok3)
	_, ok4 := request_capture(&req, 3)
	testing.expect(t, !ok4)

	req2 := Request{method = .Get, path = "/files/a/b/c.html"}
	_, ok5 := router_match(&r, &req2, alloc)
	testing.expect(t, ok5)
	dcap, _ := request_capture(&req2, 1)
	testing.expect(t, dcap == "a/b/c")

	// %d+ must not match letters
	req3 := Request{method = .Get, path = "/users/abc/posts/x"}
	route4, ok6 := router_match(&r, &req3, alloc)
	testing.expect(t, !ok6)
	testing.expect(t, route4 == nil)

	// :param still captures
	req4 := Request{method = .Get, path = "/legacy/ada"}
	_, ok7 := router_match(&r, &req4, alloc)
	testing.expect(t, ok7)
	pname, has_pname := request_param(&req4, "name")
	testing.expect(t, has_pname && pname == "ada")

	// '*' still matches the remainder
	req5 := Request{method = .Get, path = "/wild/anything/goes"}
	_, ok8 := router_match(&r, &req5, alloc)
	testing.expect(t, ok8)

	// method mismatch still reports 405
	req6 := Request{method = .Post, path = "/users/42/posts/hello"}
	_, ok9 := router_match(&r, &req6, alloc)
	testing.expect(t, !ok9)
}
