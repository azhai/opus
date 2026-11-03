package form

// Tests for middleware_form: the urlencoded and multipart paths, the error
// verdicts, and the lazy-parse contract.

import "../../web"
import "core:mem"
import "core:strings"
import "core:testing"
import "../../buffer"
import "../../http"
import "../../testenv"

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
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_form)
	web.router_post(&e.router, "/f", form_handler)

	body := "name=Ada+Lovelace&role=admin"
	req := web.Request {
		method  = .Post,
		path    = "/f",
		target  = "/f",
		body    = transmute([]byte) body,
		headers = []http.Header{http.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "name=Ada Lovelace")
	// the middleware parsed it once and cached the result on the request
	testing.expect_value(t, req.form_state, web.Form_State.Parsed)
	testing.expect_value(t, len(req.form), 2)
}

@(test)
test_middleware_form_multipart :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

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
		headers = []http.Header {
			http.Header{key = "Content-Type", value = "multipart/form-data; boundary=XyZ"},
		},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK)
	// the client's path components are stripped, the type is kept
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "name=Ada file=pic a.txt:text/plain:hello upload")

	// files are addressable as well as by field
	files := web.request_files(&req)
	testing.expect_value(t, len(files), 1)
	testing.expect_value(t, files[0].field, "avatar")
}

@(test)
test_middleware_form_errors :: proc(t: ^testing.T) {
	// require_form turns a JSON body into 415
	{
		e: testenv.Mw_Env
		testenv.mw_env_init(&e)
		defer testenv.mw_env_destroy(&e)
		cfg := web.Form_Config{require_form = true}
		web.router_use(&e.router, middleware_form, &cfg)
		web.router_post(&e.router, "/f", form_handler)

		body := `{"name":"ada"}`
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []http.Header{http.Header{key = "Content-Type", value = "application/json"}},
		}
		res: web.Response
		testenv.mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, http.Status.Unsupported_Media)
	}

	// a multipart type without a boundary is a malformed request
	{
		e: testenv.Mw_Env
		testenv.mw_env_init(&e)
		defer testenv.mw_env_destroy(&e)
		web.router_use(&e.router, middleware_form)
		web.router_post(&e.router, "/f", form_handler)

		body := "irrelevant"
		req := web.Request {
			method  = .Post,
			path    = "/f",
			target  = "/f",
			body    = transmute([]byte) body,
			headers = []http.Header{http.Header{key = "Content-Type", value = "multipart/form-data"}},
		}
		res: web.Response
		testenv.mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, http.Status.Bad_Request)
	}

	// too many fields hits the configured limit
	{
		e: testenv.Mw_Env
		testenv.mw_env_init(&e)
		defer testenv.mw_env_destroy(&e)
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
			headers = []http.Header{http.Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: web.Response
		testenv.mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, http.Status.Payload_Too_Large)
	}

	// an upload over the byte limit is refused before the handler runs
	{
		e: testenv.Mw_Env
		testenv.mw_env_init(&e)
		defer testenv.mw_env_destroy(&e)
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
			headers = []http.Header{http.Header{key = "Content-Type", value = "multipart/form-data; boundary=B"}},
		}
		res: web.Response
		testenv.mw_env_call(&e, &req, &res)
		testing.expect_value(t, res.status, http.Status.Payload_Too_Large)
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
		headers = []http.Header{http.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}},
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
		headers = []http.Header{http.Header{key = "Content-Type", value = "application/json"}},
	}
	testing.expect_value(t, len(web.request_form(&req_json)), 0)
	testing.expect_value(t, req_json.form_state, web.Form_State.Unparsed)
}
