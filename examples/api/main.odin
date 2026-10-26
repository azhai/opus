package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "../../web"
import "../../web/middlewares"

/*
REST-ish API demo: router with params, Lua-pattern captures, cookies,
JSON binding/responses, plus the built-in request-id and access-log
middleware.

	odin run examples/api -- 127.0.0.1:8080     # address is optional

	curl localhost:8080/
	curl localhost:8080/users
	curl localhost:8080/users/42
	curl -X POST localhost:8080/users -H 'Content-Type: application/json' -d '{"name":"ada"}'
	curl localhost:8080/orders/2024/42          # (%d+) pattern captures
	curl -b 'token=xyz' localhost:8080/whoami   # request cookie
	curl -i localhost:8080/login                # Set-Cookie in response
	curl localhost:8080/stats                   # response_json
	curl -i localhost:8080/nope                 # JSON 404 from router.not_found
*/

router: web.Router

Index_Info :: struct {
	service: string,
	routes:  []string,
}

User :: struct {
	id:   int,
	name: string,
}

Create_User :: struct {
	name: string,
}

Created_User :: struct {
	created: bool,
	user:    User,
}

Order :: struct {
	year: string,
	code: string,
}

Stats :: struct {
	service: string,
	version: int,
	alive:   bool,
}

// Error is the one body every failure returns, so clients can branch on the
// status and still read a machine-friendly message.
Error :: struct {
	error: string,
}

fail :: proc(res: ^web.Response, status: web.Status, message: string) {
	web.response_json_status(res, status, Error{error = message})
}

// not_found is installed as router.not_found: unmatched paths get the same
// JSON shape as handler errors instead of the default plain-text 404.
not_found :: proc(req: ^web.Request, res: ^web.Response) {
	fail(res, .Not_Found, "not found")
}

main :: proc() {
	web.router_init(&router)

	// cross-cutting concerns come from the middlewares package
	web.router_use(&router, middlewares.middleware_request_id, nil)
	web.router_use(&router, middlewares.middleware_logger, nil)
	// unmatched paths answer in the same shape as the API handlers
	router.not_found = not_found

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
	fmt.printf("serving on http://%v\n", address)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}

index :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_json(res, Index_Info{
		service = "odin-web",
		routes  = []string{"/users", "/users/:id", "/orders/(%d+)/(%w+)"},
	})
}

list_users :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_json(res, []User{
		{id = 1, name = "ada"},
		{id = 2, name = "grace"},
	})
}

get_user :: proc(req: ^web.Request, res: ^web.Response) {
	raw, ok := web.request_param(req, "id")
	if !ok {
		fail(res, .Bad_Request, "missing id")
		return
	}
	id, is_int := strconv.parse_int(raw)
	if !is_int {
		fail(res, .Bad_Request, "id must be an integer")
		return
	}
	web.response_json(res, User{id = int(id), name = "ada"})
}

create_user :: proc(req: ^web.Request, res: ^web.Response) {
	if web.request_content_type(req) != "application/json" {
		fail(res, .Unsupported_Media, "expected application/json")
		return
	}
	input: Create_User
	if err := web.request_json(req, &input); err != nil {
		fail(res, .Bad_Request, "invalid JSON body")
		return
	}
	web.response_json_status(res, .Created, Created_User{
		created = true,
		user    = User{id = 3, name = input.name},
	})
}

get_order :: proc(req: ^web.Request, res: ^web.Response) {
	year, _ := web.request_capture(req, 1)
	code, _ := web.request_capture(req, 2)
	web.response_json(res, Order{year = year, code = code})
}

whoami :: proc(req: ^web.Request, res: ^web.Response) {
	token, ok := web.request_cookie(req, "token")
	if !ok {
		web.response_error(res, .Unauthorized, "no token cookie\n")
		return
	}
	buf: [128]byte
	web.response_text(res, .OK, fmt.bprintf(buf[:], "hello %v\n", token))
}

login :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_cookie(res, web.Cookie{
		name      = "token",
		value     = "xyz",
		path      = "/",
		http_only = true,
		same_site = .Lax,
	})
	web.response_text(res, .OK, "logged in\n")
}

stats :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_json(res, Stats{service = "odin-web", version = 2, alive = true})
}
