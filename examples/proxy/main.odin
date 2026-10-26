package main

import "core:fmt"
import "core:os"
import "../../web"

/*
Reverse proxy demo: everything under /api is forwarded to an upstream
HTTP server with the prefix stripped; /health is answered locally.

Run an upstream first (e.g. the api example on :9000), then:

	odin run examples/proxy                             # upstream :9000, listen :8080
	odin run examples/proxy -- 127.0.0.1:9000 127.0.0.1:8090
	curl --noproxy '*' localhost:8080/health
	curl --noproxy '*' localhost:8080/api/users/42   # -> upstream GET /users/42

The proxy keeps idle upstream connections alive between requests, so repeated
calls reuse one upstream socket instead of dialing each time.
*/

proxy: web.Proxy
router: web.Router

main :: proc() {
	upstream := "127.0.0.1:9000"
	listen := "0.0.0.0:8080"
	if len(os.args) > 1 {
		upstream = os.args[1]
	}
	if len(os.args) > 2 {
		listen = os.args[2]
	}

	if !web.proxy_init(&proxy, {upstream}) {
		fmt.eprintfln("invalid upstream: %v", upstream)
		return
	}
	proxy.strip_prefix = "/api"

	web.router_init(&router)
	web.router_get(&router, "/health", health)
	// catch-all under /api: forward into the proxy (every method)
	web.router_all(&router, "/api/" + "*", api_forward)

	srv: web.Server
	if !web.server_init(&srv, listen) {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	// Idle upstream connections live in the proxy's pool and are owned by
	// the event loop, so they must be closed on the loop thread once the
	// loop stops.
	srv.on_stop = proc(s: ^web.Server) {
		web.proxy_close_idle(&proxy)
	}
	fmt.printf("proxying /api -> %v on %v\n", upstream, listen)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}

health :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_text(res, .OK, "ok\n")
}

api_forward :: proc(req: ^web.Request, res: ^web.Response) {
	web.proxy_serve_root(&proxy, req, res)
}
