package web

// Tests for the async response machinery (async.odin) and the fan-out hub
// (hub.odin). Both are about *not* blocking the event loop, so every case
// here runs over real sockets: a unit test with a synthetic Conn would not
// prove anything about parking and resuming.

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// hub_test_drain reads from `sock` until `needle` shows up or the deadline
// passes, and returns everything read so far.
//
// The buffer is file-scoped on purpose: returning a slice of a local array
// leaves the caller with a dangling pointer, and the very next call (the
// `testing.expectf` below every drain) reuses that stack and silently
// corrupts the bytes - which shows up as a missing status line that was in
// fact received.
@(private = "file")
hub_test_buf: [8192]byte

@(private = "file")
hub_test_len: int

@(private = "file")
hub_test_drain :: proc(sock: net.TCP_Socket, needle: string) -> (got: string, ok: bool) {
	_ = net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	hub_test_len = 0
	for hub_test_len < len(hub_test_buf) {
		n, err := net.recv_tcp(sock, hub_test_buf[hub_test_len:])
		if err != nil || n <= 0 {
			break
		}
		hub_test_len += n
		if strings.contains(string(hub_test_buf[:hub_test_len]), needle) {
			return string(hub_test_buf[:hub_test_len]), true
		}
	}
	return string(hub_test_buf[:hub_test_len]), false
}

@(private = "file")
hub_test_send_request :: proc(sock: net.TCP_Socket, request: string) -> bool {
	_, err := net.send_tcp(sock, transmute([]byte)request)
	return err == nil
}

// ---------------------------------------------------------------------------
// hub
// ---------------------------------------------------------------------------

@(private = "file")
hub_test_state: ^Hub

@(private = "file")
hub_events :: proc(req: ^Request, res: ^Response) {
	hub_subscribe(hub_test_state, req, res)
}

@(private = "file")
hub_publish :: proc(req: ^Request, res: ^Response) {
	msg, _ := request_form_value(req, "msg")
	event, _ := request_form_value(req, "event")
	hub_send(hub_test_state, event, msg, "1")
	response_text(res, .OK, "sent\n")
}

@(private = "file")
hub_count :: proc(req: ^Request, res: ^Response) {
	buf: [64]byte
	stats := hub_stats(hub_test_state)
	msg := fmt.bprintf(buf[:], "%v/%v/%v/%v\n", stats.subscribers, stats.published, stats.delivered, stats.skipped)
	response_text(res, .OK, msg)
}

// hub_relax raises the per-subscriber queue back to the default, so a test can
// prove a skipped subscriber recovers without reconnecting.
@(private = "file")
hub_relax :: proc(req: ^Request, res: ^Response) {
	hub_test_state.max_queue = HUB_MAX_QUEUE
	response_text(res, .OK, "relaxed\n")
}

@(private = "file")
hub_tick_hook :: proc(s: ^Server) {
	hub_tick(hub_test_state)
}

@(private = "file")
hub_test_router :: proc(router: ^Router) {
	router_init(router)
	router_get(router, "/events", hub_events)
	router_add(router, .Post, "/publish", hub_publish)
	router_get(router, "/count", hub_count)
	router_get(router, "/relax", hub_relax)
}

@(test)
test_integration_hub_fanout :: proc(t: ^testing.T) {
	hub: Hub
	hub_init(&hub)
	defer hub_destroy(&hub)
	hub_test_state = &hub
	defer hub_test_state = nil

	router: Router
	hub_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	// subscriber
	sub, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(sub)
	_ = net.set_option(sub, .Receive_Timeout, 2 * time.Second)
	testing.expect(t, hub_test_send_request(sub, "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"))

	head, head_ok := hub_test_drain(sub, "\r\n\r\n")
	testing.expectf(t, head_ok, "no response head: %q", head)
	testing.expect(t, strings.contains(head, "HTTP/1.1 200 OK"))
	testing.expect(t, strings.contains(head, "Content-Type: text/event-stream"))
	// chunked, and never compressed: an event stream has no length to code
	testing.expect(t, strings.contains(head, "Transfer-Encoding: chunked"))
	testing.expect(t, !strings.contains(head, "Content-Encoding"))

	// the handler has returned and the connection is parked, not held
	for _ in 0 ..< 100 {
		if hub_subscribers(&hub) == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, hub_subscribers(&hub) == 1, "the subscriber was not registered")

	// a second connection publishes; the first one must receive it
	pub, perr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, perr == nil)
	defer net.close(pub)
	body := "msg=hello%20hub&event=chat"
	request := fmt.aprintf(
		"POST /publish HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %v\r\nConnection: close\r\n\r\n%v",
		len(body),
		body,
	)
	defer delete(request)
	testing.expect(t, hub_test_send_request(pub, request))
	reply, reply_ok := hub_test_drain(pub, "sent")
	testing.expectf(t, reply_ok, "publish did not answer: %q", reply)

	stream, stream_ok := hub_test_drain(sub, "data: hello hub")
	testing.expectf(t, stream_ok, "the subscriber got: %q", stream)
	// one chunked frame around one event
	testing.expect(t, strings.contains(stream, "event: chat\n"))
	testing.expect(t, strings.contains(stream, "id: 1\n"))

	stats := hub_stats(&hub)
	testing.expect(t, stats.published == 1)
	testing.expect(t, stats.delivered == 1)

	// closing the subscriber removes it from the hub
	net.close(sub)
	for _ in 0 ..< 200 {
		if hub_subscribers(&hub) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, hub_subscribers(&hub) == 0, "a closed subscriber stayed in the hub")
}

/*
test_integration_hub_close: hub_close ends every stream with the terminating
chunk instead of dropping the socket mid-frame, so a client sees a clean end
of body.
*/
@(test)
test_integration_hub_close :: proc(t: ^testing.T) {
	hub: Hub
	hub_init(&hub)
	defer hub_destroy(&hub)
	hub_test_state = &hub
	defer hub_test_state = nil

	router: Router
	hub_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	sub, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(sub)
	testing.expect(t, hub_test_send_request(sub, "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	_, head_ok := hub_test_drain(sub, "\r\n\r\n")
	testing.expect(t, head_ok)

	for _ in 0 ..< 100 {
		if hub_subscribers(&hub) == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, hub_subscribers(&hub) == 1)

	// hub_close has to run on the loop thread: a handler is the simplest way
	close_srv := srv
	close_srv.user_ptr = srv.user_ptr
	hub_close2 :: proc(s: ^Server) {
		hub_close(hub_test_state)
	}
	srv.on_tick = hub_close2
	// stop the permissive on_tick again once the hub is closed, otherwise the
	// server keeps calling hub_close on a closed hub (a no-op, but noisy)
	defer srv.on_tick = nil

	got, got_ok := hub_test_drain(sub, "0\r\n\r\n")
	testing.expectf(t, got_ok, "no terminating chunk: %q", got)
}

// ---------------------------------------------------------------------------
// deferred responses
// ---------------------------------------------------------------------------

@(private = "file")
defer_state: ^Request

@(private = "file")
defer_postpone :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	// park: the handler returns without a response
	if !response_defer(res, defer_finish, nil) {
		response_text(res, .Internal_Error, "cannot park\n")
	}
}

@(private = "file")
defer_finish :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	response_text(res, .OK, why == .Timeout ? "timed out\n" : "resumed\n")
}

@(private = "file")
defer_wait :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	defer_state = req
	if !response_defer(res, defer_finish, nil, 20 * time.Millisecond) {
		response_text(res, .Internal_Error, "cannot park\n")
	}
}

@(private = "file")
defer_wake :: proc(req: ^Request, res: ^Response) {
	if defer_state != nil && request_resume(defer_state) {
		response_text(res, .OK, "woke\n")
		return
	}
	response_text(res, .Conflict, "nothing parked\n")
}

/*
defer_phase1 is a continuation that parks again: the documented way to build a
state machine over several events without blocking the loop. The second park
has to survive `conn_async_run`'s tail (which returns early in `.Async`) and
the second deadline has to fire on its own timer.
*/
@(private = "file")
defer_phase2 :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	response_text(res, .OK, "phase two\n")
}

@(private = "file")
defer_phase1 :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	if !response_defer(res, defer_phase2, nil, 20 * time.Millisecond) {
		response_text(res, .Internal_Error, "cannot park twice\n")
	}
}

@(private = "file")
defer_two :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	if !response_defer(res, defer_phase1, nil, 20 * time.Millisecond) {
		response_text(res, .Internal_Error, "cannot park\n")
	}
}

// defer_double_second records the verdict on a second, concurrent park.
@(private = "file")
defer_double_second: bool

@(private = "file")
defer_double :: proc(req: ^Request, res: ^Response) {
	response_set_content_type(res, "text/plain; charset=utf-8")
	first := response_defer(res, defer_finish, nil, 20 * time.Millisecond)
	defer_double_second = response_defer(res, defer_finish, nil)
	if !first {
		response_text(res, .Internal_Error, "cannot park\n")
	}
}

@(private = "file")
defer_test_router :: proc(router: ^Router) {
	router_init(router)
	router_get(router, "/wait", defer_wait)
	router_get(router, "/wake", defer_wake)
	router_get(router, "/two", defer_two)
	router_get(router, "/double", defer_double)
}

@(test)
test_integration_async_timeout :: proc(t: ^testing.T) {
	router: Router
	defer_test_router(&router)
	defer router_destroy(&router)

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
	testing.expect(t, hub_test_send_request(client, "GET /wait HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))

	got, ok := hub_test_drain(client, "timed out")
	testing.expectf(t, ok, "the continuation did not run on the deadline: %q", got)
	testing.expect(t, strings.contains(got, "HTTP/1.1 200 OK"))
	testing.expect(t, srv.stats.requests == 1)
}

@(test)
test_integration_async_resume :: proc(t: ^testing.T) {
	defer_state = nil
	defer {
		defer_state = nil
	}
	router: Router
	defer_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	// no idle timeout shorter than the test: the parked request must not be
	// swept before the waker arrives
	srv.idle_timeout = 5 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
	testing.expect(t, hub_test_send_request(client, "GET /wait HTTP/1.1\r\nHost: localhost\r\n\r\n"))

	// wait for the request to be parked
	for _ in 0 ..< 200 {
		if defer_state != nil && defer_state.conn != nil && defer_state.conn.state == .Async {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, defer_state != nil && defer_state.conn.state == .Async, "the request was not parked")

	// a second connection wakes it
	waker, werr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, werr == nil)
	defer net.close(waker)
	testing.expect(t, hub_test_send_request(waker, "GET /wake HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	woke, woke_ok := hub_test_drain(waker, "woke")
	testing.expectf(t, woke_ok, "the waker got: %q", woke)

	got, ok := hub_test_drain(client, "resumed")
	testing.expectf(t, ok, "the deferred response never arrived: %q", got)
	// the parked connection goes back to keep-alive after the response:
	// nothing was closed under it
	testing.expect(t, strings.contains(got, "HTTP/1.1 200 OK"))
}

/*
test_integration_hub_multiline: a `data` value with a newline becomes one
`data:` line per line, which is what the wire format requires. A hub that
appended the raw bytes would end the event at the newline and drop the rest -
and a browser would deliver half the message.
*/
@(test)
test_integration_hub_multiline :: proc(t: ^testing.T) {
	hub: Hub
	hub_init(&hub)
	defer hub_destroy(&hub)
	hub_test_state = &hub
	defer hub_test_state = nil

	router: Router
	hub_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	sub, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(sub)
	testing.expect(t, hub_test_send_request(sub, "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	_, head_ok := hub_test_drain(sub, "\r\n\r\n")
	testing.expect(t, head_ok)
	for _ in 0 ..< 100 {
		if hub_subscribers(&hub) == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, hub_subscribers(&hub) == 1)

	pub, perr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, perr == nil)
	defer net.close(pub)
	body := "msg=line1%0Aline2&event=note"
	request := fmt.aprintf(
		"POST /publish HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %v\r\nConnection: close\r\n\r\n%v",
		len(body),
		body,
	)
	defer delete(request)
	testing.expect(t, hub_test_send_request(pub, request))
	_, reply_ok := hub_test_drain(pub, "sent")
	testing.expect(t, reply_ok)

	stream, stream_ok := hub_test_drain(sub, "data: line2")
	testing.expectf(t, stream_ok, "the multiline event did not arrive: %q", stream)
	testing.expect(t, strings.contains(stream, "data: line1\n"))
	testing.expect(t, strings.contains(stream, "data: line2\n"))
	// the two lines belong to one event: one blank line, at the end
	testing.expectf(t, !strings.contains(stream, "line1\n\n"), "the event was split after the first line: %q", stream)
}

/*
test_integration_hub_backpressure: a subscriber whose queue would exceed
`max_queue` is skipped instead of buffered forever, and the publisher is not
slowed down. The skipped event is gone for that subscriber - the `id:` field is
what lets a real client ask for it again - but the hub keeps working, which is
the part that matters: one dead browser tab must not stall a feed.
*/
@(test)
test_integration_hub_backpressure :: proc(t: ^testing.T) {
	hub: Hub
	hub_init(&hub)
	defer hub_destroy(&hub)
	// smaller than any event frame: every publish is over the limit
	hub.max_queue = 8
	hub_test_state = &hub
	defer hub_test_state = nil

	router: Router
	hub_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	sub, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(sub)
	testing.expect(t, hub_test_send_request(sub, "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	_, head_ok := hub_test_drain(sub, "\r\n\r\n")
	testing.expect(t, head_ok)
	for _ in 0 ..< 100 {
		if hub_subscribers(&hub) == 1 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, hub_subscribers(&hub) == 1)

	// publish once: the event is dropped for the only subscriber
	pub, perr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, perr == nil)
	defer net.close(pub)
	body := "msg=hello%20drop&event=chat"
	// kept alive: the same socket publishes again below
	request := fmt.aprintf(
		"POST /publish HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %v\r\n\r\n%v",
		len(body),
		body,
	)
	defer delete(request)
	testing.expect(t, hub_test_send_request(pub, request))
	_, reply_ok := hub_test_drain(pub, "sent")
	testing.expectf(t, reply_ok, "the publisher was blocked by a slow subscriber")

	// the subscriber got nothing - the stream is still open, just starved
	_ = net.set_option(sub, .Receive_Timeout, 200 * time.Millisecond)
	idle: [256]byte
	n, rerr := net.recv_tcp(sub, idle[:])
	testing.expectf(t, rerr != nil || n <= 0, "the skipped event was delivered anyway: %q", string(idle[:max(n, 0)]))

	stats := hub_stats(&hub)
	testing.expectf(t, stats.published == 1, "published %v", stats.published)
	testing.expectf(t, stats.delivered == 0, "delivered %v to a starved subscriber", stats.delivered)
	testing.expectf(t, stats.skipped == 1, "skipped %v, want 1", stats.skipped)

	// raise the limit and publish again: the same subscriber recovers
	relax, rerr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, rerr2 == nil)
	defer net.close(relax)
	testing.expect(t, hub_test_send_request(relax, "GET /relax HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	_, relaxed := hub_test_drain(relax, "relaxed")
	testing.expect(t, relaxed)

	body2 := "msg=hello%20again&event=chat"
	request2 := fmt.aprintf(
		"POST /publish HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %v\r\nConnection: close\r\n\r\n%v",
		len(body2),
		body2,
	)
	defer delete(request2)
	testing.expect(t, hub_test_send_request(pub, request2))
	_, reply2 := hub_test_drain(pub, "sent")
	testing.expect(t, reply2)

	stream, stream_ok := hub_test_drain(sub, "data: hello again")
	testing.expectf(t, stream_ok, "the subscriber did not recover after the limit was raised: %q", stream)

	// the counter is not inflated when the sink goes away: `skipped` is a
	// publish-time total, not a sum re-added at close
	net.close(sub)
	for _ in 0 ..< 200 {
		if hub_subscribers(&hub) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	after := hub_stats(&hub)
	testing.expectf(t, after.skipped == 1, "skipped was double counted: %v", after.skipped)
}

/*
test_integration_hub_keep_alive: a quiet stream gets a comment every
`keep_alive`, driven from `Server.on_tick`. Two things depend on it - proxies
and idle timeouts that would otherwise close a silent stream, and the hub
itself, which only learns that a subscriber left when a send fails.
*/
@(test)
test_integration_hub_keep_alive :: proc(t: ^testing.T) {
	hub: Hub
	hub_init(&hub)
	defer hub_destroy(&hub)
	hub.keep_alive = 40 * time.Millisecond
	hub_test_state = &hub
	defer hub_test_state = nil

	router: Router
	hub_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 5 * time.Second
	srv.on_tick = hub_tick_hook
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	sub, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(sub)
	testing.expect(t, hub_test_send_request(sub, "GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	_, head_ok := hub_test_drain(sub, "\r\n\r\n")
	testing.expect(t, head_ok)

	got, ok := hub_test_drain(sub, ": keep-alive")
	testing.expectf(t, ok, "no keep-alive comment arrived: %q", got)
}

/*
test_integration_async_two_phase: a continuation that parks again. This is the
state-machine form the docs promise - "a continuation may defer again" - and it
is the only shape where `conn_async_run` returns with the connection parked
again, so a tail that mishandled `.Async` would hang the request instead of
advancing it.
*/
@(test)
test_integration_async_two_phase :: proc(t: ^testing.T) {
	router: Router
	defer_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 5 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, hub_test_send_request(client, "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))

	got, ok := hub_test_drain(client, "phase two")
	testing.expectf(t, ok, "the second phase never answered: %q", got)
	testing.expect(t, strings.contains(got, "HTTP/1.1 200 OK"))
	testing.expectf(t, srv.stats.requests == 1, "one request was counted as %v", srv.stats.requests)
}

/*
test_integration_async_double_defer: parking twice in one handler is refused.
The second call would overwrite the continuation and orphan the timer, so
`response_defer` reports false and leaves the first park intact.
*/
@(test)
test_integration_async_double_defer :: proc(t: ^testing.T) {
	router: Router
	defer_test_router(&router)
	defer router_destroy(&router)

	defer_double_second = true
	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 5 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, hub_test_send_request(client, "GET /double HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))

	got, ok := hub_test_drain(client, "timed out")
	testing.expectf(t, ok, "the first park did not run: %q", got)
	testing.expectf(t, !defer_double_second, "a second park in the same handler was accepted")
}

/*
test_integration_async_wake_after_timeout: once the deadline fired, the request
is no longer parked, so a producer that arrives late gets `false` instead of a
second response on a connection that already moved on. The connection itself
stays usable, which is what makes a lost wake-up survivable.
*/
@(test)
test_integration_async_wake_after_timeout :: proc(t: ^testing.T) {
	defer_state = nil
	defer {
		defer_state = nil
	}
	router: Router
	defer_test_router(&router)
	defer router_destroy(&router)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = router_handle
	srv.user_ptr = &router
	srv.idle_timeout = 5 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	// kept alive on purpose: the parked Request lives inside the Conn, so the
	// wake after the timeout must see a reset request, not freed memory
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, hub_test_send_request(client, "GET /wait HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	timed_out, ok := hub_test_drain(client, "timed out")
	testing.expectf(t, ok, "the deadline did not answer: %q", timed_out)

	// the request was reset, so there is nothing left to resume
	for _ in 0 ..< 100 {
		if defer_state == nil || defer_state.conn == nil {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, defer_state != nil && defer_state.conn == nil, "the parked flag survived the timeout")

	// a late waker is told so instead of writing a second response
	waker, werr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, werr == nil)
	defer net.close(waker)
	testing.expect(t, hub_test_send_request(waker, "GET /wake HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	late, late_ok := hub_test_drain(waker, "nothing parked")
	testing.expectf(t, late_ok, "a late resume was not refused: %q", late)
	testing.expect(t, strings.contains(late, "409"))
}
