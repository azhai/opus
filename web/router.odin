package web

import "core:mem"

/*
Router is lighttpd2's "action stack + condition evaluation" idea, expressed
as plain Odin procedures instead of a config language: a route table with
`:param` / `*` patterns, and a middleware chain that wraps the final
handler. No closures are needed - middleware continues via `router_next`
with an explicit index.
*/
Router :: struct {
	routes:      [dynamic]Route,
	middlewares: [dynamic]Middleware,
	allocator:   mem.Allocator,
	not_found:   Handler,
}

Route :: struct {
	method:  Method,
	pattern: string,
	handler: Handler,
}

// Middleware is a chain link. `proc_` receives the router, its own index,
// and the final handler; it must call `router_next` to continue the chain
// (possibly after mutating the request/response).
Middleware :: struct {
	proc_: Middleware_Proc,
	ud:    rawptr,
}

Middleware_Proc :: #type proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response)

router_init :: proc(r: ^Router, allocator := context.allocator) {
	r.allocator = allocator
	r.routes = make([dynamic]Route, allocator)
	r.middlewares = make([dynamic]Middleware, allocator)
}

router_destroy :: proc(r: ^Router) {
	if r.routes != nil {
		delete(r.routes)
		r.routes = nil
	}
	if r.middlewares != nil {
		delete(r.middlewares)
		r.middlewares = nil
	}
}

router_add :: proc(r: ^Router, method: Method, pattern: string, handler: Handler) -> ^Route {
	append(&r.routes, Route{method = method, pattern = pattern, handler = handler})
	return &r.routes[len(r.routes) - 1]
}

router_get :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Get, pattern, handler)
}

router_head :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Head, pattern, handler)
}

router_post :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Post, pattern, handler)
}

router_put :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Put, pattern, handler)
}

router_delete :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Delete, pattern, handler)
}

router_use :: proc(r: ^Router, m: Middleware_Proc, ud: rawptr = nil) {
	append(&r.middlewares, Middleware{proc_ = m, ud = ud})
}

// router_handle is a `Handler`: point `server.handler` at it and stash the
// router in `server.user_ptr`.
router_handle :: proc(req: ^Request, res: ^Response) {
	s := req.conn.server
	r := cast(^Router) s.user_ptr
	if r == nil {
		res.status = .Internal_Error
		response_write_string(res, "500 router not configured\n")
		return
	}

	route, method_ok := router_match(r, req, conn_scratch(req.conn))
	if route == nil {
		if r.not_found != nil {
			r.not_found(req, res)
			return
		}
		res.status = .Not_Found
		response_write_string(res, "404 page not found\n")
		return
	}
	if !method_ok {
		res.status = .Method_Not_Allowed
		response_set_header(res, "Allow", route_allowed_methods(r, route, conn_scratch(req.conn)))
		response_write_string(res, "405 method not allowed\n")
		return
	}
	router_next(r, 0, route.handler, req, res)
}

router_next :: proc(r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	if idx >= len(r.middlewares) {
		final(req, res)
		return
	}
	m := &r.middlewares[idx]
	m.proc_(m, r, idx, final, req, res)
}

// router_match finds the route for a request. Method+path matches win; a
// path-only match is reported with method_ok = false so the caller can
// answer 405. Register specific patterns before wildcards.
//
// Params are stored into `req.params` (backed by `allocator`, typically the
// connection scratch arena).
router_match :: proc(r: ^Router, req: ^Request, allocator: mem.Allocator) -> (route: ^Route, method_ok: bool) {
	params := make([dynamic]Param, allocator)

	// first pass: method + path
	for i in 0..<len(r.routes) {
		candidate := &r.routes[i]
		if candidate.method != req.method {
			continue
		}
		clear(&params)
		if path_match(candidate.pattern, req.path, &params) {
			req.params = params[:]
			return candidate, true
		}
	}

	// second pass: path only, for the 405 answer
	for i in 0..<len(r.routes) {
		candidate := &r.routes[i]
		clear(&params)
		if path_match(candidate.pattern, req.path, &params) {
			req.params = params[:]
			return candidate, false
		}
	}

	req.params = nil
	return nil, false
}

route_allowed_methods :: proc(r: ^Router, route: ^Route, allocator: mem.Allocator) -> string {
	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)
	for i in 0..<len(r.routes) {
		if r.routes[i].pattern == route.pattern {
			if buf_len(&b) > 0 {
				buf_append_string(&b, ", ")
			}
			buf_append_string(&b, method_string(r.routes[i].method))
		}
	}
	return clone_string(string(buf_slice(&b)), allocator)
}

// path_match matches a route pattern against a path segment by segment.
// Pattern segments beginning with ':' capture params; a final '*' matches
// the remainder of the path (including nothing).
path_match :: proc(pattern, path: string, params: ^[dynamic]Param) -> bool {
	pi, qi := 0, 0
	for {
		ps, pe := next_segment(pattern, &pi)
		qs, qe := next_segment(path, &qi)
		if ps < 0 && qs < 0 {
			return true
		}
		if ps < 0 {
			return false
		}
		pseg := pattern[ps:pe]
		if pseg == "*" {
			return true
		}
		if qs < 0 {
			return false
		}
		qseg := path[qs:qe]
		if len(pseg) > 0 && pseg[0] == ':' {
			append(params, Param{name = pseg[1:], value = qseg})
			continue
		}
		if pseg != qseg {
			return false
		}
	}
}

// next_segment returns the [start, end) bounds of the next '/'-separated
// segment, advancing `pos` past it. Returns (-1, -1) at the end.
next_segment :: proc(s: string, pos: ^int) -> (int, int) {
	i := pos^
	n := len(s)
	// skip separators
	for i < n && s[i] == '/' {
		i += 1
	}
	if i >= n {
		pos^ = i
		return -1, -1
	}
	start := i
	for i < n && s[i] != '/' {
		i += 1
	}
	pos^ = i
	return start, i
}
