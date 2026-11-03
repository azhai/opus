package http

// urlencoded decoding: the media type browsers use for query strings and for
// forms without a file part.
//
// Every case decodes into one arena, because names and values are individually
// allocated (a decoded string is not a view into the source) and a request
// lives on the connection arena for exactly that reason.

import "core:mem"
import "core:testing"

urlencoded_arena :: proc(arena: ^mem.Arena, buf: []byte) -> mem.Allocator {
	mem.arena_init(arena, buf)
	return mem.arena_allocator(arena)
}

@(test)
test_form_parse :: proc(t: ^testing.T) {
	arena_buf: [8 << 10]byte
	arena: mem.Arena
	alloc := urlencoded_arena(&arena, arena_buf[:])

	Case :: struct {
		body:   string,
		names:  []string,
		values: []string,
	}
	cases := []Case {
		{"a=1&b=2", {"a", "b"}, {"1", "2"}},
		// '+' is a space in a query string and in a form body alike
		{"q=hello+world", {"q"}, {"hello world"}},
		{"q=%E4%BD%A0%E5%A5%BD", {"q"}, {"你好"}},
		// a key without '=' maps to an empty value, not to a dropped pair
		{"flag&a=1", {"flag", "a"}, {"", "1"}},
		// empty segments are skipped, including a trailing '&'
		{"a=1&&b=2&", {"a", "b"}, {"1", "2"}},
		// a malformed escape stays literal: what a browser would have sent
		{"a=%zz", {"a"}, {"%zz"}},
		{"a=", {"a"}, {""}},
		{"", nil, nil},
	}
	for cse in cases {
		got := form_parse(cse.body, alloc)
		testing.expectf(t, len(got) == len(cse.names), "body %q: expected %v pairs, got %v", cse.body, len(cse.names), len(got))
		for i in 0 ..< min(len(got), len(cse.names)) {
			testing.expectf(t, got[i].name == cse.names[i], "body %q: pair %v name expected %q, got %q", cse.body, i, cse.names[i], got[i].name)
			testing.expectf(t, got[i].value == cse.values[i], "body %q: pair %v value expected %q, got %q", cse.body, i, cse.values[i], got[i].value)
		}
	}
}

@(test)
test_query_param :: proc(t: ^testing.T) {
	arena_buf: [4 << 10]byte
	arena: mem.Arena
	alloc := urlencoded_arena(&arena, arena_buf[:])

	q := "a=1&b=two&b=three&c"

	v, ok := query_param(q, "b", alloc)
	testing.expect(t, ok && v == "two") // first wins

	_, missing := query_param(q, "zzz", alloc)
	testing.expect(t, !missing)

	// a key without '=' is not addressable, and neither is an empty query
	_, no_value := query_param(q, "c", alloc)
	testing.expect(t, !no_value)
	_, empty := query_param("", "a", alloc)
	testing.expect(t, !empty)

	// keys compare after decoding: "%61" is "a"
	v2, ok2 := query_param("%61=1", "a", alloc)
	testing.expect(t, ok2 && v2 == "1")

	all := query_param_all(q, "b", alloc)
	testing.expect(t, len(all) == 2 && all[0] == "two" && all[1] == "three")
}

@(test)
test_param_get :: proc(t: ^testing.T) {
	params := []Param{{name = "a", value = "1"}, {name = "b", value = "2"}}
	v, ok := param_get(params, "b")
	testing.expect(t, ok && v == "2")
	_, missing := param_get(params, "c")
	testing.expect(t, !missing)
}
