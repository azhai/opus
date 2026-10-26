package middlewares

import ".."
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// Tests for the upload middleware: a multipart file is spooled to disk, the
// stored name is sanitised, and a body that is not an upload is left alone.

upload_dir := "/tmp/opus-upload-test"

upload_handler :: proc(req: ^web.Request, res: ^web.Response) {
	u, ok := request_upload(req, "avatar")
	if !ok {
		web.response_write_string(res, "no-file")
		return
	}
	web.response_write_string(res, u.path)
	web.response_write_string(res, "|")
	web.response_write_string(res, u.original)
	web.response_write_string(res, "|")
	web.response_write_string(res, web.int_to_string(i64(u.size), web.response_allocator(res)))
}

// upload_body builds a one-part multipart body into a caller-provided
// buffer: tests must not allocate, or the runner reports a leak.
upload_body :: proc(dst: []byte, filename, content: string) -> []byte {
	pieces := []string{
		"--XYZ\r\n",
		"Content-Disposition: form-data; name=\"avatar\"; filename=\"",
		filename,
		"\"\r\nContent-Type: text/plain\r\n\r\n",
		content,
		"\r\n--XYZ--\r\n",
	}
	n := 0
	for piece in pieces {
		for i in 0..<len(piece) {
			dst[n] = piece[i]
			n += 1
		}
	}
	return dst[:n]
}

@(test)
test_middleware_upload_spools_files :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	_ = os.remove_all(upload_dir)
	cfg := Upload_Config{dir = upload_dir}
	route := web.router_post(&e.router, "/upload", upload_handler)
	web.router_use_route(route, middleware_upload, &cfg)

	body_buf: [512]byte
	body := upload_body(body_buf[:], "a.txt", "hello upload")
	req := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []web.Header {
			web.Header{key = "Content-Type", value = "multipart/form-data; boundary=XYZ"},
		},
		body = body,
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)

	reported := string(web.buf_slice(&res.body))
	testing.expect(t, !strings.has_prefix(reported, "no-file"))
	testing.expect(t, strings.contains(reported, "|a.txt|12"))

	// the bytes landed on disk under a sanitised, timestamped name
	uploads := request_uploads(&req)
	testing.expect_value(t, len(uploads), 1)
	if len(uploads) == 1 {
		testing.expect(t, strings.has_prefix(uploads[0].path, upload_dir))
		testing.expect(t, strings.has_suffix(uploads[0].filename, "_a.txt"))
		testing.expect_value(t, uploads[0].size, 12)
		data, err := os.read_entire_file(uploads[0].path, context.allocator)
		testing.expect(t, err == nil)
		if err == nil {
			testing.expect_value(t, string(data), "hello upload")
			delete(data)
		}
	}

	// a path-traversal name never escapes the directory
	body2_buf: [512]byte
	body2 := upload_body(body2_buf[:], "../../etc/passwd", "x")
	req2 := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []web.Header {
			web.Header{key = "Content-Type", value = "multipart/form-data; boundary=XYZ"},
		},
		body = body2,
	}
	res2: web.Response
	mw_env_call(&e, &req2, &res2)
	uploads2 := request_uploads(&req2)
	testing.expect_value(t, len(uploads2), 1)
	if len(uploads2) == 1 {
		testing.expect(t, strings.has_prefix(uploads2[0].path, upload_dir))
		testing.expect(t, !strings.contains(uploads2[0].filename, "/"))
		testing.expect_value(t, uploads2[0].original, "passwd") // base name only
	}

	_ = os.remove_all(upload_dir)
}

/*
test_middleware_upload_moves_streamed_part: when the streaming hook already
parsed the body, the part is a file on disk and the middleware's job is to put
it under the stored name. This drives that path directly - the socket-level
half is covered by web/upload_test.odin, which is where a real body arrives.
*/
@(test)
test_middleware_upload_moves_streamed_part :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	_ = os.remove_all(upload_dir)
	testing.expect(t, os.make_directory_all(upload_dir) == nil)
	defer os.remove_all(upload_dir)

	cfg := Upload_Config{dir = upload_dir, stream = true}
	route := web.router_post(&e.router, "/upload", upload_handler)
	web.router_use_route(route, middleware_upload, &cfg)

	// a part that the sink already wrote out
	temp_path := "/tmp/opus-upload-streamed-part"
	testing.expect(t, os.write_entire_file(temp_path, tb("streamed bytes")) == nil)
	defer os.remove(temp_path)

	req := web.Request {
		method     = .Post,
		path       = "/upload",
		target     = "/upload",
		headers    = []web.Header{web.Header{key = "Content-Type", value = "multipart/form-data; boundary=XYZ"}},
		form_state = .Parsed,
		files      = []web.Form_File {
			web.Form_File {
				field        = "avatar",
				filename     = "pic.bin",
				content_type = "application/octet-stream",
				path         = temp_path,
				size         = 14,
			},
		},
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)

	uploads := request_uploads(&req)
	testing.expect_value(t, len(uploads), 1)
	if len(uploads) == 1 {
		testing.expect(t, strings.has_prefix(uploads[0].path, upload_dir))
		testing.expect(t, strings.has_suffix(uploads[0].filename, "_pic.bin"))
		testing.expect_value(t, uploads[0].size, 14)
		data, err := os.read_entire_file(uploads[0].path, context.allocator)
		testing.expect(t, err == nil)
		if err == nil {
			testing.expect_value(t, string(data), "streamed bytes")
			delete(data)
		}
	}
	// the rename is the hand-off: the temp file is gone, so the sink's own
	// cleanup has nothing left to delete
	testing.expect(t, !os.exists(temp_path))
}

@(test)
test_middleware_upload_ignores_other_bodies :: proc(t: ^testing.T) {
	e: Mw_Env
	mw_env_init(&e)
	defer mw_env_destroy(&e)

	cfg := Upload_Config{dir = upload_dir}
	route := web.router_post(&e.router, "/upload", upload_handler)
	web.router_use_route(route, middleware_upload, &cfg)

	// a urlencoded body is not an upload: the handler still runs and finds
	// no files, so a route can serve both encodings
	req := web.Request {
		method  = .Post,
		path    = "/upload",
		target  = "/upload",
		headers = []web.Header {
			web.Header{key = "Content-Type", value = "application/x-www-form-urlencoded"},
		},
		body = tb("name=ada"),
	}
	res: web.Response
	mw_env_call(&e, &req, &res)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, string(web.buf_slice(&res.body)), "no-file")
	testing.expect_value(t, len(request_uploads(&req)), 0)
}

/*
test_upload_store_adopts_streamed_part: a part the streaming sink already wrote
out is *moved* into the upload directory. The rename is what transfers
ownership - the sink deletes whatever is still in its `created` list when the
request ends - so a copy would both double the disk use and leave the temp file
behind. The in-memory half of the same function is covered here too, because
the two modes share `upload_store`.
*/
@(test)
test_upload_store_adopts_streamed_part :: proc(t: ^testing.T) {
	dir := "/tmp/opus-upload-store"
	_ = os.remove_all(dir)
	testing.expectf(t, os.make_directory_all(dir) == nil, "cannot create %v", dir)
	defer os.remove_all(dir)

	src := web.concat_strings({dir, "/web-upload-1-temp"}, context.temp_allocator)
	payload := "streamed bytes"
	testing.expect(t, os.write_entire_file(src, transmute([]byte)string(payload)) == nil)

	f := web.Form_File {
		field    = "avatar",
		filename = "a.bin",
		path     = src,
		size     = len(payload),
	}
	dst := web.concat_strings({dir, "/kept.bin"}, context.temp_allocator)
	testing.expectf(t, upload_store(f, dst), "upload_store refused a spilled part")
	testing.expectf(t, !os.exists(src), "the temp file was copied, not adopted: %v", src)

	data, derr := os.read_entire_file(dst, context.allocator)
	testing.expectf(t, derr == nil, "cannot read %v", dst)
	defer delete(data, context.allocator)
	testing.expectf(t, string(data) == payload, "the adopted file holds %q", string(data))

	// the same function, for a part that never touched the disk
	mem_part := web.Form_File {
		field    = "avatar",
		filename = "b.bin",
		data     = transmute([]byte)string("in memory"),
	}
	mem_dst := web.concat_strings({dir, "/mem.bin"}, context.temp_allocator)
	testing.expect(t, upload_store(mem_part, mem_dst))
	mem_data, merr := os.read_entire_file(mem_dst, context.allocator)
	testing.expect(t, merr == nil)
	defer delete(mem_data, context.allocator)
	testing.expectf(t, string(mem_data) == "in memory", "the in-memory part holds %q", string(mem_data))
}
