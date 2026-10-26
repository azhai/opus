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

@(test)
test_router_rewrites :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_rewrite(&r, "/old", "/new")
	router_rewrite(&r, "/favicon.ico", "/static/favicon.ico", true)
	router_rewrite(&r, "/exact", "/only", true)

	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)

	// prefix rules keep the tail
	req := Request{conn = &c, path = "/old/a/b"}
	router_apply_rewrites(&r, &req)
	testing.expect_value(t, req.path, "/new/a/b")

	req_self := Request{conn = &c, path = "/old"}
	router_apply_rewrites(&r, &req_self)
	testing.expect_value(t, req_self.path, "/new")

	// prefix matching stops at a segment boundary
	req_older := Request{conn = &c, path = "/older"}
	router_apply_rewrites(&r, &req_older)
	testing.expect_value(t, req_older.path, "/older")

	// exact rules match the whole path only
	req_favicon := Request{conn = &c, path = "/favicon.ico"}
	router_apply_rewrites(&r, &req_favicon)
	testing.expect_value(t, req_favicon.path, "/static/favicon.ico")

	req_child := Request{conn = &c, path = "/exact/sub"}
	router_apply_rewrites(&r, &req_child)
	testing.expect_value(t, req_child.path, "/exact/sub")

	// the first registered rule wins
	router_rewrite(&r, "/old", "/second")
	req_first := Request{conn = &c, path = "/old"}
	router_apply_rewrites(&r, &req_first)
	testing.expect_value(t, req_first.path, "/new")
}

@(test)
test_router_all_methods :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_all(&r, "/any", dummy_handler)

	methods := []Method{Method.Get, Method.Post, Method.Put, Method.Patch, Method.Delete, Method.Options}
	for method in methods {
		req := Request{method = method, path = "/any"}
		route, ok := router_match(&r, &req, alloc)
		testing.expectf(t, route != nil, "%v: route not matched", method)
		testing.expectf(t, ok, "%v: method rejected", method)
	}

	// .All is not a wildcard for the path
	req_miss := Request{method = .Get, path = "/nope"}
	route_miss, _ := router_match(&r, &req_miss, alloc)
	testing.expect(t, route_miss == nil)
}

// custom_not_found is installed by test_router_fallthrough below.
custom_not_found :: proc(req: ^Request, res: ^Response) {
	res.status = .Not_Found
	response_write_string(res, "custom 404")
}

@(test)
test_router_fallthrough :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_get(&r, "/only", dummy_handler)

	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	srv: Server
	srv.user_ptr = &r
	c.server = &srv

	// an unmatched path still walks the chain and ends in the 404 terminal
	res: Response
	response_init(&res, &c, conn_scratch(&c))
	req := Request{conn = &c, method = .Get, path = "/missing", target = "/missing"}
	router_handle(&req, &res)
	testing.expect_value(t, res.status, Status.Not_Found)
	testing.expect_value(t, string(buf_slice(&res.body)), "404 page not found\n")

	// a known path under the wrong method gets 405 + Allow
	res_405: Response
	response_init(&res_405, &c, conn_scratch(&c))
	req_405 := Request{conn = &c, method = .Post, path = "/only", target = "/only"}
	router_handle(&req_405, &res_405)
	testing.expect_value(t, res_405.status, Status.Method_Not_Allowed)
	allow, has_allow := response_header(&res_405, "Allow")
	testing.expect(t, has_allow)
	testing.expect(t, strings.contains(allow, "GET"))

	// r.not_found replaces the default body without losing the status
	r.not_found = custom_not_found
	res_custom: Response
	response_init(&res_custom, &c, conn_scratch(&c))
	req_custom := Request{conn = &c, method = .Get, path = "/missing", target = "/missing"}
	router_handle(&req_custom, &res_custom)
	testing.expect_value(t, res_custom.status, Status.Not_Found)
	testing.expect_value(t, string(buf_slice(&res_custom.body)), "custom 404")
}
