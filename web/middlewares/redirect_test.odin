package middlewares

import ".."
import "core:mem"
import "core:strings"
import "core:testing"

// Tests for the redirect middleware: the status, the Location it builds, and
// the fact that a non-matching request is left alone.

redirect_rules := []Redirect_Rule {
	Redirect_Rule{from = "/old", to = "/new", code = .Moved_Permanently},
	Redirect_Rule{from = "/exactly", to = "/target", exact = true},
	Redirect_Rule{from = "/gone", to = "https://example.com/gone"},
}

redirect_cfg := Redirect_Config{rules = redirect_rules}

@(test)
test_middleware_redirect_prefix :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_redirect, &redirect_cfg)
	web.router_get(&e.router, "/new/a/b", dummy_handler)

	// the suffix and the query survive the move
	req := web.Request{method = .Get, path = "/old/a/b", target = "/old/a/b?x=1", query = "x=1"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Moved_Permanently)
	if loc, ok := web.response_header(&res, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "/new/a/b?x=1")
	}
	// the target is answered on the next request: this response is only the
	// redirect (with a body, so a client that ignores Location still sees it)
	testing.expect(t, strings.contains(string(web.buf_slice(&res.body)), "/new/a/b?x=1"))
}

@(test)
test_middleware_redirect_exact_and_absolute :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_redirect, &redirect_cfg)
	web.router_get(&e.router, "/other", dummy_handler)

	// an exact rule does not match a longer path, and the default status is
	// 308 (permanent, method-preserving)
	req := web.Request{method = .Post, path = "/exactly", target = "/exactly"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Permanent_Redirect)
	if loc, ok := web.response_header(&res, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "/target")
	}

	// an absolute target is used as-is: no suffix is appended to a foreign host
	req_abs := web.Request{method = .Get, path = "/gone/x", target = "/gone/x"}
	res_abs: web.Response
	mw_env_call(&e, &req_abs, &res_abs)
	if loc, ok := web.response_header(&res_abs, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "https://example.com/gone")
	}

	// no rule matched: the chain continues to the route
	req_other := web.Request{method = .Get, path = "/other", target = "/other"}
	res_other: web.Response
	mw_env_call(&e, &req_other, &res_other)
	testing.expect_value(t, res_other.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_other.body)), "ok")
}

@(test)
test_middleware_redirect_no_double_slash :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// a target that already ends in a slash must not gain a second one when
	// the suffix is appended: "//index.html" would be a protocol-relative URL
	rules := []Redirect_Rule{Redirect_Rule{from = "/docs", to = "/assets/"}}
	cfg := Redirect_Config{rules = rules}
	web.router_use(&e.router, middleware_redirect, &cfg)
	web.router_get(&e.router, "/assets/index.html", dummy_handler)

	req := web.Request{method = .Get, path = "/docs/index.html", target = "/docs/index.html"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	if loc, ok := web.response_header(&res, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "/assets/index.html")
	}
}

@(test)
test_middleware_https_redirect :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_https_redirect, nil)
	web.router_get(&e.router, "/x", dummy_handler)

	// the host comes from the request: https on the usual port, so no port
	hdrs: [1]web.Header
	hdrs[0] = web.Header{key = "Host", value = "example.com"}
	req := web.Request{method = .Get, path = "/x", target = "/x?a=1", query = "a=1", headers = hdrs[:]}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Permanent_Redirect)
	if loc, ok := web.response_header(&res, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "https://example.com/x?a=1")
	}

	// a non-default port is spelled out
	port_cfg := Https_Redirect_Config{port = 8443}
	e2: Mw_Env
	mw_env_init(&e2)
	defer mw_env_destroy(&e2)
	web.router_use(&e2.router, middleware_https_redirect, &port_cfg)
	web.router_get(&e2.router, "/x", dummy_handler)
	req2 := web.Request{method = .Get, path = "/x", target = "/x", headers = hdrs[:]}
	res2: web.Response
	mw_env_call(&e2, &req2, &res2)
	if loc, ok := web.response_header(&res2, "Location"); testing.expect(t, ok) {
		testing.expect_value(t, loc, "https://example.com:8443/x")
	}
}
