package web

// Tests for the deflate/gzip content coding: the encoder itself
// and the filter that negotiates it.

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
// deflate / gzip content coding
// ---------------------------------------------------------------------------

@(test)
test_crc32 :: proc(t: ^testing.T) {
	// the standard check value for "123456789"
	testing.expect(t, crc32(tb("123456789")) == 0xCBF43926)
	testing.expect(t, crc32(nil) == 0)
	testing.expect(t, crc32(tb("")) == 0)
}

@(test)
test_deflate_roundtrip :: proc(t: ^testing.T) {
	arena_buf: [256 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	pat := "abcabcabc"
	repeat_buf := make([]byte, 4096, alloc)
	for i in 0..<len(repeat_buf) {
		repeat_buf[i] = pat[i % len(pat)]
	}
	random_buf := make([]byte, 2048, alloc)
	{
		x := u32(123456789)
		for i in 0..<len(random_buf) {
			x = x * 1103515245 + 12345
			random_buf[i] = byte(x >> 16)
		}
	}
	payloads := [][]byte{
		{},
		tb("a"),
		tb("hello hello hello hello world"),
		// highly repetitive: exercises long matches
		repeat_buf,
		// incompressible: pseudo-random bytes
		random_buf,
		// mixed text
		tb(test_repeat("The quick brown fox jumps over the lazy dog. ", 40, alloc)),
	}
	for i in 0..<len(payloads) {
		src := payloads[i]
		deflated := deflate_compress(src, alloc)
		testing.expectf(t, len(deflated) > 0 || len(src) == 0, "payload %d: empty deflate output", i)

		out: bytes.Buffer
		defer delete(out.buf)
		err := zlib.inflate_from_byte_array(deflated, &out, raw = true)
		testing.expectf(t, len(out.buf) == len(src), "payload %d: inflated %d bytes, expected %d", i, len(out.buf), len(src))
		if len(src) > 0 {
			testing.expectf(t, mem.compare(out.buf[:], src) == 0, "payload %d: inflated data mismatch", i)
		}
	}
}

@(test)
test_gzip_roundtrip :: proc(t: ^testing.T) {
	arena_buf: [256 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	src := tb(test_repeat("compress me! ", 200, alloc))
	gz := gzip_compress(src, alloc)
	// gzip magic + deflate method + no flags
	testing.expect(t, len(gz) > 18)
	testing.expect(t, gz[0] == 0x1F && gz[1] == 0x8B)
	testing.expect(t, gz[2] == 0x08)
	testing.expect(t, gz[3] == 0x00)

	out: bytes.Buffer
	defer delete(out.buf)
	err := gzip.load_from_bytes(gz, &out)
	testing.expect(t, err == nil)
	testing.expect(t, len(out.buf) == len(src))
	testing.expect(t, mem.compare(out.buf[:], src) == 0)

	// a corrupted CRC must be detected (proves the checksum is real)
	bad := clone_bytes(gz, alloc)
	bad[len(bad) - 5] ~= 0xFF
	out2: bytes.Buffer
	defer delete(out2.buf)
	err2 := gzip.load_from_bytes(bad, &out2)
	testing.expect(t, err2 != nil)
}

@(test)
test_gzip_distance_codes :: proc(t: ^testing.T) {
	// Every distance code must survive a strict inflater. DIST_EXTRA widens
	// once per *pair* of codes, so a single off-by-one there shifts the bit
	// stream by one bit as soon as a match is farther than 128 bytes: lenient
	// decoders still round-trip short repetitive payloads (all matches close
	// together), which is exactly how that bug hid. Walk one distance per
	// code instead: filler, then the same 64 bytes repeated at exactly that
	// distance.
	BLOCK :: 64
	for code in 0..<30 {
		arena_buf: [192 << 10]byte
		arena: mem.Arena
		mem.arena_init(&arena, arena_buf[:])
		alloc := mem.arena_allocator(&arena)

		dist := DIST_BASE[code]
		src := make([]byte, dist + BLOCK, alloc)
		// high-entropy bytes: no accidental long match except the crafted one
		x := u32(0x9E3779B9)
		for i in 0..<len(src) {
			x = x * 1664525 + 1013904223
			src[i] = byte(x >> 24)
		}
		copy(src[dist:], src[:BLOCK])

		gz := gzip_compress(src, alloc)
		out: bytes.Buffer
		err := gzip.load_from_bytes(gz, &out)
		testing.expectf(t, err == nil, "distance code %d (dist %d): %v", code, dist, err)
		if err == nil {
			testing.expectf(t, len(out.buf) == len(src), "distance code %d (dist %d): inflated %d bytes, want %d", code, dist, len(out.buf), len(src))
			testing.expectf(t, mem.compare(out.buf[:], src) == 0, "distance code %d (dist %d): payload mismatch", code, dist)
		}
	}
}

@(test)
test_content_type_compressible :: proc(t: ^testing.T) {
	testing.expect(t, content_type_compressible("text/html"))
	testing.expect(t, content_type_compressible("TEXT/CSS"))
	testing.expect(t, content_type_compressible("application/json"))
	testing.expect(t, content_type_compressible("application/javascript; charset=utf-8"))
	testing.expect(t, content_type_compressible("image/svg+xml"))
	testing.expect(t, !content_type_compressible("image/png"))
	testing.expect(t, !content_type_compressible("application/octet-stream"))
	testing.expect(t, !content_type_compressible(""))
}

compress_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	// a compressible payload: 4 KiB of a repeating phrase
	response_write_string(res, "the quick brown fox jumps over the lazy dog. ")
	for i in 0..<80 {
		response_write_string(res, "the quick brown fox jumps over the lazy dog. ")
	}
}

chunked_compress_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "application/json")
	res.chunked = true
	response_write_string(res, "{\"data\":\"")
	for i in 0..<100 {
		response_write_string(res, "aaaaaaaaaaaaaaaaaaaa")
	}
	response_write_string(res, "\"}")
}

@(test)
test_integration_gzip_filter :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = compress_handler
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
	head_end := bytes_index(buf[:total], "\r\n\r\n") + 4
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
	head_end3 := bytes_index(buf[:total3], "\r\n\r\n") + 4
	out3: bytes.Buffer
	defer delete(out3.buf)
	derr3b := zlib.inflate_from_byte_array(buf[head_end3:total3], &out3, raw = true)
	testing.expectf(t, derr3b == nil, "inflate failed: %v", derr3b)
	testing.expect(t, string(out3.buf[:]) == expected)
}

@(test)
test_integration_gzip_chunked :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = chunked_compress_handler
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

	head_end := bytes_index(buf[:total], "\r\n\r\n") + 4
	framed := buf[head_end:total]
	// de-chunk with the in-package decoder, then gunzip
	staged: Buf
	buf_init(&staged, context.allocator)
	defer buf_destroy(&staged)
	status, consumed := chunked_try_decode(framed, &staged)
	testing.expect(t, status == 1)
	testing.expect(t, consumed == len(framed))
	out: bytes.Buffer
	defer delete(out.buf)
	gerr := gzip.load_from_bytes(buf_slice(&staged), &out)
	testing.expectf(t, gerr == nil, "gunzip failed: %v", gerr)
	run_of_a := test_repeat("a", 2000, context.allocator)
	defer delete(run_of_a)
	expected := concat_strings({"{\"data\":\"", run_of_a, "\"}"}, context.allocator)
	defer delete(expected)
	testing.expect(t, string(out.buf[:]) == expected)
}

@(test)
test_integration_compress_skips :: proc(t: ^testing.T) {
	// small bodies, file bodies and already-coded bodies stay untouched
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = compress_skip_handler
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
	testing.expect(t, !bytes_contains(buf[:total], "Content-Encoding"))
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
	testing.expect(t, !bytes_contains(buf[:total3], "Content-Encoding"))
}

compress_skip_handler :: proc(req: ^Request, res: ^Response) {
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
