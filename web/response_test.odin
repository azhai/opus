package web

// Tests for the response builder and the chunked response filter:
// the serialized head, HEAD bodies and chunk framing.

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
// response builder
// ---------------------------------------------------------------------------

@(test)
test_response_build :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	c: Conn
	c.req.method = .Get
	w: Response
	response_init(&w, &c, alloc)
	response_status(&w, .OK)
	response_set_header(&w, "Content-Type", "text/plain")
	response_write_string(&w, "hello")
	w.keep_alive = true

	out: Buf
	buf_init(&out, alloc)
	response_build(&w, &out, alloc)

	s := string(buf_slice(&out))
	testing.expect(t, strings.has_prefix(s, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(s, "Content-Length: 5\r\n"))
	testing.expect(t, strings.contains(s, "Content-Type: text/plain\r\n"))
	testing.expect(t, strings.contains(s, "Connection: keep-alive\r\n"))
	testing.expect(t, strings.contains(s, "Server: web-odin/"))
	testing.expect(t, strings.contains(s, "Date: "))
	testing.expect(t, strings.has_suffix(s, "\r\n\r\nhello"))
}

@(test)
test_response_head_has_no_body :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	c: Conn
	c.req.method = .Head
	w: Response
	response_init(&w, &c, alloc)
	response_write_string(&w, "hello")
	w.keep_alive = false

	out: Buf
	buf_init(&out, alloc)
	response_build(&w, &out, alloc)

	s := string(buf_slice(&out))
	testing.expect(t, strings.has_suffix(s, "\r\n\r\n"))
	testing.expect(t, !strings.has_suffix(s, "hello"))
	testing.expect(t, strings.contains(s, "Content-Length: 5\r\n"))
}

// ---------------------------------------------------------------------------
// chunked response filter
// ---------------------------------------------------------------------------

@(test)
test_filter_chunked :: proc(t: ^testing.T) {
	c: Conn
	c.req.method = .Post
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)

	w := &c.res
	response_init(w, &c, conn_scratch(&c))
	response_status(w, .OK)
	w.chunked = true
	w.keep_alive = false
	response_write_string(w, "hello")

	f: Chunked_Filter
	filter_chunked_init(&f)
	chunked_apply(&f.filter, &c)

	testing.expect(t, string(buf_slice(&w.body)) == "5\r\nhello\r\n0\r\n\r\n")
}

@(test)
test_filter_chunked_skips_files :: proc(t: ^testing.T) {
	c: Conn
	c.req.method = .Get
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)

	w := &c.res
	response_init(w, &c, conn_scratch(&c))
	w.chunked = true
	w.file_open = true // pretend a file body is pending

	f: Chunked_Filter
	filter_chunked_init(&f)
	chunked_apply(&f.filter, &c)

	testing.expect(t, !w.chunked)
}

// ---------------------------------------------------------------------------
// response shortcuts
// ---------------------------------------------------------------------------

@(test)
test_response_send_and_redirect :: proc(t: ^testing.T) {
	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.req.method = .Get

	res: Response
	response_init(&res, &c, conn_scratch(&c))

	response_send(&res, .Accepted, "application/json", `{"ok":true}`)
	testing.expect_value(t, res.status, Status.Accepted)
	ct, _ := response_header(&res, "Content-Type")
	testing.expect_value(t, ct, "application/json")
	testing.expect_value(t, string(buf_slice(&res.body)), `{"ok":true}`)

	// an empty content type leaves the header alone
	res2: Response
	response_init(&res2, &c, conn_scratch(&c))
	response_send(&res2, .OK, "", "raw")
	_, has_ct := response_header(&res2, "Content-Type")
	testing.expect(t, !has_ct)

	// 302 by default, with a small body for clients that ignore Location
	res3: Response
	response_init(&res3, &c, conn_scratch(&c))
	response_redirect(&res3, "/login")
	testing.expect_value(t, res3.status, Status.Found)
	loc, _ := response_header(&res3, "Location")
	testing.expect_value(t, loc, "/login")
	testing.expect_value(t, string(buf_slice(&res3.body)), "redirecting to /login\n")

	// a caller-chosen status is kept
	res4: Response
	response_init(&res4, &c, conn_scratch(&c))
	response_redirect(&res4, "https://example.com/new", .Moved_Permanently)
	testing.expect_value(t, res4.status, Status.Moved_Permanently)
}

@(test)
test_response_send_file_range :: proc(t: ^testing.T) {
	// nbio hands out file handles only once the thread has an event loop
	// (a server acquires one in server_run; a bare test has to ask for it)
	if err := nbio.acquire_thread_event_loop(); !testing.expectf(t, err == nil, "event loop: %v", err) {
		return
	}
	defer nbio.release_thread_event_loop()

	c: Conn
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	defer mem.dynamic_arena_destroy(&c.scratch)
	c.req.method = .Get

	path := "/tmp/web_response_range_test.bin"
	if err := os.write_entire_file(path, "0123456789"); !testing.expectf(t, err == nil, "cannot create fixture: %v", err) {
		return
	}
	defer os.remove(path)

	res: Response
	response_init(&res, &c, conn_scratch(&c))
	testing.expect(t, response_send_file_range(&res, path, 2, 3))
	defer nbio.close(res.file_handle)
	testing.expect(t, res.file_open)
	testing.expect_value(t, res.file_size, i64(3))
	testing.expect_value(t, res.file_offset, 2)
	testing.expect_value(t, res.file_path, path)

	// only one file body can be queued per response
	testing.expect(t, !response_send_file_range(&res, path, 0, 1))

	// bad ranges are rejected before anything is opened
	res_bad: Response
	response_init(&res_bad, &c, conn_scratch(&c))
	testing.expect(t, !response_send_file_range(&res_bad, path, -1, 2))
	testing.expect(t, !response_send_file_range(&res_bad, path, 0, -2))
	testing.expect(t, !response_send_file_range(&res_bad, "/tmp/web_no_such_file_xyz.bin", 0, 1))
	testing.expect(t, !res_bad.file_open)
}
