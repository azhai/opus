package main

/*
The load half: one server on one thread, one pipelining client. Throughput is
reported as requests per second on a single core, which is the number a
per-request optimisation moves. Latency would measure the loop, not the code.
*/

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"

import "../web"

LOAD_ROUNDS :: 12 // pipelined batches per scenario
LOAD_BATCH  :: 512 // requests per batch, all in flight at once
SERIAL_ROUNDS :: 4000 // one-request-at-a-time rounds

Load_State :: struct {
	srv:  ^web.Server,
	done: bool,
}

load_thread :: proc(t: ^thread.Thread) {
	st := cast(^Load_State) t.data
	web.server_run_until(st.srv, &st.done)
}

// ---------------------------------------------------------------------------
// handlers
// ---------------------------------------------------------------------------

load_json_body: []byte

load_json :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Content-Type", "application/json")
	web.response_write(res, load_json_body)
}

load_ok :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_text(res, .OK, "ok\n")
}

load_param :: proc(req: ^web.Request, res: ^web.Response) {
	id, _ := web.request_param(req, "id")
	web.response_text(res, .OK, id)
}

// ---------------------------------------------------------------------------
// client
// ---------------------------------------------------------------------------

// pipelined_rps sends `batch` requests back to back on one connection and
// counts the responses that come back. Returns requests per second.
pipelined_rps :: proc(ep: net.Endpoint, request: string, batch: int, rounds: int) -> (rps: f64, ok: bool) {
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		fmt.eprintln("dial:", derr)
		return 0, false
	}
	defer net.close(sock)
	net.set_option(sock, .TCP_Nodelay, true)
	net.set_option(sock, .Receive_Timeout, 20 * time.Second)

	req := transmute([]byte)request
	out := make([]byte, len(req) * batch, context.allocator)
	defer delete(out, context.allocator)
	for i in 0 ..< batch {
		copy(out[i * len(req):], req)
	}

	buf := make([]byte, 64 << 10, context.allocator)
	defer delete(buf, context.allocator)

	// one warm-up batch so the arena, the route table and the Date cache are
	// all in steady state before the clock starts
	send_batch(sock, out)
	if !drain_batch(sock, buf, batch) {
		return 0, false
	}

	total := 0
	start := time.tick_now()
	for _ in 0 ..< rounds {
		send_batch(sock, out)
		if !drain_batch(sock, buf, batch) {
			return 0, false
		}
		total += batch
	}
	elapsed := time.tick_since(start)
	return f64(total) / time.duration_seconds(elapsed), true
}

send_batch :: proc(sock: net.TCP_Socket, out: []byte) {
	sent := 0
	for sent < len(out) {
		n, err := net.send_tcp(sock, out[sent:])
		if err != nil || n <= 0 {
			return
		}
		sent += n
	}
}

// drain_batch reads until `want` status lines have arrived.
drain_batch :: proc(sock: net.TCP_Socket, buf: []byte, want: int) -> bool {
	seen := 0
	for seen < want {
		n, err := net.recv_tcp(sock, buf)
		if err != nil || n <= 0 {
			return false
		}
		// count "HTTP/1.1 " occurrences in one pass
		i := 0
		for i + 9 <= n {
			if buf[i] == 'H' && bytes_at(buf[:n], i, "HTTP/1.1 ") {
				seen += 1
				i += 9
				continue
			}
			i += 1
		}
	}
	return true
}

/*
bytes_at reports whether `hay` holds `needle` at offset i. It exists because
the obvious spelling - `string(hay[i:i+9]) == needle` - converts a slice to a
string, and in Odin that copies. Inside a per-byte scan it allocated once per
candidate byte, which made the client, not the server, the limit of the
pipelined scenario.
*/
bytes_at :: proc(hay: []byte, i: int, needle: string) -> bool {
	if i < 0 || i + len(needle) > len(hay) {
		return false
	}
	for k in 0 ..< len(needle) {
		if hay[i + k] != needle[k] {
			return false
		}
	}
	return true
}

/*
serial_rps is the other traffic shape: one request in flight at a time, the way
a keep-alive client that is not pipelining behaves. Batching cannot help here -
nothing is ever waiting in the input buffer - so this number is the guard
against an optimisation that only looks good in a pipelined benchmark.
*/
serial_rps :: proc(ep: net.Endpoint, request: string, rounds: int) -> (rps: f64, ok: bool) {
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		fmt.eprintln("dial:", derr)
		return 0, false
	}
	defer net.close(sock)
	net.set_option(sock, .TCP_Nodelay, true)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)

	req := transmute([]byte)request
	buf := make([]byte, 64 << 10, context.allocator)
	defer delete(buf, context.allocator)

	if !serial_round(sock, req, buf) {
		return 0, false
	}
	start := time.tick_now()
	for _ in 0 ..< rounds {
		if !serial_round(sock, req, buf) {
			return 0, false
		}
	}
	elapsed := time.tick_since(start)
	return f64(rounds) / time.duration_seconds(elapsed), true
}

// serial_round sends one request and consumes exactly one response: head,
// then Content-Length bytes of body.
serial_round :: proc(sock: net.TCP_Socket, req: []byte, buf: []byte) -> bool {
	send_batch(sock, req)
	have, head_end, body_len := 0, -1, 0
	for {
		if head_end < 0 {
			for i := 0; i + 4 <= have; i += 1 {
				if bytes_at(buf[:have], i, "\r\n\r\n") {
					head_end = i + 4
					body_len = content_length_bench(buf[:i])
					break
				}
			}
		}
		if head_end >= 0 && have >= head_end + body_len {
			return true
		}
		if have + 1 >= len(buf) {
			return false
		}
		n, err := net.recv_tcp(sock, buf[have:])
		if err != nil || n <= 0 {
			return false
		}
		have += n
	}
}

// content_length_bench reads Content-Length out of a response head.
content_length_bench :: proc(head: []byte) -> int {
	name := "content-length:"
	i := 0
	for i < len(head) {
		line_end := i
		for line_end + 2 <= len(head) && !bytes_at(head, line_end, "\r\n") {
			line_end += 1
		}
		if line_end - i >= len(name) {
			match := true
			for k in 0 ..< len(name) {
				c := head[i + k]
				if c >= 'A' && c <= 'Z' {
					c += 'a' - 'A'
				}
				if c != name[k] {
					match = false
					break
				}
			}
			if match {
				v := 0
				for k := i + len(name); k < line_end; k += 1 {
					c := head[k]
					if c == ' ' || c == '\t' {
						continue
					}
					if c < '0' || c > '9' {
						return 0
					}
					v = v * 10 + int(c - '0')
				}
				return v
			}
		}
		i = line_end + 2
	}
	return 0
}

// ---------------------------------------------------------------------------
// scenarios
// ---------------------------------------------------------------------------

load :: proc(port: int) {
	fmt.println("== load (one loop thread, pipelined) ==")

	load_json_body = json_payload(40)

	srv := new(web.Server, context.allocator)
	addr := fmt.aprintf("127.0.0.1:%v", port)
	if !web.server_init(srv, addr) {
		fmt.eprintln("bad address")
		return
	}
	srv.max_requests_per_conn = 1 << 30
	srv.idle_timeout = 10 * time.Second

	router := new(web.Router, context.allocator)
	web.router_init(router)
	for i in 0 ..< 120 {
		path := fmt.aprintf("/api/resource%v/status", i, allocator = context.allocator)
		web.router_get(router, path, load_ok)
	}
	for i in 0 ..< 8 {
		path := fmt.aprintf("/api/v%v/items/:id", i, allocator = context.allocator)
		web.router_get(router, path, load_param)
	}
	web.router_get(router, "/json", load_json)

	srv.handler = web.router_handle
	srv.user_ptr = router

	st := Load_State {
		srv = srv,
	}
	th := thread.create(load_thread)
	th.data = &st
	thread.start(th)

	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	if !wait_for_server(ep) {
		fmt.eprintln("server did not come up on", addr)
		return
	}

	run_scenario(ep, "GET static route (1st of 120)", "GET /api/resource0/status HTTP/1.1\r\nHost: h\r\n\r\n")
	run_scenario(ep, "GET static route (119th of 120)", "GET /api/resource119/status HTTP/1.1\r\nHost: h\r\n\r\n")
	run_scenario(ep, "GET :param route", "GET /api/v7/items/999 HTTP/1.1\r\nHost: h\r\n\r\n")
	run_scenario(ep, "GET 404", "GET /nope HTTP/1.1\r\nHost: h\r\n\r\n")
	run_scenario(
		ep,
		"GET /json 4 KiB",
		"GET /json HTTP/1.1\r\nHost: h\r\nUser-Agent: bench\r\nAccept: */*\r\n\r\n",
	)
	run_scenario(
		ep,
		"GET /json 4 KiB + gzip",
		"GET /json HTTP/1.1\r\nHost: h\r\nAccept-Encoding: gzip\r\n\r\n",
	)

	fmt.println()
	fmt.println("== serial (one request in flight, keep-alive) ==")
	run_serial(ep, "GET static route (119th of 120)", "GET /api/resource119/status HTTP/1.1\r\nHost: h\r\n\r\n")
	run_serial(ep, "GET /json 4 KiB", "GET /json HTTP/1.1\r\nHost: h\r\n\r\n")

	run_hello(port + 1)
	run_static(ep)

	fmt.println()
	st.done = true
	thread.join(th)
	thread.destroy(th)
}

run_scenario :: proc(ep: net.Endpoint, name, request: string) {
	rps, ok := pipelined_rps(ep, request, LOAD_BATCH, LOAD_ROUNDS)
	if !ok {
		fmt.printf("%-42s failed\n", name)
		return
	}
	fmt.printf("%-42s %10.0f req/s  %6.2f us/req\n", name, rps, 1e6 / rps)
}

run_serial :: proc(ep: net.Endpoint, name, request: string) {
	rps, ok := serial_rps(ep, request, SERIAL_ROUNDS)
	if !ok {
		fmt.printf("%-42s failed\n", name)
		return
	}
	fmt.printf("%-42s %10.0f req/s  %6.2f us/rtt\n", name, rps, 1e6 / rps)
}

// run_hello measures the floor: one handler, no router, no headers worth
// looking at. Whatever separates this from the routed scenarios is router cost.
run_hello :: proc(port: int) {
	srv := new(web.Server, context.allocator)
	addr := fmt.aprintf("127.0.0.1:%v", port)
	if !web.server_init(srv, addr) {
		return
	}
	srv.handler = load_ok
	srv.max_requests_per_conn = 1 << 30
	srv.idle_timeout = 10 * time.Second

	st := Load_State {
		srv = srv,
	}
	th := thread.create(load_thread)
	th.data = &st
	thread.start(th)
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	if wait_for_server(ep) {
		run_scenario(ep, "GET hello (no router)", "GET / HTTP/1.1\r\nHost: h\r\n\r\n")
		run_serial(ep, "GET hello (no router)", "GET / HTTP/1.1\r\nHost: h\r\n\r\n")
	}
	st.done = true
	thread.join(th)
	thread.destroy(th)
}

// wait_for_server polls until the listener accepts.
wait_for_server :: proc(ep: net.Endpoint) -> bool {
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp_from_endpoint(ep)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// run_static serves a file from a temp directory: the sendfile path plus the
// stat cache.
run_static :: proc(ep: net.Endpoint) {
	dir := "/tmp/opus-bench-static"
	os.remove_all(dir)
	if os.make_directory_all(dir) != nil {
		return
	}
	defer os.remove_all(dir)
	path := fmt.aprintf("%v/index.html", dir)
	body := json_payload(40) // any 4 KiB file
	if os.write_entire_file(path, body) != nil {
		return
	}
	st := new(web.Static, context.allocator)
	web.static_init(st, dir)
	srv := new(web.Server, context.allocator)
	web.server_init(srv, "127.0.0.1:18098")
	srv.handler = web.static_serve
	srv.user_ptr = st
	srv.max_requests_per_conn = 1 << 30
	srv.idle_timeout = 10 * time.Second

	st2 := Load_State {
		srv = srv,
	}
	th := thread.create(load_thread)
	th.data = &st2
	thread.start(th)
	ep2 := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = 18098,
	}
	if wait_for_server(ep2) {
		run_scenario(ep2, "GET static file 4 KiB (sendfile)", "GET /index.html HTTP/1.1\r\nHost: h\r\n\r\n")
		// every request a different 404: the shadow of the stat cache
		rps, ok := pipelined_rps(ep2, "GET /missing-0 HTTP/1.1\r\nHost: h\r\n\r\n", 64, 4)
		if ok {
			fmt.printf("%-42s %10.0f req/s  %6.2f us/req\n", "GET 404 (stat cache negative hit)", rps, 1e6 / rps)
		}
	}
	st2.done = true
	thread.join(th)
	thread.destroy(th)
}
