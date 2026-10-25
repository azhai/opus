package web

import "core:mem"
import "core:net"

/*
Server-sent events (and the framing they need) over a hijacked connection.

`text/event-stream` cannot be produced by a normal handler: the response
never ends, so the length is unknown for as long as the client listens.
`sse_start` therefore takes the socket over with `response_hijack` and
writes a chunked response head itself; each event becomes one chunk, and
`sse_close` writes the terminating chunk.

	front :: proc(req: ^Request, res: ^Response) {
		w, ok := sse_start(res)
		if !ok { return }
		defer sse_close(&w)
		for i in 0..<10 {
			if !sse_event(&w, fmt.tprintf("tick %d", i), "tick") { return }
		}
	}

Cost model, stated plainly: the handler runs on its event-loop thread, so
a stream holds that thread for as long as it lives. That is fine for a
handful of dashboards and wrong for a public broadcast feed. The mitigation
this library offers is multi-acceptor (`server_run_multi`): N listeners, N
threads, so a few long streams do not stop the other threads from serving
short requests. A truly scalable feed needs a dedicated streaming service.

Browsers reconnect on their own and honour `retry:`; `sse_comment` doubles
as a keep-alive because a line starting with ':' is ignored by the client
but keeps idle-timeout proxies from dropping the connection.
*/

/*
Sse_Writer owns the hijacked socket and two reusable scratch buffers: one
for the field lines of the event being built, one for the chunked frame that
wraps them. A stream can emit an event per second for hours, so the writer
deliberately does not allocate per event - it grows these two buffers to
their high-water mark and reuses them.

Pass it by pointer (`w, ok := sse_start(res); defer sse_close(&w)`) and do
not copy it: a copy would share the buffer pointers and double-free on close.
*/
Sse_Writer :: struct {
	socket:    net.TCP_Socket,
	ok:        bool,
	allocator: mem.Allocator,
	payload:   Buf,
	frame:     Buf,
}

// sse_last_event_id returns the reconnection cursor the client sent
// (Last-Event-ID), or "" on a first connection. Resume a stream from it:
// the browser sends it on every automatic reconnect after a dropped
// connection, which is what makes `sse_event(..., id = ...)` worth setting.
sse_last_event_id :: proc(req: ^Request) -> string {
	v, ok := request_header(req, "Last-Event-ID")
	if !ok {
		return ""
	}
	return trim_ows(v)
}

/*
sse_start hijacks the connection and writes the response head:
`Content-Type: text/event-stream`, no caching, no proxy buffering and
chunked framing so the client sees a well-formed end of body.

`extra_headers` are appended for anything the caller needs (CORS, a session
cookie); Content-Type, Cache-Control and Transfer-Encoding are owned here
and a duplicate of those is skipped.
*/
sse_start :: proc(res: ^Response, extra_headers: []Header = nil, allocator := context.allocator) -> (w: Sse_Writer, ok: bool) {
	socket, hijacked := response_hijack(res)
	if !hijacked {
		return {}, false
	}
	w = Sse_Writer{socket = socket, ok = true, allocator = allocator}
	buf_init(&w.payload, allocator)
	buf_init(&w.frame, allocator)

	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)
	buf_append_string(&b, "HTTP/1.1 200 OK\r\n")
	buf_append_string(&b, "Content-Type: text/event-stream\r\n")
	buf_append_string(&b, "Cache-Control: no-cache, no-transform\r\n")
	buf_append_string(&b, "X-Accel-Buffering: no\r\n")
	buf_append_string(&b, "Transfer-Encoding: chunked\r\n")
	for h in extra_headers {
		switch {
		case eq_ignore_case(h.key, "Content-Type"),
		     eq_ignore_case(h.key, "Cache-Control"),
		     eq_ignore_case(h.key, "Transfer-Encoding"):
			continue
		}
		buf_append_string(&b, h.key)
		buf_append_string(&b, ": ")
		buf_append_string(&b, h.value)
		buf_append_string(&b, "\r\n")
	}
	buf_append_string(&b, "\r\n")

	if !stream_write(socket, buf_slice(&b)) {
		sse_release(&w)
		net.close(socket)
		return {}, false
	}
	return w, true
}

// sse_release frees the scratch buffers. Separated from sse_close because
// sse_close also has to end the HTTP response, which only happens once the
// head was written successfully.
sse_release :: proc(w: ^Sse_Writer) {
	buf_destroy(&w.payload)
	buf_destroy(&w.frame)
	w.payload = {}
	w.frame = {}
}

/*
sse_event sends one event. `event` names it (the client's
`addEventListener` key), `id` sets the reconnection cursor
(`Last-Event-ID` on the next connect). Multi-line data becomes one `data:`
line per line, which is what the wire format requires - a raw '\n' inside
the payload would end the event.
*/
sse_event :: proc(w: ^Sse_Writer, data: string, event := "", id := "") -> bool {
	if !w.ok {
		return false
	}
	p := &w.payload
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

	return sse_frame(w, buf_slice(p))
}

// sse_comment sends a comment line. Clients ignore it; it keeps proxies and
// idle timeouts from closing an otherwise quiet stream.
sse_comment :: proc(w: ^Sse_Writer, text: string) -> bool {
	if !w.ok {
		return false
	}
	p := &w.payload
	buf_reset(p)
	buf_append_string(p, ": ")
	buf_append_string(p, text)
	buf_append_string(p, "\n\n")
	return sse_frame(w, buf_slice(p))
}

// sse_retry tells the client how long to wait before reconnecting.
sse_retry :: proc(w: ^Sse_Writer, milliseconds: int) -> bool {
	if !w.ok {
		return false
	}
	p := &w.payload
	buf_reset(p)
	buf_append_string(p, "retry: ")
	buf_append_string(p, int_to_string(i64(milliseconds), w.allocator))
	buf_append_string(p, "\n\n")
	return sse_frame(w, buf_slice(p))
}

// sse_closed probes the peer without blocking (a closed tab sends FIN).
sse_closed :: proc(w: ^Sse_Writer) -> bool {
	if !w.ok {
		return true
	}
	return stream_peer_closed(w.socket)
}

// sse_close writes the terminating chunk and closes the socket. Idempotent:
// closing twice is a no-op, so `defer sse_close(&w)` is always safe.
sse_close :: proc(w: ^Sse_Writer) {
	if !w.ok {
		return
	}
	w.ok = false
	terminator := "0\r\n\r\n"
	_ = stream_write(w.socket, transmute([]byte) terminator)
	net.close(w.socket)
	sse_release(w)
}

// sse_frame wraps a payload in one chunk: "<hex length>\r\n<data>\r\n".
// `payload` may be `w.payload` - the frame buffer is a separate one.
sse_frame :: proc(w: ^Sse_Writer, payload: []byte) -> bool {
	if !w.ok || len(payload) == 0 {
		return w.ok
	}
	b := &w.frame
	buf_reset(b)
	write_hex(b, len(payload))
	buf_append_string(b, "\r\n")
	buf_append(b, payload)
	buf_append_string(b, "\r\n")
	if !stream_write(w.socket, buf_slice(b)) {
		w.ok = false
		return false
	}
	return true
}
