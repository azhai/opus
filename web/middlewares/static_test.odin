package middlewares

import ".."
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:testing"

// Tests for the static mount middleware: serving a real directory out of the
// repo, falling through when the file is not there, and the SPA fallback.
// The mount reuses the parent package's stat cache and sendfile, so a served
// file shows up as `res.file_open`, not as a body.

static_root := "examples/www"

@(test)
test_middleware_static_serves_file :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// opening a file for sendfile goes through the event loop, so the test
	// thread has to own one even though no socket is involved
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()

	st: web.Static
	web.static_init(&st, static_root)
	defer web.static_destroy(&st)

	cfg := Static_Mount_Config{st = &st, prefix = "/assets"}
	route := web.router_get(&e.router, "/assets/*", dummy_handler)
	web.router_use_route(route, middleware_static, &cfg)

	req := web.Request{method = .Get, path = "/assets/css/a.css", target = "/assets/css/a.css"}
	res: web.Response
	mw_env_call(&e, &req, &res)

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, res.file_open) // zero-copy sendfile, not a buffered body
	testing.expect(t, strings.has_suffix(res.file_path, "css/a.css"))
	if ct, ok := web.response_header(&res, "Content-Type"); testing.expect(t, ok) {
		testing.expect(t, strings.has_prefix(ct, "text/css"))
	}
	if ar, ok := web.response_header(&res, "Accept-Ranges"); testing.expect(t, ok) {
		testing.expect_value(t, ar, "bytes")
	}
	// the rewritten path is restored: the access log must see what the client
	// asked for, not what the filesystem read
	testing.expect_value(t, req.path, "/assets/css/a.css")
}

@(test)
test_middleware_static_falls_through :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// opening a file for sendfile goes through the event loop, so the test
	// thread has to own one even though no socket is involved
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()

	st: web.Static
	web.static_init(&st, static_root)
	defer web.static_destroy(&st)

	cfg := Static_Mount_Config{st = &st, prefix = "/assets"}
	route := web.router_get(&e.router, "/assets/*", dummy_handler)
	web.router_use_route(route, middleware_static, &cfg)

	// a miss is not a 404 from the mount: the route (or a later one) decides
	req := web.Request{method = .Get, path = "/assets/nope.css", target = "/assets/nope.css"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, !res.file_open)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "ok")

	// the directory itself resolves to its index file
	req_out := web.Request{method = .Get, path = "/assets/", target = "/assets/"}
	res_out: web.Response
	mw_env_call(&e, &req_out, &res_out)
	testing.expect_value(t, res_out.status, web.Status.OK)
	testing.expect(t, res_out.file_open)
	testing.expect(t, strings.has_suffix(res_out.file_path, "index.html"))
}

@(test)
test_middleware_static_spa_fallback :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// opening a file for sendfile goes through the event loop, so the test
	// thread has to own one even though no socket is involved
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()

	st: web.Static
	web.static_init(&st, static_root)
	defer web.static_destroy(&st)

	cfg := Static_Mount_Config{st = &st, spa = true}
	route := web.router_get(&e.router, "/*", dummy_handler)
	web.router_use_route(route, middleware_static, &cfg)

	// a client-side route the server has never heard of renders the shell
	req := web.Request{method = .Get, path = "/app/settings/billing", target = "/app/settings/billing"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, res.file_open)
	testing.expect(t, strings.has_suffix(res.file_path, "index.html"))
	testing.expect_value(t, req.path, "/app/settings/billing")

	// a real asset still wins over the fallback
	req_asset := web.Request{method = .Get, path = "/css/a.css", target = "/css/a.css"}
	res_asset: web.Response
	mw_env_call(&e, &req_asset, &res_asset)
	testing.expect(t, res_asset.file_open)
	testing.expect(t, strings.has_suffix(res_asset.file_path, "css/a.css"))
}
