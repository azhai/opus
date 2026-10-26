#+build !windows
package web

// The one upstream failure an ordinary socket cannot produce: a reset in the
// middle of the response. A graceful close is indistinguishable from a
// legitimately close-delimited body, so the case below resets with
// SO_LINGER {on, 0} - what a crashing upstream looks like to the proxy.

import "core:fmt"
import "base:intrinsics"
import "core:net"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"

// Raw_Reset_Upstream sends a close-delimited head plus part of the body, gives
// the proxy time to relay it, then resets instead of closing.
Raw_Reset_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
}

raw_reset_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Reset_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)
	_ = net.set_option(l, .Receive_Timeout, 2 * time.Second)

	client, _, aerr := net.accept_tcp(l)
	if aerr != nil {
		net.close(l)
		return
	}
	buf: [4096]byte
	net.recv_tcp(client, buf[:])
	resp := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npartial body"
	net.send_tcp(client, transmute([]byte)resp)
	time.sleep(250 * time.Millisecond)

	linger := [2]i32{1, 0} // l_onoff, l_linger: close() sends a RST
	_ = posix.setsockopt(
		posix.FD(net.Socket(client)),
		posix.SOL_SOCKET,
		posix.Sock_Option.LINGER,
		&linger,
		size_of(linger),
	)
	net.close(client)
	net.close(l)
}

/*
test_integration_proxy_reset_mid_body: the upstream resets after half a
close-delimited body. The client must see that half and then a cut - not a
terminated chunked body - the socket must not go back into the pool, and the
upstream must be charged with the failure.
*/
@(test)
test_integration_proxy_reset_mid_body :: proc(t: ^testing.T) {
	ru := new(Raw_Reset_Upstream, context.allocator)
	ru_th := thread.create(raw_reset_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0 ..< 10000 {
		if intrinsics.volatile_load(&ru.ready) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&ru.ready))
	defer thread.join(ru_th)
	defer thread.destroy(ru_th)
	defer free(ru, context.allocator)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", ru.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	// long enough that the reset, not a timeout, is what ends the body
	p.timeout = 5 * time.Second
	defer free(p, context.allocator)
	defer proxy_destroy(p)

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	_ = net.set_option(client, .Receive_Timeout, 3 * time.Second)
	request := "GET /reset HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	net.send_tcp(client, transmute([]byte)request)
	body := read_client_all(client)
	resp := string(body)
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expectf(t, strings.contains(resp, "partial body"), "the relayed prefix is missing: %q", resp)
	// the body was re-framed as chunked; the terminal chunk would tell the
	// client the truncation is the whole response
	testing.expectf(t, !strings.has_suffix(resp, "0\r\n\r\n"), "a truncated body was terminated: %q", resp)
	delete(body)

	time.sleep(150 * time.Millisecond)
	testing.expectf(t, len(p.pool) == 0, "the reset upstream socket was pooled")
	testing.expectf(
		t,
		p.upstreams[0].failures_total == 1,
		"the reset was not charged to the upstream (%v failure(s))",
		p.upstreams[0].failures_total,
	)
}
