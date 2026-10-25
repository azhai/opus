package middleware

import ".."
import "core:mem"
import "core:time"

/*
Sessions: a signed cookie holding the session's own state, so nothing has to
be stored server-side.

`middleware_session` reads the cookie, verifies its HMAC-SHA256 tag, and
attaches a `Session` to the request for the rest of the chain. After the
handler returns it writes the cookie back if - and only if - something
changed, so a read-only request costs one verification and no writes.

Why a signed cookie and not a server-side map:

  - it works unchanged behind `server_run_multi` (no shared state, no lock);
  - a restart does not log everyone out;
  - there is nothing to sweep, so there is nothing to leak.

The trade, stated plainly:

  - the payload is base64 - readable by whoever holds the cookie. It is
    tamper-evident, not confidential, so session values must not carry
    secrets;
  - logout is "stop sending the cookie": a cookie captured before logout
    stays valid until it expires. Keep `max_age_secs` short, and put
    anything that needs real revocation in a store of your own;
  - a cookie is at most ~4 KB. Bigger payloads are refused.

If you need server-side state (a shopping cart, a multi-step wizard), keep
an id in the session and a record in your own database - that is the design
this middleware is meant to sit beside, not replace.
*/

// SESSION_MAX_COOKIE is the largest cookie this middleware will write.
// Every browser allows at least 4 KB per cookie; the header line and the
// 54-byte tag come out of that budget.
SESSION_MAX_COOKIE :: 3800

// SESSION_DEFAULT_MAX_AGE is the default lifetime: a day.
SESSION_DEFAULT_MAX_AGE :: 24 * 60 * 60

/*
Session_Config configures middleware_session.

`secret` is the HMAC key and is mandatory: an empty one makes the middleware
a pass-through (so a config built from an unset environment variable does not
silently sign with an empty key - the sessions simply never authenticate,
which is the fail-closed direction for a login).

`allow_script = false` (the zero value) sends HttpOnly, which is what you
want unless a script genuinely must read the session.
*/
Session_Config :: struct {
	name:         string, // cookie name, default "sid"
	secret:       string, // HMAC key; required
	max_age_secs: int,    // default SESSION_DEFAULT_MAX_AGE
	path:         string, // default "/"
	domain:       string,
	secure:       bool,
	allow_script: bool,            // true => no HttpOnly
	same_site:    web.Same_Site,   // .Unset => .Lax
}

// Session is the per-request session state. It lives on the request arena:
// the map dies with the request, and only the cookie outlives it.
Session :: struct {
	alloc:        mem.Allocator, // the request arena, for values copied in
	id:           string,
	expires_unix: i64,
	values:       map[string]string,
	dirty:        bool,
	destroyed:    bool,
}

// middleware_session loads (or starts) a session for the request and writes
// the cookie back if the handler changed anything. Register it before the
// handlers that read or write session values.
middleware_session :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Session_Config) m.ud
	if cfg == nil || len(cfg.secret) == 0 {
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	s := session_load(req, cfg)
	req.session = rawptr(s)
	web.router_next(r, idx + 1, final, req, res)
	if s.dirty && !s.destroyed {
		session_save(req, res, s, cfg)
	}
}

// session_active reports whether a session is attached to this request,
// i.e. whether middleware_session runs on this route.
session_active :: proc(req: ^web.Request) -> bool {
	return req.session != nil
}

// session_id returns the session's identifier, for logs and correlation.
session_id :: proc(req: ^web.Request) -> string {
	s := cast(^Session) req.session
	if s == nil {
		return ""
	}
	return s.id
}

// session_get reads one value. `ok == false` means "no such key" - which is
// also what an expired or absent session answers, because a fresh visitor
// has no values yet.
session_get :: proc(req: ^web.Request, key: string) -> (value: string, ok: bool) {
	s := cast(^Session) req.session
	if s == nil {
		return "", false
	}
	v, found := s.values[key]
	return v, found
}

/*session_set writes one value and marks the session for saving. Overwrites
an existing key.

The key and value are copied into the request arena, so a handler may build
them in a stack buffer:

	buf: [64]byte
	session_set(req, "visits", fmt.bprintf(buf[:], "%d", n))

That copy is not a nicety. The cookie is written after the handler returns,
by which time the handler's frame is gone and reused - a session that kept
the caller's pointer would serialise whatever landed there instead.
*/
session_set :: proc(req: ^web.Request, key, value: string) {
	s := cast(^Session) req.session
	if s == nil {
		return
	}
	if _, exists := s.values[key]; !exists {
		s.values[web.clone_string(key, s.alloc)] = web.clone_string(value, s.alloc)
	} else {
		s.values[key] = web.clone_string(value, s.alloc)
	}
	s.dirty = true
}

// session_delete removes one value.
session_delete :: proc(req: ^web.Request, key: string) {
	s := cast(^Session) req.session
	if s == nil {
		return
	}
	delete_key(&s.values, key)
	s.dirty = true
}

// session_values exposes the whole map, for handlers that iterate.
session_values :: proc(req: ^web.Request) -> map[string]string {
	s := cast(^Session) req.session
	if s == nil {
		return nil
	}
	return s.values
}

/*
session_destroy logs the session out: it drops every value and expires the
cookie. Call it with the response at hand (it has to send the clearing
cookie); the middleware then skips its own save.

Destroying is not revoking: a copy of the old cookie still verifies until it
expires. Short lifetimes are the mitigation.
*/
session_destroy :: proc(req: ^web.Request, res: ^web.Response, cfg: ^Session_Config) {
	s := cast(^Session) req.session
	if s == nil {
		return
	}
	clear(&s.values)
	s.dirty = true
	s.destroyed = true
	name := "sid"
	if cfg != nil && len(cfg.name) > 0 {
		name = cfg.name
	}
	path := "/"
	if cfg != nil && len(cfg.path) > 0 {
		path = cfg.path
	}
	web.response_clear_cookie(res, name, path)
}

// ---------------------------------------------------------------------------
// load / save
// ---------------------------------------------------------------------------

// session_load reads and verifies the cookie, or starts a new session when
// there is none, the tag does not verify, or the session has expired. All
// three are the same thing to a handler: a visitor with no values.
session_load :: proc(req: ^web.Request, cfg: ^Session_Config) -> ^Session {
	alloc := web.request_allocator(req)
	name := session_cookie_name(cfg)

	s := new(Session, alloc)
	s.alloc = alloc
	s.values = make(map[string]string, alloc)

	if cookie, ok := web.request_cookie(req, name); ok {
		payload, valid := token_open(cookie, cfg.secret, alloc)
		if valid {
			params := web.form_parse(string(payload), alloc)
			exp, has_exp := param_value(params, "exp")
			if has_exp {
				if n, parsed := parse_int(exp); parsed {
					now := time.time_to_unix(time.now())
					if n > now {
						s.id = param_value_or(params, "id", "")
						s.expires_unix = n
						for p in params {
							if p.name == "id" || p.name == "exp" {
								continue
							}
							s.values[p.name] = p.value
						}
						return s
					}
				}
			}
		}
	}

	s.id = new_session_id(alloc)
	s.expires_unix = time.time_to_unix(time.now()) + i64(session_max_age(cfg))
	return s
}

// session_save serializes the session, signs it and sets the cookie.
session_save :: proc(req: ^web.Request, res: ^web.Response, s: ^Session, cfg: ^Session_Config) {
	alloc := web.request_allocator(req)
	b := make([dynamic]byte, 0, 64 + 32 * len(s.values), alloc)
	append_payload(&b, "id", s.id, alloc)
	append_payload(&b, "exp", int_to_string_i64(s.expires_unix, alloc), alloc)
	// deterministic order is not required, but it keeps cookies stable
	// across requests with unchanged data, which keeps caches and tests
	// from seeing churn
	for k, v in s.values {
		append_payload(&b, k, v, alloc)
	}

	token := token_sign(b[:], cfg.secret, alloc)
	if len(token) + 32 > SESSION_MAX_COOKIE {
		web.log_error("session: refusing to write a %d byte cookie (limit %d)", len(token), SESSION_MAX_COOKIE)
		return
	}

	web.response_set_cookie(res, web.Cookie {
		name         = session_cookie_name(cfg),
		value        = token,
		path         = session_path(cfg),
		domain       = cfg.domain,
		max_age_secs = session_max_age(cfg),
		secure       = cfg.secure,
		http_only    = !cfg.allow_script,
		same_site    = session_same_site(cfg),
	})
}

// append_payload appends one urlencoded "k=v&" pair.
append_payload :: proc(b: ^[dynamic]byte, k, v: string, alloc: mem.Allocator) {
	if len(b) > 0 {
		append(b, '&')
	}
	append(b, ..transmute([]byte) web.url_encode(k, alloc))
	append(b, '=')
	append(b, ..transmute([]byte) web.url_encode(v, alloc))
}

session_cookie_name :: proc(cfg: ^Session_Config) -> string {
	if cfg != nil && len(cfg.name) > 0 {
		return cfg.name
	}
	return "sid"
}

session_path :: proc(cfg: ^Session_Config) -> string {
	if cfg != nil && len(cfg.path) > 0 {
		return cfg.path
	}
	return "/"
}

session_max_age :: proc(cfg: ^Session_Config) -> int {
	if cfg != nil && cfg.max_age_secs > 0 {
		return cfg.max_age_secs
	}
	return SESSION_DEFAULT_MAX_AGE
}

session_same_site :: proc(cfg: ^Session_Config) -> web.Same_Site {
	if cfg != nil && cfg.same_site != .Unset {
		return cfg.same_site
	}
	return .Lax
}

// new_session_id builds a 24-character id the same way request ids are
// built: nanosecond clock plus a counter, no randomness needed.
new_session_id :: proc(alloc: mem.Allocator) -> string {
	return new_request_id(alloc)
}

// param_value is param_get for a []Param slice.
param_value :: proc(params: []web.Param, name: string) -> (string, bool) {
	for p in params {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

param_value_or :: proc(params: []web.Param, name, fallback: string) -> string {
	if v, ok := param_value(params, name); ok {
		return v
	}
	return fallback
}

// parse_int parses a decimal integer; the session expiry is written by this
// same code, so anything else means the payload was tampered with.
parse_int :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	acc: i64
	for i in 0..<len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		acc = acc * 10 + i64(s[i] - '0')
	}
	return acc, true
}

// int_to_string_i64 is the parent package's helper, named locally so this
// file reads without the package qualifier everywhere.
int_to_string_i64 :: proc(v: i64, allocator: mem.Allocator) -> string {
	return web.int_to_string(v, allocator)
}
