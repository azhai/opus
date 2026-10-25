package web

// Tests for TLS: configuration, a real handshake and a
// keep-alive exchange. Skipped when OpenSSL is not loadable.

import "base:intrinsics"
import "core:c"
import "core:bytes"
import "core:compress/gzip"
import "core:compress/zlib"
import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
// ---------------------------------------------------------------------------
// TLS (OpenSSL loaded at run time)
// ---------------------------------------------------------------------------

TLS_CERT :: "web/testdata/cert.pem"
TLS_KEY :: "web/testdata/key.pem"

// test_tls_available reports whether libssl could be loaded; the TLS tests
// skip themselves when it cannot, so the suite still passes on a machine
// without OpenSSL.
test_tls_available :: proc() -> bool {
	return tls_load()
}

// Blocking TLS client used by the tests: a plain socket plus SSL_set_fd is
// all it takes when there is no event loop involved.
Tls_Test_Client :: struct {
	sock: net.TCP_Socket,
	ssl:  rawptr,
}

/*
tls_test_connect_ctx does the client half of a handshake on a caller-owned
SSL_CTX. Sharing one context across two connections is what makes
resumption testable: OpenSSL stores the received ticket on the SSL object
and hands it back through SSL_get1_session, but only a second SSL from the
same context can present it.
*/
tls_test_connect_ctx :: proc(ep: net.Endpoint, ctx: rawptr, session: rawptr = nil) -> (client: Tls_Test_Client, ok: bool) {
	sock, derr := net.dial_tcp_from_endpoint(ep)
	if derr != nil {
		return {}, false
	}
	ssl := TLS.ssl_new(ctx)
	if ssl == nil {
		net.close(sock)
		return {}, false
	}
	if session != nil && TLS.set_session(ssl, session) != 1 {
		TLS.ssl_free(ssl)
		net.close(sock)
		return {}, false
	}
	if TLS.set_fd(ssl, i32(sock)) != 1 {
		TLS.ssl_free(ssl)
		net.close(sock)
		return {}, false
	}
	TLS.set_connect_state(ssl)
	if TLS.do_handshake(ssl) != 1 {
		fmt.println("tls client handshake failed:", tls_last_error())
		TLS.ssl_free(ssl)
		net.close(sock)
		return {}, false
	}
	return Tls_Test_Client{sock = sock, ssl = ssl}, true
}

tls_test_connect :: proc(ep: net.Endpoint) -> (client: Tls_Test_Client, ok: bool) {
	ctx := TLS.ctx_new(TLS.client_method())
	if ctx == nil {
		return {}, false
	}
	// SSL_new takes its own reference, so the context can go immediately;
	// the SSL object keeps it alive until SSL_free
	defer TLS.ctx_free(ctx)
	return tls_test_connect_ctx(ep, ctx)
}

tls_test_write :: proc(client: ^Tls_Test_Client, data: string) -> bool {
	return TLS.write(client.ssl, raw_data(data), i32(len(data))) == i32(len(data))
}

// tls_test_read_all reads until the peer closes or the socket goes quiet.
tls_test_read_all :: proc(client: ^Tls_Test_Client) -> []byte {
	out := make([dynamic]byte, context.allocator)
	buf: [8192]byte
	for {
		n := TLS.read(client.ssl, raw_data(buf[:]), i32(len(buf)))
		if n <= 0 {
			break
		}
		append(&out, ..buf[:int(n)])
	}
	return out[:]
}

tls_test_close :: proc(client: ^Tls_Test_Client) {
	if client.ssl != nil {
		TLS.ssl_free(client.ssl)
		client.ssl = nil
	}
	if client.sock != 0 {
		net.close(client.sock)
		client.sock = 0
	}
}

@(test)
test_tls_config :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	testing.expect(t, cfg.ctx != nil)
	tls_config_destroy(&cfg)
	testing.expect(t, cfg.ctx == nil)

	// a missing file is reported, not silently ignored
	bad: Tls_Config
	testing.expect(t, !tls_config_init(&bad, "web/testdata/nope.pem", TLS_KEY))
}

tls_test_handler :: proc(req: ^Request, res: ^Response) {
	response_set_header(res, "Content-Type", "text/plain")
	response_write_string(res, "secure ")
	response_write_string(res, req.target)
}

@(test)
test_integration_tls_get :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = tls_test_handler
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	request := "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, request))
	resp := tls_test_read_all(&client)
	defer delete(resp)

	body := string(resp)
	testing.expectf(t, strings.has_prefix(body, "HTTP/1.1 200 OK\r\n"), "unexpected response: %q", body)
	testing.expect(t, strings.has_suffix(body, "secure /hello"))
	testing.expect(t, server_has_requests(srv, 1))
}

server_has_requests :: proc(s: ^Server, n: u64) -> bool {
	return s.stats.requests == n
}

@(test)
test_integration_tls_keep_alive :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = tls_test_handler
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	// two requests on one TLS connection: the plaintext state machine has
	// to keep working behind the encryption layer
	r1 := "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n"
	testing.expect(t, tls_test_write(&client, r1))
	buf: [4096]byte
	total := 0
	for total < len(buf) {
		n := TLS.read(client.ssl, raw_data(buf[total:]), i32(len(buf) - total))
		if n <= 0 {
			break
		}
		total += int(n)
		if bytes_contains(buf[:total], "secure /one") {
			break
		}
	}
	first := string(buf[:total])
	testing.expectf(t, strings.contains(first, "secure /one"), "first response: %q", first)

	r2 := "GET /two HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, r2))
	tail := tls_test_read_all(&client)
	defer delete(tail)
	testing.expect(t, strings.contains(string(tail), "secure /two"))
	testing.expect(t, srv.stats.requests == 2)
}

@(test)
test_integration_tls_static_file :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	// a file body goes through the read/encrypt/send loop, not sendfile
	path := "/tmp/web_test_tls_file.bin"
	content := make([]byte, 200 << 10, context.allocator)
	defer delete(content)
	for i in 0..<len(content) {
		content[i] = byte('a' + (i % 26))
	}
	{
		f, ferr := os.open(path, {.Write, .Create, .Trunc})
		testing.expect(t, ferr == nil)
		wn, werr := os.write(f, content)
		testing.expect(t, werr == nil)
		testing.expect(t, wn == len(content))
		os.close(f)
	}
	defer os.remove(path)

	st: Static
	static_init(&st, "/tmp")
	defer static_destroy(&st)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = static_serve
	srv.user_ptr = &st
	srv.tls = &cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, ok := tls_test_connect(ep)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer tls_test_close(&client)

	request := "GET /web_test_tls_file.bin HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	testing.expect(t, tls_test_write(&client, request))
	resp := tls_test_read_all(&client)
	defer delete(resp)

	head_end := bytes_index(resp, "\r\n\r\n")
	testing.expect(t, head_end > 0)
	body := resp[head_end + 4:]
	testing.expectf(t, len(body) == len(content), "body is %d bytes, expected %d", len(body), len(content))
	if len(body) == len(content) {
		testing.expect(t, mem.compare(body, content) == 0)
	}
}

@(test)
test_tls_resumption_config :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	// the three-argument form gets resumption for free
	on: Tls_Config
	testing.expect(t, tls_config_init(&on, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&on)
	testing.expect(t, on.resumption.cache)
	testing.expect(t, on.resumption.tickets)

	// ... and it can be turned off wholesale
	off: Tls_Config
	testing.expect(t, tls_config_init(&off, TLS_CERT, TLS_KEY, TLS_RESUMPTION_OFF))
	defer tls_config_destroy(&off)
	testing.expect(t, off.ctx != nil)
	testing.expect(t, !off.resumption.cache)
	testing.expect(t, !off.resumption.tickets)

	// a live context can be switched either way
	testing.expect(t, tls_config_set_resumption(&off, TLS_RESUMPTION_DEFAULT))
	testing.expect(t, off.resumption.cache)
	testing.expect(t, !tls_config_set_resumption(&Tls_Config{}, TLS_RESUMPTION_DEFAULT))
}

/*
tls_test_tickets counts the sessions the server hands the client. It lives at
file scope because OpenSSL calls the new-session callback as a plain C
function, and the resumption tests run one at a time.

The callback is also the reason this probe exists instead of a plain
SSL_get1_session: under TLS 1.3 the reusable session is the one that arrives
in a NewSessionTicket *after* the handshake, and OpenSSL reports it here. A
client that only looks at the SSL object sees the pre-ticket session.
*/
@(private = "file")
tls_test_tickets: int

@(private = "file")
tls_test_sessions: [8]rawptr

tls_test_new_session :: proc(ssl: rawptr, session: rawptr) -> c.int {
	if session == nil {
		return 0
	}
	if tls_test_tickets < len(tls_test_sessions) {
		tls_test_sessions[tls_test_tickets] = session
		if TLS.session_up_ref(session) != 1 {
			return 0
		}
		tls_test_tickets += 1
		// Returning 1 keeps the reference we just took; the test frees it.
		return 1
	}
	return 0
}

@(private = "file")
tls_test_free_sessions :: proc() {
	for i in 0 ..< tls_test_tickets {
		if tls_test_sessions[i] != nil {
			TLS.session_free(tls_test_sessions[i])
			tls_test_sessions[i] = nil
		}
	}
	tls_test_tickets = 0
}

/*
tls_ticket_probe starts a server with `cfg`, connects once and reports how
many sessions the server offered the client during that connection.

TLS 1.3 delivers one NewSessionTicket per configured ticket (2 by default),
TLS 1.2 sends its ticket inside the handshake; a server with resumption
turned off delivers none. That count is the server's half of the resumption
contract, and unlike "did the second handshake resume" it can be observed
without a second connection - the replay itself depends on the client
library keeping and re-offering the session, which is the client's job and
not something this server can be tested for from the inside.
*/
tls_ticket_probe :: proc(t: ^testing.T, cfg: ^Tls_Config) -> (issued: int, ok: bool) {
	srv := new(Server, context.allocator)
	if !server_init(srv, "127.0.0.1:0") {
		return 0, false
	}
	srv.handler = tls_test_handler
	srv.tls = cfg
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	tls_test_free_sessions()
	ctx := TLS.ctx_new(TLS.client_method())
	if ctx == nil {
		return 0, false
	}
	defer TLS.ctx_free(ctx)
	// A client context defaults to SSL_SESS_CACHE_SERVER, and the
	// new-session callback only runs when the context's cache mode includes
	// SSL_SESS_CACHE_CLIENT.
	_ = TLS.ctx_ctrl(ctx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_CLIENT, nil)
	TLS.ctx_sess_set_new_cb(ctx, rawptr(tls_test_new_session))

	client, connected := tls_test_connect_ctx(ep, ctx)
	if !connected {
		return 0, false
	}
	// keep-alive: under TLS 1.3 the tickets are post-handshake records, so a
	// Connection: close request would end the connection before they arrive
	_ = tls_test_write(&client, "GET /one HTTP/1.1\r\nHost: localhost\r\n\r\n")
	buf: [4096]byte
	total := 0
	for total < len(buf) {
		n := TLS.read(client.ssl, raw_data(buf[total:]), i32(len(buf) - total))
		if n <= 0 {
			break
		}
		total += int(n)
		if bytes_contains(buf[:total], "secure /one") {
			break
		}
	}
	if !bytes_contains(buf[:total], "secure /one") {
		return 0, false
	}
	// bounded wait for the post-handshake ticket when there is one
	_ = net.set_option(client.sock, .Receive_Timeout, 500 * time.Millisecond)
	_ = TLS.read(client.ssl, raw_data(buf[:]), 1)

	issued = tls_test_tickets
	tls_test_close(&client)
	return issued, srv.stats.tls_handshakes == 1
}

@(test)
test_integration_tls_tickets_issued :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	defer tls_test_free_sessions()

	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY))
	defer tls_config_destroy(&cfg)

	issued, ok := tls_ticket_probe(t, &cfg)
	testing.expect(t, ok)
	// two NewSessionTickets by default: one is enough to resume, the second
	// keeps a client that reconnects twice in quick succession on the fast path
	testing.expectf(t, issued >= 1, "server issued %v resumable session(s); resumption is not working", issued)
}

@(test)
test_integration_tls_resumption_off :: proc(t: ^testing.T) {
	if !test_tls_available() {
		fmt.println("skipping TLS test: libssl not available")
		return
	}
	defer tls_test_free_sessions()

	cfg: Tls_Config
	testing.expect(t, tls_config_init(&cfg, TLS_CERT, TLS_KEY, TLS_RESUMPTION_OFF))
	defer tls_config_destroy(&cfg)

	issued, ok := tls_ticket_probe(t, &cfg)
	testing.expect(t, ok)
	testing.expectf(t, issued == 0, "resumption was configured off but %v session(s) were issued", issued)
}

@(test)
test_mime_type_for :: proc(t: ^testing.T) {
	Case :: struct {
		path, want: string,
	}
	cases := []Case{
		{"/a/index.html", "text/html; charset=utf-8"},
		{"/a/index.HTML", "text/html; charset=utf-8"}, // extension case-insensitive
		{"/a/x.js", "text/javascript; charset=utf-8"},
		{"/a/x.json", "application/json"},
		{"/a/x.svg", "image/svg+xml"},
		{"/a/x.woff2", "font/woff2"},
		{"/a/x.conf", "text/plain; charset=utf-8"},
		{"/a.b/c", "application/octet-stream"}, // no extension across '/'
		{"/a/x.", "application/octet-stream"},
		{"/a/x.unknown", "application/octet-stream"},
	}
	for c in cases {
		testing.expectf(t, mime_type_for(c.path) == c.want, "%s → %s, want %s", c.path, mime_type_for(c.path), c.want)
	}

	// charset=false is the byte-exact form (uhttpd-style headers)
	testing.expect_value(t, mime_type_for("/a/x.html", false), "text/html")
	testing.expect_value(t, mime_type_for("/a/x.js", false), "text/javascript")
	testing.expect_value(t, mime_type_for("/a/x.png", false), "image/png")
}

@(test)
test_status_text :: proc(t: ^testing.T) {
	testing.expect_value(t, status_text(.OK), "OK")
	testing.expect_value(t, status_text(.See_Other), "See Other")
	testing.expect_value(t, status_text(.Temporary_Redirect), "Temporary Redirect")
	testing.expect_value(t, status_text(.Length_Required), "Length Required")
	testing.expect_value(t, status_text(.Header_Too_Large), "Request Header Fields Too Large")
	testing.expect_value(t, status_text(Status(599)), "Unknown")
}

/*
test_tls_session_id_context: the context that namespaces a session cache has to
be stable across restarts (same certificate, same context) and distinct between
services that share a load balancer. OpenSSL silently disables TLS 1.2 caching
when the context is unset, so the derivation is worth pinning even though it is
only a hash.
*/
@(test)
test_tls_session_id_context :: proc(t: ^testing.T) {
	a := tls_session_id_context("svc-a", "/etc/ssl/cert.pem")
	b := tls_session_id_context("svc-a", "/etc/ssl/cert.pem")
	testing.expectf(t, a == b, "the context is not stable across calls")

	// a different service must not share a cache
	c := tls_session_id_context("svc-b", "/etc/ssl/cert.pem")
	testing.expectf(t, a != c, "two services share a session context")

	// an explicit id *is* the context: the certificate is only the fallback for
	// callers that do not name their service, so with an id the cert is ignored
	testing.expect(
		t,
		tls_session_id_context("svc-a", "/etc/ssl/cert.pem") ==
		tls_session_id_context("svc-a", "/etc/ssl/other.pem"),
	)
	// ... and with no id the certificate is what keeps two services apart
	testing.expect(
		t,
		tls_session_id_context("", "/etc/ssl/cert.pem") != tls_session_id_context("", "/etc/ssl/other.pem"),
	)

	// an empty id falls back to the certificate, and both empty to a constant
	testing.expect(t, tls_session_id_context("", "/x.pem") == tls_session_id_context("/x.pem", ""))
	testing.expect(t, tls_session_id_context("", "") == tls_session_id_context("web-odin", ""))

	// a context of all zeroes would be the "unset" OpenSSL treats as an error
	non_zero := false
	for v in a {
		if v != 0 {
			non_zero = true
		}
	}
	testing.expectf(t, non_zero, "the context is all zeroes")
	testing.expect(t, SSL_MAX_SID_CTX_LENGTH <= 32) // OpenSSL's SSL_MAX_SID_CTX_LENGTH
}
