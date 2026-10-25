package web

// Tests for the request parser: request lines, headers, the
// zero-copy header views, url decoding and the chunked request decoder.

import "base:intrinsics"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
// ---------------------------------------------------------------------------
// request parser
// ---------------------------------------------------------------------------

@(test)
test_parse_simple_get :: proc(t: ^testing.T) {
	head := "GET /hello?name=odin HTTP/1.1\r\nHost: localhost:8080\r\nUser-Agent: web-test\r\n\r\n"
	req: Request
	err := parse_request(&req, head, context.allocator)
	testing.expect(t, err == .None)
	testing.expect(t, req.method == .Get)
	testing.expect(t, req.version.major == 1)
	testing.expect(t, req.version.minor == 1)
	testing.expect(t, req.path == "/hello")
	testing.expect(t, req.query == "name=odin")

	v, ok := request_header(&req, "host")
	testing.expect(t, ok)
	testing.expect(t, v == "localhost:8080")

	v2, ok2 := request_header(&req, "USER-AGENT")
	testing.expect(t, ok2)
	testing.expect(t, v2 == "web-test")

	q, okq := request_query(&req, "name")
	testing.expect(t, okq)
	testing.expect(t, q == "odin")

	_, missing := request_header(&req, "x-nope")
	testing.expect(t, !missing)
	delete(req.headers)
}

@(test)
test_parse_post_with_body_headers :: proc(t: ^testing.T) {
	head := "POST /submit HTTP/1.0\r\nContent-Length: 11\r\nContent-Type: text/plain\r\n\r\n"
	req: Request
	err := parse_request(&req, head, context.allocator)
	testing.expect(t, err == .None)
	testing.expect(t, req.method == .Post)
	testing.expect(t, req.version.minor == 0)

	v, ok := request_header(&req, "Content-Length")
	testing.expect(t, ok)
	testing.expect(t, v == "11")
	v2, ok2 := request_header(&req, "content-type")
	testing.expect(t, ok2)
	testing.expect(t, v2 == "text/plain")
	delete(req.headers)
}

@(test)
test_parse_bad_requests :: proc(t: ^testing.T) {
	cases := []string{
		"GARBAGE\r\n\r\n",
		"GET\r\n\r\n",
		"GET / HTTP/1.1\r\nbad-header-line\r\n\r\n",
		"GET / FTP/1.1\r\n\r\n",
	}
	for c in cases {
		req: Request
		err := parse_request(&req, c, context.allocator)
		testing.expectf(t, err != .None, "expected parse failure for %q", c)
		if req.headers != nil {
			delete(req.headers)
		}
	}
}

@(test)
test_parse_header_trimming :: proc(t: ^testing.T) {
	head := "GET / HTTP/1.1\r\nX-Pad:    spaced   \r\nX-Tabs:\ttabbed\t\r\n\r\n"
	req: Request
	err := parse_request(&req, head, context.allocator)
	testing.expect(t, err == .None)
	v, ok := request_header(&req, "X-Pad")
	testing.expect(t, ok)
	testing.expect(t, v == "spaced")
	delete(req.headers)
}

@(test)
test_url_decode_path :: proc(t: ^testing.T) {
	p, ok := url_decode_path("/a%20b/c%2Fd", context.allocator)
	testing.expect(t, ok)
	testing.expect(t, p == "/a b/c/d")

	p2, ok2 := url_decode_path("/plain/path", context.allocator)
	testing.expect(t, ok2)
	testing.expect(t, p2 == "/plain/path")
	delete(p)
}

// ---------------------------------------------------------------------------
// chunked codec
// ---------------------------------------------------------------------------

@(test)
test_chunked_decode_complete :: proc(t: ^testing.T) {
	body: Buf
	buf_init(&body, context.allocator)
	defer buf_destroy(&body)

	input := "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
	status, consumed := chunked_try_decode(transmute([]byte)input, &body)
	testing.expect(t, status == 1)
	testing.expect(t, consumed == len(input))
	testing.expect(t, string(buf_slice(&body)) == "hello world")
}

@(test)
test_chunked_decode_partial :: proc(t: ^testing.T) {
	body: Buf
	buf_init(&body, context.allocator)
	defer buf_destroy(&body)

	input := "5\r\nhel"
	status, _ := chunked_try_decode(transmute([]byte)input, &body)
	testing.expect(t, status == 0)
	testing.expect(t, buf_len(&body) == 0)
}

@(test)
test_chunked_decode_malformed :: proc(t: ^testing.T) {
	body: Buf
	buf_init(&body, context.allocator)
	defer buf_destroy(&body)

	status, _ := chunked_try_decode(transmute([]byte)string("zz\r\nnope\r\n"), &body)
	testing.expect(t, status == -1)
}
