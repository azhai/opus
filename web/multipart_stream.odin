package web

import "core:mem"

/*
Incremental multipart/form-data parsing.

`multipart_parse` (form.odin) needs the whole body in memory before it can
answer anything, which caps an upload at `Server.max_body_size` and makes a
500 MiB file cost 500 MiB of RAM. This file parses the same grammar from a
stream of chunks instead: bytes are handed in as they arrive from the socket
and each part is emitted through callbacks, so the consumer can write it
somewhere (a file, a hash, a scanner) and let the bytes go.

The hard part of streaming multipart is the delimiter: `\r\n--boundary` can
be split across two chunks, so a parser that searches only the current chunk
would miss it and a parser that emits eagerly would emit the first half of a
delimiter as part data. The rule here is the standard one - at the end of
every feed, retain the last `len(sep) - 1` bytes undecided, because a partial
delimiter can never be longer than that. Everything before them is decided and
emitted. Memory therefore stays bounded by one chunk plus the separator, no
matter how large the part is.

	ms: web.Multipart_Stream
	web.multipart_stream_init(&ms, boundary, alloc, {}, handlers)
	for chunk in chunks {
		if !web.multipart_stream_feed(&ms, chunk) { break }
	}
	ok := web.multipart_stream_finish(&ms)
	web.multipart_stream_destroy(&ms)
*/

// MAX_MULTIPART_HEAD bounds one part's header block.
MAX_MULTIPART_HEAD :: 16 << 10

// MULTIPART_DEFAULT_MAX_PART bounds one part when no limit is configured.
MULTIPART_DEFAULT_MAX_PART :: 512 << 20

// Multipart_Phase is the parser's position in the body.
Multipart_Phase :: enum u8 {
	Preamble, // before the first delimiter
	Delimiter, // just consumed a delimiter; deciding close vs next part
	Head, // inside a part's header block
	Body, // inside a part's content
	Epilogue, // after the closing delimiter; the rest is ignored
	Failed,
}

// Stream_Part describes the part currently being parsed. Its strings are
// owned by the stream (cloned into the stream's allocator) and stay valid
// until `multipart_stream_destroy`.
Stream_Part :: struct {
	field:        string,
	filename:     string, // base name, path components stripped
	content_type: string,
	is_file:      bool, // the part carried a `filename` parameter
	index:        int, // 0-based position among all parts, unnamed ones included
	size:         int, // bytes seen so far; final value at on_part_end
}

/*
Multipart_Handlers are the callbacks the parser makes. Returning false from
any of them aborts the parse with `.Sink_Error`.

`on_data` receives a view into the parser's internal buffer: it is only valid
for the duration of the call, so a consumer that needs the bytes copies or
writes them immediately.
*/
Multipart_Handlers :: struct {
	on_part:     proc(ud: rawptr, part: ^Stream_Part) -> bool,
	on_data:     proc(ud: rawptr, part: ^Stream_Part, chunk: []byte) -> bool,
	on_part_end: proc(ud: rawptr, part: ^Stream_Part) -> bool,
	ud:          rawptr,
}

// Multipart_Options are the parser's limits. Zero means the default.
Multipart_Options :: struct {
	max_fields:    int, // default MAX_FORM_FIELDS
	max_part_size: int, // default MULTIPART_DEFAULT_MAX_PART
	max_head:      int, // default MAX_MULTIPART_HEAD
}

/*
Multipart_Stream is the incremental parser. It owns copies of the delimiter
strings and of every part's metadata, allocated from `allocator` (pass the
request arena so nothing has to be freed by hand, but `multipart_stream_destroy`
must still run to release the scan buffer).
*/
Multipart_Stream :: struct {
	allocator: mem.Allocator,
	delim:     string, // "--" + boundary
	sep:       string, // CRLF + delim
	opts:      Multipart_Options,
	h:         Multipart_Handlers,

	phase:   Multipart_Phase,
	scan:    Buf, // bytes received but not yet decided
	part:    Stream_Part,
	skipping: bool, // the current part has no field name; swallow it
	seen:    int, // parts started, named or not
	fields:  int, // non-file parts counted against max_fields
	err:     Form_Error,
}

/*
multipart_stream_init prepares a parser for `boundary`. It returns false when
the boundary is unusable (empty, or too long for the "++" prefix to fit in a
line), in which case the request should be answered 400.
*/
multipart_stream_init :: proc(
	ms: ^Multipart_Stream,
	boundary: string,
	allocator: mem.Allocator,
	opts: Multipart_Options = {},
	h: Multipart_Handlers = {},
) -> bool {
	if len(boundary) == 0 || len(boundary) > 200 {
		return false
	}
	a := allocator
	if a.procedure == nil {
		a = context.allocator
	}
	ms^ = Multipart_Stream {
		allocator = a,
		opts      = opts,
		h         = h,
		part      = Stream_Part{index = -1},
	}
	if ms.opts.max_fields <= 0 {
		ms.opts.max_fields = MAX_FORM_FIELDS
	}
	if ms.opts.max_part_size <= 0 {
		ms.opts.max_part_size = MULTIPART_DEFAULT_MAX_PART
	}
	if ms.opts.max_head <= 0 {
		ms.opts.max_head = MAX_MULTIPART_HEAD
	}
	ms.delim = concat_strings({"--", boundary}, a)
	ms.sep = concat_strings({"\r\n", ms.delim}, a)
	buf_init(&ms.scan, a)
	return true
}

// multipart_stream_destroy releases the parser's buffer. Part metadata lives
// in the same allocator and is released with it.
multipart_stream_destroy :: proc(ms: ^Multipart_Stream) {
	buf_destroy(&ms.scan)
	ms.phase = .Failed
}

// multipart_stream_error is the reason the parse stopped.
multipart_stream_error :: proc(ms: ^Multipart_Stream) -> Form_Error {
	return ms.err
}

/*
multipart_stream_feed hands the parser the next chunk of the body. It returns
false when the body is invalid or a limit was hit; `multipart_stream_error`
then says which.

Feeding after the closing delimiter is legal and ignored: a client may send
trailing CRLF, and an epilogue is part of the grammar.
*/
multipart_stream_feed :: proc(ms: ^Multipart_Stream, data: []byte) -> bool {
	switch ms.phase {
	case .Failed:
		return false
	case .Epilogue:
		return true
	case .Preamble, .Delimiter, .Head, .Body:
	}
	buf_append(&ms.scan, data)
	return ms_run(ms)
}

/*
multipart_stream_finish checks that the body ended where the grammar says it
must: after the closing delimiter. A body that stops in the middle of a part
is a truncated upload and is rejected rather than delivered half-parsed.
*/
multipart_stream_finish :: proc(ms: ^Multipart_Stream) -> bool {
	if ms.phase == .Failed {
		return false
	}
	if ms.phase == .Epilogue || ms.phase == .Failed {
		return true
	}
	// A closing delimiter is sometimes followed by nothing at all (no final
	// CRLF). Everything else - preamble, mid-part - means the body was cut.
	if ms.phase == .Delimiter && len(buf_slice(&ms.scan)) == 0 {
		ms.err = .Malformed
		ms.phase = .Failed
		return false
	}
	ms.err = .Malformed
	ms.phase = .Failed
	return false
}

// ms_run advances the state machine as far as the buffered bytes allow.
@(private = "file")
ms_run :: proc(ms: ^Multipart_Stream) -> bool {
	for {
		switch ms.phase {
		case .Preamble:
			idx := bytes_index(buf_slice(&ms.scan), ms.delim)
			if idx < 0 {
				// everything before a possible partial delimiter is preamble
				ms_keep_tail(ms, len(ms.delim) - 1)
				return true
			}
			buf_consume(&ms.scan, idx + len(ms.delim))
			ms.phase = .Delimiter

		case .Delimiter:
			scan := buf_slice(&ms.scan)
			if len(scan) >= 2 && scan[0] == '-' && scan[1] == '-' {
				// "--" closes the body; the rest is epilogue
				buf_reset(&ms.scan)
				ms.phase = .Epilogue
				return true
			}
			if len(scan) < 2 {
				return true // could still become "--"
			}
			// transport padding is legal before the CRLF
			i := 0
			for i < len(scan) && (scan[i] == ' ' || scan[i] == '\t') {
				i += 1
			}
			if i > 256 {
				return ms_fail(ms, .Malformed)
			}
			if i + 1 >= len(scan) {
				return true // waiting for the CRLF
			}
			if scan[i] != '\r' || scan[i + 1] != '\n' {
				return ms_fail(ms, .Malformed)
			}
			buf_consume(&ms.scan, i + 2)
			ms.phase = .Head

		case .Head:
			scan := buf_slice(&ms.scan)
			end := bytes_index(scan, "\r\n\r\n")
			if end < 0 {
				if len(scan) > ms.opts.max_head {
					return ms_fail(ms, .Malformed)
				}
				return true
			}
			if !ms_begin_part(ms, string(scan[:end])) {
				return false
			}
			buf_consume(&ms.scan, end + 4)
			ms.phase = .Body

		case .Body:
			scan := buf_slice(&ms.scan)
			found := -1
			search := 0
			for {
				rel := bytes_index(scan[search:], ms.sep)
				if rel < 0 {
					break
				}
				cand := search + rel
				#partial switch ms_delim_follows(scan, cand + len(ms.sep)) {
				case .Yes:
					found = cand
				case .No:
					// `\r\n--boundary` not followed by CRLF or "--" is part
					// content, not a delimiter (RFC 2046: a delimiter line
					// must end with CRLF or introduce the close delimiter).
					// Keep looking further into the body.
					search = cand + 1
					continue
				case .Need:
					// too few bytes to tell; decide after the next feed
					return true
				}
				break
			}
			if found < 0 {
				// No delimiter: everything except a possible partial one is data.
				keep := len(ms.sep) - 1
				if len(scan) > keep {
					n := len(scan) - keep
					if !ms_emit(ms, scan[:n]) {
						return false
					}
					buf_consume(&ms.scan, n)
				}
				return true
			}
			if !ms_emit(ms, scan[:found]) {
				return false
			}
			if !ms_end_part(ms) {
				return false
			}
			buf_consume(&ms.scan, found + len(ms.sep))
			ms.phase = .Delimiter
			continue

		case .Epilogue, .Failed:
			return ms.phase == .Epilogue
		}
	}
}

// ms_keep_tail drops everything but the last `keep` bytes of the buffer.
@(private = "file")
ms_keep_tail :: proc(ms: ^Multipart_Stream, keep: int) {
	n := buf_len(&ms.scan)
	if n > keep {
		buf_consume(&ms.scan, n - keep)
	}
}

@(private = "file")
ms_fail :: proc(ms: ^Multipart_Stream, err: Form_Error) -> bool {
	ms.err = err
	ms.phase = .Failed
	return false
}

// Delim_Follow is the verdict on what sits after a `\r\n--boundary` candidate.
Delim_Follow :: enum u8 {
	Yes, // transport padding + CRLF, or "--": a real delimiter line
	No, // something else: the candidate is part content
	Need, // too few bytes buffered to decide
}

/*
ms_delim_follows classifies the bytes after a delimiter candidate. This is
what keeps a part from ending inside its own data: `\r\n--boundary` is only a
delimiter when the line ends there, so a body containing the boundary string
followed by more text stays in one piece. Without this check the parser would
split at the candidate and then reject the rest as malformed - which is worse
than either extreme, because the consumer has already been handed the bytes.
*/
@(private = "file")
ms_delim_follows :: proc(scan: []byte, i: int) -> Delim_Follow {
	j := i
	for j < len(scan) && (scan[j] == ' ' || scan[j] == '\t') {
		j += 1
	}
	if j - i > 256 {
		return .No
	}
	if j >= len(scan) {
		return .Need
	}
	if scan[j] == '-' {
		if j + 1 >= len(scan) {
			return .Need
		}
		return scan[j + 1] == '-' ? .Yes : .No
	}
	if scan[j] == '\r' {
		if j + 1 >= len(scan) {
			return .Need
		}
		return scan[j + 1] == '\n' ? .Yes : .No
	}
	return .No
}

/*
ms_begin_part parses one part header block and calls `on_part`. The metadata
strings are cloned because they are views into the scan buffer, which is shifted
by the next `buf_consume`.
*/
@(private = "file")
ms_begin_part :: proc(ms: ^Multipart_Stream, head: string) -> bool {
	name, filename, ctype, is_file := multipart_part_meta(head)

	ms.seen += 1
	ms.part = Stream_Part {
		field        = clone_string(name, ms.allocator),
		filename     = clone_string(filename, ms.allocator),
		content_type = clone_string(ctype, ms.allocator),
		is_file      = is_file,
		index        = ms.seen - 1,
	}
	ms.skipping = false

	if len(name) == 0 {
		// A part with no field name is not form data (some clients send an
		// unnamed preamble part). Swallow it whole, callbacks suppressed, so
		// a consumer never sees a part it cannot name.
		ms.skipping = true
		return true
	}
	if !is_file {
		ms.fields += 1
		if ms.opts.max_fields > 0 && ms.fields > ms.opts.max_fields {
			return ms_fail(ms, .Too_Many_Fields)
		}
	}
	if ms.h.on_part != nil && !ms.h.on_part(ms.h.ud, &ms.part) {
		return ms_fail(ms, .Sink_Error)
	}
	return true
}

@(private = "file")
ms_emit :: proc(ms: ^Multipart_Stream, chunk: []byte) -> bool {
	if len(chunk) == 0 {
		return true
	}
	ms.part.size += len(chunk)
	if ms.opts.max_part_size > 0 && ms.part.size > ms.opts.max_part_size {
		return ms_fail(ms, .File_Too_Large)
	}
	if ms.skipping {
		return true
	}
	if ms.h.on_data != nil && !ms.h.on_data(ms.h.ud, &ms.part, chunk) {
		return ms_fail(ms, .Sink_Error)
	}
	return true
}

@(private = "file")
ms_end_part :: proc(ms: ^Multipart_Stream) -> bool {
	if ms.skipping {
		ms.skipping = false
		return true
	}
	if ms.h.on_part_end != nil && !ms.h.on_part_end(ms.h.ud, &ms.part) {
		return ms_fail(ms, .Sink_Error)
	}
	return true
}
