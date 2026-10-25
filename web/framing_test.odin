package web

// Tests for strict request framing (RFC 7230 section 3.3.3):
// the request-splitting defenses.

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
// strict request framing (RFC 7230 section 3.3.3, smuggling defense)
// ---------------------------------------------------------------------------

@(test)
test_request_framing_strict :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	Case :: struct {
		head: string,
		kind: Body_Kind,
		len:  int,
		err:  Framing_Error,
	}
	cases := []Case{
		// plain requests
		{"GET / HTTP/1.1\r\nHost: x\r\n\r\n", .None, 0, .None},
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n", .Length, 5, .None},
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .Length, 0, .None},
		// chunked, including compound codings with chunked last
		{"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", .Chunked, 0, .None},
		{"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", .Chunked, 0, .None},
		{"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n", .Chunked, 0, .None},
		// smuggling vectors
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", .None, 0, .TE_And_CL},
		{"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n", .None, 0, .TE_Unsupported},
		{"POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n", .None, 0, .TE_Unsupported},
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n", .None, 0, .CL_Conflict},
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\n", .None, 0, .CL_Conflict},
		// identical duplicates collapse (RFC 7230 section 3.3.2)
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n", .Length, 5, .None},
		// invalid lengths
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: abc\r\n\r\n", .None, 0, .CL_Invalid},
		{"POST / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", .None, 0, .CL_Invalid},
	}
	for cse in cases {
		req: Request
		perr := parse_request(&req, cse.head, alloc)
		testing.expectf(t, perr == .None, "%q: parse failed: %v", cse.head, perr)
		if perr != .None {
			continue
		}
		kind, length, err := request_framing(&req)
		testing.expectf(t, err == cse.err, "%q: expected %v, got %v", cse.head, cse.err, err)
		testing.expectf(t, kind == cse.kind, "%q: expected kind %v, got %v", cse.head, cse.kind, kind)
		testing.expectf(t, length == cse.len, "%q: expected length %d, got %d", cse.head, cse.len, length)
	}
}

@(test)
test_proxy_strict_upstream_head :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	c.req.method = .Get

	// TE + CL together: a smuggling vector, not relayed
	response_reset(&c.res, c, conn_scratch(c))
	r := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n")
	testing.expect(t, r == .Malformed)

	// conflicting Content-Length values
	response_reset(&c.res, c, conn_scratch(c))
	r2 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n")
	testing.expect(t, r2 == .Malformed)

	// list-valued Content-Length
	response_reset(&c.res, c, conn_scratch(c))
	r3 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\n\r\n")
	testing.expect(t, r3 == .Malformed)

	// a TE whose final coding is not chunked has no framing we relay
	response_reset(&c.res, c, conn_scratch(c))
	r4 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n")
	testing.expect(t, r4 == .Malformed)

	// identical duplicate Content-Length still collapses
	response_reset(&c.res, c, conn_scratch(c))
	r5 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n")
	testing.expect(t, r5 == .Ok)
	testing.expect(t, c.proxy_remaining == 5)
}

@(test)
test_integration_strict_framing :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	smuggle_attempts := []string{
		// TE and CL together: the classic desync
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n",
		// conflicting Content-Length values
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\nConnection: close\r\n\r\nhello",
		// list-valued Content-Length
		"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\nConnection: close\r\n\r\nhello",
		// unsupported transfer coding
		"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\nConnection: close\r\n\r\n",
	}
	for attempt in smuggle_attempts {
		client, derr := net.dial_tcp_from_endpoint(ep)
		testing.expect(t, derr == nil)
		sn, serr := net.send_tcp(client, transmute([]byte)attempt)
		testing.expect(t, serr == nil)
		testing.expect(t, sn == len(attempt))
		buf: [4096]byte
		total := 0
		for total < len(buf) {
			r, rerr := net.recv_tcp(client, buf[total:])
			if rerr != nil || r == 0 {
				break
			}
			total += r
			if bytes_contains(buf[:total], "\r\n\r\n") {
				break
			}
		}
		resp := string(buf[:total])
		testing.expectf(t, strings.has_prefix(resp, "HTTP/1.1 400 Bad Request\r\n"), "expected 400 for %q, got %q", attempt, resp)
		net.close(client)
	}

	// a plain chunked request still works (the strict checks must not
	// reject legitimate framing)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	request := "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))
	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
		if bytes_contains(buf[:total], "hello") {
			break
		}
	}
	testing.expect(t, strings.has_prefix(string(buf[:total]), "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.has_suffix(string(buf[:total]), "hello"))
}
