package web

import "core:mem"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"

/*
Range requests (RFC 7233) for file responses.

The static handler serves single ranges out of the file (`response_send_file_range`,
which streams just that slice) and falls back to an in-memory
`multipart/byteranges` body when a client asks for several ranges at once
(the rare case; slicing per range is not worth the complexity there).

Conditional requests ride along: `Last-Modified` is emitted from the stat
cache, `If-Modified-Since` short-circuits with 304, and `If-Range` decides
whether a range request may be honored at all (date validator only; this
server never emits ETags, so an entity-tag validator never matches).
*/

// MAX_RANGES caps how many byte-range-specs of one header are honored;
// extra specs are ignored (nginx does the same).
MAX_RANGES :: 16

Byte_Range :: struct {
	start:  i64, // first byte position, absolute
	length: i64, // number of bytes to send
}

Range_Decision :: enum {
	Ignore,        // no usable Range header: send the full representation (200)
	Single,        // exactly one satisfiable range (206)
	Multi,         // several satisfiable ranges (206, multipart/byteranges)
	Unsatisfiable, // nothing to send (416)
}

/*
parse_byte_ranges parses a `Range` header value against a representation of
`size` bytes.

Syntax that does not parse at all ("bytes=abc") is ignored per RFC 7233
section 2.1; specs that parse but fall outside the representation make the
request unsatisfiable (416) when none of them are satisfiable.
*/
parse_byte_ranges :: proc(header: string, size: i64) -> (ranges: [MAX_RANGES]Byte_Range, count: int, decision: Range_Decision) {
	eq := string_index_byte(header, '=')
	if eq < 0 {
		return {}, 0, .Ignore
	}
	if !eq_ignore_case(trim_ows(header[:eq]), "bytes") {
		// another range unit (none are registered): ignore
		return {}, 0, .Ignore
	}

	saw_valid_syntax := false
	rest := header[eq + 1:]
	for len(rest) > 0 && count < MAX_RANGES {
		comma := string_index_byte(rest, ',')
		spec := rest
		if comma >= 0 {
			spec = rest[:comma]
			rest = rest[comma + 1:]
		} else {
			rest = ""
		}
		spec = trim_ows(spec)
		if len(spec) == 0 {
			continue
		}
		dash := string_index_byte(spec, '-')
		if dash < 0 {
			continue // not a byte-range-spec: ignore
		}
		first := trim_ows(spec[:dash])
		second := trim_ows(spec[dash + 1:])

		if len(first) == 0 {
			// suffix form: "-<suffix-length>"
			n, ok := parse_i64_strict(second)
			if !ok {
				continue
			}
			saw_valid_syntax = true
			if n == 0 || size == 0 {
				continue // unsatisfiable spec
			}
			length := n
			if length > size {
				length = size
			}
			ranges[count] = Byte_Range{start = size - length, length = length}
			count += 1
			continue
		}

		start, ok1 := parse_i64_strict(first)
		if !ok1 {
			continue
		}
		saw_valid_syntax = true
		if start >= size {
			continue // unsatisfiable spec
		}
		end := size - 1
		if len(second) > 0 {
			e, ok2 := parse_i64_strict(second)
			if !ok2 {
				continue
			}
			if e < start {
				continue // invalid spec (last-byte-pos < first-byte-pos)
			}
			if e < end {
				end = e
			}
		}
		ranges[count] = Byte_Range{start = start, length = end - start + 1}
		count += 1
	}

	switch {
	case count == 0:
		if saw_valid_syntax {
			return {}, 0, .Unsatisfiable
		}
		return {}, 0, .Ignore
	case count == 1:
		return ranges, 1, .Single
	}
	return ranges, count, .Multi
}

// parse_i64_strict parses a non-negative decimal integer, rejecting
// anything else (leading '+', spaces, garbage).
parse_i64_strict :: proc(s: string) -> (i64, bool) {
	if len(s) == 0 || len(s) > 18 {
		return 0, false
	}
	v := i64(0)
	for i in 0..<len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		v = v * 10 + i64(c - '0')
	}
	return v, true
}

// content_range_value renders "bytes <start>-<end>/<size>".
content_range_value :: proc(start, end, size: i64, allocator: mem.Allocator) -> string {
	parts := []string{
		"bytes ",
		int_to_string(start, allocator),
		"-",
		int_to_string(end, allocator),
		"/",
		int_to_string(size, allocator),
	}
	return concat_strings(parts, allocator)
}

// unsatisfiable_content_range renders "bytes */<size>" for 416 responses.
unsatisfiable_content_range :: proc(size: i64, allocator: mem.Allocator) -> string {
	return concat_strings({"bytes */", int_to_string(size, allocator)}, allocator)
}

/*
range_multipart_body renders a multipart/byteranges body for several ranges
of one file. The file is read into memory (the multi-range path trades
zero-copy for correctness); `boundary` must not appear in the payload.
*/
range_multipart_body :: proc(
	path:      string,
	ranges:    []Byte_Range,
	boundary:  string,
	ctype:     string,
	size:      i64,
	allocator: mem.Allocator,
) -> (body: []byte, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return nil, false
	}
	defer os.close(f)

	b: Buf
	buf_init(&b, allocator)
	defer buf_destroy(&b)

	for i in 0..<len(ranges) {
		r := ranges[i]
		buf_append_string(&b, "--")
		buf_append_string(&b, boundary)
		buf_append_string(&b, "\r\nContent-Type: ")
		buf_append_string(&b, ctype)
		buf_append_string(&b, "\r\nContent-Range: bytes ")
		buf_append_string(&b, int_to_string(r.start, allocator))
		buf_append_string(&b, "-")
		buf_append_string(&b, int_to_string(r.start + r.length - 1, allocator))
		buf_append_string(&b, "/")
		buf_append_string(&b, int_to_string(size, allocator))
		buf_append_string(&b, "\r\n\r\n")

		chunk := make([]byte, r.length, allocator)
		n, rerr := os.read_at(f, chunk, r.start)
		if rerr != nil || i64(n) != r.length {
			return nil, false
		}
		buf_append(&b, chunk)
		buf_append_string(&b, "\r\n")
	}
	buf_append_string(&b, "--")
	buf_append_string(&b, boundary)
	buf_append_string(&b, "--\r\n")

	body = clone_bytes(buf_slice(&b), allocator)
	return body, true
}

// multipart_boundary derives a per-response boundary from the current time
// plus a process-lifetime counter; RFC 2046 requires it to be unique per
// message, which a nanosecond timestamp plus a counter is.
MULTIPART_COUNTER: int

multipart_boundary :: proc(allocator: mem.Allocator) -> string {
	MULTIPART_COUNTER += 1
	// nanosecond clock plus a counter: unique per message within a process
	_, _, _, nanos := time.precise_clock_from_time(time.now())
	parts := []string{
		"SEPARATOR-",
		int_to_string(i64(nanos), allocator),
		"-",
		int_to_string(i64(MULTIPART_COUNTER), allocator),
	}
	return concat_strings(parts, allocator)
}

/*
parse_http_date parses the three HTTP-date formats (RFC 7231 section 7.1.1:
IMF-fixdate, RFC 850, asctime) into a UTC timestamp.
*/
parse_http_date :: proc(v: string) -> (time.Time, bool) {
	s := trim_ows(v)
	if len(s) < 20 {
		return {}, false
	}
	// asctime: "Sun Nov  6 08:49:37 1994"
	if string_index_byte(s, ',') < 0 && string_index_byte(s, '-') < 0 {
		return parse_asctime_date(s)
	}
	if string_index_byte(s, '-') >= 0 && !strings.has_prefix(s, "Mon,") {
		// RFC 850: "Sunday, 06-Nov-94 08:49:37 GMT" (contains dashes)
		if d, ok := parse_rfc850_date(s); ok {
			return d, true
		}
	}
	return parse_imf_date(s)
}

// parse_imf_date parses "Sun, 06 Nov 1994 08:49:37 GMT".
parse_imf_date :: proc(s: string) -> (time.Time, bool) {
	comma := string_index_byte(s, ',')
	if comma < 0 {
		return {}, false
	}
	rest := trim_ows(s[comma + 1:])
	// "06 Nov 1994 08:49:37 GMT"
	sp1 := string_index_byte(rest, ' ')
	if sp1 < 0 {
		return {}, false
	}
	day, ok1 := parse_i64_strict(rest[:sp1])
	rest = trim_ows(rest[sp1 + 1:])
	sp2 := string_index_byte(rest, ' ')
	if sp2 < 0 {
		return {}, false
	}
	month := month_from_name(rest[:sp2])
	if month < 1 {
		return {}, false
	}
	rest = trim_ows(rest[sp2 + 1:])
	sp3 := string_index_byte(rest, ' ')
	if sp3 < 0 {
		return {}, false
	}
	year, ok2 := parse_i64_strict(rest[:sp3])
	rest = trim_ows(rest[sp3 + 1:])
	if !ok1 || !ok2 || day < 1 || day > 31 || year < 1601 || year > 9999 {
		return {}, false
	}
	return finish_time(year, i64(month), day, rest)
}

// parse_rfc850_date parses "Sunday, 06-Nov-94 08:49:37 GMT".
parse_rfc850_date :: proc(s: string) -> (time.Time, bool) {
	comma := string_index_byte(s, ',')
	if comma < 0 {
		return {}, false
	}
	rest := trim_ows(s[comma + 1:])
	d1 := string_index_byte(rest, '-')
	if d1 < 0 {
		return {}, false
	}
	day, ok1 := parse_i64_strict(rest[:d1])
	d2 := string_index_byte_from(rest, '-', d1 + 1)
	if d2 < 0 {
		return {}, false
	}
	month := month_from_name(rest[d1 + 1:d2])
	if month < 1 {
		return {}, false
	}
	rest = trim_ows(rest[d2 + 1:])
	sp := string_index_byte(rest, ' ')
	if sp < 0 {
		return {}, false
	}
	year2, ok2 := parse_i64_strict(rest[:sp])
	rest = trim_ows(rest[sp + 1:])
	if !ok1 || !ok2 || day < 1 || day > 31 || year2 < 0 || year2 > 99 {
		return {}, false
	}
	// two-digit years: 00-68 are 2000s, 69-99 are 1900s (RFC 7231 says to
	// interpret a recipient that parses this obsolete format as > current)
	year := year2 + 2000
	if year2 >= 69 {
		year = year2 + 1900
	}
	return finish_time(year, i64(month), day, rest)
}

// parse_asctime_date parses "Sun Nov  6 08:49:37 1994".
parse_asctime_date :: proc(s: string) -> (time.Time, bool) {
	sp1 := string_index_byte(s, ' ')
	if sp1 < 0 {
		return {}, false
	}
	rest := trim_ows(s[sp1 + 1:])
	sp2 := string_index_byte(rest, ' ')
	if sp2 < 0 {
		return {}, false
	}
	month := month_from_name(rest[:sp2])
	if month < 1 {
		return {}, false
	}
	rest = trim_ows(rest[sp2 + 1:])
	sp3 := string_index_byte(rest, ' ')
	if sp3 < 0 {
		return {}, false
	}
	day, ok1 := parse_i64_strict(rest[:sp3])
	rest = trim_ows(rest[sp3 + 1:])
	sp4 := string_index_byte(rest, ' ')
	if sp4 < 0 {
		return {}, false
	}
	year, ok2 := parse_i64_strict(rest[sp4 + 1:])
	if !ok1 || !ok2 || day < 1 || day > 31 {
		return {}, false
	}
	return finish_time(year, i64(month), day, rest[:sp4])
}

// finish_time completes a parsed "HH:MM:SS" plus Y/M/D into a Time.
finish_time :: proc(year, month, day: i64, hms_in: string) -> (time.Time, bool) {
	hms := trim_ows(hms_in)
	c1 := string_index_byte(hms, ':')
	if c1 < 0 {
		return {}, false
	}
	hour, ok1 := parse_i64_strict(hms[:c1])
	c2 := string_index_byte_from(hms, ':', c1 + 1)
	if c2 < 0 {
		return {}, false
	}
	minute, ok2 := parse_i64_strict(hms[c1 + 1:c2])
	// seconds may be followed by " GMT" or junk; cut at the first space
	rest := hms[c2 + 1:]
	if sp := string_index_byte(rest, ' '); sp >= 0 {
		rest = rest[:sp]
	}
	second, ok3 := parse_i64_strict(rest)
	if !ok1 || !ok2 || !ok3 || hour > 23 || minute > 59 || second > 60 {
		return {}, false
	}
	ordinal, err := datetime.components_to_ordinal(year, i8(month), i8(day))
	if err != .None {
		return {}, false
	}
	epoch_ordinal, eerr := datetime.components_to_ordinal(1970, 1, 1)
	if eerr != .None {
		return {}, false
	}
	secs := i64(ordinal - epoch_ordinal) * 86400 + hour * 3600 + minute * 60 + second
	return time.unix(secs, 0), true
}

// month_from_name maps a three-letter month name to 1..12 (case-insensitive).
month_from_name :: proc(s: string) -> int {
	if len(s) < 3 {
		return 0
	}
	key := []byte{lower_ascii(s[0]), lower_ascii(s[1]), lower_ascii(s[2])}
	switch string(key) {
	case "jan":
		return 1
	case "feb":
		return 2
	case "mar":
		return 3
	case "apr":
		return 4
	case "may":
		return 5
	case "jun":
		return 6
	case "jul":
		return 7
	case "aug":
		return 8
	case "sep":
		return 9
	case "oct":
		return 10
	case "nov":
		return 11
	case "dec":
		return 12
	}
	return 0
}

/*
if_range_allowed applies the If-Range validator (RFC 7233 section 3.2).

Only the date form is honored: an entity tag never matches because this
server does not emit ETags. A matching validator means the representation
is unchanged and the Range header may be applied.
*/
if_range_allowed :: proc(header: string, mod_utc: time.Time) -> bool {
	if len(header) > 0 && header[0] == '"' {
		return false // entity-tag validator: never matches (no ETags)
	}
	t, ok := parse_http_date(header)
	if !ok {
		return false
	}
	// diff(mod, t) >= 0 means t >= mod: unchanged since the client's copy
	return time.diff(mod_utc, t) >= 0
}
