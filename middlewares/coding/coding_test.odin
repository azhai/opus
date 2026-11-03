package coding

import "../../web"
import "core:testing"
import "../../testenv"

// Tests for the per-route coding switch. The middleware only sets the
// response's override; the filter that reads it is exercised by the parent
// package's integration tests, which is where the coded bytes are checked.

@(test)
test_middleware_coding_sets_override :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_get(&e.router, "/plain", testenv.dummy_handler)
	force := web.router_get(&e.router, "/force", testenv.dummy_handler)
	tuned := web.router_get(&e.router, "/tuned", testenv.dummy_handler)
	denied := web.router_get(&e.router, "/deny", testenv.dummy_handler)

	tuned_cfg := Coding_Config{min_size = 100}
	web.router_use_route(force, middleware_coding, nil)
	web.router_use_route(tuned, middleware_coding, &tuned_cfg)
	web.router_use_route(denied, middleware_no_coding)

	req := web.Request{method = .Get, path = "/plain", target = "/plain"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.coding, web.Coding_Mode.Default)

	req_force := web.Request{method = .Get, path = "/force", target = "/force"}
	res_force: web.Response
	testenv.mw_env_call(&e, &req_force, &res_force)
	testing.expect_value(t, res_force.coding, web.Coding_Mode.Force)
	testing.expect_value(t, res_force.coding_min_size, 0)

	req_tuned := web.Request{method = .Get, path = "/tuned", target = "/tuned"}
	res_tuned: web.Response
	testenv.mw_env_call(&e, &req_tuned, &res_tuned)
	testing.expect_value(t, res_tuned.coding, web.Coding_Mode.Default)
	testing.expect_value(t, res_tuned.coding_min_size, 100)

	req_deny := web.Request{method = .Get, path = "/deny", target = "/deny"}
	res_deny: web.Response
	testenv.mw_env_call(&e, &req_deny, &res_deny)
	testing.expect_value(t, res_deny.coding, web.Coding_Mode.Deny)
}
