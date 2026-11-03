package http

// Tests for cookie serialization: attribute order, quoting rules and the
// Max-Age/Expires interaction.

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_cookie_serialize :: proc(t: ^testing.T) {
	// serialize on a stack arena: cookie_string allocates per attribute
	arena_buf: [8 << 10]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_buf[:])
	alloc := mem.arena_allocator(&arena)

	// minimal: name=value only
	minimal := cookie_string(Cookie{name = "a", value = "b"}, alloc)
	testing.expect(t, minimal == "a=b")

	// full attribute set
	full := cookie_string(Cookie{
		name         = "session",
		value        = "abc",
		path         = "/app",
		domain       = "example.com",
		expires      = time.unix(784111777, 0), // 1994-11-06 08:49:37 UTC
		max_age_secs = 3600,
		secure       = true,
		http_only    = true,
		same_site    = .Lax,
	}, alloc)
	testing.expect(t, strings.has_prefix(full, "session=abc; "))
	testing.expect(t, strings.contains(full, "Path=/app"))
	testing.expect(t, strings.contains(full, "Domain=example.com"))
	testing.expect(t, strings.contains(full, "Expires=Sun, 06 Nov 1994 08:49:37 GMT"))
	testing.expect(t, strings.contains(full, "Max-Age=3600"))
	testing.expect(t, strings.contains(full, "Secure"))
	testing.expect(t, strings.contains(full, "HttpOnly"))
	testing.expect(t, strings.contains(full, "SameSite=Lax"))
	testing.expect(t, strings.has_suffix(full, "SameSite=Lax"))

	// zero expires / unset same-site are omitted
	bare := cookie_string(Cookie{name = "x", value = "y"}, alloc)
	testing.expect(t, !strings.contains(bare, "Expires"))
	testing.expect(t, !strings.contains(bare, "SameSite"))
	testing.expect(t, !strings.contains(bare, "Max-Age"))

	// empty name serializes to nothing
	testing.expect(t, cookie_string(Cookie{value = "v"}, alloc) == "")

	// strict / none variants
	strict := cookie_string(Cookie{name = "a", value = "b", same_site = .Strict}, alloc)
	testing.expect(t, strings.has_suffix(strict, "SameSite=Strict"))
	none := cookie_string(Cookie{name = "a", value = "b", same_site = .None}, alloc)
	testing.expect(t, strings.has_suffix(none, "SameSite=None"))
}
