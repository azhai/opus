package codecs

import "core:mem"

// The bit-level sink every deflate construct is written through. Deflate packs
// Huffman codes most-significant-bit-first and everything else
// least-significant-bit-first (RFC 1951 section 3.1.1), so the writer is a
// plain LSB-first accumulator and the few MSB-first callers reverse their code
// before calling it.

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
