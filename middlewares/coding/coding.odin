package coding

import "../../web"

/*
Route-level control over content coding.

The coding itself is not done here: `web.Coding_Filter` is a server-wide
`Filter` that negotiates `Accept-Encoding`, codes the body and adds
`Vary: Accept-Encoding`. These two middleware set the per-response override
the filter reads (`Response.coding`, `Response.coding_min_size`), which is how
one route can insist on coding (a 40 KB JSON report) while another refuses it
(a response that is already compressed, or a stream whose length does not
exist yet).

	report := web.router_get(&r, "/report", report_handler)
	web.router_use_route(report, middleware_coding, &Coding_Config{min_size = 512})

	stream := web.router_get(&r, "/events", events_handler)
	web.router_use_route(stream, middleware_no_coding)

Registering `middleware_coding` on a route whose handler writes a small body
without `force` changes nothing: the filter's size threshold still applies.
`force = true` is the "I know better than the heuristic" switch.

Both codings the filter can produce (gzip, deflate) are covered, which is why
the package is named after the concept rather than after one of them.
*/

// Coding_Config configures middleware_coding; `min_size` overrides the filter's
// own threshold for this route (0 means "leave it alone"), `force` codes the
// body regardless of size and content type.
Coding_Config :: struct {
	min_size: int,
	force:    bool,
}

// middleware_coding opts a route into content coding.
middleware_coding :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^Coding_Config) m.ud
	if cfg != nil {
		if cfg.min_size > 0 {
			res.coding_min_size = cfg.min_size
		}
		if cfg.force {
			res.coding = .Force
		}
	} else {
		res.coding = .Force
	}
	web.router_next(r, idx + 1, final, req, res)
}

/*
middleware_no_coding keeps a response uncoded. Use it on

  - already-compressed payloads (images, video, .gz assets, a signed blob);
  - anything streamed, where the body length is unknown until the end and
    buffering to compress would defeat the point;
  - Range responses, whose byte offsets refer to the identity body.

The SSE helpers in the parent package write their own head and never build a
`Response`, so streams that use them do not need this.
*/
middleware_no_coding :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	res.coding = .Deny
	web.router_next(r, idx + 1, final, req, res)
}
