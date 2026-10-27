package web

/*
Tests for the static handler: the stat cache (pure), and the serving path
itself over a real socket (the conditional/Range behaviour only shows up
end to end).
*/

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"


/*
test_static_cache_bounded: the stat cache is bounded, so a client walking a
path space cannot grow it without limit. Negative lookups are cached too (that
is what keeps a 404 flood from becoming a stat storm), which makes an unbounded
cache both a memory leak and an obvious thing for an attacker to do.

What must survive eviction is the *hit* path: a file that keeps being requested
is refreshed on every lookup, so it is never the oldest entry.
*/
@(test)
test_static_cache_bounded :: proc(t: ^testing.T) {
	dir := "/tmp/opus-static-cache-bound"
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	file := concat_strings({dir, "/index.html"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("<html></html>")) == nil)

	st: Static
	static_init(&st, dir, context.allocator)
	defer static_destroy(&st)
	st.cfg.max_cache_entries = 32

	// 500 distinct misses: the cache must stay at or below its limit
	for i in 0 ..< 500 {
		path := fmt.aprintf("%v/missing-%v", dir, i, allocator = context.temp_allocator)
		_, found := static_lookup(&st, path)
		testing.expect(t, !found)
	}
	testing.expectf(t, len(st.cache) <= 32, "cache grew to %v entries", len(st.cache))

	// the real file is still served while the flood is going on
	for _ in 0 ..< 5 {
		entry, found := static_lookup(&st, file)
		testing.expect(t, found && entry.exists)
		testing.expectf(t, entry.size == 13, "size %v", entry.size)
	}
	testing.expectf(t, len(st.cache) <= 32, "cache grew to %v entries after hits", len(st.cache))

	// and the hit path keeps working after the cache has been evicted under it
	for i in 0 ..< 500 {
		path := fmt.aprintf("%v/other-%v", dir, i, allocator = context.temp_allocator)
		static_lookup(&st, path)
	}
	entry2, found2 := static_lookup(&st, file)
	testing.expect(t, found2 && entry2.exists)
}

// ---------------------------------------------------------------------------
// integration: the static handler over a real socket
// ---------------------------------------------------------------------------

Static_Test_Args :: struct {
	srv:  ^Server,
	done: ^bool,
	st:   ^Static,
}

static_test_thread_proc :: proc(th: ^thread.Thread) {
	args := cast(^Static_Test_Args) th.data
	server_run_until(args.srv, args.done)
}

/*
static_test_spin starts a static file server on an ephemeral port.

The stat cache TTL is stretched to an hour so a test can seed the mtime it
needs: HTTP dates carry one-second resolution, and the conditional tests
are precisely about a mtime that falls inside its own second.
*/
static_test_spin :: proc(
	t:   ^testing.T,
	dir: string,
) -> (ep: net.Endpoint, th: ^thread.Thread, args: ^Static_Test_Args) {
	srv := new(Server, context.allocator)
	done := new(bool, context.allocator)
	st := new(Static, context.allocator)
	static_init(st, dir, context.allocator)
	st.cfg.cache_ttl = time.Hour
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = static_serve
	srv.user_ptr = st
	srv.idle_timeout = 2 * time.Second

	args = new(Static_Test_Args, context.allocator)
	args.srv = srv
	args.done = done
	args.st = st
	th = thread.create(static_test_thread_proc)
	th.data = args
	thread.start(th)

	for i in 0 ..< 10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))
	ep, _ = nbio.bound_endpoint(srv.listen_socket)
	return
}

static_test_stop :: proc(t: ^testing.T, args: ^Static_Test_Args, th: ^thread.Thread) {
	srv := args.srv
	for i in 0 ..< 10000 {
		if intrinsics.volatile_load(&srv.stats.conns_active) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	intrinsics.volatile_store(args.done, true)
	thread.join(th)
	thread.destroy(th)
	static_destroy(args.st)
	free(args.st, context.allocator)
	server_destroy(srv)
	free(args.done, context.allocator)
	free(srv, context.allocator)
	free(args, context.allocator)
}

// static_test_exchange sends one request on a fresh connection and returns
// everything the server wrote back. Storage is temp: tests compare, not keep.
static_test_exchange :: proc(t: ^testing.T, ep: net.Endpoint, request: string) -> string {
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	_, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	return strings.clone(string(buf[:total]), context.temp_allocator)
}

// static_test_header pulls one header value out of a raw response head.
static_test_header :: proc(resp, name: string) -> string {
	want := concat_strings({name, ": "}, context.temp_allocator)
	rest := resp
	for {
		nl := strings.index(rest, "\r\n")
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 2:]
		} else {
			rest = ""
		}
		if strings.has_prefix(line, want) {
			return strings.clone(line[len(want):], context.temp_allocator)
		}
		if nl < 0 {
			return ""
		}
	}
}

// static_test_body is everything after the head terminator.
static_test_body :: proc(resp: string) -> string {
	i := strings.index(resp, "\r\n\r\n")
	if i < 0 {
		return ""
	}
	return resp[i + 4:]
}

/*
test_static_conditional_get_304: a client that cached our own Last-Modified
gets a 304 the next time it asks.

The trap is resolution: HTTP dates have one second, stat has nanoseconds.
A file written at 12:00:00.400 is advertised as 12:00:00, and a client
sending that back is asking about a time 400 ms *older* than the mtime -
so comparing raw timestamps says "changed" and the server re-sends the
whole file. Every conditional GET then misses, and the cache is dead
weight. The mtime has to be compared at the resolution it was published in.
*/
@(test)
test_static_conditional_get_304 :: proc(t: ^testing.T) {
	dir := "/tmp/opus-static-304"
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	content := "<html></html>"
	file := concat_strings({dir, "/index.html"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string(content)) == nil)

	ep, th, args := static_test_spin(t, dir)
	defer static_test_stop(t, args, th)

	// seed the cache, so the mtime is a fixed sub-second value on every
	// machine instead of whatever the filesystem happened to stamp
	st := args.st
	fs_path, ok := static_resolve_path(st, "/index.html", context.temp_allocator)
	testing.expect(t, ok)
	st.cache[clone_string(fs_path, st.allocator)] = Stat_Cache_Entry {
		exists  = true,
		size    = i64(len(content)),
		mod_utc = time.unix(1_700_000_000, 400_000_000),
		checked = time.now(),
	}

	first := static_test_exchange(
		t,
		ep,
		"GET /index.html HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
	)
	testing.expectf(t, strings.has_prefix(first, "HTTP/1.1 200 OK\r\n"), "got %v", first)
	lm := static_test_header(first, "Last-Modified")
	testing.expectf(t, lm != "", "no Last-Modified in %v", first)

	req := fmt.aprintf(
		"GET /index.html HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: %v\r\nConnection: close\r\n\r\n",
		lm,
		allocator = context.temp_allocator,
	)
	second := static_test_exchange(t, ep, req)
	testing.expectf(t, strings.has_prefix(second, "HTTP/1.1 304 Not Modified\r\n"), "got %v", second)

	// and a copy that really is older still gets the file
	stale := fmt.aprintf(
		"GET /index.html HTTP/1.1\r\nHost: x\r\nIf-Modified-Since: %v\r\nConnection: close\r\n\r\n",
		http_date(time.unix(1_600_000_000, 0), context.temp_allocator),
		allocator = context.temp_allocator,
	)
	third := static_test_exchange(t, ep, stale)
	testing.expectf(t, strings.has_prefix(third, "HTTP/1.1 200 OK\r\n"), "got %v", third)
}

/*
test_static_range_responses: one range, several ranges, and a range that
cannot be satisfied. The multipart path is the one worth pinning: its parts
must name their own range, and the body must be framed by the boundary that
the Content-Type advertises.
*/
@(test)
test_static_range_responses :: proc(t: ^testing.T) {
	dir := "/tmp/opus-static-range"
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	content := "0123456789abcdef"
	file := concat_strings({dir, "/a.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string(content)) == nil)

	ep, th, args := static_test_spin(t, dir)
	defer static_test_stop(t, args, th)

	st := args.st
	fs_path, ok := static_resolve_path(st, "/a.txt", context.temp_allocator)
	testing.expect(t, ok)
	st.cache[clone_string(fs_path, st.allocator)] = Stat_Cache_Entry {
		exists  = true,
		size    = i64(len(content)),
		mod_utc = time.unix(1_700_000_000, 0),
		checked = time.now(),
	}

	one := static_test_exchange(
		t,
		ep,
		"GET /a.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-3\r\nConnection: close\r\n\r\n",
	)
	testing.expectf(t, strings.has_prefix(one, "HTTP/1.1 206 Partial Content\r\n"), "got %v", one)
	testing.expect_value(t, static_test_header(one, "Content-Range"), "bytes 0-3/16")
	testing.expect_value(t, static_test_body(one), "0123")

	two := static_test_exchange(
		t,
		ep,
		"GET /a.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=0-1,4-5\r\nConnection: close\r\n\r\n",
	)
	testing.expectf(t, strings.has_prefix(two, "HTTP/1.1 206 Partial Content\r\n"), "got %v", two)
	ct := static_test_header(two, "Content-Type")
	testing.expect(t, strings.has_prefix(ct, "multipart/byteranges; boundary="))
	boundary := ct[len("multipart/byteranges; boundary="):]
	body := static_test_body(two)
	testing.expect(t, strings.contains(body, "Content-Range: bytes 0-1/16"))
	testing.expect(t, strings.contains(body, "Content-Range: bytes 4-5/16"))
	testing.expect(t, strings.has_prefix(body, concat_strings({"--", boundary, "\r\n"}, context.temp_allocator)))
	testing.expect(
		t,
		strings.has_suffix(body, concat_strings({"--", boundary, "--\r\n"}, context.temp_allocator)),
	)

	past := static_test_exchange(
		t,
		ep,
		"GET /a.txt HTTP/1.1\r\nHost: x\r\nRange: bytes=99-\r\nConnection: close\r\n\r\n",
	)
	testing.expectf(
		t,
		strings.has_prefix(past, "HTTP/1.1 416 Range Not Satisfiable\r\n"),
		"got %v",
		past,
	)
	testing.expect_value(t, static_test_header(past, "Content-Range"), "bytes */16")
}
