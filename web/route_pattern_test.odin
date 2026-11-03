package web

// Pattern routes end to end: registration, the hash index falling through to
// the pattern scan, captures, and the ':param' / '*' routes that keep working
// next to them. The engine itself is tested in pattern/pattern_test.odin.

import "core:mem"
import "core:testing"

noop_handler :: proc(req: ^Request, res: ^Response) {}

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
