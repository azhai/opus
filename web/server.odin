package web

import "base:intrinsics"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:time"

// SWEEP_INTERVAL is the maintenance tick period. It doubles as the
// granularity at which `server_run_until` notices its done flag.
SWEEP_INTERVAL :: 250 * time.Millisecond

/*
Handler is the per-request entry point, Mongoose style: one procedure,
request in, response out. The server and any user state (a router, a
static file root) are reachable through `req.conn.server` and
`server.user_ptr`.
*/
Handler :: #type proc(req: ^Request, res: ^Response)

// Conn_Event observes connection lifecycle.
Conn_Event :: #type proc(s: ^Server, c: ^Conn)

Stats :: struct {
	conns_opened: u64,
	conns_active: int,
	requests:     u64,
	bytes_in:     u64,
	bytes_out:    u64,
}

/*
Server owns the listening socket, the connection set and the configuration.
It wraps the thread-local core:nbio event loop (io_uring / kqueue / IOCP
depending on platform) exactly like Mongoose's mg_mgr wraps its poller.
*/
Server :: struct {
	address:  string,
	endpoint: net.Endpoint,

	handler:  Handler,
	user_ptr: rawptr,

	allocator: mem.Allocator,
	conns:     [dynamic]^Conn,
	filters:   ^Filter,

	// built-in chunked encoding filter, registered at listen time so a
	// handler can opt in with `res.chunked = true` and nothing else
	chunked_filter: Chunked_Filter,

	// configuration
	keep_alive:            bool,
	max_requests_per_conn: int,
	max_header_size:       int,
	max_body_size:         int,
	max_conns:             int,
	header_timeout:        time.Duration,
	write_timeout:         time.Duration,
	idle_timeout:          time.Duration,

	on_conn_open:  Conn_Event,
	on_conn_close: Conn_Event,

	stats: Stats,

	listen_socket: net.TCP_Socket,
	listening:     bool,
	done_flag:     ^bool,

	accept_op: ^nbio.Operation,
	sweep_op:  ^nbio.Operation,
}

// server_init parses the listen address ("0.0.0.0:8080", "[::]:8080", ...)
// and fills in defaults. It does not touch the network.
server_init :: proc(s: ^Server, address := "0.0.0.0:8080", allocator := context.allocator) -> bool {
	s.address = address
	ep, ok := net.parse_endpoint(address)
	if !ok {
		log_error("web: invalid listen address: %q", address)
		return false
	}
	s.endpoint = ep
	s.allocator = allocator
	s.conns = make([dynamic]^Conn, allocator)

	s.keep_alive = true
	s.max_requests_per_conn = 1000
	s.max_header_size = 16 << 10
	s.max_body_size = 10 << 20
	s.max_conns = 1024
	s.header_timeout = 30 * time.Second
	s.write_timeout = 30 * time.Second
	s.idle_timeout = 5 * time.Second
	return true
}

server_destroy :: proc(s: ^Server) {
	if len(s.conns) > 0 {
		log_error("web: server_destroy with %v live connection(s)", len(s.conns))
	}
	if s.conns != nil {
		delete(s.conns)
		s.conns = nil
	}
}

// server_listen binds and starts accepting. Must be called from the thread
// that runs the event loop.
server_listen :: proc(s: ^Server) -> bool {
	sock, err := nbio.listen_tcp(s.endpoint, 512)
	if err != nil {
		log_error("web: listen on %v failed: %v", s.address, err)
		return false
	}
	s.listen_socket = sock
	intrinsics.volatile_store(&s.listening, true)
	filter_chunked_init(&s.chunked_filter)
	filter_add(s, &s.chunked_filter.filter)
	s.accept_op = nbio.accept_poly(sock, s, on_accept)
	s.sweep_op = nbio.timeout_poly(SWEEP_INTERVAL, s, on_sweep)
	log_info("web: listening on %v", s.address)
	return true
}

on_accept :: proc(op: ^nbio.Operation, s: ^Server) {
	s.accept_op = nil
	if server_should_stop(s) {
		return
	}
	// keep the accept pipeline full
	s.accept_op = nbio.accept_poly(op.accept.socket, s, on_accept)

	if op.accept.err != nil {
		log_error("web: accept error: %v", op.accept.err)
		return
	}
	client := op.accept.client
	if len(s.conns) >= s.max_conns {
		log_debug("web: connection limit reached, refusing %v", op.accept.client_endpoint)
		nbio.close(client)
		return
	}
	net.set_option(client, .TCP_Nodelay, true)
	c := conn_new(s, client, op.accept.client_endpoint)
	conn_recv_arm(c, s.header_timeout)
}

// on_sweep is the periodic maintenance tick: it drops connections that have
// been idle past the deadline (belt and braces behind the recv timeout) and
// keeps the event loop waking up so `run_until` can observe its done flag.
on_sweep :: proc(op: ^nbio.Operation, s: ^Server) {
	s.sweep_op = nil
	if server_should_stop(s) {
		return
	}

	now := nbio.now()
	to_close: [64]^Conn
	n := 0
	for c in s.conns {
		if n >= len(to_close) {
			break
		}
		if c.idle_since != {} && time.diff(c.idle_since, now) > s.idle_timeout {
			to_close[n] = c
			n += 1
		}
	}
	for i in 0..<n {
		conn_close(to_close[i])
	}

	s.sweep_op = nbio.timeout_poly(SWEEP_INTERVAL, s, on_sweep)
}

server_should_stop :: proc(s: ^Server) -> bool {
	return s.done_flag != nil && intrinsics.volatile_load(s.done_flag)
}

// server_run serves forever (until the process is stopped).
server_run :: proc(s: ^Server) -> (err: nbio.General_Error) {
	if err = nbio.acquire_thread_event_loop(); err != nil {
		log_error("web: cannot acquire event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	if !server_listen(s) {
		return .Unsupported
	}
	return nbio.run()
}

// server_run_until serves until `done` becomes true. Useful for tests and
// supervised deployments.
server_run_until :: proc(s: ^Server, done: ^bool) -> (err: nbio.General_Error) {
	if err = nbio.acquire_thread_event_loop(); err != nil {
		log_error("web: cannot acquire event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	s.done_flag = done
	if !server_listen(s) {
		return .Unsupported
	}
	err = nbio.run_until(done)

	// Graceful drain: cancel the loop-level operations and let in-flight
	// completions (e.g. socket close callbacks that free connections) run.
	if s.accept_op != nil {
		nbio.remove(s.accept_op)
		s.accept_op = nil
	}
	if s.sweep_op != nil {
		nbio.remove(s.sweep_op)
		s.sweep_op = nil
	}
	for i in 0..<200 {
		if nbio.num_waiting() == 0 {
			break
		}
		nbio.tick(10 * time.Millisecond)
	}
	return err
}
