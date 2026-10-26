package middlewares

import ".."

/*
middleware_form parses the request body once, before the route handler runs,
so the handler reads fields and files through `request_form` /
`request_files` without caring which encoding the client picked. It also
owns the three encoding answers a handler should not have to write:

  - 415 when `require_form` is set and the body is not a form at all
  - 400 for a multipart body with a missing or broken boundary
  - 413 when a field count or file size limit is hit

Parsing itself lives in the parent package (`form_ensure_parsed`), next
to the request: the lazy accessors need it, and a subpackage cannot be
imported by its parent without a cycle.

Limits stay per-request: `MAX_FORM_FIELDS` and `MAX_FORM_FILE_SIZE`
unless `Form_Config` overrides them, on top of `Server.max_body_size`
bounding the body as a whole. Uploads are held in memory - see
`upload.odin` for the variant that spools them to disk.
*/
middleware_form :: proc(m: ^web.Middleware, r: ^web.Router, idx: int, final: web.Handler, req: ^web.Request, res: ^web.Response) {
	cfg := cast(^web.Form_Config) m.ud
	switch web.form_ensure_parsed(req, cfg) {
	case .None:
	case .Not_A_Form:
		if cfg != nil && cfg.require_form {
			web.response_error(res, .Unsupported_Media, "")
			return
		}
	case .Bad_Boundary, .Malformed, .Sink_Error:
		web.response_error(res, .Bad_Request, "")
		return
	case .Too_Many_Fields, .File_Too_Large, .Too_Large:
		web.response_error(res, .Payload_Too_Large, "")
		return
	}
	web.router_next(r, idx + 1, final, req, res)
}
