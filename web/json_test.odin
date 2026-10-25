#+feature dynamic-literals
package web

// Tests for JSON responses.

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
// json
// ---------------------------------------------------------------------------

@(test)
test_json_response :: proc(t: ^testing.T) {
	c := test_conn_new(t)
	defer test_conn_destroy(c)
	w := &c.res

	payload := map[string]string{"hello" = "world"}
	defer delete(payload)
	err := response_json(w, payload)
	testing.expect(t, err == nil)
	ct, has_ct := response_header(w, "Content-Type")
	testing.expect(t, has_ct)
	testing.expect(t, ct == "application/json")

	out: Buf
	buf_init(&out, context.allocator)
	defer buf_destroy(&out)
	response_build(w, &out, conn_scratch(c))
	resp := string(buf_slice(&out))
	testing.expect(t, strings.contains(resp, "Content-Type: application/json\r\n"))
	testing.expect(t, strings.has_suffix(resp, "{\"hello\":\"world\"}"))

	// nested structures marshal too
	response_reset(w, c, conn_scratch(c))
	Nested :: struct {
		name:  string,
		tags:  []string,
		count: int,
	}
	err2 := response_json(w, Nested{name = "x", tags = {"a", "b"}, count = 2})
	testing.expect(t, err2 == nil)
	testing.expect(t, strings.contains(string(buf_slice(&w.body)), "\"tags\":[\"a\",\"b\"]"))
}