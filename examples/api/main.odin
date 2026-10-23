package main

import "core:fmt"
import "../../web"

/*
REST-ish API demo: router with params + a logging middleware.

	curl localhost:8080/
	curl localhost:8080/users
	curl localhost:8080/users/42
	curl -X POST localhost:8080/users -d '{"name":"ada"}'
*/

router: web.Router

main :: proc() {
	web.router_init(&router)

	web.router_use(&router, request_logger, nil)

	web.router_get(&router, "/", index)
	web.router_get(&router, "/users", list_users)
	web.router_get(&router, "/users/:id", get_user)
	web.router_post(&router, "/users", create_user)

	srv: web.Server
	if !web.server_init(&srv, "0.0.0.0:8080") {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.println("serving on http://0.0.0.0:8080")
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}

request_logger :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	fmt.printf("%v %v\n", req.method, req.path)
	web.router_next(r, idx + 1, final, req, res)
}

index :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Content-Type", "application/json")
	web.response_write_string(res, "{\"service\":\"odin-web\",\"routes\":[\"/users\",\"/users/:id\"]}\n")
}

list_users :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Content-Type", "application/json")
	web.response_write_string(res, "[{\"id\":1,\"name\":\"ada\"},{\"id\":2,\"name\":\"grace\"}]\n")
}

get_user :: proc(req: ^web.Request, res: ^web.Response) {
	id, ok := web.request_param(req, "id")
	if !ok {
		web.response_status(res, .Bad_Request)
		web.response_write_string(res, "missing id\n")
		return
	}
	web.response_set_header(res, "Content-Type", "application/json")
	web.response_write_string(res, "{\"id\":")
	web.response_write_string(res, id)
	web.response_write_string(res, ",\"name\":\"ada\"}\n")
}

create_user :: proc(req: ^web.Request, res: ^web.Response) {
	body := web.request_body_string(req)
	if len(body) == 0 {
		web.response_status(res, .Bad_Request)
		web.response_write_string(res, "empty body\n")
		return
	}
	web.response_status(res, .Created)
	web.response_set_header(res, "Content-Type", "application/json")
	web.response_write_string(res, "{\"created\":true,\"echo\":")
	web.response_write_string(res, body)
	web.response_write_string(res, "}\n")
}
