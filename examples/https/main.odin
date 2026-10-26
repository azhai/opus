package main

import "core:fmt"
import "core:os"
import "../../web"

/*
HTTPS demo: the same handler surface as the plain hello example, wrapped in
TLS by attaching a `Tls_Config` to the server. Nothing in the handler
changes - TLS lives at the socket layer, below the HTTP state machine.

OpenSSL is loaded at runtime through core:dynlib, so this example needs no
build-time C dependency. It does need libssl/libcrypto installed:

	brew install openssl          # macOS
	apt install libssl3           # Debian/Ubuntu

Run it with the bundled self-signed certificate (CN=localhost):

	odin run examples/https
	curl -k --noproxy '*' https://127.0.0.1:8443/
	curl -k --noproxy '*' -I https://127.0.0.1:8443/         # HEAD
	curl -k --noproxy '*' https://127.0.0.1:8443/ https://127.0.0.1:8443/   # keep-alive

Generate a real certificate with:

	openssl req -x509 -newkey rsa:2048 -days 365 -nodes \
	    -subj "/CN=example.com" -keyout key.pem -out cert.pem
*/

hello :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_text(res, .OK, "hello over TLS\n")
}

main :: proc() {
	cert_file := "web/testdata/cert.pem"
	key_file := "web/testdata/key.pem"
	address := "0.0.0.0:8443"
	if len(os.args) > 1 {
		cert_file = os.args[1]
	}
	if len(os.args) > 2 {
		key_file = os.args[2]
	}
	if len(os.args) > 3 {
		address = os.args[3]
	}

	cfg: web.Tls_Config
	if !web.tls_config_init(&cfg, cert_file, key_file) {
		fmt.eprintfln("cannot load certificate %v / key %v", cert_file, key_file)
		os.exit(1)
	}
	defer web.tls_config_destroy(&cfg)

	srv: web.Server
	if !web.server_init(&srv, address) {
		return
	}
	srv.handler = hello
	srv.tls = &cfg
	fmt.printf("serving https on %v with %v\n", address, cert_file)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
