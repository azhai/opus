package web

import "core:mem"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

/*
Static serves files from a directory tree with a TTL stat cache
(lighttpd2's stat_cache, minus the async stat thread pool: metadata lookups
are cached, and file bodies are streamed zero-copy with sendfile).

Usage:

	static: web.Static
	web.static_init(&static, "./www")
	srv.user_ptr = &static
	srv.handler = web.static_serve
*/
Static :: struct {
	cfg:       Static_Config,
	cache:     map[string]Stat_Cache_Entry,
	allocator: mem.Allocator,
}

Static_Config :: struct {
	root:      string,
	index:     string,      // default "index.html"
	cache_ttl: time.Duration, // default 1s
}

Stat_Cache_Entry :: struct {
	exists:  bool,
	is_dir:  bool,
	size:    i64,
	mod_utc: time.Time,
	checked: time.Time,
}

static_init :: proc(st: ^Static, root: string, allocator := context.allocator) {
	st.allocator = allocator
	st.cfg.root = root
	st.cfg.index = "index.html"
	st.cfg.cache_ttl = time.Second
	st.cache = make(map[string]Stat_Cache_Entry, allocator)
}

static_destroy :: proc(st: ^Static) {
	if st.cache != nil {
		keys: [dynamic]string
		defer delete(keys)
		for k in st.cache {
			append(&keys, k)
		}
		for k in keys {
			delete_key(&st.cache, k)
			delete(k, st.allocator)
		}
		delete(st.cache)
		st.cache = nil
	}
}

// static_serve is a `Handler` for `server.user_ptr = ^Static`.
static_serve :: proc(req: ^Request, res: ^Response) {
	s := req.conn.server
	st := cast(^Static) s.user_ptr
	if st == nil {
		res.status = .Internal_Error
		response_write_string(res, "500 static root not configured\n")
		return
	}
	static_serve_root(st, req, res)
}

// static_serve_root is static_serve with an explicit root; use it when the
// router (not the server) owns the static state.
static_serve_root :: proc(st: ^Static, req: ^Request, res: ^Response) {

	if req.method != .Get && req.method != .Head {
		res.status = .Method_Not_Allowed
		response_set_header(res, "Allow", "GET, HEAD")
		response_write_string(res, "405 method not allowed\n")
		return
	}

	fs_path, ok := static_resolve_path(st, req.path, conn_scratch(req.conn))
	if !ok {
		static_not_found(res)
		return
	}

	entry, found := static_lookup(st, fs_path)
	if !found || !entry.exists {
		static_not_found(res)
		return
	}
	if entry.is_dir {
		// try the index file inside the directory
		idx_path := concat_strings({fs_path, "/", st.cfg.index}, conn_scratch(req.conn))
		idx_entry, idx_found := static_lookup(st, idx_path)
		if !idx_found || !idx_entry.exists || idx_entry.is_dir {
			static_not_found(res)
			return
		}
		fs_path = idx_path
		entry = idx_entry
	}

	if !response_send_file_handle(res, fs_path, entry.size) {
		static_not_found(res)
		return
	}
	response_set_header(res, "Content-Type", mime_type(fs_path))
	response_set_header(res, "Accept-Ranges", "none")
}

static_not_found :: proc(res: ^Response) {
	res.status = .Not_Found
	response_set_header(res, "Content-Type", "text/plain; charset=utf-8")
	response_write_string(res, "404 not found\n")
}

// static_resolve_path maps a URL path onto the filesystem, rejecting
// traversal and control characters.
static_resolve_path :: proc(st: ^Static, url_path: string, allocator: mem.Allocator) -> (string, bool) {
	if !path_is_safe(url_path) {
		return "", false
	}
	if strings.contains(url_path, "\\") || strings.contains(url_path, "\x00") {
		return "", false
	}
	root := st.cfg.root
	sep := ""
	if len(root) > 0 && root[len(root) - 1] != '/' {
		sep = "/"
	}
	return concat_strings({root, sep, url_path}, allocator), true
}

// static_lookup consults the TTL stat cache, refreshing on miss or expiry.
static_lookup :: proc(st: ^Static, fs_path: string) -> (Stat_Cache_Entry, bool) {
	now := time.now()
	if e, ok := st.cache[fs_path]; ok {
		if time.diff(e.checked, now) < st.cfg.cache_ttl {
			return e, true
		}
	}
	fi, err := os.stat(fs_path, st.allocator)
	if err != nil {
		// cache the negative result too (avoids stat storms on 404s)
		static_cache_put(st, fs_path, Stat_Cache_Entry{checked = now})
		return Stat_Cache_Entry{}, false
	}
	entry := Stat_Cache_Entry{
		exists  = true,
		is_dir  = fi.type == .Directory,
		size    = fi.size,
		mod_utc = fi.modification_time,
		checked = now,
	}
	os.file_info_delete(fi, st.allocator)
	static_cache_put(st, fs_path, entry)
	return entry, true
}

static_cache_put :: proc(st: ^Static, fs_path: string, entry: Stat_Cache_Entry) {
	if _, ok := st.cache[fs_path]; !ok {
		st.cache[clone_string(fs_path, st.allocator)] = entry
		return
	}
	st.cache[fs_path] = entry
}

// response_send_file_handle streams an already-opened file handle.
response_send_file_handle :: proc(w: ^Response, path: string, size: i64) -> bool {
	if file_pending(w) {
		return false
	}
	handle, ferr := nbio.open_sync(path)
	if ferr != nil {
		return false
	}
	w.file_handle = handle
	w.file_open = true
	w.file_size = size
	w.file_path = path
	buf_reset(&w.body)
	return true
}
