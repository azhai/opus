package middleware

import ".."

/*
Per-route control over the gzip/deflate filter.

The filter itself is a server-wide `Filter`: it negotiates `Accept-Encoding`,
codes the body and adds `Vary: Accept-Encoding`. These two middleware do not
compress anything - they set the per-response override the filter reads, which
is how one route can insist on coding (a 40 KB JSON report) while another
refuses it (a response that is already compressed, or a stream whose length
does not exist yet).

	report := web.router_get(&r, "/report", report_handler)
	web.router_use_route(report, middleware_gzip, &Gzip_Config{min_size = 512})

	stream := web.router_get(&r, "/events", events_handler)
	web.router_use_route(stream, middleware_no_gzip)

Registering `middleware_gzip` on a route whose handler writes a small body
without `force` changes nothing: the filter's size threshold still applies.
`force = true` is the "I know better than the heuristic" switch.
*/

// Gzip_Config configures middleware_gzip; `min_size` overrides the filter's
// own threshold for this route (0 means "leave it alone"), `force` codes the
// body regardless of size and content type.
Gzip_Config :: struct {
	min_size: int,
	force:    bool,
}

// middleware_gzip opts a route into content coding.
middleware_gzip :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Gzip_Config) m.ud
	if cfg != nil {
		if cfg.min_size > 0 {
			res.compress_min = cfg.min_size
		}
		if cfg.force {
			res.compress = .Force
		}
	} else {
		res.compress = .Force
	}
	web.router_next(r, idx + 1, final, req, res)
}

/*
middleware_no_gzip keeps a response uncoded. Use it on

  - already-compressed payloads (images, video, .gz assets, a signed blob);
  - anything streamed, where the body length is unknown until the end and
    buffering to compress would defeat the point;
  - Range responses, whose byte offsets refer to the identity body.

The SSE helpers in the parent package write their own head and never build a
`Response`, so streams that use them do not need this.
*/
middleware_no_gzip :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	res.compress = .Deny
	web.router_next(r, idx + 1, final, req, res)
}
