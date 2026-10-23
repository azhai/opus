package web

import "core:mem"

/*
deflate / gzip content coding for response bodies.

Odin's core library ships decompression only (`core:compress/zlib` and
`core:compress/gzip` both inflate), so the compressor lives here: a
greedy LZ77 (hash-chain match finder, 32 KiB window) feeding fixed
Huffman blocks (RFC 1951 section 3.2.6), wrapped as a raw deflate stream
or a gzip member. Fixed Huffman costs a few percent versus dynamic
Huffman but removes the entire tree-building stage; correctness is
verified by round-tripping every test payload through
`core:compress/zlib`'s inflater.

The `Compress_Filter` negotiates `Accept-Encoding` per response and only
touches bodies that are worth compressing: in-memory, above a size
threshold, of a compressible content type, and not already coded. File
bodies keep their zero-copy sendfile path (compressing them would cost
the very thing that makes them cheap).
*/

// MIN_COMPRESS_SIZE is the default body size below which compression is
// skipped: the headers alone cost more than the savings.
MIN_COMPRESS_SIZE :: 512

// hash-chain match finder parameters
HASH_BITS  :: 15
HASH_SIZE  :: 1 << HASH_BITS
WINDOW_MASK :: WINDOW_SIZE - 1
WINDOW_SIZE :: 1 << 15 // 32 KiB, the deflate maximum
MAX_CHAIN  :: 128     // match-finder steps per position
MIN_MATCH  :: 3
MAX_MATCH  :: 258

// RFC 1951 section 3.2.5: length and distance code tables
LENGTH_BASE := [29]int{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}
LENGTH_EXTRA := [29]int{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}
DIST_BASE := [30]int{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}
DIST_EXTRA := [30]int{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 7, 7, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15}

// CRC-32 (RFC 1952), built lazily on first use
CRC32_TABLE: [256]u32
CRC32_READY: bool

crc32_table_init :: proc() {
	for i in 0..<256 {
		c := u32(i)
		for _ in 0..<8 {
			if c & 1 != 0 {
				c = 0xEDB88320 ~ (c >> 1)
			} else {
				c = c >> 1
			}
		}
		CRC32_TABLE[i] = c
	}
	CRC32_READY = true
}

// crc32 computes the IEEE CRC-32 of data.
crc32 :: proc(data: []byte) -> u32 {
	if !CRC32_READY {
		crc32_table_init()
	}
	c := u32(0xFFFFFFFF)
	for b in data {
		c = CRC32_TABLE[(c ~ u32(b)) & 0xFF] ~ (c >> 8)
	}
	return c ~ 0xFFFFFFFF
}

// Bit_Writer emits bits LSB-first (RFC 1951 section 3.1.1).
Bit_Writer :: struct {
	out:   [dynamic]byte,
	bits:  u32,
	count: int,
}

bw_init :: proc(bw: ^Bit_Writer, allocator: mem.Allocator) {
	bw.out = make([dynamic]byte, allocator)
}

bw_put :: proc(bw: ^Bit_Writer, value: u32, n: int) {
	mask := u32(1 << uint(n)) - 1
	bw.bits |= (value & mask) << uint(bw.count)
	bw.count += n
	for bw.count >= 8 {
		append(&bw.out, byte(bw.bits & 0xFF))
		bw.bits >>= 8
		bw.count -= 8
	}
}

bw_finish :: proc(bw: ^Bit_Writer) {
	if bw.count > 0 {
		append(&bw.out, byte(bw.bits & 0xFF))
		bw.bits = 0
		bw.count = 0
	}
}

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

// Deflate_State holds the match-finder hash chains. One allocation per
// compression; from an arena it costs nothing to drop.
Deflate_State :: struct {
	head: [HASH_SIZE]i32,
	prev: [WINDOW_SIZE]i32,
}

hash3 :: proc(data: []byte, i: int) -> u32 {
	v := (u32(data[i]) << 16) | (u32(data[i + 1]) << 8) | u32(data[i + 2])
	return (v * 2654435761) >> (32 - HASH_BITS)
}

ds_insert :: proc(st: ^Deflate_State, data: []byte, i: int) {
	if i + MIN_MATCH > len(data) {
		return
	}
	h := hash3(data, i)
	st.prev[i & WINDOW_MASK] = st.head[h]
	st.head[h] = i32(i)
}

/*
deflate_compress compresses src into a raw deflate stream (no zlib
header). The match finder is greedy (no lazy evaluation) and every block
uses fixed Huffman codes; both trade a few percent of ratio for a
predictable, allocation-free hot path.

Auxiliary state comes from `allocator`; when that is the connection
scratch arena it is released with the request.
*/
deflate_compress :: proc(src: []byte, allocator: mem.Allocator) -> []byte {
	bw: Bit_Writer
	bw_init(&bw, allocator)

	// The match-finder tables are 256 KiB. They come from the general
	// allocator rather than `allocator` (which in the server is the
	// per-connection arena sized for request data) so the arena never
	// has to grow to fit them.
	st := new(Deflate_State, context.allocator)
	defer free(st, context.allocator)
	for i in 0..<HASH_SIZE {
		st.head[i] = -1
	}
	// `prev` needs no clearing: it is only ever read through a `head`
	// entry, and ds_insert writes both together.

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
			limit := pos - WINDOW_SIZE
			if limit < 0 {
				limit = 0
			}
			max_len := len(src) - pos
			if max_len > MAX_MATCH {
				max_len = MAX_MATCH
			}
			steps := MAX_CHAIN
			for cand >= limit && steps > 0 {
				steps -= 1
				l := 0
				for l < max_len && src[cand + l] == src[pos + l] {
					l += 1
				}
				if l > best_len {
					best_len = l
					best_dist = pos - cand
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
				ds_insert(st, src, i)
			}
			pos += best_len
		} else {
			fh_put_symbol(&bw, int(src[pos]))
			ds_insert(st, src, pos)
			pos += 1
		}
	}

	fh_put_symbol(&bw, 256) // end of block
	bw_finish(&bw)
	return bw.out[:]
}

/*
gzip_compress wraps a raw deflate stream in a gzip member (RFC 1952):
10-byte header, deflate data, CRC-32 and input size, both little-endian.
*/
gzip_compress :: proc(src: []byte, allocator: mem.Allocator) -> []byte {
	deflated := deflate_compress(src, allocator)
	out := make([]byte, 10 + len(deflated) + 8, allocator)
	out[0] = 0x1F
	out[1] = 0x8B
	out[2] = 0x08 // deflate
	out[3] = 0x00 // no flags
	// MTIME = 0 (no timestamp), XFL = 0, OS = 255 (unknown)
	out[9] = 0xFF
	copy(out[10:], deflated)
	crc := crc32(src)
	n := 10 + len(deflated)
	out[n + 0] = byte(crc)
	out[n + 1] = byte(crc >> 8)
	out[n + 2] = byte(crc >> 16)
	out[n + 3] = byte(crc >> 24)
	size := u32(len(src))
	out[n + 4] = byte(size)
	out[n + 5] = byte(size >> 8)
	out[n + 6] = byte(size >> 16)
	out[n + 7] = byte(size >> 24)
	return out
}

// ---------------------------------------------------------------------------
// Compress_Filter: per-response Accept-Encoding negotiation
// ---------------------------------------------------------------------------

/*
Compress_Filter compresses response bodies with gzip or deflate when the
client asks for it. Registration order matters: it must run before the
chunked filter so the body is coded first and framed second (the sender
applies content codings before transfer codings).

Register it like the chunked filter:

	srv.compress_filter.min_size = 1024   // optional tuning

The filter is enabled by default; set `gzip = false, deflate = false` to
switch it off.
*/
Compress_Filter :: struct {
	using filter: Filter,
	gzip:     bool,
	deflate:  bool,
	min_size: int,
}

filter_compress_init :: proc(f: ^Compress_Filter) {
	f.apply = compress_apply
	f.gzip = true
	f.deflate = true
	f.min_size = MIN_COMPRESS_SIZE
}

compress_apply :: proc(f: ^Filter, c: ^Conn) {
	cf := cast(^Compress_Filter) f
	w := &c.res
	if !cf.gzip && !cf.deflate {
		return
	}
	if file_pending(w) {
		// a streamed file body keeps its zero-copy path
		return
	}
	if c.req.method == .Head {
		return // no body is ever sent
	}
	if w.status == .No_Content || w.status == .Not_Modified {
		return
	}
	if len(w.body.data) < cf.min_size {
		return
	}
	if _, ok := response_header(w, "Content-Encoding"); ok {
		return // already coded: never double-code
	}
	ct, has_ct := response_header(w, "Content-Type")
	if !has_ct || !content_type_compressible(ct) {
		return
	}
	ae, ok := request_header(&c.req, "Accept-Encoding")
	if !ok {
		return
	}

	encoding := ""
	if cf.gzip && contains_ignore_case(ae, "gzip") {
		encoding = "gzip"
	} else if cf.deflate && contains_ignore_case(ae, "deflate") {
		encoding = "deflate"
	}
	if len(encoding) == 0 {
		return
	}

	raw := buf_slice(&w.body)
	compressed := gzip_compress(raw, conn_scratch(c)) if encoding == "gzip" else deflate_compress(raw, conn_scratch(c))
	if len(compressed) >= len(raw) {
		return // no gain: identity is the better answer
	}

	buf_reset(&w.body)
	buf_append(&w.body, compressed)
	// the body changed length: any handler-set Content-Length is stale
	response_remove_header(w, "Content-Length")
	response_set_header(w, "Content-Encoding", encoding)
	response_add_header(w, "Vary", "Accept-Encoding")
}

// response_remove_header drops every header with the given key.
response_remove_header :: proc(w: ^Response, key: string) {
	for i := 0; i < len(w.headers); i += 1 {
		if eq_ignore_case(w.headers[i].key, key) {
			unordered_remove(&w.headers, i)
			i -= 1
		}
	}
}

// COMPRESSIBLE_TYPES lists the non-text types worth coding; anything
// starting with "text/" is compressible by definition.
COMPRESSIBLE_TYPES := [?]string{
	"application/json",
	"application/javascript",
	"application/x-javascript",
	"application/xml",
	"image/svg+xml",
}

content_type_compressible :: proc(ct: string) -> bool {
	if has_prefix_ci(ct, "text/") {
		return true
	}
	for t in COMPRESSIBLE_TYPES {
		if has_prefix_ci(ct, t) {
			return true
		}
	}
	return false
}

// has_prefix_ci is a case-insensitive prefix test.
has_prefix_ci :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	for i in 0..<len(prefix) {
		if lower_ascii(s[i]) != lower_ascii(prefix[i]) {
			return false
		}
	}
	return true
}
