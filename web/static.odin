package web

import "core:mem"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

/*
Static serves files from a directory tree with a TTL stat cache
(lighttpd2's stat_cache, minus the async stat thread pool: metadata lookups
are cached, and file bodies are streamed in FILE_CHUNK pieces).

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

// STATIC_CACHE_MAX is the default bound on cached paths. At ~48 bytes per
// entry plus the key this is a few hundred kilobytes, which is more than a
// real site has files and far less than an attacker can invent.
STATIC_CACHE_MAX :: 8192

// STATIC_EVICT_BATCH is how many entries one eviction pass removes. Evicting
// one per insert would need a full map walk per insert once the table is full;
// evicting a batch amortises that walk over the batch.
STATIC_EVICT_BATCH :: 128

Static_Config :: struct {
	root:      string,
	index:     string,        // default "index.html"
	cache_ttl: time.Duration, // default 1s
	// max_cache_entries bounds the stat cache (default STATIC_CACHE_MAX).
	// Negative results are cached too, so without a bound every distinct
	// path a client asks for - a 404 flood is the cheap version - would stay
	// in the map for the life of the process.
	max_cache_entries: int,
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
	st.cfg.max_cache_entries = STATIC_CACHE_MAX
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

	ctype := mime_type(fs_path)
	response_set_header(res, "Content-Type", ctype)
	response_set_header(res, "Last-Modified", http_date(entry.mod_utc, conn_scratch(req.conn)))
	response_set_header(res, "Accept-Ranges", "bytes")

	// conditional GET: a fresh copy in the client's cache answers 304
	if ims, ok := request_header(req, "If-Modified-Since"); ok {
		if t, tok := parse_http_date(ims); tok && time.diff(entry.mod_utc, t) >= 0 {
			static_not_modified(res)
			return
		}
	}

	if rng, ok := request_header(req, "Range"); ok {
		ranges, count, decision := parse_byte_ranges(rng, entry.size)
		switch decision {
		case .Ignore:
			// malformed or foreign unit: full response
		case .Unsatisfiable:
			static_range_unsatisfiable(res, entry.size)
			return
		case .Single, .Multi:
			// If-Range: only apply the range when the validator says the
			// file is unchanged since the client's copy
			apply := true
			if ir, has_ir := request_header(req, "If-Range"); has_ir {
				apply = if_range_allowed(ir, entry.mod_utc)
			}
			if !apply {
				static_send_full(res, fs_path, entry.size, ctype)
				return
			}
			if decision == .Single {
				r := ranges[0]
				res.status = .Partial_Content
				response_set_header(res, "Content-Range", content_range_value(r.start, r.start + r.length - 1, entry.size, conn_scratch(req.conn)))
				if !response_send_file_range(res, fs_path, r.start, r.length) {
					static_not_found(res)
					return
				}
				return
			}
			// several ranges: multipart/byteranges, read into memory (the
			// rare path; zero-copy is not worth it here)
			boundary := multipart_boundary(conn_scratch(req.conn))
			body, mok := range_multipart_body(fs_path, ranges[:count], boundary, ctype, entry.size, conn_scratch(req.conn))
			if !mok {
				static_not_found(res)
				return
			}
			res.status = .Partial_Content
			response_set_header(res, "Content-Type", concat_strings({"multipart/byteranges; boundary=", boundary}, conn_scratch(req.conn)))
			response_write(res, body)
			return
		}
	}

	static_send_full(res, fs_path, entry.size, ctype)
}

// static_send_full streams the whole file (the no-Range path).
static_send_full :: proc(res: ^Response, fs_path: string, size: i64, ctype: string) {
	if !response_send_file_handle(res, fs_path, size) {
		static_not_found(res)
		return
	}
	response_set_header(res, "Content-Type", ctype)
}

static_not_modified :: proc(res: ^Response) {
	res.status = .Not_Modified
}

// static_range_unsatisfiable answers 416 with the full length so the
// client can pick a valid range.
static_range_unsatisfiable :: proc(res: ^Response, size: i64) {
	res.status = .Range_Not_Satisfiable
	response_set_header(res, "Content-Range", unsatisfiable_content_range(size, conn_scratch(res.conn)))
	response_write_string(res, "416 range not satisfiable\n")
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
		limit := st.cfg.max_cache_entries
		if limit > 0 && len(st.cache) >= limit {
			static_cache_evict(st)
		}
		st.cache[clone_string(fs_path, st.allocator)] = entry
		return
	}
	st.cache[fs_path] = entry
}

/*
static_cache_evict makes room in a full cache, preferring entries that are
already stale (they would cost a syscall to revalidate anyway) and falling back
to an arbitrary slice when everything is fresh.

The fallback is what bounds the *memory*: a client walking a path space creates
entries that all expire at the same moment, so waiting for expiry would never
evict anything. Nothing is LRU here on purpose - a path that keeps being
requested is refreshed on every hit, so it survives, and that is the property
that matters for a file server.

Keys are collected before any is deleted: removing from a map while iterating
it is not allowed.
*/
static_cache_evict :: proc(st: ^Static) {
	now := time.now()
	victims: [STATIC_EVICT_BATCH]string

	// a small configured limit must not be cleared wholesale by one pass
	batch := STATIC_EVICT_BATCH
	if limit := st.cfg.max_cache_entries; limit > 0 && batch > limit / 2 {
		batch = limit / 2
	}
	if batch < 1 {
		batch = 1
	}

	n := 0
	for k, e in st.cache {
		if n >= batch {
			break
		}
		if time.diff(e.checked, now) >= st.cfg.cache_ttl {
			victims[n] = k
			n += 1
		}
	}
	if n < batch {
		for k in st.cache {
			if n >= batch {
				break
			}
			dup := false
			for i in 0 ..< n {
				if victims[i] == k {
					dup = true
					break
				}
			}
			if !dup {
				victims[n] = k
				n += 1
			}
		}
	}
	for i in 0 ..< n {
		delete_key(&st.cache, victims[i])
		delete(victims[i], st.allocator)
	}
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
