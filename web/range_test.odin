package web

// Tests for Range requests (RFC 7233): parsing, HTTP dates,
// If-Range and the static file paths that use them.

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
// range requests (RFC 7233)
// ---------------------------------------------------------------------------

@(test)
test_parse_byte_ranges :: proc(t: ^testing.T) {
	Case :: struct {
		header:   string,
		size:     i64,
		count:    int,
		decision: Range_Decision,
		first:    Byte_Range,
	}
	cases := []Case{
		{"bytes=0-4", 26, 1, .Single, Byte_Range{0, 5}},
		{"bytes=10-", 26, 1, .Single, Byte_Range{10, 16}},
		{"bytes=-5", 26, 1, .Single, Byte_Range{21, 5}},
		{"bytes=-100", 26, 1, .Single, Byte_Range{0, 26}}, // suffix past EOF
		{"bytes=0-1,3-4", 26, 2, .Multi, Byte_Range{0, 2}},
		{"bytes=20-100", 26, 1, .Single, Byte_Range{20, 6}}, // end clipped to size-1
		{"bytes=0-0", 26, 1, .Single, Byte_Range{0, 1}},
		{"bytes=100-200", 26, 0, .Unsatisfiable, {}},
		{"bytes=-0", 26, 0, .Unsatisfiable, {}},
		{"bytes=5-3", 26, 0, .Unsatisfiable, {}}, // last < first: dropped
		{"bytes=abc", 26, 0, .Ignore, {}},        // not a byte-range-set at all
		{"bytes=0-1,garbage", 26, 1, .Single, Byte_Range{0, 2}},
		{"items=0-4", 26, 0, .Ignore, {}}, // foreign unit
		{"bytes=0-1", 0, 0, .Unsatisfiable, {}},
	}
	for cse in cases {
		ranges, count, decision := parse_byte_ranges(cse.header, cse.size)
		testing.expectf(t, decision == cse.decision, "%q vs size %d: expected %v, got %v", cse.header, cse.size, cse.decision, decision)
		testing.expectf(t, count == cse.count, "%q vs size %d: expected %d ranges, got %d", cse.header, cse.size, cse.count, count)
		if count > 0 {
			testing.expectf(t, ranges[0] == cse.first, "%q: expected first range %v, got %v", cse.header, cse.first, ranges[0])
		}
	}
}

@(test)
test_parse_http_date :: proc(t: ^testing.T) {
	// 1994-11-06 08:49:37 UTC in all three formats
	tm, ok := parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
	testing.expect(t, ok)
	testing.expect(t, time.diff(tm, time.unix(784111777, 0)) == 0)

	tm2, ok2 := parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT")
	testing.expect(t, ok2)
	testing.expect(t, time.diff(tm2, tm) == 0)

	tm3, ok3 := parse_http_date("Sun Nov  6 08:49:37 1994")
	testing.expect(t, ok3)
	testing.expect(t, time.diff(tm3, tm) == 0)

	// case-insensitive month, extra whitespace
	tm4, ok4 := parse_http_date("sun, 06 nov 1994 08:49:37 gmt")
	testing.expect(t, ok4)
	testing.expect(t, time.diff(tm4, tm) == 0)

	// garbage
	_, ok5 := parse_http_date("not a date at all")
	testing.expect(t, !ok5)
	_, ok6 := parse_http_date("")
	testing.expect(t, !ok6)
}

@(test)
test_if_range_allowed :: proc(t: ^testing.T) {
	mod := time.unix(784111777, 0)
	// a later date means "unchanged since": the range applies
	testing.expect(t, if_range_allowed("Mon, 07 Nov 1994 00:00:00 GMT", mod))
	// an earlier date means it changed: full response
	testing.expect(t, !if_range_allowed("Sun, 06 Nov 1994 07:00:00 GMT", mod))
	// entity tags never match: this server emits no ETags
	testing.expect(t, !if_range_allowed("\"abc123\"", mod))
}

static_range_write_file :: proc(t: ^testing.T) -> (path: string, size: i64) {
	path = "/tmp/web_test_range_file.txt"
	content := "abcdefghijklmnopqrstuvwxyz"
	f, ferr := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, ferr == nil)
	n, werr := os.write(f, transmute([]byte)content)
	testing.expect(t, werr == nil)
	testing.expect(t, n == len(content))
	os.close(f)
	return path, i64(len(content))
}

@(test)
test_integration_static_range :: proc(t: ^testing.T) {
	path, size := static_range_write_file(t)
	defer os.remove(path)
	testing.expect(t, size == 26)

	st: Static
	static_init(&st, "/tmp")
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = static_serve
	srv.user_ptr = &st
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)
	defer static_destroy(&st)

	// --- single range: 206 with Content-Range, zero-copy sendfile path
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	request := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\nConnection: close\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte)request)
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
		if bytes_contains(buf[:total], "abcde") {
			break
		}
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 206 Partial Content\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Range: bytes 0-4/26\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Length: 5\r\n"))
	testing.expect(t, strings.contains(resp, "Accept-Ranges: bytes\r\n"))
	testing.expect(t, strings.has_suffix(resp, "abcde"))

	// --- open-ended and suffix ranges
	client2, derr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr2 == nil)
	defer net.close(client2)
	request2 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=-5\r\nConnection: close\r\n\r\n"
	net.send_tcp(client2, transmute([]byte)request2)
	total2 := 0
	for total2 < len(buf) {
		r, rerr := net.recv_tcp(client2, buf[total2:])
		if rerr != nil || r == 0 {
			break
		}
		total2 += r
		if bytes_contains(buf[:total2], "vwxyz") {
			break
		}
	}
	resp2 := string(buf[:total2])
	testing.expect(t, strings.has_prefix(resp2, "HTTP/1.1 206 Partial Content\r\n"))
	testing.expect(t, strings.contains(resp2, "Content-Range: bytes 21-25/26\r\n"))
	testing.expect(t, strings.has_suffix(resp2, "vwxyz"))

	// --- multiple ranges: multipart/byteranges
	client3, derr3 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr3 == nil)
	defer net.close(client3)
	request3 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-2,10-12\r\nConnection: close\r\n\r\n"
	net.send_tcp(client3, transmute([]byte)request3)
	total3 := 0
	for total3 < len(buf) {
		r, rerr := net.recv_tcp(client3, buf[total3:])
		if rerr != nil || r == 0 {
			break
		}
		total3 += r
		if bytes_contains(buf[:total3], "klm") {
			break
		}
	}
	resp3 := string(buf[:total3])
	testing.expect(t, strings.has_prefix(resp3, "HTTP/1.1 206 Partial Content\r\n"))
	testing.expect(t, strings.contains(resp3, "Content-Type: multipart/byteranges; boundary=SEPARATOR-"))
	testing.expect(t, strings.contains(resp3, "Content-Range: bytes 0-2/26\r\n"))
	testing.expect(t, strings.contains(resp3, "Content-Range: bytes 10-12/26\r\n"))
	testing.expect(t, strings.contains(resp3, "abc"))
	testing.expect(t, strings.contains(resp3, "klm"))
	testing.expect(t, strings.has_suffix(resp3, "--\r\n"))

	// --- unsatisfiable range: 416 with the full length
	client4, derr4 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr4 == nil)
	defer net.close(client4)
	request4 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=100-200\r\nConnection: close\r\n\r\n"
	net.send_tcp(client4, transmute([]byte)request4)
	total4 := 0
	for total4 < len(buf) {
		r, rerr := net.recv_tcp(client4, buf[total4:])
		if rerr != nil || r == 0 {
			break
		}
		total4 += r
	}
	resp4 := string(buf[:total4])
	testing.expect(t, strings.has_prefix(resp4, "HTTP/1.1 416 Range Not Satisfiable\r\n"))
	testing.expect(t, strings.contains(resp4, "Content-Range: bytes */26\r\n"))

	// --- garbage range unit: ignored, full 200
	client5, derr5 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr5 == nil)
	defer net.close(client5)
	request5 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: seconds=0-4\r\nConnection: close\r\n\r\n"
	net.send_tcp(client5, transmute([]byte)request5)
	total5 := 0
	for total5 < len(buf) {
		r, rerr := net.recv_tcp(client5, buf[total5:])
		if rerr != nil || r == 0 {
			break
		}
		total5 += r
		if bytes_contains(buf[:total5], "abcdefghijklmnopqrstuvwxyz") {
			break
		}
	}
	resp5 := string(buf[:total5])
	testing.expect(t, strings.has_prefix(resp5, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.has_suffix(resp5, "abcdefghijklmnopqrstuvwxyz"))

	// --- conditional GET: fresh cache copy answers 304
	client6, derr6 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr6 == nil)
	defer net.close(client6)
	request6 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: Fri, 23 Oct 2099 00:00:00 GMT\r\nConnection: close\r\n\r\n"
	net.send_tcp(client6, transmute([]byte)request6)
	total6 := 0
	for total6 < len(buf) {
		r, rerr := net.recv_tcp(client6, buf[total6:])
		if rerr != nil || r == 0 {
			break
		}
		total6 += r
	}
	resp6 := string(buf[:total6])
	testing.expect(t, strings.has_prefix(resp6, "HTTP/1.1 304 Not Modified\r\n"))
	testing.expect(t, !strings.contains(resp6, "Content-Length"))
	testing.expect(t, strings.has_suffix(resp6, "\r\n\r\n"))

	// --- If-Range with a stale validator: range ignored, full 200
	client7, derr7 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr7 == nil)
	defer net.close(client7)
	request7 := "GET /web_test_range_file.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-4\r\nIf-Range: Mon, 01 Jan 1990 00:00:00 GMT\r\nConnection: close\r\n\r\n"
	net.send_tcp(client7, transmute([]byte)request7)
	total7 := 0
	for total7 < len(buf) {
		r, rerr := net.recv_tcp(client7, buf[total7:])
		if rerr != nil || r == 0 {
			break
		}
		total7 += r
		if bytes_contains(buf[:total7], "abcdefghijklmnopqrstuvwxyz") {
			break
		}
	}
	resp7 := string(buf[:total7])
	testing.expect(t, strings.has_prefix(resp7, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.has_suffix(resp7, "abcdefghijklmnopqrstuvwxyz"))
}
