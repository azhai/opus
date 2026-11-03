package buffer

// Tests for the HTML escaper.

import "core:mem"
import "core:testing"

@(test)
test_html_escape :: proc(t: ^testing.T) {
	backing: [4096]u8
	ar: mem.Arena
	mem.arena_init(&ar, backing[:])
	old := context.allocator
	context.allocator = mem.arena_allocator(&ar)
	defer context.allocator = old

	testing.expect_value(t, html_escape("plain text"), "plain text")
	testing.expect_value(t, html_escape(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
}
