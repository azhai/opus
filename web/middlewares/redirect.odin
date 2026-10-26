package middlewares

import ".."
import "core:mem"

/*
Redirects. Two shapes, because they solve different problems:

  - `middleware_redirect` answers a path with a redirect to another path.
    Use it when a URL moved (a renamed section, an old API version) and the
    client has to be told, so search engines and bookmarks follow.
  - `middleware_https_redirect` answers an http request with the same URL
    over https. Use it when TLS is terminated by this server and plain http
    should not exist at all.

Both send a `Location` and stop the chain: the target is answered on the
second request, not this one. For "serve this path as if it were that one,
without telling the client", use the router's rewrites instead
(`web.router_rewrite`).

Which status to pick:

  - 301 Moved Permanently - the old URL is gone for good. Browsers cache it
    permanently, which is unforgiving if you change your mind.
  - 308 Permanent Redirect - 301 that keeps the method (a POST stays a POST).
  - 302 Found - temporary; browsers may rewrite POST to GET (they do).
  - 307 Temporary Redirect - temporary and method-preserving.

An unset `code` therefore means 308, and 307 is the temporary one: both
preserve the request method, unlike 301 and 302.
*/

// Redirect_Rule is one "from -> to" pair. `from` matches a whole path when
// `exact` is set, otherwise a path prefix at a segment boundary; the suffix
// and the query string are carried over, so `/old/a/b?x=1` keeps `/a/b?x=1`.
//
// `to` may be a path or an absolute URL ("https://example.com/x"), which is
// how a host-level redirect is expressed.
Redirect_Rule :: struct {
	from:  string,
	to:    string,
	code:  web.Status, // zero => 308 (permanent, method-preserving)
	exact: bool,
}

// Redirect_Config configures middleware_redirect. Rules are tried in order
// and the first match wins, so list the specific paths before the general
// prefixes.
Redirect_Config :: struct {
	rules: []Redirect_Rule,
}

// middleware_redirect answers with a redirect when a rule matches, and
// continues the chain otherwise.
middleware_redirect :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Redirect_Config) m.ud
	if cfg != nil {
		for rule in cfg.rules {
			rest, matched := redirect_match(req.path, rule)
			if !matched {
				continue
			}
			alloc := web.response_allocator(res)
			target := rule.to
			if len(rest) > 0 && !is_absolute_url(rule.to) {
				target = join_target(rule.to, rest, alloc)
			}
			if len(req.query) > 0 && !is_absolute_url(rule.to) {
				target = web.concat_strings({target, "?", req.query}, alloc)
			}
			web.response_redirect(res, target, redirect_code(rule.code))
			return
		}
	}
	web.router_next(r, idx + 1, final, req, res)
}

// join_target appends the unmatched suffix to a redirect target without
// leaving a double slash in the Location: a rule from "/docs" to "/assets/"
// sends "/docs/index.html" to "/assets/index.html", not "//index.html".
join_target :: proc(to, rest: string, alloc: mem.Allocator) -> string {
	if len(to) > 0 && to[len(to) - 1] == '/' && rest[0] == '/' {
		return web.concat_strings({to, rest[1:]}, alloc)
	}
	return web.concat_strings({to, rest}, alloc)
}

// redirect_match returns the part of the path that follows a matching rule.
redirect_match :: proc(path: string, rule: Redirect_Rule) -> (rest: string, ok: bool) {
	if rule.exact {
		if path == rule.from {
			return "", true
		}
		return "", false
	}
	if len(path) < len(rule.from) {
		return "", false
	}
	for i in 0..<len(rule.from) {
		if path[i] != rule.from[i] {
			return "", false
		}
	}
	if len(path) == len(rule.from) {
		return "", true
	}
	if len(rule.from) > 0 && rule.from[len(rule.from) - 1] == '/' {
		return path[len(rule.from):], true
	}
	if path[len(rule.from)] != '/' {
		return "", false
	}
	return path[len(rule.from):], true
}

// redirect_code maps the zero value to 308: permanent and method-preserving.
redirect_code :: proc(code: web.Status) -> web.Status {
	#partial switch code {
	case .Found, .Temporary_Redirect, .Permanent_Redirect, .Moved_Permanently:
		return code
	case:
		return .Permanent_Redirect
	}
}

/*
Https_Redirect_Config configures middleware_https_redirect.

`port` is the port to put in the URL; leave it 0 when https is on the
default port (or when the Host header already carries the right one). The
host is taken from the request, so a redirect never invents a name - but
that also means a client can send any Host it likes. Validate `Host`
yourself (or front this with a proxy that does) before relying on it.
*/
Https_Redirect_Config :: struct {
	port: int,        // 0 = default (443), omitted from the URL
	code: web.Status, // .Permanent_Redirect when zero
}

// middleware_https_redirect sends the same URL back over https. It uses the
// transport this server terminates (`web.request_scheme`), so behind a TLS
// proxy - where the server only ever sees plain http - it would loop; use
// the proxy's own redirect (or X-Forwarded-Proto) there instead.
middleware_https_redirect :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	if web.request_scheme(req) == "https" {
		web.router_next(r, idx + 1, final, req, res)
		return
	}
	cfg := cast(^Https_Redirect_Config) m.ud
	alloc := web.response_allocator(res)

	host := web.request_hostname(req)
	if len(host) == 0 {
		host = "localhost"
	}
	target := web.concat_strings({"https://", host}, alloc)
	if cfg != nil && cfg.port > 0 && cfg.port != 443 {
		target = web.concat_strings({target, ":", web.int_to_string(i64(cfg.port), alloc)}, alloc)
	}
	target = web.concat_strings({target, req.target}, alloc)

	code := web.Status.Permanent_Redirect
	if cfg != nil && cfg.code != .OK {
		code = cfg.code
	}
	web.response_redirect(res, target, code)
}

// is_absolute_url reports whether `s` starts with a scheme, in which case a
// suffix must not be appended to it.
is_absolute_url :: proc(s: string) -> bool {
	return web.has_prefix_ci(s, "http://") || web.has_prefix_ci(s, "https://")
}
