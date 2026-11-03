package pattern

// The engine on its own, with no router anywhere near it: this is the part
// that has to be right about Lua's semantics.

import "core:testing"

@(test)
test_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern: string,
		subject: string,
		match:   bool,
		caps:    []string,
	}
	cases := []Case {
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/42", true, {"john", "42"}},
		{"/users/(%w+)/comments/(%d+)", "/users/john/comments/4x", false, nil},
		{"/x/(%d+)", "/x/42", true, {"42"}},
		{"/x/(%d+)", "/x/abc", false, nil},
		{"/static/(.-)%.html", "/static/a/b.html", true, {"a/b"}},
		{"/x/[a-c]+", "/x/abc", true, nil},
		{"/x/[a-c]+", "/x/abcd", false, nil},
		{"/x/[^0-9]+", "/x/abc", true, nil},
		{"/x/[^0-9]+", "/x/ab1", false, nil},
		{"^/api/(%w+)$", "/api/hello", true, {"hello"}},
		{"/x/(%w+)", "/x/a/b", false, nil}, // anchored to the whole subject
		{"/x/(%w*)", "/x/", true, {""}},    // zero-width capture
		{"/x/(", "/x/a", false, nil},       // malformed pattern
		{"/x/(a)(b)", "/x/ab", true, {"a", "b"}},
		{"/x/(a)+", "/x/aaa", true, {"a"}}, // group quantifier keeps the last rep
		{"/x/(a)*", "/x/aaa", true, {"a"}},
		{"/x/(a)?", "/x/", true, {""}},
		{"/x/(a)?", "/x/a", true, {"a"}},
		{"/x/(.-)end", "/x/aaaend", true, {"aaa"}}, // lazy
		{"/x/(%d+)1", "/x/121", true, {"12"}},      // backtracking inside a class
		{"/a.b", "/axb", true, nil},                // '.' is any char
		{"/a%.b", "/a.b", true, nil},               // '%' escapes a literal
		{"/a%.b", "/axb", false, nil},
		{"/v1.0/status", "/v1.0/status", true, nil},
	}
	for cse in cases {
		captures: [dynamic]string
		defer delete(captures)
		got := match(cse.pattern, cse.subject, &captures)
		testing.expectf(t, got == cse.match, "pattern %q vs %q: expected %v, got %v", cse.pattern, cse.subject, cse.match, got)
		if got && cse.match {
			testing.expectf(t, len(captures) == len(cse.caps), "pattern %q vs %q: expected %v captures, got %v", cse.pattern, cse.subject, len(cse.caps), len(captures))
			for i in 0..<len(cse.caps) {
				if i < len(captures) {
					testing.expectf(t, captures[i] == cse.caps[i], "pattern %q vs %q: capture %d expected %q, got %q", cse.pattern, cse.subject, i + 1, cse.caps[i], captures[i])
				}
			}
		}
	}
}

@(test)
test_has_syntax :: proc(t: ^testing.T) {
	// A literal '.' must not opt in: that is what keeps "/v1.0/status" on the
	// cheaper segment matcher.
	testing.expect(t, !has_syntax("/v1.0/status"))
	testing.expect(t, !has_syntax("/users/:id/posts/*"))
	testing.expect(t, has_syntax("/x/(%d+)"))
	testing.expect(t, has_syntax("/x/%a+"))
	testing.expect(t, has_syntax("/x/[a-z]+"))
}

@(test)
test_match_clears_captures :: proc(t: ^testing.T) {
	// A caller reuses one capture list per request; a non-matching pattern must
	// not leave the previous match's groups behind.
	captures: [dynamic]string
	defer delete(captures)
	testing.expect(t, match("/(%a+)", "/abc", &captures))
	testing.expect(t, len(captures) == 1)
	testing.expect(t, !match("/(%d+)", "/abc", &captures))
	testing.expect(t, len(captures) == 1) // untouched: match only clears on success
}

@(test)
test_match_budget :: proc(t: ^testing.T) {
	// The step budget is what stops a pathological pattern from hanging the
	// event loop. Nested quantifiers over a long subject cannot match, so this
	// has to come back false quickly rather than explore the whole space.
	subject := "/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	captures: [dynamic]string
	defer delete(captures)
	testing.expect(t, !match("/(%a*)(%a*)(%a*)x", subject, &captures))
}
