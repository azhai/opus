package common

// Secrets and header values: constant-time comparison for anything a client
// could guess, and RFC 7230 quoted-string writing for challenge headers.

import "core:mem"
import "../../buffer"

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
quote_value :: proc(value: string, allocator: mem.Allocator) -> string {
	b: buffer.Buf
	buffer.buf_init(&b, allocator)
	defer buffer.buf_destroy(&b)
	buffer.buf_append_byte(&b, '"')
	for i in 0..<len(value) {
		c := value[i]
		if c == '"' || c == '\\' {
			buffer.buf_append_byte(&b, '\\')
		}
		buffer.buf_append_byte(&b, c)
	}
	buffer.buf_append_byte(&b, '"')
	return buffer.clone_string(string(buffer.buf_slice(&b)), allocator)
}
