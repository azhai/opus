package middleware

import ".."
import "core:encoding/base64"
import "core:mem"
import "core:strings"
import "core:testing"

// Tests for the built-in middleware. Each one drives a real `router_handle`
// dispatch over a synthetic connection (no socket involved), so the
// registration order, the chain and the short-circuits are all exercised the
// way a server would run them.


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

// ---------------------------------------------------------------------------
// request id
// ---------------------------------------------------------------------------

request_id_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, web.request_id(req))
}

@(test)
test_middleware_request_id :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_request_id)
	web.router_get(&e.router, "/id", request_id_handler)

	req := web.Request {
		method = .Get,
		path   = "/id",
		target = "/id",
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	generated, ok := web.response_header(&res, REQUEST_ID_HEADER)
	testing.expect(t, ok)
	testing.expect_value(t, len(generated), 24) // 16 hex nanos + 8 hex counter
	testing.expect_value(t, string(web.buf_slice(&res.body)), generated)

	// an inbound id (set by a front proxy) is reused verbatim
	req2 := web.Request {
		method  = .Get,
		path    = "/id",
		target  = "/id",
		headers = []web.Header{web.Header{key = "X-Request-Id", value = "from-proxy"}},
	}
	res2: web.Response
	mw_env_call(&e, &req2, &res2)
	testing.expect_value(t, string(web.buf_slice(&res2.body)), "from-proxy")
	hdr2, _ := web.response_header(&res2, REQUEST_ID_HEADER)
	testing.expect_value(t, hdr2, "from-proxy")
}

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

@(test)
test_middleware_cors_preflight :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_cors)
	// GET-only route: the preflight is an OPTIONS request that no route
	// registered, which is exactly the case CORS middleware has to answer.
	web.router_get(&e.router, "/api/users", dummy_handler)

	req := web.Request {
		method  = .Options,
		path    = "/api/users",
		target  = "/api/users",
		headers = []web.Header {
			web.Header{key = "Origin", value = "https://app.example"},
			web.Header{key = "Access-Control-Request-Method", value = "POST"},
			web.Header{key = "Access-Control-Request-Headers", value = "content-type"},
		},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	testing.expect_value(t, res.status, web.Status.No_Content)
	acao, _ := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect_value(t, acao, "*") // no credentials configured
	acam, _ := web.response_header(&res, "Access-Control-Allow-Methods")
	testing.expect(t, strings.contains(acam, "POST"))
	acah, has_acah := web.response_header(&res, "Access-Control-Allow-Headers")
	testing.expect(t, has_acah)
	testing.expect_value(t, acah, "content-type") // mirrored from the request
	// the route handler must not have run
	testing.expect_value(t, web.buf_len(&res.body), 0)
}

@(test)
test_middleware_cors_credentials :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := CORS_Config {
		origins           = []string{"https://admin.example"},
		allow_credentials = true,
		expose_headers    = "X-Total-Count",
		max_age_secs      = 600,
	}
	web.router_use(&e.router, middleware_cors, &cfg)
	web.router_get(&e.router, "/api/users", dummy_handler)

	req := web.Request {
		method  = .Get,
		path    = "/api/users",
		target  = "/api/users",
		headers = []web.Header{web.Header{key = "Origin", value = "https://admin.example"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	acao, _ := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect_value(t, acao, "https://admin.example") // echoed, not "*"
	vary, _ := web.response_header(&res, "Vary")
	testing.expect(t, strings.contains(vary, "Origin"))
	creds, _ := web.response_header(&res, "Access-Control-Allow-Credentials")
	testing.expect_value(t, creds, "true")
	expose, _ := web.response_header(&res, "Access-Control-Expose-Headers")
	testing.expect_value(t, expose, "X-Total-Count")
	testing.expect_value(t, string(web.buf_slice(&res.body)), "ok")

	// an origin outside the allow-list gets no CORS headers at all, but the
	// request is still served
	req_bad := web.Request {
		method  = .Get,
		path    = "/api/users",
		target  = "/api/users",
		headers = []web.Header{web.Header{key = "Origin", value = "https://evil.example"}},
	}
	res_bad: web.Response
	mw_env_call(&e, &req_bad, &res_bad)
	_, has_acao := web.response_header(&res_bad, "Access-Control-Allow-Origin")
	testing.expect(t, !has_acao)
	testing.expect_value(t, string(web.buf_slice(&res_bad.body)), "ok")
}

// ---------------------------------------------------------------------------
// basic auth
// ---------------------------------------------------------------------------

@(test)
test_middleware_basic_auth :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Basic_Auth_Config{username = "root", password = "s3cret", realm = "molly"}
	web.router_use(&e.router, middleware_basic_auth, &cfg)
	web.router_get(&e.router, "/private", dummy_handler)

	// no credentials
	req := web.Request {
		method = .Get,
		path   = "/private",
		target = "/private",
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Unauthorized)
	www, _ := web.response_header(&res, "WWW-Authenticate")
	testing.expect_value(t, www, `Basic realm="molly"`)
	testing.expect(t, !strings.contains(string(web.buf_slice(&res.body)), "ok"))

	// correct credentials
	encoded := base64.encode(tb("root:s3cret"))
	defer delete(encoded, context.allocator)
	value := strings.concatenate({"Basic ", encoded})
	defer delete(value, context.allocator)
	req_ok := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []web.Header{web.Header{key = "Authorization", value = value}},
	}
	res_ok: web.Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_ok.body)), "ok")

	// wrong password
	bad_encoded := base64.encode(tb("root:nope"))
	defer delete(bad_encoded, context.allocator)
	bad_value := strings.concatenate({"Basic ", bad_encoded})
	defer delete(bad_value, context.allocator)
	req_bad := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []web.Header{web.Header{key = "Authorization", value = bad_value}},
	}
	res_bad: web.Response
	mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, web.Status.Unauthorized)
}

// ---------------------------------------------------------------------------
// body limit
// ---------------------------------------------------------------------------

@(test)
test_middleware_body_limit :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Body_Limit_Config{max_bytes = 10}
	web.router_use(&e.router, middleware_body_limit, &cfg)
	web.router_post(&e.router, "/upload", dummy_handler)

	req := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []web.Header{web.Header{key = "Content-Length", value = "100"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Payload_Too_Large)
	testing.expect(t, !strings.contains(string(web.buf_slice(&res.body)), "ok"))

	// under the limit the chain continues
	req_ok := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []web.Header{web.Header{key = "Content-Length", value = "10"}},
	}
	res_ok: web.Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_ok.body)), "ok")
}

// ---------------------------------------------------------------------------
// header middleware
// ---------------------------------------------------------------------------

@(test)
test_middleware_headers :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_secure_headers)
	web.router_use(&e.router, middleware_no_cache)
	web.router_get(&e.router, "/x", dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/x",
		target = "/x",
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	if v, ok := web.response_header(&res, "X-Content-Type-Options"); testing.expect(t, ok) {
		testing.expect_value(t, v, "nosniff")
	}
	if v, ok := web.response_header(&res, "X-Frame-Options"); testing.expect(t, ok) {
		testing.expect_value(t, v, "SAMEORIGIN")
	}
	if v, ok := web.response_header(&res, "Referrer-Policy"); testing.expect(t, ok) {
		testing.expect_value(t, v, "no-referrer")
	}
	if v, ok := web.response_header(&res, "Cache-Control"); testing.expect(t, ok) {
		testing.expect(t, strings.contains(v, "no-store"))
	}
}

@(test)
test_middleware_secure_headers_configured :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// only the fields a caller fills in are sent
	cfg := Secure_Headers_Config {
		content_security_policy = "default-src 'self'",
		frame_options           = "DENY",
	}
	web.router_use(&e.router, middleware_secure_headers, &cfg)
	web.router_get(&e.router, "/x", dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/x",
		target = "/x",
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	csp, _ := web.response_header(&res, "Content-Security-Policy")
	testing.expect_value(t, csp, "default-src 'self'")
	frame, _ := web.response_header(&res, "X-Frame-Options")
	testing.expect_value(t, frame, "DENY")
	_, has_nosniff := web.response_header(&res, "X-Content-Type-Options")
	testing.expect(t, !has_nosniff)
}

// ---------------------------------------------------------------------------
// access log
// ---------------------------------------------------------------------------

@(test)
test_middleware_logger_passes_through :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_request_id)
	web.router_use(&e.router, middleware_logger)
	web.router_get(&e.router, "/logged", dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/logged",
		target = "/logged",
	}
	res: web.Response
	mw_env_call(&e, &req, &res)

	// the log line itself is best-effort output; the contract under test is
	// that the chain still produces the handler's response
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "ok")
	testing.expect_value(t, len(req.id), 24)
}
