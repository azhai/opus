package middlewares

import ".."

/*
Two-stage login on top of `Totp`: password first, then a TOTP or recovery
code, both tracked in the session.

The session carries two values, and the pair is the whole state machine:

	user_key      the account the password stage authenticated
	verified_key  "1" once a valid code was accepted

A visitor with `user` but no `verified_key` is *half* authenticated: known,
but not allowed past the gate. That is the state a login endpoint leaves
behind when the account has 2FA on, and `totp_complete_challenge` is the only
thing that turns it into a full session.

Why a flag in the signed cookie and not a server-side ticket: the same reason
the session itself is a signed cookie - nothing to synchronise between
acceptor threads, nothing to sweep. The flag cannot be forged (it is signed)
and it dies with the session.

A login handler looks like this:

	func login(req, res) {
		if !password_ok(req) { return 401 }
		if middlewares.totp_after_password(req, &t, user, &gate_cfg) {
			web.response_redirect(res, "/totp", .Found)   // second stage
			return
		}
		web.response_redirect(res, "/admin", .Found)      // no 2FA on this one
	}

	func challenge(req, res) {                           // POST /totp
		err := middlewares.totp_complete_challenge(req, &t, code, &gate_cfg)
		...
	}

and the protected routes carry `middleware_totp`, after `middleware_session`:

	web.router_use(&router, middlewares.middleware_session, &session_cfg)
	web.router_use(admin_route, middlewares.middleware_totp, &gate_cfg)

The gate answers browsers by redirecting (a navigation gets a page, not a
401 dialog) and everything else with 401 plus a `WWW-Authenticate: TOTP`
challenge. `challenge_path` and `login_path` themselves always pass through,
so a global registration does not lock you out of your own login page.
*/

// TOTP_DEFAULT_CHALLENGE is where a half-authenticated visitor is sent when
// `Totp_Gate_Config.challenge_path` is empty.
TOTP_DEFAULT_CHALLENGE :: "/totp"

// TOTP_DEFAULT_USER_KEY / TOTP_DEFAULT_VERIFIED_KEY are the session keys the
// gate reads and writes. Change them only to avoid a clash with an
// application's own session values.
TOTP_DEFAULT_USER_KEY     :: "user"
TOTP_DEFAULT_VERIFIED_KEY :: "totp_ok"

// Totp_Verify_Mode picks which factor a challenge accepts. `.Either` reads
// the code's shape: `digits` numeric characters is a TOTP code, anything
// else is treated as a recovery code - so a wrong TOTP code is not also
// charged as a wrong backup code.
Totp_Verify_Mode :: enum {
	Either,
	Totp_Only,
	Backup_Only,
}

/*
Totp_Gate_Config configures middleware_totp and the helpers around it.

`login_path` is where an unauthenticated visitor is redirected; empty means
"answer 401 instead", which is what a JSON API wants. `challenge_path` is
where a half-authenticated visitor goes to type the code.

The config must outlive the server (package-level variable or heap), like
every other middleware config in this package.
*/
Totp_Gate_Config :: struct {
	totp:           ^Totp,
	login_path:     string, // "" => 401 for unauthenticated visitors
	challenge_path: string, // default TOTP_DEFAULT_CHALLENGE
	user_key:       string, // default TOTP_DEFAULT_USER_KEY
	verified_key:   string, // default TOTP_DEFAULT_VERIFIED_KEY
	realm:          string, // default "2fa"
}

// ---------------------------------------------------------------------------
// session state
// ---------------------------------------------------------------------------

// totp_session_user returns the account the session authenticated, whether
// it is fully authenticated or still waiting for its code. Empty when the
// visitor never passed the password stage.
totp_session_user :: proc(req: ^web.Request, cfg: ^Totp_Gate_Config) -> string {
	user, ok := session_get(req, totp_user_key(cfg))
	if !ok {
		return ""
	}
	return user
}

// totp_authenticated reports whether *both* factors passed for this
// session. The user is part of the answer: a flag without a name would be
// a session that nobody logged into.
totp_authenticated :: proc(req: ^web.Request, cfg: ^Totp_Gate_Config) -> bool {
	if len(totp_session_user(req, cfg)) == 0 {
		return false
	}
	flag, ok := session_get(req, totp_verified_key(cfg))
	return ok && flag == "1"
}

// totp_challenge_pending returns the account waiting for its second factor,
// and false when there is nothing to challenge (fully authenticated, or no
// password stage yet).
totp_challenge_pending :: proc(req: ^web.Request, cfg: ^Totp_Gate_Config) -> (user: string, pending: bool) {
	user = totp_session_user(req, cfg)
	if len(user) == 0 || totp_authenticated(req, cfg) {
		return "", false
	}
	return user, true
}

/*
totp_after_password records that the password stage succeeded. It returns
true when a TOTP challenge is now required - the caller redirects to the
challenge page and stops - and false when the account has no active binding,
in which case the session is already fully authenticated.

Every prior verification is dropped first: without that, a session that was
verified as user A and then re-used for a login as user B would carry A's
"already checked" flag into B's session.
*/
totp_after_password :: proc(req: ^web.Request, t: ^Totp, user: string, cfg: ^Totp_Gate_Config) -> bool {
	session_set(req, totp_user_key(cfg), user)
	session_delete(req, totp_verified_key(cfg))
	if totp_enrolled(t, user) {
		return true
	}
	session_set(req, totp_verified_key(cfg), "1")
	return false
}

/*
totp_complete_challenge verifies the code typed on the challenge page and
marks the session fully authenticated on success. On failure the session
stays half-authenticated, so the visitor can retry (bounded by the lockout
in `totp_verify`).

The caller writes the response; `Totp_Error` is specific enough to tell
"wrong code" from "locked, come back later" from "this account has no 2FA"
(the last one means the challenge page was reached without a password
stage).
*/
totp_complete_challenge :: proc(
	req: ^web.Request,
	t: ^Totp,
	code: string,
	cfg: ^Totp_Gate_Config,
	mode := Totp_Verify_Mode.Either,
) -> Totp_Error {
	if t == nil || !t.initialized {
		return .Not_Setup
	}
	user := totp_session_user(req, cfg)
	if len(user) == 0 {
		return .Not_Setup
	}

	err: Totp_Error
	switch mode {
	case .Totp_Only:
		err = totp_verify(t, user, code)
	case .Backup_Only:
		err = totp_verify_backup(t, user, code)
	case .Either:
		if len(code) == t.digits && totp_all_digits(code) {
			err = totp_verify(t, user, code)
		} else {
			err = totp_verify_backup(t, user, code)
		}
	}
	if err != .None {
		return err
	}

	session_set(req, totp_verified_key(cfg), "1")
	return .None
}

// totp_sign_out drops both values. Call it next to the session teardown so
// the next login starts from zero even if the cookie survives.
totp_sign_out :: proc(req: ^web.Request, cfg: ^Totp_Gate_Config) {
	session_delete(req, totp_verified_key(cfg))
	session_delete(req, totp_user_key(cfg))
}

// ---------------------------------------------------------------------------
// middleware
// ---------------------------------------------------------------------------

/*
middleware_totp holds the gate: it lets a fully authenticated session
through, sends a half-authenticated one to the challenge page, and turns
away everyone else.

Register it after `middleware_session` (it reads the session) and only on
the routes it should protect, or globally - `login_path` and
`challenge_path` are exempt so the two stages stay reachable. If the request
is a navigation (GET/HEAD accepting text/html) the answer is a 302; a fetch
or an API client gets 401 with `WWW-Authenticate: TOTP` and, when the
password stage already passed, an `X-Totp-Challenge` header naming the page.
*/
middleware_totp :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Totp_Gate_Config) m.ud
	if cfg == nil || cfg.totp == nil {
		// An unconfigured gate is a pass-through, matching the other auth
		// middleware: a missing config must not lock the whole site.
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	challenge := totp_challenge_path(cfg)
	login := cfg.login_path
	if req.path == challenge || (len(login) > 0 && req.path == login) {
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	user := totp_session_user(req, cfg)
	if len(user) > 0 && totp_authenticated(req, cfg) {
		req.principal = user
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	target := login
	if len(user) > 0 {
		target = challenge
	}
	if totp_accepts_html(req) && len(target) > 0 {
		web.response_redirect(res, target, .Found)
		return
	}

	alloc := web.response_allocator(res)
	realm := "2fa"
	if len(cfg.realm) > 0 {
		realm = cfg.realm
	}
	web.response_set_header(res, "WWW-Authenticate", web.concat_strings({"TOTP realm=", auth_quote(realm, alloc)}, alloc))
	if len(user) > 0 {
		// the password stage is done: tell an API client where the second
		// one happens instead of leaving it with a bare 401
		web.response_set_header(res, "X-Totp-Challenge", challenge)
	}
	web.response_error(res, .Unauthorized, "")
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

totp_challenge_path :: proc(cfg: ^Totp_Gate_Config) -> string {
	if cfg != nil && len(cfg.challenge_path) > 0 {
		return cfg.challenge_path
	}
	return TOTP_DEFAULT_CHALLENGE
}

totp_user_key :: proc(cfg: ^Totp_Gate_Config) -> string {
	if cfg != nil && len(cfg.user_key) > 0 {
		return cfg.user_key
	}
	return TOTP_DEFAULT_USER_KEY
}

totp_verified_key :: proc(cfg: ^Totp_Gate_Config) -> string {
	if cfg != nil && len(cfg.verified_key) > 0 {
		return cfg.verified_key
	}
	return TOTP_DEFAULT_VERIFIED_KEY
}

totp_all_digits :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0..<len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// totp_accepts_html decides "is this a page navigation". It deliberately
// requires an explicit text/html (or xhtml) in the Accept list: curl sends
// `*/*` and should get the 401, not a redirect it did not ask to follow.
@(private = "file")
totp_accepts_html :: proc(req: ^web.Request) -> bool {
	if req.method != .Get && req.method != .Head {
		return false
	}
	accept, ok := web.request_header(req, "Accept")
	if !ok {
		return false
	}
	rest := accept
	for len(rest) > 0 {
		item := rest
		if comma := web.string_index_byte(rest, ','); comma >= 0 {
			item = rest[:comma]
			rest = rest[comma + 1:]
		} else {
			rest = ""
		}
		item = web.trim_ows(item)
		if semi := web.string_index_byte(item, ';'); semi >= 0 {
			item = web.trim_ows(item[:semi])
		}
		if web.eq_ignore_case(item, "text/html") || web.eq_ignore_case(item, "application/xhtml+xml") {
			return true
		}
	}
	return false
}
