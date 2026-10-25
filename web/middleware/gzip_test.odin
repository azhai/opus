package middleware

import ".."
import "core:mem"
import "core:testing"

// Tests for the per-route compression switch. The middleware sets the
// response's override; the filter that reads it is exercised by the parent
// package's integration tests, which is where the coded bytes are checked.

@(test)
test_middleware_gzip_sets_override :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_get(&e.router, "/plain", dummy_handler)
	force := web.router_get(&e.router, "/force", dummy_handler)
	tuned := web.router_get(&e.router, "/tuned", dummy_handler)
	denied := web.router_get(&e.router, "/deny", dummy_handler)

	tuned_cfg := Gzip_Config{min_size = 100}
	web.router_use_route(force, middleware_gzip, nil)
	web.router_use_route(tuned, middleware_gzip, &tuned_cfg)
	web.router_use_route(denied, middleware_no_gzip)

	req := web.Request{method = .Get, path = "/plain", target = "/plain"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.compress, web.Compress_Mode.Default)

	req_force := web.Request{method = .Get, path = "/force", target = "/force"}
	res_force: web.Response
	mw_env_call(&e, &req_force, &res_force)
	testing.expect_value(t, res_force.compress, web.Compress_Mode.Force)
	testing.expect_value(t, res_force.compress_min, 0)

	req_tuned := web.Request{method = .Get, path = "/tuned", target = "/tuned"}
	res_tuned: web.Response
	mw_env_call(&e, &req_tuned, &res_tuned)
	testing.expect_value(t, res_tuned.compress, web.Compress_Mode.Default)
	testing.expect_value(t, res_tuned.compress_min, 100)

	req_deny := web.Request{method = .Get, path = "/deny", target = "/deny"}
	res_deny: web.Response
	mw_env_call(&e, &req_deny, &res_deny)
	testing.expect_value(t, res_deny.compress, web.Compress_Mode.Deny)
}
