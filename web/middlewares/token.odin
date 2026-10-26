package middlewares

import "core:crypto/hash"
import "core:crypto/hmac"
import "core:mem"

/*
Token primitives shared by the session cookie and the JWT middleware:

  - base64url (RFC 4648 section 5) without padding, because both formats
    put their base64 in a header or a cookie where '=', '+' and '/' are
    either illegal or need escaping;
  - HMAC-SHA256, taken from core:crypto rather than hand-rolled.

`core:crypto` is used instead of a hand-written hash for the obvious reason,
but also because it gives constant-time tag comparison for free:
`hmac.verify` never early-exits, so a forgery attempt takes the same time
whether the first byte or the last one is wrong.

Nothing here is a substitute for TLS. A signed cookie is *tamper-evident*,
not confidential: the payload is base64, i.e. readable by anyone who holds
it. Do not put secrets in a session value.
*/

// HMAC_SIZE is the tag length of HMAC-SHA256.
HMAC_SIZE :: 32

// base64url_encode encodes with the URL-safe alphabet and no padding.
base64url_encode :: proc(data: []byte, allocator := context.allocator) -> string {
	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	rem := len(data) % 3
	tail_len := 0
	switch rem {
	case 1:
		tail_len = 2
	case 2:
		tail_len = 3
	}
	out := make([dynamic]byte, 0, (len(data) / 3) * 4 + tail_len, allocator)
	for i := 0; i + 2 < len(data); i += 3 {
		v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
		append(&out, alphabet[(v >> 18) & 0x3f])
		append(&out, alphabet[(v >> 12) & 0x3f])
		append(&out, alphabet[(v >> 6) & 0x3f])
		append(&out, alphabet[v & 0x3f])
	}
	switch rem {
	case 1:
		v := u32(data[len(data) - 1]) << 16
		append(&out, alphabet[(v >> 18) & 0x3f])
		append(&out, alphabet[(v >> 12) & 0x3f])
	case 2:
		v := u32(data[len(data) - 2]) << 16 | u32(data[len(data) - 1]) << 8
		append(&out, alphabet[(v >> 18) & 0x3f])
		append(&out, alphabet[(v >> 12) & 0x3f])
		append(&out, alphabet[(v >> 6) & 0x3f])
	}
	return string(out[:])
}

// base64url_decode decodes the URL-safe alphabet. Padding may be present
// (some clients add it) and is ignored; anything else that is not in the
// alphabet, and any length that is 1 mod 4, is rejected.
base64url_decode :: proc(s: string, allocator := context.allocator) -> ([]byte, bool) {
	n := 0
	for i in 0..<len(s) {
		if s[i] == '=' {
			continue
		}
		if _, ok := base64url_value(s[i]); !ok {
			return nil, false
		}
		n += 1
	}
	if n % 4 == 1 {
		return nil, false
	}
	out := make([dynamic]byte, 0, n / 4 * 3 + 2, allocator)
	acc: u32
	bits: uint = 0
	for i in 0..<len(s) {
		if s[i] == '=' {
			continue
		}
		v, _ := base64url_value(s[i])
		acc = acc << 6 | u32(v)
		bits += 6
		if bits >= 8 {
			bits -= 8
			append(&out, byte((acc >> bits) & 0xff))
		}
	}
	return out[:], true
}

// base64url_value maps one character of the URL-safe alphabet to its value.
base64url_value :: proc(c: byte) -> (value: int, ok: bool) {
	switch {
	case c >= 'A' && c <= 'Z':
		return int(c - 'A'), true
	case c >= 'a' && c <= 'z':
		return int(c - 'a') + 26, true
	case c >= '0' && c <= '9':
		return int(c - '0') + 52, true
	case c == '-':
		return 62, true
	case c == '_':
		return 63, true
	}
	return 0, false
}

// hmac_sign computes HMAC-SHA256 over `msg`.
hmac_sign :: proc(msg, key: []byte) -> [HMAC_SIZE]byte {
	tag: [HMAC_SIZE]byte
	hmac.sum(hash.Algorithm.SHA256, tag[:], msg, key)
	return tag
}

// hmac_valid checks a tag in constant time.
hmac_valid :: proc(msg, key, tag: []byte) -> bool {
	if len(tag) != HMAC_SIZE {
		return false
	}
	return hmac.verify(hash.Algorithm.SHA256, tag, msg, key)
}

// token_sign builds "<base64url(payload)>.<base64url(tag)>". The tag covers
// the encoded payload, not the raw bytes, so verification never has to
// re-encode anything the client sent.
token_sign :: proc(payload: []byte, key: string, allocator := context.allocator) -> string {
	encoded := base64url_encode(payload, allocator)
	tag := hmac_sign(transmute([]byte) encoded, transmute([]byte) key)
	return concat3(encoded, ".", base64url_encode(tag[:], allocator), allocator)
}

// token_open verifies a token and returns its payload. `ok == false` means
// the tag did not match: treat the token as absent, never as partially
// trusted.
token_open :: proc(token: string, key: string, allocator := context.allocator) -> (payload: []byte, ok: bool) {
	dot := strings_index_byte(token, '.')
	if dot < 0 {
		return nil, false
	}
	encoded := token[:dot]
	tag, tag_ok := base64url_decode(token[dot + 1:], allocator)
	if !tag_ok {
		return nil, false
	}
	if !hmac_valid(transmute([]byte) encoded, transmute([]byte) key, tag) {
		return nil, false
	}
	return base64url_decode(encoded, allocator)
}

// strings_index_byte is index-of-byte; local so this file needs no parent
// package import for a one-line helper.
strings_index_byte :: proc(s: string, c: byte) -> int {
	for i in 0..<len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// concat3 joins three strings with one allocation.
concat3 :: proc(a, b, c: string, allocator: mem.Allocator) -> string {
	out := make([dynamic]byte, 0, len(a) + len(b) + len(c), allocator)
	append(&out, ..transmute([]byte) a)
	append(&out, ..transmute([]byte) b)
	append(&out, ..transmute([]byte) c)
	return string(out[:])
}
