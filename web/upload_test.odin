package web

/*
Integration tests for streaming uploads (upload.odin + multipart_stream.odin).

Every case goes over a real socket: the point of the feature is that the body
is written out *while it arrives*, and a synthetic call cannot show whether the
connection layer handed the sink the bytes in the right order, or whether the
temp file was released when the request ended. The handler records what it saw
into a file-scoped probe and the assertions read it back after the response.
*/

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:thread"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------
// probe: what the handler saw
// ---------------------------------------------------------------------------

Up_Probe :: struct {
	used:       bool,
	has_file:   bool,
	field:      [64]byte,
	field_len:  int,
	filename:   [128]byte,
	filename_len: int,
	path:       [512]byte,
	path_len:   int,
	size:       int,
	data_len:   int,
	file_fnv:   u64,
	body_len:   int,
	form_state: Form_State,
}

@(private = "file")
up_probe: Up_Probe

@(private = "file")
up_cfg: Upload_Sink_Config

@(private = "file")
up_head_hook :: proc(s: ^Server, c: ^Conn, ud: rawptr) -> bool {
	#partial switch upload_sink_attach(c, up_cfg) {
	case .None, .Not_A_Form:
		return true
	case:
		conn_error(c, .Bad_Request, "400 bad multipart\n")
		return false
	}
}

@(private = "file")
up_copy :: proc(dst: []byte, n: ^int, src: string) {
	m := min(len(dst), len(src))
	mem.copy_non_overlapping(raw_data(dst), raw_data(transmute([]byte)src), m)
	n^ = m
}

@(private = "file")
upload_handler :: proc(req: ^Request, res: ^Response) {
	up_probe = Up_Probe{used = true}
	up_probe.body_len = len(req.body)
	up_probe.form_state = req.form_state
	if v, ok := request_form_value(req, "note"); ok {
		up_copy(up_probe.field[:], &up_probe.field_len, v)
	}
	f, has := request_file(req, "doc")
	up_probe.has_file = has
	if !has {
		response_text(res, .OK, "no file\n")
		return
	}
	up_copy(up_probe.filename[:], &up_probe.filename_len, f.filename)
	up_copy(up_probe.path[:], &up_probe.path_len, f.path)
	up_probe.size = f.size
	up_probe.data_len = len(f.data)
	if len(f.path) > 0 {
		sum, n, ok := up_file_fnv(f.path)
		up_probe.file_fnv = sum
		if !ok || n != f.size {
			response_text(res, .Internal_Error, "temp file unreadable\n")
			return
		}
	} else {
		up_probe.file_fnv = up_fnv(f.data)
	}
	response_text(res, .OK, "file ok\n")
}

// fnv1a_64 over a byte string, used to compare an uploaded temp file with what
// the client sent without holding either in the test.
@(private = "file")
up_fnv :: proc(data: []byte) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in data {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return h
}

@(private = "file")
up_file_fnv :: proc(path: string) -> (sum: u64, n: int, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return 0, 0, false
	}
	defer os.close(f)
	h := u64(0xcbf29ce484222325)
	buf: [64 << 10]byte
	total := 0
	for {
		got, rerr := os.read(f, buf[:])
		if got <= 0 || rerr != nil {
			break
		}
		for i in 0 ..< got {
			h = (h ~ u64(buf[i])) * 0x100000001b3
		}
		total += got
	}
	return h, total, true
}

// ---------------------------------------------------------------------------
// client helpers
// ---------------------------------------------------------------------------

@(private = "file")
up_buf: [8192]byte

@(private = "file")
up_len: int

@(private = "file")
up_drain :: proc(sock: net.TCP_Socket, needle: string) -> (string, bool) {
	_ = net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	up_len = 0
	for up_len < len(up_buf) {
		n, err := net.recv_tcp(sock, up_buf[up_len:])
		if err != nil || n <= 0 {
			break
		}
		up_len += n
		if strings.contains(string(up_buf[:up_len]), needle) {
			return string(up_buf[:up_len]), true
		}
	}
	return string(up_buf[:up_len]), false
}

@(private = "file")
up_send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// up_multipart_body builds a two-part body: a text field and one file.
@(private = "file")
up_multipart_body :: proc(boundary, note, filename: string, payload: []byte, alloc: mem.Allocator) -> []byte {
	out := make([dynamic]byte, 0, len(payload) + 512, alloc)
	append(&out, ..transmute([]byte)fmt.aprintf("--%v\r\n", boundary, allocator = alloc))
	append(&out, ..transmute([]byte)fmt.aprintf("Content-Disposition: form-data; name=\"note\"\r\n\r\n%v\r\n", note, allocator = alloc))
	append(&out, ..transmute([]byte)fmt.aprintf("--%v\r\n", boundary, allocator = alloc))
	append(&out, ..transmute([]byte)fmt.aprintf("Content-Disposition: form-data; name=\"doc\"; filename=\"%v\"\r\n", filename, allocator = alloc))
	append(&out, "Content-Type: application/octet-stream\r\n\r\n")
	append(&out, ..payload)
	append(&out, ..transmute([]byte)fmt.aprintf("\r\n--%v--\r\n", boundary, allocator = alloc))
	return out[:]
}

// up_chunked wraps a body in chunked framing, split at `step` bytes so the
// decoder has to reassemble across reads.
@(private = "file")
up_chunked :: proc(body: []byte, step: int, alloc: mem.Allocator) -> []byte {
	out := make([dynamic]byte, 0, len(body) + 64, alloc)
	for i := 0; i < len(body); i += step {
		end := min(i + step, len(body))
		append(&out, ..transmute([]byte)fmt.aprintf("%x\r\n", end - i, allocator = alloc))
		append(&out, ..body[i:end])
		append(&out, "\r\n")
	}
	append(&out, "0\r\n\r\n")
	return out[:]
}

// up_payload is a deterministic pattern: something compressible would hide a
// mix-up between the client's bytes and the file's.
@(private = "file")
up_payload :: proc(n: int, alloc: mem.Allocator) -> []byte {
	out := make([]byte, n, alloc)
	for i in 0 ..< n {
		out[i] = byte((i * 37 + 11) & 0xff)
	}
	return out
}

@(private = "file")
up_tmp_dir :: proc(t: ^testing.T, name: string) -> string {
	dir := fmt.aprintf("/tmp/opus-upload-%v", name, allocator = context.allocator)
	os.remove_all(dir)
	testing.expectf(t, os.make_directory_all(dir) == nil, "cannot create %v", dir)
	return dir
}

@(private = "file")
up_dir_count :: proc(dir: string) -> int {
	entries, err := os.read_directory_by_path(dir, 64, context.temp_allocator)
	if err != nil {
		return -1
	}
	return len(entries)
}

@(private = "file")
up_spin :: proc(
	t: ^testing.T,
	srv: ^Server,
	hook: proc(s: ^Server, c: ^Conn, ud: rawptr) -> bool,
	handler: Handler = upload_handler,
) -> (
	ep: net.Endpoint,
	th: ^thread.Thread,
	args: ^Integration_Args,
) {
	srv.handler = handler
	srv.on_head = hook
	srv.max_body_size = 16 << 20
	srv.idle_timeout = 2 * time.Second
	return integration_spin_srv(t, srv)
}

// ---------------------------------------------------------------------------
// probe for requests with more than one file part
// ---------------------------------------------------------------------------

@(private = "file")
UP_MAX_FILES :: 4

Up_Multi_Probe :: struct {
	used:     bool,
	count:    int,
	names:    [UP_MAX_FILES][64]byte,
	name_len: [UP_MAX_FILES]int,
	paths:    [UP_MAX_FILES][512]byte,
	path_len: [UP_MAX_FILES]int,
	sizes:    [UP_MAX_FILES]int,
	fnv:      [UP_MAX_FILES]u64,
}

@(private = "file")
up_multi_probe: Up_Multi_Probe

// up_two_handler records every file part, in the order the parser reported
// them, and hashes each one from wherever it actually landed.
@(private = "file")
up_two_handler :: proc(req: ^Request, res: ^Response) {
	up_multi_probe = Up_Multi_Probe {
		used  = true,
		count = len(req.files),
	}
	for f, i in req.files {
		if i >= UP_MAX_FILES {
			break
		}
		up_copy(up_multi_probe.names[i][:], &up_multi_probe.name_len[i], f.field)
		up_copy(up_multi_probe.paths[i][:], &up_multi_probe.path_len[i], f.path)
		up_multi_probe.sizes[i] = f.size
		if len(f.path) > 0 {
			sum, _, _ := up_file_fnv(f.path)
			up_multi_probe.fnv[i] = sum
		} else {
			up_multi_probe.fnv[i] = up_fnv(f.data)
		}
	}
	response_text(res, .OK, "two ok\n")
}

// up_two_file_body builds a body with two file parts and no field, so a mix-up
// between them cannot hide behind a text part.
@(private = "file")
up_two_file_body :: proc(boundary, first, second: string, a, b: []byte, alloc: mem.Allocator) -> []byte {
	out := make([dynamic]byte, 0, len(a) + len(b) + 512, alloc)
	append(&out, ..transmute([]byte)fmt.aprintf("--%v\r\n", boundary, allocator = alloc))
	append(&out, ..transmute([]byte)fmt.aprintf("Content-Disposition: form-data; name=\"one\"; filename=\"%v\"\r\n\r\n", first, allocator = alloc))
	append(&out, ..a)
	append(&out, ..transmute([]byte)fmt.aprintf("\r\n--%v\r\n", boundary, allocator = alloc))
	append(&out, ..transmute([]byte)fmt.aprintf("Content-Disposition: form-data; name=\"two\"; filename=\"%v\"\r\n\r\n", second, allocator = alloc))
	append(&out, ..b)
	append(&out, ..transmute([]byte)fmt.aprintf("\r\n--%v--\r\n", boundary, allocator = alloc))
	return out[:]
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

/*
test_integration_upload_spill is the headline case: a 200 KiB part with a 4 KiB
in-memory threshold lands in a temp file, byte for byte, and the file is gone
once the request ends.
*/
@(test)
test_integration_upload_spill :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "spill")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 4 << 10,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(200 << 10, context.temp_allocator)
	body := up_multipart_body("upbound", "hello", "big.bin", payload, context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=upbound\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, body))

	got, ok := up_drain(client, "file ok")
	testing.expectf(t, ok, "no response: %q", got)
	testing.expect(t, strings.contains(got, "HTTP/1.1 200 OK"))

	testing.expect(t, up_probe.used)
	testing.expectf(t, string(up_probe.field[:up_probe.field_len]) == "hello", "field %q", string(up_probe.field[:up_probe.field_len]))
	testing.expectf(t, string(up_probe.filename[:up_probe.filename_len]) == "big.bin", "filename %q", string(up_probe.filename[:up_probe.filename_len]))
	path := string(up_probe.path[:up_probe.path_len])
	testing.expectf(t, len(path) > 0, "the part was not spilled: path is empty")
	testing.expectf(t, up_probe.size == len(payload), "size %v, want %v", up_probe.size, len(payload))
	// the body was streamed, not buffered on the request
	testing.expectf(t, up_probe.body_len == 0, "req.body holds %v bytes", up_probe.body_len)
	testing.expectf(t, up_probe.file_fnv == up_fnv(payload), "the temp file does not match what was sent")

	// the request ended: nothing may be left behind
	for _ in 0 ..< 100 {
		if up_dir_count(dir) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, up_dir_count(dir) == 0, "temp files survived the request in %v", dir)
}

// a part under the threshold never touches the disk
@(test)
test_integration_upload_memory :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "memory")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 64 << 10,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(1000, context.temp_allocator)
	body := up_multipart_body("memb", "note1", "small.bin", payload, context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=memb\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, body))

	got, ok := up_drain(client, "file ok")
	testing.expectf(t, ok, "no response: %q", got)
	testing.expectf(t, up_probe.path_len == 0, "a small part was spilled to %q", string(up_probe.path[:up_probe.path_len]))
	testing.expectf(t, up_probe.data_len == len(payload), "in-memory size %v", up_probe.data_len)
	testing.expectf(t, up_probe.file_fnv == up_fnv(payload), "the in-memory bytes do not match")
	testing.expectf(t, up_dir_count(dir) == 0, "a small part created a file")
}

/*
test_integration_upload_chunked: the same upload sent with
Transfer-Encoding: chunked. This is the path where the decoder releases each
chunk to the sink instead of accumulating the body, so it exercises
chunked_try_decode's emit mode.
*/
@(test)
test_integration_upload_chunked :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "chunked")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 1024,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(64 << 10, context.temp_allocator)
	body := up_multipart_body("chb", "chunked", "c.bin", payload, context.temp_allocator)
	framed := up_chunked(body, 7919, context.temp_allocator) // a prime step on purpose
	head := "POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=chb\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)head))
	testing.expect(t, up_send_all(client, framed))

	got, ok := up_drain(client, "file ok")
	testing.expectf(t, ok, "no response: %q", got)
	testing.expectf(t, up_probe.size == len(payload), "size %v, want %v", up_probe.size, len(payload))
	testing.expectf(t, up_probe.file_fnv == up_fnv(payload), "chunked upload bytes differ")
	testing.expectf(t, string(up_probe.field[:up_probe.field_len]) == "chunked", "field %q", string(up_probe.field[:up_probe.field_len]))
}

// a part over the configured limit is refused with 413, not half-written
@(test)
test_integration_upload_part_too_large :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "limit")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir           = dir,
		threshold     = 512,
		max_part_size = 4096,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(64 << 10, context.temp_allocator)
	body := up_multipart_body("limb", "x", "too.bin", payload, context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=limb\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	_ = up_send_all(client, transmute([]byte)string(head))
	// the server may answer before reading everything; a send error is fine
	_ = up_send_all(client, body)

	got, ok := up_drain(client, "413")
	testing.expectf(t, ok, "expected 413, got: %q", got)
	// the handler must not have run
	testing.expectf(t, !up_probe.used, "the handler ran for an oversized part")
	for _ in 0 ..< 100 {
		if up_dir_count(dir) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, up_dir_count(dir) == 0, "a rejected upload left files behind")
}

// keep_temp hands the files to the application instead of deleting them
@(test)
test_integration_upload_keep_temp :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "keep")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 256,
		keep_temp = true,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(4096, context.temp_allocator)
	body := up_multipart_body("keepb", "", "keep.bin", payload, context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=keepb\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, body))
	_, ok := up_drain(client, "file ok")
	testing.expect(t, ok)

	path := string(up_probe.path[:up_probe.path_len])
	testing.expectf(t, len(path) > 0, "no file was kept")
	// give the teardown a chance to (wrongly) delete it
	time.sleep(20 * time.Millisecond)
	testing.expectf(t, up_dir_count(dir) == 1, "expected the kept file to survive")
	testing.expectf(t, os.exists(path), "%v was deleted despite keep_temp", path)
}

/*
test_integration_upload_body_untouched: a request that is not multipart must
be unaffected by the hook. This is the compatibility half of the feature - a
JSON endpoint on a server with upload streaming enabled still sees its body.
*/
@(test)
test_integration_upload_body_untouched :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "plain")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config{dir = dir, threshold = 1024}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	body := `{"a":1}`
	head := fmt.aprintf(
		"POST /json HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, transmute([]byte)string(body)))
	got, ok := up_drain(client, "HTTP/1.1")
	testing.expectf(t, ok, "no response: %q", got)
	testing.expectf(t, up_probe.body_len == len(body), "req.body holds %v bytes, want %v", up_probe.body_len, len(body))
	testing.expectf(t, !up_probe.has_file, "a JSON request produced a file")
}

// ---------------------------------------------------------------------------
// unit-level: attach refuses what it cannot stream
// ---------------------------------------------------------------------------

@(test)
test_upload_sink_attach_requires_multipart :: proc(t: ^testing.T) {
	// the sink is installed from on_head, and on_head sees a live Conn; this
	// checks the cheap guards without one
	testing.expect(t, upload_sink_attach(nil, Upload_Sink_Config{}) != .None)

	cfg := upload_sink_default_config()
	defer delete(cfg.dir, context.allocator) // the default dir is cloned
	testing.expect(t, cfg.threshold > 0)
	testing.expect(t, cfg.max_part_size > 0)
	testing.expect(t, len(cfg.dir) > 0)
}

/*
test_integration_upload_two_files: two parts over the threshold in one request.
Each must reach its own temp file with its own bytes - a sink that reused one
`open_path` or one `files[]` slot would silently overwrite the first upload
with the second, which no single-file test can catch.
*/
@(test)
test_integration_upload_two_files :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "two")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_multi_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 1024,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook, up_two_handler)
	defer integration_stop(t, args, th)

	first := up_payload(8 << 10, context.temp_allocator)
	second := up_payload(12 << 10, context.temp_allocator)
	// the second payload differs from the first: same pattern, other offset
	for i in 0 ..< len(second) {
		second[i] = byte((i * 53 + 7) & 0xff)
	}
	body := up_two_file_body("twob", "a.bin", "b.bin", first, second, context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=twob\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, body))

	got, ok := up_drain(client, "two ok")
	testing.expectf(t, ok, "no response: %q", got)

	testing.expectf(t, up_multi_probe.count == 2, "the handler saw %v files", up_multi_probe.count)
	testing.expectf(t, string(up_multi_probe.names[0][:up_multi_probe.name_len[0]]) == "one", "first field %q", string(up_multi_probe.names[0][:up_multi_probe.name_len[0]]))
	testing.expectf(t, string(up_multi_probe.names[1][:up_multi_probe.name_len[1]]) == "two", "second field %q", string(up_multi_probe.names[1][:up_multi_probe.name_len[1]]))

	path_a := string(up_multi_probe.paths[0][:up_multi_probe.path_len[0]])
	path_b := string(up_multi_probe.paths[1][:up_multi_probe.path_len[1]])
	testing.expectf(t, len(path_a) > 0 && len(path_b) > 0, "a part stayed in memory: %q / %q", path_a, path_b)
	testing.expectf(t, path_a != path_b, "both parts went to the same file %q", path_a)
	testing.expectf(t, up_multi_probe.sizes[0] == len(first), "first size %v", up_multi_probe.sizes[0])
	testing.expectf(t, up_multi_probe.sizes[1] == len(second), "second size %v", up_multi_probe.sizes[1])
	testing.expectf(t, up_multi_probe.fnv[0] == up_fnv(first), "the first file does not match what was sent")
	testing.expectf(t, up_multi_probe.fnv[1] == up_fnv(second), "the second file does not match what was sent")

	// both are released when the request is over
	for _ in 0 ..< 100 {
		if up_dir_count(dir) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, up_dir_count(dir) == 0, "temp files survived the request in %v", dir)
}

/*
test_integration_upload_field_too_large: a text part over `max_field_size` is a
413. The sink refuses it itself (the parser has no opinion about field values),
so the status has to come from the sink's own verdict - a plain refusal would
be indistinguishable from a malformed body and answer 400.
*/
@(test)
test_integration_upload_field_too_large :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "fieldlim")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir            = dir,
		threshold      = 1024,
		max_field_size = 8,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	body := up_multipart_body("fldb", "this note is longer than eight bytes", "x.bin", up_payload(16, context.temp_allocator), context.temp_allocator)
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=fldb\r\nContent-Length: %v\r\nConnection: close\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	_ = up_send_all(client, transmute([]byte)string(head))
	_ = up_send_all(client, body)

	got, ok := up_drain(client, "413")
	testing.expectf(t, ok, "expected 413 for an oversized field, got: %q", got)
	testing.expectf(t, !up_probe.used, "the handler ran for a refused body")
	testing.expectf(t, up_dir_count(dir) == 0, "a refused upload left files behind")
}

/*
test_integration_upload_keepalive_teardown: on a kept-alive connection the temp
files must be gone when the *request* ends, not when the socket does. The
cleanup has two call sites (`conn_close` and the keep-alive reset) and only the
latter is exercised here: a file service that waits for the client to hang up
leaks a disk full of uploads while the browser holds the connection open.
*/
@(test)
test_integration_upload_keepalive_teardown :: proc(t: ^testing.T) {
	dir := up_tmp_dir(t, "keepalive")
	defer delete(dir, context.allocator)
	defer os.remove_all(dir)

	up_probe = {}
	up_cfg = Upload_Sink_Config {
		dir       = dir,
		threshold = 512,
	}

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	ep, th, args := up_spin(t, srv, up_head_hook)
	defer integration_stop(t, args, th)

	payload := up_payload(8 << 10, context.temp_allocator)
	body := up_multipart_body("kab", "n", "ka.bin", payload, context.temp_allocator)
	// no Connection: close - this connection has to survive the request
	head := fmt.aprintf(
		"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: multipart/form-data; boundary=kab\r\nContent-Length: %v\r\n\r\n",
		len(body),
		allocator = context.temp_allocator,
	)
	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)
	testing.expect(t, up_send_all(client, transmute([]byte)string(head)))
	testing.expect(t, up_send_all(client, body))
	first_reply, ok := up_drain(client, "file ok")
	testing.expectf(t, ok, "no response: %q", first_reply)
	testing.expectf(t, up_probe.path_len > 0, "the part was not spilled")

	// the socket is still open: the file must already be gone
	for _ in 0 ..< 100 {
		if up_dir_count(dir) == 0 {
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expectf(t, up_dir_count(dir) == 0, "the temp file outlived the request on a kept-alive connection")

	// ... and the connection still serves: teardown did not break the reset
	up_probe = {}
	testing.expect(t, up_send_all(client, transmute([]byte)string("GET /next HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")))
	second_reply, ok2 := up_drain(client, "no file")
	testing.expectf(t, ok2, "the kept-alive connection did not answer the second request: %q", second_reply)
	testing.expectf(t, !up_probe.has_file, "a GET produced a file part")
}

/*
test_upload_safe_name: the sanitiser is the only thing standing between a
client-supplied name and the filesystem. What matters is that the result is a
single path component - no separators, no traversal, nothing the shell would
interpret - and that it is bounded.
*/
Up_Name_Case :: struct {
	input: string,
	want:  string,
}

@(test)
test_upload_safe_name :: proc(t: ^testing.T) {
	cases := []Up_Name_Case{
		{"avatar.png", "avatar.png"},
		{"../../etc/passwd", ".._.._etc_passwd"},
		{"..\\..\\windows\\system32", ".._.._windows_system32"},
		{"a b\tc", "a_b_c"},
		// the sanitiser works on bytes, so a multi-byte character becomes one
		// underscore per byte; the name is a display hint, not an identity
		{"naïve-文件.bin", "na__ve-______.bin"},
		{"", "upload"},
		{"///", "___"},
	}
	for c in cases {
		got := upload_safe_name(c.input, context.temp_allocator)
		testing.expectf(t, got == c.want, "%q became %q, want %q", c.input, got, c.want)
		testing.expectf(t, strings.index_byte(got, '/') < 0 && strings.index_byte(got, '\\') < 0, "%q kept a separator: %q", c.input, got)
	}

	// a pathological name is truncated, not passed through
	long := strings.repeat("z", 400, context.temp_allocator)
	short := upload_safe_name(long, context.temp_allocator)
	testing.expectf(t, len(short) == 96, "a long name produced %v bytes", len(short))
}
