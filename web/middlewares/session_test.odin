package middlewares

import ".."
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// Tests for the signed-cookie session middleware. They drive real
// `router_handle` dispatches and carry the cookie from one request to the
// next by hand, which is the only part a browser would otherwise do.

session_secret := "s3cret-s3cret-s3cret"

session_cfg := Session_Config {
	name         = "sid",
	secret       = session_secret,
	max_age_secs = 3600,
}

session_read_handler :: proc(req: ^web.Request, res: ^web.Response) {
	user, ok := session_get(req, "user")
	if !ok {
		user = "anon"
	}
	web.response_write_string(res, user)
	web.response_write_string(res, "|")
	web.response_write_string(res, session_id(req))
}

session_write_handler :: proc(req: ^web.Request, res: ^web.Response) {
	session_set(req, "user", "ada")
	web.response_write_string(res, "logged-in")
}

session_logout_handler :: proc(req: ^web.Request, res: ^web.Response) {
	session_destroy(req, res, &session_cfg)
	web.response_write_string(res, "bye")
}

// cookie_of returns the value of a Set-Cookie header written by the
// response, or "" when the cookie was not set.
cookie_of :: proc(res: ^web.Response, name: string) -> string {
	for h in res.headers {
		if !eq_ignore_ci(h.key, "Set-Cookie") {
			continue
		}
		v := h.value
		end := index_byte(v, ';')
		if end >= 0 {
			v = v[:end]
		}
		eq := index_byte(v, '=')
		if eq < 0 {
			continue
		}
		if eq_ignore_ci(strings.trim_space(v[:eq]), name) {
			return v[eq + 1:]
		}
	}
	return ""
}

eq_ignore_ci :: proc(a, b: string) -> bool {
	return web.eq_ignore_case(a, b)
}

index_byte :: proc(s: string, c: byte) -> int {
	return web.string_index_byte(s, c)
}

// cookie_headers fills a one-element header array with a Cookie header and
// returns it as a slice. The array lives in the caller's frame, so the
// request built from it does not outlive the test (and nothing is
// allocated, so the test runner sees no leak).
cookie_headers :: proc(storage: ^[1]web.Header, cookie: string) -> []web.Header {
	storage[0] = web.Header{key = "Cookie", value = cookie}
	return storage[:]
}

@(test)
test_session_roundtrip :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cbuf: [1024]byte

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/me", session_read_handler)
	web.router_get(&e.router, "/login", session_write_handler)

	// a fresh visitor has no values and gets no cookie back: the session was
	// created but nothing changed, so there is nothing to persist
	req := web.Request{method = .Get, path = "/me", target = "/me"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect(t, strings.has_prefix(string(web.buf_slice(&res.body)), "anon|"))
	testing.expect_value(t, cookie_of(&res, "sid"), "")

	// writing a value makes the middleware answer with a signed cookie
	req_login := web.Request{method = .Get, path = "/login", target = "/login"}
	res_login: web.Response
	mw_env_call(&e, &req_login, &res_login)
	token := cookie_of(&res_login, "sid")
	testing.expect(t, len(token) > 0)
	testing.expect(t, index_byte(token, '.') > 0) // payload.tag

	// the next request carrying that cookie sees the value again
	hdrs: [1]web.Header
	req2 := web.Request {
		method  = .Get,
		path    = "/me",
		target  = "/me",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", token)),
	}
	res2: web.Response
	mw_env_call(&e, &req2, &res2)
	body := string(web.buf_slice(&res2.body))
	testing.expect(t, strings.has_prefix(body, "ada|"))
	testing.expect(t, len(body) > len("ada|")) // a session id came back too
}

/*The cookie is written after the handler returns, so a value the handler
built in its own frame would already be gone - the session has to own a
copy. This handler checks that the copy really is a copy by comparing
addresses, which is the only part that is deterministic: whatever happens
to the stack afterwards is not.
*/
session_copy_handler :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [32]byte
	v := fmt.bprintf(buf[:], "%d", 1)
	session_set(req, "visits", v)
	got, ok := session_get(req, "visits")
	session_copy_aliased = ok && len(got) == len(v) && raw_data(got) == raw_data(v)
	web.response_write_string(res, "counted")
}

// session_copy_aliased is set by session_copy_handler: true means the
// session kept the caller's pointer instead of copying it.
session_copy_aliased := true

@(test)
test_session_set_copies_value :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/count", session_copy_handler)

	req := web.Request{method = .Get, path = "/count", target = "/count"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, session_copy_aliased, false)
	// and the value that reaches the cookie is the one that was set
	payload, valid := token_open(cookie_of(&res, "sid"), session_secret, mem.arena_allocator(&e.arena))
	testing.expect(t, valid)
	testing.expect(t, strings.contains(string(payload), "visits=1"))
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

@(test)
test_session_rejects_forged_cookie :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cbuf: [1024]byte

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/me", session_read_handler)

	// sign a payload with the wrong key: the tag will not verify
	forged := token_sign(tb("id=x&exp=99999999999&user=root"), "wrong-key", mem.arena_allocator(&e.arena))
	hdrs: [1]web.Header
	req := web.Request {
		method  = .Get,
		path    = "/me",
		target  = "/me",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", forged)),
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect(t, strings.has_prefix(string(web.buf_slice(&res.body)), "anon|"))

	// a valid tag over a tampered payload: flip the last byte of the payload
	good := token_sign(tb("id=x&exp=99999999999&user=ada"), session_secret, mem.arena_allocator(&e.arena))
	dot := index_byte(good, '.')
	testing.expect(t, dot > 0)
	mutated := strings.clone(good, mem.arena_allocator(&e.arena))
	m := transmute([]byte) mutated
	if m[dot - 1] == 'a' {
		m[dot - 1] = 'b'
	} else {
		m[dot - 1] = 'a'
	}
	hdrs2: [1]web.Header
	req2 := web.Request {
		method  = .Get,
		path    = "/me",
		target  = "/me",
		headers = cookie_headers(&hdrs2, concat_cookie(cbuf[:], "sid", mutated)),
	}
	res2: web.Response
	mw_env_call(&e, &req2, &res2)
	testing.expect(t, strings.has_prefix(string(web.buf_slice(&res2.body)), "anon|"))
}

@(test)
test_session_expiry :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cbuf: [1024]byte

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/me", session_read_handler)

	// exp in the past: valid signature, stale session -> a fresh one
	stale := token_sign(tb("id=x&exp=1000&user=ada"), session_secret, mem.arena_allocator(&e.arena))
	hdrs: [1]web.Header
	req := web.Request {
		method  = .Get,
		path    = "/me",
		target  = "/me",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", stale)),
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect(t, strings.has_prefix(string(web.buf_slice(&res.body)), "anon|"))
}

@(test)
test_session_destroy :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cbuf: [1024]byte

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/me", session_read_handler)
	web.router_get(&e.router, "/login", session_write_handler)
	web.router_get(&e.router, "/logout", session_logout_handler)

	// log in, keep the cookie, log out with it
	req_login := web.Request{method = .Get, path = "/login", target = "/login"}
	res_login: web.Response
	mw_env_call(&e, &req_login, &res_login)
	token := cookie_of(&res_login, "sid")
	testing.expect(t, len(token) > 0)

	hdrs: [1]web.Header
	req_out := web.Request {
		method  = .Get,
		path    = "/logout",
		target  = "/logout",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", token)),
	}
	res_out: web.Response
	mw_env_call(&e, &req_out, &res_out)
	// the response clears the cookie (Max-Age=0 and a past Expires)
	cleared := cookie_of(&res_out, "sid")
	testing.expect_value(t, cleared, "")
	for h in res_out.headers {
		if eq_ignore_ci(h.key, "Set-Cookie") {
			testing.expect(t, strings.contains(h.value, "Max-Age=0"))
		}
	}
}

@(test)
test_session_without_secret_is_passthrough :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cbuf: [1024]byte

	empty := Session_Config{}
	web.router_use(&e.router, middleware_session, &empty)
	web.router_get(&e.router, "/me", session_read_handler)

	req := web.Request{method = .Get, path = "/me", target = "/me"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	// no secret: no session is attached and the route still runs
	testing.expect_value(t, web.response_body_size(&res), 5) // "anon|"
	testing.expect(t, !session_active(&req))
}
