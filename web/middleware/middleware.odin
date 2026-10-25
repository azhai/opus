package middleware

import ".."
import "core:mem"
import "core:sync"
import "core:time"


/*
Common middleware, in the shape the router already supports: a
`Middleware_Proc` registered with `router_use`, continuing the chain with
`router_next(r, idx + 1, final, req, res)`.

Two conventions matter here:

  - Ordering. `router_use` appends, and the chain runs in registration
    order. Register cross-cutting concerns first (request id, logger,
    security headers), routing/auth concerns later, so a rejected request
    still gets an id and a log line.

  - Configuration. Odin has no closures, so configured middleware reads its
    settings from `Middleware.ud` (the second argument of `router_use`),
    cast to the matching `*_Config`. `ud == nil` means "defaults". The
    config must outlive the server, so keep it in a package-level variable
    or a heap allocation - never a stack temporary.

There is deliberately no recover middleware: Odin has no exceptions, so a
panic (assertion failure, bounds error) terminates the process and cannot be
caught. Run the server under a supervisor (gorch, systemd, procd) instead.
*/

// DEFAULT_BODY_LIMIT is the fallback for middleware_body_limit.
DEFAULT_BODY_LIMIT :: 1 << 20 // 1 MiB

// ---------------------------------------------------------------------------
// Request ID
// ---------------------------------------------------------------------------

// REQUEST_ID_HEADER carries the request identifier both ways: an inbound
// value is reused (so a front proxy's id survives), otherwise one is
// generated. The value is also stored on the request (`request_id`).
REQUEST_ID_HEADER :: "X-Request-Id"

// middleware_request_id installs a request id: reuse the inbound
// X-Request-Id when present, else generate one, store it on the request and
// echo it back in the response.
middleware_request_id :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	id, ok := web.request_header(req, REQUEST_ID_HEADER)
	if !ok || len(id) == 0 {
		id = new_request_id(web.request_allocator(req))
	}
	req.id = id
	web.response_set_header(res, REQUEST_ID_HEADER, id)
	web.router_next(r, idx + 1, final, req, res)
}

@(private = "file")
request_id_seq: u64

// new_request_id builds a 24-character id: 16 hex digits of UTC nanoseconds
// followed by 8 hex digits of a process-wide counter. The time half keeps
// ids roughly sortable across restarts, the counter keeps them unique; no
// randomness source is involved.
new_request_id :: proc(allocator: mem.Allocator) -> string {
	seq := sync.atomic_add(&request_id_seq, u64(1))
	ns := u64(time.time_to_unix_nano(time.now()))
	out := make([]byte, 24, allocator)
	write_hex_padded(out[0:16], ns)
	write_hex_padded(out[16:24], seq)
	return string(out)
}

@(private = "file")
write_hex_padded :: proc(dst: []byte, value: u64) {
	digits := "0123456789abcdef"
	v := value
	for i := len(dst) - 1; i >= 0; i -= 1 {
		dst[i] = digits[v & 0xf]
		v >>= 4
	}
}

// ---------------------------------------------------------------------------
// Access log
// ---------------------------------------------------------------------------

// middleware_logger writes one line per request after the handler returns:
// status, method, path, body size and duration. `request_id`,
// `request_client_ip` and `request_principal` are included when available,
// so registering middleware_request_id first makes the log lines
// correlatable and an auth middleware further down the chain labels who
// made the request.
middleware_logger :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	start := time.now()
	web.router_next(r, idx + 1, final, req, res)
	elapsed := time.duration_microseconds(time.since(start)) / 1000
	web.log_info(
		"[web] %d %s %s %dB %.3fms id=%s ip=%s user=%s",
		int(res.status),
		web.method_string(req.method),
		req.path,
		web.response_body_size(res),
		elapsed,
		req.id,
		web.request_client_ip(req),
		req.principal,
	)
}

// ---------------------------------------------------------------------------
// Security headers
// ---------------------------------------------------------------------------

/*
Secure_Headers_Config lists the headers middleware_secure_headers sets.

A nil config applies the defaults below. A non-nil config sets exactly the
non-empty fields, which is how a caller opts out of one header while keeping
the rest.

	X-Content-Type-Options: nosniff
	X-Frame-Options:        SAMEORIGIN
	Referrer-Policy:        no-referrer
*/
Secure_Headers_Config :: struct {
	content_type_options:    string,
	frame_options:           string,
	referrer_policy:         string,
	content_security_policy: string,
	strict_transport_security: string, // e.g. "max-age=31536000"
}

middleware_secure_headers :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Secure_Headers_Config) m.ud
	if cfg == nil {
		web.response_set_header(res, "X-Content-Type-Options", "nosniff")
		web.response_set_header(res, "X-Frame-Options", "SAMEORIGIN")
		web.response_set_header(res, "Referrer-Policy", "no-referrer")
	} else {
		if len(cfg.content_type_options) > 0 {
			web.response_set_header(res, "X-Content-Type-Options", cfg.content_type_options)
		}
		if len(cfg.frame_options) > 0 {
			web.response_set_header(res, "X-Frame-Options", cfg.frame_options)
		}
		if len(cfg.referrer_policy) > 0 {
			web.response_set_header(res, "Referrer-Policy", cfg.referrer_policy)
		}
		if len(cfg.content_security_policy) > 0 {
			web.response_set_header(res, "Content-Security-Policy", cfg.content_security_policy)
		}
		if len(cfg.strict_transport_security) > 0 {
			web.response_set_header(res, "Strict-Transport-Security", cfg.strict_transport_security)
		}
	}
	web.router_next(r, idx + 1, final, req, res)
}

// middleware_no_cache marks the response as non-storable. Register it on the
// routes that must never be cached (authenticated pages, JSON APIs feeding a
// UI); static assets should not carry it.
middleware_no_cache :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Cache-Control", "no-store, no-cache, must-revalidate")
	web.response_set_header(res, "Pragma", "no-cache")
	web.response_set_header(res, "Expires", "0")
	web.router_next(r, idx + 1, final, req, res)
}

// ---------------------------------------------------------------------------
// CORS
// ---------------------------------------------------------------------------

/*
CORS_Config configures middleware_cors. A nil config means "allow any
origin, no credentials, GET/POST/PUT/PATCH/DELETE/OPTIONS", which is the
right default for a public read-only API and the wrong one for anything
session-based.

`allow_headers` empty means "mirror Access-Control-Request-Headers", the
permissive behaviour browsers expect from a generic API.
*/
CORS_Config :: struct {
	origins:           []string, // exact origins, or {"*"} / empty for any
	allow_methods:     string,
	allow_headers:     string,
	expose_headers:    string,
	max_age_secs:      int,
	allow_credentials: bool,
}

middleware_cors :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^CORS_Config) m.ud
	origin, _ := web.request_header(req, "Origin")
	if len(origin) == 0 {
		// not a cross-origin request: nothing to negotiate
		web.router_next(r, idx + 1, final, req, res)
		return
	}
	if !cors_origin_allowed(cfg, origin) {
		// A disallowed origin gets no CORS headers at all; the request is
		// still served, the browser is what refuses to hand it to script.
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	any_origin := cfg == nil || len(cfg.origins) == 0
	if !any_origin {
		for o in cfg.origins {
			if o == "*" {
				any_origin = true
				break
			}
		}
	}
	cred := cfg != nil && cfg.allow_credentials
	if any_origin && !cred {
		// The wildcard form is only legal without credentials.
		web.response_set_header(res, "Access-Control-Allow-Origin", "*")
	} else {
		web.response_set_header(res, "Access-Control-Allow-Origin", origin)
		web.response_add_header(res, "Vary", "Origin")
	}
	if cred {
		web.response_set_header(res, "Access-Control-Allow-Credentials", "true")
	}

	requested_method, preflight := web.request_header(req, "Access-Control-Request-Method")
	if req.method == .Options && preflight && len(requested_method) > 0 {
		methods := "GET, POST, PUT, PATCH, DELETE, OPTIONS"
		if cfg != nil && len(cfg.allow_methods) > 0 {
			methods = cfg.allow_methods
		}
		web.response_set_header(res, "Access-Control-Allow-Methods", methods)

		headers := ""
		if cfg != nil {
			headers = cfg.allow_headers
		}
		if len(headers) == 0 {
			headers, _ = web.request_header(req, "Access-Control-Request-Headers")
		}
		if len(headers) > 0 {
			web.response_set_header(res, "Access-Control-Allow-Headers", headers)
		}
		if cfg != nil && cfg.max_age_secs > 0 {
			web.response_set_header(
				res,
				"Access-Control-Max-Age",
				web.int_to_string(i64(cfg.max_age_secs), web.response_allocator(res)),
			)
		}
		// The preflight answer is complete: do not run the route.
		web.response_no_content(res, .No_Content)
		return
	}

	if cfg != nil && len(cfg.expose_headers) > 0 {
		web.response_set_header(res, "Access-Control-Expose-Headers", cfg.expose_headers)
	}
	web.router_next(r, idx + 1, final, req, res)
}

cors_origin_allowed :: proc(cfg: ^CORS_Config, origin: string) -> bool {
	if cfg == nil || len(cfg.origins) == 0 {
		return true
	}
	for o in cfg.origins {
		if o == "*" || web.eq_ignore_case(o, origin) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Streams
// ---------------------------------------------------------------------------

/*
middleware_no_buffer marks a response as a stream that intermediaries must
not collect: `X-Accel-Buffering: no` covers nginx, `Cache-Control:
no-transform` stops a transforming proxy from rewriting or re-coding the
body. Compression is skipped as a side effect - a coded body has a length
that only exists once the stream ends.

Use it on any route that emits progress, a log tail or a server-sent event
body. The SSE helpers in `sse.odin` write their own head, so they set the
same fields themselves; this middleware is for the responses that go
through the normal write path.
*/
middleware_no_buffer :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Cache-Control", "no-cache, no-transform")
	web.response_set_header(res, "X-Accel-Buffering", "no")
	web.router_next(r, idx + 1, final, req, res)
}

// ---------------------------------------------------------------------------
// Body limit
// ---------------------------------------------------------------------------

// Body_Limit_Config configures middleware_body_limit; max_bytes <= 0 means
// DEFAULT_BODY_LIMIT.
Body_Limit_Config :: struct {
	max_bytes: int,
}

// middleware_body_limit rejects an oversized request before the handler runs
// by checking Content-Length. A chunked body carries no length up front and
// is only bounded by Server.max_body_size, so this is a fast rejection for
// the common case, not the last line of defence.
middleware_body_limit :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Body_Limit_Config) m.ud
	limit := DEFAULT_BODY_LIMIT
	if cfg != nil && cfg.max_bytes > 0 {
		limit = cfg.max_bytes
	}
	if v, ok := web.request_header(req, "Content-Length"); ok {
		if n, parsed := parse_i64(web.trim_ows(v)); parsed && n > i64(limit) {
			web.response_error(res, .Payload_Too_Large, "")
			return
		}
	}
	web.router_next(r, idx + 1, final, req, res)
}

// parse_i64 parses a non-negative decimal integer; HTTP Content-Length never
// carries a sign or base prefix.
parse_i64 :: proc(s: string) -> (value: i64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	acc: i64
	for i in 0..<len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		acc = acc * 10 + i64(s[i] - '0')
		if acc > (1 << 62) {
			return 0, false
		}
	}
	return acc, true
}
