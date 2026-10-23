#+feature dynamic-literals

package web

import "base:intrinsics"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:testing"
import "core:os"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// tb turns a string literal into bytes (transmute needs a typed value).
tb :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// test_repeat builds s repeated n times from allocator.
test_repeat :: proc(s: string, n: int, allocator: mem.Allocator) -> string {
	out := make([]byte, len(s) * n, allocator)
	for i in 0..<n {
		copy(out[i * len(s):], s)
	}
	return string(out)
}

dummy_handler :: proc(req: ^Request, res: ^Response) {
	response_write_string(res, "ok")
}

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

// ---------------------------------------------------------------------------
// router
// ---------------------------------------------------------------------------

@(test)
test_router_match_and_params :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_get(&r, "/users/:id", dummy_handler)
	router_post(&r, "/users", dummy_handler)
	router_get(&r, "/assets/*", dummy_handler)

	req: Request
	req.method = .Get
	req.path = "/users/42"
	route, ok := router_match(&r, &req, alloc)
	testing.expect(t, route != nil)
	testing.expect(t, ok)
	id, has_id := request_param(&req, "id")
	testing.expect(t, has_id)
	testing.expect(t, id == "42")

	// path matches, method does not
	req2: Request
	req2.method = .Delete
	req2.path = "/users"
	route2, ok2 := router_match(&r, &req2, alloc)
	testing.expect(t, route2 != nil)
	testing.expect(t, !ok2)

	// wildcard
	req3: Request
	req3.method = .Get
	req3.path = "/assets/css/app.css"
	route3, ok3 := router_match(&r, &req3, alloc)
	testing.expect(t, route3 != nil)
	testing.expect(t, ok3)

	// no match
	req4: Request
	req4.method = .Get
	req4.path = "/nope"
	route4, _ := router_match(&r, &req4, alloc)
	testing.expect(t, route4 == nil)
}

@(test)
test_router_middleware_chain :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_use(&r, middleware_mark_a, nil)
	router_use(&r, middleware_mark_b, nil)
	router_get(&r, "/chain", chain_final_handler)

	req: Request
	req.method = .Get
	req.path = "/chain"
	res: Response
	c: Conn
	response_init(&res, &c, alloc)
	router_handle_with(&r, &req, &res)

	testing.expect(t, strings.contains(string(buf_slice(&res.body)), "a>b>final"))
}

middleware_mark_a :: proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	response_write_string(res, "a>")
	router_next(r, idx + 1, final, req, res)
}

middleware_mark_b :: proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	response_write_string(res, "b>")
	router_next(r, idx + 1, final, req, res)
}

chain_final_handler :: proc(req: ^Request, res: ^Response) {
	response_write_string(res, "final")
}

// router_handle_with is router_handle with an explicit router (the public
// entry point reads the router out of server.user_ptr).
router_handle_with :: proc(r: ^Router, req: ^Request, res: ^Response) {
	route, method_ok := router_match(r, req, context.allocator)
	if route == nil {
		res.status = .Not_Found
		response_write_string(res, "404 page not found\n")
		return
	}
	if !method_ok {
		res.status = .Method_Not_Allowed
		response_write_string(res, "405 method not allowed\n")
		return
	}
	router_next(r, 0, route.handler, req, res)
}

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
// end-to-end: real sockets through the nbio event loop
// ---------------------------------------------------------------------------

Integration_Args :: struct {
	srv:  ^Server,
	done: ^bool,
}

integration_thread_proc :: proc(th: ^thread.Thread) {
	args := cast(^Integration_Args) th.data
	server_run_until(args.srv, args.done)
}

integration_handler :: proc(req: ^Request, res: ^Response) {
	if req.path == "/echo" {
		response_write(res, req.body)
		return
	}
	if req.path == "/emptyfile" {
		if !response_send_file(res, "/tmp/web_test_empty_file.bin") {
			res.status = .Internal_Error
			response_write_string(res, "could not open file\n")
		}
		return
	}
	response_set_header(res, "Content-Type", "text/plain")
	response_write_string(res, "hello integration")
}

@(test)
test_integration_request_response :: proc(t: ^testing.T) {
	done: bool
	srv: Server
	testing.expect(t, server_init(&srv, "127.0.0.1:0"))
	srv.handler = integration_handler
	srv.idle_timeout = 2 * time.Second

	args := Integration_Args{srv = &srv, done = &done}
	th := thread.create(integration_thread_proc)
	th.data = &args
	thread.start(th)
	defer thread.destroy(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))

	ep, _ := nbio.bound_endpoint(srv.listen_socket)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello"
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
		if bytes_contains(buf[:total], "\r\n\r\nhello") {
			break
		}
	}
	testing.expect(t, total > 0)
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Length: 5\r\n"))
	testing.expect(t, strings.contains(resp, "Connection: close\r\n"))
	testing.expect(t, strings.has_suffix(resp, "hello"))

	// wait for the server to observe the FIN and tear the connection down
	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.stats.conns_active) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	intrinsics.volatile_store(&done, true)
	thread.join(th)
	server_destroy(&srv)
}

@(test)
test_integration_bad_request :: proc(t: ^testing.T) {
	done: bool
	srv: Server
	testing.expect(t, server_init(&srv, "127.0.0.1:0"))
	srv.handler = integration_handler
	srv.idle_timeout = 2 * time.Second

	args := Integration_Args{srv = &srv, done = &done}
	th := thread.create(integration_thread_proc)
	th.data = &args
	thread.start(th)
	defer thread.destroy(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))

	ep, _ := nbio.bound_endpoint(srv.listen_socket)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	garbage := "NOT-HTTP\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte)garbage)
	testing.expect(t, serr == nil)
	testing.expect(t, n == len(garbage))

	buf: [4096]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
		if bytes_contains(buf[:total], "400") {
			break
		}
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 400 Bad Request\r\n"))

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.stats.conns_active) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	intrinsics.volatile_store(&done, true)
	thread.join(th)
	server_destroy(&srv)
}

// ---------------------------------------------------------------------------
// end-to-end: chunked bodies, pipelining, HEAD, empty files
// ---------------------------------------------------------------------------

// integration_spin starts a server on an ephemeral port and returns the
// endpoint plus the thread handle. The server and done flag are heap
// allocated; `integration_stop` frees them. Caller must stop.
integration_spin :: proc(t: ^testing.T, handler: Handler) -> (ep: net.Endpoint, th: ^thread.Thread, args: ^Integration_Args) {
	srv := new(Server, context.allocator)
	done := new(bool, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = handler
	srv.idle_timeout = 2 * time.Second

	args = new(Integration_Args, context.allocator)
	args.srv = srv
	args.done = done
	th = thread.create(integration_thread_proc)
	th.data = args
	thread.start(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))
	ep, _ = nbio.bound_endpoint(srv.listen_socket)
	return
}

integration_stop :: proc(t: ^testing.T, args: ^Integration_Args, th: ^thread.Thread) {
	srv := args.srv
	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.stats.conns_active) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	intrinsics.volatile_store(args.done, true)
	thread.join(th)
	thread.destroy(th)
	server_destroy(srv)
	free(args.done, context.allocator)
	free(srv, context.allocator)
	free(args, context.allocator)
}

@(test)
test_integration_chunked_request :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	// two chunks, no Content-Length
	request := "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
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
		if bytes_contains(buf[:total], "\r\n\r\nhello world") {
			break
		}
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Length: 11\r\n"))
	testing.expect(t, strings.has_suffix(resp, "hello world"))
}

@(test)
test_integration_pipelined_requests :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	// two requests back-to-back in a single write
	request := "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\nGET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
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
		if bytes_contains(buf[:total], "hello integrationhello integration") {
			break
		}
	}
	resp := string(buf[:total])
	// both responses must be present, in order
	first := strings.index(resp, "hello integration")
	second := strings.index(resp[first + 1:], "hello integration")
	testing.expect(t, first >= 0)
	testing.expect(t, second >= 0)
	testing.expect(t, strings.contains(resp, "Connection: keep-alive\r\n"))
}

@(test)
test_integration_head_request :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "HEAD / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, n == len(request))

	buf: [4096]byte
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
	testing.expect(t, strings.contains(resp, "Content-Length: 17\r\n"))
	// no body bytes after the head terminator
	testing.expect(t, strings.has_suffix(resp, "\r\n\r\n"))
}

@(test)
test_integration_empty_file :: proc(t: ^testing.T) {
	// create a zero-byte file for the handler to serve
	f, ferr := os.open("/tmp/web_test_empty_file.bin", {.Write, .Create})
	testing.expect(t, ferr == nil)
	os.close(f)

	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /emptyfile HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, n == len(request))

	buf: [4096]byte
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
	testing.expect(t, strings.contains(resp, "Content-Length: 0\r\n"))
	testing.expect(t, strings.has_suffix(resp, "\r\n\r\n"))
	os.remove("/tmp/web_test_empty_file.bin")
}

// ---------------------------------------------------------------------------
// reverse proxy
// ---------------------------------------------------------------------------

// test_conn_new builds a socket-free Conn for unit tests that touch the
// response/proxy parsing paths.
test_conn_new :: proc(t: ^testing.T) -> ^Conn {
	c := new(Conn, context.allocator)
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	buf_init(&c.inbuf, context.allocator)
	buf_init(&c.out, context.allocator)
	buf_init(&c.body_buf, context.allocator)
	buf_init(&c.proxy_req, context.allocator)
	buf_init(&c.proxy_buf, context.allocator)
	c.state = .Process
	response_reset(&c.res, c, conn_scratch(c))
	return c
}

test_conn_destroy :: proc(c: ^Conn) {
	buf_destroy(&c.inbuf)
	buf_destroy(&c.out)
	buf_destroy(&c.body_buf)
	buf_destroy(&c.proxy_req)
	buf_destroy(&c.proxy_buf)
	mem.dynamic_arena_destroy(&c.scratch)
	free(c, context.allocator)
}

@(test)
test_proxy_hop_by_hop_headers :: proc(t: ^testing.T) {
	testing.expect(t, is_hop_by_hop_header("Connection"))
	testing.expect(t, is_hop_by_hop_header("connection"))
	testing.expect(t, is_hop_by_hop_header("Keep-Alive"))
	testing.expect(t, is_hop_by_hop_header("Proxy-Connection"))
	testing.expect(t, is_hop_by_hop_header("Proxy-Authorization"))
	testing.expect(t, is_hop_by_hop_header("TE"))
	testing.expect(t, is_hop_by_hop_header("Trailer"))
	testing.expect(t, is_hop_by_hop_header("Transfer-Encoding"))
	testing.expect(t, is_hop_by_hop_header("Upgrade"))
	testing.expect(t, !is_hop_by_hop_header("Content-Type"))
	testing.expect(t, !is_hop_by_hop_header("Content-Length"))
	testing.expect(t, !is_hop_by_hop_header("X-Custom-Thing"))
}

@(test)
test_proxy_chunked_scan :: proc(t: ^testing.T) {
	s1 := "5\r\nhello\r\n0\r\n\r\n"
	complete, length := proxy_chunked_complete(transmute([]byte)s1)
	testing.expect(t, complete)
	testing.expect(t, length == 15)

	s2 := "5\r\nhello\r\n"
	complete2, _ := proxy_chunked_complete(transmute([]byte)s2)
	testing.expect(t, !complete2)

	s3 := "3\r\nabc\r\n4\r\ndefg\r\n0\r\nX-T: 1\r\n\r\n"
	complete3, length3 := proxy_chunked_complete(transmute([]byte)s3)
	testing.expect(t, complete3)
	testing.expect(t, length3 == 30)

	s4 := "zz\r\n"
	complete4, _ := proxy_chunked_complete(transmute([]byte)s4)
	testing.expect(t, !complete4)

	// chunk payload containing a fake terminator must not fool the scan
	s5 := "8\r\n0\r\n\r\nxyz\r\n0\r\n\r\n"
	complete5, length5 := proxy_chunked_complete(transmute([]byte)s5)
	testing.expect(t, complete5)
	testing.expect(t, length5 == 18)
}

@(test)
test_proxy_parse_upstream_head :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	c.req.method = .Get

	// content-length response: framing decided, hop-by-hop dropped
	r := proxy_parse_head(c, "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\nServer: up\r\n\r\n")
	testing.expect(t, r == .Ok)
	testing.expect(t, c.res.status == .Created)
	testing.expect(t, c.res.reason == "Created")
	testing.expect(t, c.proxy_framing == .Content_Length)
	testing.expect(t, c.proxy_remaining == 5)
	_, has_conn := response_header(&c.res, "Connection")
	testing.expect(t, !has_conn)
	cl, has_cl := response_header(&c.res, "Content-Length")
	testing.expect(t, has_cl)
	testing.expect(t, cl == "5")
	ct, has_ct := response_header(&c.res, "Content-Type")
	testing.expect(t, has_ct)
	testing.expect(t, ct == "text/plain")

	// chunked response: TE passes through, keep-alive preserved
	response_reset(&c.res, c, conn_scratch(c))
	r2 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
	testing.expect(t, r2 == .Ok)
	testing.expect(t, c.proxy_framing == .Chunked)
	te, has_te := response_header(&c.res, "Transfer-Encoding")
	testing.expect(t, has_te)
	testing.expect(t, te == "chunked")

	// close-delimited response: no framing headers, the relay re-frames it
	response_reset(&c.res, c, conn_scratch(c))
	r3 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
	testing.expect(t, r3 == .Ok)
	testing.expect(t, c.proxy_framing == .Until_Close)

	// 204 never carries a body
	response_reset(&c.res, c, conn_scratch(c))
	r4 := proxy_parse_head(c, "HTTP/1.1 204 No Content\r\n\r\n")
	testing.expect(t, r4 == .Ok)
	testing.expect(t, c.proxy_framing == .None)

	// HEAD: framing passes through but no body is expected
	response_reset(&c.res, c, conn_scratch(c))
	c.req.method = .Head
	r5 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n")
	testing.expect(t, r5 == .Ok)
	testing.expect(t, c.proxy_framing == .None)
	cl5, has_cl5 := response_header(&c.res, "Content-Length")
	testing.expect(t, has_cl5)
	testing.expect(t, cl5 == "42")
	c.req.method = .Get

	// 1xx informational heads are skipped
	response_reset(&c.res, c, conn_scratch(c))
	r6 := proxy_parse_head(c, "HTTP/1.1 100 Continue\r\n\r\n")
	testing.expect(t, r6 == .Skip)

	// unknown status codes pass through with the upstream reason
	response_reset(&c.res, c, conn_scratch(c))
	r7 := proxy_parse_head(c, "HTTP/1.1 599 Weird\r\nContent-Length: 0\r\n\r\n")
	testing.expect(t, r7 == .Ok)
	testing.expect(t, int(c.res.status) == 599)
	testing.expect(t, c.res.reason == "Weird")

	// malformed heads are rejected
	response_reset(&c.res, c, conn_scratch(c))
	r8 := proxy_parse_head(c, "garbage\r\n\r\n")
	testing.expect(t, r8 == .Malformed)
}

@(test)
test_proxy_no_upstream :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	req := Request{conn = c, method = .Get, path = "/"}
	p: Proxy // zero value: no upstreams
	proxy_serve_root(&p, &req, &c.res)
	testing.expect(t, c.res.status == .Bad_Gateway)
	testing.expect(t, c.state == .Process) // not hijacked into proxy mode
}

@(test)
test_proxy_round_robin :: proc(t: ^testing.T) {
	p: Proxy
	ok := proxy_init(&p, {"127.0.0.1:9001", "127.0.0.1:9002"})
	testing.expect(t, ok)
	defer proxy_destroy(&p)
	ep1, host1, idx1 := proxy_next_upstream(&p)
	ep2, host2, _ := proxy_next_upstream(&p)
	ep3, _, _ := proxy_next_upstream(&p)
	testing.expect(t, idx1 == 0)
	testing.expect(t, ep1.port == 9001)
	testing.expect(t, ep2.port == 9002)
	testing.expect(t, ep3.port == 9001) // wraps around
	testing.expect(t, host1 == "127.0.0.1:9001")
	testing.expect(t, host2 == "127.0.0.1:9002")

	bad: Proxy
	testing.expect(t, !proxy_init(&bad, {"not-an-address"}))
}

// integration_spin_srv starts an already-initialized server (handler and
// user_ptr set by the caller) on an ephemeral port.
integration_spin_srv :: proc(t: ^testing.T, srv: ^Server) -> (ep: net.Endpoint, th: ^thread.Thread, args: ^Integration_Args) {
	done := new(bool, context.allocator)
	args = new(Integration_Args, context.allocator)
	args.srv = srv
	args.done = done
	th = thread.create(integration_thread_proc)
	th.data = args
	thread.start(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))
	ep, _ = nbio.bound_endpoint(srv.listen_socket)
	return
}

// proxy_test_stop releases the upstream pool on the loop thread when the
// server stops: pooled sockets belong to that loop.
proxy_test_stop :: proc(s: ^Server) {
	if p := cast(^Proxy) s.user_ptr; p != nil {
		proxy_close_idle(p)
	}
}

// proxy_upstream_handler echoes what the proxy forwarded: method, target
// and the headers the proxy is required to add/rewrite.
proxy_upstream_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	response_write_string(res, "upstream ")
	response_write_string(res, method_string(req.method))
	response_write_string(res, " ")
	response_write_string(res, req.target)
	if v, ok := request_header(req, "X-Test"); ok {
		response_write_string(res, " xtest=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "X-Forwarded-For"); ok {
		response_write_string(res, " xff=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "X-Forwarded-Proto"); ok {
		response_write_string(res, " xfp=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Via"); ok {
		response_write_string(res, " via=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Host"); ok {
		response_write_string(res, " host=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Connection"); ok {
		response_write_string(res, " conn=")
		response_write_string(res, v)
	}
	response_write_string(res, " body=")
	response_write_string(res, string(req.body))
}

proxy_upstream_chunked_handler :: proc(req: ^Request, res: ^Response) {
	res.chunked = true
	response_write_string(res, "chunked-upstream ")
	response_write_string(res, req.target)
}

@(test)
test_integration_proxy_get :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.strip_prefix = "/api"
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	// stop the servers first (the proxy server's on_stop releases the
	// upstream pool on the loop thread), then drop the proxy
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /api/hello?x=1 HTTP/1.1\r\nHost: example.com\r\nX-Test: 42\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	// prefix stripped, query preserved, custom header forwarded
	testing.expect(t, strings.contains(resp, "upstream GET /hello?x=1"))
	testing.expect(t, strings.contains(resp, "xtest=42"))
	// proxy-added headers
	testing.expect(t, strings.contains(resp, "xff=127.0.0.1"))
	testing.expect(t, strings.contains(resp, "xfp=http"))
	testing.expect(t, strings.contains(resp, "via=1.1 " + SERVER_NAME))
	// Host rewritten to the upstream
	testing.expect(t, strings.contains(resp, "host=127.0.0.1:"))
	// upstream connections are pooled, so the proxy asks for keep-alive
	testing.expect(t, strings.contains(resp, "conn=keep-alive"))
	testing.expect(t, strings.has_suffix(resp, "body="))

	// The relayed body must not contain any part of the response head: the
	// proxy streams the head first and the body as it arrives, and arming a
	// second send while the head is still in flight would resend the head
	// bytes as body.
	head_end := strings.index(resp, "\r\n\r\n")
	testing.expect(t, head_end > 0)
	if head_end > 0 {
		body := resp[head_end + 4:]
		testing.expectf(t, strings.has_prefix(body, "upstream GET /hello?x=1"),
			"body does not start with the upstream payload: %q", body)
		testing.expectf(t, !strings.contains(body, "HTTP/1.1"),
			"body contains a second response head: %q", body)
	}
}

@(test)
test_integration_proxy_post_body :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "POST /echo HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nConnection: close\r\n\r\nping!"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "upstream POST /echo"))
	testing.expect(t, strings.has_suffix(resp, "body=ping!"))
}

@(test)
test_integration_proxy_chunked_upstream :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_chunked_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /chunked HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	// chunked framing is relayed verbatim, terminator included
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "chunked-upstream /chunked"))
	testing.expect(t, strings.has_suffix(resp, "\r\n0\r\n\r\n"))
}

// Raw_Upstream is a one-shot blocking HTTP server used to exercise
// close-delimited upstream responses (no Content-Length, no chunked).
Raw_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
}

raw_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	client, _, aerr := net.accept_tcp(l)
	if aerr != nil {
		net.close(l)
		return
	}
	buf: [4096]byte
	net.recv_tcp(client, buf[:]) // wait for the request to arrive
	response := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose-delimited body"
	net.send_tcp(client, transmute([]byte)response)
	net.close(client)
	net.close(l)
}

@(test)
test_integration_proxy_close_delimited :: proc(t: ^testing.T) {
	ru := new(Raw_Upstream, context.allocator)
	ru_th := thread.create(raw_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
		if intrinsics.volatile_load(&ru.ready) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&ru.ready))
	defer thread.join(ru_th)
	defer thread.destroy(ru_th)
	defer free(ru, context.allocator)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", ru.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /raw HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	// the close-delimited upstream body is streamed out re-framed as
	// chunked ("close-delimited body" is 20 bytes, so one 0x14 chunk)
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "Connection: close\r\n"))
	testing.expect(t, strings.has_suffix(resp, "14\r\nclose-delimited body\r\n0\r\n\r\n"))
}

@(test)
test_integration_proxy_upstream_refused :: proc(t: ^testing.T) {
	// bind and immediately release a port so dialing it is refused
	sock, lerr := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil)
	dead_ep, _ := net.bound_endpoint(sock)
	net.close(sock)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", dead_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /dead HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [4096]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 502 Bad Gateway\r\n"))
	testing.expect(t, strings.contains(resp, "upstream connect failed"))
}

// ---------------------------------------------------------------------------
// cookies
// ---------------------------------------------------------------------------

@(test)
test_cookie_serialize :: proc(t: ^testing.T) {
	// serialize on a stack arena: cookie_string allocates per attribute
	arena_buf: [8 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	// minimal: name=value only
	minimal := cookie_string(Cookie{name = "a", value = "b"}, alloc)
	testing.expect(t, minimal == "a=b")

	// full attribute set
	full := cookie_string(Cookie{
		name         = "session",
		value        = "abc",
		path         = "/app",
		domain       = "example.com",
		expires      = time.unix(784111777, 0), // 1994-11-06 08:49:37 UTC
		max_age_secs = 3600,
		secure       = true,
		http_only    = true,
		same_site    = .Lax,
	}, alloc)
	testing.expect(t, strings.has_prefix(full, "session=abc; "))
	testing.expect(t, strings.contains(full, "Path=/app"))
	testing.expect(t, strings.contains(full, "Domain=example.com"))
	testing.expect(t, strings.contains(full, "Expires=Sun, 06 Nov 1994 08:49:37 GMT"))
	testing.expect(t, strings.contains(full, "Max-Age=3600"))
	testing.expect(t, strings.contains(full, "Secure"))
	testing.expect(t, strings.contains(full, "HttpOnly"))
	testing.expect(t, strings.contains(full, "SameSite=Lax"))
	testing.expect(t, strings.has_suffix(full, "SameSite=Lax"))

	// zero expires / unset same-site are omitted
	bare := cookie_string(Cookie{name = "x", value = "y"}, alloc)
	testing.expect(t, !strings.contains(bare, "Expires"))
	testing.expect(t, !strings.contains(bare, "SameSite"))
	testing.expect(t, !strings.contains(bare, "Max-Age"))

	// empty name serializes to nothing
	testing.expect(t, cookie_string(Cookie{value = "v"}, alloc) == "")

	// strict / none variants
	strict := cookie_string(Cookie{name = "a", value = "b", same_site = .Strict}, alloc)
	testing.expect(t, strings.has_suffix(strict, "SameSite=Strict"))
	none := cookie_string(Cookie{name = "a", value = "b", same_site = .None}, alloc)
	testing.expect(t, strings.has_suffix(none, "SameSite=None"))
}

@(test)
test_cookie_request_parse :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	req := &c.req
	req.method = .Get
	req.conn = c

	head := "GET / HTTP/1.1\r\nHost: x\r\nCookie: token=xyz; theme=\"dark\"; flag\r\n\r\n"
	perr := parse_request(req, head, conn_scratch(c))
	testing.expect(t, perr == .None)

	v, ok := request_cookie(req, "token")
	testing.expect(t, ok)
	testing.expect(t, v == "xyz")

	// quoted values are unquoted
	theme, ok2 := request_cookie(req, "theme")
	testing.expect(t, ok2)
	testing.expect(t, theme == "dark")

	// valueless pair: no match, no crash
	_, ok3 := request_cookie(req, "flag")
	testing.expect(t, !ok3)

	// unknown name
	_, ok4 := request_cookie(req, "nope")
	testing.expect(t, !ok4)

	// no Cookie header at all
	req.headers = nil
	_, ok5 := request_cookie(req, "token")
	testing.expect(t, !ok5)

	// multiple Cookie headers are scanned
	req.headers = nil
	head2 := "GET / HTTP/1.1\r\nHost: x\r\nCookie: a=1\r\nCookie: b=2\r\n\r\n"
	testing.expect(t, parse_request(req, head2, conn_scratch(c)) == .None)
	av, _ := request_cookie(req, "a")
	bv, _ := request_cookie(req, "b")
	testing.expect(t, av == "1")
	testing.expect(t, bv == "2")

	// request_cookies parses all pairs
	cookies := request_cookies(req)
	testing.expect(t, len(cookies) == 2)
	testing.expect(t, cookies[0].name == "a" && cookies[0].value == "1")
	testing.expect(t, cookies[1].name == "b" && cookies[1].value == "2")
}

@(test)
test_cookie_response_build :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	w := &c.res
	response_set_cookie(w, Cookie{name = "session", value = "abc123", path = "/", http_only = true, same_site = .Lax})
	response_set_cookie(w, Cookie{name = "theme", value = "dark", max_age_secs = 3600})

	out: Buf
	buf_init(&out, context.allocator)
	defer buf_destroy(&out)
	response_build(w, &out, conn_scratch(c))

	resp := string(buf_slice(&out))
	// Set-Cookie does not fold: one header line per cookie
	testing.expect(t, strings.contains(resp, "Set-Cookie: session=abc123; Path=/; HttpOnly; SameSite=Lax\r\n"))
	testing.expect(t, strings.contains(resp, "Set-Cookie: theme=dark; Max-Age=3600\r\n"))
}

// ---------------------------------------------------------------------------
// json
// ---------------------------------------------------------------------------

@(test)
test_json_response :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	w := &c.res

	payload := map[string]string{"hello" = "world"}
	defer delete(payload)
	err := response_json(w, payload)
	testing.expect(t, err == nil)
	ct, has_ct := response_header(w, "Content-Type")
	testing.expect(t, has_ct)
	testing.expect(t, ct == "application/json")

	out: Buf
	buf_init(&out, context.allocator)
	defer buf_destroy(&out)
	response_build(w, &out, conn_scratch(c))
	resp := string(buf_slice(&out))
	testing.expect(t, strings.contains(resp, "Content-Type: application/json\r\n"))
	testing.expect(t, strings.has_suffix(resp, "{\"hello\":\"world\"}"))

	// nested structures marshal too
	response_reset(w, c, conn_scratch(c))
	Nested :: struct {
		name:  string,
		tags:  []string,
		count: int,
	}
	err2 := response_json(w, Nested{name = "x", tags = {"a", "b"}, count = 2})
	testing.expect(t, err2 == nil)
	testing.expect(t, strings.contains(string(buf_slice(&w.body)), "\"tags\":[\"a\",\"b\"]"))
}

// ---------------------------------------------------------------------------
// pattern routing
// ---------------------------------------------------------------------------

noop_handler :: proc(req: ^Request, res: ^Response) {}

@(test)
test_pattern_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern: string,
		path:    string,
		match:   bool,
		caps:    []string,
	}
	cases := []Case{
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/42", true, {"john", "42"}},
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/4x", false, nil},
		{"/x/(%d+)", "/x/42", true, {"42"}},
		{"/x/(%d+)", "/x/abc", false, nil},
		{"/static/(.-)%.html", "/static/a/b.html", true, {"a/b"}},
		{"/x/[a-c]+", "/x/abc", true, nil},
		{"/x/[a-c]+", "/x/abcd", false, nil},
		{"/x/[^0-9]+", "/x/abc", true, nil},
		{"/x/[^0-9]+", "/x/ab1", false, nil},
		{"^/api/(%w+)$", "/api/hello", true, {"hello"}},
		{"/x/(%w+)", "/x/a/b", false, nil}, // anchored to the whole path
		{"/x/(%w*)", "/x/", true, {""}},    // zero-width capture
		{"/x/(", "/x/a", false, nil},       // malformed pattern
		{"/x/(a)(b)", "/x/ab", true, {"a", "b"}},
		{"/x/(a)+", "/x/aaa", true, {"a"}}, // group quantifier keeps the last rep
		{"/x/(a)*", "/x/aaa", true, {"a"}},
		{"/x/(a)?", "/x/", true, {""}},
		{"/x/(a)?", "/x/a", true, {"a"}},
		{"/x/(.-)end", "/x/aaaend", true, {"aaa"}}, // lazy
		{"/x/(%d+)1", "/x/121", true, {"12"}},      // backtracking inside a class
		{"/a.b", "/axb", true, nil},                // pattern mode: '.' is any char
		{"/a%.b", "/a.b", true, nil},               // '%' opts into pattern mode
		{"/a%.b", "/axb", false, nil},
		{"/v1.0/status", "/v1.0/status", true, nil}, // segment mode, literal dot
	}
	for cse in cases {
		captures: [dynamic]string
		defer delete(captures)
		got := pattern_match(cse.pattern, cse.path, &captures)
		testing.expectf(t, got == cse.match, "pattern %q vs %q: expected %v, got %v", cse.pattern, cse.path, cse.match, got)
		if got && cse.match {
			testing.expectf(t, len(captures) == len(cse.caps), "pattern %q vs %q: expected %v captures, got %v", cse.pattern, cse.path, len(cse.caps), len(captures))
			for i in 0..<len(cse.caps) {
				if i < len(captures) {
					testing.expectf(t, captures[i] == cse.caps[i], "pattern %q vs %q: capture %d expected %q, got %q", cse.pattern, cse.path, i + 1, cse.caps[i], captures[i])
				}
			}
		}
	}
}

@(test)
test_pattern_route :: proc(t: ^testing.T) {
	arena_buf: [64 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	r: Router
	router_init(&r, alloc)
	defer router_destroy(&r)
	router_get(&r, "/users/(%d+)/posts/(%w+)", noop_handler)
	router_get(&r, "/files/(.-)%.html", noop_handler)
	// old-style patterns keep working next to pattern routes
	router_get(&r, "/legacy/:name", noop_handler)
	router_get(&r, "/wild/*", noop_handler)

	req := Request{method = .Get, path = "/users/42/posts/hello"}
	route, ok := router_match(&r, &req, alloc)
	testing.expect(t, ok)
	testing.expect(t, route != nil)
	c1, ok1 := request_capture(&req, 1)
	c2, ok2 := request_capture(&req, 2)
	testing.expect(t, ok1 && c1 == "42")
	testing.expect(t, ok2 && c2 == "hello")
	// request_capture is 1-based and bounds-checked
	_, ok3 := request_capture(&req, 0)
	testing.expect(t, !ok3)
	_, ok4 := request_capture(&req, 3)
	testing.expect(t, !ok4)

	req2 := Request{method = .Get, path = "/files/a/b/c.html"}
	_, ok5 := router_match(&r, &req2, alloc)
	testing.expect(t, ok5)
	dcap, _ := request_capture(&req2, 1)
	testing.expect(t, dcap == "a/b/c")

	// %d+ must not match letters
	req3 := Request{method = .Get, path = "/users/abc/posts/x"}
	route4, ok6 := router_match(&r, &req3, alloc)
	testing.expect(t, !ok6)
	testing.expect(t, route4 == nil)

	// :param still captures
	req4 := Request{method = .Get, path = "/legacy/ada"}
	_, ok7 := router_match(&r, &req4, alloc)
	testing.expect(t, ok7)
	pname, has_pname := request_param(&req4, "name")
	testing.expect(t, has_pname && pname == "ada")

	// '*' still matches the remainder
	req5 := Request{method = .Get, path = "/wild/anything/goes"}
	_, ok8 := router_match(&r, &req5, alloc)
	testing.expect(t, ok8)

	// method mismatch still reports 405
	req6 := Request{method = .Post, path = "/users/42/posts/hello"}
	_, ok9 := router_match(&r, &req6, alloc)
	testing.expect(t, !ok9)
}

// ---------------------------------------------------------------------------
// integration: cookies / json / pattern routes over the wire
// ---------------------------------------------------------------------------

cookie_handler :: proc(req: ^Request, res: ^Response) {
	token, _ := request_cookie(req, "token")
	theme, _ := request_cookie(req, "theme")
	response_write_string(res, "token=")
	response_write_string(res, token)
	response_write_string(res, " theme=")
	response_write_string(res, theme)
	response_set_cookie(res, Cookie{name = "session", value = "abc123", path = "/", http_only = true, same_site = .Lax})
	response_set_cookie(res, Cookie{name = "theme", value = "dark", max_age_secs = 3600})
}

@(test)
test_integration_cookie :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = cookie_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)

	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /cookie HTTP/1.1\r\nHost: example.com\r\nCookie: token=xyz; theme=\"dark\"\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Set-Cookie: session=abc123; Path=/; HttpOnly; SameSite=Lax\r\n"))
	testing.expect(t, strings.contains(resp, "Set-Cookie: theme=dark; Max-Age=3600\r\n"))
	testing.expect(t, strings.contains(resp, "token=xyz theme=dark"))
}

json_handler :: proc(req: ^Request, res: ^Response) {
	payload := map[string]string{"hello" = "world"}
	response_json(res, payload)
}

@(test)
test_integration_json :: proc(t: ^testing.T) {
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = json_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)

	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /json HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Type: application/json\r\n"))
	testing.expect(t, strings.has_suffix(resp, "{\"hello\":\"world\"}"))
}

pattern_handler :: proc(req: ^Request, res: ^Response) {
	id, _ := request_capture(req, 1)
	name, _ := request_capture(req, 2)
	response_write_string(res, "user=")
	response_write_string(res, id)
	response_write_string(res, " name=")
	response_write_string(res, name)
}

@(test)
test_integration_pattern_route :: proc(t: ^testing.T) {
	router: Router
	router_init(&router)
	defer router_destroy(&router)
	router_get(&router, "/users/(%d+)/(%w+)", pattern_handler)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)

	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /users/42/ada HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
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
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.has_suffix(resp, "user=42 name=ada"))

	// letters where %d+ is required: no route, 404
	client2, derr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr2 == nil)
	defer net.close(client2)
	request2 := "GET /users/abc/ada HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
	sn2, _ := net.send_tcp(client2, transmute([]byte)request2)
	testing.expect(t, sn2 == len(request2))
	total2 := 0
	for total2 < len(buf) {
		r, rerr := net.recv_tcp(client2, buf[total2:])
		if rerr != nil || r == 0 {
			break
		}
		total2 += r
	}
	testing.expect(t, strings.has_prefix(string(buf[:total2]), "HTTP/1.1 404 Not Found\r\n"))
}

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

// ---------------------------------------------------------------------------
// proxy streaming and upstream connection reuse
// ---------------------------------------------------------------------------

// read_client_all drains a client socket into an owned byte slice.
read_client_all :: proc(client: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte, context.allocator)
	buf: [8192]byte
	for {
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&out, ..buf[:r])
	}
	return out[:]
}

// Raw_Slow_Upstream answers one request with a close-delimited body that it
// hands over in two halves with a pause in between, which is what makes the
// difference between streaming and buffering observable.
Raw_Slow_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
	head:     string,
	tail:     string,
	pause:    time.Duration,
}

raw_slow_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Slow_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	client, _, aerr := net.accept_tcp(l)
	if aerr != nil {
		net.close(l)
		return
	}
	buf: [4096]byte
	net.recv_tcp(client, buf[:])
	net.send_tcp(client, transmute([]byte)ru.head)
	time.sleep(ru.pause)
	net.send_tcp(client, transmute([]byte)ru.tail)
	net.close(client)
	net.close(l)
}

@(test)
test_integration_proxy_streams_early :: proc(t: ^testing.T) {
	// the upstream sends its head and half the body, then stalls: a proxy
	// that buffers the whole response would keep the client silent for the
	// entire pause
	ru := new(Raw_Slow_Upstream, context.allocator)
	ru.head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nfirst-half "
	ru.tail = "second-half"
	ru.pause = 400 * time.Millisecond
	ru_th := thread.create(raw_slow_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
		if intrinsics.volatile_load(&ru.ready) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&ru.ready))
	defer thread.join(ru_th)
	defer thread.destroy(ru_th)
	defer free(ru, context.allocator)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", ru.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second
	defer free(p, context.allocator)
	defer proxy_destroy(p)

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	// the first half has to show up long before the pause is over
	start := time.now()
	first := make([dynamic]byte, context.allocator)
	defer delete(first)
	buf: [4096]byte
	for {
		if bytes_contains(first[:], "first-half") {
			break
		}
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&first, ..buf[:r])
	}
	elapsed := time.since(start)
	testing.expectf(t, bytes_contains(first[:], "first-half"), "first half never arrived: %q", string(first[:]))
	testing.expectf(t, elapsed < 250 * time.Millisecond, "first body bytes took %v: the proxy is buffering", elapsed)

	// and the rest still arrives, re-framed as chunked. Read until the
	// terminating chunk shows up (or the connection closes): the tail and
	// the terminator are separate writes, so stopping at "second-half"
	// would race against the final flush.
	for {
		if bytes_contains(first[:], "0\r\n\r\n") {
			break
		}
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&first, ..buf[:r])
	}
	resp := string(first[:])
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "first-half "))
	testing.expect(t, strings.contains(resp, "second-half"))
	testing.expect(t, strings.has_suffix(resp, "0\r\n\r\n"))
}

// Raw_Stale_Upstream answers the first request on a connection, promises
// keep-alive and then drops it anyway - the classic stale pooled connection.
Raw_Stale_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
	accepts:  int,
}

raw_stale_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Stale_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	for i in 0..<2 {
		client, _, aerr := net.accept_tcp(l)
		if aerr != nil {
			break
		}
		ru.accepts += 1
		buf: [4096]byte
		net.recv_tcp(client, buf[:])
		resp := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello"
		net.send_tcp(client, transmute([]byte)resp)
		time.sleep(50 * time.Millisecond)
		net.close(client) // promise broken
	}
	net.close(l)
}

@(test)
test_integration_proxy_stale_pool_retry :: proc(t: ^testing.T) {
	ru := new(Raw_Stale_Upstream, context.allocator)
	ru_th := thread.create(raw_stale_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
		if intrinsics.volatile_load(&ru.ready) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&ru.ready))
	defer thread.join(ru_th)
	defer thread.destroy(ru_th)
	defer free(ru, context.allocator)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", ru.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second
	defer free(p, context.allocator)
	defer proxy_destroy(p)

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)
	defer integration_stop(t, px_args, px_th)

	// first request: served, then the upstream socket is pooled and dies
	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	req := "GET /one HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	net.send_tcp(client, transmute([]byte)req)
	body := read_client_all(client)
	defer delete(body)
	net.close(client)
	testing.expect(t, strings.has_suffix(string(body), "hello"))
	testing.expect(t, len(p.pool) == 1)

	// let the upstream drop the pooled connection
	time.sleep(150 * time.Millisecond)

	// second request: the pooled socket is dead, the proxy has to retry
	client2, derr2 := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr2 == nil)
	net.send_tcp(client2, transmute([]byte)req)
	body2 := read_client_all(client2)
	defer delete(body2)
	net.close(client2)
	resp2 := string(body2)
	testing.expectf(t, strings.has_prefix(resp2, "HTTP/1.1 200 OK\r\n"), "retry did not recover: %q", resp2)
	testing.expect(t, strings.has_suffix(resp2, "hello"))
	testing.expect(t, ru.accepts == 2)
}

@(test)
test_integration_proxy_pool_reuse :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 10 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second
	defer free(p, context.allocator)
	defer proxy_destroy(p)

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)
	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)

	for i in 0..<3 {
		client, derr := net.dial_tcp_from_endpoint(px_ep)
		testing.expect(t, derr == nil)
		request := "GET /reuse HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]byte)request)
		body := read_client_all(client)
		net.close(client)
		defer delete(body)
		testing.expectf(t, strings.has_prefix(string(body), "HTTP/1.1 200 OK\r\n"), "request %d failed: %q", i, string(body))
		testing.expect(t, strings.has_suffix(string(body), "body="))
	}

	// three client connections, one upstream connection: the pool did its job
	testing.expectf(t, up_srv.stats.conns_opened == 1, "upstream saw %d connections, expected 1", up_srv.stats.conns_opened)
	testing.expectf(t, p.pool_hits == 2, "expected 2 pool hits, got %d", p.pool_hits)
}

// ---------------------------------------------------------------------------
// multi-acceptor mode (SO_REUSEPORT + one event loop per thread)
// ---------------------------------------------------------------------------

Multi_Acceptor_Args :: struct {
	servers: []^Server,
	done:    ^bool,
	ok:      bool,
}

multi_acceptor_thread :: proc(t: ^thread.Thread) {
	a := cast(^Multi_Acceptor_Args) t.data
	a.ok = server_run_multi(a.servers, a.done)
}

@(test)
test_integration_multi_acceptor :: proc(t: ^testing.T) {
	COUNT :: 3
	servers := make([]^Server, COUNT, context.allocator)
	defer delete(servers)
	for i in 0..<COUNT {
		s := new(Server, context.allocator)
		testing.expect(t, server_init(s, "127.0.0.1:0"))
		s.handler = integration_handler
		s.idle_timeout = 2 * time.Second
		servers[i] = s
	}
	done := new(bool, context.allocator)
	args := new(Multi_Acceptor_Args, context.allocator)
	args.servers = servers
	args.done = done

	th := thread.create(multi_acceptor_thread)
	th.data = args
	thread.start(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&servers[0].listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&servers[0].listening))
	port := servers[0].bound_port
	testing.expect(t, port != 0)

	// the ephemeral port is shared: every server reports the same one
	for i in 0..<COUNT {
		testing.expect(t, servers[i].bound_port == port)
	}

	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for i in 0..<30 {
		client, derr := net.dial_tcp_from_endpoint(ep)
		testing.expectf(t, derr == nil, "request %d: dial failed: %v", i, derr)
		if derr != nil {
			continue
		}
		request := "GET /echo HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]byte)request)
		body := read_client_all(client)
		net.close(client)
		resp := string(body)
		testing.expectf(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"), "request %d: %q", i, resp)
		delete(body)
	}

	intrinsics.volatile_store(done, true)
	thread.join(th)
	thread.destroy(th)

	testing.expect(t, args.ok)
	total := u64(0)
	spread := 0
	for i in 0..<COUNT {
		total += servers[i].stats.requests
		if servers[i].stats.requests > 0 {
			spread += 1
		}
	}
	testing.expectf(t, total == 30, "servers handled %d requests, expected 30", total)
	// Linux hashes the 4-tuple over the SO_REUSEPORT group, so a run of
	// distinct client ports lands on more than one acceptor. macOS accepts
	// the option but hands every connection to the most recently bound
	// listener, so there is nothing to assert there.
	when ODIN_OS == .Linux {
		testing.expectf(t, spread > 1, "all requests went to %d server(s): reuse_port not in effect", spread)
	}

	for i in 0..<COUNT {
		server_destroy(servers[i])
		free(servers[i], context.allocator)
	}
	free(args, context.allocator)
	free(done, context.allocator)
}

// ---------------------------------------------------------------------------
// TLS (OpenSSL loaded at run time)
// ---------------------------------------------------------------------------

TLS_CERT :: "web/testdata/cert.pem"
TLS_KEY :: "web/testdata/key.pem"

// test_tls_available reports whether libssl could be loaded; the TLS tests
// skip themselves when it cannot, so the suite still passes on a machine
// without OpenSSL.
test_tls_available :: proc() -> bool {
	return tls_load()
}

// Blocking TLS client used by the tests: a plain socket plus SSL_set_fd is
// all it takes when there is no event loop involved.
Tls_Test_Client :: struct {
	sock: net.TCP_Socket,
	ssl:  rawptr,
}

tls_test_connect :: proc(ep: net.Endpoint) -> (client: Tls_Test_Client, ok: bool) {
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		return {}, false
	}
	ctx := TLS.ctx_new(TLS.client_method())
	if ctx == nil {
		net.close(sock)
		return {}, false
	}
	defer TLS.ctx_free(ctx)

	ssl := TLS.ssl_new(ctx)
	if ssl == nil {
		net.close(sock)
		return {}, false
	}
	if TLS.set_fd(ssl, i32(sock)) != 1 {
		TLS.ssl_free(ssl)
		net.close(sock)
		return {}, false
	}
	TLS.set_connect_state(ssl)
	if TLS.do_handshake(ssl) != 1 {
		fmt.println("tls client handshake failed:", tls_last_error())
		TLS.ssl_free(ssl)
		net.close(sock)
		return {}, false
	}
	return Tls_Test_Client{sock = sock, ssl = ssl}, true
}

tls_test_write :: proc(client: ^Tls_Test_Client, data: string) -> bool {
	return TLS.write(client.ssl, raw_data(data), i32(len(data))) == i32(len(data))
}

// tls_test_read_all reads until the peer closes or the socket goes quiet.
tls_test_read_all :: proc(client: ^Tls_Test_Client) -> []byte {
	out := make([dynamic]byte, context.allocator)
	buf: [8192]byte
	for {
		n := TLS.read(client.ssl, raw_data(buf[:]), i32(len(buf)))
		if n <= 0 {
			break
		}
		append(&out, ..buf[:int(n)])
	}
	return out[:]
}

tls_test_close :: proc(client: ^Tls_Test_Client) {
	if client.ssl != nil {
		TLS.ssl_free(client.ssl)
		client.ssl = nil
	}
	if client.sock != 0 {
		net.close(client.sock)
		client.sock = 0
	}
}

@(test)
test_tls_config :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	testing.expect(t, cfg.ctx != nil)
	tls_config_destroy(&cfg)
	testing.expect(t, cfg.ctx == nil)

	// a missing file is reported, not silently ignored
	bad: Tls_Config
	testing.expect(t, !tls_config_init(&bad, "web/testdata/nope.pem", TLS_KEY))
}

tls_test_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	response_write_string(res, "secure ")
	response_write_string(res, req.target)
}

@(test)
test_integration_tls_get :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = tls_test_handler
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	request := "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, request))
	resp := tls_test_read_all(&client)
	defer delete(resp)

	body := string(resp)
	testing.expectf(t, strings.has_prefix(body, "HTTP/1.1 200 OK\r\n"), "unexpected response: %q", body)
	testing.expect(t, strings.has_suffix(body, "secure /hello"))
	testing.expect(t, server_has_requests(srv, 1))
}

server_has_requests :: proc(s: ^Server, n: u64) -> bool {
	return s.stats.requests == n
}

@(test)
test_integration_tls_keep_alive :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = tls_test_handler
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	// two requests on one TLS connection: the plaintext state machine has
	// to keep working behind the encryption layer
	r1 := "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n"
	testing.expect(t, tls_test_write(&client, r1))
	buf: [4096]byte
	total := 0
	for total < len(buf) {
		n := TLS.read(client.ssl, raw_data(buf[total:]), i32(len(buf) - total))
		if n <= 0 {
			break
		}
		total += int(n)
		if bytes_contains(buf[:total], "secure /one") {
			break
		}
	}
	first := string(buf[:total])
	testing.expectf(t, strings.contains(first, "secure /one"), "first response: %q", first)

	r2 := "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, r2))
	tail := tls_test_read_all(&client)
	defer delete(tail)
	testing.expect(t, strings.contains(string(tail), "secure /two"))
	testing.expect(t, srv.stats.requests == 2)
}

@(test)
test_integration_tls_static_file :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	// a file body goes through the read/encrypt/send loop, not sendfile
	path := "/tmp/web_test_tls_file.bin"
	content := make([]byte, 200 << 10, context.allocator)
	defer delete(content)
	for i in 0..<len(content) {
		content[i] = byte('a' + (i % 26))
	}
	{
		f, ferr := os.open(path, {.Write, .Create, .Trunc})
		testing.expect(t, ferr == nil)
		wn, werr := os.write(f, content)
		testing.expect(t, werr == nil)
		testing.expect(t, wn == len(content))
		os.close(f)
	}
	defer os.remove(path)

	st: Static
	static_init(&st, "/tmp")
	defer static_destroy(&st)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = static_serve
	srv.user_ptr = &st
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	request := "GET /web_test_tls_file.bin HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, request))
	resp := tls_test_read_all(&client)
	defer delete(resp)

	head_end := bytes_index(resp, "\r\n\r\n")
	testing.expect(t, head_end > 0)
	body := resp[head_end + 4:]
	testing.expectf(t, len(body) == len(content), "body is %d bytes, expected %d", len(body), len(content))
	if len(body) == len(content) {
		testing.expect(t, mem.compare(body, content) == 0)
	}
}
