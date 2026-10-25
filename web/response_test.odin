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
