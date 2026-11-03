package token

import "core:testing"

// Tests for the two primitives the rest of the middleware stack is built on.
// They are tested here directly rather than only through the session cookie
// and the JWT middleware: this package has no dependencies, so a failure here
// is unambiguously a failure of base64url or HMAC, not of the caller.

tb :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// RFC 4648 §10 test vectors, re-encoded with the URL-safe alphabet and no
// padding: the standard vectors contain '+' and '/', which this alphabet
// replaces with '-' and '_', so the expectations below are the §10 strings
// with those characters translated and the '=' stripped.
@(test)
test_base64url_vectors :: proc(t: ^testing.T) {
	Case :: struct {
		raw, encoded: string,
	}
	cases := [?]Case {
		{"", ""},
		{"f", "Zg"},
		{"fo", "Zm8"},
		{"foo", "Zm9v"},
		{"foob", "Zm9vYg"},
		{"fooba", "Zm9vYmE"},
		{"foobar", "Zm9vYmFy"},
	}
	for c in cases {
		got := base64url_encode(tb(c.raw))
		defer delete(got)
		testing.expectf(t, got == c.encoded, "%q encoded to %q, want %q", c.raw, got, c.encoded)

		back, ok := base64url_decode(got)
		defer delete(back)
		testing.expectf(t, ok && string(back) == c.raw, "%q decoded to %q (ok=%v)", got, string(back), ok)
	}
}

// The two alphabet-specific characters must survive a round trip, which is the
// whole reason this is not core:encoding/base64's standard alphabet.
@(test)
test_base64url_alphabet :: proc(t: ^testing.T) {
	raw: [4]byte
	// Bytes chosen so the output contains both '-' (62) and '_' (63).
	raw[0] = 0xfb
	raw[1] = 0xff
	raw[2] = 0xbf
	raw[3] = 0xef
	got := base64url_encode(raw[:])
	defer delete(got)
	testing.expectf(t, len(got) == 6, "encoded length %d, want 6", len(got))
	testing.expect(t, got[0] == '-', "first byte should use the URL-safe alphabet")

	back, ok := base64url_decode(got)
	defer delete(back)
	testing.expect(t, ok, "decode of our own output failed")
	testing.expectf(t, len(back) == 4 && back[0] == 0xfb && back[3] == 0xef, "round trip changed the bytes")
}

@(test)
test_base64url_rejects :: proc(t: ^testing.T) {
	// Padding is tolerated (some clients add it back), even when it is where
	// canonical base64url would not put it.
	back, ok := base64url_decode("Zm9vYg==")
	defer delete(back)
	testing.expect(t, ok && string(back) == "foob", "padded input was rejected")

	// Standard-alphabet characters are not in this alphabet.
	_, bad_plus := base64url_decode("ab+c")
	_, bad_slash := base64url_decode("ab/c")
	testing.expect(t, !bad_plus, "'+' accepted by the URL-safe decoder")
	testing.expect(t, !bad_slash, "'/' accepted by the URL-safe decoder")

	// Length 1 mod 4 cannot encode a whole number of bytes.
	_, bad_len := base64url_decode("abcde")
	testing.expect(t, !bad_len, "length 5 accepted")

	// Garbage in the middle.
	_, bad_char := base64url_decode("ab*d")
	testing.expect(t, !bad_char, "'*' accepted")
}

// RFC 4231 test case 2: key "Jefe", data "what do ya want for nothing?".
@(test)
test_hmac_vector :: proc(t: ^testing.T) {
	tag := hmac_sign(tb("what do ya want for nothing?"), tb("Jefe"))
	want := [HMAC_SIZE]byte {
		0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
		0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
		0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
		0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
	}
	testing.expectf(t, tag == want, "HMAC-SHA256 mismatch: %x", tag[:])

	testing.expect(t, hmac_valid(tb("what do ya want for nothing?"), tb("Jefe"), tag[:]), "own tag rejected")
	testing.expect(t, !hmac_valid(tb("what do ya want for nothing?"), tb("JefE"), tag[:]), "wrong key accepted")
	testing.expect(t, !hmac_valid(tb("what do ya want for nothing!"), tb("Jefe"), tag[:]), "wrong message accepted")

	// A truncated tag must be refused by length, not compared byte by byte.
	testing.expect(t, !hmac_valid(tb("m"), tb("k"), tag[:8]), "short tag accepted")
}

@(test)
test_token_round_trip :: proc(t: ^testing.T) {
	key := "0123456789abcdef"
	tok := token_sign(tb("user=42"), key)
	defer delete(tok)

	dot := strings_index_byte(tok, '.')
	testing.expectf(t, dot > 0 && dot < len(tok) - 1, "token %q is not <payload>.<tag>", tok)

	payload, ok := token_open(tok, key)
	defer delete(payload)
	testing.expect(t, ok, "own token rejected")
	testing.expectf(t, string(payload) == "user=42", "payload came back as %q", string(payload))
}

@(test)
test_token_tampering :: proc(t: ^testing.T) {
	key := "0123456789abcdef"
	tok := token_sign(tb("user=42"), key)
	defer delete(tok)

	// Flip the payload: the tag covers the encoded form, so this must fail
	// even though the encoded bytes are still valid base64url.
	scratch: [64]byte
	forged := scratch[:copy(scratch[:], tok)]
	forged[0] = forged[0] == 'd' ? 'e' : 'd'
	_, ok := token_open(string(forged), key)
	testing.expect(t, !ok, "payload edit accepted")

	// Wrong key.
	_, wrong_key := token_open(tok, "fedcba9876543210")
	testing.expect(t, !wrong_key, "wrong key accepted")

	// No separator at all: the session cookie's "empty" case.
	_, no_dot := token_open("justpayload", key)
	testing.expect(t, !no_dot, "token without a tag accepted")

	// Tag present but not decodable, and tag of the wrong length.
	_, bad_tag := token_open("payload.", key)
	testing.expect(t, !bad_tag, "empty tag accepted")
	_, short_tag := token_open("payload.Zm9v", key)
	testing.expect(t, !short_tag, "4-byte tag accepted")

	// Empty payload is still signed; it must open (the cookie layer treats an
	// empty value as "no session", not this layer's job).
	empty := token_sign(nil, key)
	defer delete(empty)
	payload, empty_ok := token_open(empty, key)
	defer delete(payload)
	testing.expect(t, empty_ok && len(payload) == 0, "signed empty payload did not round trip")
}
