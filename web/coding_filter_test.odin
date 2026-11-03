package web

// Tests for the content-coding filter: wiring, not policy.

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
import "../buffer"
import "../http"
// ---------------------------------------------------------------------------
// content coding: the filter, end to end over a real socket
//
// The two rules the filter consults are tested where they live: Accept-Encoding
// negotiation and "is this media type worth coding" in http/coding_test.odin,
// the encoders in coding/*_test.odin. What is left here is the wiring - which
// bodies get coded, in which order the codings apply, and that the match-finder
// scratch is safe to share across responses.
// ---------------------------------------------------------------------------

coding_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	// a compressible payload: 4 KiB of a repeating phrase
	response_write_string(res, "the quick brown fox jumps over the lazy dog. ")
	for i in 0..<80 {
		response_write_string(res, "the quick brown fox jumps over the lazy dog. ")
	}
}

chunked_coding_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "application/json")
	res.chunked = true
	response_write_string(res, "{\"data\":\"")
	for i in 0..<100 {
		response_write_string(res, "aaaaaaaaaaaaaaaaaaaa")
	}
	response_write_string(res, "\"}")
}

@(test)
test_integration_coding_gzip :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = coding_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	// --- client accepts gzip: body is coded, Vary is set
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	request := "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip, deflate\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [64 << 10]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Encoding: gzip\r\n"))
	testing.expect(t, strings.contains(resp, "Vary: Accept-Encoding\r\n"))
	testing.expect(t, !strings.contains(resp, "Content-Length: 3680"))

	// gunzip the body and compare with the original payload
	head_end := buffer.bytes_index(buf[:total], "\r\n\r\n") + 4
	body := buf[head_end:total]
	out: bytes.Buffer
	defer delete(out.buf)
	gerr := gzip.load_from_bytes(body, &out)
	testing.expectf(t, gerr == nil, "gunzip failed: %v", gerr)
	expected := test_repeat("the quick brown fox jumps over the lazy dog. ", 81, context.allocator)
	defer delete(expected)
	testing.expect(t, string(out.buf[:]) == expected)

	// --- no Accept-Encoding: identity
	client2, derr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr2 == nil)
	defer net.close(client2)
	request2 := "GET /big HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	net.send_tcp(client2, transmute([]byte)request2)
	total2 := 0
	for total2 < len(buf) {
		r, rerr := net.recv_tcp(client2, buf[total2:])
		if rerr != nil || r == 0 {
			break
		}
		total2 += r
	}
	resp2 := string(buf[:total2])
	testing.expect(t, strings.has_prefix(resp2, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, !strings.contains(resp2, "Content-Encoding"))
	testing.expect(t, strings.has_suffix(resp2, expected))

	// --- deflate only
	client3, derr3 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr3 == nil)
	defer net.close(client3)
	request3 := "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: deflate\r\nConnection: close\r\n\r\n"
	net.send_tcp(client3, transmute([]byte)request3)
	total3 := 0
	for total3 < len(buf) {
		r, rerr := net.recv_tcp(client3, buf[total3:])
		if rerr != nil || r == 0 {
			break
		}
		total3 += r
	}
	resp3 := string(buf[:total3])
	testing.expect(t, strings.has_prefix(resp3, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp3, "Content-Encoding: deflate\r\n"))
	head_end3 := buffer.bytes_index(buf[:total3], "\r\n\r\n") + 4
	out3: bytes.Buffer
	defer delete(out3.buf)
	derr3b := zlib.inflate_from_byte_array(buf[head_end3:total3], &out3, raw = true)
	testing.expectf(t, derr3b == nil, "inflate failed: %v", derr3b)
	testing.expect(t, string(out3.buf[:]) == expected)
}

@(test)
test_integration_coding_chunked :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = chunked_coding_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	request := "GET /chunked HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [64 << 10]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	// both codings are announced: content-coding first, transfer-coding second
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Encoding: gzip\r\n"))
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))

	head_end := buffer.bytes_index(buf[:total], "\r\n\r\n") + 4
	framed := buf[head_end:total]
	// de-chunk with the in-package decoder, then gunzip
	staged: buffer.Buf
	buffer.buf_init(&staged, context.allocator)
	defer buffer.buf_destroy(&staged)
	status, consumed := http.chunked_decode(framed, &staged)
	testing.expect(t, status == 1)
	testing.expect(t, consumed == len(framed))
	out: bytes.Buffer
	defer delete(out.buf)
	gerr := gzip.load_from_bytes(buffer.buf_slice(&staged), &out)
	testing.expectf(t, gerr == nil, "gunzip failed: %v", gerr)
	run_of_a := test_repeat("a", 2000, context.allocator)
	defer delete(run_of_a)
	expected := buffer.concat_strings({"{\"data\":\"", run_of_a, "\"}"}, context.allocator)
	defer delete(expected)
	testing.expect(t, string(out.buf[:]) == expected)
}

@(test)
test_integration_coding_skips :: proc(t: ^testing.T) {
	// small bodies, file bodies and already-coded bodies stay untouched
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = coding_skip_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	// tiny body: below the threshold
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	request := "GET /small HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
	net.send_tcp(client, transmute([]byte)request)
	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	testing.expect(t, !buffer.bytes_contains(buf[:total], "Content-Encoding"))
	testing.expect(t, strings.has_suffix(string(buf[:total]), "tiny"))

	// already coded upstream: never double-coded
	client2, derr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr2 == nil)
	defer net.close(client2)
	request2 := "GET /coded HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
	net.send_tcp(client2, transmute([]byte)request2)
	total2 := 0
	for total2 < len(buf) {
		r, rerr := net.recv_tcp(client2, buf[total2:])
		if rerr != nil || r == 0 {
			break
		}
		total2 += r
	}
	resp2 := string(buf[:total2])
	testing.expect(t, strings.contains(resp2, "Content-Encoding: identity\r\n"))
	// exactly one Content-Encoding header
	first := strings.index(resp2, "Content-Encoding")
	testing.expect(t, strings.index(resp2[first + 1:], "Content-Encoding") < 0)

	// incompressible content type: untouched
	client3, derr3 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr3 == nil)
	defer net.close(client3)
	request3 := "GET /binary HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
	net.send_tcp(client3, transmute([]byte)request3)
	total3 := 0
	for total3 < len(buf) {
		r, rerr := net.recv_tcp(client3, buf[total3:])
		if rerr != nil || r == 0 {
			break
		}
		total3 += r
	}
	testing.expect(t, !buffer.bytes_contains(buf[:total3], "Content-Encoding"))
}

coding_skip_handler :: proc(req: ^Request, res: ^Response) {
	switch req.path {
	case "/small":
		response_set_header(res, "Content-Type", "text/plain")
		response_write_string(res, "tiny")
	case "/coded":
		response_set_header(res, "Content-Type", "text/plain")
		response_set_header(res, "Content-Encoding", "identity")
		response_write_string(res, test_repeat("already coded, plenty long enough to compress otherwise. ", 20, conn_scratch(req.conn)))
	case "/binary":
		response_set_header(res, "Content-Type", "image/png")
		response_write_string(res, test_repeat("not compressible by policy, plenty long enough. ", 20, conn_scratch(req.conn)))
	}
}

/*
test_deflate_shared_scratch: the match-finder tables are reused across calls,
with a rolling position base instead of a per-call clear. Reuse is what makes
the tables worth having, and it is also where a bug would hide: an entry left
by the previous input must be invisible to this one, or a match would point
into a buffer that no longer exists (a silent corruption, not a crash).
*/

// scratch_handler varies its payload by path so one connection can produce two
// responses that compress to different lengths.
scratch_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	n := 200
	if req.path == "/small" {
		n = 20 // above MIN_CODING_SIZE, but far shorter than /big
	}
	for i in 0 ..< n {
		response_write_string(res, "lorem ipsum dolor sit amet consectetur ")
	}
}

/*
test_integration_coding_scratch_reuse: the coding filter owns one match-finder
table for its whole life, so responses on the same server share it. The table
carries positions from earlier responses, and if those were not filtered out a
match would be emitted against bytes that belong to a different body - the
stream would still be well-formed and still inflate, just to the wrong data.

Two responses on one connection is the smallest case that catches it.
*/
@(test)
test_integration_coding_scratch_reuse :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	defer server_destroy(srv)
	srv.handler = scratch_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	// both requests on one keep-alive connection, pipelined
	requests := "GET /big HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n" +
		"GET /small HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)requests)
	testing.expect(t, serr == nil && sn == len(requests))

	_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
	buf := make([]byte, 64 << 10, context.allocator)
	defer delete(buf, context.allocator)
	total := 0
	seen := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || n <= 0 {
			break
		}
		// count complete responses by counting status lines
		for i := total; i + 9 <= total + n; i += 1 {
			if string(buf[i:i + 9]) == "HTTP/1.1 " {
				seen += 1
			}
		}
		total += n
		if seen >= 2 {
			// keep reading until the peer closes (Connection: close)
			continue
		}
	}
	stream := buf[:total]

	big := test_repeat("lorem ipsum dolor sit amet consectetur ", 200, context.allocator)
	defer delete(big)
	small := test_repeat("lorem ipsum dolor sit amet consectetur ", 20, context.allocator)
	defer delete(small)

	pos := 0
	for want, idx in ([2]string{big, small}) {
		head_end := buffer.bytes_index(stream[pos:], "\r\n\r\n")
		testing.expectf(t, head_end >= 0, "response %v has no head", idx)
		if head_end < 0 {
			return
		}
		head := string(stream[pos:pos + head_end])
		testing.expectf(t, strings.contains(head, "Content-Encoding: gzip"), "response %v is not coded: %v", idx, head)
		cl, ok := content_length_of(head)
		testing.expectf(t, ok, "response %v has no Content-Length", idx)
		body_start := pos + head_end + 4
		body := stream[body_start:body_start + cl]

		out: bytes.Buffer
		err := gzip.load_from_bytes(body, &out)
		testing.expectf(t, err == nil, "response %v did not inflate: %v", idx, err)
		testing.expectf(t, string(out.buf[:]) == string(want), "response %v inflated to the wrong bytes (%v vs %v)", idx, len(out.buf), len(want))
		delete(out.buf)

		pos = body_start + cl
	}
}

// content_length_of digs Content-Length out of a response head.
content_length_of :: proc(head: string) -> (int, bool) {
	rest := head
	for {
		nl := http.string_index(rest, "\r\n")
		if nl < 0 {
			return 0, false
		}
		line := rest[:nl]
		rest = rest[nl + 2:]
		if !http.eq_ignore_case(line, "Content-Length") && http.has_prefix_ignore_case(line, "content-length:") {
			if v, ok := buffer.parse_int(http.trim_ows(line[len("content-length:"):])); ok {
				return v, true
			}
		}
	}
}
