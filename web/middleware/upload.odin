package middleware

import ".."
import "core:mem"
import "core:os"

/*
Uploads: multipart file parts spooled to disk instead of held in memory.

`middleware_form` keeps uploads in memory, which is right for an avatar and
wrong for a video. `middleware_upload` writes each file part into a directory,
recording where it landed so the handler can move it, scan it or stream it
back:

	up := web.router_post(&r, "/upload", upload_handler)
	web.router_use_route(up, middleware_upload, &Upload_Config{dir = "./uploads"})

	upload_handler :: proc(req: ^web.Request, res: ^web.Response) {
		file, ok := request_upload(req, "avatar")
		if !ok {
			web.response_error(res, .Bad_Request, "")
			return
		}
		fmt.printfln("saved %v (%v bytes) at %v", file.original, file.size, file.path)
	}

Two modes, decided by `Upload_Config.stream`:

  - false (default): the body is parsed in memory and each part is written out
    after it has been received. Bounded by `Server.max_body_size`, so it is
    "don't hold the bytes twice and don't lose them when the request ends".
  - true: `web.upload_sink_attach` is installed before the body is read and
    each part is written as it arrives. Memory stays at one recv chunk plus
    the part's prefix, so the only limit on the upload size is what the
    application chooses.

Streaming mode needs a hook, because the decision has to be made before the
route handler exists:

	srv.on_head = middleware.upload_stream_hook
	srv.on_head_ud = upload_cfg

The hook is a no-op for requests that are not multipart and for configs with
`stream = false`, so it is safe to install unconditionally on a server whose
other routes take JSON.

Stored names are prefixed with a timestamp and sanitised: the client's name
is only used after path components are stripped and every character outside
`[A-Za-z0-9._-]` is replaced, so `../../etc/passwd` becomes `.._.._etc_passwd`
inside the upload directory and nowhere else. The original name is kept for
display (`Upload.original`) and must never be used to build a path.
*/

// DEFAULT_UPLOAD_DIR is where files go when `Upload_Config.dir` is empty.
DEFAULT_UPLOAD_DIR :: "./uploads"

// DEFAULT_MAX_UPLOAD_FILES bounds the number of parts per request.
DEFAULT_MAX_UPLOAD_FILES :: 8

/*
Upload_Config configures middleware_upload. `dir` is created on first use;
`max_file_bytes` and `max_files` are per request, and both reject with 413.

`stream` switches to the out-of-memory path (see the file comment) and
`threshold` is how much of a part is buffered before it spills. Both are only
meaningful together with the hook below.
*/
Upload_Config :: struct {
	dir:            string, // default DEFAULT_UPLOAD_DIR
	max_file_bytes: int,    // default web.MAX_FORM_FILE_SIZE
	max_files:      int,    // default DEFAULT_MAX_UPLOAD_FILES
	stream:         bool,
	threshold:      int, // default web.UPLOAD_SPILL_THRESHOLD
}

// Upload is one stored file. `path` is the full path on disk; `original` is
// the client's base name, for display only.
Upload :: struct {
	field:        string,
	original:     string,
	filename:     string, // stored base name (timestamped, sanitised)
	content_type: string,
	path:         string,
	size:         int,
}

/*
upload_stream_hook installs the streaming sink on requests this config cares
about. Install it as `Server.on_head` with the same `*Upload_Config` the route
uses:

	srv.on_head = middleware.upload_stream_hook
	srv.on_head_ud = cfg

It returns true for "carry on with the request" and false only after it has
answered a malformed body with a 4xx itself.
*/
upload_stream_hook :: proc(s: ^web.Server, c: ^web.Conn, ud: rawptr) -> bool {
	cfg := cast(^Upload_Config) ud
	if cfg == nil || !cfg.stream {
		return true
	}
	sink := web.Upload_Sink_Config {
		dir            = upload_config_dir(cfg),
		threshold      = upload_threshold(cfg),
		max_part_size  = upload_max_bytes(cfg),
		max_fields     = web.MAX_FORM_FIELDS,
	}
	#partial switch web.upload_sink_attach(c, sink) {
	case .None, .Not_A_Form:
		return true
	case .Bad_Boundary, .Malformed:
		web.log_debug("upload: malformed multipart body from %v", c.remote)
		web.response_error_for_conn(c, .Bad_Request)
		return false
	case:
		web.response_error_for_conn(c, .Payload_Too_Large)
		return false
	}
}

/*
middleware_upload parses a multipart body and spools every file part to
disk, then continues the chain. A body that is not multipart is left for
the next middleware or the handler: a JSON handler on the same route must
not be broken by this one.

When the streaming hook already parsed the body, `request_files` returns the
parts with `path` set and the work here is a rename into the upload directory
under the stored name; otherwise the part came from memory and is written out
now.
*/
middleware_upload :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Upload_Config) m.ud
	alloc := web.request_allocator(req)

	// A streamed body is already parsed and its parts are already on disk;
	// form_ensure_parsed would only re-parse an empty `req.body` and report
	// "not a form".
	streamed := len(req.files) > 0 && len(req.files[0].path) > 0
	if !streamed {
		limit_cfg := web.Form_Config {
			max_file_size = upload_max_bytes(cfg),
		}
		if err := web.form_ensure_parsed(req, &limit_cfg); err != .None {
			switch err {
			case .None:
			case .Not_A_Form:
				// not an upload; let the handler deal with the body
			case .Bad_Boundary, .Malformed, .Sink_Error:
				web.response_error(res, .Bad_Request, "")
				return
			case .Too_Many_Fields, .File_Too_Large, .Too_Large:
				web.response_error(res, .Payload_Too_Large, "")
				return
			}
			web.router_next(r, idx + 1, final, req, res)
			return
		}
	}

	files := web.request_files(req)
	if len(files) == 0 {
		web.router_next(r, idx + 1, final, req, res)
		return
	}
	if max_files := upload_max_files(cfg); max_files > 0 && len(files) > max_files {
		web.response_error(res, .Payload_Too_Large, "")
		return
	}

	dir := upload_config_dir(cfg)
	// make_directory_all reports an existing directory as an error, which is
	// not a failure here: the write below is what really tells us whether the
	// directory is usable.
	if err := os.make_directory_all(dir); err != nil {
		web.log_debug("upload: %v exists or could not be created: %v", dir, err)
	}

	stamp := upload_stamp(alloc)
	saved := make([dynamic]Upload, 0, len(files), alloc)
	for f in files {
		name := web.concat_strings({stamp, "_", web.upload_safe_name(f.filename, alloc)}, alloc)
		path := web.concat_strings({dir, "/", name}, alloc)
		if !upload_store(f, path) {
			web.response_error(res, .Internal_Error, "")
			return
		}
		append(&saved, Upload {
			field        = f.field,
			original     = f.filename,
			filename     = name,
			content_type = f.content_type,
			path         = path,
			size         = f.size,
		})
	}
	list := new(Upload_List, alloc)
	list.items = saved[:]
	req.uploads = rawptr(list)
	web.router_next(r, idx + 1, final, req, res)
}

/*
upload_store puts one part at `path`. A part that is already on disk (streamed)
is renamed into place - same filesystem in the normal configuration, because
the sink writes into the same directory - and a part still in memory is
written out. The rename is what transfers ownership: the sink deletes its temp
file when the request ends, and after a successful rename there is nothing
left to delete.
*/
upload_store :: proc(f: web.Form_File, path: string) -> bool {
	if len(f.path) > 0 {
		if err := os.rename(f.path, path); err == nil {
			return true
		}
		// a different filesystem, or a cross-device temp dir: copy instead
		if !upload_copy_file(f.path, path) {
			web.log_error("upload: cannot move %v to %v", f.path, path)
			return false
		}
		_ = os.remove(f.path)
		return true
	}
	if err := os.write_entire_file(path, f.data); err != nil {
		web.log_error("upload: cannot write %v: %v", path, err)
		return false
	}
	return true
}

// upload_copy_file copies with a fixed buffer: the point of the streaming path
// is that the bytes are never all in memory at once.
upload_copy_file :: proc(from, to: string) -> bool {
	src, err := os.open(from)
	if err != nil {
		return false
	}
	defer os.close(src)
	dst, derr := os.create(to)
	if derr != nil {
		return false
	}
	buf: [64 << 10]byte
	copied := false
	for {
		n, rerr := os.read(src, buf[:])
		if n > 0 {
			if _, werr := os.write(dst, buf[:n]); werr != nil {
				break
			}
			copied = true
		}
		if n <= 0 || rerr != nil {
			break
		}
	}
	if cerr := os.close(dst); cerr != nil {
		return false
	}
	return copied
}

// Upload_List is what `Request.uploads` points at. The request carries one
// untyped pointer, so the slice lives inside a struct rather than being
// reconstructed from a bare pointer.
Upload_List :: struct {
	items: []Upload,
}

// request_uploads returns every file stored for this request.
request_uploads :: proc(req: ^web.Request) -> []Upload {
	list := cast(^Upload_List) req.uploads
	if list == nil {
		return nil
	}
	return list.items
}

// request_upload returns the first stored file for a field.
request_upload :: proc(req: ^web.Request, field: string) -> (file: Upload, ok: bool) {
	for u in request_uploads(req) {
		if u.field == field {
			return u, true
		}
	}
	return {}, false
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

upload_config_dir :: proc(cfg: ^Upload_Config) -> string {
	if cfg != nil && len(cfg.dir) > 0 {
		return cfg.dir
	}
	return DEFAULT_UPLOAD_DIR
}

upload_max_bytes :: proc(cfg: ^Upload_Config) -> int {
	if cfg != nil && cfg.max_file_bytes > 0 {
		return cfg.max_file_bytes
	}
	return web.MAX_FORM_FILE_SIZE
}

upload_max_files :: proc(cfg: ^Upload_Config) -> int {
	if cfg != nil && cfg.max_files > 0 {
		return cfg.max_files
	}
	return DEFAULT_MAX_UPLOAD_FILES
}

upload_threshold :: proc(cfg: ^Upload_Config) -> int {
	if cfg != nil && cfg.threshold > 0 {
		return cfg.threshold
	}
	return web.UPLOAD_SPILL_THRESHOLD
}

// upload_stamp is the shared prefix for one request's files: nanosecond
// clock plus a counter, so two requests in the same nanosecond still differ
// and names sort roughly by arrival.
upload_stamp :: proc(alloc: mem.Allocator) -> string {
	return new_request_id(alloc)
}

// sanitize_filename is the historical name for the sanitiser, which now lives
// next to the upload sink that needs it too (`web.upload_safe_name`).
sanitize_filename :: proc(name: string, alloc: mem.Allocator) -> string {
	return web.upload_safe_name(name, alloc)
}
