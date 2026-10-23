package web

import "core:mem"

/*
Buf is a growable byte buffer.

Buffers used across recv/send callbacks are owned by the server allocator
and must stay alive until the nbio operation completes; per-request scratch
memory lives on the connection arena instead.
*/
Buf :: struct {
	data: [dynamic]byte,
}

buf_init :: proc(b: ^Buf, allocator: mem.Allocator) {
	assert(b.data == nil)
	b.data = make([dynamic]byte, allocator)
}

buf_destroy :: proc(b: ^Buf) {
	if b.data != nil {
		delete(b.data)
		b.data = nil
	}
}

buf_len :: proc(b: ^Buf) -> int {
	return len(b.data)
}

buf_slice :: proc(b: ^Buf) -> []byte {
	return b.data[:]
}

buf_reset :: proc(b: ^Buf) {
	if b.data != nil {
		clear(&b.data)
	}
}

buf_append :: proc(b: ^Buf, data: []byte) {
	if len(data) == 0 {
		return
	}
	append(&b.data, ..data)
}

buf_append_byte :: proc(b: ^Buf, c: byte) {
	append(&b.data, c)
}

buf_append_string :: proc(b: ^Buf, s: string) {
	buf_append(b, transmute([]byte)s)
}

// buf_consume drops the first n bytes, keeping the remainder.
buf_consume :: proc(b: ^Buf, n: int) {
	if n <= 0 {
		return
	}
	if n >= len(b.data) {
		clear(&b.data)
		return
	}
	remaining := len(b.data) - n
	mem.copy_non_overlapping(raw_data(b.data[:]), raw_data(b.data[n:]), remaining)
	resize(&b.data, remaining)
}

// buf_truncate keeps only the first n bytes.
buf_truncate :: proc(b: ^Buf, n: int) {
	m := n
	if m < 0 {
		m = 0
	}
	if m < len(b.data) {
		resize(&b.data, m)
	}
}

// bytes_index finds needle in haystack; returns -1 when absent.
bytes_index :: proc(haystack: []byte, needle: string) -> int {
	n, m := len(haystack), len(needle)
	if m == 0 || n < m {
		return -1
	}
	last := n - m
	for i in 0..=last {
		if haystack[i] != needle[0] {
			continue
		}
		match := true
		for j in 1..<m {
			if haystack[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

bytes_contains :: proc(haystack: []byte, needle: string) -> bool {
	return bytes_index(haystack, needle) >= 0
}

// clone_bytes copies s into a fresh allocation from allocator.
clone_bytes :: proc(s: []byte, allocator: mem.Allocator) -> []byte {
	if len(s) == 0 {
		return nil
	}
	out := make([]byte, len(s), allocator)
	mem.copy_non_overlapping(raw_data(out), raw_data(s), len(s))
	return out
}

clone_string :: proc(s: string, allocator: mem.Allocator) -> string {
	return string(clone_bytes(transmute([]byte)s, allocator))
}

// concat_strings joins parts into one allocation.
concat_strings :: proc(parts: []string, allocator: mem.Allocator) -> string {
	total := 0
	for p in parts {
		total += len(p)
	}
	out := make([]byte, total, allocator)
	n := 0
	for p in parts {
		mem.copy_non_overlapping(raw_data(out[n:]), raw_data(transmute([]byte)p), len(p))
		n += len(p)
	}
	return string(out)
}

// write_hex writes v as lowercase hex without allocation.
write_hex :: proc(b: ^Buf, v: int) {
	digits := "0123456789abcdef"
	tmp: [20]byte
	n := 0
	x := v
	if x == 0 {
		buf_append_byte(b, '0')
		return
	}
	for x > 0 {
		tmp[n] = digits[x & 0xF]
		x >>= 4
		n += 1
	}
	for i := n - 1; i >= 0; i -= 1 {
		buf_append_byte(b, tmp[i])
	}
}
