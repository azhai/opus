package web

import "core:net"

/*
Streaming helpers for connections taken over with response_hijack.

Once a connection is detached from the server, the handler owns the socket
and the regular response API no longer applies. These procedures cover the
common long-lived cases (SSE, chunked long-poll, proxying) so applications
do not roll their own send loops.
*/

// stream_write writes all of data to a blocking socket, retrying short
// writes. Returns false when the peer is gone or the send fails.
stream_write :: proc(socket: net.TCP_Socket, data: []byte) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(socket, data[off:])
		if err != net.TCP_Send_Error.None || n <= 0 {
			return false
		}
		off += n
	}
	return true
}

// stream_peer_closed probes a blocking socket for a peer that has closed its
// side. The socket is switched to non-blocking around a single recv, so a
// full send buffer is never mistaken for a disconnect (writes stay blocking).
// Note: any bytes the peer sent are consumed.
stream_peer_closed :: proc(socket: net.TCP_Socket) -> bool {
	_ = net.set_blocking(socket, false)
	b: [1]byte
	n, err := net.recv_tcp(socket, b[:])
	_ = net.set_blocking(socket, true)
	if err == net.TCP_Recv_Error.None {
		return n == 0
	}
	if err == net.TCP_Recv_Error.Would_Block || err == net.TCP_Recv_Error.Interrupted {
		return false
	}
	return true
}

/*
stream_write_head writes a response head (status line + headers) to a socket
the handler took over with response_hijack.

`content_length` is the body length when the caller knows it up front. Pass -1
for a stream whose end is marked by closing the connection (SSE): then no
Content-Length is written and `Connection: close` is added, unless the caller
already set a Connection header of its own.

The head is built on `allocator` and released before returning, so nothing of
it outlives the call.
*/
stream_write_head :: proc(
	socket: net.TCP_Socket,
	status: Status,
	headers: []Header,
	content_length: int,
	allocator := context.allocator,
) -> bool {
	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)

	buf_append_string(&b, "HTTP/1.1 ")
	write_padded_i64(&b, i64(status), 3)
	buf_append_byte(&b, ' ')
	buf_append_string(&b, status_text(status))
	buf_append_string(&b, "\r\n")
	connection_set := false
	for h in headers {
		if eq_ignore_case(h.key, "Connection") {
			connection_set = true
		}
		buf_append_string(&b, h.key)
		buf_append_string(&b, ": ")
		buf_append_string(&b, h.value)
		buf_append_string(&b, "\r\n")
	}
	if content_length >= 0 {
		buf_append_string(&b, "Content-Length: ")
		write_padded_i64(&b, i64(content_length), 1)
		buf_append_string(&b, "\r\n")
	} else if !connection_set {
		buf_append_string(&b, "Connection: close\r\n")
	}
	buf_append_string(&b, "\r\n")

	return stream_write(socket, buf_slice(&b))
}
