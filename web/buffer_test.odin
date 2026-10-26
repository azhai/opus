package web

// Tests for the byte-search primitives.

import "core:testing"

// ref_index is the obvious byte-by-byte search: what bytes_index must agree
// with, whatever strategy it uses internally.
ref_index :: proc(hay: []byte, needle: string) -> int {
	if len(needle) == 0 || len(hay) < len(needle) {
		return -1
	}
	for i in 0 ..= len(hay) - len(needle) {
		match := true
		for j in 0 ..< len(needle) {
			if hay[i + j] != needle[j] {
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

/*
test_bytes_index_matches_naive: bytes_index switches to Boyer-Moore-Horspool
past a size threshold, and the skip table is where such a search goes wrong -
a needle with a repeated byte, a match at the very end, or a match that only
straddles the window are the usual culprits. Random haystacks over a tiny
alphabet produce all three, plus the worst case for Horspool (a needle of one
repeated byte, where every probe finds a candidate and compares).
*/
@(test)
test_bytes_index_matches_naive :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	hay := make([]byte, 4096, alloc)
	needle_buf := make([]byte, 24, alloc)

	// a small alphabet is what makes accidental matches and repeated bytes
	// likely; 'a' dominates so long runs appear
	alphabet := [6]byte{'a', 'a', 'a', 'b', '\r', '\n'}

	x := u32(99)
	next :: proc(x: ^u32, n: u32) -> u32 {
		x^ = x^ * 1103515245 + 12345
		return (x^ >> 16) % n
	}

	for case_index in 0 ..< 400 {
		hlen := 1 + int(next(&x, 4095))
		for i in 0 ..< hlen {
			hay[i] = alphabet[next(&x, 6)]
		}
		m := 1 + int(next(&x, 20))
		for i in 0 ..< m {
			needle_buf[i] = alphabet[next(&x, 6)]
		}
		hay_slice := hay[:hlen]
		needle := string(needle_buf[:m])

		want := ref_index(hay_slice, needle)
		got := bytes_index(hay_slice, needle)
		testing.expectf(t, got == want, "case %v: hay %v B needle %q: got %v want %v", case_index, hlen, needle, got, want)

		// the short-buffer path must agree too
		if hlen > 8 {
			short := hay_slice[:8]
			short_want := ref_index(short, needle)
			short_got := bytes_index(short, needle)
			testing.expectf(t, short_got == short_want, "case %v short: got %v want %v", case_index, short_got, short_want)
		}
	}

	// a needle longer than the haystack, an empty needle, and a match that
	// ends exactly at the last byte
	testing.expect_value(t, bytes_index(hay[:4], "abcdefgh"), -1)
	testing.expect_value(t, bytes_index(hay[:4], ""), -1)
	for i in 0 ..< 200 {
		hay[i] = 'z'
	}
	copy(hay[192:], "abcdefgh")
	testing.expect_value(t, bytes_index(hay[:200], "abcdefgh"), 192)
	testing.expect_value(t, bytes_index(hay[:199], "abcdefgh"), -1)
}

/*
test_bytes_index_long_needle: a multipart separator is a few dozen bytes and
the buffer it is searched in is a megabyte - the case Horspool exists for.
*/
@(test)
test_bytes_index_long_needle :: proc(t: ^testing.T) {
	alloc := context.temp_allocator
	hay := make([]byte, 1 << 20, alloc)
	// incompressible-ish filler that shares no prefix with the separator
	x := u32(7)
	for i in 0 ..< len(hay) {
		x = x * 1103515245 + 12345
		hay[i] = byte(x >> 24) | 0x80
	}
	sep := "\r\n--XyZabcdefghijklmnop"
	copy(hay[len(hay) - 300:], sep)
	testing.expect_value(t, bytes_index(hay, sep), len(hay) - 300)

	// absent: the whole buffer is scanned and nothing is found
	testing.expect_value(t, bytes_index(hay[:len(hay) - 400], sep), -1)
}
