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
  - A response builder, a `Filter` chain (chunked encoding built in and
    registered by default, gzip/TLS are extension points), a router with
    `:param`/`*` patterns and an Odin-native middleware chain, and a
    static file handler with stat caching and zero-copy `sendfile`.
  - A reverse proxy: round-robin upstreams, prefix stripping,
    X-Forwarded-For / X-Forwarded-Proto / Via headers, hop-by-hop
    filtering, and faithful relaying of Content-Length / chunked /
    close-delimited responses.
  - Per-connection arena allocation: all per-request scratch memory is
    freed in one shot between keep-alive requests.

Not included (deliberately): TLS (plug a `Filter` over the socket layer),
HTTP/2, a config-file language, dynamic module loading.

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
