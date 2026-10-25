package web

import "core:mem"

// html_escape replaces the five characters that change HTML parsing
// (& < > " ') with entities. Storage comes from `allocator`; the input is
// returned as a view when nothing needs escaping. Callers own the result.
html_escape :: proc(s: string, allocator: mem.Allocator = context.allocator) -> string {
	needs := false
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '<', '>', '&', '"', '\'':
			needs = true
		}
		if needs {
			break
		}
	}
	if !needs {
		return s
	}

	out := make([dynamic]u8, allocator)
	for i := 0; i < len(s); i += 1 {
		switch s[i] {
		case '<':
			append(&out, "&lt;")
		case '>':
			append(&out, "&gt;")
		case '&':
			append(&out, "&amp;")
		case '"':
			append(&out, "&quot;")
		case '\'':
			append(&out, "&#39;")
		case:
			append(&out, s[i])
		}
	}
	return string(out[:])
}
