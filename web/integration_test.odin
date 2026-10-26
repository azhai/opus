#+feature dynamic-literals
package web

// End-to-end tests over real sockets through the nbio event
// loop, plus the fixtures they share: one thread running one
// server, and a helper to stop it cleanly.

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

/*
test_integration_pipeline_batch: a deep pipeline is answered in as few writes
as the batch cap allows (see conn_batch_next). What must not change is the
framing: every response follows the previous one exactly, a request that
carries a body still has that body consumed before the next request is parsed,
and the last response still closes the connection.

The body-carrying request sits in the middle of the burst on purpose. It is the
one hop where batching must be refused, because the input buffer then starts at
the body rather than at the next head.
*/
@(test)
test_integration_pipeline_batch :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	DEPTH :: 24
	PIPE_ECHO_BODY :: "abcde"

	req := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&req)
	for i in 0 ..< DEPTH {
		fmt.sbprintf(&req, "GET /n%v HTTP/1.1\r\nHost: localhost\r\n\r\n", i)
	}
	fmt.sbprintf(
		&req,
		"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\n%v",
		PIPE_ECHO_BODY,
	)
	fmt.sbprintf(&req, "GET /after HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	payload := strings.to_string(req)

	sent := 0
	for sent < len(payload) {
		n, serr := net.send_tcp(client, transmute([]byte)payload[sent:])
		testing.expect(t, serr == nil && n > 0)
		if serr != nil || n <= 0 {
			return
		}
		sent += n
	}

	data := make([]byte, 64 << 10, context.allocator)
	defer delete(data, context.allocator)
	total := 0
	for total < len(data) {
		n, rerr := net.recv_tcp(client, data[total:])
		if rerr != nil || n <= 0 {
			break // the server closed after the Connection: close request
		}
		total += n
	}

	// walk the stream response by response: head, then Content-Length bytes
	pos, count, echo_at := 0, 0, -1
	for pos < total {
		rel := bytes_index(data[pos:total], "\r\n\r\n")
		testing.expectf(t, rel >= 0, "response %v has no head terminator", count)
		if rel < 0 {
			break
		}
		head := transmute(string)data[pos : pos + rel]
		cl, has_len := content_length_of(head)
		testing.expectf(t, has_len, "response %v has no Content-Length: %v", count, head)
		body_start := pos + rel + 4
		if body_start + cl > total {
			testing.expectf(t, false, "response %v body is truncated", count)
			break
		}
		body := data[body_start : body_start + cl]
		if string(body) == PIPE_ECHO_BODY {
			echo_at = count
		}
		pos = body_start + cl
		count += 1
	}
	testing.expectf(t, count == DEPTH + 2, "got %v responses, want %v", count, DEPTH + 2)
	testing.expectf(t, echo_at == DEPTH, "echo arrived as response %v, want %v", echo_at, DEPTH)
	testing.expect(
		t,
		bytes_contains(data[:total], "Connection: close\r\n"),
		"the last response does not close the connection",
	)
}

/*
test_integration_pipeline_bad_request: a malformed request in the middle of a
pipeline must not cost the client the responses that came before it.

The error path used to clear the output buffer, which was correct while every
response was flushed on its own and wrong as soon as batching let earlier
responses wait there (conn_error truncates to `out_mark` instead). The client
sees the good responses, then the 400, then the close.
*/
@(test)
test_integration_pipeline_bad_request :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, integration_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n" +
		"GET /b HTTP/1.1\r\nHost: localhost\r\n\r\n" +
		"GET /bad HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n"
	sent := 0
	for sent < len(request) {
		n, serr := net.send_tcp(client, transmute([]byte)request[sent:])
		testing.expect(t, serr == nil && n > 0)
		if serr != nil || n <= 0 {
			return
		}
		sent += n
	}

	data := make([]byte, 16 << 10, context.allocator)
	defer delete(data, context.allocator)
	total := 0
	for total < len(data) {
		n, rerr := net.recv_tcp(client, data[total:])
		if rerr != nil || n <= 0 {
			break
		}
		total += n
	}

	stream := data[:total]
	testing.expect(t, bytes_contains(stream, "hello integration"))
	// both good bodies are present, then the 400, in that order
	first := bytes_index(stream, "hello integration")
	second := bytes_index(stream[first + 1:], "hello integration")
	bad := bytes_index(stream, "HTTP/1.1 400 Bad Request")
	testing.expectf(t, first >= 0 && second >= 0, "the batched responses were lost: %v", total)
	testing.expectf(t, bad > first + 1 + second, "the 400 came before the responses it followed: %v", total)
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