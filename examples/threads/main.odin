package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"
import "../../web"

/*
Multi-acceptor demo: N Server instances, one per thread, all bound to the
same address with SO_REUSEPORT. The kernel spreads incoming connections
across the accept loops, so accept/read/write scale with cores and the
library needs no locks - every per-connection structure is already
thread-local.

Handlers are shareable only if they are read-only after setup. Anything
holding event-loop-owned resources (a Proxy and its idle upstream pool, for
example) needs one instance per thread.

	odin run examples/threads                # 4 acceptors on :8099
	odin run examples/threads -- 8 8099 10   # 8 acceptors, :8099, 10 s

Hit it from several shells at once:

	for i in $(seq 20); do curl -s --noproxy '*' localhost:8099/ ; done

Each response reports which acceptor handled it, and the summary on exit
shows the per-acceptor request counts. Both paths spread, by different
mechanisms: Linux hashes the 4-tuple over a SO_REUSEPORT group, macOS/BSD
share one listening fd and hand each connection to whichever loop wakes
first (SO_REUSEPORT there would send everything to a single listener).

A connection stays with the acceptor that accepted it, so open more than one
connection when checking the split - a single curl only ever reaches one
thread.
*/

THREADS :: 4
MAX_ACCEPTORS :: 256

handler :: proc(req: ^web.Request, res: ^web.Response) {
	// No counter here on purpose: the per-acceptor split comes from
	// `Server.stats.requests`, which is per-server state and therefore free of
	// the data race a shared array incremented from every acceptor thread
	// would have.
	id := 0
	if req.conn != nil && req.conn.server != nil {
		id = int(uintptr(req.conn.server.user_ptr))
	}

	buf: [128]byte
	body := fmt.bprintf(buf[:], "hello from acceptor %d\n", id)
	web.response_text(res, .OK, body)
}

Stop_Args :: struct {
	done:    ^bool,
	seconds: int,
}

stopper :: proc(t: ^thread.Thread) {
	a := cast(^Stop_Args) t.data
	time.sleep(time.Duration(a.seconds) * time.Second)
	a.done^ = true
}

main :: proc() {
	count := THREADS
	address := "0.0.0.0:8099"
	seconds := 10
	if len(os.args) > 1 {
		if v, ok := strconv.parse_int(os.args[1]); ok {
			count = clamp(v, 1, MAX_ACCEPTORS)
		}
	}
	if len(os.args) > 2 {
		address = os.args[2]
	}
	if len(os.args) > 3 {
		if v, ok := strconv.parse_int(os.args[3]); ok {
			seconds = v
		}
	}

	// NOTE: the servers are freed in an explicit loop below, not with
	// `defer free(s)` inside this loop - Odin attaches `defer` to the
	// enclosing block, so a defer in a loop body fires at the end of every
	// iteration and would free the server before the loop ever runs it.
	servers := make([]^web.Server, count, context.allocator)
	defer delete(servers)
	for i in 0..<count {
		s := new(web.Server)
		if !web.server_init(s, address) {
			return
		}
		s.handler = handler
		s.user_ptr = rawptr(uintptr(i))
		servers[i] = s
	}

	fmt.printf("%d acceptor(s) on http://%v, running for %vs\n", count, address, seconds)

	done: bool
	args := Stop_Args{done = &done, seconds = seconds}
	stopwatch := thread.create(stopper)
	stopwatch.data = &args
	thread.start(stopwatch)

	ok := web.server_run_multi(servers, &done)
	thread.join(stopwatch)
	thread.destroy(stopwatch)

	if !ok {
		fmt.eprintln("server failed to start")
		os.exit(1)
	}

	total: u64
	for i in 0..<count {
		fmt.printf("acceptor %d: %v request(s)\n", i, servers[i].stats.requests)
		total += servers[i].stats.requests
	}
	fmt.printf("total: %v request(s)\n", total)

	for i in 0..<count {
		web.server_destroy(servers[i])
		free(servers[i], context.allocator)
	}
}
