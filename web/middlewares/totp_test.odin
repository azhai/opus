package middlewares

import ".."
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

/*
Tests for the TOTP second factor.

The algorithm is checked against the published vectors (RFC 4226 appendix D
for HOTP, RFC 6238 appendix B for the 8-digit TOTP), because a TOTP
implementation that is merely self-consistent is worthless: it has to agree
with what the authenticator app computes. The rest covers the state machine -
enrollment, replay, lockout, recovery codes, persistence - and the two-stage
login through a real router dispatch.
*/

// MASTER_KEY_HEX is 32 bytes of hex; any fixed value works, the point is that
// everything encrypted in these tests uses it.
MASTER_KEY_HEX :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

TOTP_TEST_PATH :: "/tmp/web_totp_test_state.json"

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// test_code computes the TOTP value for a base32 secret at `secs`, written
// into the caller's buffer (a returned slice would point at a dead frame).
@(private = "file")
test_code :: proc(buf: []byte, secret_b32: string, secs: i64, digits := 6, period := 30) -> string {
	secret, ok := totp_base32_decode(secret_b32, context.allocator)
	if !ok {
		return ""
	}
	defer delete(secret, context.allocator)
	code, _ := totp_hotp(buf, secret, secs / i64(period), digits)
	return string(code)
}

@(private = "file")
free_enrollment :: proc(e: Totp_Enrollment) {
	delete(e.secret, context.allocator)
	delete(e.otpauth_uri, context.allocator)
	for code in e.backup_codes {
		delete(code, context.allocator)
	}
	delete(e.backup_codes, context.allocator)
}

// totp_test_instance enrolls `user` and leaves the binding enabled. The
// caller destroys the instance and frees the returned enrollment.
@(private = "file")
totp_test_instance :: proc(t: ^testing.T, totp: ^Totp, user: string, cfg := Totp_Config{}) -> Totp_Enrollment {
	config := cfg
	config.issuer = "web-test"
	config.secret_hex = MASTER_KEY_HEX
	testing.expect_value(t, totp_init(totp, config), Totp_Error.None)

	enrollment, err := totp_setup(totp, user)
	testing.expect_value(t, err, Totp_Error.None)
	testing.expect(t, len(enrollment.secret) > 0)

	buf: [8]byte
	code := test_code(buf[:], enrollment.secret, time.to_unix_seconds(time.now()))
	testing.expect_value(t, totp_confirm(totp, user, code), Totp_Error.None)
	testing.expect(t, totp_enrolled(totp, user))
	return enrollment
}

// ---------------------------------------------------------------------------
// RFC vectors
// ---------------------------------------------------------------------------

@(test)
test_totp_hotp_rfc4226 :: proc(t: ^testing.T) {
	secret := transmute([]byte) string("12345678901234567890")
	want := [10]string {
		"755224", "287082", "359152", "969429", "338314",
		"254676", "287922", "162583", "399871", "520489",
	}
	buf: [8]byte
	for expected, counter in want {
		code, ok := totp_hotp(buf[:], secret, i64(counter), 6)
		testing.expect(t, ok)
		testing.expectf(t, string(code) == expected, "hotp(%d) = %s, want %s", counter, code, expected)
	}

	// RFC 6238 appendix B: the 8-digit values are the same counters read
	// with a longer modulus (SHA-1 row).
	want8 := [3]struct {
		secs: i64,
		code: string,
	} {
		{59, "94287082"},
		{1111111109, "07081804"},
		{2000000000, "69279037"},
	}
	for item in want8 {
		code, ok := totp_hotp(buf[:], secret, item.secs / 30, 8)
		testing.expect(t, ok)
		testing.expectf(t, string(code) == item.code, "totp(%d) = %s, want %s", item.secs, code, item.code)
	}
}

@(test)
test_totp_base32 :: proc(t: ^testing.T) {
	raw := transmute([]byte) string("12345678901234567890")
	encoded := totp_base32_encode(raw, context.allocator)
	defer delete(encoded, context.allocator)
	testing.expect_value(t, encoded, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")

	decoded, ok := totp_base32_decode(encoded, context.allocator)
	testing.expect(t, ok)
	defer delete(decoded, context.allocator)
	testing.expect_value(t, string(decoded), "12345678901234567890")

	// a secret typed by hand arrives lower case, spaced and padded
	typed, typed_ok := totp_base32_decode("gezd gnbv gy3t qojq gezd gnbv gy3t qojq====", context.allocator)
	testing.expect(t, typed_ok)
	defer delete(typed, context.allocator)
	testing.expect_value(t, string(typed), "12345678901234567890")

	// '1' is not in the alphabet (0/1/8/9 are excluded on purpose)
	_, bad_ok := totp_base32_decode("GEZDGNBV1Y3TQOJQ", context.allocator)
	testing.expect(t, !bad_ok)
	_, empty_ok := totp_base32_decode("", context.allocator)
	testing.expect(t, !empty_ok)
}

@(test)
test_totp_secret_encryption :: proc(t: ^testing.T) {
	key: [32]byte
	for i in 0..<32 {
		key[i] = byte(i)
	}
	plain := "JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP"
	sealed, ok := totp_encrypt_secret(plain, key, context.allocator)
	testing.expect(t, ok)
	defer delete(sealed, context.allocator)
	testing.expect(t, sealed != plain)

	opened, open_ok := totp_decrypt_secret(sealed, key, context.allocator)
	testing.expect(t, open_ok)
	defer delete(opened, context.allocator)
	testing.expect_value(t, opened, plain)

	// a different master key must not open it (that is what the tag is for)
	other: [32]byte
	_, wrong_key := totp_decrypt_secret(sealed, other, context.allocator)
	testing.expect(t, !wrong_key)

	// flipping one character of the ciphertext must fail authentication,
	// not yield garbage that then gets used as a secret
	tampered_buf: [512]byte
	copy(tampered_buf[:], sealed)
	pos := len(sealed) - 1
	tampered_buf[pos] = tampered_buf[pos] == 'A' ? 'B' : 'A'
	_, tampered := totp_decrypt_secret(string(tampered_buf[:len(sealed)]), key, context.allocator)
	testing.expect(t, !tampered)
}

// ---------------------------------------------------------------------------
// enrollment / verification
// ---------------------------------------------------------------------------

@(test)
test_totp_enrollment_and_verify :: proc(t: ^testing.T) {
	totp: Totp
	enrollment := totp_test_instance(t, &totp, "ada@example.com")
	defer totp_destroy(&totp)
	defer free_enrollment(enrollment)

	testing.expect(t, len(enrollment.backup_codes) == TOTP_BACKUP_CODES)
	testing.expect(t, strings.has_prefix(enrollment.otpauth_uri, "otpauth://totp/"))
	testing.expect(t, strings.contains(enrollment.otpauth_uri, "secret="))

	status := totp_status(&totp, "ada@example.com")
	testing.expect(t, status.enabled && status.has_binding)
	testing.expect_value(t, status.backup_codes, TOTP_BACKUP_CODES)

	// an unknown account has no binding, and is not "enrolled"
	testing.expect(t, !totp_enrolled(&totp, "bob@example.com"))
	testing.expect_value(t, totp_verify(&totp, "bob@example.com", "123456"), Totp_Error.Not_Enabled)

	// one buffer per code: the returned string is a view into the buffer,
	// so reusing it would make `next` alias `code`
	now_buf: [8]byte
	next_buf: [8]byte
	prev_buf: [8]byte
	now := time.to_unix_seconds(time.now())
	code := test_code(now_buf[:], enrollment.secret, now)
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", code), Totp_Error.None)

	// the same digits again are a replay, not a second login
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", code), Totp_Error.Code_Already_Used)

	// the next window's code differs and is accepted
	next := test_code(next_buf[:], enrollment.secret, now + 30)
	testing.expect(t, next != code)
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", next), Totp_Error.None)

	// the skew tolerance accepts the previous window too
	previous := test_code(prev_buf[:], enrollment.secret, now - 30)
	testing.expect(t, previous != code && previous != next)
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", previous), Totp_Error.None)

	// ... and the replay record names the window the code belonged to, not
	// the current one: otherwise the same digits would be accepted again
	// while they are still inside the skew window
	matched_previous := false
	for entry in totp.state.used["ada@example.com"] {
		if entry.code == previous {
			matched_previous = entry.window == (now / 30) - 1
		}
	}
	testing.expect(t, matched_previous, "used-code window must be the matched window")

	// garbage never verifies
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", "abcdef"), Totp_Error.Invalid_Code)
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", "12345"), Totp_Error.Invalid_Code)
}

@(test)
test_totp_setup_requires_confirmation :: proc(t: ^testing.T) {
	totp: Totp
	cfg := Totp_Config{issuer = "web-test", secret_hex = MASTER_KEY_HEX}
	testing.expect_value(t, totp_init(&totp, cfg), Totp_Error.None)
	defer totp_destroy(&totp)

	enrollment, err := totp_setup(&totp, "ada@example.com")
	testing.expect_value(t, err, Totp_Error.None)
	defer free_enrollment(enrollment)

	// enrolled but not enabled: a login for this user still needs no code
	status := totp_status(&totp, "ada@example.com")
	testing.expect(t, status.has_binding && !status.enabled)
	testing.expect(t, !totp_enrolled(&totp, "ada@example.com"))
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", "000000"), Totp_Error.Not_Enabled)
	testing.expect_value(t, totp_confirm(&totp, "ada@example.com", "000000"), Totp_Error.Invalid_Code)

	buf: [8]byte
	code := test_code(buf[:], enrollment.secret, time.to_unix_seconds(time.now()))
	testing.expect_value(t, totp_confirm(&totp, "ada@example.com", code), Totp_Error.None)
	testing.expect(t, totp_enrolled(&totp, "ada@example.com"))

	// re-enrolling an active account is refused: that is how a stolen
	// session would take the second factor over
	_, again := totp_setup(&totp, "ada@example.com")
	testing.expect_value(t, again, Totp_Error.Already_Enabled)

	// after disabling, the account is back to a single factor
	testing.expect_value(t, totp_disable(&totp, "ada@example.com"), Totp_Error.None)
	testing.expect(t, !totp_enrolled(&totp, "ada@example.com"))
}

@(test)
test_totp_lockout :: proc(t: ^testing.T) {
	totp: Totp
	enrollment := totp_test_instance(t, &totp, "ada@example.com", Totp_Config {
		max_attempts = 3,
		lock_secs    = 60,
	})
	defer totp_destroy(&totp)
	defer free_enrollment(enrollment)

	now_buf: [8]byte
	wrong_buf: [8]byte
	now := time.to_unix_seconds(time.now())
	code := test_code(now_buf[:], enrollment.secret, now)
	wrong := test_code(wrong_buf[:], enrollment.secret, now + 90) // far outside the skew
	for _ in 0..<3 {
		testing.expect_value(t, totp_verify(&totp, "ada@example.com", wrong), Totp_Error.Invalid_Code)
	}
	// the correct code does not get through either while the lock holds
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", code), Totp_Error.Account_Locked)
	testing.expect(t, totp_status(&totp, "ada@example.com").locked)

	// expire the lock the way the clock would, then the budget is fresh
	sync.lock(&totp.mu)
	{
		b := totp.state.bindings["ada@example.com"]
		b.locked_until = time.to_unix_seconds(time.now()) - 1
		totp.state.bindings["ada@example.com"] = b
	}
	sync.unlock(&totp.mu)

	unlocked := test_code(wrong_buf[:], enrollment.secret, time.to_unix_seconds(time.now()) + 30)
	testing.expect_value(t, totp_verify(&totp, "ada@example.com", unlocked), Totp_Error.None)
	testing.expect(t, !totp_status(&totp, "ada@example.com").locked)
	testing.expect_value(t, totp.state.bindings["ada@example.com"].failed_attempts, 0)
}

@(test)
test_totp_backup_codes :: proc(t: ^testing.T) {
	totp: Totp
	cfg := Totp_Config{issuer = "web-test", secret_hex = MASTER_KEY_HEX, max_attempts = 0}
	testing.expect_value(t, totp_init(&totp, cfg), Totp_Error.None)
	defer totp_destroy(&totp)

	ada, ada_err := totp_setup(&totp, "ada@example.com")
	testing.expect_value(t, ada_err, Totp_Error.None)
	defer free_enrollment(ada)
	bob, bob_err := totp_setup(&totp, "bob@example.com")
	testing.expect_value(t, bob_err, Totp_Error.None)
	defer free_enrollment(bob)

	buf: [8]byte
	now := time.to_unix_seconds(time.now())
	testing.expect_value(t, totp_confirm(&totp, "ada@example.com", test_code(buf[:], ada.secret, now)), Totp_Error.None)
	testing.expect_value(t, totp_confirm(&totp, "bob@example.com", test_code(buf[:], bob.secret, now)), Totp_Error.None)

	// a recovery code is bound to the account it was issued for
	testing.expect_value(t, totp_verify_backup(&totp, "bob@example.com", ada.backup_codes[0]), Totp_Error.Invalid_Backup_Code)
	testing.expect_value(t, totp_verify_backup(&totp, "ada@example.com", ada.backup_codes[0]), Totp_Error.None)
	// and it is single-use
	testing.expect_value(t, totp_verify_backup(&totp, "ada@example.com", ada.backup_codes[0]), Totp_Error.Invalid_Backup_Code)
	testing.expect_value(t, totp_status(&totp, "ada@example.com").backup_codes, TOTP_BACKUP_CODES - 1)

	// lower case and stray spaces still match: the user retypes the code
	lowered := ada.backup_codes[1]
	lowered_buf: [16]byte
	n := copy(lowered_buf[:], lowered)
	for i in 0..<n {
		c := lowered_buf[i]
		if c >= 'A' && c <= 'F' {
			lowered_buf[i] = c + 32
		}
	}
	testing.expect_value(t, totp_verify_backup(&totp, "ada@example.com", string(lowered_buf[:n])), Totp_Error.None)

	// regenerating invalidates the old set
	fresh, fresh_err := totp_regenerate_backup_codes(&totp, "ada@example.com")
	testing.expect_value(t, fresh_err, Totp_Error.None)
	defer {
		for code in fresh {
			delete(code, context.allocator)
		}
		delete(fresh, context.allocator)
	}
	testing.expect_value(t, totp_verify_backup(&totp, "ada@example.com", ada.backup_codes[2]), Totp_Error.Invalid_Backup_Code)
	testing.expect_value(t, totp_verify_backup(&totp, "ada@example.com", fresh[0]), Totp_Error.None)
	testing.expect_value(t, totp_status(&totp, "ada@example.com").backup_codes, TOTP_BACKUP_CODES - 1)
}

// ---------------------------------------------------------------------------
// persistence
// ---------------------------------------------------------------------------

@(test)
test_totp_confirm_is_rate_limited :: proc(t: ^testing.T) {
	totp: Totp
	cfg := Totp_Config {
		issuer       = "web-test",
		secret_hex   = MASTER_KEY_HEX,
		max_attempts = 2,
		lock_secs    = 60,
	}
	testing.expect_value(t, totp_init(&totp, cfg), Totp_Error.None)
	defer totp_destroy(&totp)

	enrollment, err := totp_setup(&totp, "ada@example.com")
	testing.expect_value(t, err, Totp_Error.None)
	defer free_enrollment(enrollment)

	// The enrollment page only needs the password, so guessing the code
	// there must cost the same as guessing it at login.
	now_buf: [8]byte
	now := time.to_unix_seconds(time.now())
	wrong := test_code(now_buf[:], enrollment.secret, now + 90)
	for _ in 0..<2 {
		testing.expect_value(t, totp_confirm(&totp, "ada@example.com", wrong), Totp_Error.Invalid_Code)
	}
	right_buf: [8]byte
	right := test_code(right_buf[:], enrollment.secret, now)
	testing.expect_value(t, totp_confirm(&totp, "ada@example.com", right), Totp_Error.Account_Locked)
	testing.expect(t, !totp_enrolled(&totp, "ada@example.com"))
}

@(test)
test_totp_persists_state :: proc(t: ^testing.T) {
	os.remove(TOTP_TEST_PATH)

	cfg := Totp_Config {
		issuer     = "web-test",
		secret_hex = MASTER_KEY_HEX,
		path       = TOTP_TEST_PATH,
	}
	totp: Totp
	testing.expect_value(t, totp_init(&totp, cfg), Totp_Error.None)
	// a missing file is the first run, not a failure
	testing.expect(t, !totp_load_failed(&totp))

	enrollment, err := totp_setup(&totp, "ada@example.com")
	testing.expect_value(t, err, Totp_Error.None)
	defer free_enrollment(enrollment)

	buf: [8]byte
	now := time.to_unix_seconds(time.now())
	testing.expect_value(t, totp_confirm(&totp, "ada@example.com", test_code(buf[:], enrollment.secret, now)), Totp_Error.None)
	totp_destroy(&totp)

	// the file must not carry the secret in the clear
	data, read_err := os.read_entire_file(TOTP_TEST_PATH, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(data, context.allocator)
	testing.expect(t, !strings.contains(string(data), enrollment.secret))
	testing.expect(t, strings.contains(string(data), "ada@example.com"))

	// a second instance reads the same state: the binding is still on, and
	// a fresh code verifies
	reloaded: Totp
	testing.expect_value(t, totp_init(&reloaded, cfg), Totp_Error.None)
	defer totp_destroy(&reloaded)
	testing.expect(t, !totp_load_failed(&reloaded))
	status := totp_status(&reloaded, "ada@example.com")
	testing.expect(t, status.enabled && status.backup_codes == TOTP_BACKUP_CODES)
	testing.expect_value(
		t,
		totp_verify(&reloaded, "ada@example.com", test_code(buf[:], enrollment.secret, now + 30)),
		Totp_Error.None,
	)

	os.remove(TOTP_TEST_PATH)

	// a corrupt file is reported instead of silently starting empty
	corrupt := "this is not json"
	testing.expect(t, os.write_entire_file_from_bytes(TOTP_TEST_PATH, transmute([]byte) corrupt) == nil)
	broken: Totp
	testing.expect_value(t, totp_init(&broken, cfg), Totp_Error.None)
	defer totp_destroy(&broken)
	testing.expect(t, totp_load_failed(&broken))

	// and it is never overwritten by the empty state this instance started
	// with - that would turn 2FA off for everyone without a word
	_, broken_err := totp_setup(&broken, "bob@example.com")
	testing.expect_value(t, broken_err, Totp_Error.Storage_Failure)
	still, still_err := os.read_entire_file(TOTP_TEST_PATH, context.allocator)
	testing.expect(t, still_err == nil)
	defer delete(still, context.allocator)
	testing.expect_value(t, string(still), corrupt)

	os.remove(TOTP_TEST_PATH)
}

// ---------------------------------------------------------------------------
// two-stage login through the router
// ---------------------------------------------------------------------------

// The gate handlers are plain procs (Odin has no closures), so the instance
// and its config live at file scope for the duration of one test.
gate_totp: Totp
gate_cfg:  Totp_Gate_Config

gate_login :: proc(req: ^web.Request, res: ^web.Response) {
	user, _ := web.request_query(req, "user")
	if len(user) == 0 {
		user = "ada@example.com"
	}
	if totp_after_password(req, &gate_totp, user, &gate_cfg) {
		web.response_redirect(res, "/totp", .Found)
		return
	}
	web.response_redirect(res, "/admin", .Found)
}

gate_challenge :: proc(req: ^web.Request, res: ^web.Response) {
	code, _ := web.request_form_value(req, "code")
	#partial switch totp_complete_challenge(req, &gate_totp, code, &gate_cfg) {
	case .None:
		web.response_write_string(res, "ok")
	case .Account_Locked:
		web.response_error(res, .Forbidden, "locked")
	case:
		web.response_error(res, .Unauthorized, "bad code")
	}
}

gate_admin :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, "admin:")
	web.response_write_string(res, request_principal(req))
}

@(test)
test_totp_gate_flow :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	enrollment := totp_test_instance(t, &gate_totp, "ada@example.com")
	defer totp_destroy(&gate_totp)
	defer free_enrollment(enrollment)

	gate_cfg = Totp_Gate_Config {
		totp    = &gate_totp,
		login_path     = "/login",
		challenge_path = "/totp",
	}

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/login", gate_login)
	web.router_add(&e.router, .Post, "/totp", gate_challenge)
	admin_route := web.router_get(&e.router, "/admin", gate_admin)
	web.router_use_route(admin_route, middleware_totp, &gate_cfg)

	// 1. no session at all: an API client gets a challenge, not a redirect
	req := web.Request{method = .Get, path = "/admin", target = "/admin"}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.Unauthorized)
	_, has_realm := web.response_header(&res, "WWW-Authenticate")
	testing.expect(t, has_realm)
	_, has_hint := web.response_header(&res, "X-Totp-Challenge")
	testing.expect(t, !has_hint, "a visitor without a password stage has no challenge page")

	// 2. same route, browsed: a navigation is answered with a redirect
	html_hdrs: [1]web.Header
	html_hdrs[0] = web.Header{key = "Accept", value = "text/html,application/xhtml+xml"}
	req_html := web.Request {
		method  = .Get,
		path    = "/admin",
		target  = "/admin",
		headers = html_hdrs[:],
	}
	res_html: web.Response
	mw_env_call(&e, &req_html, &res_html)
	testing.expect_value(t, res_html.status, web.Status.Found)
	location, _ := web.response_header(&res_html, "Location")
	testing.expect_value(t, location, "/login")

	// 3. the password stage: the session now holds a half-authenticated user
	cbuf: [1024]byte
	login_req := web.Request{method = .Get, path = "/login", target = "/login?user=ada%40example.com"}
	login_req.query = "user=ada%40example.com"
	res_login: web.Response
	mw_env_call(&e, &login_req, &res_login)
	testing.expect_value(t, res_login.status, web.Status.Found)
	login_location, _ := web.response_header(&res_login, "Location")
	testing.expect_value(t, login_location, "/totp")
	token := cookie_of(&res_login, "sid")
	testing.expect(t, len(token) > 0)

	// 4. half-authenticated: still refused, but now the gate says where to go
	hdrs: [1]web.Header
	req_pending := web.Request {
		method  = .Get,
		path    = "/admin",
		target  = "/admin",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", token)),
	}
	res_pending: web.Response
	mw_env_call(&e, &req_pending, &res_pending)
	testing.expect_value(t, res_pending.status, web.Status.Unauthorized)
	hint, hint_ok := web.response_header(&res_pending, "X-Totp-Challenge")
	testing.expect(t, hint_ok)
	testing.expect_value(t, hint, "/totp")

	// 5. a wrong code keeps the session half-authenticated
	wrong_buf: [24]byte
	wrong_body := fmt.bprintf(wrong_buf[:], "code=%s", "000000")
	form_hdrs: [2]web.Header
	form_hdrs[0] = web.Header{key = "Cookie", value = concat_cookie(cbuf[:], "sid", token)}
	form_hdrs[1] = web.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}
	req_wrong := web.Request {
		method  = .Post,
		path    = "/totp",
		target  = "/totp",
		headers = form_hdrs[:],
		body    = transmute([]byte) wrong_body,
	}
	res_wrong: web.Response
	mw_env_call(&e, &req_wrong, &res_wrong)
	testing.expect_value(t, res_wrong.status, web.Status.Unauthorized)

	// 6. the right code completes the login
	code_buf: [16]byte
	code := test_code(code_buf[:], enrollment.secret, time.to_unix_seconds(time.now()))
	body_buf: [24]byte
	body := fmt.bprintf(body_buf[:], "code=%s", code)
	form_hdrs[1] = web.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"}
	req_ok := web.Request {
		method  = .Post,
		path    = "/totp",
		target  = "/totp",
		headers = form_hdrs[:],
		body    = transmute([]byte) body,
	}
	res_ok: web.Response
	mw_env_call(&e, &req_ok, &res_ok)
	testing.expect_value(t, res_ok.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_ok.body)), "ok")
	verified := cookie_of(&res_ok, "sid")
	testing.expect(t, len(verified) > 0)

	// 7. with both factors in the session the gate steps aside
	hdrs2: [1]web.Header
	req_admin := web.Request {
		method  = .Get,
		path    = "/admin",
		target  = "/admin",
		headers = cookie_headers(&hdrs2, concat_cookie(cbuf[:], "sid", verified)),
	}
	res_admin: web.Response
	mw_env_call(&e, &req_admin, &res_admin)
	testing.expect_value(t, res_admin.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res_admin.body)), "admin:ada@example.com")
}

@(test)
test_totp_gate_skips_non_enrolled_account :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	// no enrollment for this account: the password stage alone is enough
	cfg := Totp_Config{issuer = "web-test", secret_hex = MASTER_KEY_HEX}
	testing.expect_value(t, totp_init(&gate_totp, cfg), Totp_Error.None)
	defer totp_destroy(&gate_totp)

	gate_cfg = Totp_Gate_Config{totp = &gate_totp, login_path = "/login", challenge_path = "/totp"}

	web.router_use(&e.router, middleware_session, &session_cfg)
	web.router_get(&e.router, "/login", gate_login)
	admin_route := web.router_get(&e.router, "/admin", gate_admin)
	web.router_use_route(admin_route, middleware_totp, &gate_cfg)

	login_req := web.Request{method = .Get, path = "/login", target = "/login"}
	login_req.query = "user=nobody%40example.com"
	res_login: web.Response
	mw_env_call(&e, &login_req, &res_login)
	location, _ := web.response_header(&res_login, "Location")
	testing.expect_value(t, location, "/admin")

	cbuf: [1024]byte
	token := cookie_of(&res_login, "sid")
	hdrs: [1]web.Header
	req := web.Request {
		method  = .Get,
		path    = "/admin",
		target  = "/admin",
		headers = cookie_headers(&hdrs, concat_cookie(cbuf[:], "sid", token)),
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "admin:nobody@example.com")
}

@(test)
test_totp_bad_master_key :: proc(t: ^testing.T) {
	totp: Totp
	// short, non-hex, and empty keys are all refused at init: a 2FA that
	// silently stores secrets in clear is worse than none
	for bad in ([]string{"", "abcd", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"}) {
		cfg := Totp_Config{secret_hex = bad}
		testing.expect_value(t, totp_init(&totp, cfg), Totp_Error.Bad_Master_Key)
	}
}

