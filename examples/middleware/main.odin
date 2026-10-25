package main

/*
Purpose-built middleware: auth, form parsing, Range/ETag and SSE, each
attached to the one route that needs it instead of the whole router.

	odin run examples/middleware            # :8080
	odin run examples/middleware -- 127.0.0.1:9000

	curl -r 10-19        http://127.0.0.1:8080/report.csv
	curl -I              http://127.0.0.1:8080/report.csv     # ETag, Accept-Ranges
	curl -u admin:secret http://127.0.0.1:8080/admin
	curl -H 'X-API-Key: key-live-1' http://127.0.0.1:8080/api/keys
	curl -F name=ada -F avatar=@README.md http://127.0.0.1:8080/submit
	curl -N              http://127.0.0.1:8080/events
*/

import "core:fmt"
import "core:os"
import "../../web"

// Middleware configs outlive the server, so they live at file scope: a stack
// temporary would dangle as soon as main's scope changed.
admin_cfg := web.Basic_Auth_Config {
	username = "admin",
	password = "secret",
	realm    = "admin",
}

key_cfg := web.API_Key_Config {
	tokens = []web.Auth_Token{web.Auth_Token{token = "key-live-1", name = "mobile-app"}},
	header = "X-API-Key",
}

form_cfg := web.Form_Config {
	require_form  = true, // a JSON body on this route is a 415, not a surprise
	max_file_size = 1 << 20,
}

range_cfg := web.Range_Config {
	etag = true, // content hash + If-None-Match -> 304
}

index :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_content_type(res, "text/plain; charset=utf-8")
	web.response_write_string(res, `purpose-built middleware demo

  GET  /report.csv   Range + ETag over a generated body (middleware_range)
  GET  /admin        HTTP basic auth, route-local (middleware_basic_auth)
  GET  /api/keys     API key in X-API-Key (middleware_api_key)
  POST /submit       form parser, urlencoded or multipart (middleware_form)
  GET  /events       server-sent events (sse_*)

The access log line for each request carries the authenticated principal, so
a 401 and a 200 are attributable to the same token.
`)
}

// report is an ordinary handler: it knows nothing about Range or ETag.
report :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_content_type(res, "text/csv")
	web.response_write_string(res, "id,name,score\n")
	web.response_write_string(res, "1,ada,91\n")
	web.response_write_string(res, "2,grace,88\n")
	web.response_write_string(res, "3,linus,73\n")
}

admin :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [128]byte
	msg := fmt.bprintf(buf[:], "admin area, user=%v\n", web.request_principal(req))
	web.response_text(res, .OK, msg)
}

keys :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [128]byte
	msg := fmt.bprintf(buf[:], "key accepted for %v\n", web.request_principal(req))
	web.response_text(res, .OK, msg)
}

submit :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [256]byte
	name, _ := web.request_form_value(req, "name")
	web.response_write_string(res, fmt.bprintf(buf[:], "name=%v\n", name))
	if f, ok := web.request_file(req, "avatar"); ok {
		web.response_write_string(res, fmt.bprintf(buf[:], "file=%v type=%v bytes=%v\n", f.filename, f.content_type, len(f.data)))
	}
	if len(req.files) == 0 {
		web.response_write_string(res, "no file uploaded\n")
	}
}

events :: proc(req: ^web.Request, res: ^web.Response) {
	w, ok := web.sse_start(res)
	if !ok {
		return
	}
	defer web.sse_close(&w)

	_ = web.sse_retry(&w, 2000)
	for i in 0..<3 {
		payload: [64]byte
		idbuf: [16]byte
		data := fmt.bprintf(payload[:], "tick %d", i + 1)
		id := fmt.bprintf(idbuf[:], "%d", i + 1)
		if !web.sse_event(&w, data, "tick", id) {
			return // the client is gone
		}
	}
}

main :: proc() {
	address := "0.0.0.0:8080"
	if len(os.args) > 1 {
		address = os.args[1]
	}

	srv: web.Server
	if !web.server_init(&srv, address) {
		return
	}

	router: web.Router
	web.router_init(&router)
	// router-wide chain: cross-cutting concerns only
	web.router_use(&router, web.middleware_request_id)
	web.router_use(&router, web.middleware_logger)
	web.router_use(&router, web.middleware_secure_headers)

	// register every route first: adding a route can move the table and
	// invalidate the pointers the next block needs
	web.router_get(&router, "/", index)
	report_route := web.router_get(&router, "/report.csv", report)
	admin_route := web.router_get(&router, "/admin", admin)
	keys_route := web.router_get(&router, "/api/keys", keys)
	submit_route := web.router_add(&router, web.Method.Post, "/submit", submit)
	web.router_get(&router, "/events", events)

	// route-local middleware, one purpose per route
	web.router_use_route(report_route, web.middleware_range, &range_cfg)
	web.router_use_route(admin_route, web.middleware_basic_auth, &admin_cfg)
	web.router_use_route(keys_route, web.middleware_api_key, &key_cfg)
	web.router_use_route(submit_route, web.middleware_form, &form_cfg)

	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.printf("middleware demo on http://%v\n", address)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
