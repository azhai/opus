package web

// Tests for the SSE writer over a real socket: the response head, the
// chunked framing and the terminating chunk.

import "core:net"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// SSE over a real socket
// ---------------------------------------------------------------------------

sse_handler :: proc(req: ^Request, res: ^Response) {
	w, ok := sse_start(res)
	if !ok {
		return
	}
	defer sse_close(&w)
	if !sse_retry(&w, 1000) {
		return
	}
	_ = sse_comment(&w, "keep-alive")
	_ = sse_event(&w, "line one\nline two", "tick", "42")
}

@(test)
test_integration_sse :: proc(t: ^testing.T) {
	ep, th, args := integration_spin(t, sse_handler)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /sse HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	n, serr := net.send_tcp(client, transmute([]byte) request)
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
		// the terminating chunk ends the stream
		if bytes_contains(buf[:total], "0\r\n\r\n") {
			break
		}
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "Content-Type: text/event-stream\r\n"))
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "X-Accel-Buffering: no\r\n"))
	// chunk framing: "<hex>\r\n<fields>"
	testing.expect(t, bytes_contains(buf[:total], "retry: 1000\n\n"))
	testing.expect(t, bytes_contains(buf[:total], ": keep-alive\n\n"))
	testing.expect(t, bytes_contains(buf[:total], "event: tick\n"))
	testing.expect(t, bytes_contains(buf[:total], "id: 42\n"))
	testing.expect(t, bytes_contains(buf[:total], "data: line one\n"))
	testing.expect(t, bytes_contains(buf[:total], "data: line two\n"))
	testing.expect(t, strings.has_suffix(resp, "0\r\n\r\n"))
}
