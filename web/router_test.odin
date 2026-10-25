package web

// Tests for the router: pattern matching, params and captures,
// the middleware chain and the Lua-pattern subset.

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
// router
// ---------------------------------------------------------------------------

@(test)
test_router_match_and_params :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_get(&r, "/users/:id", dummy_handler)
	router_post(&r, "/users", dummy_handler)
	router_get(&r, "/assets/*", dummy_handler)

	req: Request
	req.method = .Get
	req.path = "/users/42"
	route, ok := router_match(&r, &req, alloc)
	testing.expect(t, route != nil)
	testing.expect(t, ok)
	id, has_id := request_param(&req, "id")
	testing.expect(t, has_id)
	testing.expect(t, id == "42")

	// path matches, method does not
	req2: Request
	req2.method = .Delete
	req2.path = "/users"
	route2, ok2 := router_match(&r, &req2, alloc)
	testing.expect(t, route2 != nil)
	testing.expect(t, !ok2)

	// wildcard
	req3: Request
	req3.method = .Get
	req3.path = "/assets/css/app.css"
	route3, ok3 := router_match(&r, &req3, alloc)
	testing.expect(t, route3 != nil)
	testing.expect(t, ok3)

	// no match
	req4: Request
	req4.method = .Get
	req4.path = "/nope"
	route4, _ := router_match(&r, &req4, alloc)
	testing.expect(t, route4 == nil)
}

@(test)
test_router_middleware_chain :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_use(&r, middleware_mark_a, nil)
	router_use(&r, middleware_mark_b, nil)
	router_get(&r, "/chain", chain_final_handler)

	req: Request
	req.method = .Get
	req.path = "/chain"
	res: Response
	c: Conn
	response_init(&res, &c, alloc)
	router_handle_with(&r, &req, &res)

	testing.expect(t, strings.contains(string(buf_slice(&res.body)), "a>b>final"))
}

middleware_mark_a :: proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	response_write_string(res, "a>")
	router_next(r, idx + 1, final, req, res)
}

middleware_mark_b :: proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	response_write_string(res, "b>")
	router_next(r, idx + 1, final, req, res)
}

chain_final_handler :: proc(req: ^Request, res: ^Response) {
	response_write_string(res, "final")
}

// router_handle_with is router_handle with an explicit router (the public
// entry point reads the router out of server.user_ptr).
router_handle_with :: proc(r: ^Router, req: ^Request, res: ^Response) {
	route, method_ok := router_match(r, req, context.allocator)
	if route == nil {
		res.status = .Not_Found
		response_write_string(res, "404 page not found\n")
		return
	}
	if !method_ok {
		res.status = .Method_Not_Allowed
		response_write_string(res, "405 method not allowed\n")
		return
	}
	router_next(r, 0, route.handler, req, res)
}
