package http

import "core:testing"

/*
Tests for the content-coding rules: which coding an `Accept-Encoding` asks for,
and which media types are worth coding at all.

The negotiation cases are the ones a real client actually sends, plus the two
the naive "does the header contain gzip" test gets wrong: `gzip;q=0` (explicit
refusal) and `*;q=0` (refuse everything I did not name).
*/

@(test)
test_negotiate_coding :: proc(t: ^testing.T) {
	Case :: struct {
		header: string,
		want:   Coding,
	}
	cases := [?]Case {
		{"", .Identity}, // absent: identity
		{"identity", .Identity},
		{"gzip", .Gzip},
		{"GZIP", .Gzip}, // tokens are case-insensitive
		{"x-gzip", .Gzip}, // legacy alias
		{"deflate", .Deflate},
		{"gzip, deflate", .Gzip}, // tie: prefer gzip
		{"deflate, gzip", .Gzip}, // order must not matter
		{" deflate ,  gzip ; q=1 ", .Gzip},
		{"br", .Identity}, // unknown coding: fall back, do not fail
		{"br, gzip;q=0.1", .Gzip},
		{"gzip;q=0", .Identity}, // explicit refusal
		{"gzip;q=0, deflate", .Deflate},
		{"gzip;q=0, deflate;q=0", .Identity},
		{"deflate;q=0.5, gzip;q=0.4", .Deflate},
		{"gzip;q=0.4, deflate;q=0.5", .Deflate},
		{"gzip;q=0.001", .Gzip},
		{"gzip;q=1.0", .Gzip},
		{"gzip;q=abc", .Identity}, // malformed weight: treat as refusal
		{"gzip;q=2", .Identity}, // out of range
		{"*", .Gzip}, // wildcard covers gzip
		{"*;q=0", .Identity},
		{"*;q=0, gzip", .Gzip},
		{"gzip;q=0, *", .Deflate}, // wildcard still covers deflate
		{"identity;q=0, gzip", .Gzip},
		{"identity;q=0, gzip;q=0", .Identity}, // nothing acceptable: identity anyway
	}
	for c in cases {
		got := negotiate_coding(c.header)
		testing.expectf(t, got == c.want, "Accept-Encoding %q negotiated %v, want %v", c.header, got, c.want)
	}
}

@(test)
test_coding_name :: proc(t: ^testing.T) {
	testing.expect(t, coding_name(.Gzip) == "gzip")
	testing.expect(t, coding_name(.Deflate) == "deflate")
	testing.expect(t, coding_name(.Identity) == "identity")
}

// The server's half of the negotiation: a coding it does not produce must be
// skipped rather than chosen and then refused, and `*` must not resurrect it.
@(test)
test_negotiate_coding_server_capability :: proc(t: ^testing.T) {
	testing.expect(t, negotiate_coding("gzip, deflate", false, true) == .Deflate)
	testing.expect(t, negotiate_coding("gzip, deflate", true, false) == .Gzip)
	testing.expect(t, negotiate_coding("gzip", false, true) == .Identity)
	testing.expect(t, negotiate_coding("*", false, true) == .Deflate)
	testing.expect(t, negotiate_coding("*", true, true) == .Gzip)
	testing.expect(t, negotiate_coding("gzip", false, false) == .Identity)
}

@(test)
test_content_type_compressible :: proc(t: ^testing.T) {
	testing.expect(t, content_type_compressible("text/html"))
	testing.expect(t, content_type_compressible("TEXT/CSS")) // case-insensitive
	testing.expect(t, content_type_compressible("application/json"))
	testing.expect(t, content_type_compressible("application/javascript; charset=utf-8"))
	testing.expect(t, content_type_compressible("image/svg+xml"))
	testing.expect(t, !content_type_compressible("image/png"))
	testing.expect(t, !content_type_compressible("application/octet-stream"))
	testing.expect(t, !content_type_compressible(""))
}
