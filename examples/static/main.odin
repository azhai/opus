package main

import "core:fmt"
import "core:os"
import "../../web"

/*
Static file serving with the stat cache + sendfile, plus one dynamic route.

	odin run examples/static -- ./examples/www
	curl localhost:8080/            -> examples/www/index.html
	curl localhost:8080/css/a.css   -> served with sendfile
	curl localhost:8080/time        -> dynamic handler
*/

router: web.Router
files: web.Static

main :: proc() {
	root := "./www"
	if len(os.args) > 1 {
		root = os.args[1]
	}
	address := "0.0.0.0:8080"
	if len(os.args) > 2 {
		address = os.args[2]
	}

	web.static_init(&files, root)
	web.router_init(&router)
	web.router_get(&router, "/time", current_time)
	// catch-all: everything else is a file under root
	web.router_get(&router, "/*", static_files)

	srv: web.Server
	if !web.server_init(&srv, address) {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.printf("serving %v on http://%v\n", root, address)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}

static_files :: proc(req: ^web.Request, res: ^web.Response) {
	web.static_serve_root(&files, req, res)
}

current_time :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_text(res, .OK, "the time is now\n")
}
