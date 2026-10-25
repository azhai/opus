package web

import "core:mem"

/*
Form bodies: `application/x-www-form-urlencoded` and `multipart/form-data`.

`form_parse` (request.odin) has always decoded urlencoded bodies; this file
adds the multipart half and a middleware that parses either encoding exactly
once per request, so a handler can read fields and uploaded files without
caring which one the client picked.

Multipart parsing is deliberately in-memory: `MAX_FORM_FILE_SIZE` bounds a
single part and `Server.max_body_size` bounds the whole body, so a request
cannot make the parser allocate more than it already read. Streaming an
upload to disk is a different product (a file service, not a web framework
router); the in-memory form is what a contact form, a profile picture and a
CSV import need.

Parsing rule that matters: a part is a *file* when its Content-Disposition
carries a `filename` parameter - even an empty one. Browsers omit
Content-Type on text fields, and send `filename=""` for an empty file input;
keying off Content-Type would turn every empty file input into a field.
*/

// MAX_FORM_FIELDS caps the number of non-file parts decoded per request.
MAX_FORM_FIELDS :: 256

// MAX_FORM_FILE_SIZE caps a single uploaded part (8 MiB). The whole body is
// already bounded by `Server.max_body_size`.
MAX_FORM_FILE_SIZE :: 8 << 20

Form_File :: struct {
	field:        string, // the `name="..."` of the part
	filename:     string, // client-supplied base name, path components stripped
	content_type: string, // part Content-Type, empty when the client sent none
	data:         []byte, // a view into the request body: valid until it is done
}

Form_State :: enum u8 {
	Unparsed,
	Parsed,
	Malformed, // the body claimed a form encoding it did not have
	Too_Large, // a field or file limit was hit
}

Form_Error :: enum {
	None,
	Not_A_Form, // neither urlencoded nor multipart (or an empty body)
	Bad_Boundary,
	Malformed,
	Too_Many_Fields,
	File_Too_Large,
	Too_Large, // a cached parse hit a limit; the specific one is gone
}

// Form_Config configures middleware_form. Zero fields mean the defaults:
// MAX_FORM_FIELDS, MAX_FORM_FILE_SIZE, and `require_form = false`
// (a non-form body is left alone for a JSON handler to consume).
Form_Config :: struct {
	max_fields:    int,
	max_file_size: int,
	require_form:  bool,
}

// request_is_multipart reports a multipart/form-data body.
request_is_multipart :: proc(r: ^Request) -> bool {
	return eq_ignore_case(request_content_type(r), "multipart/form-data")
}

// request_files returns every uploaded file of a multipart body, parsing it
// on first use (defaults, no enforcement).
request_files :: proc(r: ^Request) -> []Form_File {
	form_ensure_parsed(r, nil)
	return r.files
}

// request_file returns the first upload with the given field name.
request_file :: proc(r: ^Request, field: string) -> (file: Form_File, ok: bool) {
	for f in request_files(r) {
		if f.field == field {
			return f, true
		}
	}
	return {}, false
}

/*
form_ensure_parsed decodes the request body once and caches the result on
the request (`form`, `files`, `form_state`), which is what makes both the
middleware and the lazy `request_form` / `request_files` accessors cheap and
idempotent.

The body encoding decides the parser:
  - multipart/form-data      -> multipart_parse
  - urlencoded, no type      -> form_parse (browsers always set the type, but
                                a hand-rolled client that forgets it still works)
  - empty body               -> an empty form, not an error
  - anything else            -> Not_A_Form, left unparsed
*/
form_ensure_parsed :: proc(r: ^Request, cfg: ^Form_Config) -> Form_Error {
	switch r.form_state {
	case .Parsed:
		return .None
	case .Malformed:
		return .Malformed
	case .Too_Large:
		return .Too_Large
	case .Unparsed:
	}

	max_file := MAX_FORM_FILE_SIZE
	max_fields := MAX_FORM_FIELDS
	if cfg != nil {
		if cfg.max_file_size > 0 {
			max_file = cfg.max_file_size
		}
		if cfg.max_fields > 0 {
			max_fields = cfg.max_fields
		}
	}

	alloc := request_allocator(r)

	if request_is_multipart(r) {
		raw, _ := request_header(r, "Content-Type")
		boundary := multipart_boundary_param(raw)
		if len(boundary) == 0 {
			r.form_state = .Malformed
			return .Bad_Boundary
		}
		fields, files, err := multipart_parse(r.body, boundary, alloc, max_file, max_fields)
		switch err {
		case .None:
			r.form, r.files, r.form_state = fields, files, .Parsed
			return .None
		case .Too_Many_Fields, .File_Too_Large:
			r.form_state = .Too_Large
			return err
		case .Not_A_Form, .Bad_Boundary, .Too_Large, .Malformed:
			r.form_state = .Malformed
			return .Malformed
		}
	}

	if len(r.body) == 0 {
		r.form_state = .Parsed
		return .None
	}

	if ct := request_content_type(r); len(ct) == 0 || eq_ignore_case(ct, "application/x-www-form-urlencoded") {
		r.form = form_parse(string(r.body), alloc)
		r.form_state = .Parsed
		return .None
	}
	return .Not_A_Form
}

// middleware_form parses the body before the route handler runs and answers
// the encoding errors itself: 415 for a body that is not a form when
// `require_form` is set, 400 for a broken multipart body, 413 for a limit.
middleware_form :: proc(m: ^Middleware, r: ^Router, idx: int, final: Handler, req: ^Request, res: ^Response) {
	cfg := cast(^Form_Config) m.ud
	switch form_ensure_parsed(req, cfg) {
	case .None:
	case .Not_A_Form:
		if cfg != nil && cfg.require_form {
			response_error(res, .Unsupported_Media, "")
			return
		}
	case .Bad_Boundary, .Malformed:
		response_error(res, .Bad_Request, "")
		return
	case .Too_Many_Fields, .File_Too_Large, .Too_Large:
		response_error(res, .Payload_Too_Large, "")
		return
	}
	router_next(r, idx + 1, final, req, res)
}

// ---------------------------------------------------------------------------
// Multipart parsing
// ---------------------------------------------------------------------------

/*
multipart_parse decodes an RFC 7578 multipart/form-data body.

The grammar it walks, with `D = "--" boundary`:

	D CRLF part *(" CRLF " D CRLF part) " CRLF " D "--" CRLF

Each part is a header block, a blank line and the content, so the content of
a part ends at the CRLF that precedes the next delimiter - a body containing
the bare boundary string (without the leading CRLF) cannot terminate a part
early. Header values stay views into `body`; nothing is copied except the
dynamic arrays themselves.
*/
multipart_parse :: proc(
	body: []byte,
	boundary: string,
	allocator: mem.Allocator,
	max_file_size, max_fields: int,
) -> (fields: []Param, files: []Form_File, err: Form_Error) {
	f := make([dynamic]Param, allocator)
	fl := make([dynamic]Form_File, allocator)

	delim := concat_strings({"--", boundary}, allocator)
	sep := concat_strings({"\r\n", delim}, allocator)

	pos := bytes_index(body, delim)
	if pos < 0 {
		return f[:], fl[:], .Bad_Boundary
	}
	pos += len(delim)

	for {
		// a delimiter followed by "--" closes the body
		if pos + 1 < len(body) && body[pos] == '-' && body[pos + 1] == '-' {
			return f[:], fl[:], .None
		}
		// transport padding is legal before the CRLF that ends the delimiter
		for pos < len(body) && (body[pos] == ' ' || body[pos] == '\t') {
			pos += 1
		}
		if pos + 1 >= len(body) || body[pos] != '\r' || body[pos + 1] != '\n' {
			return f[:], fl[:], .Malformed
		}
		pos += 2

		hend := bytes_index(body[pos:], "\r\n\r\n")
		if hend < 0 {
			return f[:], fl[:], .Malformed
		}
		head := string(body[pos:pos + hend])
		content_start := pos + hend + 4

		next := bytes_index(body[content_start:], sep)
		if next < 0 {
			return f[:], fl[:], .Malformed
		}
		content := body[content_start:content_start + next]
		pos = content_start + next + len(sep)

		name, filename, ctype, is_file := multipart_part_meta(head)
		if len(name) == 0 {
			// a part with no field name is not form data (some clients send
			// an unnamed preamble part); skipping it is more useful than 400
			continue
		}
		if is_file {
			if max_file_size > 0 && len(content) > max_file_size {
				return f[:], fl[:], .File_Too_Large
			}
			append(&fl, Form_File {
				field        = name,
				filename     = filename,
				content_type = ctype,
				data         = content, // view into the request body
			})
			continue
		}
		if max_fields > 0 && len(f) >= max_fields {
			return f[:], fl[:], .Too_Many_Fields
		}
		append(&f, Param{name = name, value = string(content)})
	}
}

// multipart_part_meta pulls the three fields the parser needs out of a part
// header block: field name, file name marker, part content type.
multipart_part_meta :: proc(head: string) -> (name, filename, ctype: string, is_file: bool) {
	rest := head
	for len(rest) > 0 {
		nl := string_index(rest, "\r\n")
		line := rest
		if nl >= 0 {
			line = rest[:nl]
			rest = rest[nl + 2:]
		} else {
			rest = ""
		}
		colon := string_index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		key := trim_ows(line[:colon])
		value := trim_ows(line[colon + 1:])
		switch {
		case eq_ignore_case(key, "Content-Disposition"):
			if v, ok := header_param(value, "name"); ok {
				name = v
			}
			if v, ok := header_param(value, "filename"); ok {
				filename = strip_path_components(v)
				is_file = true
			}
		case eq_ignore_case(key, "Content-Type"):
			ctype = value
		}
	}
	return
}

// multipart_boundary_param extracts the `boundary` parameter of a
// multipart Content-Type. RFC 2046 allows it quoted or bare; both are
// accepted, and the value is returned as-is (boundaries are token-safe).
multipart_boundary_param :: proc(content_type: string) -> string {
	if len(content_type) == 0 {
		return ""
	}
	v, _ := header_param(content_type, "boundary")
	return v
}

// header_param returns the value of one `;`-separated parameter of a header
// value, unquoted. Parameter names match case-insensitively; a name that
// merely ends with the wanted one ("filename*" vs "filename") does not
// match, so an RFC 5987 extended value never shadows the plain one.
header_param :: proc(value, param: string) -> (string, bool) {
	rest := value
	for len(rest) > 0 {
		semi := string_index_byte(rest, ';')
		seg := rest
		if semi >= 0 {
			seg = rest[:semi]
			rest = rest[semi + 1:]
		} else {
			rest = ""
		}
		seg = trim_ows(seg)
		eq := string_index_byte(seg, '=')
		if eq <= 0 {
			continue // the leading "media type" segment has no '='
		}
		if !eq_ignore_case(trim_ows(seg[:eq]), param) {
			continue
		}
		return unquote_header_value(trim_ows(seg[eq + 1:])), true
	}
	return "", false
}

// unquote_header_value strips one layer of double quotes.
unquote_header_value :: proc(v: string) -> string {
	if len(v) >= 2 && v[0] == '"' && v[len(v) - 1] == '"' {
		return v[1:len(v) - 1]
	}
	return v
}

// strip_path_components reduces a client-supplied file name to its base
// name: browsers may send a full local path (IE used to), and the name is
// echoed into Content-Disposition on download.
strip_path_components :: proc(name: string) -> string {
	out := name
	if i := last_index_byte(out, '/'); i >= 0 {
		out = out[i + 1:]
	}
	if i := last_index_byte(out, '\\'); i >= 0 {
		out = out[i + 1:]
	}
	return out
}
