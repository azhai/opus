package web

import "core:encoding/json"
import "core:mem"
import "core:net"

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
	conn:       ^Conn,
	method:     Method,
	version:    HTTP_Version,
	target:     string,
	path:       string,
	query:      string,
	headers:    []Header,
	body:       []byte,
	keep_alive: bool,
	params:     []Param,
	// captures holds the positional captures of a pattern route
	// (patterns containing '(', '%' or '['), 1-based via request_capture.
	captures: []string,
	// id is the request identifier installed by middleware_request_id;
	// empty when that middleware is not in the chain. Read it through
	// request_id rather than the field.
	id: string,
	// principal is the authenticated identity installed by an auth
	// middleware (basic auth user, bearer/API-key token name). Read it
	// through request_principal.
	principal: string,
	// form/files hold the decoded body of a form request (either encoding)
	// and are filled at most once per request, by middleware_form or by the
	// lazy request_form / request_files accessors.
	form:       []Param,
	files:      []Form_File,
	form_state: Form_State,
	// route is the route table entry that matched (nil for an unmatched
	// path) and chain is its route-local middleware chain. Package-internal
	// plumbing for the router.
	route: ^Route,
	chain: []Middleware,
}

request_header :: proc(r: ^Request, name: string) -> (value: string, ok: bool) {
	for h in r.headers {
		if eq_ignore_case(h.key, name) {
			return h.value, true
		}
	}
	return "", false
}

// request_allocator is where decoded query/form storage goes: the connection
// scratch arena in a live request, context.allocator for detached requests
// (unit tests, synthetic handlers).
request_allocator :: proc(r: ^Request) -> mem.Allocator {
	if r.conn != nil {
		return conn_scratch(r.conn)
	}
	return context.allocator
}

// request_query returns the first value of key in the query string (Echo's
// QueryParam, Fiber's Query). Keys and values are form-decoded ('+' → space,
// %XX), so callers compare and use the decoded forms.
request_query :: proc(r: ^Request, key: string) -> (string, bool) {
	alloc := request_allocator(r)
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
		if url_decode(pair[:eq], alloc) == key {
			return url_decode(pair[eq + 1:], alloc), true
		}
	}
	return "", false
}

// request_query_all returns every value for key, in order (Echo's
// QueryParams; repeated query keys are legitimate).
request_query_all :: proc(r: ^Request, key: string) -> []string {
	alloc := request_allocator(r)
	out := make([dynamic]string, alloc)
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
		if url_decode(pair[:eq], alloc) == key {
			append(&out, url_decode(pair[eq + 1:], alloc))
		}
	}
	return out[:]
}

// form_parse parses an application/x-www-form-urlencoded body into
// name/value pairs. '+' and %XX are decoded; malformed escapes are kept
// literally, the same tolerance browsers apply to query strings. Empty
// segments are skipped, and a key without '=' maps to an empty value.
form_parse :: proc(body: string, allocator: mem.Allocator = context.allocator) -> []Param {
	out := make([dynamic]Param, allocator)
	i := 0
	for i <= len(body) {
		j := i
		for j < len(body) && body[j] != '&' {
			j += 1
		}
		item := body[i:j]
		if len(item) > 0 {
			eq := string_index_byte(item, '=')
			name, value: string
			if eq >= 0 {
				name = item[:eq]
				value = item[eq + 1:]
			} else {
				name = item
			}
			append(&out, Param {
				name  = url_decode(name, allocator),
				value = url_decode(value, allocator),
			})
		}
		i = j + 1
		if j >= len(body) {
			break
		}
	}
	return out[:]
}

// request_form parses the request body as a form and returns its fields. Both
// encodings are handled: application/x-www-form-urlencoded directly, and
// multipart/form-data through the same parser `middleware_form` uses (read
// uploads with request_files / request_file). The result is cached on the
// request, so a handler may call this repeatedly.
request_form :: proc(r: ^Request) -> []Param {
	form_ensure_parsed(r, nil)
	return r.form
}

// request_form_value returns the first value of key from the form body.
request_form_value :: proc(r: ^Request, key: string) -> (string, bool) {
	return param_get(request_form(r), key)
}

// param_get returns the first value for name in a name/value list; it works
// for both query and form results (first wins, like Echo's FormValue).
param_get :: proc(params: []Param, name: string) -> (string, bool) {
	for p in params {
		if p.name == name {
			return p.value, true
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

// ---------------------------------------------------------------------------
// Context helpers — the accessors application code expects from a Go web
// framework's context (Echo's Host/Hostname/RealIP/IsAjax/Accepts, Fiber's
// Queries/IP/BodyParser equivalent). Strings stay views into the request
// buffers unless a decode or parse is involved, in which case storage comes
// from the request arena.
// ---------------------------------------------------------------------------

// request_id returns the identifier installed by middleware_request_id
// (empty when that middleware is not in the chain).
request_id :: proc(r: ^Request) -> string {
	return r.id
}

// request_query_params returns every query parameter in order, decoded the
// same way request_query decodes a single key (Echo's QueryParams, Fiber's
// Queries). Repeated keys stay repeated.
request_query_params :: proc(r: ^Request) -> []Param {
	return form_parse(r.query, request_allocator(r))
}

// request_content_type returns the media type of the request body with its
// parameters dropped and lowercased: "application/json", not
// "Application/JSON; charset=utf-8". Empty when the header is absent.
request_content_type :: proc(r: ^Request) -> string {
	v, ok := request_header(r, "Content-Type")
	if !ok {
		return ""
	}
	if semi := string_index_byte(v, ';'); semi >= 0 {
		v = v[:semi]
	}
	return ascii_lower(trim_ows(v), request_allocator(r))
}

// request_host returns the Host header as sent, port included. Empty for an
// HTTP/1.0 request without one.
request_host :: proc(r: ^Request) -> string {
	host, _ := request_header(r, "Host")
	return host
}

// request_hostname returns the Host header without its port; an IPv6 literal
// loses its brackets ("[::1]:80" -> "::1") to match Fiber's Hostname.
request_hostname :: proc(r: ^Request) -> string {
	host := request_host(r)
	if len(host) == 0 {
		return ""
	}
	if host[0] == '[' {
		if close := string_index_byte(host, ']'); close > 0 {
			return host[1:close]
		}
		return host
	}
	if colon := last_index_byte(host, ':'); colon >= 0 {
		return host[:colon]
	}
	return host
}

// request_scheme reports "https" for a TLS connection, "http" otherwise.
// Behind a reverse proxy the client-facing scheme is X-Forwarded-Proto; this
// reports the transport the server itself terminates.
request_scheme :: proc(r: ^Request) -> string {
	if r.conn != nil && r.conn.tls != nil {
		return "https"
	}
	return "http"
}

// request_remote_addr returns the peer endpoint as "ip:port".
request_remote_addr :: proc(r: ^Request) -> string {
	if r.conn == nil {
		return ""
	}
	return net.endpoint_to_string(r.conn.remote, request_allocator(r))
}

// request_client_ip returns the originating client address: X-Real-IP, else
// the leftmost X-Forwarded-For entry, else the socket peer. Proxies append
// to X-Forwarded-For, so the leftmost entry is the client (Echo's RealIP).
request_client_ip :: proc(r: ^Request) -> string {
	if v, ok := request_header(r, "X-Real-IP"); ok {
		if t := trim_ows(v); len(t) > 0 {
			return t
		}
	}
	if v, ok := request_header(r, "X-Forwarded-For"); ok {
		first := v
		if comma := string_index_byte(v, ','); comma >= 0 {
			first = v[:comma]
		}
		if t := trim_ows(first); len(t) > 0 {
			return t
		}
	}
	if r.conn == nil {
		return ""
	}
	return net.address_to_string(r.conn.remote.address, request_allocator(r))
}

// request_is_ajax reports an XMLHttpRequest, using the X-Requested-With
// convention jQuery and friends still send.
request_is_ajax :: proc(r: ^Request) -> bool {
	v, ok := request_header(r, "X-Requested-With")
	return ok && eq_ignore_case(trim_ows(v), "XMLHttpRequest")
}

// request_accepts answers content negotiation for a single media type
// against the Accept header: an exact match, "type/*" and "*/*" all count,
// and q=0 entries are refusals. A missing or empty Accept header accepts
// everything (RFC 7231 section 5.3.2).
request_accepts :: proc(r: ^Request, media_type: string) -> bool {
	accept, ok := request_header(r, "Accept")
	if !ok || len(trim_ows(accept)) == 0 {
		return true
	}
	alloc := request_allocator(r)
	// media type parameters are not part of negotiation
	wanted := media_type
	if semi := string_index_byte(wanted, ';'); semi >= 0 {
		wanted = wanted[:semi]
	}
	want := ascii_lower(trim_ows(wanted), alloc)
	rest := accept
	for len(rest) > 0 {
		item := rest
		if comma := string_index_byte(rest, ','); comma >= 0 {
			item = rest[:comma]
			rest = rest[comma + 1:]
		} else {
			rest = ""
		}
		item = trim_ows(item)
		if len(item) == 0 {
			continue
		}
		token, params := item, ""
		if semi := string_index_byte(item, ';'); semi >= 0 {
			token = trim_ows(item[:semi])
			params = item[semi + 1:]
		}
		if accept_q_is_zero(params) {
			continue
		}
		got := ascii_lower(token, alloc)
		if got == "*/*" || got == want {
			return true
		}
		if len(got) >= 2 && got[len(got) - 1] == '*' && got[len(got) - 2] == '/' {
			prefix := got[:len(got) - 1] // "text/" out of "text/*"
			if len(want) >= len(prefix) && eq_ignore_case(want[:len(prefix)], prefix) {
				return true
			}
		}
	}
	return false
}

// request_json unmarshals the request body into v (Echo's Bind for JSON
// bodies, Fiber's BodyParser without the form branch). Decoded storage comes
// from the request arena. This reports parse failures only; a handler that
// must reject non-JSON bodies should check request_content_type first.
request_json :: proc(r: ^Request, v: ^$T, spec := json.DEFAULT_SPECIFICATION) -> json.Unmarshal_Error {
	return json.unmarshal(r.body, v, spec, request_allocator(r))
}

// accept_q_is_zero reports a q=0 parameter, an explicit refusal. Only a
// literal zero counts: q=0.000 refuses, q=0.5 does not.
accept_q_is_zero :: proc(params: string) -> bool {
	i := string_index(params, "q=")
	if i < 0 {
		return false
	}
	j := i + 2
	if j >= len(params) || params[j] != '0' {
		return false
	}
	zero := true
	j += 1
	if j < len(params) && params[j] == '.' {
		j += 1
		for j < len(params) && params[j] >= '0' && params[j] <= '9' {
			if params[j] != '0' {
				zero = false
			}
			j += 1
		}
	}
	return zero
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

last_index_byte :: proc(s: string, c: byte) -> int {
	for i := len(s) - 1; i >= 0; i -= 1 {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// ascii_lower lowercases ASCII letters. The input is returned as a view when
// it is already lowercase; otherwise the copy lives on `allocator`.
ascii_lower :: proc(s: string, allocator: mem.Allocator) -> string {
	for i in 0..<len(s) {
		if s[i] >= 'A' && s[i] <= 'Z' {
			out := make([]byte, len(s), allocator)
			copy(out, transmute([]byte)s)
			for j in i..<len(s) {
				if out[j] >= 'A' && out[j] <= 'Z' {
					out[j] += 'a' - 'A'
				}
			}
			return string(out)
		}
	}
	return s
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
