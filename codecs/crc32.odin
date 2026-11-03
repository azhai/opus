package codecs

// CRC-32 as gzip needs it (RFC 1952): the trailer of a member carries the
// checksum of the *uncompressed* bytes, so this is not part of deflate itself
// and does not belong in deflate.odin.

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
