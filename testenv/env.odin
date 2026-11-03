package testenv

// Shared fixtures for the middleware tests: every middleware package's tests
// need the same "one router + one synthetic Conn, dispatch through the real
// router_handle" setup, and the alternative is copying it into ten
// `*_test.odin` files.
//
// Why a separate package instead of a file in one middleware's tests:
// `_test.odin` files are ordinary members of their package -- Odin compiles
// them on a plain `odin build` too, the suffix only marks where `odin test`
// looks for `@(test)` procedures -- so their symbols *are* importable. But
// then one middleware's tests would depend on another's, and that package's
// test code would ride along in every build of the dependent. Here the
// dependency stays one-way: tests import `testenv`, `testenv` imports only
// `web` and `http`.

import "../web"
import "../http"
import "core:mem"
import "core:strings"

// tb turns a string literal into bytes (transmute needs a typed value).
tb :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// dummy_handler is the terminal handler most of these tests need: it writes
// a body so the tests can tell "the chain reached the route" from "a
// middleware answered first".
dummy_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, "ok")
}

// Mw_Env is one router + one synthetic connection: enough for router_handle
// to resolve the router from server.user_ptr without binding a socket.
Mw_Env :: struct {
	arena:     mem.Arena,
	arena_buf: [64 << 10]byte,
	router:    web.Router,
	conn:      web.Conn,
	srv:       web.Server,
}

mw_env_init :: proc(e: ^Mw_Env) {
	mem.arena_init(&e.arena, e.arena_buf[:])
	mem.dynamic_arena_init(&e.conn.scratch, context.allocator)
	web.router_init(&e.router, mem.arena_allocator(&e.arena))
	e.conn.server = &e.srv
	e.srv.user_ptr = &e.router
}

mw_env_destroy :: proc(e: ^Mw_Env) {
	web.router_destroy(&e.router)
	mem.dynamic_arena_destroy(&e.conn.scratch)
}

// mw_env_call dispatches one request through the router, so the middleware
// chain (and its terminals) run exactly as in production.
mw_env_call :: proc(e: ^Mw_Env, req: ^web.Request, res: ^web.Response) {
	req.conn = &e.conn
	e.conn.req.method = req.method
	res^ = web.Response{}
	web.response_init(res, &e.conn, web.conn_scratch(&e.conn))
	web.router_handle(req, res)
}

// concat_cookie builds "name=value" inside a caller-provided buffer. Tests
// must not allocate: the runner reports every leftover allocation as a leak.
concat_cookie :: proc(dst: []byte, name, value: string) -> string {
	n := 0
	for i in 0..<len(name) {
		dst[n] = name[i]
		n += 1
	}
	dst[n] = '='
	n += 1
	for i in 0..<len(value) {
		dst[n] = value[i]
		n += 1
	}
	return string(dst[:n])
}

// cookie_of returns the value of a Set-Cookie header written by the
// response, or "" when the cookie was not set.
cookie_of :: proc(res: ^web.Response, name: string) -> string {
	for h in res.headers {
		if !http.eq_ignore_case(h.key, "Set-Cookie") {
			continue
		}
		v := h.value
		end := http.string_index_byte(v, ';')
		if end >= 0 {
			v = v[:end]
		}
		eq := http.string_index_byte(v, '=')
		if eq < 0 {
			continue
		}
		if http.eq_ignore_case(strings.trim_space(v[:eq]), name) {
			return v[eq + 1:]
		}
	}
	return ""
}

// cookie_headers fills a one-element header array with a Cookie header and
// returns it as a slice. The array lives in the caller's frame, so the
// request built from it does not outlive the test (and nothing is
// allocated, so the test runner sees no leak).
cookie_headers :: proc(storage: ^[1]http.Header, cookie: string) -> []http.Header {
	storage[0] = http.Header{key = "Cookie", value = cookie}
	return storage[:]
}
