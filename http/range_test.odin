package http

// Tests for the range layer: byte-range parsing, HTTP-date parsing, the
// If-Range check, boundary uniqueness under concurrency, and the ownership of
// the multipart body builder.

import "core:mem"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../buffer"
import "core:os"

@(test)
test_parse_byte_ranges :: proc(t: ^testing.T) {
	Case :: struct {
		header:   string,
		size:     i64,
		count:    int,
		decision: Range_Decision,
		first:    Byte_Range,
	}
	cases := []Case{
		{"bytes=0-4", 26, 1, .Single, Byte_Range{0, 5}},
		{"bytes=10-", 26, 1, .Single, Byte_Range{10, 16}},
		{"bytes=-5", 26, 1, .Single, Byte_Range{21, 5}},
		{"bytes=-100", 26, 1, .Single, Byte_Range{0, 26}}, // suffix past EOF
		{"bytes=0-1,3-4", 26, 2, .Multi, Byte_Range{0, 2}},
		{"bytes=20-100", 26, 1, .Single, Byte_Range{20, 6}}, // end clipped to size-1
		{"bytes=0-0", 26, 1, .Single, Byte_Range{0, 1}},
		{"bytes=100-200", 26, 0, .Unsatisfiable, {}},
		{"bytes=-0", 26, 0, .Unsatisfiable, {}},
		{"bytes=5-3", 26, 0, .Unsatisfiable, {}}, // last < first: dropped
		{"bytes=abc", 26, 0, .Ignore, {}},        // not a byte-range-set at all
		{"bytes=0-1,garbage", 26, 1, .Single, Byte_Range{0, 2}},
		{"items=0-4", 26, 0, .Ignore, {}}, // foreign unit
		{"bytes=0-1", 0, 0, .Unsatisfiable, {}},
	}
	for cse in cases {
		ranges, count, decision := parse_byte_ranges(cse.header, cse.size)
		testing.expectf(t, decision == cse.decision, "%q vs size %d: expected %v, got %v", cse.header, cse.size, cse.decision, decision)
		testing.expectf(t, count == cse.count, "%q vs size %d: expected %d ranges, got %d", cse.header, cse.size, cse.count, count)
		if count > 0 {
			testing.expectf(t, ranges[0] == cse.first, "%q: expected first range %v, got %v", cse.header, cse.first, ranges[0])
		}
	}
}

@(test)
test_parse_http_date :: proc(t: ^testing.T) {
	// 1994-11-06 08:49:37 UTC in all three formats
	tm, ok := parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT")
	testing.expect(t, ok)
	testing.expect(t, time.diff(tm, time.unix(784111777, 0)) == 0)

	tm2, ok2 := parse_http_date("Sunday, 06-Nov-94 08:49:37 GMT")
	testing.expect(t, ok2)
	testing.expect(t, time.diff(tm2, tm) == 0)

	tm3, ok3 := parse_http_date("Sun Nov  6 08:49:37 1994")
	testing.expect(t, ok3)
	testing.expect(t, time.diff(tm3, tm) == 0)

	// case-insensitive month, extra whitespace
	tm4, ok4 := parse_http_date("sun, 06 nov 1994 08:49:37 gmt")
	testing.expect(t, ok4)
	testing.expect(t, time.diff(tm4, tm) == 0)

	// garbage
	_, ok5 := parse_http_date("not a date at all")
	testing.expect(t, !ok5)
	_, ok6 := parse_http_date("")
	testing.expect(t, !ok6)
}

@(test)
test_if_range_allowed :: proc(t: ^testing.T) {
	mod := time.unix(784111777, 0)
	// a later date means "unchanged since": the range applies
	testing.expect(t, if_range_allowed("Mon, 07 Nov 1994 00:00:00 GMT", mod))
	// an earlier date means it changed: full response
	testing.expect(t, !if_range_allowed("Sun, 06 Nov 1994 07:00:00 GMT", mod))
	// entity tags never match: this server emits no ETags
	testing.expect(t, !if_range_allowed("\"abc123\"", mod))
}

@(test)
test_multipart_boundary_concurrent :: proc(t: ^testing.T) {
	bt := Boundary_Test{alloc = context.allocator}
	defer {
		for s in bt.ids {
			delete(s, context.allocator)
		}
		delete(bt.ids)
	}

	threads := make([]^thread.Thread, BOUNDARY_TEST_LANES, context.allocator)
	defer delete(threads, context.allocator)
	for i in 0 ..< BOUNDARY_TEST_LANES {
		threads[i] = thread.create(boundary_test_thread_proc)
		threads[i].data = &bt
		thread.start(threads[i])
	}
	for i in 0 ..< BOUNDARY_TEST_LANES {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}

	testing.expect_value(t, len(bt.ids), BOUNDARY_TEST_LANES * BOUNDARY_TEST_PER_LANE)
	n_distinct := 0
	for i in 0 ..< len(bt.ids) {
		counter := boundary_counter_of(bt.ids[i])
		unique := true
		for j in 0 ..< i {
			if boundary_counter_of(bt.ids[j]) == counter {
				unique = false
				break
			}
		}
		if unique {
			n_distinct += 1
		}
	}
	testing.expectf(
		t,
		n_distinct == len(bt.ids),
		"%v of %v boundary counters were distinct",
		n_distinct,
		len(bt.ids),
	)
}

@(test)
test_range_multipart_body_releases :: proc(t: ^testing.T) {
	file := "/tmp/web_test_multipart_body.txt"
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("0123456789abcdef")) == nil)
	defer os.remove(file)

	ranges := []Byte_Range{{start = 0, length = 3}, {start = 8, length = 3}}
	body, ok := range_multipart_body(file, ranges, "SEPARATOR-1", "text/plain", 16, context.allocator)
	testing.expect(t, ok)
	defer delete(body, context.allocator)

	text := string(body)
	testing.expect(t, strings.contains(text, "Content-Range: bytes 0-2/16"))
	testing.expect(t, strings.contains(text, "Content-Range: bytes 8-10/16"))
	testing.expect(t, strings.contains(text, "\r\n\r\n012"))
	testing.expect(t, strings.contains(text, "\r\n\r\n89a"))
	testing.expect(t, strings.has_suffix(text, "--SEPARATOR-1--\r\n"))
}

BOUNDARY_TEST_LANES :: 8
BOUNDARY_TEST_PER_LANE :: 500

Boundary_Test :: struct {
	mu:    sync.Mutex,
	ids:   [dynamic]string,
	alloc: mem.Allocator,
}

boundary_test_thread_proc :: proc(th: ^thread.Thread) {
	bt := cast(^Boundary_Test) th.data
	local := make([dynamic]string, bt.alloc)
	for i in 0 ..< BOUNDARY_TEST_PER_LANE {
		append(&local, multipart_boundary(bt.alloc))
	}
	sync.mutex_lock(&bt.mu)
	append(&bt.ids, ..local[:])
	sync.mutex_unlock(&bt.mu)
	delete(local)
}

// boundary_counter_of returns the counter part of "SEPARATOR-<nanos>-<n>".
boundary_counter_of :: proc(s: string) -> string {
	last := -1
	for i in 0 ..< len(s) {
		if s[i] == '-' {
			last = i
		}
	}
	if last < 0 {
		return s
	}
	return s[last + 1:]
}
