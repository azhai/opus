package main

/*
Benchmarks and stress probes for the web package.

	odin run bench -- 18099

Three parts, chosen by the second argument:

  micro  - the per-request functions, called directly with no socket, so the
           numbers describe the algorithm rather than the syscalls. The
           request-side benchmarks allocate from a bump allocator that is
           rewound per iteration, which is how the connection arena behaves
           between keep-alive requests: real malloc traffic, but no free.
           Each benchmark runs five rounds and keeps the fastest: one round on
           a machine with two core types and other work on it is a coin flip.
  load   - one real server on one loop thread driven by a pipelining client.
           Pipelining removes the effect of RTT, so what is left is the cost
           of the request path itself: RPS = one core's request budget.
  multi  - N acceptors plus a poll-driven client, to see how throughput scales
           with cores and how the connections split. `serve` and `client` run
           those halves as separate processes so each side's CPU time is
           attributable; see multi.odin.
*/

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "../web"

// ---------------------------------------------------------------------------
// measurement primitives
// ---------------------------------------------------------------------------

Bench :: struct {
	name: string,
	ops:  int,
	ns:   i64,
	// rounds is how many timed rounds were run; the allocator counters in the
	// benchmark context accumulate over all of them, so per-op figures are
	// divided by this and by ops.
	rounds: int,
}

/*
bench_run times `body` over several rounds and keeps the fastest.

One round is not a measurement on a machine with two kinds of core and other
work on it: the same parse benchmark read 211 ns and 253 ns in back-to-back
runs, purely from where the thread happened to be scheduled. The minimum is
the round that came closest to the code's own cost, which is the number worth
optimising and the only one that reproduces.
*/
bench_run :: proc(
	b: ^Bench,
	body: proc(ctx: rawptr),
	ctx: rawptr,
	min_ns := 100 * time.Millisecond,
	rounds := 5,
) {
	n := 1
	body(ctx) // warm up: first-call table builds must not be amortised in
	// grow the iteration count until one round fills the window
	for {
		start := time.tick_now()
		for _ in 0 ..< n {
			body(ctx)
		}
		elapsed := time.tick_since(start)
		if elapsed >= min_ns || n > 1 << 24 {
			break
		}
		if elapsed <= 0 {
			n *= 8
		} else {
			grow := int(min_ns / elapsed) + 1
			n *= clamp(grow, 2, 64)
		}
	}

	best := i64(max(i64))
	for _ in 0 ..< rounds {
		start := time.tick_now()
		for _ in 0 ..< n {
			body(ctx)
		}
		e := i64(time.tick_since(start))
		if e < best {
			best = e
		}
	}
	b.ops = n
	b.ns = best
	b.rounds = rounds
}

bench_report :: proc(b: Bench, allocs: u64 = 0, bytes: u64 = 0) {
	if b.ops == 0 {
		return
	}
	ns_per := f64(b.ns) / f64(b.ops)
	rounds := max(b.rounds, 1)
	if allocs > 0 {
		fmt.printf("%-46s %8.1f ns/op  %5.1f alloc/op  %7.0f B/op\n",
			b.name,
			ns_per,
			f64(allocs) / f64(b.ops * rounds),
			f64(bytes) / f64(b.ops * rounds))
	} else {
		fmt.printf("%-46s %8.1f ns/op  %12.0f /s\n", b.name, ns_per, 1e9 / ns_per)
	}
}

// ---------------------------------------------------------------------------
// bump allocator: an arena with a rewind, so a benchmark pays for allocations
// the way a request does (malloc on first touch, nothing on reset)
// ---------------------------------------------------------------------------

Bump :: struct {
	mem:    []byte,
	cur:    int,
	allocs: u64,
	bytes:  u64,
}

bump :: proc(b: ^Bump, size: int) {
	b.mem = make([]byte, size, context.allocator)
}

bump_reset :: proc(b: ^Bump) {
	b.cur = 0
}

bump_allocator :: proc(b: ^Bump) -> mem.Allocator {
	return mem.Allocator{procedure = bump_proc, data = b}
}

bump_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	b := cast(^Bump) allocator_data
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		off := (b.cur + alignment - 1) & ~(alignment - 1)
		if off + size > len(b.mem) {
			return nil, .Out_Of_Memory
		}
		b.cur = off + size
		b.allocs += 1
		b.bytes += u64(size)
		return b.mem[off:off + size], nil
	case .Free:
		return nil, nil
	case .Free_All:
		b.cur = 0
		return nil, nil
	case .Resize, .Resize_Non_Zeroed:
		return nil, .Mode_Not_Implemented // fall back to alloc + copy
	case .Query_Info, .Query_Features:
		return nil, nil
	}
	return nil, .Mode_Not_Implemented
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

REQ_HEAD :: "GET /api/users/42?verbose=1&fields=id,name,email HTTP/1.1\r\n" +
	"Host: example.com\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64)\r\n" +
	"Accept: application/json, text/plain, */*\r\nAccept-Encoding: gzip, deflate\r\n" +
	"Accept-Language: en-US,en;q=0.9\r\nCookie: token=abc123; theme=dark\r\n" +
	"Referer: https://example.com/dashboard\r\nConnection: keep-alive\r\n\r\n"

// json_payload builds a realistic API response body: n records of JSON.
json_payload :: proc(n: int) -> []byte {
	b: strings.Builder
	strings.builder_init(&b, context.allocator)
	strings.write_string(&b, "[")
	for i := 0; i < n; i += 1 {
		if i > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, `{{"id":%d,"name":"user%d","email":"user%d@example.com","active":true}}`, i, i, i)
	}
	strings.write_string(&b, "]")
	return transmute([]byte)strings.to_string(b)
}

main :: proc() {
	port := 18099
	mode := "all"
	if len(os.args) > 1 {
		if p, ok := strconv.parse_int(os.args[1]); ok {
			port = p
		}
	}
	if len(os.args) > 2 {
		mode = os.args[2]
	}
	if mode == "multi" {
		multi_scale(port)
		return
	}
	if mode == "micro" {
		micro()
		return
	}
	if mode == "client" {
		clients, conns, seconds := 3, 4, 10
		if len(os.args) > 3 {
			if v, ok := strconv.parse_int(os.args[3]); ok {
				clients = v
			}
		}
		if len(os.args) > 4 {
			if v, ok := strconv.parse_int(os.args[4]); ok {
				conns = v
			}
		}
		if len(os.args) > 5 {
			if v, ok := strconv.parse_int(os.args[5]); ok {
				seconds = v
			}
		}
		multi_load(port, clients, conns, seconds)
		return
	}
	if mode == "serve" {
		acceptors, seconds := 4, 10
		if len(os.args) > 3 {
			if v, ok := strconv.parse_int(os.args[3]); ok {
				acceptors = v
			}
		}
		if len(os.args) > 4 {
			if v, ok := strconv.parse_int(os.args[4]); ok {
				seconds = v
			}
		}
		multi_serve(port, acceptors, seconds)
		return
	}
	if mode == "load" {
		load(port)
		return
	}
	micro()
	load(port)
}

// ---------------------------------------------------------------------------
// micro
// ---------------------------------------------------------------------------

Head_Ctx :: struct {
	head:  Bump,
	alloc: mem.Allocator,
	req:   web.Request,
	n:     int,
}

head_body :: proc(ctx: rawptr) {
	c := cast(^Head_Ctx) ctx
	bump_reset(&c.head)
	c.req = {}
	web.parse_request(&c.req, REQ_HEAD, c.alloc)
	c.n += len(c.req.headers)
}

Router_Ctx :: struct {
	router: ^web.Router,
	req:    web.Request,
	bump:   Bump,
	alloc:  mem.Allocator,
	hits:   int,
}

router_body :: proc(ctx: rawptr) {
	c := cast(^Router_Ctx) ctx
	bump_reset(&c.bump)
	r, _ := web.router_match(c.router, &c.req, c.alloc)
	if r != nil {
		c.hits += 1
	}
}

Response_Ctx :: struct {
	res:   web.Response,
	out:   web.Buf,
	bump:  Bump,
	alloc: mem.Allocator,
	body:  []byte,
}

response_body :: proc(ctx: rawptr) {
	c := cast(^Response_Ctx) ctx
	bump_reset(&c.bump)
	web.buf_reset(&c.out)
	c.res = {}
	web.response_init(&c.res, nil, c.alloc)
	web.response_set_header(&c.res, "Content-Type", "application/json")
	web.response_set_header(&c.res, "X-Request-Id", "01HQ8Z4W7Y6V5U4T3S2R1Q0P9N")
	web.response_write(&c.res, c.body)
	web.response_build(&c.res, &c.out, c.alloc)
}

Compress_Ctx :: struct {
	src:   []byte,
	bump:  Bump,
	alloc: mem.Allocator,
	out:   int,
}

compress_body :: proc(ctx: rawptr) {
	c := cast(^Compress_Ctx) ctx
	bump_reset(&c.bump)
	out := web.gzip_compress(c.src, c.alloc)
	c.out += len(out)
}

Multipart_Ctx :: struct {
	body:  []byte,
	bump:  Bump,
	alloc: mem.Allocator,
	n:     int,
}

multipart_body_of :: proc(payload_len: int, alloc: mem.Allocator) -> []byte {
	b: web.Buf
	web.buf_init(&b, alloc)
	web.buf_append_string(&b, "--XyZ\r\nContent-Disposition: form-data; name=\"note\"\r\n\r\nhello world\r\n")
	web.buf_append_string(&b, "--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"big.bin\"\r\n")
	web.buf_append_string(&b, "Content-Type: application/octet-stream\r\n\r\n")
	data := make([]byte, payload_len, alloc)
	for i in 0 ..< payload_len {
		data[i] = byte((i * 37 + 11) & 0xff)
	}
	web.buf_append(&b, data)
	web.buf_append_string(&b, "\r\n--XyZ--\r\n")
	return web.buf_slice(&b)
}

mp_count :: proc(ud: rawptr, part: ^web.Stream_Part, chunk: []byte) -> bool {
	c := cast(^Multipart_Ctx) ud
	c.n += len(chunk)
	return true
}

multipart_body :: proc(ctx: rawptr) {
	c := cast(^Multipart_Ctx) ctx
	bump_reset(&c.bump)
	c.n = 0
	ms: web.Multipart_Stream
	if !web.multipart_stream_init(&ms, "XyZ", c.alloc, {}, {on_data = mp_count, ud = c}) {
		return
	}
	defer web.multipart_stream_destroy(&ms)
	web.multipart_stream_feed(&ms, c.body)
	web.multipart_stream_finish(&ms)
}

micro :: proc() {
	fmt.println("== micro ==")

	hc := Head_Ctx{}
	bump(&hc.head, 256 << 10)
	hc.alloc = bump_allocator(&hc.head)
	b := Bench{name = "parse_request (9 headers, 240 B)"}
	bench_run(&b, head_body, &hc)
	bench_report(b, hc.head.allocs, hc.head.bytes)

	micro_router()
	micro_response()
	micro_compress()
	micro_multipart()
	fmt.println()
}

micro_router :: proc() {
	r := new(web.Router, context.allocator)
	web.router_init(r)
	// a table the size of a real API: 120 static routes, 8 parameterised
	for i := 0; i < 120; i += 1 {
		path := fmt.aprintf("/api/resource%v/status", i, allocator = context.allocator)
		web.router_get(r, path, proc(req: ^web.Request, res: ^web.Response) {})
	}
	for i := 0; i < 8; i += 1 {
		path := fmt.aprintf("/api/v%v/items/:id", i, allocator = context.allocator)
		web.router_get(r, path, proc(req: ^web.Request, res: ^web.Response) {})
	}
	web.router_get(r, "/static/*", proc(req: ^web.Request, res: ^web.Response) {})

	cb := Router_Ctx {
		router = r,
	}
	bump(&cb.bump, 64 << 10)
	cb.alloc = bump_allocator(&cb.bump)

	scenarios := []struct {
		name: string,
		req:  web.Request,
	} {
		{"router_match: hit, 1st of 120 static", {method = .Get, path = "/api/resource0/status"}},
		{"router_match: hit, 120th of 120 static", {method = .Get, path = "/api/resource119/status"}},
		{"router_match: :param route", {method = .Get, path = "/api/v7/items/12345"}},
		{"router_match: miss (404, two passes)", {method = .Get, path = "/nope/at/all"}},
		{"router_match: HEAD -> GET route", {method = .Head, path = "/api/resource119/status"}},
	}
	for s in scenarios {
		cb.req = s.req
		cb.bump.allocs = 0
		cb.bump.bytes = 0
		b := Bench{name = s.name}
		bench_run(&b, router_body, &cb, 100 * time.Millisecond)
		bench_report(b, cb.bump.allocs, cb.bump.bytes)
	}
}

micro_response :: proc() {
	c := Response_Ctx {
		body = json_payload(40), // ~4 KiB
	}
	web.buf_init(&c.out, context.allocator)
	bump(&c.bump, 256 << 10)
	c.alloc = bump_allocator(&c.bump)
	b := Bench{name = "response_build (4 KiB JSON + Date)"}
	bench_run(&b, response_body, &c, 100 * time.Millisecond)
	bench_report(b, c.bump.allocs, c.bump.bytes)
}

micro_compress :: proc() {
	src := json_payload(640) // ~64 KiB of compressible JSON
	c := Compress_Ctx {
		src = src,
	}
	bump(&c.bump, 2 << 20)
	c.alloc = bump_allocator(&c.bump)
	b := Bench{name = "gzip_compress (64 KiB JSON)"}
	bench_run(&b, compress_body, &c, 300 * time.Millisecond)
	bench_report(b, c.bump.allocs, c.bump.bytes)
	gz := web.gzip_compress(src, c.alloc)
	fmt.printf("    ratio %v -> %v bytes (%.1f%%), %.1f MiB/s\n",
		len(src), len(gz), 100 * f64(len(gz)) / f64(len(src)),
		f64(len(src)) * f64(b.ops) / f64(b.ns) * 1e9 / (1 << 20))

	text := make([]byte, 256 << 10, context.allocator)
	for i in 0 ..< len(text) {
		text[i] = byte((i * 31 + i / 7) & 0xff)
	}
	c.src = text
	b2 := Bench{name = "gzip_compress (256 KiB binary-ish)"}
	bench_run(&b2, compress_body, &c, 300 * time.Millisecond)
	bench_report(b2, c.bump.allocs, c.bump.bytes)
}

micro_multipart :: proc() {
	c := Multipart_Ctx {
		body = multipart_body_of(1 << 20, context.allocator),
	}
	bump(&c.bump, 8 << 20)
	c.alloc = bump_allocator(&c.bump)
	b := Bench{name = "multipart parse (1 MiB part)"}
	bench_run(&b, multipart_body, &c, 200 * time.Millisecond)
	bench_report(b, c.bump.allocs, c.bump.bytes)
	fmt.printf("    %.0f MiB/s, sink saw %v bytes\n",
		f64(len(c.body)) * f64(b.ops) / f64(b.ns) * 1e9 / (1 << 20), c.n / b.ops)
}
