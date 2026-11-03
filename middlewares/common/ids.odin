package common

// Request identifiers: the time/counter pair is also used outside
// middleware_request_id (session ids, upload temp names), so it lives on its
// own rather than inside the middleware that happens to need it first.

import "core:mem"
import "core:sync"
import "core:time"

// new_request_id builds a 24-character id: 16 hex digits of UTC nanoseconds
// followed by 8 hex digits of a process-wide counter. The time half keeps
// ids roughly sortable across restarts, the counter keeps them unique; no
// randomness source is involved.
new_request_id :: proc(allocator: mem.Allocator) -> string {
	seq := sync.atomic_add(&request_id_seq, u64(1))
	ns := u64(time.time_to_unix_nano(time.now()))
	out := make([]byte, 24, allocator)
	write_hex_padded(out[0:16], ns)
	write_hex_padded(out[16:24], seq)
	return string(out)
}

write_hex_padded :: proc(dst: []byte, value: u64) {
	digits := "0123456789abcdef"
	v := value
	for i := len(dst) - 1; i >= 0; i -= 1 {
		dst[i] = digits[v & 0xf]
		v >>= 4
	}
}
