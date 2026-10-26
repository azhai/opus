package web

import "core:mem"
import "core:nbio"
import "core:time"

/*
Hub fans out events to many subscribers from one event loop thread.

`Sse_Writer` (sse.odin) is the right tool for a stream that one handler
generates by itself: it hijacks the socket and writes, which blocks the loop
thread for as long as the stream lives. A hub is the other shape - the
subscribers are passive, and the events come from somewhere else (another
request, a background tick, a message queue). Nothing blocks:

	hub: web.Hub
	web.hub_init(&hub)

	events :: proc(req: ^web.Request, res: ^web.Response) {
		web.hub_subscribe(&hub, req, res)   // returns immediately
	}

	publish :: proc(req: ^web.Request, res: ^web.Response) {
		msg, _ := web.request_form_value(req, "msg")
		web.hub_send(&hub, "chat", msg, "")  // every subscriber gets it
		web.response_text(res, .OK, "sent\n")
	}

	srv.on_tick = proc(s: ^web.Server) { web.hub_tick(&hub) }

Each subscriber is a `Hub_Sink`: a queue of already-framed chunk bytes plus
the connection it drains to. Publishing appends one frame to every queue and
asks each sink to flush; a flush is a non-blocking `send` on the client
socket, and if one is already in flight the queue simply waits for its
completion callback. So the thread cost of a subscriber is a struct and a
buffer, not a thread - ten thousand of them run on the loop that also serves
ordinary requests.

Backpressure is per subscriber: `max_queue` bytes (64 KiB by default). A
client that stops reading is *skipped* rather than buffered forever or
allowed to stall the publisher - SSE clients recover on reconnect, and the
`id:` field is what lets them ask for what they missed. `hub_stats` reports
how often that happened, because a silently lossy feed is worse than a
measured one.
*/

// HUB_MAX_QUEUE is the default per-subscriber backlog. A slow consumer is
// skipped once its queue would exceed this.
HUB_MAX_QUEUE :: 64 << 10

// HUB_KEEP_ALIVE is the default quiet period before a comment is sent to keep
// proxies and idle timeouts from closing the stream.
HUB_KEEP_ALIVE :: 15 * time.Second

Hub :: struct {
	subs:      [dynamic]^Hub_Sink,
	allocator: mem.Allocator,

	max_queue:  int,
	keep_alive: time.Duration,

	// scratch buffers reused by every publish: a feed that emits an event per
	// second must not allocate per event
	payload: Buf, // the event body (data:/event:/id: lines)
	frame:   Buf, // one chunked frame wrapping `payload`

	published: u64, // events fanned out
	delivered: u64, // subscriber-event pairs written
	skipped:   u64, // subscriber-event pairs dropped for being over the limit
	closed:    bool,
}

// Hub_Sink is one subscriber: its queue of framed bytes and the connection
// draining it.
Hub_Sink :: struct {
	hub:       ^Hub,
	conn:      ^Conn,
	queue:     Buf,
	// index is this sink's slot in `hub.subs`. Removal is then a swap with the
	// last element instead of a scan, which matters when a client churns: a
	// scan costs O(subscribers) per disconnect, i.e. O(n^2) to turn the whole
	// feed over once.
	index:     int,
	sending:   bool,
	closing:   bool, // terminating chunk queued; close when the queue drains
	closed:    bool, // removed from the hub; the struct is about to be freed
	skipped:   u64,  // events dropped for this subscriber (backpressure)
	last_send: time.Time,
}

hub_init :: proc(h: ^Hub, allocator := context.allocator) {
	h.allocator = allocator
	h.subs = make([dynamic]^Hub_Sink, allocator)
	h.max_queue = HUB_MAX_QUEUE
	h.keep_alive = HUB_KEEP_ALIVE
	buf_init(&h.payload, allocator)
	buf_init(&h.frame, allocator)
}

/*
hub_destroy frees the hub. Like `proxy_destroy` it does not touch the client
sockets: those belong to the event loop, so close the streams first with
`hub_close` from `Server.on_stop`. A leftover subscriber is reported, because
forgetting that step leaks a connection per client.
*/
hub_destroy :: proc(h: ^Hub) {
	if len(h.subs) > 0 {
		log_error("web: hub_destroy with %v live subscriber(s); call hub_close on the event loop thread", len(h.subs))
	}
	if h.subs != nil {
		delete(h.subs)
		h.subs = nil
	}
	buf_destroy(&h.payload)
	buf_destroy(&h.frame)
}

// hub_subscribers reports how many streams are open.
hub_subscribers :: proc(h: ^Hub) -> int {
	return len(h.subs)
}

/*
hub_subscribe turns the request into a server-sent event stream and returns
immediately. It writes the response head itself (chunked, no-store,
no-transform) and parks the connection, so the calling handler costs one
struct and one `send`.

Returns nil when the connection cannot be parked (already gone, already
hijacked), in which case the handler should simply return.

`last_id` is echoed nowhere by the hub - it is the caller's cursor from
`sse_last_event_id` and the caller's business, since only it knows which
events the client already saw.
*/
hub_subscribe :: proc(h: ^Hub, req: ^Request, res: ^Response) -> (sink: ^Hub_Sink, ok: bool) {
	if h.closed {
		return nil, false
	}
	c := req.conn
	if c == nil || c.closed {
		return nil, false
	}
	if c.state == .Async {
		return nil, false
	}

	s := new(Hub_Sink, h.allocator)
	s.hub = h
	s.conn = c
	buf_init(&s.queue, h.allocator)

	// The head goes through response_build like any other response, with
	// chunked framing and content coding switched off; the body that follows
	// is written by hub_flush as raw chunk frames.
	res.status = .OK
	response_set_header(res, "Content-Type", "text/event-stream")
	response_set_header(res, "Cache-Control", "no-cache, no-transform")
	response_set_header(res, "X-Accel-Buffering", "no")
	res.chunked = true
	res.compress = .Deny
	response_build(res, &c.out, conn_scratch(c))

	if !response_defer(res, hub_resume, s, 0, hub_on_close) {
		buf_destroy(&s.queue)
		free(s, h.allocator)
		return nil, false
	}
	s.last_send = nbio.now()
	s.index = len(h.subs)
	append(&h.subs, s)
	hub_flush(s)
	return s, true
}

/*
hub_resume only ever runs on the deadline, and hub_subscribe never sets one:
a stream ends because the client leaves or the server closes it. It is here
so a future subscriber with a lifetime (a trial stream, an auction) can park
with a timeout and reuse the same machinery.
*/
@(private)
hub_resume :: proc(req: ^Request, res: ^Response, ud: rawptr, why: Async_Reason) {
	s := cast(^Hub_Sink) ud
	if s == nil {
		return
	}
	hub_terminate(s)
}

@(private)
hub_on_close :: proc(ud: rawptr) {
	s := cast(^Hub_Sink) ud
	if s == nil {
		return
	}
	h := s.hub
	if h != nil {
		hub_remove(h, s)
		// `h.skipped` is incremented at publish time so a live /stats handler
		// sees it; adding `s.skipped` here would count every drop twice
	}
	s.closed = true
	buf_destroy(&s.queue)
	free(s, s.hub.allocator)
}

/*
hub_remove drops a sink from the subscriber list in O(1).

The last element is moved into the vacated slot, which is why `hub_publish`
iterates backwards: by the time it reaches slot `i`, every slot above it has
already been visited, so a sink that jumps down into `i` cannot be skipped or
visited twice.
*/
@(private)
hub_remove :: proc(h: ^Hub, s: ^Hub_Sink) {
	i := s.index
	last := len(h.subs) - 1
	if i < 0 || i > last || h.subs[i] != s {
		// index out of date (defensive: a duplicate close): fall back to a scan
		i = -1
		for j := 0; j < len(h.subs); j += 1 {
			if h.subs[j] == s {
				i = j
				break
			}
		}
		if i < 0 {
			return
		}
	}
	if i != last {
		moved := h.subs[last]
		h.subs[i] = moved
		moved.index = i
	}
	pop(&h.subs)
}

// hub_flush pushes whatever is queued at the socket, one send at a time. The
// response head may already be sitting in `c.out`; it goes first.
@(private)
hub_flush :: proc(s: ^Hub_Sink) {
	c := s.conn
	if s.closed || s.sending || c == nil || c.closed || c.op != nil {
		return
	}
	if buf_len(&c.out) == 0 {
		if buf_len(&s.queue) == 0 {
			return
		}
		buf_append(&c.out, buf_slice(&s.queue))
		buf_reset(&s.queue)
	}
	if !conn_flush_out(c, on_hub_sent) {
		return // nothing to send after all
	}
	s.sending = true
}

@(private)
on_hub_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	s := cast(^Hub_Sink) c.async.ud
	if s == nil || s.closed {
		return
	}
	s.sending = false
	if op.send.err != nil {
		log_debug("web: hub stream to %v failed: %v", c.remote, op.send.err)
		conn_close(c) // hub_on_close removes the sink
		return
	}
	conn_after_send(c, op.send.sent)
	if buf_len(&s.queue) == 0 && s.closing {
		conn_close(c)
		return
	}
	hub_flush(s)
}

// ---------------------------------------------------------------------------
// publishing
// ---------------------------------------------------------------------------

/*
hub_send emits one event to every subscriber. `event` names it (the client's
`addEventListener` key), `id` sets the reconnection cursor. A multi-line
`data` becomes one `data:` line per line, which is what the wire format
requires.

The event is formatted once and the framed bytes are appended to each
subscriber's queue, so the per-subscriber cost is a memcpy, not a
reformatting.
*/
hub_send :: proc(h: ^Hub, event, data, id: string) {
	if h.closed {
		return
	}
	p := &h.payload
	buf_reset(p)
	if len(event) > 0 {
		buf_append_string(p, "event: ")
		buf_append_string(p, event)
		buf_append_byte(p, '\n')
	}
	if len(id) > 0 {
		buf_append_string(p, "id: ")
		buf_append_string(p, id)
		buf_append_byte(p, '\n')
	}
	rest := data
	for {
		nl := string_index_byte(rest, '\n')
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 1:]
		} else {
			rest = ""
		}
		buf_append_string(p, "data: ")
		buf_append_string(p, line)
		buf_append_byte(p, '\n')
		if nl < 0 {
			break
		}
	}
	buf_append_byte(p, '\n')
	hub_publish(h, buf_slice(p))
}

// hub_comment sends a comment line to every subscriber. Clients ignore it; it
// is the keep-alive that keeps idle proxies from closing a quiet stream.
hub_comment :: proc(h: ^Hub, text: string) {
	if h.closed {
		return
	}
	p := &h.payload
	buf_reset(p)
	buf_append_string(p, ": ")
	buf_append_string(p, text)
	buf_append_string(p, "\n\n")
	hub_publish(h, buf_slice(p))
}

/*
hub_publish frames `payload` as one chunk and queues it for every subscriber.

Iterating backwards is deliberate: a flush can close a connection (TLS
encryption failure does it synchronously), and `hub_remove` moving the last
element into the freed slot is only safe when that element has already been
visited.
*/
hub_publish :: proc(h: ^Hub, payload: []byte) {
	if h.closed || len(payload) == 0 {
		return
	}
	f := &h.frame
	buf_reset(f)
	write_hex(f, len(payload))
	buf_append_string(f, "\r\n")
	buf_append(f, payload)
	buf_append_string(f, "\r\n")

	h.published += 1
	now := nbio.now()
	frame := buf_slice(f)
	for i := len(h.subs) - 1; i >= 0; i -= 1 {
		s := h.subs[i]
		if s.closed {
			continue
		}
		if hub_backlog(s) + len(frame) > h.max_queue {
			// over the limit: skip this event for this subscriber instead of
			// growing without bound. SSE clients resync from `id:`.
			s.skipped += 1
			h.skipped += 1
			continue
		}
		hub_enqueue(s, frame)
		s.last_send = now
		h.delivered += 1
	}
}

/*
hub_enqueue puts one framed chunk on its way to a subscriber.

The common case is an idle sink, and for that the frame goes straight into the
connection buffer. Routing it through `queue` instead would copy it twice -
into the queue, then out of the queue into `c.out` - for a feed where every
event is broadcast to every subscriber, that is the dominant cost.
*/
@(private)
hub_enqueue :: proc(s: ^Hub_Sink, chunk: []byte) {
	c := s.conn
	if !s.sending && c != nil && !c.closed && c.op == nil && buf_len(&c.out) == 0 && buf_len(&s.queue) == 0 {
		buf_append(&c.out, chunk)
	} else {
		buf_append(&s.queue, chunk)
	}
	hub_flush(s)
}

/*
hub_backlog is how many bytes this subscriber still owes the network: its own
queue plus whatever the last send left in the connection buffer.

Counting both is what makes `max_queue` a real bound. A send in flight drains
`c.out` progressively, so ignoring it would let a slow client refill its queue
while the connection buffer was still holding a previous event, and the actual
backlog would be twice the configured limit.
*/
@(private)
hub_backlog :: proc(s: ^Hub_Sink) -> int {
	n := buf_len(&s.queue)
	if c := s.conn; c != nil && !c.closed {
		n += buf_len(&c.out)
	}
	return n
}

/*
hub_tick keeps quiet streams alive and is meant to run from `Server.on_tick`:

	srv.on_tick = proc(s: ^web.Server) { web.hub_tick(&hub) }

It also re-fixes the send order: a subscriber whose flush was refused because
a send was already in flight gets another chance here, so a dropped callback
cannot wedge a queue forever.
*/
hub_tick :: proc(h: ^Hub) {
	if h.closed {
		return
	}
	now := nbio.now()
	for i := len(h.subs) - 1; i >= 0; i -= 1 {
		s := h.subs[i]
		if s.closed {
			continue
		}
		if buf_len(&s.queue) > 0 {
			hub_flush(s)
			continue
		}
		if h.keep_alive > 0 && s.last_send != {} && time.diff(s.last_send, now) > h.keep_alive {
			// a comment costs 20 bytes and proves the connection is alive in
			// both directions: the send fails on a client that left
			buf_append_string(&s.queue, "14\r\n: keep-alive\n\n\r\n")
			s.last_send = now
			hub_flush(s)
		}
	}
}

/*
hub_close ends every stream: the terminating chunk goes out and the
connection is closed once it has been written (or immediately if a send is
already in flight, since the client cannot resume an unfinished stream
anyway).

Call it on the event loop thread - from `Server.on_stop` for shutdown, or from
a handler for a "drain" endpoint.
*/
hub_close :: proc(h: ^Hub) {
	h.closed = true
	for i := len(h.subs) - 1; i >= 0; i -= 1 {
		s := h.subs[i]
		if s.closed {
			continue
		}
		hub_terminate(s)
	}
}

@(private)
hub_terminate :: proc(s: ^Hub_Sink) {
	if s.closed || s.closing {
		return
	}
	s.closing = true
	c := s.conn
	if c == nil || c.closed {
		return
	}
	buf_append_string(&s.queue, "0\r\n\r\n")
	if s.sending || c.op != nil {
		return // on_hub_sent closes once the queue drains
	}
	hub_flush(s)
}

// Hub_Stats is a snapshot for a /stats handler or a log line.
Hub_Stats :: struct {
	subscribers: int,
	published:   u64,
	delivered:   u64,
	skipped:     u64,
}

hub_stats :: proc(h: ^Hub) -> Hub_Stats {
	return Hub_Stats {
		subscribers = len(h.subs),
		published = h.published,
		delivered = h.delivered,
		skipped = h.skipped,
	}
}
