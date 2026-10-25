package web

import "core:nbio"
import "core:net"
import "core:time"

/*
Upstream health and load balancing for the reverse proxy.

Before this file existed the pool had exactly one recovery path: a request
picked a dead upstream, failed, and was retried on a fresh connection -
which is fine for a single flaky socket and useless when a backend is
actually down, because every request still paid a connect timeout before
falling through. Two additions fix that:

  - Passive health: consecutive failures eject an upstream from the rotation
    for a while (5 s, doubling per ejection, capped at 60 s). The ejection is
    never permanent: once the window passes the upstream goes half-open and a
    single request decides whether it comes back.
  - Active probing: while an upstream is ejected and nobody is requesting it,
    a cheap TCP connect (`proxy_health_poll`, driven from `Server.on_tick`)
    finds out the moment it is back instead of waiting for real traffic to
    discover it.

Selection itself is smooth weighted round-robin (nginx's algorithm), so an
upstream with `weight = 4` gets four times the requests of a `weight = 1`
peer *without* the bursts a naive "repeat the entry N times" scheme
produces.

Fail-open rule: when every upstream is ejected, the one whose window expires
soonest is used anyway. A proxy that answers 503 to everything because its
health bookkeeping says "all down" is worse than one that keeps trying - the
bookkeeping can be wrong, the request is real.
*/

Upstream_State :: enum u8 {
	Healthy,
	Ejected,
}

Upstream :: struct {
	endpoint: net.Endpoint,
	host:     string, // "host:port" for the Host header
	weight:   int,    // relative share of the traffic; 0 means 1

	state:          Upstream_State,
	failures:       int,       // consecutive failures since the last success
	successes:      int,       // consecutive successes since the ejection
	ejected_until:  time.Time, // healthy again from this instant on
	eject_count:    int,       // how many times in a row it was ejected
	next_probe:     time.Time,
	probing:        bool, // a probe connect is in flight
	current_weight: int,  // smooth weighted round-robin accumulator

	// counters, read them for a /stats handler or a dashboard
	requests:       u64,
	failures_total: u64,
	ejections:      u64,
}

/*
Health_Config tunes the circuit breaker. The zero value is not useful -
`proxy_init` installs PROXY_HEALTH_DEFAULT - and `max_failures = 0` disables
ejection entirely (the proxy then behaves exactly as it did before this file
existed: retry on a fresh connection and nothing else).
*/
Health_Config :: struct {
	max_failures:   int,           // consecutive failures before an ejection
	eject_for:      time.Duration, // first ejection window
	max_eject:      time.Duration, // cap for the doubling backoff
	probe:          bool,          // actively probe while ejected
	probe_interval: time.Duration, // between probe attempts
	probe_timeout:  time.Duration, // per probe connect
}

PROXY_HEALTH_DEFAULT :: Health_Config {
	max_failures   = 5,
	eject_for      = 5 * time.Second,
	max_eject      = 60 * time.Second,
	probe          = true,
	probe_interval = 2 * time.Second,
	probe_timeout  = 2 * time.Second,
}

// proxy_now is nbio's clock on the loop thread and the wall clock elsewhere
// (unit tests, a stats handler on another thread). Both are Unix-epoch based,
// so the comparisons below stay meaningful either way.
@(private)
proxy_now :: proc() -> time.Time {
	t := nbio.now()
	if t == {} {
		t = time.now()
	}
	return t
}

// proxy_upstream_weight is the configured weight, with 0 read as 1: an
// unset field must not mean "never picked".
proxy_upstream_weight :: proc(u: ^Upstream) -> int {
	return u.weight > 0 ? u.weight : 1
}

/*
proxy_upstream_usable reports whether the upstream may take a request now.
An ejected upstream becomes usable again the moment its window expires: the
next request through it is the half-open probe, and its outcome either
promotes it back to healthy or ejects it for twice as long.
*/
proxy_upstream_usable :: proc(u: ^Upstream, now: time.Time) -> bool {
	if u.state == .Healthy {
		return true
	}
	if u.ejected_until == {} {
		return true
	}
	return time.diff(u.ejected_until, now) >= 0
}

/*
proxy_note_failure records one failed attempt. The upstream is ejected once
`max_failures` consecutive attempts have failed; until then the request-level
retry keeps working on its own.
*/
proxy_note_failure :: proc(p: ^Proxy, index: int) {
	if index < 0 || index >= len(p.upstreams) {
		return
	}
	u := &p.upstreams[index]
	u.failures += 1
	u.failures_total += 1
	u.successes = 0
	if p.health.max_failures <= 0 || u.failures < p.health.max_failures {
		return
	}
	proxy_eject(p, index)
}

@(private)
proxy_eject :: proc(p: ^Proxy, index: int) {
	u := &p.upstreams[index]
	h := p.health
	window := h.eject_for
	if window <= 0 {
		window = PROXY_HEALTH_DEFAULT.eject_for
	}
	// exponential backoff, capped: a backend that fails repeatedly should
	// not be retried every five seconds forever
	for i in 0 ..< u.eject_count {
		window *= 2
		if h.max_eject > 0 && window >= h.max_eject {
			window = h.max_eject
			break
		}
	}
	if h.max_eject > 0 && window > h.max_eject {
		window = h.max_eject
	}
	now := proxy_now()
	u.state = .Ejected
	u.ejected_until = time.time_add(now, window)
	u.next_probe = time.time_add(now, h.probe_interval)
	u.eject_count += 1
	u.ejections += 1
	p.upstreams_ejected += 1
	// an ejected backend's idle sockets are dead weight: dropping them also
	// keeps the pool from handing out connections to a box that is down
	proxy_pool_close_upstream(p, index)
	log_info(
		"web: proxy: upstream %v ejected for %v after %v consecutive failure(s)",
		u.host,
		window,
		u.failures,
	)
}

/*
proxy_note_success records a completed round trip. A success always clears
the failure streak, and a success on an ejected upstream - the half-open
probe - brings it back into the rotation.
*/
proxy_note_success :: proc(p: ^Proxy, index: int) {
	if index < 0 || index >= len(p.upstreams) {
		return
	}
	u := &p.upstreams[index]
	u.failures = 0
	u.successes += 1
	if u.state == .Ejected {
		u.state = .Healthy
		u.ejected_until = {}
		u.eject_count = 0
		if p.upstreams_ejected > 0 {
			p.upstreams_ejected -= 1
		}
		log_info("web: proxy: upstream %v back in rotation", u.host)
	}
}

/*
proxy_next_upstream picks the upstream for the next request: smooth weighted
round-robin over the usable ones, or - when none is usable - the one that
recovers soonest (see the fail-open note at the top of this file).

Returns -1 only when the proxy has no upstreams at all.
*/
proxy_next_upstream :: proc(p: ^Proxy) -> int {
	n := len(p.upstreams)
	if n == 0 {
		return -1
	}
	now := proxy_now()

	best := -1
	total := 0
	for i in 0 ..< n {
		u := &p.upstreams[i]
		if !proxy_upstream_usable(u, now) {
			continue
		}
		w := proxy_upstream_weight(u)
		u.current_weight += w
		total += w
		if best < 0 || u.current_weight > p.upstreams[best].current_weight {
			best = i
		}
	}
	if best >= 0 {
		p.upstreams[best].current_weight -= total
		p.upstreams[best].requests += 1
		return best
	}

	// everything is ejected: try whichever comes back first rather than
	// answering 503 on the strength of our own bookkeeping
	soonest := 0
	for i in 1 ..< n {
		u := &p.upstreams[i]
		s := &p.upstreams[soonest]
		// time.diff(a, b) is b - a: a positive value here means u's window
		// ends later than the current best, so the best stays
		if s.ejected_until != {} && time.diff(u.ejected_until, s.ejected_until) > 0 {
			soonest = i
		}
	}
	p.upstreams[soonest].requests += 1
	return soonest
}

/*
proxy_set_weight changes an upstream's share of the traffic. Weights are
relative and need no renormalisation: {4, 1} and {8, 2} behave the same.
Returns false for an out-of-range index or a non-positive weight (use
`proxy_eject_all`-style operations for taking an upstream out deliberately).
*/
proxy_set_weight :: proc(p: ^Proxy, index, weight: int) -> bool {
	if index < 0 || index >= len(p.upstreams) || weight <= 0 {
		return false
	}
	p.upstreams[index].weight = weight
	return true
}

/*
proxy_health_poll probes ejected upstreams and is meant to run on the event
loop thread from `Server.on_tick`:

	srv.on_tick = proc(s: ^web.Server) {
		web.proxy_health_poll(cast(^web.Proxy) s.user_ptr)
	}

Each probe is a plain TCP connect with `probe_timeout`; success is enough to
put the upstream back (the socket is closed again immediately, no HTTP is
spoken). A backend that accepts connections but cannot serve would still be
caught by the passive path on the next real request.
*/
proxy_health_poll :: proc(p: ^Proxy) {
	h := p.health
	if !h.probe || len(p.upstreams) == 0 {
		return
	}
	now := proxy_now()
	for i in 0 ..< len(p.upstreams) {
		u := &p.upstreams[i]
		if u.state != .Ejected || u.probing {
			continue
		}
		if u.next_probe != {} && time.diff(u.next_probe, now) < 0 {
			continue
		}
		u.probing = true
		u.next_probe = time.time_add(now, h.probe_interval)
		pr := new(Proxy_Probe, p.allocator)
		pr.proxy = p
		pr.upstream = i
		nbio.dial_poly(u.endpoint, pr, on_health_probe, timeout = h.probe_timeout)
	}
}

@(private)
Proxy_Probe :: struct {
	proxy:    ^Proxy,
	upstream: int,
}

@(private)
on_health_probe :: proc(op: ^nbio.Operation, pr: ^Proxy_Probe) {
	p := pr.proxy
	index := pr.upstream
	u := &p.upstreams[index]
	u.probing = false
	p.probes += 1
	if op.dial.err != nil {
		p.probe_failures += 1
		// still down: eject again, which doubles the window
		proxy_eject(p, index)
	} else {
		nbio.close(op.dial.socket)
		proxy_note_success(p, index)
	}
	free(pr, p.allocator)
}

// proxy_upstream_state reports the health of one upstream, for a stats
// handler that wants to render it without reaching into the struct.
proxy_upstream_state :: proc(p: ^Proxy, index: int) -> (state: Upstream_State, failures: int, until: time.Time) {
	if index < 0 || index >= len(p.upstreams) {
		return .Healthy, 0, {}
	}
	u := &p.upstreams[index]
	return u.state, u.failures, u.ejected_until
}
