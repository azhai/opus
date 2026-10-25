package web

import "core:mem"

/*
URI helpers for application code: form decoding/encoding and request-path
normalization. They mirror the pieces every Go web framework exposes
(Echo's QueryString/Path handling, Fiber's QueryUnescape/path cleaning) so
handlers do not grow their own copies.
*/

Path_State :: enum {
	Ok,       // safe to append to a document root
	Bad,      // malformed escapes, or decoded control characters
	Escaping, // a ".." segment after decoding
}

// url_decode decodes an application/x-www-form-urlencoded value: %XX to the
// byte it denotes and '+' to a space. Malformed escapes are kept literally.
// Returns a view of `s` when nothing needed decoding, otherwise storage from
// `allocator`.
url_decode :: proc(s: string, allocator: mem.Allocator = context.allocator) -> string {
	if string_index_byte(s, '%') < 0 && string_index_byte(s, '+') < 0 {
		return s
	}
	out := make([]byte, len(s), allocator)
	n := 0
	for i := 0; i < len(s); {
		c := s[i]
		if c == '%' && i + 2 < len(s) {
			hi := hex_nibble(s[i + 1])
			lo := hex_nibble(s[i + 2])
			if hi >= 0 && lo >= 0 {
				out[n] = byte(hi << 4 | lo)
				n += 1
				i += 3
				continue
			}
		}
		if c == '+' {
			out[n] = ' '
			n += 1
			i += 1
			continue
		}
		out[n] = c
		n += 1
		i += 1
	}
	return string(out[:n])
}

// url_encode escapes a value for use in a query string: unreserved
// characters stay, ' ' becomes '+', everything else is %XX (uppercase hex).
// Storage comes from `allocator`.
url_encode :: proc(s: string, allocator: mem.Allocator = context.allocator) -> string {
	HEX := "0123456789ABCDEF"
	out := make([]byte, len(s) * 3, allocator)
	n := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z',
		     c >= '0' && c <= '9', c == '-', c == '_', c == '.', c == '~':
			out[n] = c
			n += 1
		case c == ' ':
			out[n] = '+'
			n += 1
		case:
			out[n] = '%'
			out[n + 1] = HEX[c >> 4]
			out[n + 2] = HEX[c & 0x0f]
			n += 3
		}
	}
	return string(out[:n])
}

// url_path_clean decodes and normalizes an origin-form request path: drops
// the query/fragment, percent-decodes, rejects control characters, collapses
// empty and "." segments, and reports ".." as Escaping. The result always
// starts with '/'. Storage comes from `allocator`.
//
// This is the filesystem-facing policy, not routing: application handlers
// that map paths onto files should treat anything but Ok as a rejection
// (400 for Bad, 403 for Escaping, matching uhttpd).
url_path_clean :: proc(raw: string, allocator: mem.Allocator = context.allocator) -> (string, Path_State) {
	if len(raw) == 0 || raw[0] != '/' {
		return "", .Bad
	}

	target := raw
	for i := 0; i < len(target); i += 1 {
		if target[i] == '?' || target[i] == '#' {
			target = target[:i]
			break
		}
	}

	decoded := make([]byte, len(target), allocator)
	defer delete(decoded, allocator)
	n := 0
	for i := 0; i < len(target); {
		c := target[i]
		if c == '%' {
			if i + 2 >= len(target) {
				return "", .Bad
			}
			hi := hex_nibble(target[i + 1])
			lo := hex_nibble(target[i + 2])
			if hi < 0 || lo < 0 {
				return "", .Bad
			}
			c = byte(hi << 4 | lo)
			i += 2
		}
		if c < 0x20 || c == 0x7f {
			return "", .Bad
		}
		decoded[n] = c
		n += 1
		i += 1
	}

	out := make([]byte, len(target) + 1, allocator)
	out[0] = '/'
	m := 1
	i := 1 // the leading '/' is already written
	for i < n {
		j := i
		for j < n && decoded[j] != '/' {
			j += 1
		}
		seg := decoded[i:j]
		if len(seg) == 0 || (len(seg) == 1 && seg[0] == '.') {
			// redundant '/' and "." only clutter the path
		} else if len(seg) == 2 && seg[0] == '.' && seg[1] == '.' {
			return "", .Escaping
		} else {
			if m > 1 {
				out[m] = '/'
				m += 1
			}
			for k := 0; k < len(seg); k += 1 {
				out[m] = seg[k]
				m += 1
			}
		}
		i = j + 1
	}
	return string(out[:m]), .Ok
}
