package codecs

import "core:mem"

// The gzip member format (RFC 1952) is a 10-byte header, a raw deflate stream,
// and an 8-byte trailer holding the CRC-32 and length of the uncompressed
// bytes. Nothing else of deflate changes, which is why this file is short and
// why `coding` covers both codings with one compressor.

/*
gzip_compress wraps a raw deflate stream in a gzip member (RFC 1952):
10-byte header, deflate data, CRC-32 and input size, both little-endian.

The deflate stream is built into a temporary buffer and copied into the
member, so it is released here: callers that pass the permanent allocator
would otherwise leak one body's worth of memory per response.
*/
gzip_compress :: proc(
	src: []byte,
	allocator: mem.Allocator,
	scratch: ^Deflate_State = nil,
) -> []byte {
	deflated := deflate_compress(src, allocator, scratch)
	defer delete(deflated, allocator)
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
