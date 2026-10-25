package middleware

import ".."
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"

// Tests for the purpose-specific middleware: auth (bearer, API key),
// form/multipart, Range + ETag and the streaming headers, plus one real
// socket test for the SSE writer.


// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------

principal_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, "user=")
	web.response_write_string(res, request_principal(req))
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
	web.router_use(&e.router, middleware_bearer_auth, &cfg)
	web.router_get(&e.router, "/m", principal_handler)

	// no credentials: a challenge, no `error` code (RFC 6750 section 3)
	req := web.Request{method = .Get, path = "/m", target = "/m"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Unauthorized)
	if www, ok := web.response_header(&res, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics"`)
	}

	// a wrong token names the failure
	req_bad := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []web.Header{web.Header{key = "Authorization", value = "Bearer nope"}},
	}
	res_bad: web.Response
	mw_env_call(&e, &req_bad, &res_bad)
	testing.expect_value(t, res_bad.status, web.Status.Unauthorized)
	if www, ok := web.response_header(&res_bad, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="metrics", error="invalid_token"`)
	}

	// the second token maps to its own principal
	req_ok := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []web.Header{web.Header{key = "Authorization", value = "Bearer tok_live_2"}},
	}
	res_ok: web.Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_ok.body)), "user=reporting")

	// a different scheme does not authenticate
	req_basic := web.Request {
		method  = .Get,
		path    = "/m",
		target  = "/m",
		headers = []web.Header{web.Header{key = "Authorization", value = "Basic abc"}},
	}
	res_basic: web.Response
	mw_env_call(&e, &req_basic, &res_basic)
	testing.expect_value(t, res_basic.status, web.Status.Unauthorized)
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
	web.router_use(&e.router, middleware_api_key, &cfg)
	web.router_get(&e.router, "/k", principal_handler)

	// header form
	req := web.Request {
		method  = .Get,
		path    = "/k",
		target  = "/k",
		headers = []web.Header{web.Header{key = "X-API-Key", value = "key-1"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "user=svc-a")

	// query fallback
	req_q := web.Request{method = .Get, path = "/k", target = "/k?api_key=key-1", query = "api_key=key-1"}
	res_q: web.Response
	mw_env_call(&e, &req_q, &res_q)
	testing.expect_value(t, res_q.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_q.body)), "user=svc-a")

	// nothing presented
	req_none := web.Request{method = .Get, path = "/k", target = "/k"}
	res_none: web.Response
	mw_env_call(&e, &req_none, &res_none)
	testing.expect_value(t, res_none.status, web.Status.Unauthorized)
	if www, ok := web.response_header(&res_none, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `ApiKey realm="api"`)
	}
}

// ---------------------------------------------------------------------------
// form
// ---------------------------------------------------------------------------

form_handler :: proc(req: ^web.Request, res: ^web.Response) {
	name, _ := web.request_form_value(req, "name")
	web.response_write_string(res, "name=")
	web.response_write_string(res, name)
	if f, ok := web.request_file(req, "avatar"); ok {
		web.response_write_string(res, " file=")
		web.response_write_string(res, f.filename)
		web.response_write_string(res, ":")
		web.response_write_string(res, f.content_type)
		web.response_write_string(res, ":")
		web.response_write(res, f.data)
	}
}

@(test)
test_middleware_form_urlencoded :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_form)
	web.router_post(&e.router, "/f", form_handler)

	body := "name=Ada+Lovelace&role=admin"
	req := web.Request {
		method  = .Post,
		path    = "/f",
		target  = "/f",
		body    = transmute([]byte) body,
		headers = []web.Header{web.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "name=Ada Lovelace")
	// the middleware parsed it once and cached the result on the request
	testing.expect_value(t, req.form_state, web.Form_State.Parsed)
	testing.expect_value(t, len(req.form), 2)
}

@(test)
test_middleware_form_multipart :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_form)
	web.router_post(&e.router, "/f", form_handler)

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
	req := web.Request {
		method  = .Post,
		path    = "/f",
		target  = "/f",
		body    = transmute([]byte) body,
		headers = []web.Header {
			web.Header{key = "Content-Type", value = "multipart/form-data; boundary=XyZ"},
		},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	// the client's path components are stripped, the type is kept
	testing.expect_value(t, string(web.buf_slice(&res.body)), "name=Ada file=pic a.txt:text/plain:hello upload")

	// files are addressable as well as by field
	files := web.request_files(&req)
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
		cfg := web.Form_Config{require_form = true}
		web.router_use(&e.router, middleware_form, &cfg)
		web.router_post(&e.router, "/f", form_handler)

		body := `{"name":"ada"}`
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []web.Header{web.Header{key = "Content-Type", value = "application/json"}},
		}
		res: web.Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, web.Status.Unsupported_Media)
	}

	// a multipart type without a boundary is a malformed request
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		web.router_use(&e.router, middleware_form)
		web.router_post(&e.router, "/f", form_handler)

		body := "irrelevant"
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []web.Header{web.Header{key = "Content-Type", value = "multipart/form-data"}},
		}
		res: web.Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, web.Status.Bad_Request)
	}

	// too many fields hits the configured limit
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		cfg := web.Form_Config{max_fields = 1}
		web.router_use(&e.router, middleware_form, &cfg)
		web.router_post(&e.router, "/f", form_handler)

		body := "--B\r\n" +
			"Content-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" +
			"--B\r\n" +
			"Content-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" +
			"--B--\r\n"
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []web.Header{web.Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: web.Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, web.Status.Payload_Too_Large)
	}

	// an upload over the byte limit is refused before the handler runs
	{
		e: Mw_Env
		mw_env_init(&e)
		defer mw_env_destroy(&e)
		cfg := web.Form_Config{max_file_size = 4}
		web.router_use(&e.router, middleware_form, &cfg)
		web.router_post(&e.router, "/f", form_handler)

		body := "--B\r\n" +
			"Content-Disposition: form-data; name=\"f\"; filename=\"x\"\r\n\r\n" +
			"12345\r\n" +
			"--B--\r\n"
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []web.Header{web.Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: web.Response
		mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, web.Status.Payload_Too_Large)
	}
}

@(test)
test_middleware_form_lazy_parse :: proc(t: ^testing.T) {
	// without the middleware, the accessors parse on first use - and a body
	// that is not a form stays untouched for a JSON handler
	conn: web.Conn
	mem.dynamic_arena_init(&conn.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&conn.scratch)

	body := "a=1&b=2"
	req := web.Request {
		conn    = &conn,
		method  = .Post,
		body    = transmute([]byte) body,
		headers = []web.Header{web.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
	}
	testing.expect_value(t, len(web.request_form(&req)), 2)
	if v, ok := web.request_form_value(&req, "b"); testing.expect(t, ok) {
		testing.expect_value(t, v, "2")
	}
	// second call is a cache hit, not a re-parse
	testing.expect_value(t, len(web.request_form(&req)), 2)

	json_body := `{"a":1}`
	req_json := web.Request {
		method  = .Post,
		body    = transmute([]byte) json_body,
		headers = []web.Header{web.Header{key = "Content-Type", value = "application/json"}},
	}
	testing.expect_value(t, len(web.request_form(&req_json)), 0)
	testing.expect_value(t, req_json.form_state, web.Form_State.Unparsed)
}

// ---------------------------------------------------------------------------
// range + ETag
// ---------------------------------------------------------------------------

range_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_content_type(res, "text/plain")
	// "0123456789" ten times: 100 bytes with a string index every 10 bytes
	for i in 0..<10 {
		web.response_write_string(res, "0123456789")
	}
}

range_file_handler :: proc(req: ^web.Request, res: ^web.Response) {
	// stand-in for a sendfile response: the middleware must leave it alone
	res.file_open = true
	res.file_size = 100
	web.response_write_string(res, "ignored")
}

@(test)
test_middleware_range_single :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "Range", value = "bytes=10-19"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Partial_Content)
	if cr, ok := web.response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 10-19/100")
	}
	testing.expect_value(t, string(web.buf_slice(&res.body)), "0123456789")
	if ar, ok := web.response_header(&res, "Accept-Ranges"); testing.expect(t, ok) {
		testing.expect_value(t, ar, "bytes")
	}

	// suffix form: the last five bytes
	req_suffix := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "Range", value = "bytes=-5"}},
	}
	res_suffix: web.Response
	mw_env_call(&e, &req_suffix, &res_suffix)
	testing.expect_value(t, res_suffix.status, web.Status.Partial_Content)
	testing.expect_value(t, string(web.buf_slice(&res_suffix.body)), "56789")
	if cr, ok := web.response_header(&res_suffix, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 95-99/100")
	}

	// several ranges are ignored: full body, 200
	req_multi := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "Range", value = "bytes=0-1,5-6"}},
	}
	res_multi: web.Response
	mw_env_call(&e, &req_multi, &res_multi)
	testing.expect_value(t, res_multi.status, web.Status.OK)
	testing.expect_value(t, len(res_multi.body.data), 100)

	// no Range header: untouched, and without etag config no extra headers
	req_plain := web.Request{method = .Get, path = "/r", target = "/r"}
	res_plain: web.Response
	mw_env_call(&e, &req_plain, &res_plain)
	testing.expect_value(t, res_plain.status, web.Status.OK)
	_, has_etag := web.response_header(&res_plain, "ETag")
	testing.expect(t, !has_etag)
}

@(test)
test_middleware_range_unsatisfiable :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "Range", value = "bytes=200-300"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Range_Not_Satisfiable)
	if cr, ok := web.response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes */100")
	}
}

@(test)
test_middleware_range_etag :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Range_Config{etag = true}
	web.router_use(&e.router, middleware_range, &cfg)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request{method = .Get, path = "/r", target = "/r"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	etag, has_etag := web.response_header(&res, "ETag")
	testing.expect(t, has_etag)
	testing.expect_value(t, len(etag), 18) // two quotes + 16 hex digits
	testing.expect(t, etag[0] == '"' && etag[len(etag) - 1] == '"')

	// revalidation
	req_304 := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "If-None-Match", value = etag}},
	}
	res_304: web.Response
	mw_env_call(&e, &req_304, &res_304)
	testing.expect_value(t, res_304.status, web.Status.Not_Modified)
	testing.expect_value(t, len(res_304.body.data), 0)
	_, has_ct := web.response_header(&res_304, "Content-Type")
	testing.expect(t, !has_ct)
	etag_304, _ := web.response_header(&res_304, "ETag")
	testing.expect_value(t, etag_304, etag)

	// a stale tag and a wildcard
	req_stale := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "If-None-Match", value = `"deadbeefdeadbeef"`}},
	}
	res_stale: web.Response
	mw_env_call(&e, &req_stale, &res_stale)
	testing.expect_value(t, res_stale.status, web.Status.OK)

	req_star := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header{web.Header{key = "If-None-Match", value = "*"}},
	}
	res_star: web.Response
	mw_env_call(&e, &req_star, &res_star)
	testing.expect_value(t, res_star.status, web.Status.Not_Modified)

	// If-Range with a matching tag keeps the range
	req_ifrange := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header {
			web.Header{key = "If-Range", value = etag},
			web.Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange: web.Response
	mw_env_call(&e, &req_ifrange, &res_ifrange)
	testing.expect_value(t, res_ifrange.status, web.Status.Partial_Content)
	testing.expect_value(t, string(web.buf_slice(&res_ifrange.body)), "0123")

	// If-Range with a stale tag falls back to the full body
	req_ifrange_stale := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []web.Header {
			web.Header{key = "If-Range", value = `"deadbeefdeadbeef"`},
			web.Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange_stale: web.Response
	mw_env_call(&e, &req_ifrange_stale, &res_ifrange_stale)
	testing.expect_value(t, res_ifrange_stale.status, web.Status.OK)
	testing.expect_value(t, len(res_ifrange_stale.body.data), 100)
}

@(test)
test_middleware_range_skips_file_responses :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/f", range_file_handler)

	req := web.Request {
		method  = .Get,
		path    = "/f",
		target  = "/f",
		headers = []web.Header{web.Header{key = "Range", value = "bytes=0-3"}},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK) // sendfile path owns ranges
	_, has_cr := web.response_header(&res, "Content-Range")
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

	web.router_use(&e.router, middleware_no_buffer)
	web.router_get(&e.router, "/s", dummy_handler)

	req := web.Request{method = .Get, path = "/s", target = "/s"}
	res: web.Response
	mw_env_call(&e, &req, &res)

	if v, ok := web.response_header(&res, "X-Accel-Buffering"); testing.expect(t, ok) {
		testing.expect_value(t, v, "no")
	}
	if v, ok := web.response_header(&res, "Cache-Control"); testing.expect(t, ok) {
		testing.expect(t, strings.contains(v, "no-transform"))
	}
	testing.expect_value(t, string(web.buf_slice(&res.body)), "ok")
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
	web.router_get(&e.router, "/open", principal_handler)
	private := web.router_get(&e.router, "/private", principal_handler)
	web.router_use_route(private, middleware_bearer_auth, &cfg)

	// the guarded route needs a token...
	req := web.Request{method = .Get, path = "/private", target = "/private"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Unauthorized)

	// ...and runs the handler once one is presented
	req_ok := web.Request {
		method  = .Get,
		path    = "/private",
		target  = "/private",
		headers = []web.Header{web.Header{key = "Authorization", value = "Bearer tok"}},
	}
	res_ok: web.Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_ok.body)), "user=svc")

	// the unguarded route is untouched by the route middleware
	req_open := web.Request{method = .Get, path = "/open", target = "/open"}
	res_open: web.Response
	mw_env_call(&e, &req_open, &res_open)
	testing.expect_value(t, res_open.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_open.body)), "user=")
}
