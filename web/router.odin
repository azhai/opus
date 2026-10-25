package web

import "core:mem"
import "core:strings"

/*
Router is lighttpd2's "action stack + condition evaluation" idea, expressed
as plain Odin procedures instead of a config language: a route table with
`:param` / `*` patterns, and a middleware chain that wraps the final
handler. No closures are needed - middleware continues via `router_next`
with an explicit index.
*/
Router :: struct {
	// routes holds pointers, not values: appending to the table must not
	// move the routes themselves, because `router_add` hands a `^Route` to
	// the caller and `router_use_route` keeps writing to it long after.
	routes:      [dynamic]^Route,
	middlewares: [dynamic]Middleware,
	allocator:   mem.Allocator,
	not_found:   Handler,
	// rewrites are applied to the request path before the route table is
	// consulted (see router_rewrite).
	rewrites:    [dynamic]Rewrite,
}

// Rewrite is one internal rewrite rule: a request path that starts with
// `from` (at a segment boundary) is served as if it had started with `to`.
// `exact` makes it a whole-path match instead of a prefix one.
Rewrite :: struct {
	from:  string,
	to:    string,
	exact: bool,
}

Route :: struct {
	method:  Method,
	pattern: string,
	handler: Handler,
	// middlewares are route-local: they run after the router-wide chain and
	// before `handler`, so auth or a body parser can be attached to one
	// route. Empty for a plain route.
	middlewares: [dynamic]Middleware,
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
	r.routes = make([dynamic]^Route, allocator)
	r.middlewares = make([dynamic]Middleware, allocator)
	r.rewrites = make([dynamic]Rewrite, allocator)
}

router_destroy :: proc(r: ^Router) {
	if r.routes != nil {
		for i in 0..<len(r.routes) {
			route := r.routes[i]
			if route == nil {
				continue
			}
			if route.middlewares != nil {
				delete(route.middlewares)
				route.middlewares = nil
			}
			free(route, r.allocator)
		}
		delete(r.routes)
		r.routes = nil
	}
	if r.middlewares != nil {
		delete(r.middlewares)
		r.middlewares = nil
	}
	if r.rewrites != nil {
		delete(r.rewrites)
		r.rewrites = nil
	}
}

/*
router_rewrite registers an internal rewrite: the request path is changed
before the route table sees it, and nothing is sent to the client. That is
what makes it different from middleware_redirect - no second request, no
address-bar change, the client cannot tell.

	router_rewrite(&r, "/old", "/new")         // /old/x/y -> /new/x/y
	router_rewrite(&r, "/favicon.ico", "/static/favicon.ico", true)

Rules are tried in registration order and the first match wins, so register
the specific ones first. Matching is segment-aware: "/old" does not rewrite
"/older". The query string is untouched - it is parsed out of the target
before this runs.
*/
router_rewrite :: proc(r: ^Router, from, to: string, exact := false) {
	append(&r.rewrites, Rewrite{from = from, to = to, exact = exact})
}

// router_apply_rewrites rewrites `req.path` in place. The new path is
// allocated on the connection arena, so it dies with the request.
router_apply_rewrites :: proc(r: ^Router, req: ^Request) {
	if len(r.rewrites) == 0 {
		return
	}
	path := req.path
	for rule in r.rewrites {
		if len(rule.from) == 0 {
			continue
		}
		if rule.exact {
			if path == rule.from {
				req.path = concat_strings({rule.to}, request_allocator(req))
				return
			}
			continue
		}
		if !rewrite_prefix_matches(path, rule.from) {
			continue
		}
		rest := path[len(rule.from):]
		req.path = concat_strings({rule.to, rest}, request_allocator(req))
		return
	}
}

// rewrite_prefix_matches reports whether `path` starts with `from` at a
// segment boundary: "/old" matches "/old" and "/old/x", not "/older".
rewrite_prefix_matches :: proc(path, from: string) -> bool {
	if len(path) < len(from) {
		return false
	}
	if !strings.has_prefix(path, from) {
		return false
	}
	if len(path) == len(from) {
		return true
	}
	if from[len(from) - 1] == '/' {
		return true
	}
	return path[len(from)] == '/'
}

router_add :: proc(r: ^Router, method: Method, pattern: string, handler: Handler) -> ^Route {
	// The route is heap-allocated and only its pointer goes in the table, so
	// the pointer stays valid however many routes are added afterwards.
	route := new(Route, r.allocator)
	route.method = method
	route.pattern = pattern
	route.handler = handler
	route.middlewares = make([dynamic]Middleware, r.allocator)
	append(&r.routes, route)
	return route
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

router_patch :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Patch, pattern, handler)
}

// router_options registers the OPTIONS handler for a path. Registering one
// is optional: CORS preflights are usually answered by middleware_cors
// before the route table is consulted.
router_options :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .Options, pattern, handler)
}

// router_all registers a route that answers every request method. It exists
// for endpoints whose contract is genuinely method-agnostic - health probes
// and reverse-proxy liveness checks do not promise to use GET - so that a
// POST to such a path answers instead of falling through to 405.
router_all :: proc(r: ^Router, pattern: string, handler: Handler) -> ^Route {
	return router_add(r, .All, pattern, handler)
}

router_use :: proc(r: ^Router, m: Middleware_Proc, ud: rawptr = nil) {
	append(&r.middlewares, Middleware{proc_ = m, ud = ud})
}

/*
router_use_route attaches a middleware to one route instead of the whole
router: it runs after every router-wide middleware and before the route's
handler. This is what makes a purpose-built middleware usable on a single
endpoint - auth in front of /admin, a form parser on /upload - without
guarding inside the handler.

`route` is the pointer a `router_*` registration call returned. Routes live on
the heap and the table only stores pointers, so that pointer stays valid no
matter how many routes are added afterwards: register the whole table first
and attach its middleware in a second pass, or attach as you go - both are
fine.
*/
router_use_route :: proc(route: ^Route, m: Middleware_Proc, ud: rawptr = nil) {
	append(&route.middlewares, Middleware{proc_ = m, ud = ud})
}

// router_handle is a `Handler`: point `server.handler` at it and stash the
// router in `server.user_ptr`.
//
// Unmatched requests still walk the middleware chain, with a terminal that
// answers 404 (or `r.not_found`) or 405 + `Allow`. That is what makes
// cross-cutting middleware useful on the edges: a CORS preflight is an
// OPTIONS request that no route registered, and a request id / access log
// line for a 404 is exactly as valuable as for a 200.
router_handle :: proc(req: ^Request, res: ^Response) {
	s := req.conn.server
	r := cast(^Router) s.user_ptr
	if r == nil {
		res.status = .Internal_Error
		response_write_string(res, "500 router not configured\n")
		return
	}

	router_apply_rewrites(r, req)

	route, method_ok := router_match(r, req, conn_scratch(req.conn))
	switch {
	case route == nil:
		router_next(r, 0, router_fallthrough_not_found, req, res)
	case !method_ok:
		router_next(r, 0, router_fallthrough_method_not_allowed, req, res)
	case:
		req.route = route
		router_next(r, 0, router_route_terminal, req, res)
	}
}

// router_route_terminal is the end of the router-wide chain: it either calls
// the route handler directly or runs the route's own middleware chain first.
// The route is carried on the request because `Handler` has no user data.
router_route_terminal :: proc(req: ^Request, res: ^Response) {
	route := req.route
	if route == nil {
		router_fallthrough_not_found(req, res)
		return
	}
	if len(route.middlewares) == 0 {
		route.handler(req, res)
		return
	}
	req.chain = route.middlewares[:]
	// A nil router tells router_next to walk `req.chain`, which is how one
	// Middleware_Proc implementation serves both a router-wide chain and a
	// single-route one.
	router_next(nil, 0, route.handler, req, res)
}

// router_fallthrough_not_found is the chain terminal for an unmatched path.
// The router is re-read from the server because `Handler` carries no user
// data; rematching only happens on the 404 path.
router_fallthrough_not_found :: proc(req: ^Request, res: ^Response) {
	r := cast(^Router) req.conn.server.user_ptr
	if r != nil && r.not_found != nil {
		r.not_found(req, res)
		return
	}
	res.status = .Not_Found
	response_write_string(res, "404 page not found\n")
}

// router_fallthrough_method_not_allowed is the chain terminal for a path
// that exists under other methods; the `Allow` header lists them.
router_fallthrough_method_not_allowed :: proc(req: ^Request, res: ^Response) {
	r := cast(^Router) req.conn.server.user_ptr
	res.status = .Method_Not_Allowed
	if r != nil {
		if route, _ := router_match(r, req, conn_scratch(req.conn)); route != nil {
			response_set_header(res, "Allow", route_allowed_methods(r, route, conn_scratch(req.conn)))
		}
	}
	response_write_string(res, "405 method not allowed\n")
}

// router_next runs one link of a middleware chain. `r` is the router whose
// chain is being walked; nil means "the chain stored on the request", which
// is how route-local middleware reuses the same Middleware_Proc signature as
// router-wide middleware.
router_next :: proc(r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	chain := req.chain
	if r != nil {
		chain = r.middlewares[:]
	}
	if idx >= len(chain) {
		final(req, res)
		return
	}
	m := &chain[idx]
	m.proc_(m, r, idx, final, req, res)
}

// router_match finds the route for a request. Method+path matches win; a
// path-only match is reported with method_ok = false so the caller can
// answer 405. Register specific patterns before wildcards.
//
// Params are stored into `req.params` (backed by `allocator`, typically the
// connection scratch arena); positional captures of pattern routes go to
// `req.captures`.
router_match :: proc(r: ^Router, req: ^Request, allocator: mem.Allocator) -> (route: ^Route, method_ok: bool) {
	params := make([dynamic]Param, allocator)
	captures := make([dynamic]string, allocator)

	// first pass: method + path (.All routes accept any request method)
	for i in 0..<len(r.routes) {
		candidate := r.routes[i]
		if candidate.method != req.method && candidate.method != .All {
			continue
		}
		clear(&params)
		clear(&captures)
		if path_match(candidate.pattern, req.path, &params, &captures) {
			req.params = params[:]
			req.captures = captures[:]
			return candidate, true
		}
	}

	// HEAD falls back to the GET route: RFC 7231 section 4.3.2 requires HEAD
	// wherever GET is offered, and the response builder already drops the
	// body (it keeps the length the GET would have had).
	if req.method == .Head {
		for i in 0..<len(r.routes) {
			candidate := r.routes[i]
			if candidate.method != .Get {
				continue
			}
			clear(&params)
			clear(&captures)
			if path_match(candidate.pattern, req.path, &params, &captures) {
				req.params = params[:]
				req.captures = captures[:]
				return candidate, true
			}
		}
	}

	// second pass: path only, for the 405 answer
	for i in 0..<len(r.routes) {
		candidate := r.routes[i]
		clear(&params)
		clear(&captures)
		if path_match(candidate.pattern, req.path, &params, &captures) {
			req.params = params[:]
			req.captures = captures[:]
			return candidate, false
		}
	}

	req.params = nil
	req.captures = nil
	return nil, false
}

route_allowed_methods :: proc(r: ^Router, route: ^Route, allocator: mem.Allocator) -> string {
	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)
	for i in 0..<len(r.routes) {
		if r.routes[i].pattern == route.pattern && r.routes[i].method != .All {
			if buf_len(&b) > 0 {
				buf_append_string(&b, ", ")
			}
			buf_append_string(&b, method_string(r.routes[i].method))
		}
	}
	return clone_string(string(buf_slice(&b)), allocator)
}

// path_match matches a route pattern against a path. Patterns containing
// pattern syntax ('(', '%' or '[') are matched with the Lua-pattern
// subset below and fill `captures` positionally; every other pattern
// keeps segment semantics: segments beginning with ':' capture params,
// and a final '*' matches the remainder of the path (including nothing).
path_match :: proc(pattern, path: string, params: ^[dynamic]Param, captures: ^[dynamic]string) -> bool {
	if pattern_has_syntax(pattern) {
		return pattern_match(pattern, path, captures)
	}
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

// ---------------------------------------------------------------------------
// Lua-pattern-subset route matching
//
// Route patterns containing '(' (captures), '%' (classes) or '[' (sets)
// are matched with this engine instead of segment matching. It covers the
// subset of Lua patterns that is useful for routes:
//
//   literals, '%' escapes the next character
//   '.'                 any character
//   %a %d %w %s %p %l %u %c %x    classes (uppercase = complement)
//   [set] [^set]        character sets, ranges like [a-z]
//   * + ?               greedy quantifiers, with backtracking
//   -                   lazy quantifier (zero or more)
//   (...)               capture groups, nesting allowed
//
// The match is always anchored to the whole path; a leading '^' and a
// trailing '$' are accepted and ignored.
//
// Implementation: the pattern is compiled into a tiny backtracking VM
// (Char / Split / Jmp / Save / Match instructions). A VM - rather than
// direct recursion - is what makes capture groups backtrack correctly:
// in "(.-)%.html" the lazy body must extend until the *outer*
// continuation matches, and Save/undo give Lua's capture semantics (a
// capture holds the last repetition of a quantified group) for free.
// Known limits: no '%b', no '%f'.
// ---------------------------------------------------------------------------

// pattern_has_syntax reports whether a pattern opts into pattern matching.
// A literal '.' does not trigger it (so "/v1.0/status" stays a segment
// pattern); write '%.' when pattern mode is on.
pattern_has_syntax :: proc(pattern: string) -> bool {
	for i in 0..<len(pattern) {
		switch pattern[i] {
		case '(', '%', '[':
			return true
		}
	}
	return false
}

pattern_match :: proc(pattern, path: string, captures: ^[dynamic]string) -> bool {
	p := pattern
	if len(p) > 0 && p[0] == '^' {
		p = p[1:]
	}
	if len(p) > 0 && p[len(p) - 1] == '$' {
		p = p[:len(p) - 1]
	}
	m: Match_Ctx
	m.pat = p
	m.s = path
	pb: Prog_Builder
	pb.prog = &m.prog
	pb.m = &m
	if !compile_seq(&pb, 0, len(p)) {
		return false
	}
	if pb_emit(&pb, .Match) < 0 {
		return false
	}
	if !vm_run(&m, 0, 0) {
		return false
	}
	clear(captures)
	for i in 0..<m.n {
		append(captures, path[m.caps[2 * i]:m.caps[2 * i + 1]])
	}
	return true
}

MAX_PROG    :: 128 // compiled instructions
MAX_STEPS   :: 8192 // backtracking budget per match
MAX_UNDO    :: 256 // capture undo entries
MAX_CAPTURES :: 16

Inst_Kind :: enum {
	Char,  // match one item (prog.item)
	Split, // try x first, then y (order encodes greedy vs lazy)
	Jmp,   // jump to x
	Save,  // record the current position into capture slot x
	Match, // succeed when the whole subject is consumed
}

Prog :: struct {
	kind: [MAX_PROG]Inst_Kind,
	x:    [MAX_PROG]int,
	y:    [MAX_PROG]int,
	item: [MAX_PROG]string,
	n:    int,
}

Undo :: struct {
	slot, old: int,
}

Match_Ctx :: struct {
	prog:  Prog,
	pat:   string, // the pattern being compiled
	s:     string, // the subject being matched
	caps:  [2 * MAX_CAPTURES]int,
	n:     int, // capture groups opened
	undo:  [MAX_UNDO]Undo,
	undo_n: int,
	steps: int,
}

Prog_Builder :: struct {
	prog: ^Prog,
	m:    ^Match_Ctx, // for capture slot allocation
}

pb_emit :: proc(pb: ^Prog_Builder, kind: Inst_Kind, x := 0, y := 0, item := "") -> int {
	if pb.prog.n >= MAX_PROG {
		return -1
	}
	pc := pb.prog.n
	pb.prog.kind[pc] = kind
	pb.prog.x[pc] = x
	pb.prog.y[pc] = y
	pb.prog.item[pc] = item
	pb.prog.n += 1
	return pc
}

// compile_seq compiles p[pi:pend] into the program. Returns false on
// malformed patterns or overflow.
compile_seq :: proc(pb: ^Prog_Builder, pi_in, pend: int) -> bool {
	p := pb.m.pat
	pi := pi_in // parameters are immutable in Odin
	for pi < pend {
		c := p[pi]

		// ---- capture group ----
		if c == '(' {
			depth := 1
			j := pi + 1
			for j < pend && depth > 0 {
				switch p[j] {
				case '(':
					depth += 1
				case ')':
					depth -= 1
				}
				j += 1
			}
			if depth != 0 {
				return false // unbalanced '('
			}
			gend := j - 1 // index of the ')'
			q := pat_quant_at(p, j, pend)
			cont := j
			if q != 0 {
				cont = j + 1
			}
			if pb.m.n >= MAX_CAPTURES {
				return false
			}
			cap := pb.m.n
			pb.m.n += 1

			if q == 0 {
				if pb_emit(pb, .Save, 2 * cap) < 0 {
					return false
				}
				if !compile_seq(pb, pi + 1, gend) {
					return false
				}
				if pb_emit(pb, .Save, 2 * cap + 1) < 0 {
					return false
				}
				pi = cont
				continue
			}

			// quantified group:
			//   greedy:  Split L1, exit ; L1: Save(body) Save ; Jmp Split
			//   lazy:    Split exit, L1 ; L1: Save(body) Save ; Jmp Split
			//   '+':     L1 runs once, then the greedy loop (min one rep)
			//   '?':     plain split (zero or one)
			if q == '+' {
				l1 := pb_emit(pb, .Save, 2 * cap)
				if l1 < 0 {
					return false
				}
				if !compile_seq(pb, pi + 1, gend) {
					return false
				}
				if pb_emit(pb, .Save, 2 * cap + 1) < 0 {
					return false
				}
				sp := pb_emit(pb, .Split)
				if sp < 0 {
					return false
				}
				pb.prog.x[sp] = l1
				pb.prog.y[sp] = pb.prog.n
				pi = cont
				continue
			}

			sp := pb_emit(pb, .Split)
			if sp < 0 {
				return false
			}
			l1 := pb.prog.n
			{
				if pb_emit(pb, .Save, 2 * cap) < 0 {
					return false
				}
				if !compile_seq(pb, pi + 1, gend) {
					return false
				}
				if pb_emit(pb, .Save, 2 * cap + 1) < 0 {
					return false
				}
				jmp := pb_emit(pb, .Jmp)
				if jmp < 0 {
					return false
				}
				pb.prog.x[jmp] = sp
				if q == '-' {
					pb.prog.x[sp] = pb.prog.n // exit first (lazy)
					pb.prog.y[sp] = l1
				} else {
					pb.prog.x[sp] = l1 // body first (greedy / '?')
					pb.prog.y[sp] = pb.prog.n
				}
			}
			pi = cont
			continue
		}

		if c == ')' {
			return false // unbalanced ')'
		}

		// ---- single-character item ----
		item_end := pi + 1
		switch c {
		case '%':
			if pi + 1 >= pend {
				return false
			}
			item_end = pi + 2
		case '[':
			e := pat_set_end(p, pi, pend)
			if e < 0 {
				return false
			}
			item_end = e + 1
		}
		q := pat_quant_at(p, item_end, pend)
		cont := item_end
		if q != 0 {
			cont = item_end + 1
		}
		item := p[pi:item_end]

		if q == 0 {
			if pb_emit(pb, .Char, item = item) < 0 {
				return false
			}
			pi = cont
			continue
		}

		if q == '+' {
			// min one: the character first, then a greedy loop
			l1 := pb_emit(pb, .Char, item = item)
			if l1 < 0 {
				return false
			}
			sp := pb_emit(pb, .Split)
			if sp < 0 {
				return false
			}
			pb.prog.x[sp] = l1
			pb.prog.y[sp] = pb.prog.n
			pi = cont
			continue
		}

		sp := pb_emit(pb, .Split)
		if sp < 0 {
			return false
		}
		l1 := pb_emit(pb, .Char, item = item)
		if l1 < 0 {
			return false
		}
		if q == '?' {
			pb.prog.x[sp] = l1
			pb.prog.y[sp] = pb.prog.n
		} else {
			jmp := pb_emit(pb, .Jmp)
			if jmp < 0 {
				return false
			}
			pb.prog.x[jmp] = sp
			if q == '-' {
				pb.prog.x[sp] = pb.prog.n // exit first (lazy)
				pb.prog.y[sp] = l1
			} else {
				pb.prog.x[sp] = l1 // body first (greedy)
				pb.prog.y[sp] = pb.prog.n
			}
		}
		pi = cont
	}
	return true
}

// vm_run runs the program from pc and restores capture state on failure,
// so a failed backtracking branch never leaves stale captures behind.
vm_run :: proc(m: ^Match_Ctx, pc, si: int) -> bool {
	mark := m.undo_n
	if !vm_run_inner(m, pc, si) {
		for m.undo_n > mark {
			m.undo_n -= 1
			u := m.undo[m.undo_n]
			m.caps[u.slot] = u.old
		}
		return false
	}
	return true
}

vm_run_inner :: proc(m: ^Match_Ctx, pc_in, si_in: int) -> bool {
	pc, si := pc_in, si_in // parameters are immutable in Odin
	for {
		m.steps += 1
		if m.steps > MAX_STEPS {
			return false
		}
		switch m.prog.kind[pc] {
		case .Char:
			if si >= len(m.s) || !pat_item_matches(m.prog.item[pc], m.s[si]) {
				return false
			}
			si += 1
			pc += 1
		case .Split:
			if vm_run(m, m.prog.x[pc], si) {
				return true
			}
			pc = m.prog.y[pc]
		case .Jmp:
			pc = m.prog.x[pc]
		case .Save:
			slot := m.prog.x[pc]
			if m.undo_n >= MAX_UNDO {
				return false
			}
			m.undo[m.undo_n] = Undo{slot = slot, old = m.caps[slot]}
			m.undo_n += 1
			m.caps[slot] = si
			pc += 1
		case .Match:
			return si == len(m.s)
		}
	}
}

// pat_quant_at returns the quantifier byte at pos ('*', '+', '?', '-')
// or 0 when there is none.
pat_quant_at :: proc(p: string, pos, pend: int) -> byte {
	if pos >= pend {
		return 0
	}
	switch p[pos] {
	case '*', '+', '?', '-':
		return p[pos]
	}
	return 0
}

// pat_set_end returns the index of the ']' closing the set that starts at
// pi, or -1. A ']' right after '[' (or '[^') is a literal.
pat_set_end :: proc(p: string, pi, pend: int) -> int {
	j := pi + 1
	if j < pend && p[j] == '^' {
		j += 1
	}
	if j < pend && p[j] == ']' {
		j += 1
	}
	for j < pend && p[j] != ']' {
		if p[j] == '%' {
			j += 1
		}
		j += 1
	}
	if j >= pend {
		return -1
	}
	return j
}

// pat_item_matches tests one character against a single item: a literal,
// '.', a '%' class escape, or a '[...]' set. An escape of a non-class
// character ('%.', '%-', ...) is a literal.
pat_item_matches :: proc(item: string, ch: byte) -> bool {
	if len(item) == 0 {
		return false
	}
	switch item[0] {
	case '.':
		return true
	case '%':
		if len(item) < 2 {
			return false
		}
		cl := item[1]
		if pat_is_class_letter(cl) {
			if cl >= 'A' && cl <= 'Z' {
				return !pat_class_match(cl + ('a' - 'A'), ch)
			}
			return pat_class_match(cl, ch)
		}
		return ch == cl // escaped literal
	case '[':
		return pat_set_matches(item, ch)
	}
	return ch == item[0]
}

pat_is_class_letter :: proc(cl: byte) -> bool {
	switch cl {
	case 'a', 'd', 'w', 's', 'p', 'l', 'u', 'c', 'x',
	     'A', 'D', 'W', 'S', 'P', 'L', 'U', 'C', 'X':
		return true
	}
	return false
}

pat_set_matches :: proc(item: string, ch: byte) -> bool {
	neg := false
	i := 1
	if i < len(item) && item[i] == '^' {
		neg = true
		i += 1
	}
	found := false
	for i < len(item) && item[i] != ']' {
		if item[i] == '%' && i + 1 < len(item) {
			if pat_class_match(item[i + 1], ch) {
				found = true
			}
			i += 2
			continue
		}
		if i + 2 < len(item) && item[i + 1] == '-' && item[i + 2] != ']' {
			if ch >= item[i] && ch <= item[i + 2] {
				found = true
			}
			i += 3
			continue
		}
		if ch == item[i] {
			found = true
		}
		i += 1
	}
	return found != neg
}

pat_class_match :: proc(cl, ch: byte) -> bool {
	switch cl {
	case 'a':
		return pat_is_alpha(ch)
	case 'd':
		return pat_is_digit(ch)
	case 'w':
		return pat_is_alnum(ch)
	case 's':
		return pat_is_space(ch)
	case 'p':
		return pat_is_punct(ch)
	case 'l':
		return ch >= 'a' && ch <= 'z'
	case 'u':
		return ch >= 'A' && ch <= 'Z'
	case 'c':
		return ch < 0x20 || ch == 0x7f
	case 'x':
		return pat_is_xdigit(ch)
	}
	return false
}

pat_is_alpha :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

pat_is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

pat_is_alnum :: proc(c: byte) -> bool {
	return pat_is_alpha(c) || pat_is_digit(c)
}

pat_is_space :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

pat_is_punct :: proc(c: byte) -> bool {
	return (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

pat_is_xdigit :: proc(c: byte) -> bool {
	return pat_is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

