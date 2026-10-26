package web

// Tests for async.odin. The parking itself is exercised end-to-end over real
// sockets (a synthetic Conn would never arm an nbio operation), and the
// refusal rules are unit tested because they must cost nothing.

import "base:intrinsics"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

@(private = "file")
async_test_req: ^Request // the currently parked request

@(private = "file")
async_test_conn: ^Conn // its connection, for state assertions

@(private = "file")
async_test_closed: int // on_close invocations

@(private = "file")
async_test_hijacked: bool // the continuation got the socket

@(private = "file")
async_test_noop_resume :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {}

@(private = "file")
async_test_on_close :: proc(ud: rawptr) {
	async_test_closed += 1
}

@(private = "file")
async_test_on_park :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	response_write_string(res, "resumed\n")
}

@(private = "file")
async_test_on_hijack :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	socket, ok := response_hijack(res)
	if !ok {
		return
	}
	async_test_hijacked = true
	// ownership moved to the continuation, so closing is its job
	net.close(socket)
}

@(private = "file")
async_test_park :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	if !response_defer(res, async_test_on_park, nil, 0, async_test_on_close) {
		response_text(res, .Internal_Error, "cannot park\n")
		return
	}
	async_test_req = req
	async_test_conn = req.conn
}

@(private = "file")
async_test_park_hijack :: proc(req: ^Request, res: ^Response) {
	if !response_defer(res, async_test_on_hijack, nil) {
		response_text(res, .Internal_Error, "cannot park\n")
		return
	}
	async_test_req = req
	async_test_conn = req.conn
}

@(private = "file")
async_test_wake :: proc(req: ^Request, res: ^Response) {
	parked := async_test_req
	async_test_req = nil
	if parked == nil || !request_resume(parked) {
		response_text(res, .Conflict, "nothing parked\n")
		return
	}
	response_text(res, .OK, "woke\n")
}

@(private = "file")
async_test_once :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	response_write_string(res, "plain\n")
}

@(private = "file")
async_test_router_init :: proc(r: ^Router) {
	router_init(r)
	router_get(r, "/park", async_test_park)
	router_get(r, "/hijack", async_test_park_hijack)
	router_get(r, "/wake", async_test_wake)
	router_get(r, "/once", async_test_once)
}

@(private = "file")
async_test_buf: [8192]byte

@(private = "file")
async_test_send :: proc(sock: net.TCP_Socket, request: string) -> bool {
	_, err := net.send_tcp(sock, transmute([]byte)request)
	return err == nil
}

// async_test_drain reads until `needle` arrives or the receive times out. The
// result is backed by a file-scoped buffer, so it stays valid for the
// assertions that follow.
@(private = "file")
async_test_drain :: proc(sock: net.TCP_Socket, needle: string) -> string {
	_ = net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	n := 0
	for n < len(async_test_buf) {
		got, err := net.recv_tcp(sock, async_test_buf[n:])
		if err != nil || got <= 0 {
			break
		}
		n += got
		if strings.contains(string(async_test_buf[:n]), needle) {
			break
		}
	}
	return string(async_test_buf[:n])
}

@(private = "file")
async_test_wait_parked :: proc(t: ^testing.T) -> bool {
	for _ in 0 ..< 1000 {
		if async_test_conn != nil && async_test_conn.state == .Async {
			return true
		}
		time.sleep(time.Millisecond)
	}
	return testing.expectf(t, false, "the request was never parked")
}

// async_test_stop is integration_stop for a Server that lives on the stack and
// whose allocator the caller still needs to inspect afterwards.
@(private = "file")
async_test_stop :: proc(args: ^Integration_Args, th: ^thread.Thread) {
	for _ in 0 ..< 10000 {
		if intrinsics.volatile_load(&args.srv.stats.conns_active) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	intrinsics.volatile_store(args.done, true)
	thread.join(th)
	thread.destroy(th)
	server_destroy(args.srv)
	free(args.done, context.allocator)
	free(args, context.allocator)
}

// ---------------------------------------------------------------------------
// refusal rules
// ---------------------------------------------------------------------------

@(test)
test_async_defer_refusals :: proc(t: ^testing.T) {
	res: Response
	req: Request

	// nothing to park without a connection
	testing.expect(t, !response_defer(&res, async_test_noop_resume, nil))
	testing.expect(t, !request_defer(&req, &res, async_test_noop_resume, nil))

	c: Conn
	res.conn = &c
	req.conn = &c

	// a closed connection is never parked
	c.closed = true
	testing.expect(t, !response_defer(&res, async_test_noop_resume, nil))
	c.closed = false

	// a park with no continuation could never be resumed
	testing.expect(t, !response_defer(&res, nil, nil))

	// a second park would overwrite the continuation and orphan the timer
	c.state = .Async
	c.async = Async_State{resume = async_test_noop_resume, ud = &c}
	testing.expect(t, !response_defer(&res, async_test_on_park, nil))
	testing.expect(t, c.async.resume == async_test_noop_resume, "the refused park clobbered the live one")
	testing.expect(t, c.async.ud == &c)
	testing.expect(t, request_is_parked(&req))

	// resuming is refused when nothing is parked; the handler's request keeps
	// working (no nbio state is touched on these paths)
	c.state = .Process
	testing.expect(t, !request_is_parked(&req))
	testing.expect(t, !request_resume(&req))
	testing.expect(t, !request_is_parked(&Request{}))
	testing.expect(t, !request_resume(&Request{}))
}

// ---------------------------------------------------------------------------
// resume
// ---------------------------------------------------------------------------

/*
test_integration_async_resume_keeps_conn: after the continuation runs, the
connection is a plain keep-alive connection again. The parked request owned a
recv operation watching for the client going away; if that read survived the
resume it would compete with the keep-alive reader for the next request, and
the bytes would land in a callback that no longer drives the connection.
*/
@(test)
test_integration_async_resume_keeps_conn :: proc(t: ^testing.T) {
	async_test_req = nil
	async_test_conn = nil
	async_test_closed = 0
	defer {
		async_test_req = nil
		async_test_conn = nil
	}

	router: Router
	async_test_router_init(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	// long enough that only the parked read can answer for the client leaving
	srv.idle_timeout = 10 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, async_test_send(client, "GET /park HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	if !async_test_wait_parked(t) {
		return
	}

	waker, werr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, werr == nil)
	defer net.close(waker)
	testing.expect(t, async_test_send(waker, "GET /wake HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	woke := async_test_drain(waker, "woke")
	testing.expectf(t, strings.contains(woke, "woke"), "the waker got: %q", woke)

	got := async_test_drain(client, "resumed")
	testing.expectf(t, strings.contains(got, "resumed"), "the continuation never answered: %q", got)
	testing.expectf(t, strings.contains(got, "HTTP/1.1 200 OK"), "unexpected status: %q", got)

	for _ in 0 ..< 1000 {
		if async_test_conn.state == .Read_Head && async_test_conn.async_op == nil {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, async_test_conn.state == .Read_Head, "the connection did not return to reading")
	testing.expectf(t, async_test_conn.async_op == nil, "the parked recv outlived the resume")

	// the same reader must now pick up a second request
	testing.expect(t, async_test_send(client, "GET /once HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	second := async_test_drain(client, "plain")
	testing.expectf(t, strings.contains(second, "plain"), "the second request on the reused connection got: %q", second)
}

/*
test_integration_async_close_while_parked: the client leaving is noticed by the
parked read, not by the sweep (the idle timeout here is far longer than the
test), and `on_close` runs exactly once - it is the subscription cleanup hook.
*/
@(test)
test_integration_async_close_while_parked :: proc(t: ^testing.T) {
	async_test_req = nil
	async_test_conn = nil
	async_test_closed = 0
	defer {
		async_test_req = nil
		async_test_conn = nil
	}

	router: Router
	async_test_router_init(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 10 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	testing.expect(t, async_test_send(client, "GET /park HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	if !async_test_wait_parked(t) {
		return
	}

	net.close(client)

	for _ in 0 ..< 1000 {
		if async_test_closed > 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, async_test_closed == 1, "on_close ran %v time(s) for a parked disconnect", async_test_closed)
	time.sleep(100 * time.Millisecond)
	testing.expectf(t, async_test_closed == 1, "on_close ran %v time(s) after the connection was already down", async_test_closed)

	for _ in 0 ..< 1000 {
		if srv.stats.conns_active == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, srv.stats.conns_active == 0, "%v connection(s) still registered", srv.stats.conns_active)
}

/*
test_integration_async_hijack_frees_conn: a continuation that takes the socket
over with `response_hijack` leaves the Conn with no owner - the socket close
callback that normally frees it will never run. The Conn (and everything
allocated from its scratch arena) must be freed at that point, which the
tracking allocator makes visible: after the server is stopped, nothing the
server allocated may remain.
*/
@(test)
test_integration_async_hijack_frees_conn :: proc(t: ^testing.T) {
	async_test_req = nil
	async_test_conn = nil
	async_test_hijacked = false
	defer {
		async_test_req = nil
		async_test_conn = nil
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	router: Router
	async_test_router_init(&router)
	defer router_destroy(&router)

	srv: Server
	testing.expect(t, server_init(&srv, "127.0.0.1:0", mem.tracking_allocator(&track)))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 10 * time.Second
	ep, th, args := integration_spin_srv(t, &srv)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, async_test_send(client, "GET /hijack HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	if !async_test_wait_parked(t) {
		async_test_stop(args, th)
		return
	}

	waker, werr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, werr == nil)
	defer net.close(waker)
	testing.expect(t, async_test_send(waker, "GET /wake HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	woke := async_test_drain(waker, "woke")
	testing.expectf(t, strings.contains(woke, "woke"), "the continuation did not run: %q", woke)
	testing.expect(t, async_test_hijacked)

	async_test_stop(args, th)
	testing.expectf(t, track.current_memory_allocated == 0, "%v byte(s) the server allocated were never freed", track.current_memory_allocated)
}
