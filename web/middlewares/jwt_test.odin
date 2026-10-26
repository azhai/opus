package middlewares

import ".."
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

// Tests for the HS256 JWT middleware: what it accepts, what it rejects, and
// why (the error enum is part of the contract - "expired" and "forged" are
// different answers).

jwt_secret := "jwt-secret-key"

jwt_cfg := Jwt_Config {
	secret   = jwt_secret,
	issuer   = "opus",
	audience = "api",
}

jwt_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, request_principal(req))
}

jwt_claims :: proc(sub: string, exp_delta: i64) -> Jwt_Claims {
	return Jwt_Claims {
		sub = sub,
		iss = "opus",
		aud = "api",
		exp = time.time_to_unix(time.now()) + exp_delta,
	}
}

// bearer_of builds "Bearer <token>" in a caller-provided buffer.
bearer_of :: proc(dst: []byte, token: string) -> string {
	prefix := "Bearer "
	n := 0
	for i in 0..<len(prefix) {
		dst[n] = prefix[i]
		n += 1
	}
	for i in 0..<len(token) {
		dst[n] = token[i]
		n += 1
	}
	return string(dst[:n])
}

auth_request :: proc(path: string, storage: ^[1]web.Header, value: string) -> web.Request {
	storage[0] = web.Header{key = "Authorization", value = value}
	return web.Request{method = .Get, path = path, target = path, headers = storage[:]}
}

@(test)
test_middleware_jwt_accepts_valid_token :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_jwt, &jwt_cfg)
	web.router_get(&e.router, "/me", jwt_handler)

	token, signed := jwt_sign(jwt_claims("ada", 600), jwt_secret, mem.arena_allocator(&e.arena))
	testing.expect(t, signed)

	buf: [1024]byte
	hdrs: [1]web.Header
	req := auth_request("/me", &hdrs, bearer_of(buf[:], token))
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "ada")
}

@(test)
test_middleware_jwt_rejects :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	web.router_use(&e.router, middleware_jwt, &jwt_cfg)
	web.router_get(&e.router, "/me", jwt_handler)

	buf: [1024]byte
	hdrs: [1]web.Header

	// no credentials at all: a bare challenge, no error code (RFC 6750)
	req_none := web.Request{method = .Get, path = "/me", target = "/me"}
	res_none: web.Response
	mw_env_call(&e, &req_none, &res_none)
	testing.expect_value(t, res_none.status, web.Status.Unauthorized)
	if www, ok := web.response_header(&res_none, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect_value(t, www, `Bearer realm="api"`)
	}

	// expired: signed correctly, no longer valid
	expired, _ := jwt_sign(jwt_claims("ada", -600), jwt_secret, mem.arena_allocator(&e.arena))
	req_exp := auth_request("/me", &hdrs, bearer_of(buf[:], expired))
	res_exp: web.Response
	mw_env_call(&e, &req_exp, &res_exp)
	testing.expect_value(t, res_exp.status, web.Status.Unauthorized)
	if www, ok := web.response_header(&res_exp, "WWW-Authenticate"); testing.expect(t, ok) {
		testing.expect(t, strings.contains(www, `error="invalid_token"`))
	}

	// signed with a different key
	other, _ := jwt_sign(jwt_claims("ada", 600), "another-key", mem.arena_allocator(&e.arena))
	req_other := auth_request("/me", &hdrs, bearer_of(buf[:], other))
	res_other: web.Response
	mw_env_call(&e, &req_other, &res_other)
	testing.expect_value(t, res_other.status, web.Status.Unauthorized)
	// the handler never ran, so the body is the error page, not "ada"
	testing.expect(t, string(web.buf_slice(&res_other.body)) != "ada")
}

@(test)
test_jwt_verify_error_cases :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)
	alloc := mem.arena_allocator(&e.arena)

	// alg: none - the classic downgrade, rejected before any signature check
	none_token := concat3(
		concat3(base64url_encode(tb(`{"alg":"none"}`), alloc), ".", base64url_encode(tb(`{"sub":"root"}`), alloc), alloc),
		".",
		"",
		alloc,
	)
	_, err := jwt_verify_secret(none_token, jwt_secret, "", "", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Bad_Algorithm)

	// a token whose payload was swapped after signing
	good, _ := jwt_sign(jwt_claims("ada", 600), jwt_secret, alloc)
	dot := web.string_index_byte(good, '.')
	second := web.string_index_byte_from(good, '.', dot + 1)
	forged := concat3(good[:second], ".", base64url_encode(tb(`{"sub":"root"}`), alloc), alloc)
	_, err = jwt_verify_secret(forged, jwt_secret, "", "", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Bad_Signature)

	// right signature, wrong issuer
	_, err = jwt_verify_secret(good, jwt_secret, "someone-else", "", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Wrong_Issuer)

	// right signature, wrong audience
	_, err = jwt_verify_secret(good, jwt_secret, "opus", "other-api", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Wrong_Audience)

	// not a token at all
	_, err = jwt_verify_secret("nonsense", jwt_secret, "", "", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Malformed)
}

@(test)
test_jwt_expiry_and_leeway :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)
	alloc := mem.arena_allocator(&e.arena)

	// expired 10 seconds ago, 30 seconds of leeway: still accepted
	token, _ := jwt_sign(jwt_claims("ada", -10), jwt_secret, alloc)
	claims, err := jwt_verify_secret(token, jwt_secret, "opus", "api", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.None)
	testing.expect_value(t, claims.sub, "ada")

	// the same token without leeway is expired
	_, err = jwt_verify_secret(token, jwt_secret, "opus", "api", 1, alloc)
	testing.expect_value(t, err, Jwt_Error.Expired)

	// nbf in the future: not yet valid
	future := Jwt_Claims{sub = "ada", iss = "opus", aud = "api", nbf = time.time_to_unix(time.now()) + 600}
	early, _ := jwt_sign(future, jwt_secret, alloc)
	_, err = jwt_verify_secret(early, jwt_secret, "opus", "api", 30, alloc)
	testing.expect_value(t, err, Jwt_Error.Not_Yet_Valid)
}
