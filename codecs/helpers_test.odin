package codecs

// Shared fixtures for the coding tests.

import "core:mem"

// tb turns a string literal into bytes (transmute needs a typed value).
tb :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// test_repeat builds s repeated n times from allocator.
test_repeat :: proc(s: string, n: int, allocator: mem.Allocator) -> string {
	out := make([]byte, len(s) * n, allocator)
	for i in 0..<n {
		copy(out[i * len(s):], s)
	}
	return string(out)
}
