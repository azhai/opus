package web

// Tests for the reverse proxy: header handling, upstream framing
// and the pooled upstream connections, over real sockets where it matters.

import "base:intrinsics"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
// ---------------------------------------------------------------------------
// reverse proxy
// ---------------------------------------------------------------------------

// test_conn_new builds a socket-free Conn for unit tests that touch the
// response/proxy parsing paths.
test_conn_new :: proc(t: ^testing.T) -> ^Conn {
	c := new(Conn, context.allocator)
	mem.dynamic_arena_init(&c.scratch, context.allocator)
	buf_init(&c.inbuf, context.allocator)
	buf_init(&c.out, context.allocator)
	buf_init(&c.body_buf, context.allocator)
	buf_init(&c.proxy_req, context.allocator)
	buf_init(&c.proxy_buf, context.allocator)
	c.state = .Process
	response_reset(&c.res, c, conn_scratch(c))
	return c
}

test_conn_destroy :: proc(c: ^Conn) {
	buf_destroy(&c.inbuf)
	buf_destroy(&c.out)
	buf_destroy(&c.body_buf)
	buf_destroy(&c.proxy_req)
	buf_destroy(&c.proxy_buf)
	mem.dynamic_arena_destroy(&c.scratch)
	free(c, context.allocator)
}

@(test)
test_proxy_hop_by_hop_headers :: proc(t: ^testing.T) {
	testing.expect(t, is_hop_by_hop_header("Connection"))
	testing.expect(t, is_hop_by_hop_header("connection"))
	testing.expect(t, is_hop_by_hop_header("Keep-Alive"))
	testing.expect(t, is_hop_by_hop_header("Proxy-Connection"))
	testing.expect(t, is_hop_by_hop_header("Proxy-Authorization"))
	testing.expect(t, is_hop_by_hop_header("TE"))
	testing.expect(t, is_hop_by_hop_header("Trailer"))
	testing.expect(t, is_hop_by_hop_header("Transfer-Encoding"))
	testing.expect(t, is_hop_by_hop_header("Upgrade"))
	testing.expect(t, !is_hop_by_hop_header("Content-Type"))
	testing.expect(t, !is_hop_by_hop_header("Content-Length"))
	testing.expect(t, !is_hop_by_hop_header("X-Custom-Thing"))
}

@(test)
test_proxy_chunked_scan :: proc(t: ^testing.T) {
	s1 := "5\r\nhello\r\n0\r\n\r\n"
	complete, length := proxy_chunked_complete(transmute([]byte)s1)
	testing.expect(t, complete)
	testing.expect(t, length == 15)

	s2 := "5\r\nhello\r\n"
	complete2, _ := proxy_chunked_complete(transmute([]byte)s2)
	testing.expect(t, !complete2)

	s3 := "3\r\nabc\r\n4\r\ndefg\r\n0\r\nX-T: 1\r\n\r\n"
	complete3, length3 := proxy_chunked_complete(transmute([]byte)s3)
	testing.expect(t, complete3)
	testing.expect(t, length3 == 30)

	s4 := "zz\r\n"
	complete4, _ := proxy_chunked_complete(transmute([]byte)s4)
	testing.expect(t, !complete4)

	// chunk payload containing a fake terminator must not fool the scan
	s5 := "8\r\n0\r\n\r\nxyz\r\n0\r\n\r\n"
	complete5, length5 := proxy_chunked_complete(transmute([]byte)s5)
	testing.expect(t, complete5)
	testing.expect(t, length5 == 18)
}

@(test)
test_proxy_parse_upstream_head :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	c.req.method = .Get

	// content-length response: framing decided, hop-by-hop dropped
	r := proxy_parse_head(c, "HTTP/1.1 201 Created\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\nServer: up\r\n\r\n")
	testing.expect(t, r == .Ok)
	testing.expect(t, c.res.status == .Created)
	testing.expect(t, c.res.reason == "Created")
	testing.expect(t, c.proxy_framing == .Content_Length)
	testing.expect(t, c.proxy_remaining == 5)
	_, has_conn := response_header(&c.res, "Connection")
	testing.expect(t, !has_conn)
	cl, has_cl := response_header(&c.res, "Content-Length")
	testing.expect(t, has_cl)
	testing.expect(t, cl == "5")
	ct, has_ct := response_header(&c.res, "Content-Type")
	testing.expect(t, has_ct)
	testing.expect(t, ct == "text/plain")

	// chunked response: TE passes through, keep-alive preserved
	response_reset(&c.res, c, conn_scratch(c))
	r2 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
	testing.expect(t, r2 == .Ok)
	testing.expect(t, c.proxy_framing == .Chunked)
	te, has_te := response_header(&c.res, "Transfer-Encoding")
	testing.expect(t, has_te)
	testing.expect(t, te == "chunked")

	// close-delimited response: no framing headers, the relay re-frames it
	response_reset(&c.res, c, conn_scratch(c))
	r3 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
	testing.expect(t, r3 == .Ok)
	testing.expect(t, c.proxy_framing == .Until_Close)

	// 204 never carries a body
	response_reset(&c.res, c, conn_scratch(c))
	r4 := proxy_parse_head(c, "HTTP/1.1 204 No Content\r\n\r\n")
	testing.expect(t, r4 == .Ok)
	testing.expect(t, c.proxy_framing == .None)

	// HEAD: framing passes through but no body is expected
	response_reset(&c.res, c, conn_scratch(c))
	c.req.method = .Head
	r5 := proxy_parse_head(c, "HTTP/1.1 200 OK\r\nContent-Length: 42\r\n\r\n")
	testing.expect(t, r5 == .Ok)
	testing.expect(t, c.proxy_framing == .None)
	cl5, has_cl5 := response_header(&c.res, "Content-Length")
	testing.expect(t, has_cl5)
	testing.expect(t, cl5 == "42")
	c.req.method = .Get

	// 1xx informational heads are skipped
	response_reset(&c.res, c, conn_scratch(c))
	r6 := proxy_parse_head(c, "HTTP/1.1 100 Continue\r\n\r\n")
	testing.expect(t, r6 == .Skip)

	// unknown status codes pass through with the upstream reason
	response_reset(&c.res, c, conn_scratch(c))
	r7 := proxy_parse_head(c, "HTTP/1.1 599 Weird\r\nContent-Length: 0\r\n\r\n")
	testing.expect(t, r7 == .Ok)
	testing.expect(t, int(c.res.status) == 599)
	testing.expect(t, c.res.reason == "Weird")

	// malformed heads are rejected
	response_reset(&c.res, c, conn_scratch(c))
	r8 := proxy_parse_head(c, "garbage\r\n\r\n")
	testing.expect(t, r8 == .Malformed)
}

@(test)
test_proxy_no_upstream :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	req := Request{conn = c, method = .Get, path = "/"}
	p: Proxy // zero value: no upstreams
	proxy_serve_root(&p, &req, &c.res)
	testing.expect(t, c.res.status == .Bad_Gateway)
	testing.expect(t, c.state == .Process) // not hijacked into proxy mode
}

@(test)
test_proxy_round_robin :: proc(t: ^testing.T) {
	p: Proxy
	ok := proxy_init(&p, {"127.0.0.1:9001", "127.0.0.1:9002"})
	testing.expect(t, ok)
	defer proxy_destroy(&p)
	idx1 := proxy_next_upstream(&p)
	idx2 := proxy_next_upstream(&p)
	idx3 := proxy_next_upstream(&p)
	testing.expect(t, idx1 == 0)
	testing.expect(t, idx2 == 1)
	testing.expect(t, idx3 == 0) // wraps around
	testing.expect(t, p.upstreams[idx1].endpoint.port == 9001)
	testing.expect(t, p.upstreams[idx1].host == "127.0.0.1:9001")
	testing.expect(t, p.upstreams[idx2].endpoint.port == 9002)
	testing.expect(t, p.upstreams[idx2].host == "127.0.0.1:9002")

	bad: Proxy
	testing.expect(t, !proxy_init(&bad, {"not-an-address"}))
}

/*
test_proxy_weighted_round_robin checks smooth weighted round-robin, the
selection nginx uses: over `sum(weights)` picks each upstream appears exactly
`weight` times, and consecutive picks do not clump. {3, 1} must therefore
produce the pattern 1,0,1,1 rather than 0,0,0,1.
*/
@(test)
test_proxy_weighted_round_robin :: proc(t: ^testing.T) {
	p: Proxy
	testing.expect(t, proxy_init(&p, {"127.0.0.1:9001", "127.0.0.1:9002"}))
	defer proxy_destroy(&p)
	testing.expect(t, proxy_set_weight(&p, 0, 3))
	testing.expect(t, !proxy_set_weight(&p, 0, 0)) // zero would mean "never"
	testing.expect(t, !proxy_set_weight(&p, 9, 1)) // out of range

	picks: [4]int
	for i in 0 ..< len(picks) {
		picks[i] = proxy_next_upstream(&p)
	}
	count0 := 0
	for v in picks {
		if v == 0 {
			count0 += 1
		}
	}
	testing.expectf(t, count0 == 3, "got %v, want three picks of the heavy upstream", picks)
	// smooth: the light upstream is not starved to the end
	testing.expectf(t, picks[1] == 1 || picks[2] == 1, "got %v, want the light upstream early", picks)

	// a single upstream keeps getting everything, weights or not
	one: Proxy
	testing.expect(t, proxy_init(&one, {"127.0.0.1:9001"}))
	defer proxy_destroy(&one)
	testing.expect(t, proxy_next_upstream(&one) == 0)
	testing.expect(t, proxy_next_upstream(&one) == 0)
}

/*
test_proxy_health_ejection covers the circuit breaker without a network:
failures accumulate, the upstream leaves the rotation, the window expires and
the next success puts it back.
*/
@(test)
test_proxy_health_ejection :: proc(t: ^testing.T) {
	p: Proxy
	testing.expect(t, proxy_init(&p, {"127.0.0.1:9001", "127.0.0.1:9002"}))
	defer proxy_destroy(&p)
	p.health.max_failures = 2
	p.health.eject_for = 30 * time.Millisecond
	p.health.probe = false

	proxy_note_failure(&p, 0)
	{
		state, failures, _ := proxy_upstream_state(&p, 0)
		testing.expect(t, state == .Healthy) // one failure is not a pattern
		testing.expect(t, failures == 1)
	}

	proxy_note_failure(&p, 0)
	{
		state, _, until := proxy_upstream_state(&p, 0)
		testing.expect(t, state == .Ejected)
		testing.expect(t, p.upstreams_ejected == 1)
		testing.expect(t, until != {})
	}

	// the ejected upstream is out of the rotation
	for _ in 0 ..< 6 {
		testing.expect(t, proxy_next_upstream(&p) == 1)
	}

	// the window expires: the next request through it is the half-open probe
	time.sleep(40 * time.Millisecond)
	testing.expect(t, proxy_next_upstream(&p) == 0)
	proxy_note_success(&p, 0)
	{
		state, failures, until := proxy_upstream_state(&p, 0)
		testing.expect(t, state == .Healthy)
		testing.expect(t, failures == 0)
		testing.expect(t, until == {})
		testing.expect(t, p.upstreams_ejected == 0)
	}
}

/*
test_integration_proxy_health_probe is the active half of the circuit
breaker: an ejected upstream is probed from the event loop instead of waiting
for real traffic to rediscover it.

The "upstream" is a listening socket that never accepts - a TCP connect
succeeds against it, which is all a liveness probe asks for - so the test
does not need a real HTTP backend. The proxy has no traffic at all: the only
thing that can bring the upstream back is the probe.
*/
@(test)
test_integration_proxy_health_probe :: proc(t: ^testing.T) {
	bind := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 0,
	}
	listener, lerr := net.listen_tcp(bind, 16)
	testing.expect(t, lerr == nil)
	if lerr != nil {
		return
	}
	defer net.close(listener)
	lep, _ := nbio.bound_endpoint(listener)
	buf: [32]byte
	address := fmt.bprintf(buf[:], "127.0.0.1:%v", lep.port)

	p: Proxy
	testing.expect(t, proxy_init(&p, {address}))
	defer proxy_destroy(&p)
	p.health.max_failures = 1
	p.health.eject_for = 10 * time.Second
	p.health.probe = true
	p.health.probe_interval = 20 * time.Millisecond
	p.health.probe_timeout = time.Second

	// eject the upstream without sending a single request through it
	proxy_note_failure(&p, 0)
	testing.expect(t, p.upstreams_ejected == 1)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.user_ptr = &p
	srv.on_tick = proc(s: ^Server) {
		proxy_health_poll(cast(^Proxy) s.user_ptr)
	}
	srv.on_stop = proxy_test_stop
	_, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	// the tick runs every SWEEP_INTERVAL (250 ms): give it two rounds
	for _ in 0 ..< 40 {
		if intrinsics.volatile_load(&p.upstreams_ejected) == 0 {
			break
		}
		time.sleep(25 * time.Millisecond)
	}
	testing.expectf(t, p.upstreams_ejected == 0, "the probe did not bring the upstream back")
	testing.expect(t, p.probes >= 1)
	testing.expect(t, p.probe_failures == 0)
}

/*
test_proxy_health_fail_open: with every upstream ejected the proxy still
picks one - the one that recovers soonest - instead of answering 503 on the
strength of its own bookkeeping.
*/
@(test)
test_proxy_health_fail_open :: proc(t: ^testing.T) {
	p: Proxy
	testing.expect(t, proxy_init(&p, {"127.0.0.1:9001", "127.0.0.1:9002"}))
	defer proxy_destroy(&p)
	p.health.max_failures = 1
	p.health.eject_for = 60 * time.Second
	p.health.probe = false

	proxy_note_failure(&p, 0)
	proxy_note_failure(&p, 1)
	testing.expect(t, p.upstreams_ejected == 2)

	// upstream 0 was ejected first, so its window ends first
	for _ in 0 ..< 4 {
		testing.expect(t, proxy_next_upstream(&p) == 0)
	}
}

// integration_spin_srv starts an already-initialized server (handler and
// user_ptr set by the caller) on an ephemeral port.
integration_spin_srv :: proc(t: ^testing.T, srv: ^Server) -> (ep: net.Endpoint, th: ^thread.Thread, args: ^Integration_Args) {
	done := new(bool, context.allocator)
	args = new(Integration_Args, context.allocator)
	args.srv = srv
	args.done = done
	th = thread.create(integration_thread_proc)
	th.data = args
	thread.start(th)

	for i in 0..<10000 {
		if intrinsics.volatile_load(&srv.listening) {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, intrinsics.volatile_load(&srv.listening))
	ep, _ = nbio.bound_endpoint(srv.listen_socket)
	return
}

// proxy_test_stop releases the upstream pool on the loop thread when the
// server stops: pooled sockets belong to that loop.
proxy_test_stop :: proc(s: ^Server) {
	if p := cast(^Proxy) s.user_ptr; p != nil {
		proxy_close_idle(p)
	}
}

// proxy_upstream_handler echoes what the proxy forwarded: method, target
// and the headers the proxy is required to add/rewrite.
proxy_upstream_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	response_write_string(res, "upstream ")
	response_write_string(res, method_string(req.method))
	response_write_string(res, " ")
	response_write_string(res, req.target)
	if v, ok := request_header(req, "X-Test"); ok {
		response_write_string(res, " xtest=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "X-Forwarded-For"); ok {
		response_write_string(res, " xff=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "X-Forwarded-Proto"); ok {
		response_write_string(res, " xfp=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Via"); ok {
		response_write_string(res, " via=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Host"); ok {
		response_write_string(res, " host=")
		response_write_string(res, v)
	}
	if v, ok := request_header(req, "Connection"); ok {
		response_write_string(res, " conn=")
		response_write_string(res, v)
	}
	response_write_string(res, " body=")
	response_write_string(res, string(req.body))
}

proxy_upstream_chunked_handler :: proc(req: ^Request, res: ^Response) {
	res.chunked = true
	response_write_string(res, "chunked-upstream ")
	response_write_string(res, req.target)
}

@(test)
test_integration_proxy_get :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.strip_prefix = "/api"
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	// stop the servers first (the proxy server's on_stop releases the
	// upstream pool on the loop thread), then drop the proxy
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /api/hello?x=1 HTTP/1.1\r\nHost: example.com\r\nX-Test: 42\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	// prefix stripped, query preserved, custom header forwarded
	testing.expect(t, strings.contains(resp, "upstream GET /hello?x=1"))
	testing.expect(t, strings.contains(resp, "xtest=42"))
	// proxy-added headers
	testing.expect(t, strings.contains(resp, "xff=127.0.0.1"))
	testing.expect(t, strings.contains(resp, "xfp=http"))
	testing.expect(t, strings.contains(resp, "via=1.1 " + SERVER_NAME))
	// Host rewritten to the upstream
	testing.expect(t, strings.contains(resp, "host=127.0.0.1:"))
	// upstream connections are pooled, so the proxy asks for keep-alive
	testing.expect(t, strings.contains(resp, "conn=keep-alive"))
	testing.expect(t, strings.has_suffix(resp, "body="))

	// The relayed body must not contain any part of the response head: the
	// proxy streams the head first and the body as it arrives, and arming a
	// second send while the head is still in flight would resend the head
	// bytes as body.
	head_end := strings.index(resp, "\r\n\r\n")
	testing.expect(t, head_end > 0)
	if head_end > 0 {
		body := resp[head_end + 4:]
		testing.expectf(t, strings.has_prefix(body, "upstream GET /hello?x=1"),
			"body does not start with the upstream payload: %q", body)
		testing.expectf(t, !strings.contains(body, "HTTP/1.1"),
			"body contains a second response head: %q", body)
	}
}

@(test)
test_integration_proxy_post_body :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "POST /echo HTTP/1.1\r\nHost: example.com\r\nContent-Length: 5\r\nConnection: close\r\n\r\nping!"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	testing.expect(t, strings.contains(resp, "upstream POST /echo"))
	testing.expect(t, strings.has_suffix(resp, "body=ping!"))
}

@(test)
test_integration_proxy_chunked_upstream :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_chunked_handler
	up_srv.idle_timeout = 2 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer integration_stop(t, up_args, up_th)
	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /chunked HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	// chunked framing is relayed verbatim, terminator included
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "chunked-upstream /chunked"))
	testing.expect(t, strings.has_suffix(resp, "\r\n0\r\n\r\n"))
}

// Raw_Upstream is a one-shot blocking HTTP server used to exercise
// close-delimited upstream responses (no Content-Length, no chunked).
Raw_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
}

raw_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	client, _, aerr := net.accept_tcp(l)
	if aerr != nil {
		net.close(l)
		return
	}
	buf: [4096]byte
	net.recv_tcp(client, buf[:]) // wait for the request to arrive
	response := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nclose-delimited body"
	net.send_tcp(client, transmute([]byte)response)
	net.close(client)
	net.close(l)
}

@(test)
test_integration_proxy_close_delimited :: proc(t: ^testing.T) {
	ru := new(Raw_Upstream, context.allocator)
	ru_th := thread.create(raw_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
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
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /raw HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [8192]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 200 OK\r\n"))
	// the close-delimited upstream body is streamed out re-framed as
	// chunked ("close-delimited body" is 20 bytes, so one 0x14 chunk)
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "Connection: close\r\n"))
	testing.expect(t, strings.has_suffix(resp, "14\r\nclose-delimited body\r\n0\r\n\r\n"))
}

@(test)
test_integration_proxy_upstream_refused :: proc(t: ^testing.T) {
	// bind and immediately release a port so dialing it is refused
	sock, lerr := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	testing.expect(t, lerr == nil)
	dead_ep, _ := net.bound_endpoint(sock)
	net.close(sock)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", dead_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
	p.timeout = 5 * time.Second

	px_srv := new(Server, context.allocator)
	testing.expect(t, server_init(px_srv, "127.0.0.1:0"))
	px_srv.handler = proxy_serve
	px_srv.user_ptr = p
	px_srv.idle_timeout = 2 * time.Second
	px_srv.on_stop = proxy_test_stop
	px_ep, px_th, px_args := integration_spin_srv(t, px_srv)

	defer proxy_destroy(p)
	defer free(p, context.allocator)
	defer integration_stop(t, px_args, px_th)

	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	request := "GET /dead HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	buf: [4096]byte
	total := 0
	for total < len(buf) {
		r, rerr := net.recv_tcp(client, buf[total:])
		if rerr != nil || r == 0 {
			break
		}
		total += r
	}
	resp := string(buf[:total])
	testing.expect(t, strings.has_prefix(resp, "HTTP/1.1 502 Bad Gateway\r\n"))
	testing.expect(t, strings.contains(resp, "upstream connect failed"))
}

// ---------------------------------------------------------------------------
// proxy streaming and upstream connection reuse
// ---------------------------------------------------------------------------

// read_client_all drains a client socket into an owned byte slice.
read_client_all :: proc(client: net.TCP_Socket) -> []byte {
	out := make([dynamic]byte, context.allocator)
	buf: [8192]byte
	for {
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&out, ..buf[:r])
	}
	return out[:]
}

// Raw_Slow_Upstream answers one request with a close-delimited body that it
// hands over in two halves with a pause in between, which is what makes the
// difference between streaming and buffering observable.
Raw_Slow_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
	head:     string,
	tail:     string,
	pause:    time.Duration,
}

raw_slow_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Slow_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	client, _, aerr := net.accept_tcp(l)
	if aerr != nil {
		net.close(l)
		return
	}
	buf: [4096]byte
	net.recv_tcp(client, buf[:])
	net.send_tcp(client, transmute([]byte)ru.head)
	time.sleep(ru.pause)
	net.send_tcp(client, transmute([]byte)ru.tail)
	net.close(client)
	net.close(l)
}

@(test)
test_integration_proxy_streams_early :: proc(t: ^testing.T) {
	// the upstream sends its head and half the body, then stalls: a proxy
	// that buffers the whole response would keep the client silent for the
	// entire pause
	ru := new(Raw_Slow_Upstream, context.allocator)
	ru.head = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nfirst-half "
	ru.tail = "second-half"
	ru.pause = 400 * time.Millisecond
	ru_th := thread.create(raw_slow_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
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
	defer net.close(client)

	request := "GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	sn, serr := net.send_tcp(client, transmute([]byte)request)
	testing.expect(t, serr == nil)
	testing.expect(t, sn == len(request))

	// the first half has to show up long before the pause is over
	start := time.now()
	first := make([dynamic]byte, context.allocator)
	defer delete(first)
	buf: [4096]byte
	for {
		if bytes_contains(first[:], "first-half") {
			break
		}
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&first, ..buf[:r])
	}
	elapsed := time.since(start)
	testing.expectf(t, bytes_contains(first[:], "first-half"), "first half never arrived: %q", string(first[:]))
	testing.expectf(t, elapsed < 250 * time.Millisecond, "first body bytes took %v: the proxy is buffering", elapsed)

	// and the rest still arrives, re-framed as chunked. Read until the
	// terminating chunk shows up (or the connection closes): the tail and
	// the terminator are separate writes, so stopping at "second-half"
	// would race against the final flush.
	for {
		if bytes_contains(first[:], "0\r\n\r\n") {
			break
		}
		r, rerr := net.recv_tcp(client, buf[:])
		if rerr != nil || r == 0 {
			break
		}
		append(&first, ..buf[:r])
	}
	resp := string(first[:])
	testing.expect(t, strings.contains(resp, "Transfer-Encoding: chunked\r\n"))
	testing.expect(t, strings.contains(resp, "first-half "))
	testing.expect(t, strings.contains(resp, "second-half"))
	testing.expect(t, strings.has_suffix(resp, "0\r\n\r\n"))
}

// Raw_Stale_Upstream answers the first request on a connection, promises
// keep-alive and then drops it anyway - the classic stale pooled connection.
Raw_Stale_Upstream :: struct {
	listener: net.TCP_Socket,
	port:     int,
	ready:    bool,
	accepts:  int,
}

raw_stale_upstream_proc :: proc(t: ^thread.Thread) {
	ru := cast(^Raw_Stale_Upstream) t.data
	l, err := net.listen_tcp({address = net.IP4_Address{127, 0, 0, 1}, port = 0})
	if err != nil {
		return
	}
	ru.listener = l
	ep, _ := net.bound_endpoint(l)
	ru.port = ep.port
	intrinsics.volatile_store(&ru.ready, true)

	for i in 0..<2 {
		client, _, aerr := net.accept_tcp(l)
		if aerr != nil {
			break
		}
		ru.accepts += 1
		buf: [4096]byte
		net.recv_tcp(client, buf[:])
		resp := "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: keep-alive\r\n\r\nhello"
		net.send_tcp(client, transmute([]byte)resp)
		time.sleep(50 * time.Millisecond)
		net.close(client) // promise broken
	}
	net.close(l)
}

@(test)
test_integration_proxy_stale_pool_retry :: proc(t: ^testing.T) {
	ru := new(Raw_Stale_Upstream, context.allocator)
	ru_th := thread.create(raw_stale_upstream_proc)
	ru_th.data = ru
	thread.start(ru_th)
	for i in 0..<10000 {
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

	// first request: served, then the upstream socket is pooled and dies
	client, derr := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr == nil)
	req := "GET /one HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
	net.send_tcp(client, transmute([]byte)req)
	body := read_client_all(client)
	defer delete(body)
	net.close(client)
	testing.expect(t, strings.has_suffix(string(body), "hello"))
	testing.expect(t, len(p.pool) == 1)

	// let the upstream drop the pooled connection
	time.sleep(150 * time.Millisecond)

	// second request: the pooled socket is dead, the proxy has to retry
	client2, derr2 := net.dial_tcp_from_endpoint(px_ep)
	testing.expect(t, derr2 == nil)
	net.send_tcp(client2, transmute([]byte)req)
	body2 := read_client_all(client2)
	defer delete(body2)
	net.close(client2)
	resp2 := string(body2)
	testing.expectf(t, strings.has_prefix(resp2, "HTTP/1.1 200 OK\r\n"), "retry did not recover: %q", resp2)
	testing.expect(t, strings.has_suffix(resp2, "hello"))
	testing.expect(t, ru.accepts == 2)
}

@(test)
test_integration_proxy_pool_reuse :: proc(t: ^testing.T) {
	up_srv := new(Server, context.allocator)
	testing.expect(t, server_init(up_srv, "127.0.0.1:0"))
	up_srv.handler = proxy_upstream_handler
	up_srv.idle_timeout = 10 * time.Second
	up_ep, up_th, up_args := integration_spin_srv(t, up_srv)

	addr_buf: [64]byte
	addr := fmt.bprintf(addr_buf[:], "127.0.0.1:%d", up_ep.port)
	p := new(Proxy, context.allocator)
	testing.expect(t, proxy_init(p, {addr}))
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
	defer integration_stop(t, up_args, up_th)
	defer integration_stop(t, px_args, px_th)

	for i in 0..<3 {
		client, derr := net.dial_tcp_from_endpoint(px_ep)
		testing.expect(t, derr == nil)
		request := "GET /reuse HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
		net.send_tcp(client, transmute([]byte)request)
		body := read_client_all(client)
		net.close(client)
		defer delete(body)
		testing.expectf(t, strings.has_prefix(string(body), "HTTP/1.1 200 OK\r\n"), "request %d failed: %q", i, string(body))
		testing.expect(t, strings.has_suffix(string(body), "body="))
	}

	// three client connections, one upstream connection: the pool did its job
	testing.expectf(t, up_srv.stats.conns_opened == 1, "upstream saw %d connections, expected 1", up_srv.stats.conns_opened)
	testing.expectf(t, p.pool_hits == 2, "expected 2 pool hits, got %d", p.pool_hits)
}

/*
test_proxy_health_backoff_cap: repeated ejections double the window and stop at
`max_eject`. Without the cap a backend that has been down for an hour would not
be probed again until the next day, and the doubling is what keeps a flapping
upstream from pulling traffic every few seconds.
*/
@(test)
test_proxy_health_backoff_cap :: proc(t: ^testing.T) {
	p: Proxy
	testing.expect(t, proxy_init(&p, {"127.0.0.1:9001"}))
	defer proxy_destroy(&p)
	p.health.max_failures = 1 // eject on the first failure
	p.health.eject_for = 20 * time.Millisecond
	p.health.max_eject = 50 * time.Millisecond
	p.health.probe = false

	want := [4]time.Duration {
		20 * time.Millisecond,
		40 * time.Millisecond,
		50 * time.Millisecond, // would be 80 without the cap
		50 * time.Millisecond,
	}
	for w, i in want {
		proxy_note_failure(&p, 0)
		state, _, until := proxy_upstream_state(&p, 0)
		testing.expectf(t, state == .Ejected, "ejection %v did not happen", i)
		// time.diff(a, b) is b - a: the remaining window is `until - now`
		window := time.diff(time.now(), until)
		testing.expectf(
			t,
			window <= w && window > w - 5 * time.Millisecond,
			"ejection %v: window %v, want about %v",
			i,
			window,
			w,
		)
	}
	testing.expectf(t, p.upstreams[0].ejections == 4, "ejection counter %v", p.upstreams[0].ejections)
	// an out-of-range index is ignored rather than corrupting a neighbour
	proxy_note_failure(&p, 7)
	proxy_note_success(&p, -1)
	testing.expect(t, p.upstreams[0].failures_total == 4)
}
