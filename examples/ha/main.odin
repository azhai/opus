package main

/*
High availability: opus serves, tina supervises, and a lying counter kills.

One process, three kinds of thread:

	main thread   tina's watchdog - tina_start blocks here until SIGINT/SIGTERM
	tina shard    a Sentinel isolate that probes /health over real TCP, plus a
	              one-shot Prober isolate per probe
	opus thread   the acceptor: web.server_run_until, its own nbio event loop

The supervised service and its supervisor share nothing but the wire. The
Sentinel does not read opus counters through a pointer - it opens a socket,
sends a request, and believes only what the response says. That is what makes
this safe to run: no lock, no shared heap, and a shard crashing cannot take a
connection with it.

	routes
	  GET  /health       the probe target. Publishes X-Opus-Served (requests
	                     handled) and X-Opus-Seq (how many of them were
	                     /health). seq <= served always holds, because every
	                     health line is itself a request.
	  POST /admin/rot    poisons the page: it starts publishing
	                     seq = served + 9, a number that cannot be true
	  POST /admin/heal   puts the invariant back
	  GET  /             what to curl

Where it fails early, in the order the layers fire:

	compile time   #asserts on the sizes of the messages the isolates exchange,
	               on the restart budget, on the probe timings
	preflight      the address is parsed and the port is really bindable before
	               a thread exists - a failure exits 1 and nothing listens
	startup        the acceptor has to be listening before tina_start runs, so
	               the supervisor never watches a service that never came up
	runtime        a contradictory /health crashes the Sentinel on the spot,
	               its restart budget then quarantines the shard, and the
	               process keeps serving through both

What is deliberately NOT a crash: a refused connection, a slow response, a page
whose counters are missing. Those are transport faults - recorded, warned about,
and answered to - because "unreachable" is a fact about the network while
"impossible" is a fact about the process. Only the second one ends an isolate.
That boundary is the whole example.

Run it (tina is a checkout, passed in with -collection). Linux/BSD only:

	odin run examples/ha -collection:tina=/path/to/tina -- 127.0.0.1:8097

	On macOS with dev-2026-10 the build never gets here - tina_start calls
	core:sys/info.ram_stats, whose darwin implementation reaches Objective-C,
	and Odin's backend asserts. The SIGUSR2 revive below also dies instead of
	reviving. Both are tina/Odin, not opus.

	# the ledger is consistent, so every probe passes
	curl -s --noproxy '*' -D- -o/dev/null http://127.0.0.1:8097/health

	# break the invariant and read the escalation in the log
	curl -s --noproxy '*' -X POST http://127.0.0.1:8097/admin/rot
	#   probe #1 -> Contract_Violation -> restart (1 of budget 2)
	#   probe #2 -> Contract_Violation -> restart (2 of budget 2)
	#   probe #3 -> budget spent       -> shard QUARANTINED, opus still serves

	curl -s --noproxy '*' http://127.0.0.1:8097/          # still answering

	# heal first, then revive: an unhealed shard quarantines again on tick 1
	curl -s --noproxy '*' -X POST http://127.0.0.1:8097/admin/heal
	kill -USR2 <pid>                                      # watchdog revives it

	Ctrl-C     tina drains its shards, then the acceptor drains its
	           connections, then the process exits 0
*/

import "base:intrinsics"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "../../http"
import "../../web"
import tina "tina:src"

DEFAULT_ADDRESS :: "127.0.0.1:8097"

// PROBE_MS is how often the Sentinel asks; PROBE_TIMEOUT_MS is how long one
// answer may take before that probe is given up on.
PROBE_MS         :: #config(OPUS_HA_PROBE_MS, 250)
PROBE_TIMEOUT_MS :: #config(OPUS_HA_PROBE_TIMEOUT_MS, 1500)

// RESTART_MAX is the group's restart budget: the (RESTART_MAX + 1)'th crash
// inside the window escalates, and the shard is quarantined instead restarted.
RESTART_MAX          :: #config(OPUS_HA_RESTART_MAX, 2)
RESTART_WINDOW_TICKS :: #config(OPUS_HA_RESTART_WINDOW_TICKS, 20_000)

// ROT_SKEW is how far /admin/rot pushes the health sequence past the request
// count it must stay under.
ROT_SKEW :: 9

// The isolation a shard has to offer is only worth having if the unit that
// dies is small: one isolate, one probe, one socket.
SENTINEL_TYPE :: tina.Isolate_Type_Id(0)
PROBER_TYPE   :: tina.Isolate_Type_Id(1)

TAG_TICK: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 1
TAG_PROBE_DUE: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 2
TAG_HEALTH: tina.Message_Tag : tina.USER_MESSAGE_TAG_BASE + 3

LOG_DEMO: tina.Log_Tag : tina.USER_LOG_TAG_BASE + 1

// ============================================================================
// opus side: the supervised service
// ============================================================================

// Service_State is reached through Server.user_ptr and touched only on the
// acceptor's event-loop thread, which is why it needs no atomics. Adding a
// second acceptor (web.server_run_multi) means one of these per thread.
Service_State :: struct {
	health_seq: u64,
	rotten:     bool,
}

// set_counter_header publishes a counter. response_set_header keeps a string
// view and the headers are serialized after the handler returns, so the digits
// have to live on the per-request arena rather than on the handler's stack.
set_counter_header :: proc(res: ^web.Response, name: string, value: u64) {
	web.response_set_header(res, name, web.int_to_string(i64(value), web.response_allocator(res)))
}

handler :: proc(req: ^web.Request, res: ^web.Response) {
	srv := req.conn.server
	st := cast(^Service_State) srv.user_ptr

	switch req.path {
	case "/health":
		if req.method != http.Method.Get {
			web.response_text(res, .Method_Not_Allowed, "GET only\n")
			return
		}
		st.health_seq += 1
		// stats.requests already counts this one: it is incremented when the
		// head is parsed, before the handler runs
		served := srv.stats.requests
		seq := st.health_seq
		if st.rotten {
			// the bug the supervisor is looking for: a number that cannot be
			// true, on a page that otherwise looks perfectly healthy
			seq = served + ROT_SKEW
		}

		set_counter_header(res, "X-Opus-Served", served)
		set_counter_header(res, "X-Opus-Seq", seq)

		body: [128]u8
		web.response_text(res, .OK, fmt.bprintf(
			body[:], "opus ok served=%v seq=%v rotten=%v\n", served, seq, st.rotten,
		))

	case "/admin/rot":
		if req.method != http.Method.Post {
			web.response_text(res, .Method_Not_Allowed, "POST only\n")
			return
		}
		st.rotten = true
		web.response_text(res, .OK, "the health page now publishes seq = served + 9\n")

	case "/admin/heal":
		if req.method != http.Method.Post {
			web.response_text(res, .Method_Not_Allowed, "POST only\n")
			return
		}
		st.rotten = false
		web.response_text(res, .OK, "the health page is consistent again\n")

	case "/":
		web.response_text(res, .OK,
			"opus + tina\n" +
			"  GET  /health      what the supervisor probes (X-Opus-Served, X-Opus-Seq)\n" +
			"  POST /admin/rot   publish seq > served -> the Sentinel crashes\n" +
			"  POST /admin/heal  restore the invariant\n")

	case:
		web.response_text(res, .Not_Found, "no such route\n")
	}
}

Service_Args :: struct {
	srv:  ^web.Server,
	done: ^bool,
}

// service_thread runs a whole opus loop: it owns its event loop, binds its
// listener, and stops when `done` is set.
service_thread :: proc(t: ^thread.Thread) {
	a := cast(^Service_Args) t.data
	web.server_run_until(a.srv, a.done)
}

// ============================================================================
// the messages the two isolates exchange
// ============================================================================

// Sentinel_Args is what the Sentinel knows about the service it watches.
Sentinel_Args :: struct {
	ip:         net.IP4_Address,
	port:       u16,
	probe_ns:   u64,
	timeout_ns: u64,
}

// Probe_Job is handed to a fresh Prober isolate when it is spawned.
Probe_Job :: struct {
	sentinel: tina.Isolate_Handle,
	probe_id: u32,
	ip:       net.IP4_Address,
	port:     u16,
}

// Probe_Result travels back on one message, so the Sentinel judges the wire
// rather than a pointer it was handed.
Probe_Result :: struct {
	probe_id:  u32,
	status:    u16, // HTTP status, 0 when no response arrived
	connected: bool,
	parsed:    bool, // both counters were read
	served:    u64,
	seq:       u64,
}

// ============================================================================
// pre-flight, layer 1: what the compiler is allowed to refuse
// ============================================================================

// A message that does not fit cannot be sent at all, and the limit is a hard
// constant in tina - so the shapes are checked here instead of at the first
// probe of the first run.
#assert(size_of(Sentinel_Args) <= tina.MAX_INIT_ARGS_SIZE)
#assert(size_of(Probe_Job) <= tina.MAX_INIT_ARGS_SIZE)
#assert(size_of(Probe_Result) <= tina.MAX_PAYLOAD_SIZE)

// tina refuses a group whose budget is below 1, and it finds out in
// tina_start - after this process would already be listening. Same rule, one
// layer earlier.
#assert(RESTART_MAX >= 1, "tina: restart_count_max must be at least 1")
#assert(RESTART_WINDOW_TICKS >= 1_000, "the restart window must span at least a second of ticks")
#assert(PROBE_MS > 0 && PROBE_TIMEOUT_MS > 0, "probe timings must be positive")
#assert(PROBE_TIMEOUT_MS < PROBE_MS * 8, "a probe that outlives eight intervals makes its timeout pointless")

// ============================================================================
// Prober: one probe, one isolate, then it is gone
// ============================================================================

// The request bytes live inside the isolate: ctx_io_send is zero-copy and
// points at an offset within the isolate struct, so a stack buffer would be
// gone by the time the write happens.
ProberIsolate :: struct {
	sentinel:  tina.Isolate_Handle,
	probe_id:  u32,
	fd:        tina.FD_Handle,
	request:   [256]u8,
	request_n: u16,
	result:    Probe_Result,
}

prober_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(ProberIsolate, self_raw)
	job := tina.payload_as(Probe_Job, args)
	self.sentinel = job.sentinel
	self.probe_id = job.probe_id

	self.request_n = u16(len(fmt.bprintf(self.request[:],
		"GET /health HTTP/1.1\r\n" +
		"Host: %d.%d.%d.%d:%d\r\n" +
		"User-Agent: opus-ha-probe\r\n" +
		"Accept: */*\r\n" +
		"Connection: close\r\n" +
		"\r\n",
		int(job.ip[0]), int(job.ip[1]), int(job.ip[2]), int(job.ip[3]), int(job.port))))

	fd, err := tina.ctx_socket(.AF_INET, .STREAM, .TCP)
	if err != .None {
		// the probe never started: say so instead of letting it time out
		self.result.probe_id = self.probe_id
		_ = tina.ctx_send(self.sentinel, TAG_HEALTH, &self.result)
		return tina.ISOLATE_TRANSITION_DONE
	}
	self.fd = fd

	return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Connect{
		fd      = self.fd,
		address = tina.ipv4(job.ip[0], job.ip[1], job.ip[2], job.ip[3], job.port),
	}))
}

// report answers the probe and closes the socket in the same turn: ctx_send
// routes immediately, the close is this turn's staged effect.
report :: proc(self: ^ProberIsolate) -> tina.Isolate_Transition {
	self.result.probe_id = self.probe_id
	_ = tina.ctx_send(self.sentinel, TAG_HEALTH, &self.result)
	return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Close{fd = self.fd}))
}

prober_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
	self := tina.self_as(ProberIsolate, self_raw)

	switch message.tag {
	case tina.IO_TAG_CONNECT_COMPLETE:
		if message.io.result < 0 || tina.ctx_is_shutting_down() {
			return report(self) // result.connected stays false
		}
		self.result.connected = true
		return tina.transition_to_wait_io_or_crash(
			tina.ctx_io_send(self, self.fd, self.request[:int(self.request_n)]),
		)

	case tina.IO_TAG_SEND_COMPLETE:
		if message.io.result < 0 {
			return report(self)
		}
		return tina.transition_to_wait_io_or_crash(tina.ctx_submit_io(tina.IoOp_Recv{
			fd              = self.fd,
			buffer_size_max = 1024,
		}))

	case tina.IO_TAG_RECV_COMPLETE:
		if message.io.result <= 0 {
			return report(self)
		}
		n := u32(min(int(message.io.result), 1024))
		parse_health(&self.result, tina.ctx_read_io_slot(message.io.buffer_index, n))
		return report(self)

	case tina.IO_TAG_CLOSE_COMPLETE:
		return tina.ISOLATE_TRANSITION_DONE

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

// ============================================================================
// Sentinel: the supervisor that reads a page and believes the arithmetic
// ============================================================================

SentinelIsolate :: struct {
	target:     net.IP4_Address,
	port:       u16,
	probe_ns:   u64,
	timeout_ns: u64,

	next_probe: u32,
	pending:    u32, // probe_id awaiting its answer, 0 when none is in flight

	served:      u64, // the last values the wire reported
	seq:         u64,
	ok:          u64,
	timeouts:    u64,
	transport:   u64, // faults that were about the wire, not the ledger
	consecutive: u64, // transport faults in a row, reset by a good probe
}

sentinel_init :: proc(self_raw: rawptr, args: []u8) -> tina.Isolate_Transition {
	self := tina.self_as(SentinelIsolate, self_raw)
	a := tina.payload_as(Sentinel_Args, args)
	self.target = a.ip
	self.port = a.port
	self.probe_ns = a.probe_ns
	self.timeout_ns = a.timeout_ns

	logf(.INFO, "sentinel up: probing %d.%d.%d.%d:%d every %dns",
		a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.port, a.probe_ns)

	tina.ctx_register_timer(self.probe_ns, TAG_TICK)
	return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
}

sentinel_handler :: proc(self_raw: rawptr, message: ^tina.Message) -> tina.Isolate_Transition {
	self := tina.self_as(SentinelIsolate, self_raw)

	switch message.tag {
	case TAG_TICK:
		if tina.ctx_is_shutting_down() {
			// a permanent isolate that exits during shutdown is removed rather
			// than restarted, and it does not touch the restart budget
			return tina.ISOLATE_TRANSITION_DONE
		}

		if self.pending != 0 {
			// One probe in flight: a wedged shard would otherwise pile up
			// probers until the slots were gone. Shedding a tick is a load
			// decision, so it is logged and then forgotten.
			logf(.WARN, "still waiting, shedding this tick")
		} else {
			self.next_probe += 1
			start_probe(self, self.next_probe)
		}

		tina.ctx_register_timer(self.probe_ns, TAG_TICK)
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case TAG_PROBE_DUE:
		// the deadline names the probe it was armed for, so an answer that
		// arrived in the meantime makes this message stale and harmless
		if u32(message.correlation) != self.pending {
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		self.pending = 0
		self.timeouts += 1
		logf(.WARN, "timed out after %dns (slow or wedged is not the same as corrupt)",
			self.timeout_ns)
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case TAG_HEALTH:
		r := tina.payload_as(Probe_Result, message.user.payload[:])
		if r.probe_id != self.pending {
			// the probe this answer belongs to already timed out
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		self.pending = 0

		if !r.connected || !r.parsed || r.status != 200 {
			// a transport fault: the service is unreachable or confused, which
			// proves nothing about whether its state is impossible. Record it,
			// keep serving, let the operator decide.
			self.transport += 1
			self.consecutive += 1
			logf(.WARN, "probe %d faulted: connected=%v status=%d parsed=%v (%d in a row)",
				r.probe_id, r.connected, r.status, r.parsed, self.consecutive)
			return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
		}
		self.consecutive = 0

		// Both invariants are checkable from a single response, so a restarted
		// Sentinel with an empty ledger finds the rot on its very first probe -
		// which is what makes the restart budget run out.
		if r.seq > r.served {
			logf(.ERROR, "impossible ledger: seq=%d exceeds served=%d -> crash", r.seq, r.served)
			return tina.transition_to_crash(.Contract_Violation)
		}
		if r.served < self.served {
			logf(.ERROR, "ledger went backwards: served=%d was %d -> crash", r.served, self.served)
			return tina.transition_to_crash(.Contract_Violation)
		}

		self.served = r.served
		self.seq = r.seq
		self.ok += 1
		if self.ok%8 == 1 {
			logf(.INFO, "healthy: served=%d seq=%d ok=%d timeouts=%d faults=%d",
				r.served, r.seq, self.ok, self.timeouts, self.transport)
		}
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE

	case:
		return tina.ISOLATE_TRANSITION_WAIT_MESSAGE
	}
}

start_probe :: proc(self: ^SentinelIsolate, probe_id: u32) {
	job := Probe_Job{
		sentinel = tina.ctx_self_handle(),
		probe_id = probe_id,
		ip       = self.target,
		port     = self.port,
	}

	args, size := tina.init_args_of(&job)
	spec := tina.Spawn_Spec{
		type_id      = PROBER_TYPE,
		group_id     = tina.ctx_supervision_group_id(),
		restart_type = .temporary, // one shot: never restarted, slot freed on exit
		args_payload = args,
		args_size    = size,
	}
	if _, is_handle := tina.ctx_spawn(spec).(tina.Isolate_Handle); !is_handle {
		logf(.WARN, "no prober slot for probe %d", probe_id)
		return
	}
	self.pending = probe_id

	// the deadline carries the probe id, which is how a late answer and a stale
	// deadline cancel each other out without any shared state
	tina.ctx_register_timer_with_correlation(self.timeout_ns, TAG_PROBE_DUE, tina.Correlation_Id(probe_id))
}

logf :: proc(level: tina.Log_Level, fmt_str: string, args: ..any) {
	buf: [128]u8
	msg := fmt.bprintf(buf[:], fmt_str, ..args)
	tina.ctx_log(level, LOG_DEMO, transmute([]u8)msg)
}

// ============================================================================
// the two lines of HTTP parsing a probe needs
// ============================================================================

same_ignore_case :: proc(a: []u8, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(b); i += 1 {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x += 32
		}
		if 'A' <= y && y <= 'Z' {
			y += 32
		}
		if x != y {
			return false
		}
	}
	return true
}

// header_value finds `name` in a raw HTTP header block. Header names are
// case-insensitive and only count at the start of a line.
header_value :: proc(response: []u8, name: string) -> (string, bool) {
	for i := 0; i + len(name) < len(response); i += 1 {
		if i != 0 && response[i-1] != '\n' {
			continue
		}
		if !same_ignore_case(response[i:i+len(name)], name) || response[i+len(name)] != ':' {
			continue
		}
		value := response[i+len(name)+1:]
		end := 0
		for end < len(value) && value[end] != '\r' && value[end] != '\n' {
			end += 1
		}
		return strings.trim_left_space(string(value[:end])), true
	}
	return "", false
}

parse_health :: proc(r: ^Probe_Result, response: []u8) {
	if len(response) >= 12 && same_ignore_case(response[0:5], "HTTP/") {
		if code, ok := strconv.parse_u64(string(response[9:12])); ok {
			r.status = u16(code)
		}
	}

	served, has_served := header_value(response, "X-Opus-Served")
	seq, has_seq := header_value(response, "X-Opus-Seq")
	if !has_served || !has_seq {
		return
	}
	a, ok_a := strconv.parse_u64(served)
	b, ok_b := strconv.parse_u64(seq)
	if !ok_a || !ok_b {
		return
	}
	r.served = a
	r.seq = b
	r.parsed = true
}

// ============================================================================
// pre-flight, layer 2: nothing listens until the port is really ours
// ============================================================================

Config :: struct {
	ip:   net.IP4_Address,
	port: u16,
}

reject :: proc(why: string) {
	fmt.eprintln(why)
	fmt.eprintln("refusing to start - nothing is listening and no supervisor was built")
}

preflight :: proc(address: string, out: ^Config) -> bool {
	ep, ok := net.parse_endpoint(address)
	if !ok {
		reject(fmt.aprintf("preflight: listen address %q does not parse", address))
		return false
	}
	if net.family_from_endpoint(ep) != .IP4 {
		// the prober builds a sockaddr_in; an IPv6 service would need one for
		// that family too, and guessing is not what a pre-flight is for
		reject("preflight: only IPv4 endpoints can be supervised here")
		return false
	}
	ip, is_ip4 := ep.address.(net.IP4_Address)
	if !is_ip4 {
		reject("preflight: the address is not IPv4")
		return false
	}
	if ep.port == 0 {
		// the kernel would pick the port after the supervisor was built, so the
		// address it probes would be a guess
		reject("preflight: port 0 is not allowed - the supervisor must know where to probe")
		return false
	}

	// binding to every interface is fine, but there is no such thing as
	// connecting to 0.0.0.0: the probe goes to loopback instead
	if ip == (net.IP4_Address{}) {
		ip = net.IP4_Loopback
	}
	out.ip = ip
	out.port = u16(ep.port)

	// Prove the endpoint is bindable while there is no thread and no shard to
	// undo. The probe socket is closed and the acceptor binds the same address
	// for real, which reopens the race for microseconds: the startup gate in
	// main turns that into an exit rather than a supervised lie.
	sock, err := net.listen_tcp(ep, 512)
	if err != nil {
		reject(fmt.aprintf("preflight: cannot bind %s: %v", address, err))
		return false
	}
	bound, berr := net.bound_endpoint(sock)
	net.close(sock)
	if berr != nil {
		reject(fmt.aprintf("preflight: cannot read the bound endpoint: %v", berr))
		return false
	}
	if bound.port != ep.port {
		reject(fmt.aprintf("preflight: asked for port %d and got %d", ep.port, bound.port))
		return false
	}
	return true
}

// ============================================================================
// the supervision tree
// ============================================================================

// A SystemSpec keeps slices of its tables rather than copies, so the tables
// have to outlive whatever built the spec: these are globals, not locals.
g_types:    [2]tina.IsolateTypeDescriptor
g_children: [1]tina.Child_Spec
g_shards:   [1]tina.ShardSpec

configure_spec :: proc(a: Sentinel_Args) -> tina.SystemSpec {
	g_types[0] = tina.IsolateTypeDescriptor{
		id                = SENTINEL_TYPE,
		slot_count        = 1,
		stride            = size_of(SentinelIsolate),
		soa_metadata_size = size_of(tina.Isolate_Metadata),
		mailbox_capacity  = 32,
		init_handler      = sentinel_init,
		handler_fn        = sentinel_handler,
	}
	g_types[1] = tina.IsolateTypeDescriptor{
		id                = PROBER_TYPE,
		slot_count        = 4,
		stride            = size_of(ProberIsolate),
		soa_metadata_size = size_of(tina.Isolate_Metadata),
		mailbox_capacity  = 4,
		init_handler      = prober_init,
		handler_fn        = prober_handler,
	}

	local := a
	args, size := tina.init_args_of(&local)
	g_children[0] = tina.Static_Child_Spec{
		type_id      = SENTINEL_TYPE,
		restart_type = .permanent,
		args_payload = args,
		args_size    = size,
	}

	g_shards[0] = tina.ShardSpec{
		shard_id = 0,
		root_group = tina.Group_Spec{
			// One_For_One: the Sentinel crashing restarts the Sentinel. The
			// probers come and go on their own, and none of it reaches opus.
			strategy                = .One_For_One,
			restart_count_max       = RESTART_MAX,
			window_duration_ticks   = RESTART_WINDOW_TICKS,
			children                = g_children[:],
			child_count_dynamic_max = 4, // the probers
		},
		target_core = -1,
	}

	return tina.SystemSpec{
		// The budget is spent: quarantine the shard and let the service keep
		// answering traffic. Aborting would trade availability for a clean log,
		// and surviving the supervisor is the point of the example.
		quarantine_policy = .Quarantine,
		watchdog = tina.Watchdog_Config{
			check_interval_ms       = 500,
			shard_restart_window_ms = 30_000,
			shard_restart_max       = 2,
			phase_2_threshold       = 2,
		},
		shard_count               = 1,
		types                     = g_types[:],
		shard_specs               = g_shards[:],
		timer_resolution_ns       = 1_000_000, // one tick per millisecond
		pool_slot_count           = 4096,
		timer_entry_count         = 1024,
		log_ring_size             = 65536,
		default_ring_size         = 16,
		scratch_memory_size       = 65536,
		fd_table_slot_count       = 16,
		fd_entry_size             = size_of(tina.FD_Entry),
		supervision_groups_max    = 4,
		reactor_buffer_slot_count = 16,
		reactor_buffer_slot_size  = 4096,
		staging_slot_count        = 16,
		staging_slot_size         = 1024,
		transfer_slot_count       = 16,
		transfer_slot_size        = 4096,
		shutdown_timeout_ms       = 3_000,
	}
}

main :: proc() {
	address := DEFAULT_ADDRESS
	if len(os.args) > 1 {
		address = os.args[1]
	}

	cfg: Config
	if !preflight(address, &cfg) {
		os.exit(1)
	}

	spec := configure_spec(Sentinel_Args{
		ip         = cfg.ip,
		port       = cfg.port,
		probe_ns   = PROBE_MS * 1_000_000,
		timeout_ns = PROBE_TIMEOUT_MS * 1_000_000,
	})

	// the acceptor: an ordinary opus server on a thread tina knows nothing
	// about, which is exactly why a quarantined shard cannot hurt it
	done := false
	srv := new(web.Server)
	if !web.server_init(srv, address) {
		reject(fmt.aprintf("cannot initialize the server for %s", address))
		os.exit(1)
	}
	srv.handler = handler
	srv.user_ptr = new(Service_State)

	args := Service_Args{srv = srv, done = &done}
	th := thread.create(service_thread)
	if th == nil {
		reject("the service thread could not be created")
		os.exit(1)
	}
	th.data = &args
	thread.start(th)

	// The supervisor starts last: watching something that never came up is how
	// you end up with a restarting isolate in front of a service that never
	// existed.
	for i := 0; i < 2000 && !intrinsics.volatile_load(&srv.listening); i += 1 {
		time.sleep(time.Millisecond)
	}
	if !intrinsics.volatile_load(&srv.listening) {
		reject(fmt.aprintf("startup: nothing is listening on %s", address))
		intrinsics.volatile_store(&done, true)
		thread.join(th)
		thread.destroy(th)
		web.server_destroy(srv)
		os.exit(1)
	}

	fmt.println("-------------------------------------------------------------")
	fmt.printf("opus + tina | http://%d.%d.%d.%d:%d | pid %d\n",
		cfg.ip[0], cfg.ip[1], cfg.ip[2], cfg.ip[3], srv.bound_port, os.get_pid())
	fmt.println("  GET  /health      the page the Sentinel probes")
	fmt.println("  POST /admin/rot   publish seq > served -> crash -> quarantine")
	fmt.println("  POST /admin/heal  restore the invariant")
	fmt.printf("  kill -USR2 %d      revive the quarantined shard\n", os.get_pid())
	fmt.printf("  Ctrl-C             drain shards, then connections (probe %dms, budget %d)\n",
		PROBE_MS, RESTART_MAX)
	fmt.println("-------------------------------------------------------------")

	// blocks until SIGINT/SIGTERM: the main thread is tina's watchdog
	tina.tina_start(&spec)

	// the shards are down; now stop taking traffic and let clients drain
	intrinsics.volatile_store(&done, true)
	thread.join(th)
	thread.destroy(th)
	fmt.printf("drained: %v request(s) served, %v connection(s) opened\n",
		srv.stats.requests, srv.stats.conns_opened)
	web.server_destroy(srv)
}
