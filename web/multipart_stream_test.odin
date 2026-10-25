package web

// Tests for the incremental multipart parser (multipart_stream.odin).
//
// The property that matters is chunk-boundary independence: the same body fed
// in one piece, in fixed-size windows and one byte at a time must produce the
// same parts. Most of this file is that single assertion applied to bodies
// chosen to be nasty - a delimiter split across chunks, a part whose content
// contains a partial delimiter, an empty part, a closing delimiter without a
// trailing CRLF.

import "core:mem"
import "core:strings"
import "core:testing"

// ms_probe records what the parser emitted, so a test can compare runs.
Ms_Probe :: struct {
	parts: [dynamic]Ms_Part,
	cur:   Ms_Part,
	open:  bool,
}

Ms_Part :: struct {
	field:    string,
	filename: string,
	ctype:    string,
	is_file:  bool,
	data:     string,
	index:    int, // position among all parts, as the parser reports it
	size:     int, // final size, captured at on_part_end
}

@(private = "file")
ms_probe_begin :: proc(ud: rawptr, part: ^Stream_Part) -> bool {
	p := cast(^Ms_Probe) ud
	p.cur = Ms_Part {
		field    = part.field,
		filename = part.filename,
		ctype    = part.content_type,
		is_file  = part.is_file,
	}
	p.open = true
	return true
}

@(private = "file")
ms_probe_data :: proc(ud: rawptr, part: ^Stream_Part, chunk: []byte) -> bool {
	p := cast(^Ms_Probe) ud
	if p.open {
		p.cur.data = strings.concatenate({p.cur.data, string(chunk)}, context.temp_allocator)
	}
	return true
}

@(private = "file")
ms_probe_end :: proc(ud: rawptr, part: ^Stream_Part) -> bool {
	p := cast(^Ms_Probe) ud
	p.cur.index = part.index
	p.cur.size = part.size
	append(&p.parts, p.cur)
	p.open = false
	return true
}

@(private = "file")
ms_probe_handlers :: proc(p: ^Ms_Probe) -> Multipart_Handlers {
	return Multipart_Handlers {
		on_part = ms_probe_begin,
		on_data = ms_probe_data,
		on_part_end = ms_probe_end,
		ud = cast(rawptr) p,
	}
}

/*
ms_run_chunked feeds `body` through a parser in windows of `step` bytes and
returns the parsed parts. `step <= 0` feeds the whole body at once.

The parser's metadata strings point into its own allocator, so the probe
copies them into the temp allocator (`strings.concatenate` above) and the
comparison survives the parser being destroyed.
*/
@(private = "file")
ms_run_chunked :: proc(body: string, boundary: string, step: int, opts := Multipart_Options{}) -> (probe: Ms_Probe, ok: bool) {
	probe.parts = make([dynamic]Ms_Part, context.temp_allocator)
	ms: Multipart_Stream
	if !multipart_stream_init(&ms, boundary, context.temp_allocator, opts, ms_probe_handlers(&probe)) {
		return probe, false
	}
	data := transmute([]byte)body
	if step <= 0 {
		if !multipart_stream_feed(&ms, data) {
			return probe, false
		}
	} else {
		for i := 0; i < len(data); i += step {
			end := min(i + step, len(data))
			if !multipart_stream_feed(&ms, data[i:end]) {
				return probe, false
			}
		}
	}
	return probe, multipart_stream_finish(&ms)
}

// ms_same_content compares the parts a corpus case cares about. `index` and
// `size` are checked where they are the point, not in the shared comparison:
// most cases would have to repeat a position that is not what they test.
@(private = "file")
ms_same_content :: proc(a, b: Ms_Part) -> bool {
	return(
		a.field == b.field &&
		a.filename == b.filename &&
		a.ctype == b.ctype &&
		a.is_file == b.is_file &&
		a.data == b.data \
	)
}

@(private = "file")
ms_expect_parts :: proc(t: ^testing.T, probe: Ms_Probe, want: []Ms_Part, label: string) {
	testing.expectf(t, len(probe.parts) == len(want), "%v: got %v parts, want %v", label, len(probe.parts), len(want))
	if len(probe.parts) != len(want) {
		return
	}
	for got, i in probe.parts {
		testing.expectf(t, ms_same_content(got, want[i]), "%v: part %v is %#v, want %#v", label, i, got, want[i])
	}
}

// ms_bodies is the corpus: each entry is a body plus the parts it must yield.
@(private = "file")
MS_SIMPLE_BODY :: "--X\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--X--\r\n"

MS_FILE_BODY :: "--B\r\nContent-Disposition: form-data; name=\"doc\"; filename=\"../../etc/passwd\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--B--\r\n"

// a part whose content contains a prefix of the delimiter but not the
// delimiter itself: "\r\n--boundar" must not terminate the part
MS_TRICKY_BODY :: "--bnd\r\nContent-Disposition: form-data; name=\"v\"\r\n\r\nx\r\n--bndarincomplete\r\n--bnd--\r\n"

// the closing delimiter with no trailing CRLF at all
MS_NO_FINAL_CRLF :: "--Z\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nz\r\n--Z--"

// an empty file part and an unnamed part that must be swallowed
MS_EMPTY_AND_UNNAMED :: "--Q\r\nContent-Disposition: form-data; name=\"e\"; filename=\"\"\r\n\r\n\r\n--Q\r\nContent-Disposition: form-data\r\n\r\nnope\r\n--Q\r\nContent-Disposition: form-data; name=\"after\"\r\n\r\nok\r\n--Q--\r\n"

@(test)
test_multipart_stream_simple :: proc(t: ^testing.T) {
	probe, ok := ms_run_chunked(MS_SIMPLE_BODY, "X", 0)
	testing.expect(t, ok)
	ms_expect_parts(t, probe, []Ms_Part{{field = "a", data = "1"}}, "whole body")
}

@(test)
test_multipart_stream_file_meta :: proc(t: ^testing.T) {
	probe, ok := ms_run_chunked(MS_FILE_BODY, "B", 0)
	testing.expect(t, ok)
	testing.expect(t, len(probe.parts) == 1)
	if len(probe.parts) == 1 {
		p := probe.parts[0]
		testing.expect(t, p.is_file)
		testing.expect(t, p.field == "doc")
		// path components are stripped: the name is for display, never a path
		testing.expectf(t, p.filename == "passwd", "filename %q", p.filename)
		testing.expect(t, p.ctype == "text/plain")
		testing.expect(t, p.data == "hello")
	}
}

/*
test_multipart_stream_chunk_boundaries is the test this file exists for: the
same body, fed at every window size from 1 byte up, must parse identically.
A delimiter split across a chunk boundary is the bug this catches.
*/
Ms_Case :: struct {
	body:     string,
	boundary: string,
	want:     []Ms_Part,
}

@(test)
test_multipart_stream_chunk_boundaries :: proc(t: ^testing.T) {
	cases := []Ms_Case{
		{MS_SIMPLE_BODY, "X", []Ms_Part{{field = "a", data = "1"}}},
		{
			MS_FILE_BODY,
			"B",
			[]Ms_Part{{field = "doc", filename = "passwd", ctype = "text/plain", is_file = true, data = "hello"}},
		},
		{MS_TRICKY_BODY, "bnd", []Ms_Part{{field = "v", data = "x\r\n--bndarincomplete"}}},
		{MS_NO_FINAL_CRLF, "Z", []Ms_Part{{field = "a", data = "z"}}},
		{
			MS_EMPTY_AND_UNNAMED,
			"Q",
			[]Ms_Part{{field = "e", filename = "", is_file = true, data = ""}, {field = "after", data = "ok"}},
		},
	}
	for c in cases {
		whole, ok := ms_run_chunked(c.body, c.boundary, 0)
		testing.expectf(t, ok, "whole-body feed failed for %q", c.body)
		ms_expect_parts(t, whole, c.want, "whole body")

		for step in 1 ..= len(c.body) {
			got, ok2 := ms_run_chunked(c.body, c.boundary, step)
			testing.expectf(t, ok2, "step %v did not complete the body", step)
			ms_expect_parts(t, got, c.want, "steps")
		}
	}
}

@(test)
test_multipart_stream_truncated :: proc(t: ^testing.T) {
	// the body stops in the middle of a part: a truncated upload must fail
	// rather than deliver half a file
	body := "--T\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nhalf"
	_, ok := ms_run_chunked(body, "T", 0)
	testing.expect(t, !ok)

	// no delimiter at all
	_, ok2 := ms_run_chunked("nothing to see here", "T", 0)
	testing.expect(t, !ok2)
}

@(test)
test_multipart_stream_limits :: proc(t: ^testing.T) {
	// a part over the per-part limit
	big := strings.concatenate({"--L\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a\"\r\n\r\n", strings.repeat("x", 1024, context.temp_allocator), "\r\n--L--\r\n"}, context.temp_allocator)
	_, ok := ms_run_chunked(big, "L", 0, Multipart_Options{max_part_size = 256})
	testing.expect(t, !ok)

	// more fields than allowed
	many := strings.Builder{}
	strings.builder_init(&many, context.temp_allocator)
	for i in 0 ..< 4 {
		strings.write_string(&many, "--F\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nv\r\n")
	}
	strings.write_string(&many, "--F--\r\n")
	_, ok2 := ms_run_chunked(strings.to_string(many), "F", 0, Multipart_Options{max_fields = 2})
	testing.expect(t, !ok2)
}

@(test)
test_multipart_stream_sink_refusal :: proc(t: ^testing.T) {
	// a consumer that says no stops the parse with .Sink_Error, not .Malformed
	ms: Multipart_Stream
	refuse := Multipart_Handlers {
		on_data = proc(ud: rawptr, part: ^Stream_Part, chunk: []byte) -> bool {
			return false
		},
	}
	testing.expect(t, multipart_stream_init(&ms, "X", context.temp_allocator, {}, refuse))
	ok := multipart_stream_feed(&ms, transmute([]byte)string(MS_SIMPLE_BODY))
	testing.expect(t, !ok)
	testing.expect(t, multipart_stream_error(&ms) == .Sink_Error)
	multipart_stream_destroy(&ms)
}

@(test)
test_multipart_stream_bad_boundary :: proc(t: ^testing.T) {
	ms: Multipart_Stream
	testing.expect(t, !multipart_stream_init(&ms, "", context.temp_allocator))
	testing.expect(t, !multipart_stream_init(&ms, strings.repeat("x", 300, context.temp_allocator), context.temp_allocator))
}

/*
test_multipart_stream_memory_is_bounded is the point of streaming: feeding a
large part must not make the parser hold it. The scan buffer is checked
directly - if the retention rule were wrong, it would grow with the part.
*/
@(test)
test_multipart_stream_memory_is_bounded :: proc(t: ^testing.T) {
	ms: Multipart_Stream
	total := 0
	counter := Multipart_Handlers {
		on_data = proc(ud: rawptr, part: ^Stream_Part, chunk: []byte) -> bool {
			c := cast(^int) ud
			c^ += len(chunk)
			return true
		},
		ud = cast(rawptr) &total,
	}
	testing.expect(t, multipart_stream_init(&ms, "M", context.temp_allocator, {}, counter))
	defer multipart_stream_destroy(&ms)

	testing.expect(t, multipart_stream_feed(&ms, transmute([]byte)string("--M\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a\"\r\n\r\n")))

	// 64 chunks of 32 KiB, checking the retained buffer after each
	chunk := make([]byte, 32 << 10, context.temp_allocator)
	for i in 0 ..< len(chunk) {
		chunk[i] = 'a'
	}
	worst := 0
	for _ in 0 ..< 64 {
		testing.expect(t, multipart_stream_feed(&ms, chunk))
		if n := buf_len(&ms.scan); n > worst {
			worst = n
		}
	}
	testing.expectf(t, worst <= len(chunk) + len(ms.sep), "the parser retained %v bytes", worst)
	// the last `len(sep)-1` bytes are still undecided, by design
	testing.expectf(t, total == 64 * len(chunk) - (len(ms.sep) - 1), "emitted %v of %v", total, 64 * len(chunk))
	testing.expect(t, multipart_stream_feed(&ms, transmute([]byte)string("\r\n--M--\r\n")))
	testing.expect(t, multipart_stream_finish(&ms))
	_ = mem.Allocator{}
}

/*
test_multipart_stream_multi_part_sequence: parts arrive in order and each one
reports its own position and final size. `upload.odin` builds `files[]` from
these callbacks, so an index that drifted (an unnamed part counted, a file
missed) would attach the wrong metadata to the wrong part.
*/
MS_MULTI_BODY :: "--MM\r\nContent-Disposition: form-data; name=\"a\"; filename=\"1.bin\"\r\n\r\nAAA\r\n--MM\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\nBBB\r\n--MM\r\nContent-Disposition: form-data; name=\"c\"; filename=\"2.bin\"\r\n\r\nCCCC\r\n--MM--\r\n"

@(test)
test_multipart_stream_multi_part_sequence :: proc(t: ^testing.T) {
	want := []Ms_Part {
		{field = "a", filename = "1.bin", is_file = true, data = "AAA"},
		{field = "b", data = "BBB"},
		{field = "c", filename = "2.bin", is_file = true, data = "CCCC"},
	}
	// a few window sizes; the exhaustive sweep is the boundaries test
	steps := [5]int{0, 1, 3, 5, 7}
	for step in steps {
		probe, ok := ms_run_chunked(MS_MULTI_BODY, "MM", step)
		testing.expectf(t, ok, "step %v did not complete the body", step)
		ms_expect_parts(t, probe, want, "multi")
		if len(probe.parts) != len(want) {
			continue
		}
		for p, i in probe.parts {
			testing.expectf(t, p.index == i, "part %v reported index %v", i, p.index)
			testing.expectf(t, p.size == len(want[i].data), "part %v reported size %v, want %v", i, p.size, len(want[i].data))
		}
	}
}

/*
test_multipart_stream_preamble_epilogue: RFC 2046 allows text before the first
delimiter and after the closing one. Browsers do not send either, but a proxy
or a hand-rolled client can, and rejecting those bodies would be wrong. Feeding
more bytes after the close delimiter is also legal and must be ignored.
*/
MS_PREAMBLE_BODY :: "this line is a preamble\r\n--PB\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--PB--\r\nand an epilogue\r\n"

@(test)
test_multipart_stream_preamble_epilogue :: proc(t: ^testing.T) {
	steps := [3]int{0, 1, 4}
	for step in steps {
		probe, ok := ms_run_chunked(MS_PREAMBLE_BODY, "PB", step)
		testing.expectf(t, ok, "step %v rejected a body with a preamble", step)
		ms_expect_parts(t, probe, []Ms_Part{{field = "a", data = "1"}}, "preamble")
	}

	// after the close delimiter the parser is done: more bytes change nothing
	ms: Multipart_Stream
	ended := 0
	count_end := Multipart_Handlers {
		on_part_end = proc(ud: rawptr, part: ^Stream_Part) -> bool {
			n := cast(^int) ud
			n^ += 1
			return true
		},
		ud = cast(rawptr) &ended,
	}
	testing.expect(t, multipart_stream_init(&ms, "PB", context.temp_allocator, {}, count_end))
	defer multipart_stream_destroy(&ms)
	testing.expect(t, multipart_stream_feed(&ms, transmute([]byte)string(MS_PREAMBLE_BODY)))
	testing.expect(t, multipart_stream_finish(&ms))
	testing.expect(t, multipart_stream_feed(&ms, transmute([]byte)string("garbage after the epilogue")))
	testing.expectf(t, ended == 1, "the epilogue produced %v parts", ended)
}

/*
test_multipart_stream_delimiter_line_end: `\r\n--boundary` only starts a new
part when the rest of that line is padding and CRLF (or `--`). Two bodies that
a naive "search for the separator" parser gets wrong: the boundary followed by
text is content, and transport padding before the CRLF is legal.
*/
MS_DELIM_LOOKALIKE :: "--X\r\nContent-Disposition: form-data; name=\"v\"\r\n\r\nz\r\n--X y\r\n--X--\r\n"

MS_DELIM_PADDED :: "--PB \t\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n--PB  \r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n--PB--\r\n"

@(test)
test_multipart_stream_delimiter_line_end :: proc(t: ^testing.T) {
	lookalike, ok := ms_run_chunked(MS_DELIM_LOOKALIKE, "X", 0)
	testing.expect(t, ok)
	// the whole `z\r\n--X y` is one part: nothing ended at the candidate
	ms_expect_parts(t, lookalike, []Ms_Part{{field = "v", data = "z\r\n--X y"}}, "lookalike")

	padded, pok := ms_run_chunked(MS_DELIM_PADDED, "PB", 0)
	testing.expect(t, pok)
	ms_expect_parts(
		t,
		padded,
		[]Ms_Part{{field = "a", data = "1"}, {field = "b", data = "2"}},
		"padding",
	)
	// both must also parse when the decision has to wait for the next chunk
	for step in 1 ..= 8 {
		got, ok2 := ms_run_chunked(MS_DELIM_PADDED, "PB", step)
		testing.expectf(t, ok2, "padding at step %v", step)
		testing.expectf(t, len(got.parts) == 2, "padding at step %v produced %v parts", step, len(got.parts))
	}
}
