package middlewares

import ".."
import "core:encoding/json"
import "core:mem"
import "core:time"

/*
JSON Web Tokens: HS256 only, verification only by default.

`middleware_jwt` reads `Authorization: Bearer <token>`, verifies the
HMAC-SHA256 signature and the time claims, and puts `sub` on the request as
the principal (`web.request_principal`). `jwt_sign` is here so a login
endpoint in the same process can issue what this middleware accepts - it is
not a general-purpose JWT library.

What is deliberately not implemented:

  - `alg: none` and the asymmetric algorithms (RS256, ES256, ...). "none"
    is the classic JWT downgrade attack, so an unrecognised `alg` is
    rejected before the signature is looked at;
  - key sets (JWKS) and key rotation. One shared secret is the honest scope
    for a service that signs its own tokens;
  - refresh tokens and revocation lists - same answer as for sessions: keep
    the lifetime short.

A JWT is not a session: it cannot be invalidated, it is readable by whoever
holds it, and its claims go stale. Use it for service-to-service calls and
short-lived API access, and use `middleware_session` for a browser login.
*/

// Jwt_Claims are the registered claims this middleware understands. Custom
// claims can be added on the issuing side; verification only enforces these.
Jwt_Claims :: struct {
	sub: string `json:"sub,omitempty"`,
	iss: string `json:"iss,omitempty"`,
	aud: string `json:"aud,omitempty"`,
	exp: i64    `json:"exp,omitempty"`,
	nbf: i64    `json:"nbf,omitempty"`,
	iat: i64    `json:"iat,omitempty"`,
}

// Jwt_Error is why a token was rejected. `Expired` and `Not_Yet_Valid` are
// separated so an API can answer "your token expired" instead of a bare 401.
Jwt_Error :: enum {
	None,
	Malformed,      // not three base64url parts, or not JSON
	Bad_Algorithm,  // alg is missing, "none", or not HS256
	Bad_Signature,
	Expired,
	Not_Yet_Valid,
	Wrong_Issuer,
	Wrong_Audience,
}

// JWT_HEADER is the fixed HS256 header, pre-encoded: it never changes, so
// signing does not have to marshal it.
JWT_HEADER :: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"

/*
Jwt_Config configures middleware_jwt.

`secret` is mandatory; an empty one makes the middleware a pass-through, so
an unset environment variable does not turn into "accept any token".

`leeway_secs` absorbs clock skew between the issuer and this server; 30 is
plenty inside one network. `issuer`/`audience` are checked only when set.
*/
Jwt_Config :: struct {
	secret:      string,
	issuer:      string,
	audience:    string,
	leeway_secs: int, // default 30
	realm:       string, // default "api"
}

// middleware_jwt verifies a bearer JWT and names the subject as the
// principal. A rejected request gets 401 with a `WWW-Authenticate` challenge
// carrying `error="invalid_token"` (RFC 6750 section 3).
middleware_jwt :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Jwt_Config) m.ud
	if cfg == nil || len(cfg.secret) == 0 {
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
			have_credentials = true
		}
	}

	claims, err := jwt_verify(presented, cfg, web.request_allocator(req))
	if err == .None {
		req.principal = claims.sub
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	realm := "api"
	if len(cfg.realm) > 0 {
		realm = cfg.realm
	}
	alloc := web.response_allocator(res)
	challenge := web.concat_strings({"Bearer realm=", auth_quote(realm, alloc)}, alloc)
	if have_credentials {
		// RFC 6750 section 3.1: name the failure when a token was offered.
		// An absent Authorization header gets the bare challenge instead.
		challenge = web.concat_strings({challenge, ", error=\"invalid_token\""}, alloc)
	}
	web.response_set_header(res, "WWW-Authenticate", challenge)
	web.response_error(res, .Unauthorized, "")
}

/*
jwt_sign issues an HS256 token for `claims`. `exp` is the caller's job: a
token without one is valid forever, which is almost never what you want.
*/
jwt_sign :: proc(claims: Jwt_Claims, secret: string, allocator := context.allocator) -> (token: string, ok: bool) {
	payload, err := json.marshal(claims, allocator = allocator)
	if err != nil {
		return "", false
	}
	encoded_payload := base64url_encode(payload, allocator)
	signing_input := concat3(JWT_HEADER, ".", encoded_payload, allocator)
	tag := hmac_sign(transmute([]byte) signing_input, transmute([]byte) secret)
	return concat3(signing_input, ".", base64url_encode(tag[:], allocator), allocator), true
}

// jwt_verify checks the signature and the claims. `ok` is `err == .None`.
jwt_verify :: proc(token: string, cfg: ^Jwt_Config, allocator := context.allocator) -> (claims: Jwt_Claims, err: Jwt_Error) {
	return jwt_verify_secret(token, cfg.secret, cfg.issuer, cfg.audience, cfg.leeway_secs, allocator)
}

// jwt_verify_secret is jwt_verify with the parameters spelled out, for
// callers that do not carry a `Jwt_Config` (a login endpoint checking a
// token it just read out of a cookie, say).
jwt_verify_secret :: proc(
	token, secret, issuer, audience: string,
	leeway_secs: int,
	allocator := context.allocator,
) -> (claims: Jwt_Claims, err: Jwt_Error) {
	// three parts: header.payload.signature
	first := strings_index_byte(token, '.')
	if first < 0 {
		return {}, .Malformed
	}
	second := strings_index_byte_from(token, '.', first + 1)
	if second < 0 {
		return {}, .Malformed
	}

	// alg is checked before the signature: an attacker-chosen algorithm must
	// never reach the verification code
	header_bytes, header_ok := base64url_decode(token[:first], allocator)
	if !header_ok {
		return {}, .Malformed
	}
	header: Jwt_Header
	if json.unmarshal_string(string(header_bytes), &header, allocator = allocator) != nil {
		return {}, .Malformed
	}
	if !eq_case(header.alg, "HS256") {
		return {}, .Bad_Algorithm
	}

	signing_input := token[:second]
	tag, tag_ok := base64url_decode(token[second + 1:], allocator)
	if !tag_ok {
		return {}, .Malformed
	}
	if !hmac_valid(transmute([]byte) signing_input, transmute([]byte) secret, tag) {
		return {}, .Bad_Signature
	}

	payload, payload_ok := base64url_decode(token[first + 1:second], allocator)
	if !payload_ok {
		return {}, .Malformed
	}
	if json.unmarshal_string(string(payload), &claims, allocator = allocator) != nil {
		return {}, .Malformed
	}

	now := time.time_to_unix(time.now())
	leeway := i64(leeway_secs)
	if leeway <= 0 {
		leeway = 30
	}
	if claims.exp != 0 && now > claims.exp + leeway {
		return claims, .Expired
	}
	if claims.nbf != 0 && now < claims.nbf - leeway {
		return claims, .Not_Yet_Valid
	}
	if len(issuer) > 0 && claims.iss != issuer {
		return claims, .Wrong_Issuer
	}
	if len(audience) > 0 && claims.aud != audience {
		return claims, .Wrong_Audience
	}
	return claims, .None
}

// Jwt_Header is the small part of the header this middleware cares about.
Jwt_Header :: struct {
	alg: string `json:"alg"`,
	typ: string `json:"typ,omitempty"`,
}

// strings_index_byte_from is index-of-byte starting at `from`.
strings_index_byte_from :: proc(s: string, c: byte, from: int) -> int {
	for i in from..<len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// eq_case compares two ASCII strings exactly. Header values in a JWT are
// case-sensitive, unlike HTTP header names.
eq_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0..<len(a) {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
