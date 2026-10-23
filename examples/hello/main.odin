package main

import "core:fmt"
import "../../web"

hello :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_status(res, .OK)
	web.response_set_header(res, "Content-Type", "text/plain; charset=utf-8")
	web.response_write_string(res, "hello from odin web\n")
}

main :: proc() {
	srv: web.Server
	if !web.server_init(&srv, "0.0.0.0:8080") {
		return
	}
	srv.handler = hello
	fmt.println("serving on http://0.0.0.0:8080")
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
