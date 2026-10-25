package web

import "core:mem"
import "core:os"
import "core:time"

/*
Uploads that outlive the request: multipart parts spilled to temporary files
as the body arrives.

The in-memory path (form.odin) has two hard limits - `MAX_FORM_FILE_SIZE` per
part and `Server.max_body_size` for the whole body - because it holds the
bytes twice: once in `Request.body` and again in the part view. That is fine
for an avatar and useless for a video, so this file adds the other half:
`upload_sink_attach` installs a body sink on the connection *before* the body
is read (from `Server.on_head`), and every part is then written out through
`multipart_stream` as it arrives. Memory stays at one recv chunk plus the
part's in-memory prefix (`cfg.threshold`), no matter how large the upload is.

	cfg := web.Upload_Sink_Config{dir = "./uploads"}
	srv.on_head = proc(s: ^web.Server, c: ^web.Conn) {
		if len(c.req.body) == 0 {   // never true here; see below
		}
		web.upload_sink_attach(c, cfg)
	}

Attaching is a no-op for anything that is not multipart/form-data, so the
hook does not have to sniff content types itself.

The parts land in `Form_File`, the same type the in-memory parser fills, so
`request_file` / `request_files` work unchanged - except that `data` is empty
and `path` names the file on disk. Temp files are removed when the request
ends unless the consumer took them over: a file is kept when `cfg.keep_temp`
is set, or when the path was renamed away before then (`os.rename` on a gone
source is simply not attempted, the remove just fails quietly).

The honesty note: this streams the *body*, not the *connection*. The head is
still parsed and routed before the body is read, and the connection is still
busy until the upload finishes, so a 4 GiB upload still occupies one socket
for its duration. What it no longer costs is 4 GiB of RAM.
*/

// UPLOAD_SPILL_THRESHOLD is how many bytes of a part are kept in memory before
// the rest goes to a file. Small parts therefore never touch the disk.
UPLOAD_SPILL_THRESHOLD :: 256 << 10

// UPLOAD_MAX_FIELD_SIZE bounds one non-file part.
UPLOAD_MAX_FIELD_SIZE :: 1 << 20

// UPLOAD_TEMP_PREFIX marks the files this file creates, so a crashed process
// leaves something identifiable behind (and so a cleanup cron can match them).
UPLOAD_TEMP_PREFIX :: "web-upload-"

/*
Upload_Sink_Config configures the streaming upload path.

`dir` is where parts are written and must exist (or be creatable); empty means
the system temporary directory. `threshold` is the in-memory prefix per part;
`max_part_size` and `max_field_size` bound one part; `keep_temp` leaves the
files behind for the application to collect instead of deleting them when the
request ends.
*/
Upload_Sink_Config :: struct {
	dir:            string,
	threshold:      int,
	max_part_size:  int,
	max_field_size: int,
	max_fields:     int,
	keep_temp:      bool,
}

/*
Upload_Sink is the streaming consumer. It lives on the connection arena for
exactly one request.
*/
Upload_Sink :: struct {
	cfg:       Upload_Sink_Config,
	alloc:     mem.Allocator,
	req:       ^Request,
	parser:    Multipart_Stream,
	fields:    [dynamic]Param,
	files:     [dynamic]Form_File,
	mem:       Buf, // in-memory prefix / field value being accumulated
	file:      ^os.File, // open spill file, nil while the part fits in memory
	cur:       int, // index into files while a file part is open, else -1
	open_path: string,
	created:   [dynamic]string, // every path written, for cleanup
	seq:       int,
}

/*
upload_sink_attach installs the streaming multipart parser on a connection.
It must run from `Server.on_head`, i.e. after the request head is parsed and
before the body is read; calling it later is a no-op that reports
`.Not_A_Form` because the body has already been consumed.

Returns `.None` when the sink is installed, `.Not_A_Form` when the request is
not a multipart body (the normal case for most requests, not an error), and
`.Bad_Boundary` / `.Malformed` when the request claims multipart framing it
does not have.
*/
upload_sink_attach :: proc(c: ^Conn, cfg: Upload_Sink_Config) -> Form_Error {
	if c == nil || c.closed {
		return .Malformed
	}
	r := &c.req
	if !request_is_multipart(r) {
		return .Not_A_Form
	}
	if c.body_sink.write != nil {
		return .Malformed // already streaming; one sink per body
	}
	raw, _ := request_header(r, "Content-Type")
	boundary := multipart_boundary_param(raw)
	if len(boundary) == 0 {
		return .Bad_Boundary
	}

	alloc := conn_scratch(c)
	s := new(Upload_Sink, alloc)
	s.alloc = alloc
	s.req = r
	s.cur = -1
	s.cfg = cfg
	upload_sink_fill_defaults(&s.cfg, alloc)
	buf_init(&s.mem, alloc)
	s.fields = make([dynamic]Param, alloc)
	s.files = make([dynamic]Form_File, alloc)
	s.created = make([dynamic]string, alloc)

	opts := Multipart_Options {
		max_part_size = s.cfg.max_part_size,
		max_fields    = s.cfg.max_fields,
	}
	if !multipart_stream_init(&s.parser, boundary, alloc, opts, upload_sink_handlers(s)) {
		return .Bad_Boundary
	}

	conn_set_body_sink(c, Body_Sink {
		write    = upload_sink_write,
		finish   = upload_sink_finish,
		teardown = upload_sink_teardown,
		ud       = cast(rawptr) s,
	})
	return .None
}

// upload_sink_default_config fills the zero value with the documented
// defaults; a config built from a literal only sets what it cares about.
upload_sink_default_config :: proc() -> Upload_Sink_Config {
	cfg: Upload_Sink_Config
	upload_sink_fill_defaults(&cfg, context.allocator)
	return cfg
}

@(private = "file")
upload_sink_fill_defaults :: proc(cfg: ^Upload_Sink_Config, alloc: mem.Allocator) {
	if cfg.threshold <= 0 {
		cfg.threshold = UPLOAD_SPILL_THRESHOLD
	}
	if cfg.max_part_size <= 0 {
		cfg.max_part_size = MULTIPART_DEFAULT_MAX_PART
	}
	if cfg.max_field_size <= 0 {
		cfg.max_field_size = UPLOAD_MAX_FIELD_SIZE
	}
	if cfg.max_fields <= 0 {
		cfg.max_fields = MAX_FORM_FIELDS
	}
	if len(cfg.dir) == 0 {
		// the system temp path comes from a temporary allocator: clone it,
		// because the config outlives the call
		cfg.dir = clone_string(upload_temp_dir(), alloc)
	}
}

// upload_temp_dir is where parts spill when the config names no directory.
// The result may point into a temporary allocator, which is why the config
// clones it before storing it.
upload_temp_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		if v := os.get_env("TEMP", context.temp_allocator); len(v) > 0 {
			return v
		}
		return "C:/Windows/Temp"
	} else {
		if v := os.get_env("TMPDIR", context.temp_allocator); len(v) > 0 {
			return v
		}
		return "/tmp"
	}
}

// ---------------------------------------------------------------------------
// multipart callbacks
// ---------------------------------------------------------------------------

@(private = "file")
upload_sink_handlers :: proc(s: ^Upload_Sink) -> Multipart_Handlers {
	return Multipart_Handlers {
		on_part = upload_on_part,
		on_data = upload_on_data,
		on_part_end = upload_on_part_end,
		ud = cast(rawptr) s,
	}
}

@(private = "file")
upload_on_part :: proc(ud: rawptr, part: ^Stream_Part) -> bool {
	s := cast(^Upload_Sink) ud
	buf_reset(&s.mem)
	s.cur = -1
	if !part.is_file {
		return true // a field: accumulated in s.mem until on_part_end
	}
	append(&s.files, Form_File {
		field = part.field,
		filename = part.filename,
		content_type = part.content_type,
	})
	s.cur = len(s.files) - 1
	return true
}

@(private = "file")
upload_on_data :: proc(ud: rawptr, part: ^Stream_Part, chunk: []byte) -> bool {
	s := cast(^Upload_Sink) ud
	if s.cur < 0 {
		// field value
		if buf_len(&s.mem) + len(chunk) > s.cfg.max_field_size {
			// record the reason here: a refusal alone is indistinguishable from
			// a malformed body further down, and the client should see 413
			s.req.form_state = .Too_Large
			return false
		}
		buf_append(&s.mem, chunk)
		return true
	}
	if s.file == nil {
		// still in the in-memory prefix
		if buf_len(&s.mem) + len(chunk) <= s.cfg.threshold {
			buf_append(&s.mem, chunk)
			return true
		}
		if !upload_open_spill(s) {
			return false
		}
	}
	_, err := os.write(s.file, chunk)
	return err == nil
}

@(private = "file")
upload_on_part_end :: proc(ud: rawptr, part: ^Stream_Part) -> bool {
	s := cast(^Upload_Sink) ud
	if s.cur < 0 {
		if len(s.mem.data) == 0 {
			append(&s.fields, Param{name = part.field, value = ""})
			return true
		}
		value := clone_string(string(buf_slice(&s.mem)), s.alloc)
		append(&s.fields, Param{name = part.field, value = value})
		buf_reset(&s.mem)
		return true
	}
	f := &s.files[s.cur]
	if s.file != nil {
		err := os.close(s.file)
		s.file = nil
		if err != nil {
			log_error("web: upload: cannot close %v: %v", s.open_path, err)
			return false
		}
		f.path = s.open_path
		f.size = part.size
		s.open_path = ""
		s.cur = -1
		return true
	}
	// stayed in memory: the parser's buffer is reused, so copy
	f.data = clone_bytes(buf_slice(&s.mem), s.alloc)
	f.size = len(f.data)
	buf_reset(&s.mem)
	s.cur = -1
	return true
}

/*
upload_open_spill creates the temporary file for a part that outgrew the
in-memory threshold and flushes the prefix into it. The name is generated
here rather than taken from the client: the original name is kept in
`Form_File.filename` for display and must never reach the filesystem.
*/
@(private = "file")
upload_open_spill :: proc(s: ^Upload_Sink) -> bool {
	dir := s.cfg.dir
	if err := os.make_directory_all(dir); err != nil {
		log_debug("web: upload: %v exists or could not be created: %v", dir, err)
	}
	for attempt in 0 ..< 8 {
		s.seq += 1
		hint := ""
		if s.cur >= 0 && s.cur < len(s.files) {
			hint = upload_safe_name(s.files[s.cur].filename, s.alloc)
		}
		name := upload_temp_name(s.alloc, s.seq, attempt, hint)
		path := concat_strings({dir, "/", name}, s.alloc)
		f, err := os.create(path)
		if err != nil {
			continue // a name collision: try the next one
		}
		s.file = f
		s.open_path = path
		append(&s.created, path)
		if buf_len(&s.mem) > 0 {
			if _, werr := os.write(f, buf_slice(&s.mem)); werr != nil {
				log_error("web: upload: cannot write %v: %v", path, werr)
				os.close(f)
				s.file = nil
				return false
			}
			buf_reset(&s.mem)
		}
		return true
	}
	log_error("web: upload: cannot create a temp file in %v", dir)
	return false
}

// upload_temp_name builds a collision-resistant name: wall clock, process id,
// per-request sequence and the attempt number. Time alone is not enough -
// two connections in the same nanosecond on different threads would pick the
// same name, and `os.create` truncates what it finds.
@(private = "file")
upload_temp_name :: proc(alloc: mem.Allocator, seq, attempt: int, hint: string) -> string {
	nano := u64(time.time_to_unix_nano(time.now()))
	tail := ""
	if len(hint) > 0 {
		// the client's (sanitised) name, only to make the file recognisable in
		// a directory listing - the unique part of the name comes first
		tail = concat_strings({"-", hint}, alloc)
	}
	return concat_strings(
		{
			UPLOAD_TEMP_PREFIX,
			upload_itoa(alloc, nano),
			"-",
			upload_itoa(alloc, u64(os.get_pid())),
			"-",
			upload_itoa(alloc, u64(seq)),
			"-",
			upload_itoa(alloc, u64(attempt)),
			tail,
		},
		alloc,
	)
}

// upload_itoa formats v in decimal without going through fmt, which would
// allocate through the wrong allocator and drag `core:fmt` into the library.
@(private = "file")
upload_itoa :: proc(alloc: mem.Allocator, v: u64) -> string {
	buf: [24]byte
	n := 0
	x := v
	if x == 0 {
		buf[0] = '0'
		n = 1
	} else {
		for x > 0 {
			buf[n] = byte('0' + x % 10)
			x /= 10
			n += 1
		}
		for i in 0 ..< n / 2 {
			buf[i], buf[n - 1 - i] = buf[n - 1 - i], buf[i]
		}
	}
	return clone_string(string(buf[:n]), alloc)
}

// ---------------------------------------------------------------------------
// body sink plumbing
// ---------------------------------------------------------------------------

@(private = "file")
upload_sink_write :: proc(ud: rawptr, chunk: []byte) -> bool {
	s := cast(^Upload_Sink) ud
	if multipart_stream_feed(&s.parser, chunk) {
		return true
	}
	// record why, so the connection can answer 413 rather than 400 for a
	// limit and 400 for a malformed body
	upload_sink_record_error(s)
	return false
}

// upload_sink_record_error copies the parser's verdict onto the request, which
// is where the connection layer looks when it builds the error response.
//
// A verdict the sink already reached itself wins: a field it refused for
// exceeding `max_field_size` arrives here as `.Sink_Error`, which would be
// downgraded to a 400, but the honest answer is 413.
@(private = "file")
upload_sink_record_error :: proc(s: ^Upload_Sink) {
	if s.req.form_state == .Too_Large {
		return
	}
	switch multipart_stream_error(&s.parser) {
	case .Too_Many_Fields, .File_Too_Large:
		s.req.form_state = .Too_Large
	case .None, .Not_A_Form, .Bad_Boundary, .Malformed, .Too_Large, .Sink_Error:
		s.req.form_state = .Malformed
	}
}

@(private = "file")
upload_sink_finish :: proc(ud: rawptr) -> bool {
	s := cast(^Upload_Sink) ud
	r := s.req
	if !multipart_stream_finish(&s.parser) {
		upload_sink_record_error(s)
		return false
	}
	r.form = s.fields[:]
	r.files = s.files[:]
	r.form_state = .Parsed
	return true
}

/*
upload_sink_teardown deletes the temp files the request did not keep. It runs
from `conn_close` and from the keep-alive reset, i.e. exactly once per
request, after the handler had its chance to rename them away.
*/
@(private = "file")
upload_sink_teardown :: proc(ud: rawptr) {
	s := cast(^Upload_Sink) ud
	if s.file != nil {
		os.close(s.file)
		s.file = nil
	}
	if s.cfg.keep_temp {
		return
	}
	for path in s.created {
		if err := os.remove(path); err != nil {
			// already renamed away (or gone): the normal way to keep a file
			log_debug("web: upload: %v not removed: %v", path, err)
		}
	}
	clear(&s.created)
}

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

// form_file_bytes returns the part's content, reading it back from disk when
// the part was spilled. It is meant for parts known to be small; a caller
// streaming a large file should open `path` itself.
form_file_bytes :: proc(f: Form_File, allocator: mem.Allocator) -> ([]byte, bool) {
	if len(f.path) == 0 {
		return f.data, true
	}
	data, err := os.read_entire_file(f.path, allocator)
	if err != nil {
		return nil, false
	}
	return data, true
}

// request_file_bytes is form_file_bytes for the first upload of a field.
request_file_bytes :: proc(r: ^Request, field: string, allocator: mem.Allocator) -> ([]byte, bool) {
	f, ok := request_file(r, field)
	if !ok {
		return nil, false
	}
	return form_file_bytes(f, allocator)
}

/*
upload_safe_name reduces a client-supplied file name to something safe to
create: no path separators, no control characters, nothing outside
`[A-Za-z0-9._-]`. An empty result becomes "upload". The name is truncated to
96 bytes so a pathological one cannot blow past the filesystem's own limit.

It lives here rather than in the middleware because the spill sink needs it
too: a temp file named after the client's part is easier to identify in a
directory listing, and the sanitiser is the only thing that may touch that
name. The original name is still the one `Form_File.filename` keeps.
*/
upload_safe_name :: proc(name: string, allocator: mem.Allocator) -> string {
	out := make([dynamic]byte, 0, min(len(name) + 1, 96), allocator)
	for i in 0..<len(name) {
		c := name[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '.', c == '-', c == '_':
			append(&out, c)
		case:
			append(&out, '_')
		}
		if len(out) >= 96 {
			break
		}
	}
	if len(out) == 0 {
		return "upload"
	}
	return string(out[:])
}
