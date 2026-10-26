package web

// Tests for the static handler's stat cache.

import "core:fmt"
import "core:os"
import "core:testing"


/*
test_static_cache_bounded: the stat cache is bounded, so a client walking a
path space cannot grow it without limit. Negative lookups are cached too (that
is what keeps a 404 flood from becoming a stat storm), which makes an unbounded
cache both a memory leak and an obvious thing for an attacker to do.

What must survive eviction is the *hit* path: a file that keeps being requested
is refreshed on every lookup, so it is never the oldest entry.
*/
@(test)
test_static_cache_bounded :: proc(t: ^testing.T) {
	dir := "/tmp/opus-static-cache-bound"
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	file := concat_strings({dir, "/index.html"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("<html></html>")) == nil)

	st: Static
	static_init(&st, dir, context.allocator)
	defer static_destroy(&st)
	st.cfg.max_cache_entries = 32

	// 500 distinct misses: the cache must stay at or below its limit
	for i in 0 ..< 500 {
		path := fmt.aprintf("%v/missing-%v", dir, i, allocator = context.temp_allocator)
		_, found := static_lookup(&st, path)
		testing.expect(t, !found)
	}
	testing.expectf(t, len(st.cache) <= 32, "cache grew to %v entries", len(st.cache))

	// the real file is still served while the flood is going on
	for _ in 0 ..< 5 {
		entry, found := static_lookup(&st, file)
		testing.expect(t, found && entry.exists)
		testing.expectf(t, entry.size == 13, "size %v", entry.size)
	}
	testing.expectf(t, len(st.cache) <= 32, "cache grew to %v entries after hits", len(st.cache))

	// and the hit path keeps working after the cache has been evicted under it
	for i in 0 ..< 500 {
		path := fmt.aprintf("%v/other-%v", dir, i, allocator = context.temp_allocator)
		static_lookup(&st, path)
	}
	entry2, found2 := static_lookup(&st, file)
	testing.expect(t, found2 && entry2.exists)
}
