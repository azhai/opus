package auth

// Tests for the header-based auth middleware (bearer tokens, API keys) and the
// principal they install on the request.

import "../../web"
import "core:mem"
import "core:strings"
import "core:testing"
import "../../buffer"
import "../../http"
import "../../testenv"
import "../token"
import "core:encoding/base64"

principal_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, "user=")
	web.response_write_string(res, request_principal(req))
}

@(test)
test_middleware_bearer_auth :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Bearer_Auth_Config {
		tokens = []Auth_Token{
			Auth_Token{token = "tok_live_1", name = "deploy-bot"},
			Auth_Token{token = "tok_live_2", name = "reporting"},
		},
		realm = "metrics",
	}
	web.router_use(&e.router, middleware_bearer_auth, &cfg)
	web.router_get(&e.router, "/m", principal_handler)

	// no credentials: a challenge, no `error` code (RFC 6750 section 3)
	req := web.Request{method = .Get, path = "/m", target = "/m"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Unauthorized)
	if www, ok := web.response_header(&res, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics"`)
	}

	// a wrong token names the failure
	req_bad := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []http.Header{http.Header{key = "Authorization", value = "Bearer nope"}},
	}
	res_bad: web.Response
	testenv.mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, http.Status.Unauthorized)
	if www, ok := web.response_header(&res_bad, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics", error="invalid_token"`)
	}

	// the second token maps to its own principal
	req_ok := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []http.Header{http.Header{key = "Authorization", value = "Bearer tok_live_2"}},
	}
	res_ok: web.Response
	testenv.mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_ok.body)), "user=reporting")

	// a different scheme does not authenticate
	req_basic := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []http.Header{http.Header{key = "Authorization", value = "Basic abc"}},
	}
	res_basic: web.Response
	testenv.mw_env_call(&e, &req_basic, &res_basic)
	testing.expect_value(t, res_basic.status, http.Status.Unauthorized)
}

@(test)
test_middleware_api_key :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := API_Key_Config {
		tokens = []Auth_Token{Auth_Token{token = "key-1", name = "svc-a"}},
		query  = "api_key",
	}
	web.router_use(&e.router, middleware_api_key, &cfg)
	web.router_get(&e.router, "/k", principal_handler)

	// header form
	req := web.Request {
		method  = .Get,
		path    = "/k",
		target  = "/k",
		headers = []http.Header{http.Header{key = "X-API-Key", value = "key-1"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "user=svc-a")

	// query fallback
	req_q := web.Request{method = .Get, path = "/k", target = "/k?api_key=key-1", query = "api_key=key-1"}
	res_q: web.Response
	testenv.mw_env_call(&e, &req_q, &res_q)
	testing.expect_value(t, res_q.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_q.body)), "user=svc-a")

	// nothing presented
	req_none := web.Request{method = .Get, path = "/k", target = "/k"}
	res_none: web.Response
	testenv.mw_env_call(&e, &req_none, &res_none)
	testing.expect_value(t, res_none.status, http.Status.Unauthorized)
	if www, ok := web.response_header(&res_none, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `ApiKey realm="api"`)
	}
}

@(test)
test_middleware_basic_auth :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Basic_Auth_Config{username = "root", password = "s3cret", realm = "molly"}
	web.router_use(&e.router, middleware_basic_auth, &cfg)
	web.router_get(&e.router, "/private", testenv.dummy_handler)

	// no credentials
	req := web.Request {
		method = .Get,
		path   = "/private",
		target = "/private",
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Unauthorized)
	www, _ := web.response_header(&res, "WWW-Authenticate")
	testing.expect_value(t, www, `Basic realm="molly"`)
	testing.expect(t, !strings.contains(string(buffer.buf_slice(&res.body)), "ok"))

	// correct credentials
	encoded := base64.encode(testenv.tb("root:s3cret"))
	defer delete(encoded, context.allocator)
	value := strings.concatenate({"Basic ", encoded})
	defer delete(value, context.allocator)
	req_ok := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []http.Header{http.Header{key = "Authorization", value = value}},
	}
	res_ok: web.Response
	testenv.mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_ok.body)), "ok")

	// wrong password
	bad_encoded := base64.encode(testenv.tb("root:nope"))
	defer delete(bad_encoded, context.allocator)
	bad_value := strings.concatenate({"Basic ", bad_encoded})
	defer delete(bad_value, context.allocator)
	req_bad := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []http.Header{http.Header{key = "Authorization", value = bad_value}},
	}
	res_bad: web.Response
	testenv.mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, http.Status.Unauthorized)
}

@(test)
test_middleware_basic_auth_fails_open :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Basic_Auth_Config{password = "s3cret"} // no username: disabled
	web.router_use(&e.router, middleware_basic_auth, &cfg)
	web.router_get(&e.router, "/private", testenv.dummy_handler)

	req := web.Request{method = .Get, path = "/private", target = "/private"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "ok")
}

@(test)
test_middleware_bearer_auth_fails_open :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Bearer_Auth_Config{} // no tokens: disabled
	web.router_use(&e.router, middleware_bearer_auth, &cfg)
	web.router_get(&e.router, "/api", testenv.dummy_handler)

	req := web.Request{method = .Get, path = "/api", target = "/api"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)
}

@(test)
test_router_use_route :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Bearer_Auth_Config {
		tokens = []Auth_Token{Auth_Token{token = "tok", name = "svc"}},
	}

	// Register every route first: a later router_add may move the table and
	// invalidate route pointers (documented on router_use_route).
	web.router_get(&e.router, "/open", principal_handler)
	private := web.router_get(&e.router, "/private", principal_handler)
	web.router_use_route(private, middleware_bearer_auth, &cfg)

	// the guarded route needs a token...
	req := web.Request{method = .Get, path = "/private", target = "/private"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Unauthorized)

	// ...and runs the handler once one is presented
	req_ok := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []http.Header{http.Header{key = "Authorization", value = "Bearer tok"}},
	}
	res_ok: web.Response
	testenv.mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_ok.body)), "user=svc")

	// the unguarded route is untouched by the route middleware
	req_open := web.Request{method = .Get, path = "/open", target = "/open"}
	res_open: web.Response
	testenv.mw_env_call(&e, &req_open, &res_open)
	testing.expect_value(t, res_open.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res_open.body)), "user=")
}
