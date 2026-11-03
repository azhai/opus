package codecs

import "base:intrinsics"
import "core:mem"

// deflate (RFC 1951): a greedy LZ77 match finder over a 32 KiB window feeding
// fixed-Huffman blocks. Fixed Huffman costs a few percent of ratio against
// dynamic Huffman and removes the entire tree-building stage, which is the
// right trade for response bodies in the tens of kilobytes.

// ---------------------------------------------------------------------------
// hash-chain match finder parameters
// ---------------------------------------------------------------------------


// hash-chain match finder parameters
HASH_BITS  :: 15
HASH_SIZE  :: 1 << HASH_BITS
WINDOW_MASK :: WINDOW_SIZE - 1
WINDOW_SIZE :: 1 << 15 // 32 KiB, the deflate maximum
MAX_CHAIN  :: 128     // match-finder steps per position
MIN_MATCH  :: 3
MAX_MATCH  :: 258

// RFC 1951 section 3.2.5: length and distance code tables.
//
// Every entry here is consumed bit-exactly by the decoder, so a single wrong
// one silently desyncs the stream from that point on. `DIST_EXTRA` in
// particular is *not* the rank of the code: the width grows once per pair of
// distance codes (129..192 and 193..256 both carry 6 extra bits), so the
// 30 entries only reach 13 — an off-by-one in this table shows up as
// `Bad_Distance` in strict inflaters (gzip, zlib) for any match farther than
// 128 bytes, while lenient ones may still round-trip short payloads.
LENGTH_BASE := [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
LENGTH_EXTRA := [29]int{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
DIST_BASE := [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
DIST_EXTRA := [30]int{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

// fh_put_symbol emits one literal/length symbol with the fixed Huffman
// code of RFC 1951 section 3.2.6. Huffman codes are packed most
// significant bit first, so the code is bit-reversed before hitting the
// LSB-first bit writer; extra bits are plain LSB-first fields.
fh_put_symbol :: proc(bw: ^Bit_Writer, s: int) {
	code: u32
	n := 8
	switch {
	case s < 144:
		code = u32(0x30 + s)
	case s < 256:
		code, n = u32(0x190 + s - 144), 9
	case s < 280:
		code, n = u32(s - 256), 7
	case:
		code = u32(0xC0 + s - 280)
	}
	bw_put(bw, reverse_bits(code, n), n)
}

// reverse_bits flips the low n bits of v.
reverse_bits :: proc(v: u32, n: int) -> u32 {
	r := u32(0)
	for i in 0..<n {
		r = (r << 1) | ((v >> uint(i)) & 1)
	}
	return r
}

// length_code maps a match length (3..258) to its code + extra bits.
length_code :: proc(length: int) -> (code: int, extra_bits: int, extra_val: int) {
	for i := 28; i >= 0; i -= 1 {
		if length >= LENGTH_BASE[i] {
			return 257 + i, LENGTH_EXTRA[i], length - LENGTH_BASE[i]
		}
	}
	return 285, 0, 0
}

// distance_code maps a match distance (1..32768) to its code + extra bits.
distance_code :: proc(dist: int) -> (code: int, extra_bits: int, extra_val: int) {
	for i := 29; i >= 0; i -= 1 {
		if dist >= DIST_BASE[i] {
			return i, DIST_EXTRA[i], dist - DIST_BASE[i]
		}
	}
	return 29, 0, 0
}

/*
Deflate_State holds the match-finder hash chains plus the rolling position
base that lets them be reused between calls.

Positions are stored in a monotonic coordinate space instead of in `src`:
`base` is where the current input starts. That is what makes the tables
reusable without clearing them - an entry left by a previous call is smaller
than the current window limit and is rejected by the `cand >= limit` test,
exactly as if the table had been cleared. zlib does the same with `strstart`.

Without this, every compressed response paid a 128 KiB memset (32 K slots)
before it could hash its first byte, which for a 4 KiB body cost more than the
compression itself.

`base` advances by `len(src)` per call and is renormalised (the head table is
cleared once) after about 1 GiB of input on the same scratch.
*/
Deflate_State :: struct {
	// allocator produced this table. Keeping it here means the filter may
	// allocate on the thread that first compresses and release from
	// `server_destroy` on whichever thread owns the server: a thread-local
	// allocator (test runners track one per thread) would otherwise report a
	// mismatched free.
	allocator: mem.Allocator,
	head:      [HASH_SIZE]i32,
	prev:      [WINDOW_SIZE]i32,
	base:      i32,
}

// NO_POS marks an empty hash slot. -1 can never be a valid rolling position.
NO_POS :: -1

deflate_state_create :: proc(allocator := context.allocator) -> ^Deflate_State {
	st := new(Deflate_State, allocator)
	st^ = {}
	st.allocator = allocator
	for i in 0 ..< HASH_SIZE {
		st.head[i] = NO_POS
	}
	// `prev` needs no clearing: it is only ever read through a `head` entry,
	// and ds_insert writes both together.
	return st
}

deflate_state_destroy :: proc(st: ^Deflate_State) {
	free(st, st.allocator)
}

hash3 :: proc(data: []byte, i: int) -> u32 {
	v := (u32(data[i]) << 16) | (u32(data[i + 1]) << 8) | u32(data[i + 2])
	return (v * 2654435761) >> (32 - HASH_BITS)
}

ds_insert :: proc(st: ^Deflate_State, data: []byte, i, base: int) {
	if i + MIN_MATCH > len(data) {
		return
	}
	h := hash3(data, i)
	p := i32(base + i)
	st.prev[p & WINDOW_MASK] = st.head[h]
	st.head[h] = p
}

/*
match_len counts the bytes `src[a...]` and `src[b...]` agree on, up to `max`.

Eight bytes are compared at a time and the first differing byte is located with
a trailing-zero count. The match finder calls this once per candidate on its
hash chain (up to MAX_CHAIN of them per position), so it is where compression
time goes: byte-at-a-time comparison measured at ~48 MiB/s, this at three to
four times that.
*/
match_len :: proc(src: []byte, a, b, max: int) -> int {
	n := 0
	for n + 8 <= max {
		x := intrinsics.unaligned_load((^u64)(rawptr(uintptr(&src[a + n]))))
		y := intrinsics.unaligned_load((^u64)(rawptr(uintptr(&src[b + n]))))
		if x != y {
			return n + int(intrinsics.count_trailing_zeros(x ~ y) >> 3)
		}
		n += 8
	}
	for n < max && src[a + n] == src[b + n] {
		n += 1
	}
	return n
}

/*
deflate_compress compresses src into a raw deflate stream (no zlib header).
The match finder is greedy (no lazy evaluation) and every block uses fixed
Huffman codes; both trade a few percent of ratio for a predictable hot path.

`scratch` is a match-finder table to reuse. Pass the same one on every call for
a stream of responses (the compress filter keeps one) and the tables are only
built once; pass nil and a table is allocated and freed per call.

Auxiliary state comes from `allocator`; when that is the connection scratch
arena it is released with the request.
*/
deflate_compress :: proc(
	src: []byte,
	allocator: mem.Allocator,
	scratch: ^Deflate_State = nil,
) -> []byte {
	bw: Bit_Writer
	bw_init(&bw, allocator)
	// deflate output is bounded by the input plus a small overhead, and a
	// compressed body is normally a fraction of it: one reservation removes
	// the doubling chain (13 reallocations for a 64 KiB body) from the path
	reserve(&bw.out, len(src) / 2 + 512)

	owned := scratch == nil
	st: ^Deflate_State
	if owned {
		st = deflate_state_create()
	} else {
		st = scratch
	}
	defer {
		if owned {
			deflate_state_destroy(st)
		}
	}

	base := int(st.base)

	// one fixed-Huffman block, final
	bw_put(&bw, 1, 1) // BFINAL
	bw_put(&bw, 1, 2) // BTYPE = 01 (fixed Huffman)

	pos := 0
	for pos < len(src) {
		best_len := 0
		best_dist := 0
		if pos + MIN_MATCH <= len(src) {
			h := hash3(src, pos)
			cand := int(st.head[h])
			// The window limit is in the same rolling coordinates as `cand`.
			// It can never reach back past `base`: earlier input belongs to
			// a different buffer, and `cand - base` would go negative.
			limit := base + pos - WINDOW_SIZE
			if limit < base {
				limit = base
			}
			max_len := len(src) - pos
			if max_len > MAX_MATCH {
				max_len = MAX_MATCH
			}
			steps := MAX_CHAIN
			for cand >= limit && steps > 0 {
				steps -= 1
				// `cand` is a rolling position; the match is against the
				// current input, so shift it back into src's index space
				cand_local := cand - base
				l := match_len(src, cand_local, pos, max_len)
				if l > best_len {
					best_len = l
					best_dist = pos - cand_local
					if l >= max_len {
						break
					}
				}
				cand = int(st.prev[cand & WINDOW_MASK])
			}
		}

		if best_len >= MIN_MATCH {
			code, extra_bits, extra_val := length_code(best_len)
			fh_put_symbol(&bw, code)
			if extra_bits > 0 {
				bw_put(&bw, u32(extra_val), extra_bits)
			}
			dcode, dextra_bits, dextra_val := distance_code(best_dist)
			bw_put(&bw, reverse_bits(u32(dcode), 5), 5)
			if dextra_bits > 0 {
				bw_put(&bw, u32(dextra_val), dextra_bits)
			}
			// register every covered position so later matches can
			// point into the middle of this one
			for i := pos; i < pos + best_len; i += 1 {
				ds_insert(st, src, i, base)
			}
			pos += best_len
		} else {
			fh_put_symbol(&bw, int(src[pos]))
			ds_insert(st, src, pos, base)
			pos += 1
		}
	}

	fh_put_symbol(&bw, 256) // end of block
	bw_finish(&bw)

	// advance the rolling base; renormalise before i32 can overflow
	st.base += i32(len(src))
	if st.base > 1 << 30 {
		for i in 0 ..< HASH_SIZE {
			st.head[i] = NO_POS
		}
		st.base = 0
	}
	return bw.out[:]
}
