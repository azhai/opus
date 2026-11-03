package buffer

/*
i64_to_buf writes `v` as decimal into `buf` and returns how many bytes it
took. 20 digits plus a sign is the worst case an i64 can ask for.

Formatting into a caller's buffer is what lets the renderers below build
their result in **one** allocation instead of one per number: a
`Content-Range` used to cost four allocations and leak three of them, since
the intermediate strings were handed to `concat_strings` and never freed.
*/
i64_to_buf :: proc(buf: []byte, v: i64) -> int {
	neg := v < 0
	// -min(i64) has no positive counterpart; widen before negating
	mag := u64(v)
	if neg {
		mag = u64(-(v + 1)) + 1
	}
	tmp: [20]byte
	n := 0
	if mag == 0 {
		tmp[0] = '0'
		n = 1
	}
	for mag > 0 {
		tmp[n] = byte('0' + mag % 10)
		mag /= 10
		n += 1
	}
	total := n
	i := 0
	if neg {
		buf[0] = '-'
		i = 1
		total += 1
	}
	for j := n - 1; j >= 0; j -= 1 {
		buf[i] = tmp[j]
		i += 1
	}
	return total
}

write_padded_u64 :: proc(b: ^Buf, v: u64, width: int) {
	tmp: [24]byte
	n := 0
	x := v
	for x > 0 {
		tmp[n] = byte('0' + x % 10)
		x /= 10
		n += 1
	}
	if n == 0 {
		tmp[0] = '0'
		n = 1
	}
	for pad := n; pad < width; pad += 1 {
		buf_append_byte(b, '0')
	}
	for i := n - 1; i >= 0; i -= 1 {
		buf_append_byte(b, tmp[i])
	}
}

write_padded_i64 :: proc(b: ^Buf, v: i64, width: int) {
	if v < 0 {
		buf_append_byte(b, '-')
		write_padded_u64(b, u64(-v), width)
		return
	}
	write_padded_u64(b, u64(v), width)
}
