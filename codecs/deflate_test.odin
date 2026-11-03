package codecs

// The encoder itself: round trips through a strict inflater, the distance-code
// table, and the match-finder scratch that is reused across calls.

import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:mem"
import "core:testing"

@(test)
test_deflate_roundtrip :: proc(t: ^testing.T) {
	arena_buf: [256 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	pat := "abcabcabc"
	repeat_buf := make([]byte, 4096, alloc)
	for i in 0..<len(repeat_buf) {
		repeat_buf[i] = pat[i % len(pat)]
	}
	random_buf := make([]byte, 2048, alloc)
	{
		x := u32(123456789)
		for i in 0..<len(random_buf) {
			x = x * 1103515245 + 12345
			random_buf[i] = byte(x >> 16)
		}
	}
	payloads := [][]byte{
		{},
		tb("a"),
		tb("hello hello hello hello world"),
		// highly repetitive: exercises long matches
		repeat_buf,
		// incompressible: pseudo-random bytes
		random_buf,
		// mixed text
		tb(test_repeat("The quick brown fox jumps over the lazy dog. ", 40, alloc)),
	}
	for i in 0..<len(payloads) {
		src := payloads[i]
		deflated := deflate_compress(src, alloc)
		testing.expectf(t, len(deflated) > 0 || len(src) == 0, "payload %d: empty deflate output", i)

		out: bytes.Buffer
		defer delete(out.buf)
		err := zlib.inflate_from_byte_array(deflated, &out, raw = true)
		testing.expectf(t, len(out.buf) == len(src), "payload %d: inflated %d bytes, expected %d", i, len(out.buf), len(src))
		if len(src) > 0 {
			testing.expectf(t, mem.compare(out.buf[:], src) == 0, "payload %d: inflated data mismatch", i)
		}
	}
}

@(test)
test_deflate_distance_codes :: proc(t: ^testing.T) {
	// Every distance code must survive a strict inflater. DIST_EXTRA widens
	// once per *pair* of codes, so a single off-by-one there shifts the bit
	// stream by one bit as soon as a match is farther than 128 bytes: lenient
	// decoders still round-trip short repetitive payloads (all matches close
	// together), which is exactly how that bug hid. Walk one distance per
	// code instead: filler, then the same 64 bytes repeated at exactly that
	// distance.
	BLOCK :: 64
	for code in 0..<30 {
		arena_buf: [192 << 10]byte
		arena: mem.Arena
		mem.arena_init(&arena, arena_buf[:])
		alloc := mem.arena_allocator(&arena)

		dist := DIST_BASE[code]
		src := make([]byte, dist + BLOCK, alloc)
		// high-entropy bytes: no accidental long match except the crafted one
		x := u32(0x9E3779B9)
		for i in 0..<len(src) {
			x = x * 1664525 + 1013904223
			src[i] = byte(x >> 24)
		}
		copy(src[dist:], src[:BLOCK])

		gz := gzip_compress(src, alloc)
		out: bytes.Buffer
		// the inflated buffer comes from context.allocator, not the arena, so
		// it has to be released per iteration (defer binds to this block)
		defer delete(out.buf)
		err := gzip.load_from_bytes(gz, &out)
		testing.expectf(t, err == nil, "distance code %d (dist %d): %v", code, dist, err)
		if err == nil {
			testing.expectf(t, len(out.buf) == len(src), "distance code %d (dist %d): inflated %d bytes, want %d", code, dist, len(out.buf), len(src))
			testing.expectf(t, mem.compare(out.buf[:], src) == 0, "distance code %d (dist %d): payload mismatch", code, dist)
		}
	}
}

@(test)
test_deflate_shared_scratch :: proc(t: ^testing.T) {
	arena_buf := make([]byte, 1 << 20, context.allocator)
	defer delete(arena_buf, context.allocator)
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf)
	alloc := mem.arena_allocator(&arena)

	scratch := deflate_state_create()
	defer deflate_state_destroy(scratch)

	make_text :: proc(n: int, seed: int, alloc: mem.Allocator) -> []byte {
		b := make([]byte, n, alloc)
		x := u32(seed)
		for i in 0 ..< n {
			// mostly repetitive, with periodic noise: matches *and* literals
			if (i / 97) % 5 == 0 {
				b[i] = byte('a' + (i * 7) % 26)
			} else {
				x = x * 1103515245 + 12345
				b[i] = byte('a' + (x >> 16) % 26)
			}
		}
		return b
	}

	// several inputs through one scratch: the first builds the tables, later
	// ones must not see stale positions; the 64 KiB one is wider than the
	// 32 KiB window, which is what the rolling base has to handle
	sizes := [5]int{1024, 4096, 64 << 10, 300, 33 << 10}
	for size, i in sizes {
		src := make_text(size, 7 + i, alloc)
		deflated := deflate_compress(src, alloc, scratch)
		out: bytes.Buffer
		defer delete(out.buf)
		err := zlib.inflate_from_byte_array(deflated, &out, raw = true)
		testing.expectf(t, err == nil, "size %v: inflate failed", size)
		testing.expectf(t, len(out.buf) == len(src), "size %v: inflated %v bytes", size, len(out.buf))
		if len(out.buf) == len(src) {
			testing.expectf(t, mem.compare(out.buf[:], src) == 0, "size %v: round trip differs", size)
		}
	}

	// the same input through a warmed scratch and a fresh one must agree:
	// reuse may cost ratio, but it must never change what is encoded
	src := make_text(8192, 99, alloc)
	a := deflate_compress(src, alloc, scratch)
	b := deflate_compress(src, alloc)
	testing.expectf(t, mem.compare(a, b) == 0, "shared scratch changed the output")
}
