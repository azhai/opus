package main

import "core:fmt"
import "core:os"
import "../../web"

/*
REST-ish API demo: router with params, Lua-pattern captures, cookies,
JSON responses and a logging middleware.

	odin run examples/api -- 127.0.0.1:9000     # address is optional

	curl localhost:8080/
	odin run examples/api -- 127.0.0.1:9000     # address is optional

	curl localhost:8080/users
	odin run examples/api -- 127.0.0.1:9000     # address is optional

	curl localhost:8080/users/42
	curl -X POST localhost:8080/users -d '{"name":"ada"}'
	odin run examples/api -- 127.0.0.1:9000     # address is optional

	curl localhost:8080/orders/2024/42          # (%d+) pattern captures
	curl -b 'token=xyz' localhost:8080/whoami   # request cookie
	curl -i localhost:8080/login                # Set-Cookie in response
*/

router: web.Router

main :: proc() {
	web.router_init(&router)

	web.router_use(&router, request_logger, nil)

	web.router_get(&router, "/", index)
	web.router_get(&router, "/users", list_users)
	web.router_get(&router, "/users/:id", get_user)
	web.router_post(&router, "/users", create_user)

	// Lua-pattern route: captures are positional, 1-based
	web.router_get(&router, "/orders/(%d+)/(%w+)", get_order)
	// cookies: read from the request, write with response_set_cookie
	web.router_get(&router, "/whoami", whoami)
	web.router_get(&router, "/login", login)
	// JSON marshalling straight from Odin values
	web.router_get(&router, "/stats", stats)

	address := "0.0.0.0:8080"
	if len(os.args) > 1 {
		address = os.args[1]
	}

	srv: web.Server
	if !web.server_init(&srv, address) {
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

Order :: struct {
	year: string,
	code: string,
}

get_order :: proc(req: ^web.Request, res: ^web.Response) {
	year, _ := web.request_capture(req, 1)
	code, _ := web.request_capture(req, 2)
	web.response_json(res, Order{year = year, code = code})
}

whoami :: proc(req: ^web.Request, res: ^web.Response) {
	token, ok := web.request_cookie(req, "token")
	if !ok {
		web.response_status(res, .Unauthorized)
		web.response_write_string(res, "no token cookie\n")
		return
	}
	web.response_write_string(res, "hello ")
	web.response_write_string(res, token)
	web.response_write_string(res, "\n")
}

login :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_cookie(res, web.Cookie{
		name      = "token",
		value     = "xyz",
		path      = "/",
		http_only = true,
		same_site = .Lax,
	})
	web.response_write_string(res, "logged in\n")
}

Stats :: struct {
	service: string,
	version: int,
	alive:   bool,
}

stats :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_json(res, Stats{service = "odin-web", version = 2, alive = true})
}
