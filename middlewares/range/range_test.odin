package range

// Tests for the Range middleware: single ranges, unsatisfiable ranges, ETag
// preconditions, and the file-body pass-through.

import "../../web"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import "../../buffer"
import "../../http"
import "../../testenv"

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
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "Range", value = "bytes=10-19"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Partial_Content)
	if cr, ok := web.response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 10-19/100")
	}
	testing.expect_value(t, string(buffer.buf_slice(&res.body)), "0123456789")
	if ar, ok := web.response_header(&res, "Accept-Ranges"); testing.expect(t, ok) {
		testing.expect_value(t, ar, "bytes")
	}

	// suffix form: the last five bytes
	req_suffix := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "Range", value = "bytes=-5"}},
	}
	res_suffix: web.Response
	testenv.mw_env_call(&e, &req_suffix, &res_suffix)
	testing.expect_value(t, res_suffix.status, http.Status.Partial_Content)
	testing.expect_value(t, string(buffer.buf_slice(&res_suffix.body)), "56789")
	if cr, ok := web.response_header(&res_suffix, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes 95-99/100")
	}

	// several ranges are ignored: full body, 200
	req_multi := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "Range", value = "bytes=0-1,5-6"}},
	}
	res_multi: web.Response
	testenv.mw_env_call(&e, &req_multi, &res_multi)
	testing.expect_value(t, res_multi.status, http.Status.OK)
	testing.expect_value(t, len(res_multi.body.data), 100)

	// no Range header: untouched, and without etag config no extra headers
	req_plain := web.Request{method = .Get, path = "/r", target = "/r"}
	res_plain: web.Response
	testenv.mw_env_call(&e, &req_plain, &res_plain)
	testing.expect_value(t, res_plain.status, http.Status.OK)
	_, has_etag := web.response_header(&res_plain, "ETag")
	testing.expect(t, !has_etag)
}

@(test)
test_middleware_range_unsatisfiable :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "Range", value = "bytes=200-300"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.Range_Not_Satisfiable)
	if cr, ok := web.response_header(&res, "Content-Range"); testing.expect(t, ok) {
		testing.expect_value(t, cr, "bytes */100")
	}
}

@(test)
test_middleware_range_etag :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	cfg := Range_Config{etag = true}
	web.router_use(&e.router, middleware_range, &cfg)
	web.router_get(&e.router, "/r", range_handler)

	req := web.Request{method = .Get, path = "/r", target = "/r"}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	etag, has_etag := web.response_header(&res, "ETag")
	testing.expect(t, has_etag)
	testing.expect_value(t, len(etag), 18) // two quotes + 16 hex digits
	testing.expect(t, etag[0] == '"' && etag[len(etag) - 1] == '"')

	// revalidation
	req_304 := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "If-None-Match", value = etag}},
	}
	res_304: web.Response
	testenv.mw_env_call(&e, &req_304, &res_304)
	testing.expect_value(t, res_304.status, http.Status.Not_Modified)
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
		headers = []http.Header{http.Header{key = "If-None-Match", value = `"deadbeefdeadbeef"`}},
	}
	res_stale: web.Response
	testenv.mw_env_call(&e, &req_stale, &res_stale)
	testing.expect_value(t, res_stale.status, http.Status.OK)

	req_star := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header{http.Header{key = "If-None-Match", value = "*"}},
	}
	res_star: web.Response
	testenv.mw_env_call(&e, &req_star, &res_star)
	testing.expect_value(t, res_star.status, http.Status.Not_Modified)

	// If-Range with a matching tag keeps the range
	req_ifrange := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header {
			http.Header{key = "If-Range", value = etag},
			http.Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange: web.Response
	testenv.mw_env_call(&e, &req_ifrange, &res_ifrange)
	testing.expect_value(t, res_ifrange.status, http.Status.Partial_Content)
	testing.expect_value(t, string(buffer.buf_slice(&res_ifrange.body)), "0123")

	// If-Range with a stale tag falls back to the full body
	req_ifrange_stale := web.Request {
		method  = .Get,
		path    = "/r",
		target  = "/r",
		headers = []http.Header {
			http.Header{key = "If-Range", value = `"deadbeefdeadbeef"`},
			http.Header{key = "Range", value = "bytes=0-3"},
		},
	}
	res_ifrange_stale: web.Response
	testenv.mw_env_call(&e, &req_ifrange_stale, &res_ifrange_stale)
	testing.expect_value(t, res_ifrange_stale.status, http.Status.OK)
	testing.expect_value(t, len(res_ifrange_stale.body.data), 100)
}

@(test)
test_middleware_range_skips_file_responses :: proc(t: ^testing.T) {
	e: testenv.Mw_Env
	testenv.mw_env_init(&e)
	defer testenv.mw_env_destroy(&e)

	web.router_use(&e.router, middleware_range)
	web.router_get(&e.router, "/f", range_file_handler)

	req := web.Request {
		method  = .Get,
		path    = "/f",
		target  = "/f",
		headers = []http.Header{http.Header{key = "Range", value = "bytes=0-3"}},
	}
	res: web.Response
	testenv.mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, http.Status.OK) // sendfile path owns ranges
	_, has_cr := web.response_header(&res, "Content-Range")
	testing.expect(t, !has_cr)
}
