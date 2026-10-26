package main

import "core:fmt"
import "../../web"

hello :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_text(res, .OK, "hello from odin web\n")
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
