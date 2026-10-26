package main

/*
The multi-core half: N acceptor threads behind SO_REUSEPORT, K pipelining
client threads in the same process. It answers two questions the single-loop
benchmark cannot:

  - does throughput scale with acceptor threads, or does something shared
    (allocator, accept queue, a lock in the library) flatten the curve;
  - is the kernel actually spreading connections, or is one acceptor doing
    all the work while the others idle.

Note on the client: it runs in the same process, so clients and acceptors
compete for the same cores. Read the numbers as "throughput of the whole
machine with N acceptors + K clients", not as a server-only figure. The
distribution column, on the other hand, is exact: it comes from
`Server.stats.requests`, which is per-server state and therefore free of
cross-thread contention.

	odin run bench -- 18100 multi
*/

import "core:fmt"
import "core:net"
import "core:sys/posix"
import "core:strings"
import "core:thread"
import "core:time"

import "../web"

MULTI_SECONDS :: 2
MULTI_BATCH :: 64 // requests in flight per client thread

Multi_Server_Args :: struct {
	servers: []^web.Server,
	done:    ^bool,
}

multi_server_thread :: proc(t: ^thread.Thread) {
	a := cast(^Multi_Server_Args) t.data
	web.server_run_multi(a.servers, a.done)
}

Multi_Conn :: struct {
	sock: net.TCP_Socket,
	// One batch in flight per connection: `sent` walks the request buffer
	// out, `got` accumulates response bytes, and `draining` says which half
	// of the cycle we are in.
	sent:     int,
	got:      int,
	draining: bool,
}

Multi_Client :: struct {
	ep:    net.Endpoint,
	req:   string,
	conns: int, // connections per thread, all driven by one poll loop
	stop:  ^bool, // set by the driver when the window closes
	count: u64, // requests completed, read after join
}

/*
A connection is pinned to the acceptor that accepted it, so the *connection*
is the unit of distribution: a client with one connection per thread can only
ever exercise that many acceptors. Each thread therefore runs many
connections, and drives them from one poll loop rather than walking them one
at a time - a thread that blocks on a single connection leaves the other
thirty idle, which is what capped the earlier multi-acceptor runs at two
cores' worth of load.

Responses are not parsed. The handler's response length is constant, so the
client probes it once and afterwards adds up bytes; scanning status lines cost
about as much per request as the server's own work.
*/
multi_client_thread :: proc(t: ^thread.Thread) {
	c := cast(^Multi_Client) t.data
	req := transmute([]byte)c.req
	out := make([]byte, len(req) * MULTI_BATCH, context.allocator)
	defer delete(out, context.allocator)
	for i in 0 ..< MULTI_BATCH {
		copy(out[i * len(req):], req)
	}
	buf := make([]byte, 64 << 10, context.allocator)
	defer delete(buf, context.allocator)

	// measure one response on a throwaway blocking connection
	probe, perr := net.dial_tcp_from_endpoint(c.ep)
	if perr != nil {
		return
	}
	resp_len := probe_response_len(probe, req, buf)
	net.close(probe)
	if resp_len <= 0 {
		return
	}
	batch_bytes := MULTI_BATCH * resp_len

	conns := make([]Multi_Conn, c.conns, context.allocator)
	defer delete(conns, context.allocator)
	fds := make([]posix.pollfd, c.conns, context.allocator)
	defer delete(fds, context.allocator)
	opened := 0
	defer for i in 0 ..< opened {
		net.close(conns[i].sock)
	}
	for i in 0 ..< c.conns {
		sock, derr := net.dial_tcp_from_endpoint(c.ep)
		if derr != nil {
			return
		}
		net.set_option(sock, .TCP_Nodelay, true)
		net.set_blocking(sock, false)
		conns[i] = Multi_Conn{sock = sock}
		fds[i] = posix.pollfd {
			fd     = posix.FD(sock),
			events = {.IN, .OUT},
		}
		opened += 1
	}

	for !c.stop^ {
		ready := posix.poll(raw_data(fds), posix.nfds_t(len(fds)), 20)
		if ready <= 0 {
			continue
		}
		for i in 0 ..< opened {
			conn := &conns[i]
			re := fds[i].revents
			if .NVAL in re || .ERR in re || .HUP in re {
				return
			}
			if !conn.draining && .OUT in re {
				n, err := net.send_tcp(conn.sock, out[conn.sent:])
				if err == nil {
					conn.sent += n
					if conn.sent == len(out) {
						conn.sent = 0
						conn.draining = true
					}
				}
			}
			if .IN in re {
				for {
					n, err := net.recv_tcp(conn.sock, buf)
					if err != nil || n <= 0 {
						break
					}
					conn.got += n
					if conn.got >= batch_bytes {
						conn.got -= batch_bytes
						conn.draining = false
						c.count += MULTI_BATCH
						break
					}
				}
			}
		}
	}
}

// probe_response_len sends one request and measures the whole response: head,
// header block and Content-Length body.
probe_response_len :: proc(sock: net.TCP_Socket, req: []byte, buf: []byte) -> int {
	send_batch(sock, req)
	have := 0
	for {
		for i := 0; i + 4 <= have; i += 1 {
			if bytes_at(buf[:have], i, "\r\n\r\n") {
				return i + 4 + content_length_bench(buf[:i])
			}
		}
		if have + 1 >= len(buf) {
			return 0
		}
		n, err := net.recv_tcp(sock, buf[have:])
		if err != nil || n <= 0 {
			return 0
		}
		have += n
	}
}

/*
multi_scale runs the same workload with 1, 2, 4, 8 acceptors and reports
throughput, the per-acceptor split and the scaling efficiency.
*/
multi_scale :: proc(port: int) {
	clients := 4
	conns := 4
	fmt.println("== multi-core (SO_REUSEPORT acceptors + pipelining clients, same machine) ==")

	baseline: f64
	for acceptors in ([4]int{1, 2, 4, 6}) {
		rps, split, ok := multi_run(port, acceptors, clients, conns, MULTI_SECONDS, false)
		if !ok {
			fmt.printf("%v acceptor(s): failed\n", acceptors)
			continue
		}
		if baseline == 0 {
			baseline = rps
		}
		fmt.printf(
			"%-2v acceptors  %-10.0f req/s  %-6.2f us/req  scale %-5.2fx  efficiency %-5.1f%%  split %v\n",
			acceptors,
			rps,
			1e6 / rps,
			rps / baseline,
			rps / (baseline * f64(acceptors)) * 100,
			split,
		)
	}

	fmt.println()
	fmt.println("== same, with the router in the path (120 routes) ==")
	for acceptors in ([3]int{1, 4, 6}) {
		rps, split, ok := multi_run(port, acceptors, clients, conns, MULTI_SECONDS, true)
		if !ok {
			fmt.printf("%v acceptor(s): failed\n", acceptors)
			continue
		}
		fmt.printf(
			"%-2v acceptors  %-10.0f req/s  %-6.2f us/req  split %v\n",
			acceptors,
			rps,
			1e6 / rps,
			split,
		)
	}
}

// multi_run starts `acceptors` servers on `port`, drives them with `clients`
// pipelining threads for `seconds`, then stops everything and reports. When
// `router` is set the handler goes through a 120-route table, otherwise it is
// the bare "ok" handler.
multi_run :: proc(port, acceptors, clients, conns, seconds: int, router: bool) -> (rps: f64, split: string, ok: bool) {
	servers := make([]^web.Server, acceptors, context.allocator)
	defer delete(servers, context.allocator)
	// the address string is kept alive for the lifetime of the server:
	// server_init stores the pointer, it does not copy it
	addrs := make([]string, acceptors, context.allocator)
	defer delete(addrs, context.allocator)

	for i in 0 ..< acceptors {
		s := new(web.Server, context.allocator)
		addrs[i] = fmt.aprintf("127.0.0.1:%v", port, allocator = context.allocator)
		if !web.server_init(s, addrs[i]) {
			return 0, "", false
		}
		s.max_requests_per_conn = 1 << 30
		s.idle_timeout = 10 * time.Second
		if router {
			r := new(web.Router, context.allocator)
			web.router_init(r)
			for k in 0 ..< 120 {
				path := fmt.aprintf("/api/resource%v/status", k, allocator = context.allocator)
				web.router_get(r, path, load_ok)
				delete(path, context.allocator)
			}
			s.handler = web.router_handle
			s.user_ptr = r
		} else {
			s.handler = load_ok
		}
		servers[i] = s
	}
	defer {
		for s in servers {
			web.server_destroy(s)
			free(s, context.allocator)
		}
	}

	done: bool
	sargs := Multi_Server_Args {
		servers = servers,
		done    = &done,
	}
	sth := thread.create(multi_server_thread)
	sth.data = &sargs
	thread.start(sth)

	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	if !wait_for_server(ep) {
		done = true
		thread.join(sth)
		thread.destroy(sth)
		return 0, "", false
	}

	request := "GET /api/resource42/status HTTP/1.1\r\nHost: h\r\n\r\n"
	if !router {
		request = "GET / HTTP/1.1\r\nHost: h\r\n\r\n"
	}

	// clients == 0 means "serve only": the driver sleeps while an external
	// client (oha, wrk, ...) drives the group. Same-process clients compete
	// for the cores the acceptors need, so anything measured with them is a
	// whole-machine number; an external client at least has its own scheduler
	// and can open as many connections as the test needs.
	stop: bool
	total: u64
	elapsed: time.Duration
	start := time.tick_now()
	if clients > 0 {
		states := make([]Multi_Client, clients, context.allocator)
		defer delete(states, context.allocator)
		threads := make([]^thread.Thread, clients, context.allocator)
		defer delete(threads, context.allocator)
		for i in 0 ..< clients {
			states[i] = Multi_Client {
				ep    = ep,
				req   = request,
				conns = conns,
				stop  = &stop,
			}
			th := thread.create(multi_client_thread)
			th.data = &states[i]
			thread.start(th)
			threads[i] = th
		}

		start = time.tick_now()
		time.sleep(time.Duration(seconds) * time.Second)
		elapsed = time.tick_since(start)
		stop = true

		for i in 0 ..< clients {
			thread.join(threads[i])
			thread.destroy(threads[i])
			total += states[i].count
		}
	} else {
		time.sleep(time.Duration(seconds) * time.Second)
		elapsed = time.tick_since(start)
	}

	done = true
	thread.join(sth)
	thread.destroy(sth)

	if clients > 0 && elapsed > 0 {
		rps = f64(total) / time.duration_seconds(elapsed)
	}

	// the server-side counters are authoritative: they cannot be inflated by
	// a client that miscounts, and they show the spread
	served: u64
	lo := u64(max(u64))
	hi: u64
	parts := make([dynamic]string, 0, acceptors, context.allocator)
	defer delete(parts)
	for i in 0 ..< acceptors {
		n := servers[i].stats.requests
		served += n
		lo = min(lo, n)
		hi = max(hi, n)
		append(&parts, fmt.aprintf("%v", n))
	}
	if served > 0 && hi > 0 {
		append(&parts, fmt.aprintf("min/max %.0f%%", f64(lo) / f64(hi) * 100))
	}
	split = strings.join(parts[:], " ", context.allocator)
	return rps, split, true
}

// multi_serve runs a group with no in-process client and reports how the
// external client's connections landed. Used with oha/wrk so the load
// generator is not competing for the acceptors' cores.
multi_serve :: proc(port, acceptors, seconds: int) {
	fmt.printf("serving on 127.0.0.1:%v with %v acceptor(s) for %vs\n", port, acceptors, seconds)
	_, split, ok := multi_run(port, acceptors, 0, 0, seconds, false)
	if !ok {
		fmt.println("server failed to start")
		return
	}
	fmt.printf("%v acceptors served: %v\n", acceptors, split)
}

/*
multi_load is the client half as a standalone process, so the server can be
measured with /usr/bin/time while the load generator runs elsewhere. Two
processes also means two schedulers: the acceptors and the client no longer
steal each other's timeslices, and the CPU time each side burns is
attributable.
*/
multi_load :: proc(port, clients, conns, seconds: int) {
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	if !wait_for_server(ep) {
		fmt.eprintln("no server on", port)
		return
	}

	stop: bool
	states := make([]Multi_Client, clients, context.allocator)
	defer delete(states, context.allocator)
	threads := make([]^thread.Thread, clients, context.allocator)
	defer delete(threads, context.allocator)
	for i in 0 ..< clients {
		states[i] = Multi_Client {
			ep    = ep,
			req   = "GET / HTTP/1.1\r\nHost: h\r\n\r\n",
			conns = conns,
			stop  = &stop,
		}
		th := thread.create(multi_client_thread)
		th.data = &states[i]
		thread.start(th)
		threads[i] = th
	}

	start := time.tick_now()
	time.sleep(time.Duration(seconds) * time.Second)
	elapsed := time.tick_since(start)
	stop = true

	total: u64
	for i in 0 ..< clients {
		thread.join(threads[i])
		thread.destroy(threads[i])
		total += states[i].count
	}
	rps := f64(total) / time.duration_seconds(elapsed)
	fmt.printf("client: %v threads x %v conns -> %v req/s (%.2f us/req)\n", clients, conns, int(rps), 1e6 / rps)
}
