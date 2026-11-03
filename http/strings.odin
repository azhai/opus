package http

// String helpers shared by the header, cookie and form parsers. They live in
// this package because every one of them is defined in terms of the HTTP
// grammar (optional whitespace, `;`-separated parameters), not of a buffer.

import "../buffer"

string_index :: proc(s: string, needle: string) -> int {
	// same search as the byte version: a word compare for the short header
	// needles, Horspool beyond that
	return buffer.bytes_index(transmute([]byte)s, needle)
}

string_index_byte :: proc(s: string, c: byte) -> int {
	for i in 0..<len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

trim_ows :: proc(s: string) -> string {
	start, end := 0, len(s)
	for start < end && (s[start] == ' ' || s[start] == '\t') {
		start += 1
	}
	for end > start && (s[end - 1] == ' ' || s[end - 1] == '\t') {
		end -= 1
	}
	return s[start:end]
}

// header_param returns the value of one `;`-separated parameter of a header
// value, unquoted. Parameter names match case-insensitively; a name that
// merely ends with the wanted one ("filename*" vs "filename") does not
// match, so an RFC 5987 extended value never shadows the plain one.
header_param :: proc(value, param: string) -> (string, bool) {
	rest := value
	for len(rest) > 0 {
		semi := string_index_byte(rest, ';')
		seg := rest
		if semi >= 0 {
			seg = rest[:semi]
			rest = rest[semi + 1:]
		} else {
			rest = ""
		}
		seg = trim_ows(seg)
		eq := string_index_byte(seg, '=')
		if eq <= 0 {
			continue // the leading "media type" segment has no '='
		}
		if !eq_ignore_case(trim_ows(seg[:eq]), param) {
			continue
		}
		return unquote_header_value(trim_ows(seg[eq + 1:])), true
	}
	return "", false
}

// strip_path_components reduces a client-supplied file name to its base
// name: browsers may send a full local path (IE used to), and the name is
// echoed into Content-Disposition on download.
strip_path_components :: proc(name: string) -> string {
	out := name
	if i := last_index_byte(out, '/'); i >= 0 {
		out = out[i + 1:]
	}
	if i := last_index_byte(out, '\\'); i >= 0 {
		out = out[i + 1:]
	}
	return out
}

string_index_byte_from :: proc(s: string, c: byte, from: int) -> int {
	for i := from; i < len(s); i += 1 {
		if s[i] == c {
			return i
		}
	}
	return -1
}

last_index_byte :: proc(s: string, c: byte) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == c {
			return i
		}
	}
	return -1
}

hex_nibble :: proc(c: byte) -> int {
	switch c {
	case '0'..='9':
		return int(c - '0')
	case 'a'..='f':
		return int(c - 'a' + 10)
	case 'A'..='F':
		return int(c - 'A' + 10)
	}
	return -1
}

// unquote_header_value strips one layer of double quotes.
unquote_header_value :: proc(v: string) -> string {
	if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {
		return v[1:len(v) - 1]
	}
	return v
}

contains_ignore_case :: proc(s, sub: string) -> bool {
	if len(sub) == 0 {
		return true
	}
	if len(s) < len(sub) {
		return false
	}
	for i in 0..=len(s) - len(sub) {
		match := true
		for j in 0..<len(sub) {
			if lower_ascii(s[i + j]) != lower_ascii(sub[j]) {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}

lower_ascii :: proc(c: byte) -> byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

// has_prefix_ignore_case is a case-insensitive prefix test, for the places
// where the value is a media type or a scheme rather than a header name.
has_prefix_ignore_case :: proc(s, prefix: string) -> bool {
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
