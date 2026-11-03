package http

import "core:mem"

/*
application/x-www-form-urlencoded: the encoding a browser uses for a query
string and for a form without a file input, and the only one that is decoded
in place.

This is a *rule*, not a request concern, so it lives here rather than in the
request type: a caller with a body in hand and no connection at all (a queue
worker, a test, the session middleware decoding a redirect) can use it.
*/

// Param is one name/value pair. Query strings, form bodies and route
// parameters all reduce to a list of these; repeated keys stay repeated, in
// wire order.
Param :: struct {
	name:  string,
	value: string,
}

// form_parse parses an application/x-www-form-urlencoded body into name/value
// pairs. '+' and %XX are decoded; malformed escapes are kept literally, the
// same tolerance browsers apply to query strings. Empty segments are skipped,
// and a key without '=' maps to an empty value.
//
// Returned names and values are allocated on `allocator` (a decoded string
// cannot be a view into the source), so one allocator per request keeps the
// whole result releasable in one go.
form_parse :: proc(body: string, allocator: mem.Allocator = context.allocator) -> []Param {
	out := make([dynamic]Param, allocator)
	i := 0
	for i <= len(body) {
		j := i
		for j < len(body) && body[j] != '&' {
			j += 1
		}
		item := body[i:j]
		if len(item) > 0 {
			eq := string_index_byte(item, '=')
			name, value: string
			if eq >= 0 {
				name = item[:eq]
				value = item[eq + 1:]
			} else {
				name = item
			}
			append(&out, Param {
				name  = url_decode(name, allocator),
				value = url_decode(value, allocator),
			})
		}
		i = j + 1
		if j >= len(body) {
			break
		}
	}
	return out[:]
}

// param_get returns the first value for name in a name/value list; it works
// for query strings, form bodies and route parameters alike (first wins, the
// way every framework's FormValue does).
param_get :: proc(params: []Param, name: string) -> (string, bool) {
	for p in params {
		if p.name == name {
			return p.value, true
		}
	}
	return "", false
}

/*
query_param returns the first value of `name` in a raw query string (the part
after the '?'), decoded. The scan is one pass and does not build the full list:
a handler that wants one parameter should not pay for decoding all of them.

Keys compare after decoding, so "%6Eame" matches "name" - which is what a
client that double-encoded a key expects.
*/
query_param :: proc(query, name: string, allocator: mem.Allocator = context.allocator) -> (string, bool) {
	q := query
	for len(q) > 0 {
		end := string_index_byte(q, '&')
		pair := q
		if end >= 0 {
			pair = q[:end]
			q = q[end + 1:]
		} else {
			q = ""
		}
		eq := string_index_byte(pair, '=')
		if eq < 0 {
			continue
		}
		if url_decode(pair[:eq], allocator) == name {
			return url_decode(pair[eq + 1:], allocator), true
		}
	}
	return "", false
}

// query_param_all returns every value for `name`, in order: a repeated query
// key is legitimate and the caller may need all of it.
query_param_all :: proc(query, name: string, allocator: mem.Allocator = context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	q := query
	for len(q) > 0 {
		end := string_index_byte(q, '&')
		pair := q
		if end >= 0 {
			pair = q[:end]
			q = q[end + 1:]
		} else {
			q = ""
		}
		eq := string_index_byte(pair, '=')
		if eq < 0 {
			continue
		}
		if url_decode(pair[:eq], allocator) == name {
			append(&out, url_decode(pair[eq + 1:], allocator))
		}
	}
	return out[:]
}
