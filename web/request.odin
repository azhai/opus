package web

import "core:mem"

MAX_HEADERS :: 128

Param :: struct {
	name:  string,
	value: string,
}

/*
Request is a parsed HTTP/1.1 request.

String fields (target/path/query/header key+value) are zero-copy views
into a per-request head buffer owned by the connection arena; `body` is
a stable copy made when the body has fully arrived. Both live until the
request is done.
*/
Request :: struct {
	conn:      ^Conn,
	method:    Method,
	version:   HTTP_Version,
	target:    string,
	path:      string,
	query:     string,
	headers:   []Header,
	body:      []byte,
	keep_alive: bool,
	params:    []Param,
	// captures holds the positional captures of a pattern route
	// (patterns containing '(', '%' or '['), 1-based via request_capture.
	captures: []string,
}

request_header :: proc(r: ^Request, name: string) -> (value: string, ok: bool) {
	for h in r.headers {
		if eq_ignore_case(h.key, name) {
			return h.value, true
		}
	}
	return "", false
}

// request_query returns the first value of key in the raw query string.
request_query :: proc(r: ^Request, key: string) -> (string, bool) {
	q := r.query
	for len(q) > 0 {
		end := string_index_byte(q, '&')
		pair := q
		if end >= 0 {
			pair = q[:end]
			q = q[end + 1:]
		} else {
			q = ""
		}
		eq := string_index_byte(pair, '=')
		if eq < 0 {
			continue
		}
		if pair[:eq] == key {
			return pair[eq + 1:], true
		}
	}
	return "", false
}

request_param :: proc(r: ^Request, name: string) -> (string, bool) {
	for p in r.params {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

// request_capture returns the idx-th positional capture of a pattern
// route (1-based, like odin-http's req.url_params). Only filled when the
// matched route pattern used pattern syntax.
request_capture :: proc(r: ^Request, idx: int) -> (string, bool) {
	if idx < 1 || idx > len(r.captures) {
		return "", false
	}
	return r.captures[idx - 1], true
}

request_body_string :: proc(r: ^Request) -> string {
	return string(r.body)
}

Parse_Error :: enum {
	None,
	Bad_Request,
	URI_Too_Long,
	Header_Too_Large,
}

// parse_request parses a full request head (request line + headers, ending
// with the blank line). All string views point into `head`, which must stay
// alive for the lifetime of the request. Header storage is allocated from
// `allocator`.
parse_request :: proc(r: ^Request, head: string, allocator: mem.Allocator) -> Parse_Error {
	line_end := string_index(head, "\r\n")
	if line_end <= 0 {
		return .Bad_Request
	}
	line := head[:line_end]

	sp1 := string_index_byte(line, ' ')
	if sp1 <= 0 {
		return .Bad_Request
	}
	sp2 := string_index_byte_from(line, ' ', sp1 + 1)
	if sp2 < 0 {
		return .Bad_Request
	}
	r.method = method_from_string(line[:sp1])
	r.target = line[sp1 + 1:sp2]
	if !parse_version(line[sp2 + 1:], &r.version) {
		return .Bad_Request
	}

	qmark := string_index_byte(r.target, '?')
	if qmark >= 0 {
		r.path = r.target[:qmark]
		r.query = r.target[qmark + 1:]
	} else {
		r.path = r.target
	}

	headers := make([dynamic]Header, allocator)
	rest := head[line_end + 2:]
	count := 0
	for len(rest) > 0 {
		// blank line terminates the head
		if len(rest) >= 2 && rest[0] == '\r' && rest[1] == '\n' {
			break
		}
		nl := string_index(rest, "\r\n")
		if nl < 0 {
			return .Bad_Request
		}
		hdr := rest[:nl]
		rest = rest[nl + 2:]
		colon := string_index_byte(hdr, ':')
		if colon <= 0 {
			return .Bad_Request
		}
		key := hdr[:colon]
		value := trim_ows(hdr[colon + 1:])
		append(&headers, Header{key = key, value = value})
		count += 1
		if count > MAX_HEADERS {
			return .Header_Too_Large
		}
	}
	r.headers = headers[:]
	return .None
}

// url_decode_path percent-decodes a path into allocator memory.
// Returns the decoded path (a view into the original string when nothing
// needed decoding).
url_decode_path :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
	if string_index_byte(path, '%') < 0 {
		return path, true
	}
	decoded := make([]byte, len(path), allocator)
	n := 0
	for i := 0; i < len(path); {
		c := path[i]
		if c == '%' && i + 2 < len(path) {
			hi := hex_nibble(path[i + 1])
			lo := hex_nibble(path[i + 2])
			if hi >= 0 && lo >= 0 {
				decoded[n] = byte(hi << 4 | lo)
				n += 1
				i += 3
				continue
			}
		}
		decoded[n] = c
		n += 1
		i += 1
	}
	return string(decoded[:n]), true
}

parse_version :: proc(s: string, v: ^HTTP_Version) -> bool {
	// "HTTP/1.1"
	if len(s) < 8 || !eq_ignore_case(s[:5], "HTTP/") {
		return false
	}
	major := s[5] - '0'
	if s[6] != '.' {
		return false
	}
	minor := s[7] - '0'
	if major > 9 || minor > 9 {
		return false
	}
	v.major = major
	v.minor = minor
	return true
}

string_index :: proc(s: string, needle: string) -> int {
	n, m := len(s), len(needle)
	if m == 0 || n < m {
		return -1
	}
	last := n - m
	for i in 0..=last {
		match := true
		for j in 0..<m {
			if s[i + j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return i
		}
	}
	return -1
}

string_index_byte :: proc(s: string, c: byte) -> int {
	for i in 0..<len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

string_index_byte_from :: proc(s: string, c: byte, from: int) -> int {
	for i := from; i < len(s); i += 1 {
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
