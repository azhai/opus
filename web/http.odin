package web

import "core:time"
import "core:time/datetime"

Method :: enum u8 {
	Get,
	Head,
	Post,
	Put,
	Delete,
	Options,
	Patch,
	Trace,
	Connect,
	// All is a route-table wildcard, never a request method: a route
	// registered with it answers every verb (`router_all`). `method_from_string`
	// never returns it.
	All,
	Unknown,
}

method_from_string :: proc(s: string) -> Method {
	switch s {
	case "GET":
		return .Get
	case "HEAD":
		return .Head
	case "POST":
		return .Post
	case "PUT":
		return .Put
	case "DELETE":
		return .Delete
	case "OPTIONS":
		return .Options
	case "PATCH":
		return .Patch
	case "TRACE":
		return .Trace
	case "CONNECT":
		return .Connect
	}
	return .Unknown
}

method_string :: proc(m: Method) -> string {
	switch m {
	case .Get:
		return "GET"
	case .Head:
		return "HEAD"
	case .Post:
		return "POST"
	case .Put:
		return "PUT"
	case .Delete:
		return "DELETE"
	case .Options:
		return "OPTIONS"
	case .Patch:
		return "PATCH"
	case .Trace:
		return "TRACE"
	case .Unknown:
		return "UNKNOWN"
	case .Connect:
		return "CONNECT"
	case .All:
		// only reachable from a route table, so this is a label, not a method
		return "ALL"
	}
	return "UNKNOWN"
}

HTTP_Version :: struct {
	major: u8,
	minor: u8,
}

Status :: enum u16 {
	OK                  = 200,
	Created             = 201,
	Accepted            = 202,
	Partial_Content     = 206,
	No_Content          = 204,
	Moved_Permanently   = 301,
	Found               = 302,
	See_Other           = 303,
	Not_Modified        = 304,
	Temporary_Redirect  = 307,
	Permanent_Redirect  = 308,
	Bad_Request         = 400,
	Unauthorized        = 401,
	Forbidden           = 403,
	Not_Found           = 404,
	Method_Not_Allowed  = 405,
	Not_Acceptable      = 406,
	Request_Timeout     = 408,
	Conflict            = 409,
	Length_Required     = 411,
	Payload_Too_Large   = 413,
	URI_Too_Long        = 414,
	Unsupported_Media    = 415,
	Range_Not_Satisfiable = 416,
	Header_Too_Large    = 431,
	Internal_Error      = 500,
	Not_Implemented     = 501,
	Bad_Gateway         = 502,
	Service_Unavailable = 503,
	Gateway_Timeout     = 504,
}

status_text :: proc(s: Status) -> string {
	switch s {
	case .OK:
		return "OK"
	case .Created:
		return "Created"
	case .Accepted:
		return "Accepted"
	case .Partial_Content:
		return "Partial Content"
	case .No_Content:
		return "No Content"
	case .Moved_Permanently:
		return "Moved Permanently"
	case .Found:
		return "Found"
	case .See_Other:
		return "See Other"
	case .Not_Modified:
		return "Not Modified"
	case .Temporary_Redirect:
		return "Temporary Redirect"
	case .Permanent_Redirect:
		return "Permanent Redirect"
	case .Bad_Request:
		return "Bad Request"
	case .Unauthorized:
		return "Unauthorized"
	case .Forbidden:
		return "Forbidden"
	case .Not_Found:
		return "Not Found"
	case .Method_Not_Allowed:
		return "Method Not Allowed"
	case .Not_Acceptable:
		return "Not Acceptable"
	case .Request_Timeout:
		return "Request Timeout"
	case .Conflict:
		return "Conflict"
	case .Length_Required:
		return "Length Required"
	case .Payload_Too_Large:
		return "Payload Too Large"
	case .URI_Too_Long:
		return "URI Too Long"
	case .Unsupported_Media:
		return "Unsupported Media Type"
	case .Range_Not_Satisfiable:
		return "Range Not Satisfiable"
	case .Header_Too_Large:
		return "Request Header Fields Too Large"
	case .Internal_Error:
		return "Internal Server Error"
	case .Not_Implemented:
		return "Not Implemented"
	case .Bad_Gateway:
		return "Bad Gateway"
	case .Service_Unavailable:
		return "Service Unavailable"
	case .Gateway_Timeout:
		return "Gateway Timeout"
	}
	return "Unknown"
}

// Header is a zero-copy view into the request head buffer.
Header :: struct {
	key:   string,
	value: string,
}

eq_ignore_case :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0..<len(a) {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}

// mime_type maps a file path's extension to a content type, with
// "; charset=utf-8" on textual types. Shorthand for mime_type_for(path).
mime_type :: proc(path: string) -> string {
	return mime_type_for(path)
}

// mime_type_for maps a file path's extension to a Content-Type. Extensions
// are matched case-insensitively against the segment after the last '.'
// (never across a '/'); unknown ones become application/octet-stream.
//
// charset decides whether textual types carry "; charset=utf-8". Pass false
// when the caller must emit byte-exact headers (e.g. to mirror uhttpd), and
// true for the browser-friendly default.
mime_type_for :: proc(path: string, charset := true) -> string {
	dot := -1
	for i := len(path) - 1; i >= 0; i -= 1 {
		c := path[i]
		if c == '/' {
			break
		}
		if c == '.' {
			dot = i
			break
		}
	}
	if dot < 0 || dot + 1 >= len(path) {
		return "application/octet-stream"
	}

	// Lowercase into a stack buffer: the table is ASCII and no known
	// extension is longer than this, so no allocation is needed per call.
	raw := path[dot + 1:]
	buf: [16]u8
	if len(raw) > len(buf) {
		return "application/octet-stream"
	}
	n := len(raw)
	for i in 0..<n {
		c := raw[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		buf[i] = c
	}

	switch string(buf[:n]) {
	case "html", "htm":
		return charset ? "text/html; charset=utf-8" : "text/html"
	case "css":
		return charset ? "text/css; charset=utf-8" : "text/css"
	case "js", "mjs":
		return charset ? "text/javascript; charset=utf-8" : "text/javascript"
	case "json":
		return "application/json"
	case "txt", "md", "conf", "log":
		return charset ? "text/plain; charset=utf-8" : "text/plain"
	case "xml":
		return "application/xml"
	case "svg":
		return "image/svg+xml"
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "gif":
		return "image/gif"
	case "bmp":
		return "image/bmp"
	case "webp":
		return "image/webp"
	case "ico":
		return "image/x-icon"
	case "pdf":
		return "application/pdf"
	case "zip":
		return "application/zip"
	case "gz":
		return "application/x-gzip"
	case "tar":
		return "application/x-tar"
	case "mp4":
		return "video/mp4"
	case "mp3":
		return "audio/mpeg"
	case "wav":
		return "audio/x-wav"
	case "wasm":
		return "application/wasm"
	case "woff":
		return "font/woff"
	case "woff2":
		return "font/woff2"
	case "sh":
		return "application/x-shellscript"
	}
	return "application/octet-stream"
}

WEEKDAY_NAMES := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
MONTH_NAMES := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// HTTP_DATE_LEN is the length of an RFC 7231 IMF-fixdate timestamp
// ("Sun, 06 Nov 1994 08:49:37 GMT").
HTTP_DATE_LEN :: 29

/*
http_date_buf renders `t` into `dst` and returns the number of bytes written,
or 0 when the time is not representable.

It writes into a caller-supplied buffer instead of appending to a Buf: the
format is fixed-width, so the growth chain (and the clone that followed it)
was pure overhead on a path every single response takes.
*/
http_date_buf :: proc(t: time.Time, dst: []byte) -> int {
	if len(dst) < HTTP_DATE_LEN {
		return 0
	}
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return 0
	}
	ordinal, err := datetime.date_to_ordinal({dt.year, dt.month, dt.day})
	if err != .None {
		return 0
	}
	wd := datetime.day_of_week(ordinal)

	n := 0
	dst[0] = WEEKDAY_NAMES[int(wd)][0]
	dst[1] = WEEKDAY_NAMES[int(wd)][1]
	dst[2] = WEEKDAY_NAMES[int(wd)][2]
	dst[3] = ','
	dst[4] = ' '
	n = 5
	n += put_padded(dst[n:], u64(dt.day), 2)
	dst[n] = ' '
	n += 1
	month_idx := int(dt.month)
	name := MONTH_NAMES[0]
	if month_idx >= 1 && month_idx <= 12 {
		name = MONTH_NAMES[month_idx - 1]
	}
	dst[n] = name[0]
	dst[n + 1] = name[1]
	dst[n + 2] = name[2]
	n += 3
	dst[n] = ' '
	n += 1
	n += put_padded(dst[n:], u64(dt.year), 4)
	dst[n] = ' '
	n += 1
	n += put_padded(dst[n:], u64(dt.hour), 2)
	dst[n] = ':'
	n += 1
	n += put_padded(dst[n:], u64(dt.minute), 2)
	dst[n] = ':'
	n += 1
	n += put_padded(dst[n:], u64(dt.second), 2)
	dst[n] = ' '
	dst[n + 1] = 'G'
	dst[n + 2] = 'M'
	dst[n + 3] = 'T'
	n += 4
	return n
}

// http_date renders an RFC 7231 IMF-fixdate timestamp, e.g.
// "Sun, 06 Nov 1994 08:49:37 GMT".
http_date :: proc(t: time.Time, allocator := context.allocator) -> string {
	tmp: [HTTP_DATE_LEN]byte
	n := http_date_buf(t, tmp[:])
	if n == 0 {
		return ""
	}
	out := make([]byte, n, allocator)
	copy(out, tmp[:n])
	return string(out)
}

/*
Date_Cache holds the current Date header value for one server.

`response_build` runs once per response, and an IMF-fixdate timestamp changes
at most once a second: formatting it per response (and allocating the string)
was measurable work spent re-deriving the same 29 bytes. The cache is filled
on the first response of each second and then shared by every connection
served by that event loop, which is safe because a Server belongs to exactly
one thread (see threads.odin).
*/
Date_Cache :: struct {
	text:   string, // a view into `buf`, valid while `sec` is current
	sec:    i64,    // unix second the cached text was formatted for
	length: int,
	buf:    [HTTP_DATE_LEN]byte,
}

// server_date returns the Date header value for `now`, reformatting it when
// the second has changed.
//
// The returned string is a view into the cache, so it is only valid until the
// next call on the same server. That is enough here: the only caller stores it
// in a response header and serializes that header in the same event-loop turn
// (response_build), never across a suspension point.
server_date :: proc(s: ^Server, now: time.Time) -> string {
	sec := time.time_to_unix(now)
	if s.date.text == "" || s.date.sec != sec {
		n := http_date_buf(now, s.date.buf[:])
		if n == 0 {
			return ""
		}
		s.date.length = n
		s.date.text = string(s.date.buf[:n])
		s.date.sec = sec
	}
	return s.date.text
}

// put_padded writes v zero-padded to `width` digits into dst and returns the
// count. The buffer is assumed large enough (width <= 20).
put_padded :: proc(dst: []byte, v: u64, width: int) -> int {
	tmp: [20]byte
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
	total := n
	if width > n {
		total = width
	}
	for i := 0; i < total - n; i += 1 {
		dst[i] = '0'
	}
	for i := 0; i < n; i += 1 {
		dst[total - n + i] = tmp[n - 1 - i]
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
