package web

import "base:intrinsics"
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
	testing.expect(t, c.proxy_state == .Content_Length)
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
	testing.expect(t, c.proxy_state == .Chunked)
	te, has_te := response_header(&c.res, "Transfer-Encoding")
	testing.expect(t, has_te)
	testing.expect(t, te == "chunked")

	// close-delimited response: no framing headers, connection must close
	response_reset(&c.res, c, conn_scratch(c))
	r3 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
	testing.expect(t, r3 == .Ok)
	testing.expect(t, c.proxy_state == .Until_Close)
	testing.expect(t, !c.res.keep_alive)

	// 204 never carries a body
	response_reset(&c.res, c, conn_scratch(c))
	r4 := proxy_parse_head(c, "HTTP/1.1 204 No Content\r\n\r\n")
	testing.expect(t, r4 == .Ok)
	testing.expect(t, c.proxy_state == .Done)

	// HEAD: framing passes through but no body is expected
	response_reset(&c.res, c, conn_scratch(c))
	c.req.method = .Head
	r5 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n")
	testing.expect(t, r5 == .Ok)
	testing.expect(t, c.proxy_state == .Done)
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
	ep1, host1 := proxy_next_upstream(&p)
	ep2, host2 := proxy_next_upstream(&p)
	ep3, _ := proxy_next_upstream(&p)
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
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	// stop the proxy first: it owns the upstream connections
	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)

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
	// upstream sees one-shot connection semantics
	testing.expect(t, strings.contains(resp, "conn=close"))
	testing.expect(t, strings.has_suffix(resp, "body="))
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
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)

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
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)

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
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, px_args, px_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)

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
	// the close-delimited upstream body is re-framed with a proxy
	// Content-Length of its own ("close-delimited body" is 20 bytes)
	testing.expect(t, strings.contains(resp, "Content-Length: 20\r\n"))
	testing.expect(t, strings.has_suffix(resp, "close-delimited body"))
	testing.expect(t, strings.contains(resp, "Connection: close\r\n"))
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
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, px_args, px_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)

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
