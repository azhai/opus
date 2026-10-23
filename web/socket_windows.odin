#+build windows
package web

import "core:net"

// socket_listen is the POSIX-only listen step (see socket_posix.odin).
// Windows has no SO_REUSEPORT, so the multi-acceptor path is unavailable
// and server_listen keeps using nbio's own listen_tcp.
socket_listen :: proc(sock: net.TCP_Socket, backlog: int) -> bool {
	return false
}

// socket_set_reuse_port has no Windows equivalent that spreads connections
// over several listening sockets of the same process.
socket_set_reuse_port :: proc(sock: net.TCP_Socket) -> bool {
	return false
}
