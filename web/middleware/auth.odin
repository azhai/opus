package middleware

import ".."
import "core:encoding/base64"
import "core:mem"


/*
Authentication middleware, and the principal it installs on the request.

Three schemes cover what a service actually needs:

  - `middleware_basic_auth`: RFC 7617 user/password. Browser-native (the
    login dialog comes for free), one account - the right thing in front of
    an admin UI or a metrics page.
  - `middleware_bearer_auth`: RFC 6750 `Authorization: Bearer <token>`, the
    shape a JWT or an opaque API token arrives in.
  - `middleware_api_key`: a shared key in a custom header, with an optional
    query fallback for clients that cannot set headers (curl-less devices,
    image tags, third-party webhooks).

Every scheme compares the presented secret against the whole configured list
without short-circuiting, so the time to reject does not reveal how much of
a token was right. A successful match sets `req.principal`, read through
`request_principal`; `middleware_logger` includes it in the access log.

A token list is a poor man's user database: rotating a token needs a
restart, there is no per-user state and no revocation short of editing the
list. That is the right trade for service-to-service calls and for a single
shared admin credential. Anything with real accounts belongs behind a
session store of your own; `middleware_basic_auth` plus a TLS server is the
cheapest honest answer below that line.
*/

// Auth_Token pairs a secret with the identity it stands for. `name` is what
// handlers and logs see, so a leaked token can be identified without being
// logged: {"tok_live_...", "deploy-bot"}.
Auth_Token :: struct {
	token: string,
	name:  string,
}

// request_principal returns the identity installed by the auth middleware
// (basic auth user name, bearer/API-key token name); empty when the request
// is unauthenticated or no auth middleware runs on this route.
request_principal :: proc(r: ^web.Request) -> string {
	return r.principal
}

// auth_token_match looks `presented` up in `tokens`. Every candidate is
// compared (no early exit on the first mismatch) and the last match wins, so
// the loop cost is the same whether the token is absent or wrong-but-close.
auth_token_match :: proc(tokens: []Auth_Token, presented: string) -> (name: string, ok: bool) {
	if len(presented) == 0 {
		return "", false
	}
	for t in tokens {
		if secure_eq(t.token, presented) {
			name = t.name
			ok = true
		}
	}
	if ok && len(name) == 0 {
		name = "token"
	}
	return
}

// secure_eq compares two strings in time independent of where they differ
// (length still leaks, which is unavoidable without hashing).
secure_eq :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	diff: byte = 0
	for i in 0..<len(a) {
		diff |= a[i] ~ b[i]
	}
	return diff == 0
}

// auth_quote wraps a value as an RFC 7230 quoted-string: '"' and '\' are
// escaped, everything else is left alone (the header is ASCII by contract).
auth_quote :: proc(value: string, allocator: mem.Allocator) -> string {
	b: web.Buf
	web.buf_init(&b, allocator)
	defer web.buf_destroy(&b)
	web.buf_append_byte(&b, '"')
	for i in 0..<len(value) {
		c := value[i]
		if c == '"' || c == '\\' {
			web.buf_append_byte(&b, '\\')
		}
		web.buf_append_byte(&b, c)
	}
	web.buf_append_byte(&b, '"')
	return web.clone_string(string(web.buf_slice(&b)), allocator)
}

// auth_bearer_value extracts the credentials of "Authorization: Bearer x".
auth_bearer_value :: proc(header: string) -> (token: string, ok: bool) {
	v := web.trim_ows(header)
	if len(v) < 7 || !web.eq_ignore_case(v[:7], "Bearer ") {
		return "", false
	}
	token = web.trim_ows(v[7:])
	return token, len(token) > 0
}

// ---------------------------------------------------------------------------
// Basic auth
// ---------------------------------------------------------------------------

// Basic_Auth_Config configures middleware_basic_auth. An empty `username`
// disables the check (the middleware becomes a pass-through), so a config
// built from an unset environment variable fails open - validate it at
// startup.
Basic_Auth_Config :: struct {
	username: string,
	password: string,
	realm:    string, // default "restricted"
}

middleware_basic_auth :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Basic_Auth_Config) m.ud
	if cfg == nil || len(cfg.username) == 0 {
		web.router_next(r, idx + 1, final, req, res)
		return
	}
	if v, ok := web.request_header(req, "Authorization"); ok {
		if basic_auth_ok(v, cfg.username, cfg.password) {
			req.principal = cfg.username
			web.router_next(r, idx + 1, final, req, res)
			return
		}
	}

	realm := "restricted"
	if len(cfg.realm) > 0 {
		realm = cfg.realm
	}
	alloc := web.response_allocator(res)
	web.response_set_header(res, "WWW-Authenticate", web.concat_strings({"Basic realm=", auth_quote(realm, alloc)}, alloc))
	web.response_error(res, .Unauthorized, "")
}

basic_auth_ok :: proc(header, username, password: string) -> bool {
	if len(header) < 7 || !web.eq_ignore_case(header[:6], "Basic ") {
		return false
	}
	raw, err := base64.decode(header[6:], allocator = context.allocator)
	if err != nil {
		return false
	}
	defer delete(raw)

	creds := string(raw)
	colon := web.string_index_byte(creds, ':')
	if colon < 0 {
		return false
	}
	// Compare both halves unconditionally: short-circuiting on the user
	// name would leak which half was wrong through timing.
	user_ok := secure_eq(creds[:colon], username)
	pass_ok := secure_eq(creds[colon + 1:], password)
	return user_ok && pass_ok
}

// ---------------------------------------------------------------------------
// Bearer tokens
// ---------------------------------------------------------------------------

// Bearer_Auth_Config configures middleware_bearer_auth. Empty `tokens`
// makes the middleware a pass-through (fail open, validate at startup).
Bearer_Auth_Config :: struct {
	tokens: []Auth_Token,
	realm:  string, // default "api"
}

middleware_bearer_auth :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Bearer_Auth_Config) m.ud
	if cfg == nil || len(cfg.tokens) == 0 {
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	presented := ""
	have_credentials := false
	if v, ok := web.request_header(req, "Authorization"); ok {
		if tok, tok_ok := auth_bearer_value(v); tok_ok {
			presented = tok
			have_credentials = true
		} else if len(web.trim_ows(v)) > 0 {
			// some other scheme was offered: answer with a Bearer challenge
			have_credentials = true
		}
	}

	if name, ok := auth_token_match(cfg.tokens, presented); ok {
		req.principal = name
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	realm := "api"
	if len(cfg.realm) > 0 {
		realm = cfg.realm
	}
	alloc := web.response_allocator(res)
	// RFC 6750 section 3: the challenge names the scheme and the realm; an
	// absent Authorization header gets no `error` code, a rejected one gets
	// invalid_token.
	challenge := web.concat_strings({"Bearer realm=", auth_quote(realm, alloc)}, alloc)
	if have_credentials {
		challenge = web.concat_strings({challenge, ", error=\"invalid_token\""}, alloc)
	}
	web.response_set_header(res, "WWW-Authenticate", challenge)
	web.response_error(res, .Unauthorized, "")
}

// ---------------------------------------------------------------------------
// API keys
// ---------------------------------------------------------------------------

/*
API_Key_Config configures middleware_api_key.

`header` defaults to "X-API-Key". `query` is an optional fallback parameter
name: setting one is a compromise (query strings end up in access logs and
Referer headers), so leave it empty unless a client cannot send headers.

The 401 carries a `WWW-Authenticate: ApiKey` challenge. "ApiKey" is not a
registered scheme, which is exactly right here: no client auto-negotiates
it, but the response still satisfies RFC 7235's rule that a 401 names a
challenge.
*/
API_Key_Config :: struct {
	tokens: []Auth_Token,
	header: string,
	query:  string,
	realm:  string,
}

middleware_api_key :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^API_Key_Config) m.ud
	if cfg == nil || len(cfg.tokens) == 0 {
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	header := "X-API-Key"
	if len(cfg.header) > 0 {
		header = cfg.header
	}
	presented := ""
	if v, ok := web.request_header(req, header); ok {
		presented = web.trim_ows(v)
	}
	if len(presented) == 0 && len(cfg.query) > 0 {
		if v, ok := web.request_query(req, cfg.query); ok {
			presented = v
		}
	}

	if name, ok := auth_token_match(cfg.tokens, presented); ok {
		req.principal = name
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	realm := "api"
	if len(cfg.realm) > 0 {
		realm = cfg.realm
	}
	alloc := web.response_allocator(res)
	web.response_set_header(res, "WWW-Authenticate", web.concat_strings({"ApiKey realm=", auth_quote(realm, alloc)}, alloc))
	web.response_error(res, .Unauthorized, "")
}
