/*
Package web is an embeddable HTTP/1.1 foundation library for Odin.

Design DNA:

  - Mongoose (cesanta/mongoose): API ergonomics and engineering shape.
    One `Server` + one event loop + per-connection `Conn` struct + event
    style callbacks. Single package, zero third-party dependencies, small
    footprint. `server_run` is the whole integration surface.

  - lighttpd2: internal architecture. A dual-layer state machine
    (connection level `Conn_State` and request level parser states),
    a pluggable `Filter` output pipeline, action/middleware composition
    expressed in host-language procedures (no config language), and a
    stat cache for static file serving.

  - core:nbio: the event loop itself. nbio already provides a unified
    non-blocking IO abstraction (io_uring on Linux, kqueue on Darwin,
    IOCP on Windows) with accept/recv/send/sendfile/open/stat/timeout
    operations and a single callback type. web builds on top of it
    instead of hand-rolling epoll/kqueue.

What you get:

  - HTTP/1.1 parsing (zero-copy header slices), keep-alive, request
    bodies (Content-Length + chunked), timeouts, backpressure-aware
    non-blocking writes.
  - Strict request framing per RFC 7230 section 3.3.3: `TE` + `CL`
    together, a `TE` that does not end in chunked, and duplicated or
    conflicting `Content-Length` are answered with 400 instead of being
    resolved silently. The same rules apply to upstream responses, which
    become 502 rather than being relayed.
  - A response builder, a `Filter` chain (chunked encoding and
    gzip/deflate content coding are built in and registered by default),
    a router with `:param` / `*` patterns plus a Lua-pattern subset
    (`(%w+)`, `(%d+)`, `[a-z]`, `.-`, ...) and an Odin-native middleware
    chain - router-wide or attached to a single route with
    `router_use_route`. HEAD is served by the GET route when no HEAD route
    exists. Unmatched requests still walk the middleware chain before the
    404/405 terminal answers. A static file handler with stat caching and
    zero-copy `sendfile` rounds out the routing layer.
  - Application-level context helpers, the surface a Go developer expects
    from Fiber/Echo: `request_hostname`, `request_scheme`,
    `request_client_ip`, `request_content_type`, `request_is_ajax`,
    `request_accepts`, `request_json`, plus `response_json_status`,
    `response_error`, `response_download` and `response_clear_cookie`.
  - Middleware, split by purpose:
      request id, access log (with the authenticated principal), CORS,
      security headers, no-cache, no-buffer for streams;
      auth - basic, bearer tokens and API keys, all comparing in constant
      time and installing `request_principal`;
      form - urlencoded and multipart parsing, files included, parsed once
      per request with field/size limits;
      range - Range and ETag over a body an ordinary handler produced, so
      a handler that writes the whole representation still answers 206,
      416 and 304 correctly.
    Configured ones take their settings through `Middleware.ud`, since
    Odin has no closures.
  - Server-sent events: `sse_start` / `sse_event` / `sse_comment` /
    `sse_retry` / `sse_close` hijack the connection and speak chunked
    framing, so a handler emits events instead of bytes.
  - Range requests (RFC 7233): single ranges stream zero-copy via
    `sendfile` with an offset, multiple ranges answer as
    `multipart/byteranges`, unsatisfiable ranges get 416 with a
    `Content-Range` header carrying the full length.
    `Last-Modified` / `If-Modified-Since` (304) and `If-Range` validators
    are honored.
  - Cookies: `response_set_cookie` / `request_cookie` with Path,
    Domain, Expires, Max-Age, Secure, HttpOnly and SameSite.
  - JSON responses: `response_json` marshals any Odin value with
    `core:encoding/json` and sets the content type.
  - A streaming reverse proxy: round-robin upstreams, prefix stripping,
    X-Forwarded-For / X-Forwarded-Proto / Via headers, hop-by-hop
    filtering, faithful relaying of Content-Length / chunked /
    close-delimited responses, and a pool of idle keep-alive upstream
    connections (with a replay on a fresh connection when a pooled one
    turns out to be stale). The response head reaches the client as soon
    as it arrives; the body is relayed as it streams, so memory stays
    bounded regardless of the response size.
  - TLS, wrapped around the socket layer rather than the state machine:
    attach a `Tls_Config` to the server (`srv.tls = &cfg`) and every
    accepted connection gets an OpenSSL session. OpenSSL is loaded at
    runtime through `core:dynlib`, so there is no build-time C
    dependency. Handlers do not change at all.
  - Multi-acceptor mode: `server_run_multi` starts one `Server` per
    thread, each with its own event loop and its own SO_REUSEPORT
    listener on the same address, so accept/read/write parallelize
    across cores without any locking in the library.
  - Per-connection arena allocation: all per-request scratch memory is
    freed in one shot between keep-alive requests.

Not included (deliberately): HTTP/2, a config-file language, dynamic
module loading, multi-process management (hand it to a supervisor).

Quick start:

	package main

	import "core:fmt"
	import "web"

	hello :: proc(req: ^web.Request, res: ^web.Response) {
		web.response_status(res, .OK)
		web.response_set_header(res, "Content-Type", "text/plain")
		web.response_write_string(res, "hello from odin\n")
	}

	main :: proc() {
		srv: web.Server
		if !web.server_init(&srv, "0.0.0.0:8080") {
			return
		}
		srv.handler = hello
		web.server_run(&srv)
	}
*/
package web
