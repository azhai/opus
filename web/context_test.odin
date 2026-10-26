package web

// Tests for the application-facing helpers on Request/Response (the pieces a
// Go framework would call its context API). Everything here is decorative on
// top of the parser: the assertions pin the semantics so they do not drift.

import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"

// context_test_conn builds a Conn whose scratch arena the caller owns: the
// request allocator routes through it, so decoded strings are freed by
// dynamic_arena_destroy instead of tripping the test allocator's leak check.

@(test)
test_request_context_helpers :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.remote = net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 51234,
	}

	req: Request
	req.conn = &c
	req.method = .Get
	req.target = "/search?q=odin&tag=a&tag=b"
	req.path = "/search"
	req.query = "q=odin&tag=a&tag=b"
	req.headers = []Header {
		Header{key = "Host", value = "example.com:8080"},
		Header{key = "Content-Type", value = "Application/JSON; charset=utf-8"},
		Header{key = "Accept", value = "text/html, application/json;q=0.9"},
		Header{key = "X-Requested-With", value = "XMLHttpRequest"},
		Header{key = "X-Forwarded-For", value = "203.0.113.7, 10.0.0.1"},
	}

	testing.expect_value(t, request_content_type(&req), "application/json")
	testing.expect_value(t, request_host(&req), "example.com:8080")
	testing.expect_value(t, request_hostname(&req), "example.com")
	testing.expect_value(t, request_scheme(&req), "http")
	testing.expect_value(t, request_remote_addr(&req), "127.0.0.1:51234")
	testing.expect_value(t, request_client_ip(&req), "203.0.113.7")
	testing.expect(t, request_is_ajax(&req))
	testing.expect(t, request_accepts(&req, "application/json"))
	testing.expect(t, request_accepts(&req, "text/html"))
	testing.expect(t, !request_accepts(&req, "image/png"))

	// every query pair, in order, decoded the same way request_query decodes
	params := request_query_params(&req)
	testing.expect_value(t, len(params), 3)
	first, ok := param_get(params, "tag")
	testing.expect(t, ok)
	testing.expect_value(t, first, "a")
	q, has_q := request_query(&req, "q")
	testing.expect(t, has_q)
	testing.expect_value(t, q, "odin")
}

@(test)
test_request_hostname_variants :: proc(t: ^testing.T) {
	by_host :: proc(host: string) -> string {
		req := Request {
			headers = []Header{Header{key = "Host", value = host}},
		}
		return request_hostname(&req)
	}
	testing.expect_value(t, by_host("example.com:8080"), "example.com")
	testing.expect_value(t, by_host("example.com"), "example.com")
	testing.expect_value(t, by_host("[::1]:8080"), "::1")
	testing.expect_value(t, by_host("[fe80::1]"), "fe80::1")
	testing.expect_value(t, by_host(""), "")
}

@(test)
test_request_accepts_wildcards :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)

	// "type/*" matches every subtype of that type, nothing else
	req := Request {
		conn    = &c,
		headers = []Header{Header{key = "Accept", value = "text/*"}},
	}
	testing.expect(t, request_accepts(&req, "text/plain"))
	testing.expect(t, request_accepts(&req, "text/html; charset=utf-8"))
	testing.expect(t, !request_accepts(&req, "application/json"))

	// "*/*" accepts everything
	req_wild := Request {
		conn    = &c,
		headers = []Header{Header{key = "Accept", value = "*/*"}},
	}
	testing.expect(t, request_accepts(&req_wild, "image/png"))

	// q=0 is a refusal
	req_zero := Request {
		conn    = &c,
		headers = []Header{Header{key = "Accept", value = "application/json;q=0"}},
	}
	testing.expect(t, !request_accepts(&req_zero, "application/json"))

	// a missing Accept header accepts everything (RFC 7231 5.3.2)
	req_none := Request {
		conn = &c,
	}
	testing.expect(t, request_accepts(&req_none, "application/json"))
}

@(test)
test_request_json_binds_struct :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)

	User :: struct {
		name: string,
		id:   int,
	}

	req: Request
	req.conn = &c
	req.body = tb(`{"name":"ada","id":42}`)
	req.headers = []Header{Header{key = "Content-Type", value = "application/json"}}

	testing.expect_value(t, request_content_type(&req), "application/json")

	u: User
	err := request_json(&req, &u)
	testing.expect(t, err == nil)
	testing.expect_value(t, u.name, "ada")
	testing.expect_value(t, u.id, 42)

	// malformed bodies surface as an error instead of a silent zero value
	bad := Request {
		conn = &c,
		body = tb(`{"name":`),
	}
	v: User
	testing.expect(t, request_json(&bad, &v) != nil)
}

@(test)
test_response_error_and_disposition :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.req.method = .Get

	res: Response
	response_init(&res, &c, conn_scratch(&c))

	response_error(&res, .Not_Found)
	testing.expect_value(t, res.status, Status.Not_Found)
	testing.expect_value(t, string(buf_slice(&res.body)), "Not Found\n")
	ct, _ := response_header(&res, "Content-Type")
	testing.expect_value(t, ct, "text/plain; charset=utf-8")
	testing.expect_value(t, response_body_size(&res), i64(len("Not Found\n")))

	// set_content_type with an empty value removes the header
	response_set_content_type(&res, "")
	_, has_ct := response_header(&res, "Content-Type")
	testing.expect(t, !has_ct)

	// Content-Disposition quoting
	response_set_disposition(&res, .Attachment, `weird "name".txt`)
	cd, _ := response_header(&res, "Content-Disposition")
	testing.expect_value(t, cd, `attachment; filename="weird \"name\".txt"`)

	// ClearCookie: the only combination every browser honours
	res_cookie: Response
	response_init(&res_cookie, &c, conn_scratch(&c))
	response_clear_cookie(&res_cookie, "sysauth_molly")
	sc, _ := response_header(&res_cookie, "Set-Cookie")
	testing.expect(t, strings.contains(sc, "sysauth_molly=;"))
	testing.expect(t, strings.contains(sc, "Path=/"))
	testing.expect(t, strings.contains(sc, "Max-Age=0"))
	testing.expect(t, strings.contains(sc, "Expires=Thu, 01 Jan 1970"))
}

@(test)
test_response_json_status :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.req.method = .Post

	res: Response
	response_init(&res, &c, conn_scratch(&c))

	Payload :: struct {
		ok: bool,
	}
	testing.expect(t, response_json_status(&res, .Created, Payload{ok = true}) == nil)
	testing.expect_value(t, res.status, Status.Created)
	body := string(buf_slice(&res.body))
	testing.expect(t, strings.contains(body, `"ok"`))
	testing.expect(t, strings.contains(body, "true"))
}

@(test)
test_response_download_missing_file :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.req.method = .Get

	res: Response
	response_init(&res, &c, conn_scratch(&c))

	testing.expect(t, !response_download(&res, "/tmp/web_test_no_such_file.bin", "x.bin"))
	testing.expect_value(t, res.status, Status.Internal_Error)
	// the failure path must not leave a disposition behind
	_, has_cd := response_header(&res, "Content-Disposition")
	testing.expect(t, !has_cd)
}

@(test)
test_request_client_ip_precedence :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.remote = net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 1234,
	}

	// X-Real-IP wins over X-Forwarded-For
	req := Request {
		conn    = &c,
		headers = []Header {
			Header{key = "X-Real-IP", value = "203.0.113.9"},
			Header{key = "X-Forwarded-For", value = "198.51.100.1, 10.0.0.1"},
		},
	}
	testing.expect_value(t, request_client_ip(&req), "203.0.113.9")

	// without X-Real-IP, the leftmost X-Forwarded-For entry, trimmed
	req_xff := Request {
		conn    = &c,
		headers = []Header{Header{key = "X-Forwarded-For", value = " 198.51.100.2 , 10.0.0.1"}},
	}
	testing.expect_value(t, request_client_ip(&req_xff), "198.51.100.2")

	// an empty X-Real-IP is not an address: fall through to X-Forwarded-For
	req_empty := Request {
		conn    = &c,
		headers = []Header {
			Header{key = "X-Real-IP", value = "   "},
			Header{key = "X-Forwarded-For", value = "198.51.100.3"},
		},
	}
	testing.expect_value(t, request_client_ip(&req_empty), "198.51.100.3")

	// no forwarding header at all: the socket peer, without the port
	req_peer := Request{conn = &c}
	testing.expect_value(t, request_client_ip(&req_peer), "127.0.0.1")

	// no connection: no address to report
	req_none := Request{}
	testing.expect_value(t, request_client_ip(&req_none), "")
}

@(test)
test_request_is_ajax :: proc(t: ^testing.T) {
	ajax := Request {
		headers = []Header{Header{key = "X-Requested-With", value = "xmlhttprequest"}},
	}
	testing.expect(t, request_is_ajax(&ajax))

	fetch := Request {
		headers = []Header{Header{key = "X-Requested-With", value = "fetch"}},
	}
	testing.expect(t, !request_is_ajax(&fetch))

	testing.expect(t, !request_is_ajax(&Request{}))
}
