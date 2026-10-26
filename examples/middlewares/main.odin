package main

/*
Purpose-built middleware: auth, form parsing, Range/ETag, compression and
SSE, each attached to the one route that needs it instead of the whole
router. They live in the `web/middlewares` subpackage, so this example
imports both.

	odin run examples/middlewares            # :8080
	odin run examples/middlewares -- 127.0.0.1:9000

	curl -r 10-19        http://127.0.0.1:8080/report.csv
	curl -I              http://127.0.0.1:8080/report.csv     # ETag, Accept-Ranges
	curl -u admin:secret http://127.0.0.1:8080/admin
	curl -H 'X-API-Key: key-live-1' http://127.0.0.1:8080/api/keys
	curl -F name=ada -F avatar=@README.md http://127.0.0.1:8080/submit
	curl -F doc=@big.bin        http://127.0.0.1:8080/upload     # streamed to disk
	curl --compressed   http://127.0.0.1:8080/big             # gzip on one route
	curl -N              http://127.0.0.1:8080/events
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "../../web"
import "../../web/middlewares"

// Middleware configs outlive the server, so they live at file scope: a stack
// temporary would dangle as soon as main's scope changed.
admin_cfg := middlewares.Basic_Auth_Config {
	username = "admin",
	password = "secret",
	realm    = "admin",
}

key_cfg := middlewares.API_Key_Config {
	tokens = []middlewares.Auth_Token{middlewares.Auth_Token{token = "key-live-1", name = "mobile-app"}},
	header = "X-API-Key",
}

form_cfg := web.Form_Config {
	require_form  = true, // a JSON body on this route is a 415, not a surprise
	max_file_size = 1 << 20,
}

// Uploads above 64 KiB per part are written out while the body is still
// arriving, so the size of the file is not the size of the process.
upload_cfg := middlewares.Upload_Config {
	dir      = "./uploads",
	stream   = true,
	threshold = 64 << 10,
	max_file_bytes = 512 << 20,
}

range_cfg := middlewares.Range_Config {
	etag = true, // content hash + If-None-Match -> 304
}

// "compress anything over 256 bytes on this route" - the filter's own
// default threshold stays in force everywhere else.
gzip_cfg := middlewares.Gzip_Config {
	min_size = 256,
}

index :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_content_type(res, "text/plain; charset=utf-8")
	web.response_write_string(res, `purpose-built middleware demo

  GET  /report.csv   Range + ETag over a generated body (middleware_range)
  GET  /admin        HTTP basic auth, route-local (middleware_basic_auth)
  GET  /api/keys     API key in X-API-Key (middleware_api_key)
  POST /submit       form parser, urlencoded or multipart (middleware_form)
  POST /upload       upload spooled to disk as it arrives (middleware_upload)
  GET  /big          gzip above 256 bytes (middleware_gzip)
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

// big is a body worth compressing: the same line repeated, so gzip has
// something to bite on and curl --compressed shows the difference.
big :: proc(req: ^web.Request, res: ^web.Response) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for _ in 0..<40 {
		strings.write_string(&sb, "the quick brown fox jumps over the lazy dog\n")
	}
	// say what it is: the compress filter only codes bodies whose
	// Content-Type is worth coding, and an untyped body has none
	web.response_set_content_type(res, "text/plain; charset=utf-8")
	web.response_write_string(res, strings.to_string(sb))
}

admin :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [128]byte
	msg := fmt.bprintf(buf[:], "admin area, user=%v\n", middlewares.request_principal(req))
	web.response_text(res, .OK, msg)
}

keys :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [128]byte
	msg := fmt.bprintf(buf[:], "key accepted for %v\n", middlewares.request_principal(req))
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

// upload is the streaming counterpart of submit: by the time it runs the part
// is already a file, so `data` is empty and the bytes were never all resident.
upload :: proc(req: ^web.Request, res: ^web.Response) {
	buf: [256]byte
	u, ok := middlewares.request_upload(req, "doc")
	if !ok {
		web.response_error(res, .Bad_Request, "expected a file part named doc\n")
		return
	}
	web.response_write_string(res, fmt.bprintf(buf[:], "stored  %v\n", u.path))
	web.response_write_string(res, fmt.bprintf(buf[:], "name    %v\n", u.original))
	web.response_write_string(res, fmt.bprintf(buf[:], "type    %v\n", u.content_type))
	web.response_write_string(res, fmt.bprintf(buf[:], "bytes   %v\n", u.size))
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
	web.router_use(&router, middlewares.middleware_request_id)
	web.router_use(&router, middlewares.middleware_logger)
	web.router_use(&router, middlewares.middleware_secure_headers)

	// routes are heap-allocated, so the pointers stay valid while the rest of
	// the table is registered; attaching in a second pass keeps the two
	// concerns separate
	web.router_get(&router, "/", index)
	report_route := web.router_get(&router, "/report.csv", report)
	admin_route := web.router_get(&router, "/admin", admin)
	keys_route := web.router_get(&router, "/api/keys", keys)
	submit_route := web.router_add(&router, web.Method.Post, "/submit", submit)
	upload_route := web.router_add(&router, web.Method.Post, "/upload", upload)
	big_route := web.router_get(&router, "/big", big)
	web.router_get(&router, "/events", events)

	// route-local middleware, one purpose per route
	web.router_use_route(report_route, middlewares.middleware_range, &range_cfg)
	web.router_use_route(admin_route, middlewares.middleware_basic_auth, &admin_cfg)
	web.router_use_route(keys_route, middlewares.middleware_api_key, &key_cfg)
	web.router_use_route(submit_route, middlewares.middleware_form, &form_cfg)
	web.router_use_route(upload_route, middlewares.middleware_upload, &upload_cfg)
	web.router_use_route(big_route, middlewares.middleware_gzip, &gzip_cfg)

	srv.handler = web.router_handle
	srv.user_ptr = &router
	// the body has to be diverted before the route is known: the hook runs on
	// every request head and only acts on multipart bodies
	srv.on_head = middlewares.upload_stream_hook
	srv.on_head_ud = &upload_cfg
	fmt.printf("middleware demo on http://%v\n", address)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
