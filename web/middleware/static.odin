package middleware

import ".."

/*
`middleware_static` serves a directory tree for the routes it is registered
on, and falls through when the path is not a file. That fall-through is what
makes it usable in a router instead of as a whole-server handler:

	assets := web.router_all(&r, "/assets/:rest", web.router_fallthrough_not_found)
	web.router_use_route(assets, middleware_static, &Static_Mount_Config{st = &files})

	// or, for a single-page app: every unmatched path renders index.html
	spa := web.router_get(&r, "/:rest", spa_handler) // last route
	web.router_use_route(spa, middleware_static, &Static_Mount_Config{st = &files, spa = true})

Serving itself is the parent package's `static_serve_root`, so the stat
cache, `sendfile`, Range requests and `Last-Modified`/304 all apply. The
middleware only decides *whether* to serve and *which* path to serve:
`prefix` is stripped from the request path before it is handed over, so
`/assets/css/a.css` reads `www/css/a.css`.

The lookup is done with `static_lookup` (the cached stat) before serving, so
a fall-through costs one cached stat, not a failed file open.
*/

// Static_Mount_Config configures middleware_static.
//
// `st` is a `web.Static` the caller initialised and keeps alive; several
// mounts can share one. `prefix` is the URL prefix to strip. `spa` makes an
// unknown path render the index file instead of falling through - the
// single-page-app convention, where every route is a client-side route and
// the server only owns the assets.
Static_Mount_Config :: struct {
	st:     ^web.Static,
	prefix: string,
	spa:    bool,
}

middleware_static :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Static_Mount_Config) m.ud
	if cfg == nil || cfg.st == nil {
		web.router_next(r, idx + 1, final, req, res)
		return
	}
	if req.method != .Get && req.method != .Head {
		web.router_next(r, idx + 1, final, req, res)
		return
	}

	alloc := web.request_allocator(req)
	rel := req.path
	if len(cfg.prefix) > 0 {
		rest, ok := strip_url_prefix(req.path, cfg.prefix)
		if !ok {
			web.router_next(r, idx + 1, final, req, res)
			return
		}
		rel = rest
	}
	if len(rel) == 0 {
		rel = "/"
	}

	fs_path, path_ok := web.static_resolve_path(cfg.st, rel, alloc)
	if path_ok {
		entry, found := web.static_lookup(cfg.st, fs_path)
		if found && entry.exists {
			static_serve_relative(cfg.st, req, res, rel)
			return
		}
	}

	if cfg.spa {
		// unknown path: the client-side router owns it, so send the shell
		static_serve_relative(cfg.st, req, res, "/")
		return
	}
	web.router_next(r, idx + 1, final, req, res)
}

// static_serve_relative serves `rel` out of `st`. The parent's helper reads
// `req.path`, so the (prefix-stripped) path is swapped in for the duration
// and restored afterwards - a handler must not leave a rewritten path behind
// for the access log.
static_serve_relative :: proc(st: ^web.Static, req: ^web.Request, res: ^web.Response, rel: string) {
	saved := req.path
	req.path = rel
	web.static_serve_root(st, req, res)
	req.path = saved
}

// strip_url_prefix removes `prefix` from `path` at a segment boundary:
// "/assets" + "/assets/css/a.css" -> "/css/a.css", and "/assetsx" does not
// match. A bare prefix match yields "/".
strip_url_prefix :: proc(path, prefix: string) -> (rest: string, ok: bool) {
	if len(path) < len(prefix) {
		return "", false
	}
	if len(prefix) > 0 && !prefix_matches(path, prefix) {
		return "", false
	}
	rest = path[len(prefix):]
	if len(rest) == 0 {
		return "/", true
	}
	if rest[0] != '/' {
		return "", false
	}
	return rest, true
}

prefix_matches :: proc(path, prefix: string) -> bool {
	for i in 0..<len(prefix) {
		if path[i] != prefix[i] {
			return false
		}
	}
	if len(path) == len(prefix) {
		return true
	}
	if prefix[len(prefix) - 1] == '/' {
		return true
	}
	return path[len(prefix)] == '/'
}
