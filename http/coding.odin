package http

/*
Content coding as *rules* (RFC 7231 section 3.1.2.1), not as code:

  - `Coding` names a coding this library can produce;
  - `negotiate_coding` reads `Accept-Encoding` and answers which one to use;
  - `content_type_compressible` answers whether a media type is worth coding.

The codecs themselves live in the `coding` package (bit writer, LZ77, CRC-32),
and the filter that applies the answer to a live response lives in `web`,
because only it can see a `Conn`. Keeping the decision here means it is
testable without a socket, and means there is exactly one implementation of
"should this be coded" in the whole library.

The rule of thumb behind `content_type_compressible` is that coding helps when
the payload is text-like and hurts when it is already dense: PNG, JPEG, video
and any pre-compressed archive grow slightly when deflated again.
*/

// Coding is a content coding this library implements.
Coding :: enum u8 {
	Identity,
	Gzip,
	Deflate,
}

// coding_name is the token used in `Content-Encoding`.
coding_name :: proc(c: Coding) -> string {
	switch c {
	case .Gzip:
		return "gzip"
	case .Deflate:
		return "deflate"
	case .Identity:
		return "identity"
	}
	return "identity"
}

/*
negotiate_coding picks the coding to answer with, given an `Accept-Encoding`
value.

The rules that matter in practice:

  - an absent or empty header means identity (RFC 7231 section 5.3.4);
  - `q=0` means "not acceptable", which is not the same as "not mentioned":
    `gzip;q=0` must leave the body identity, otherwise a client that told us
    it cannot decode gzip gets gzip;
  - `*` covers every coding that is not named explicitly;
  - a tie goes to gzip, then deflate: both are equally acceptable to the
    client and gzip saves more;
  - unknown codings (`br`, `zstd`) are ignored rather than rejected; identity
    is always a valid answer.

`allow_gzip` / `allow_deflate` are the *server's* half of the question: a
coding this server does not produce is treated as one the client never offered,
so the other one is chosen instead of falling back to identity.
*/
negotiate_coding :: proc(header: string, allow_gzip := true, allow_deflate := true) -> Coding {
	q_gzip, q_deflate: int
	has_gzip, has_deflate: bool
	q_star := -1

	rest := header
	for len(rest) > 0 {
		item := rest
		if comma := string_index_byte(rest, ','); comma >= 0 {
			item = rest[:comma]
			rest = rest[comma + 1:]
		} else {
			rest = ""
		}
		item = trim_ows(item)
		if len(item) == 0 {
			continue
		}
		name := item
		q := 1000
		if semi := string_index_byte(item, ';'); semi >= 0 {
			name = trim_ows(item[:semi])
			q = coding_q_value(item[semi + 1:])
		}
		switch {
		case eq_ignore_case(name, "gzip") || eq_ignore_case(name, "x-gzip"):
			if !has_gzip || q > q_gzip {
				q_gzip, has_gzip = q, true
			}
		case eq_ignore_case(name, "deflate"):
			if !has_deflate || q > q_deflate {
				q_deflate, has_deflate = q, true
			}
		case name == "*":
			q_star = q
		}
	}

	// A coding that was not named inherits the wildcard, if there was one.
	if !has_gzip && q_star >= 0 {
		q_gzip, has_gzip = q_star, true
	}
	if !has_deflate && q_star >= 0 {
		q_deflate, has_deflate = q_star, true
	}

	// A coding this server cannot produce is not a candidate, the same way an
	// unmentioned one is not. This has to come after the wildcard: `*` must
	// not resurrect a coding that is switched off.
	if !allow_gzip {
		has_gzip = false
	}
	if !allow_deflate {
		has_deflate = false
	}

	// Identity is not weighed against the codings: a client that sends
	// `Accept-Encoding` at all is telling us a coded body is fine, so the only
	// question is which coding. `identity` is what we answer when none is
	// acceptable (a 406 is the caller's decision - see the note above).
	best := Coding.Identity
	best_q := 0
	if has_gzip && q_gzip > best_q {
		best, best_q = .Gzip, q_gzip
	}
	if has_deflate && q_deflate > best_q {
		best, best_q = .Deflate, q_deflate
	}
	return best
}

// coding_q_value finds the `q=` weight in a `;`-separated parameter list and
// returns it in thousandths. A missing weight is 1000; a malformed one is 0,
// i.e. "not acceptable" - rounding a broken weight upwards could send a coding
// the client cannot read.
@(private = "file")
coding_q_value :: proc(params: string) -> int {
	rest := params
	for len(rest) > 0 {
		param := rest
		if semi := string_index_byte(rest, ';'); semi >= 0 {
			param = rest[:semi]
			rest = rest[semi + 1:]
		} else {
			rest = ""
		}
		param = trim_ows(param)
		if !has_prefix_ignore_case(param, "q=") {
			continue
		}
		return parse_qvalue(param[2:])
	}
	return 1000
}

// parse_qvalue parses "0", "1", "0.5", "1.000" into thousandths. Anything
// outside 0..1, or with junk after the number, is 0.
@(private = "file")
parse_qvalue :: proc(raw: string) -> int {
	s := trim_ows(raw)
	if len(s) == 0 {
		return 0
	}
	i := 0
	whole := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		whole = whole * 10 + int(s[i] - '0')
		i += 1
		if whole > 1 {
			return 0
		}
	}
	val := whole * 1000
	if i < len(s) && s[i] == '.' {
		i += 1
		scale := 100
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			if scale > 0 {
				val += int(s[i] - '0') * scale
				scale /= 10
			}
			i += 1
		}
	}
	if i != len(s) || val > 1000 {
		return 0
	}
	return val
}

// COMPRESSIBLE_TYPES lists the non-text media types worth coding; anything
// starting with "text/" is compressible by definition.
COMPRESSIBLE_TYPES := [?]string {
	"application/json",
	"application/javascript",
	"application/x-javascript",
	"application/xml",
	"image/svg+xml",
}

// content_type_compressible reports whether a media type benefits from content
// coding. An empty value is not compressible: without a type the filter cannot
// tell a JSON document from a PNG.
content_type_compressible :: proc(content_type: string) -> bool {
	if len(content_type) == 0 {
		return false
	}
	if has_prefix_ignore_case(content_type, "text/") {
		return true
	}
	for t in COMPRESSIBLE_TYPES {
		if has_prefix_ignore_case(content_type, t) {
			return true
		}
	}
	return false
}
