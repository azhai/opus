package codecs

import "core:testing"

@(test)
test_crc32 :: proc(t: ^testing.T) {
	// the standard check value for "123456789"
	testing.expect(t, crc32(tb("123456789")) == 0xCBF43926)
	testing.expect(t, crc32(nil) == 0)
	testing.expect(t, crc32(tb("")) == 0)
}
