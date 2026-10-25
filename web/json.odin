package web

import "core:encoding/json"

/*
JSON responses, backed by core:encoding/json.

response_json marshals any Odin value and writes it as the response body
with the application/json content type. The marshaled bytes are staged on
the connection scratch arena and copied into the response body, so they
do not outlive the call.
*/

// response_json marshals `v` as JSON and writes it as the response body
// with Content-Type: application/json. The handler may set the status
// before calling. On marshal failure the response becomes a 500 with a
// plain-text body and the error is returned.
response_json :: proc(w: ^Response, v: any) -> json.Marshal_Error {
	alloc := context.allocator
	if w.conn != nil {
		alloc = conn_scratch(w.conn)
	}
	data, err := json.marshal(v, allocator = alloc)
	if err != nil {
		w.status = .Internal_Error
		response_write_string(w, "500 json marshal failed\n")
		return err
	}
	response_set_header(w, "Content-Type", "application/json")
	response_write(w, data)
	return nil
}

// response_json_status is response_json with the status set in the same
// call (Echo's c.JSON(code, i), Fiber's c.Status(...).JSON(...)).
response_json_status :: proc(w: ^Response, status: Status, v: any) -> json.Marshal_Error {
	w.status = status
	return response_json(w, v)
}
