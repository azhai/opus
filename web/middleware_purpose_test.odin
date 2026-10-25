package web

// Tests for the purpose-specific middleware: auth (bearer, API key),
// form/multipart, Range + ETag and the streaming headers, plus one real
// socket test for the SSE writer.

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------

principal_handler :: proc(req: ^Request, res: ^Response) {
	response_write_string(res, "user=")
	response_write_string(res, request_principal(req))
}

@(test)
test_middleware_bearer_auth :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Bearer_Auth_Config {
		tokens = []Auth_Token{
			Auth_Token{token = "tok_live_1", name = "deploy-bot"},
			Auth_Token{token = "tok_live_2", name = "reporting"},
		},
		realm = "metrics",
	}
	router_use(&e.router, middleware_bearer_auth, &cfg)
	router_get(&e.router, "/m", principal_handler)

	// no credentials: a challenge, no `error` code (RFC 6750 section 3)
	req := Request{method = .Get, path = "/m", target = "/m"}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.Unauthorized)
	if www, ok := response_header(&res, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics"`)
	}

	// a wrong token names the failure
	req_bad := Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []Header{Header{key = "Authorization", value = "Bearer nope"}},
	}
	res_bad: Response
	mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, Status.Unauthorized)
	if www, ok := response_header(&res_bad, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics", error="invalid_token"`)
	}

	// the second token maps to its own principal
	req_ok := Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []Header{Header{key = "Authorization", value = "Bearer tok_live_2"}},
	}
	res_ok: Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res_ok.body)), "user=reporting")

	// a different scheme does not authenticate
	req_basic := Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []Header{Header{key = "Authorization", value = "Basic abc"}},
	}
	res_basic: Response
	mw_env_call(&e, &req_basic, &res_basic)
	testing.expect_value(t, res_basic.status, Status.Unauthorized)
}

@(test)
test_middleware_api_key :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := API_Key_Config {
		tokens = []Auth_Token{Auth_Token{token = "key-1", name = "svc-a"}},
		query  = "api_key",
	}
	router_use(&e.router, middleware_api_key, &cfg)
	router_get(&e.router, "/k", principal_handler)

	// header form
	req := Request {
		method  = .Get,
		path    = "/k",
		target  = "/k",
		headers = []Header{Header{key = "X-API-Key", value = "key-1"}},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res.body)), "user=svc-a")

	// query fallback
	req_q := Request{method = .Get, path = "/k", target = "/k?api_key=key-1", query = "api_key=key-1"}
	res_q: Response
	mw_env_call(&e, &req_q, &res_q)
	testing.expect_value(t, res_q.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res_q.body)), "user=svc-a")

	// nothing presented
	req_none := Request{method = .Get, path = "/k", target = "/k"}
	res_none: Response
	mw_env_call(&e, &req_none, &res_none)
	testing.expect_value(t, res_none.status, Status.Unauthorized)
	if www, ok := response_header(&res_none, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `ApiKey realm="api"`)
	}
}

// ---------------------------------------------------------------------------
// form
// ---------------------------------------------------------------------------

form_handler :: proc(req: ^Request, res: ^Response) {
	name, _ := request_form_value(req, "name")
	response_write_string(res, "name=")
	response_write_string(res, name)
	if f, ok := request_file(req, "avatar"); ok {
		response_write_string(res, " file=")
		response_write_string(res, f.filename)
		response_write_string(res, ":")
		response_write_string(res, f.content_type)
		response_write_string(res, ":")
		response_write(res, f.data)
	}
}

@(test)
test_middleware_form_urlencoded :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_form)
	router_post(&e.router, "/f", form_handler)

	body := "name=Ada+Lovelace&role=admin"
	req := Request {
		method  = .Post,
		path    = "/f",
		target  = "/f",
		body    = transmute([]byte) body,
		headers = []Header{Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res.body)), "name=Ada Lovelace")
	// the middleware parsed it once and cached the result on the request
	testing.expect_value(t, req.form_state, Form_State.Parsed)
	testing.expect_value(t, len(req.form), 2)
}

@(test)
test_middleware_form_multipart :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_form)
	router_post(&e.router, "/f", form_handler)

	body := "--XyZ\r\n" +
		"Content-Disposition: form-data; name=\"name\"\r\n" +
		"\r\n" +
		"Ada\r\n" +
		"--XyZ\r\n" +
		"Content-Disposition: form-data; name=\"avatar\"; filename=\"/tmp/pic a.txt\"\r\n" +
		"Content-Type: text/plain\r\n" +
		"\r\n" +
		"hello upload\r\n" +
		"--XyZ--\r\n"
	req := Request {
		method  = .Post,
		path    = "/f",
		target  = "/f",
		body    = transmute([]byte) body,
		headers = []Header {
			Header{key = "Content-Type", value = "multipart/form-data; boundary=XyZ"},
		},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.OK)
	// the client's path components are stripped, the type is kept
	testing.expect_value(t, string(buf_slice(&res.body)), "name=Ada file=pic a.txt:text/plain:hello upload")

	// files are addressable as well as by field
	files := request_files(&req)
	testing.expect_value(t, len(files), 1)
	testing.expect_value(t, files[0].field, "avatar")
}

@(test)
test_middleware_form_errors :: proc(t: ^testing.T) {
	// require_form turns a JSON body into 415
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		cfg := Form_Config{require_form = true}
		router_use(&e.router, middleware_form, &cfg)
		router_post(&e.router, "/f", form_handler)

		body := `{"name":"ada"}`
		req := Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []Header{Header{key = "Content-Type", value = "application/json"}},
		}
		res: Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, Status.Unsupported_Media)
	}

	// a multipart type without a boundary is a malformed request
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		router_use(&e.router, middleware_form)
		router_post(&e.router, "/f", form_handler)

		body := "irrelevant"
		req := Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []Header{Header{key = "Content-Type", value = "multipart/form-data"}},
		}
		res: Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, Status.Bad_Request)
	}

	// too many fields hits the configured limit
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		cfg := Form_Config{max_fields = 1}
		router_use(&e.router, middleware_form, &cfg)
		router_post(&e.router, "/f", form_handler)

		body := "--B\r\n" +
			"Content-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" +
			"--B\r\n" +
			"Content-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" +
			"--B--\r\n"
		req := Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []Header{Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, Status.Payload_Too_Large)
	}

	// an upload over the byte limit is refused before the handler runs
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		cfg := Form_Config{max_file_size = 4}
		router_use(&e.router, middleware_form, &cfg)
		router_post(&e.router, "/f", form_handler)

		body := "--B\r\n" +
			"Content-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\n" +
			"12345\r\n" +
			"--B--\r\n"
		req := Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []Header{Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, Status.Payload_Too_Large)
	}
}

@(test)
test_middleware_form_lazy_parse :: proc(t: ^testing.T) {
	// without the middleware, the accessors parse on first use - and a body
	// that is not a form stays untouched for a JSON handler
	conn: Conn
	mem.dynamic_arena_init(&conn.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&conn.scratch)

	body := "a=1&b=2"
	req := Request {
		conn    = &conn,
		method  = .Post,
		body    = transmute([]byte) body,
		headers = []Header{Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
	}
	testing.expect_value(t, len(request_form(&req)), 2)
	if v, ok := request_form_value(&req, "b"); testing.expect(t, ok) {
		testing.expect_value(t, v, "2")
	}
	// second call is a cache hit, not a re-parse
	testing.expect_value(t, len(request_form(&req)), 2)

	json_body := `{"a":1}`
	req_json := Request {
		method  = .Post,
		body    = transmute([]byte) json_body,
		headers = []Header{Header{key = "Content-Type", value = "application/json"}},
	}
	testing.expect_value(t, len(request_form(&req_json)), 0)
	testing.expect_value(t, req_json.form_state, Form_State.Unparsed)
}

// ---------------------------------------------------------------------------
// range + ETag
// ---------------------------------------------------------------------------

range_handler :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain")
	// "0123456789" ten times: 100 bytes with a string index every 10 bytes
	for i in 0..<10 {
		response_write_string(res, "0123456789")
	}
}

range_file_handler :: proc(req: ^Request, res: ^Response) {
	// stand-in for a sendfile response: the middleware must leave it alone
	res.file_open = true
	res.file_size = 100
	response_write_string(res, "ignored")
}

@(test)
test_middleware_range_single :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_range)
	router_get(&e.router, "/r", range_handler)

	req := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "Range", value = "bytes=10-19"}},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.Partial_Content)
	if cr, ok := response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 10-19/100")
	}
	testing.expect_value(t, string(buf_slice(&res.body)), "0123456789")
	if ar, ok := response_header(&res, "Accept-Ranges"); testing.expect(t, ok) {
		testing.expect_value(t, ar, "bytes")
	}

	// suffix form: the last five bytes
	req_suffix := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "Range", value = "bytes=-5"}},
	}
	res_suffix: Response
	mw_env_call(&e, &req_suffix, &res_suffix)
	testing.expect_value(t, res_suffix.status, Status.Partial_Content)
	testing.expect_value(t, string(buf_slice(&res_suffix.body)), "56789")
	if cr, ok := response_header(&res_suffix, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 95-99/100")
	}

	// several ranges are ignored: full body, 200
	req_multi := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "Range", value = "bytes=0-1,5-6"}},
	}
	res_multi: Response
	mw_env_call(&e, &req_multi, &res_multi)
	testing.expect_value(t, res_multi.status, Status.OK)
	testing.expect_value(t, len(res_multi.body.data), 100)

	// no Range header: untouched, and without etag config no extra headers
	req_plain := Request{method = .Get, path = "/r", target = "/r"}
	res_plain: Response
	mw_env_call(&e, &req_plain, &res_plain)
	testing.expect_value(t, res_plain.status, Status.OK)
	_, has_etag := response_header(&res_plain, "ETag")
	testing.expect(t, !has_etag)
}

@(test)
test_middleware_range_unsatisfiable :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_range)
	router_get(&e.router, "/r", range_handler)

	req := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "Range", value = "bytes=200-300"}},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.Range_Not_Satisfiable)
	if cr, ok := response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes */100")
	}
}

@(test)
test_middleware_range_etag :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Range_Config{etag = true}
	router_use(&e.router, middleware_range, &cfg)
	router_get(&e.router, "/r", range_handler)

	req := Request{method = .Get, path = "/r", target = "/r"}
	res: Response
	mw_env_call(&e, &req, &res)
	etag, has_etag := response_header(&res, "ETag")
	testing.expect(t, has_etag)
	testing.expect_value(t, len(etag), 18) // two quotes + 16 hex digits
	testing.expect(t, etag[0] == '"' && etag[len(etag) - 1] == '"')

	// revalidation
	req_304 := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "If-None-Match", value = etag}},
	}
	res_304: Response
	mw_env_call(&e, &req_304, &res_304)
	testing.expect_value(t, res_304.status, Status.Not_Modified)
	testing.expect_value(t, len(res_304.body.data), 0)
	_, has_ct := response_header(&res_304, "Content-Type")
	testing.expect(t, !has_ct)
	etag_304, _ := response_header(&res_304, "ETag")
	testing.expect_value(t, etag_304, etag)

	// a stale tag and a wildcard
	req_stale := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "If-None-Match", value = `"deadbeefdeadbeef"`}},
	}
	res_stale: Response
	mw_env_call(&e, &req_stale, &res_stale)
	testing.expect_value(t, res_stale.status, Status.OK)

	req_star := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header{Header{key = "If-None-Match", value = "*"}},
	}
	res_star: Response
	mw_env_call(&e, &req_star, &res_star)
	testing.expect_value(t, res_star.status, Status.Not_Modified)

	// If-Range with a matching tag keeps the range
	req_ifrange := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header {
			Header{key = "If-Range", value = etag},
			Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange: Response
	mw_env_call(&e, &req_ifrange, &res_ifrange)
	testing.expect_value(t, res_ifrange.status, Status.Partial_Content)
	testing.expect_value(t, string(buf_slice(&res_ifrange.body)), "0123")

	// If-Range with a stale tag falls back to the full body
	req_ifrange_stale := Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []Header {
			Header{key = "If-Range", value = `"deadbeefdeadbeef"`},
			Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange_stale: Response
	mw_env_call(&e, &req_ifrange_stale, &res_ifrange_stale)
	testing.expect_value(t, res_ifrange_stale.status, Status.OK)
	testing.expect_value(t, len(res_ifrange_stale.body.data), 100)
}

@(test)
test_middleware_range_skips_file_responses :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_range)
	router_get(&e.router, "/f", range_file_handler)

	req := Request {
		method  = .Get,
		path    = "/f",
		target  = "/f",
		headers = []Header{Header{key = "Range", value = "bytes=0-3"}},
	}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.OK) // sendfile path owns ranges
	_, has_cr := response_header(&res, "Content-Range")
	testing.expect(t, !has_cr)
}

// ---------------------------------------------------------------------------
// streaming headers
// ---------------------------------------------------------------------------

@(test)
test_middleware_no_buffer :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	router_use(&e.router, middleware_no_buffer)
	router_get(&e.router, "/s", dummy_handler)

	req := Request{method = .Get, path = "/s", target = "/s"}
	res: Response
	mw_env_call(&e, &req, &res)

	if v, ok := response_header(&res, "X-Accel-Buffering"); testing.expect(t, ok) {
		testing.expect_value(t, v, "no")
	}
	if v, ok := response_header(&res, "Cache-Control"); testing.expect(t, ok) {
		testing.expect(t, strings.contains(v, "no-transform"))
	}
	testing.expect_value(t, string(buf_slice(&res.body)), "ok")
}

// ---------------------------------------------------------------------------
// route-local middleware
// ---------------------------------------------------------------------------

@(test)
test_router_use_route :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Bearer_Auth_Config {
		tokens = []Auth_Token{Auth_Token{token = "tok", name = "svc"}},
	}

	// Register every route first: a later router_add may move the table and
	// invalidate route pointers (documented on router_use_route).
	router_get(&e.router, "/open", principal_handler)
	private := router_get(&e.router, "/private", principal_handler)
	router_use_route(private, middleware_bearer_auth, &cfg)

	// the guarded route needs a token...
	req := Request{method = .Get, path = "/private", target = "/private"}
	res: Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, Status.Unauthorized)

	// ...and runs the handler once one is presented
	req_ok := Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []Header{Header{key = "Authorization", value = "Bearer tok"}},
	}
	res_ok: Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res_ok.body)), "user=svc")

	// the unguarded route is untouched by the route middleware
	req_open := Request{method = .Get, path = "/open", target = "/open"}
	res_open: Response
	mw_env_call(&e, &req_open, &res_open)
	testing.expect_value(t, res_open.status, Status.OK)
	testing.expect_value(t, string(buf_slice(&res_open.body)), "user=")
}

// ---------------------------------------------------------------------------
// SSE over a real socket
// ---------------------------------------------------------------------------

sse_handler :: proc(req: ^Request, res: ^Response) {
	w, ok := sse_start(res)
	if !ok {
		return
	}
	defer sse_close(&w)
	if !sse_retry(&w, 1000) {
		return
	}
	_ = sse_comment(&w, "keep-alive")
	_ = sse_event(&w, "line one\nline two", "tick", "42")
}

@(test)
test_integration_sse :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, sse_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /sse HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte) request)
	testing.expect(t, serr == nil)
	testing.expect(t, n == len(request))

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
		// the terminating chunk ends the stream
		if bytes_contains(buf[:total], "0\r\n\r\n") {
			break
		}
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Type: text/event-stream\r\n"))
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "X-Accel-Buffering: no\r\n"))
	// chunk framing: "<hex>\r\n<fields>"
	testing.expect(t, bytes_contains(buf[:total], "retry: 1000\n\n"))
	testing.expect(t, bytes_contains(buf[:total], ": keep-alive\n\n"))
	testing.expect(t, bytes_contains(buf[:total], "event: tick\n"))
	testing.expect(t, bytes_contains(buf[:total], "id: 42\n"))
	testing.expect(t, bytes_contains(buf[:total], "data: line one\n"))
	testing.expect(t, bytes_contains(buf[:total], "data: line two\n"))
	testing.expect(t, strings.has_suffix(resp, "0\r\n\r\n"))
}
