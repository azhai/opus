package common

import "../../web"
import "core:encoding/base64"
import "core:mem"
import "core:strings"
import "core:testing"
import "../../buffer"
import "../../http"
import "../../testenv"

// Tests for the built-in middleware. Each one drives a real `router_handle`
// dispatch over a synthetic connection (no socket involved), so the
// registration order, the chain and the short-circuits are all exercised the
// way a server would run them.








// ---------------------------------------------------------------------------
// request id
// ---------------------------------------------------------------------------

request_id_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, web.request_id(req))
}

@(test)
test_middleware_request_id :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_request_id)
	web.router_get(&e.router, "/id", request_id_handler)

	req := web.Request {
		method = .Get,
		path   = "/id",
		target = "/id",
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	generated, ok := web.response_header(&res, REQUEST_ID_HEADER)
	testing.expect(t, ok)
	testing.expect_value(t, len(generated), 24) // 16 hex nanos + 8 hex counter
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), generated)

	// an inbound id (set by a front proxy) is reused verbatim
	req2 := web.Request {
		method  = .Get,
		path    = "/id",
		target  = "/id",
		headers = []http.Header{http.Header{key = "X-Request-Id", value = "from-proxy"}},
	}
	res2: web.Response
	testenv.mw_env_call(&e, &req2, &res2)
	testing.expect_value(t, string(buffer.buf_slice(&res2.body)), "from-proxy")
	hdr2, _ := web.response_header(&res2, REQUEST_ID_HEADER)
	testing.expect_value(t, hdr2, "from-proxy")
}

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

@(test)
test_middleware_cors_preflight :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_cors)
	// GET-only route: the preflight is an OPTIONS request that no route
	// registered, which is exactly the case CORS middleware has to answer.
	web.router_get(&e.router, "/api/users", testenv.dummy_handler)

	req := web.Request {
		method  = .Options,
		path    = "/api/users",
		target  = "/api/users",
		headers = []http.Header {
			http.Header{key = "Origin", value = "https://app.example"},
			http.Header{key = "Access-Control-Request-Method", value = "POST"},
			http.Header{key = "Access-Control-Request-Headers", value = "content-type"},
		},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	testing.expect_value(t, res.status, http.Status.No_Content)
	acao, _ := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect_value(t, acao, "*") // no credentials configured
	acam, _ := web.response_header(&res, "Access-Control-Allow-Methods")
	testing.expect(t, strings.contains(acam, "POST"))
	acah, has_acah := web.response_header(&res, "Access-Control-Allow-Headers")
	testing.expect(t, has_acah)
	testing.expect_value(t, acah, "content-type") // mirrored from the request
	// the route handler must not have run
	testing.expect_value(t, buffer.buf_len(&res.body), 0)
}

@(test)
test_middleware_cors_credentials :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := CORS_Config {
		origins           = []string{"https://admin.example"},
		allow_credentials = true,
		expose_headers    = "X-Total-Count",
		max_age_secs      = 600,
	}
	web.router_use(&e.router, middleware_cors, &cfg)
	web.router_get(&e.router, "/api/users", testenv.dummy_handler)

	req := web.Request {
		method  = .Get,
		path    = "/api/users",
		target  = "/api/users",
		headers = []http.Header{http.Header{key = "Origin", value = "https://admin.example"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	acao, _ := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect_value(t, acao, "https://admin.example") // echoed, not "*"
	vary, _ := web.response_header(&res, "Vary")
	testing.expect(t, strings.contains(vary, "Origin"))
	creds, _ := web.response_header(&res, "Access-Control-Allow-Credentials")
	testing.expect_value(t, creds, "true")
	expose, _ := web.response_header(&res, "Access-Control-Expose-Headers")
	testing.expect_value(t, expose, "X-Total-Count")
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "ok")

	// an origin outside the allow-list gets no CORS headers at all, but the
	// request is still served
	req_bad := web.Request {
		method  = .Get,
		path    = "/api/users",
		target  = "/api/users",
		headers = []http.Header{http.Header{key = "Origin", value = "https://evil.example"}},
	}
	res_bad: web.Response
	testenv.mw_env_call(&e, &req_bad, &res_bad)
	_, has_acao := web.response_header(&res_bad, "Access-Control-Allow-Origin")
	testing.expect(t, !has_acao)
	testing.expect_value(t, string(buffer.buf_slice(&res_bad.body)), "ok")
}

// ---------------------------------------------------------------------------
// basic auth
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// body limit
// ---------------------------------------------------------------------------

@(test)
test_middleware_body_limit :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Body_Limit_Config{max_bytes = 10}
	web.router_use(&e.router, middleware_body_limit, &cfg)
	web.router_post(&e.router, "/upload", testenv.dummy_handler)

	req := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []http.Header{http.Header{key = "Content-Length", value = "100"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Payload_Too_Large)
	testing.expect(t, !strings.contains(string(buffer.buf_slice(&res.body)), "ok"))

	// under the limit the chain continues
	req_ok := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []http.Header{http.Header{key = "Content-Length", value = "10"}},
	}
	res_ok: web.Response
	testenv.mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_ok.body)), "ok")
}

// ---------------------------------------------------------------------------
// header middleware
// ---------------------------------------------------------------------------

@(test)
test_middleware_headers :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_secure_headers)
	web.router_use(&e.router, middleware_no_cache)
	web.router_get(&e.router, "/x", testenv.dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/x",
		target = "/x",
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

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
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	// only the fields a caller fills in are sent
	cfg := Secure_Headers_Config {
		content_security_policy = "default-src 'self'",
		frame_options           = "DENY",
	}
	web.router_use(&e.router, middleware_secure_headers, &cfg)
	web.router_get(&e.router, "/x", testenv.dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/x",
		target = "/x",
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

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
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_request_id)
	web.router_use(&e.router, middleware_logger)
	web.router_get(&e.router, "/logged", testenv.dummy_handler)

	req := web.Request {
		method = .Get,
		path   = "/logged",
		target = "/logged",
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	// the log line itself is best-effort output; the contract under test is
	// that the chain still produces the handler's response
	testing.expect_value(t, res.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "ok")
	testing.expect_value(t, len(req.id), 24)
}

@(test)
test_middleware_cors_plain_request :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_cors)
	web.router_get(&e.router, "/plain", testenv.dummy_handler)

	// same-origin request: no Origin header, so nothing to negotiate and no
	// CORS headers are added
	req := web.Request{method = .Get, path = "/plain", target = "/plain"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	_, has_acao := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect(t, !has_acao)
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "ok")
}

@(test)
test_middleware_cors_disallowed_preflight :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := CORS_Config{origins = []string{"https://admin.example"}}
	web.router_use(&e.router, middleware_cors, &cfg)
	web.router_get(&e.router, "/api/users", testenv.dummy_handler)

	req := web.Request {
		method  = .Options,
		path    = "/api/users",
		target  = "/api/users",
		headers = []http.Header {
			http.Header{key = "Origin", value = "https://evil.example"},
			http.Header{key = "Access-Control-Request-Method", value = "POST"},
		},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	// no CORS grant, and no route answers OPTIONS either
	_, has_acao := web.response_header(&res, "Access-Control-Allow-Origin")
	testing.expect(t, !has_acao)
	testing.expect_value(t, res.status, http.Status.Method_Not_Allowed)
}

@(test)
test_middleware_cors_preflight_without_requested_headers :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_cors)
	web.router_get(&e.router, "/api/users", testenv.dummy_handler)

	req := web.Request {
		method  = .Options,
		path    = "/api/users",
		target  = "/api/users",
		headers = []http.Header {
			http.Header{key = "Origin", value = "https://app.example"},
			http.Header{key = "Access-Control-Request-Method", value = "PUT"},
		},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	testing.expect_value(t, res.status, http.Status.No_Content)
	methods, _ := web.response_header(&res, "Access-Control-Allow-Methods")
	testing.expect(t, strings.contains(methods, "PUT"))
	// nothing was requested, so the mirror is empty and the header is absent
	_, has_acah := web.response_header(&res, "Access-Control-Allow-Headers")
	testing.expect(t, !has_acah)
}


// ---------------------------------------------------------------------------
// auth fail-open
// ---------------------------------------------------------------------------


// ---------------------------------------------------------------------------
// body limit
// ---------------------------------------------------------------------------

@(test)
test_middleware_body_limit_without_length :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Body_Limit_Config{max_bytes = 10}
	web.router_use(&e.router, middleware_body_limit, &cfg)
	web.router_post(&e.router, "/upload", testenv.dummy_handler)

	// a chunked body has no length up front: this middleware cannot judge it
	req := web.Request{method = .Post, path = "/upload", target = "/upload"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)

	// a malformed length is not a reason to reject either
	req_bad := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []http.Header{http.Header{key = "Content-Length", value = "lots"}},
	}
	res_bad: web.Response
	testenv.mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, http.Status.OK)

	// a value straddling whitespace is still parsed
	req_pad := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []http.Header{http.Header{key = "Content-Length", value = " 50 "}},
	}
	res_pad: web.Response
	testenv.mw_env_call(&e, &req_pad, &res_pad)
	testing.expect_value(t, res_pad.status, http.Status.Payload_Too_Large)
}

@(test)
test_middleware_no_buffer :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_no_buffer)
	web.router_get(&e.router, "/s", testenv.dummy_handler)

	req := web.Request{method = .Get, path = "/s", target = "/s"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)

	if v, ok := web.response_header(&res, "X-Accel-Buffering"); testing.expect(t, ok) {
		testing.expect_value(t, v, "no")
	}
	if v, ok := web.response_header(&res, "Cache-Control"); testing.expect(t, ok) {
		testing.expect(t, strings.contains(v, "no-transform"))
	}
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "ok")
}

