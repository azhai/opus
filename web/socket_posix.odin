#+build !windows
package web

import "core:c"
import "core:net"
import "core:sys/posix"

/*
socket_listen puts an already bound socket into the listening state.

core:net only exposes the combined create-bind-listen path, and here the
socket is created by nbio (so the event loop owns it) with SO_REUSEPORT set
before bind. This wraps the missing last step.
*/
socket_listen :: proc(sock: net.TCP_Socket, backlog: int) -> bool {
	return posix.listen(posix.FD(sock), i32(backlog)) == .OK
}

// SO_REUSEPORT is not exposed by core:net (its Reuse_Port option maps to -1)
// and core:sys/posix only names the options it needs, so the platform value
// is spelled out here.
when ODIN_OS == .Linux {
	SO_REUSEPORT :: 15
} else {
	SO_REUSEPORT :: 0x0200
}

// socket_set_reuse_port enables SO_REUSEPORT. It has to happen before bind;
// this is what lets several acceptor threads share one address.
socket_set_reuse_port :: proc(sock: net.TCP_Socket) -> bool {
	one: c.int = 1
	rc := posix.setsockopt(
		posix.FD(sock),
		posix.SOL_SOCKET,
		posix.Sock_Option(SO_REUSEPORT),
		&one,
		size_of(one),
	)
	return rc == .OK
}
