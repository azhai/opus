package web

import "base:intrinsics"
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
