package web

import "core:nbio"
import "core:time"

/*
Deferred responses: a handler that cannot finish inside one call.

Everything else in this library assumes `Handler` runs to completion: when it
returns, the response is serialized and the connection moves on. That breaks
for a response whose end depends on something that has not happened yet - a
message arriving on a bus, a row appearing in a table, the fifth second of a
stream. The usual escape hatch is `response_hijack`, which hands the raw
socket to the handler; the handler then owns a *blocking* socket and whatever
thread it is running on, so a thousand open streams means a thousand threads.
That is the thousand-thread problem this file exists to solve.

The shape instead:

	front :: proc(req: ^Request, res: ^Response) {
		web.response_set_content_type(res, "text/plain")
		web.response_defer(res, on_wake, req)   // park, do not answer yet
	}

	on_wake :: proc(req: ^Request, res: ^Response, ud: rawptr, why: web.Async_Reason) {
		web.response_write_string(res, "the wait is over\n")
	}

The handler returns after `response_defer` and the connection is parked in
the `Async` state: nothing is serialized, nothing is closed, and the event
loop thread is free for other connections. Later, `request_resume` runs the
continuation, which writes the response and lets the normal machinery take
over. A continuation may defer again - that is how a state machine over many
events is written - and a timeout can be attached so a parked request cannot
sit forever.

What is deliberately *not* provided: a way to call `request_resume` safely
from another OS thread. Everything in this library runs on one event loop
thread, and so does the continuation; a producer on another thread should
hand its work to the loop (for example through a queue drained in
`Server.on_tick`) and resume from there. The cost of that rule is explicit
instead of hidden behind a mutex the reader would have to reason about.
*/

// Async_Reason says why a continuation is running.
Async_Reason :: enum u8 {
	Resume, // a producer called request_resume
	Timeout, // the deadline passed before that happened
}

// Async_Proc is the continuation of a deferred response.
Async_Proc :: #type proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason)

// Async_State is the per-connection parking record.
Async_State :: struct {
	resume:   Async_Proc,
	ud:       rawptr,
	on_close: proc(ud: rawptr),
	timer:    ^nbio.Operation, // deadline, nil when none was requested
}

/*
response_defer parks the response and returns true. The handler must then
return; anything it writes afterwards is written by the continuation.

`timeout` arms a deadline: when it passes the continuation runs with
`why = .Timeout` and is expected to answer (a 503, an empty event, a final
message). 0 means "no deadline", which is right for a stream that ends when
the client leaves.

`on_close` runs exactly once, from `conn_close`, whether the response ended
normally, the client vanished or the server shut down. It is where a
subscription is removed from whatever list it was added to; without it a
closed connection would stay in that list until the next publish noticed.
*/
response_defer :: proc(
	res: ^Response,
	resume: Async_Proc,
	ud: rawptr,
	timeout: time.Duration = 0,
	on_close: proc(ud: rawptr) = nil,
) -> bool {
	c := res.conn
	if c == nil || c.closed || resume == nil {
		return false
	}
	// The response head may already be on the wire (a stream writes it before
	// parking), so `res.built` is not a reason to refuse - only a second
	// concurrent continuation is.
	if c.state == .Async {
		return false
	}
	c.async = Async_State{resume = resume, ud = ud, on_close = on_close}
	c.state = .Async
	if timeout > 0 {
		c.async.timer = nbio.timeout_poly(timeout, c, on_async_timeout)
	}
	conn_async_arm_recv(c)
	return true
}

// request_defer is response_defer with the request in hand, for handlers that
// think in terms of "this request is not done".
request_defer :: proc(
	req: ^Request,
	res: ^Response,
	resume: Async_Proc,
	ud: rawptr,
	timeout: time.Duration = 0,
	on_close: proc(ud: rawptr) = nil,
) -> bool {
	return response_defer(res, resume, ud, timeout, on_close)
}

// request_is_parked reports whether the request is waiting for its
// continuation. Middleware that must not serialize a response can check it.
request_is_parked :: proc(req: ^Request) -> bool {
	return req.conn != nil && req.conn.state == .Async
}

/*
request_resume runs the continuation now, on the event loop thread. Returns
false when the connection is gone or was never parked, which is not an error:
a producer that fires after the client left must be able to ignore it.
*/
request_resume :: proc(req: ^Request) -> bool {
	c := req.conn
	if c == nil || c.closed || c.state != .Async {
		return false
	}
	conn_async_run(c, .Resume)
	return true
}

// conn_async_run hands control back to the continuation and then finishes the
// response exactly like a synchronous handler would have.
@(private)
conn_async_run :: proc(c: ^Conn, why: Async_Reason) {
	if c.closed || c.state != .Async {
		return
	}
	a := c.async
	c.async = {}
	if a.timer != nil {
		// only reachable for .Resume: the timeout callback clears its own op
		// before calling in, because a completed operation is already back in
		// nbio's pool and must not be removed again
		nbio.remove(a.timer)
		a.timer = nil
	}
	c.state = .Process
	a.resume(&c.req, &c.res, a.ud, why)
	conn_process_tail(c)
	// conn_process_tail only *arms* the write state; in the synchronous path
	// the conn_drive loop is what calls conn_begin_write next. A resumed
	// response is not inside that loop, so it has to re-enter it - which also
	// covers the two other endings: a continuation that defers again
	// (state = .Async, drive returns at once) and one that hijacks the
	// connection (state = .Closed).
	conn_drive(c)
}

@(private)
on_async_timeout :: proc(op: ^nbio.Operation, c: ^Conn) {
	if c.closed {
		return
	}
	c.async.timer = nil
	conn_async_run(c, .Timeout)
}

/*
conn_async_arm_recv watches for the client going away while the request is
parked. A parked request has read everything it is going to read, so the only
thing left on the wire is a FIN (or a client that is confused about the
protocol); the read exists to notice both.

TLS connections are skipped: their reader shares `c.op` with the flush path,
and a parked TLS stream instead learns about a dead peer from its next write.
Streams that emit keep-alive comments (`hub_tick`) therefore notice within one
interval, which is bounded enough for the resources involved.
*/
@(private)
conn_async_arm_recv :: proc(c: ^Conn) {
	if c.tls != nil || c.async_op != nil || c.closed {
		return
	}
	c.async_op = nbio.recv_poly(
		c.socket,
		[][]byte{c.rbuf[:]},
		c,
		on_async_recv,
		all = false,
		timeout = nbio.NO_TIMEOUT,
	)
}

@(private)
on_async_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.async_op = nil
	if c.closed {
		return
	}
	n := op.recv.received
	if op.recv.err != nil || n == 0 {
		// FIN, reset or timeout: the client is gone
		conn_close(c)
		return
	}
	c.server.stats.bytes_in += u64(n)
	// A client that talks while its response is still open is pipelining
	// behind an unbounded response. Keep a bounded amount (it may be a
	// legitimate pipelined request once the stream ends) and drop the rest.
	if buf_len(&c.inbuf) + n > c.server.max_header_size {
		log_debug("web: conn %v pipelined too much behind a deferred response", c.remote)
		conn_close(c)
		return
	}
	buf_append(&c.inbuf, c.rbuf[:n])
	conn_async_arm_recv(c)
}

// conn_async_detach releases the parking state without running it. Called
// from conn_close, which is the only place a parked request can end.
@(private)
conn_async_detach :: proc(c: ^Conn) {
	if c.async_op != nil {
		nbio.remove(c.async_op)
		c.async_op = nil
	}
	if c.async.timer != nil {
		nbio.remove(c.async.timer)
		c.async.timer = nil
	}
	cb := c.async.on_close
	ud := c.async.ud
	c.async = {}
	if cb != nil {
		cb(ud)
	}
}
