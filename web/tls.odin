package web

import "core:c"
import "core:dynlib"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:time"

/*
TLS support, loaded at run time from the system's OpenSSL.

Odin has no TLS implementation usable by a server, and linking libssl into
the library would make a C dependency mandatory for every user, including
those serving plaintext. `core:dynlib` keeps the library pure Odin at build
time: if libssl is missing, `tls_config_init` logs one clear line and
everything else keeps working over HTTP.

Model: the socket carries ciphertext, and an SSL object sits on top of it,
fed through a pair of memory BIOs.

	read:   socket -> rbio -> SSL_read  -> plaintext -> c.inbuf
	write:  c.out  -> SSL_write -> wbio -> ciphertext -> socket

Conn stays the only state machine: it asks `conn_recv_arm` and
`conn_flush_out`, which know whether the connection is wrapped. The
handshake is just a phase of that machine - `Tls_Session.handshaking` stays
true until SSL_do_handshake reports success.

Usage:

	cfg: web.Tls_Config
	if !web.tls_config_init(&cfg, "cert.pem", "key.pem") { ... }
	srv.tls = &cfg
	defer web.tls_config_destroy(&cfg)
*/
Tls_Config :: struct {
	ctx:  rawptr, // SSL_CTX*
	cert: string,
	key:  string,
}

Tls_Session :: struct {
	ssl:         rawptr, // SSL*
	rbio:        rawptr, // BIO* (owned by ssl after SSL_set_bio)
	wbio:        rawptr,
	handshaking: bool,
	eof:         bool, // clean close_notify received
	failed:      bool, // fatal protocol error
}

// OpenSSL return codes we have to tell apart (ssl.h)
SSL_ERROR_NONE          :: 0
SSL_ERROR_SSL           :: 1
SSL_ERROR_WANT_READ     :: 2
SSL_ERROR_WANT_WRITE    :: 3
SSL_ERROR_SYSCALL       :: 5
SSL_ERROR_ZERO_RETURN   :: 6
SSL_FILETYPE_PEM        :: 1

// TLS_FILE_CHUNK is how much of a file body is read, encrypted and sent per
// round trip. There is no sendfile equivalent once TLS is in the way.
TLS_FILE_CHUNK :: 64 << 10

// ---------------------------------------------------------------------------
// dynamic bindings
// ---------------------------------------------------------------------------

@(private)
Tls_Api :: struct {
	ctx_new:                  proc(method: rawptr) -> rawptr,
	ctx_free:                 proc(ctx: rawptr),
	ctx_use_certificate_file: proc(ctx: rawptr, file: cstring, kind: c.int) -> c.int,
	ctx_use_private_key_file: proc(ctx: rawptr, file: cstring, kind: c.int) -> c.int,
	ctx_check_private_key:    proc(ctx: rawptr) -> c.int,
	server_method:            proc() -> rawptr,
	client_method:            proc() -> rawptr,
	ssl_new:                  proc(ctx: rawptr) -> rawptr,
	ssl_free:                 proc(ssl: rawptr),
	set_bio:                  proc(ssl: rawptr, rbio: rawptr, wbio: rawptr),
	set_fd:                   proc(ssl: rawptr, fd: c.int) -> c.int,
	set_accept_state:         proc(ssl: rawptr),
	set_connect_state:        proc(ssl: rawptr),
	do_handshake:             proc(ssl: rawptr) -> c.int,
	read:                     proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int,
	write:                    proc(ssl: rawptr, buf: rawptr, num: c.int) -> c.int,
	get_error:                proc(ssl: rawptr, ret: c.int) -> c.int,
	shutdown:                 proc(ssl: rawptr) -> c.int,
	bio_new:                  proc(method: rawptr) -> rawptr,
	bio_s_mem:                proc() -> rawptr,
	bio_read:                 proc(bio: rawptr, buf: rawptr, len: c.int) -> c.int,
	bio_write:                proc(bio: rawptr, buf: rawptr, len: c.int) -> c.int,
	bio_ctrl_pending:         proc(bio: rawptr) -> c.size_t,
	bio_free:                 proc(bio: rawptr) -> c.int,
	err_get_error:            proc() -> c.ulong,
	err_clear_error:          proc(),
	err_reason_string:        proc(code: c.ulong) -> cstring,
}

@(private)
TLS: Tls_Api

@(private)
TLS_LOADED: bool

@(private)
TLS_SSL_LIB: dynlib.Library

@(private)
TLS_CRYPTO_LIB: dynlib.Library

when ODIN_OS == .Darwin {
	// Absolute paths only, and never a bare leaf name: dyld aborts the
	// process ("loading libcrypto in an unsafe way") when it has to resolve
	// an OpenSSL dylib through the fallback search path of an unsigned
	// binary, which is not something the library can recover from.
	@(private)
	TLS_SSL_NAMES := [?]string {
		"/opt/homebrew/lib/libssl.dylib",
		"/opt/homebrew/opt/openssl/lib/libssl.dylib",
		"/usr/local/lib/libssl.dylib",
		"/opt/local/lib/libssl.dylib",
		"/usr/lib/libssl.dylib",
	}
	@(private)
	TLS_CRYPTO_NAMES := [?]string {
		"/opt/homebrew/lib/libcrypto.dylib",
		"/opt/homebrew/opt/openssl/lib/libcrypto.dylib",
		"/usr/local/lib/libcrypto.dylib",
		"/opt/local/lib/libcrypto.dylib",
		"/usr/lib/libcrypto.dylib",
	}
} else {
	@(private)
	TLS_SSL_NAMES := [?]string {
		"libssl.so.3",
		"libssl.so.1.1",
		"libssl.so",
	}
	@(private)
	TLS_CRYPTO_NAMES := [?]string {
		"libcrypto.so.3",
		"libcrypto.so.1.1",
		"libcrypto.so",
	}
}

@(private)
tls_open_library :: proc(names: []string) -> dynlib.Library {
	for name in names {
		if lib, ok := dynlib.load_library(name); ok {
			log_info("web: tls: loaded %v", name)
			return lib
		}
	}
	return nil
}

@(private)
tls_symbol :: proc(lib: dynlib.Library, name: string, target: ^$T) -> bool {
	ptr, found := dynlib.symbol_address(lib, name)
	if !found {
		log_error("web: tls: missing symbol %v", name)
		return false
	}
	target^ = cast(T) ptr
	return true
}

/*
tls_load resolves the OpenSSL entry points once per process. It returns
false when libssl cannot be found or a symbol is missing, in which case
`tls_config_init` reports the reason and TLS stays off.
*/
tls_load :: proc() -> bool {
	if TLS_LOADED {
		return true
	}
	ssl_lib := tls_open_library(TLS_SSL_NAMES[:])
	if ssl_lib == nil {
		log_error("web: tls: libssl not found; install OpenSSL to serve HTTPS")
		return false
	}
	crypto_lib := tls_open_library(TLS_CRYPTO_NAMES[:])
	if crypto_lib == nil {
		log_error("web: tls: libcrypto not found")
		return false
	}

	ok := true
	ok &= tls_symbol(ssl_lib, "SSL_CTX_new", &TLS.ctx_new)
	ok &= tls_symbol(ssl_lib, "SSL_CTX_free", &TLS.ctx_free)
	ok &= tls_symbol(ssl_lib, "SSL_CTX_use_certificate_file", &TLS.ctx_use_certificate_file)
	ok &= tls_symbol(ssl_lib, "SSL_CTX_use_PrivateKey_file", &TLS.ctx_use_private_key_file)
	ok &= tls_symbol(ssl_lib, "SSL_CTX_check_private_key", &TLS.ctx_check_private_key)
	ok &= tls_symbol(ssl_lib, "TLS_server_method", &TLS.server_method)
	ok &= tls_symbol(ssl_lib, "TLS_client_method", &TLS.client_method)
	ok &= tls_symbol(ssl_lib, "SSL_new", &TLS.ssl_new)
	ok &= tls_symbol(ssl_lib, "SSL_free", &TLS.ssl_free)
	ok &= tls_symbol(ssl_lib, "SSL_set_bio", &TLS.set_bio)
	ok &= tls_symbol(ssl_lib, "SSL_set_fd", &TLS.set_fd)
	ok &= tls_symbol(ssl_lib, "SSL_set_accept_state", &TLS.set_accept_state)
	ok &= tls_symbol(ssl_lib, "SSL_set_connect_state", &TLS.set_connect_state)
	ok &= tls_symbol(ssl_lib, "SSL_do_handshake", &TLS.do_handshake)
	ok &= tls_symbol(ssl_lib, "SSL_read", &TLS.read)
	ok &= tls_symbol(ssl_lib, "SSL_write", &TLS.write)
	ok &= tls_symbol(ssl_lib, "SSL_get_error", &TLS.get_error)
	ok &= tls_symbol(ssl_lib, "SSL_shutdown", &TLS.shutdown)
	ok &= tls_symbol(crypto_lib, "BIO_new", &TLS.bio_new)
	ok &= tls_symbol(crypto_lib, "BIO_s_mem", &TLS.bio_s_mem)
	ok &= tls_symbol(crypto_lib, "BIO_read", &TLS.bio_read)
	ok &= tls_symbol(crypto_lib, "BIO_write", &TLS.bio_write)
	ok &= tls_symbol(crypto_lib, "BIO_ctrl_pending", &TLS.bio_ctrl_pending)
	ok &= tls_symbol(crypto_lib, "BIO_free", &TLS.bio_free)
	ok &= tls_symbol(crypto_lib, "ERR_get_error", &TLS.err_get_error)
	ok &= tls_symbol(crypto_lib, "ERR_clear_error", &TLS.err_clear_error)
	ok &= tls_symbol(crypto_lib, "ERR_reason_error_string", &TLS.err_reason_string)
	if !ok {
		return false
	}
	TLS_SSL_LIB = ssl_lib
	TLS_CRYPTO_LIB = crypto_lib
	TLS_LOADED = true
	return true
}

// tls_last_error renders the oldest queued OpenSSL error, which is what
// makes a failed handshake diagnosable.
tls_last_error :: proc() -> string {
	code := TLS.err_get_error()
	if code == 0 {
		return "no queued OpenSSL error"
	}
	if text := TLS.err_reason_string(code); text != nil {
		return string(text)
	}
	return "unknown OpenSSL error"
}

// ---------------------------------------------------------------------------
// context
// ---------------------------------------------------------------------------

/*
tls_config_init loads the certificate chain and private key into an
SSL_CTX. Both files are PEM. Returns false (and logs) on any failure,
including libssl not being available at all.
*/
tls_config_init :: proc(cfg: ^Tls_Config, cert_file, key_file: string) -> bool {
	cfg^ = {}
	if !tls_load() {
		return false
	}
	ctx := TLS.ctx_new(TLS.server_method())
	if ctx == nil {
		log_error("web: tls: SSL_CTX_new failed: %v", tls_last_error())
		return false
	}
	cert := strings.clone_to_cstring(cert_file, context.temp_allocator)
	key := strings.clone_to_cstring(key_file, context.temp_allocator)
	if TLS.ctx_use_certificate_file(ctx, cert, SSL_FILETYPE_PEM) != 1 {
		log_error("web: tls: cannot read certificate %v: %v", cert_file, tls_last_error())
		TLS.ctx_free(ctx)
		return false
	}
	if TLS.ctx_use_private_key_file(ctx, key, SSL_FILETYPE_PEM) != 1 {
		log_error("web: tls: cannot read private key %v: %v", key_file, tls_last_error())
		TLS.ctx_free(ctx)
		return false
	}
	if TLS.ctx_check_private_key(ctx) != 1 {
		log_error("web: tls: private key does not match the certificate: %v", tls_last_error())
		TLS.ctx_free(ctx)
		return false
	}
	cfg.ctx = ctx
	cfg.cert = cert_file
	cfg.key = key_file
	log_info("web: tls: serving with %v", cert_file)
	return true
}

tls_config_destroy :: proc(cfg: ^Tls_Config) {
	if cfg.ctx != nil {
		TLS.ctx_free(cfg.ctx)
		cfg.ctx = nil
	}
}

// ---------------------------------------------------------------------------
// per-connection session
// ---------------------------------------------------------------------------

// tls_attach wraps the connection's socket in an SSL object and provisions
// the ciphertext staging buffers.
tls_attach :: proc(c: ^Conn, cfg: ^Tls_Config) -> bool {
	s := new(Tls_Session, c.server.allocator)
	s.ssl = TLS.ssl_new(cfg.ctx)
	if s.ssl == nil {
		log_error("web: tls: SSL_new failed: %v", tls_last_error())
		free(s, c.server.allocator)
		return false
	}
	s.rbio = TLS.bio_new(TLS.bio_s_mem())
	s.wbio = TLS.bio_new(TLS.bio_s_mem())
	if s.rbio == nil || s.wbio == nil {
		log_error("web: tls: cannot allocate memory BIOs")
		TLS.ssl_free(s.ssl)
		free(s, c.server.allocator)
		return false
	}
	// SSL_set_bio takes ownership of both BIOs: SSL_free releases them
	TLS.set_bio(s.ssl, s.rbio, s.wbio)
	TLS.set_accept_state(s.ssl)
	s.handshaking = true

	c.tls = s
	c.tls_net = make([]byte, RECV_BUF_SIZE, c.server.allocator)
	c.tls_file_buf = make([]byte, TLS_FILE_CHUNK, c.server.allocator)
	return true
}

tls_destroy :: proc(c: ^Conn) {
	if c.tls != nil {
		if c.tls.ssl != nil {
			TLS.ssl_free(c.tls.ssl)
		}
		free(c.tls, c.server.allocator)
		c.tls = nil
	}
	if c.tls_net != nil {
		delete(c.tls_net, c.server.allocator)
		c.tls_net = nil
	}
	if c.tls_file_buf != nil {
		delete(c.tls_file_buf, c.server.allocator)
		c.tls_file_buf = nil
	}
}

// tls_start kicks off the server handshake.
tls_start :: proc(c: ^Conn) {
	tls_handshake_step(c)
}

/*
tls_handshake_step advances the handshake as far as the buffered ciphertext
allows, then either sends what the handshake produced and waits for more
ciphertext, or moves the connection into normal reading.
*/
tls_handshake_step :: proc(c: ^Conn) {
	s := c.tls
	for {
		ret := TLS.do_handshake(s.ssl)
		if ret == 1 {
			s.handshaking = false
			break
		}
		err := TLS.get_error(s.ssl, ret)
		if err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE {
			break
		}
		log_debug("web: tls handshake failed: %v", tls_last_error())
		conn_close(c)
		return
	}
	if !tls_send_pending(c, on_tls_handshake_sent) {
		return // handshake bytes in flight; the callback resumes
	}
	tls_after_handshake(c)
}

on_tls_handshake_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: tls handshake send failed: %v", op.send.err)
		conn_close(c)
		return
	}
	c.server.stats.bytes_out += u64(op.send.sent)
	buf_reset(&c.tls_out)
	if c.tls.handshaking {
		conn_recv_arm(c, c.server.header_timeout)
		return
	}
	tls_after_handshake(c)
}

@(private)
tls_after_handshake :: proc(c: ^Conn) {
	if c.tls.handshaking {
		conn_recv_arm(c, c.server.header_timeout)
		return
	}
	if tls_read_plain(c) {
		conn_drive(c)
		return
	}
	if c.op == nil && !c.closed && (c.state == .Read_Head || c.state == .Read_Body) {
		conn_recv_arm(c, c.server.header_timeout)
	}
}

// ---------------------------------------------------------------------------
// ciphertext plumbing
// ---------------------------------------------------------------------------

// tls_feed pushes ciphertext from the socket into the read BIO.
tls_feed :: proc(c: ^Conn, data: []byte) -> bool {
	if len(data) == 0 {
		return true
	}
	n := TLS.bio_write(c.tls.rbio, raw_data(data), i32(len(data)))
	return n == i32(len(data))
}

// tls_drain_wbio moves whatever SSL produced into the outgoing buffer.
tls_drain_wbio :: proc(c: ^Conn) {
	for {
		pending := int(TLS.bio_ctrl_pending(c.tls.wbio))
		if pending <= 0 {
			return
		}
		start := buf_len(&c.tls_out)
		resize(&c.tls_out.data, start + pending)
		got := TLS.bio_read(c.tls.wbio, raw_data(c.tls_out.data[start:]), i32(pending))
		if got <= 0 {
			resize(&c.tls_out.data, start)
			return
		}
		resize(&c.tls_out.data, start + int(got))
		if int(got) < pending {
			return
		}
	}
}

/*
tls_send_pending flushes buffered ciphertext. It returns true when there is
nothing left to send (the caller may continue synchronously), false when a
send operation is now in flight and the callback owns the flow.
*/
tls_send_pending :: proc(c: ^Conn, cb: proc(op: ^nbio.Operation, c: ^Conn)) -> bool {
	tls_drain_wbio(c)
	if buf_len(&c.tls_out) == 0 {
		return true
	}
	c.op = nbio.send_poly(
		c.socket,
		[][]byte{buf_slice(&c.tls_out)},
		c,
		cb,
		all = true,
		timeout = c.server.write_timeout,
	)
	return false
}

// tls_encrypt runs plaintext through SSL_write and buffers the ciphertext.
tls_encrypt :: proc(c: ^Conn, data: []byte) -> bool {
	off := 0
	for off < len(data) {
		n := TLS.write(c.tls.ssl, raw_data(data[off:]), i32(len(data) - off))
		if n <= 0 {
			err := TLS.get_error(c.tls.ssl, n)
			if err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE {
				// memory BIOs never fill, so this would mean a renegotiation
				// request; not supported here
				log_debug("web: tls write wants more I/O")
				return false
			}
			log_debug("web: tls write failed: %v", tls_last_error())
			return false
		}
		off += int(n)
	}
	tls_drain_wbio(c)
	return true
}

// tls_read_plain decrypts everything currently buffered into c.inbuf.
// Returns whether any plaintext arrived.
tls_read_plain :: proc(c: ^Conn) -> bool {
	got := false
	for {
		n := TLS.read(c.tls.ssl, raw_data(c.rbuf[:]), i32(len(c.rbuf)))
		if n > 0 {
			buf_append(&c.inbuf, c.rbuf[:int(n)])
			c.server.stats.bytes_in += u64(n)
			got = true
			continue
		}
		err := TLS.get_error(c.tls.ssl, n)
		if err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE {
			break
		}
		if err == SSL_ERROR_ZERO_RETURN {
			c.tls.eof = true // close_notify: a clean end of stream
			break
		}
		c.tls.failed = true
		log_debug("web: tls read failed: %v", tls_last_error())
		break
	}
	return got
}

// tls_recv_arm arms a ciphertext read on the socket.
tls_recv_arm :: proc(c: ^Conn, timeout: time.Duration) {
	c.op = nbio.recv_poly(
		c.socket,
		[][]byte{c.tls_net},
		c,
		on_tls_recv,
		all = false,
		timeout = timeout,
	)
}

on_tls_recv :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.recv.err != nil {
		log_debug("web: tls socket recv error: %v", op.recv.err)
		conn_close(c)
		return
	}
	n := op.recv.received
	if n == 0 {
		conn_close(c)
		return
	}
	if !tls_feed(c, c.tls_net[:n]) {
		conn_close(c)
		return
	}

	if c.tls.handshaking {
		tls_handshake_step(c)
		return
	}

	if tls_read_plain(c) {
		conn_drive(c)
	}
	if c.tls != nil && (c.tls.eof || c.tls.failed) {
		conn_close(c)
		return
	}
	// the drive above may have armed its own read
	if !c.closed && c.op == nil && (c.state == .Read_Head || c.state == .Read_Body) {
		conn_recv_arm(c, c.server.header_timeout)
	}
}

// ---------------------------------------------------------------------------
// write path
// ---------------------------------------------------------------------------

/*
tls_write_loop is conn_begin_write's TLS counterpart: it encrypts the
pending response head/body, then streams any file body in TLS_FILE_CHUNK
pieces (there is no sendfile once the bytes have to be encrypted).
*/
tls_write_loop :: proc(c: ^Conn) {
	w := &c.res

	if buf_len(&c.out) > 0 {
		if !tls_encrypt(c, buf_slice(&c.out)) {
			conn_close(c)
			return
		}
		buf_reset(&c.out)
	}

	if file_pending(w) && c.tls_file_offset < w.file_size {
		if !tls_send_pending(c, on_tls_write_sent) {
			return
		}
		chunk := TLS_FILE_CHUNK
		remaining := w.file_size - c.tls_file_offset
		if remaining < i64(chunk) {
			chunk = int(remaining)
		}
		c.op = nbio.read_poly(
			w.file_handle,
			w.file_offset + int(c.tls_file_offset),
			c.tls_file_buf[:chunk],
			c,
			on_tls_file_read,
			all = true,
			timeout = c.server.write_timeout,
		)
		return
	}

	if !tls_send_pending(c, on_tls_write_sent) {
		return
	}
	if file_pending(w) {
		nbio.close(w.file_handle)
		w.file_open = false
	}
	conn_after_write(c)
}

on_tls_file_read :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.read.err != nil {
		log_debug("web: tls file read failed: %v", op.read.err)
		conn_close(c)
		return
	}
	n := op.read.read
	if n <= 0 {
		conn_close(c)
		return
	}
	if !tls_encrypt(c, c.tls_file_buf[:n]) {
		conn_close(c)
		return
	}
	c.tls_file_offset += i64(n)
	tls_write_loop(c)
}

on_tls_write_sent :: proc(op: ^nbio.Operation, c: ^Conn) {
	c.op = nil
	if c.closed {
		return
	}
	if op.send.err != nil {
		log_debug("web: tls send failed: %v", op.send.err)
		conn_close(c)
		return
	}
	c.server.stats.bytes_out += u64(op.send.sent)
	buf_reset(&c.tls_out)
	tls_write_loop(c)
}
