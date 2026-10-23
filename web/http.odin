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
	Not_Modified        = 304,
	Bad_Request         = 400,
	Unauthorized        = 401,
	Forbidden           = 403,
	Not_Found           = 404,
	Method_Not_Allowed  = 405,
	Not_Acceptable      = 406,
	Request_Timeout     = 408,
	Conflict            = 409,
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
	case .Not_Modified:
		return "Not Modified"
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

// mime_type maps a file extension to a content type.
mime_type :: proc(path: string) -> string {
	// find the last '.' after the last '/'
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
	if dot < 0 {
		return "application/octet-stream"
	}
	ext := path[dot:]
	switch ext {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "text/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".txt", ".md":
		return "text/plain; charset=utf-8"
	case ".xml":
		return "application/xml"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".ico":
		return "image/x-icon"
	case ".pdf":
		return "application/pdf"
	case ".zip":
		return "application/zip"
	case ".wasm":
		return "application/wasm"
	case ".woff":
		return "font/woff"
	case ".woff2":
		return "font/woff2"
	}
	return "application/octet-stream"
}

WEEKDAY_NAMES := [?]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
MONTH_NAMES := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// http_date renders an RFC 7231 IMF-fixdate timestamp, e.g.
// "Sun, 06 Nov 1994 08:49:37 GMT".
http_date :: proc(t: time.Time, allocator := context.allocator) -> string {
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return ""
	}
	ordinal, err := datetime.date_to_ordinal({dt.year, dt.month, dt.day})
	if err != .None {
		return ""
	}
	wd := datetime.day_of_week(ordinal)
	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)
	buf_append_string(&b, WEEKDAY_NAMES[int(wd)])
	buf_append_string(&b, ", ")
	write_padded_u64(&b, u64(dt.day), 2)
	buf_append_byte(&b, ' ')
	month_idx := int(dt.month)
	if month_idx >= 1 && month_idx <= 12 {
		buf_append_string(&b, MONTH_NAMES[month_idx - 1])
	} else {
		buf_append_string(&b, "Jan")
	}
	buf_append_byte(&b, ' ')
	write_padded_i64(&b, dt.year, 4)
	buf_append_string(&b, " ")
	write_padded_i64(&b, i64(dt.hour), 2)
	buf_append_byte(&b, ':')
	write_padded_i64(&b, i64(dt.minute), 2)
	buf_append_byte(&b, ':')
	write_padded_i64(&b, i64(dt.second), 2)
	buf_append_string(&b, " GMT")
	return clone_string(string(buf_slice(&b)), allocator)
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
