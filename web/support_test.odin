package web

// Fixtures shared by the test files of this package: byte
// literals, a terminal handler and a string repeater.

import "base:intrinsics"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// tb turns a string literal into bytes (transmute needs a typed value).
tb :: proc(s: string) -> []byte {
	return transmute([]byte)s
}

// dummy_handler is a terminal handler: it writes a body, so a test can tell
// "the chain reached the route" from "a middleware answered first".
dummy_handler :: proc(req: ^Request, res: ^Response) {
	response_write_string(res, "ok")
}

// test_repeat builds s repeated n times from allocator.
test_repeat :: proc(s: string, n: int, allocator: mem.Allocator) -> string {
	out := make([]byte, len(s) * n, allocator)
	for i in 0..<n {
		copy(out[i * len(s):], s)
	}
	return string(out)
}
