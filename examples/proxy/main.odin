package main

import "core:fmt"
import "core:os"
import "../../web"

/*
Reverse proxy demo: everything under /api is forwarded to an upstream
HTTP server with the prefix stripped; /health is answered locally.

Run an upstream first (e.g. the api example on :9000), then:

	odin run examples/proxy -- 127.0.0.1:9000
	curl --noproxy '*' localhost:8080/health
	curl --noproxy '*' localhost:8080/api/users/42   # -> upstream GET /users/42
*/

proxy: web.Proxy
router: web.Router

main :: proc() {
	upstream := "127.0.0.1:9000"
	if len(os.args) > 1 {
		upstream = os.args[1]
	}

	if !web.proxy_init(&proxy, {upstream}) {
		fmt.eprintfln("invalid upstream: %v", upstream)
		return
	}
	proxy.strip_prefix = "/api"

	web.router_init(&router)
	web.router_get(&router, "/health", health)
	// catch-all under /api: forward into the proxy (every method)
	web.router_add(&router, .Get, "/api/" + "*", api_forward)
	web.router_add(&router, .Head, "/api/" + "*", api_forward)
	web.router_add(&router, .Post, "/api/" + "*", api_forward)
	web.router_add(&router, .Put, "/api/" + "*", api_forward)
	web.router_add(&router, .Delete, "/api/" + "*", api_forward)
	web.router_add(&router, .Patch, "/api/" + "*", api_forward)

	srv: web.Server
	if !web.server_init(&srv, "0.0.0.0:8080") {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.printf("proxying /api -> %v on http://0.0.0.0:8080\n", upstream)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}

health :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Content-Type", "text/plain")
	web.response_write_string(res, "ok\n")
}

api_forward :: proc(req: ^web.Request, res: ^web.Response) {
	web.proxy_serve_root(&proxy, req, res)
}
