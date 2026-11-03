package codecs

// gzip is the deflate stream plus a header and a CRC trailer, so what needs
// testing here is the framing and that the checksum is actually checked.

import "core:bytes"
import "core:compress/gzip"
import "core:mem"
import "core:testing"
import "../buffer"

@(test)
test_gzip_roundtrip :: proc(t: ^testing.T) {
	arena_buf: [256 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	src := tb(test_repeat("compress me! ", 200, alloc))
	gz := gzip_compress(src, alloc)
	// gzip magic + deflate method + no flags
	testing.expect(t, len(gz) > 18)
	testing.expect(t, gz[0] == 0x1F && gz[1] == 0x8B)
	testing.expect(t, gz[2] == 0x08)
	testing.expect(t, gz[3] == 0x00)

	out: bytes.Buffer
	defer delete(out.buf)
	err := gzip.load_from_bytes(gz, &out)
	testing.expect(t, err == nil)
	testing.expect(t, len(out.buf) == len(src))
	testing.expect(t, mem.compare(out.buf[:], src) == 0)

	// a corrupted CRC must be detected (proves the checksum is real)
	bad := buffer.clone_bytes(gz, alloc)
	bad[len(bad) - 5] ~= 0xFF
	out2: bytes.Buffer
	defer delete(out2.buf)
	err2 := gzip.load_from_bytes(bad, &out2)
	testing.expect(t, err2 != nil)
}
