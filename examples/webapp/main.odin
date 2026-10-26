package main

/*
One small application assembled out of the purpose middleware: a browser
login (signed session cookie), an API token (JWT), a file tree (static),
two URL rules (an internal rewrite and a real redirect), multipart uploads
spooled to disk, and gzip on the responses that are worth it.

	odin run examples/webapp                    # :8080
	odin run examples/webapp -- 127.0.0.1:9000

	curl -c /tmp/c -d user=ada   localhost:8080/login     # session starts
	curl -b /tmp/c               localhost:8080/me        # "ada, visit 2"
	curl -b /tmp/c -X POST       localhost:8080/logout    # cookie cleared

	TOK=$(curl -s localhost:8080/token)                   # mint a JWT
	curl -H "Authorization: Bearer $TOK" localhost:8080/api/profile
	curl -i localhost:8080/api/profile                    # 401 + challenge

	curl -i localhost:8080/old                            # 308 -> /
	curl    localhost:8080/intro                          # rewritten to /
	curl    localhost:8080/assets/app.css                # static, sendfile
	curl -F doc=@README.md localhost:8080/upload          # spooled to ./uploads
	curl --compressed localhost:8080/big                  # gzip on one route

Everything below the router-wide chain is attached to the single route that
needs it, which is the point of the middleware package: nothing here is
paid for by the routes that do not use it.
*/

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../web"
import "../../web/middlewares"

// Configs must outlive the server, so they live at file scope.
session_cfg := middlewares.Session_Config {
	name         = "sid",
	secret       = "demo-session-secret-change-me",
	max_age_secs = 3600,
}

jwt_cfg := middlewares.Jwt_Config {
	secret   = "demo-jwt-secret-change-me",
	issuer   = "webapp-demo",
	audience = "webapp-clients",
	realm    = "api",
}

static_cfg := middlewares.Static_Mount_Config {
	prefix = "/assets",
}

upload_cfg := middlewares.Upload_Config {
	dir            = "./uploads",
	max_file_bytes = 4 << 20,
	max_files      = 4,
}

gzip_cfg := middlewares.Gzip_Config {
	min_size = 256,
}

// Legacy URLs. Registered router-wide because they are a property of the
// site, not of one route; the same middleware works route-locally, which is
// what you want when only one path moved.
redirect_cfg := middlewares.Redirect_Config {
	rules = []middlewares.Redirect_Rule{
		{from = "/old", to = "/", exact = true},
		{from = "/docs", to = "/assets/"},
	},
}

files: web.Static

index :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_html(res, .OK, `<!doctype html>
<title>webapp</title>
<h1>webapp</h1>
<pre>
  POST /login          start a session              (middleware_session)
  GET  /me             read it, and count visits    (middleware_session)
  POST /logout         clear it                     (middleware_session)
  GET  /token          issue an HS256 JWT           (jwt_sign)
  GET  /api/profile    require that JWT             (middleware_jwt)
  GET  /old            308 to /                     (middleware_redirect)
  GET  /intro          rewritten to / internally    (router_rewrite)
  GET  /assets/app.css served from a directory tree (middleware_static)
  POST /upload         multipart spooled to disk    (middleware_upload)
  GET  /big            gzipped above 256 bytes      (middleware_gzip)
</pre>
`)
}

// ---------------------------------------------------------------------------
// session
// ---------------------------------------------------------------------------

login :: proc(req: ^web.Request, res: ^web.Response) {
	user, _ := web.request_form_value(req, "user")
	if len(user) == 0 {
		user = "anonymous"
	}
	middlewares.session_set(req, "user", user)
	middlewares.session_set(req, "visits", "0")
	buf: [128]byte
	web.response_text(res, .OK, fmt.bprintf(buf[:], "welcome %v (session %v)\n", user, middlewares.session_id(req)))
}

me :: proc(req: ^web.Request, res: ^web.Response) {
	user, _ := middlewares.session_get(req, "user")
	if len(user) == 0 {
		web.response_error(res, .Unauthorized, "no session - POST /login first")
		return
	}
	visits, _ := middlewares.session_get(req, "visits")
	n := 1
	if v, ok := strconv.parse_int(visits); ok {
		n = int(v) + 1
	}
	buf: [128]byte
	middlewares.session_set(req, "visits", fmt.bprintf(buf[:], "%d", n))
	msg: [128]byte
	web.response_text(res, .OK, fmt.bprintf(msg[:], "%v, visit %d\n", user, n))
}

logout :: proc(req: ^web.Request, res: ^web.Response) {
	middlewares.session_destroy(req, res, &session_cfg)
	web.response_text(res, .OK, "bye\n")
}

// ---------------------------------------------------------------------------
// JWT
// ---------------------------------------------------------------------------

// token is the login endpoint of a token-based API: it issues a short-lived
// credential. In a real app this is where you check a password.
token :: proc(req: ^web.Request, res: ^web.Response) {
	sub, _ := web.request_query(req, "sub")
	if len(sub) == 0 {
		sub = "service-a"
	}
	claims := middlewares.Jwt_Claims {
		sub = sub,
		iss = jwt_cfg.issuer,
		aud = jwt_cfg.audience,
		iat = time.time_to_unix(time.now()),
		exp = time.time_to_unix(time.now()) + 3600,
	}
	tok, ok := middlewares.jwt_sign(claims, jwt_cfg.secret, web.request_allocator(req))
	if !ok {
		web.response_error(res, .Internal_Error, "")
		return
	}
	web.response_text(res, .OK, tok)
}

profile :: proc(req: ^web.Request, res: ^web.Response) {
	// middleware_jwt already verified the token before we got here; the
	// subject it puts on the request is the only thing we have to trust.
	web.response_json(res, Profile{subject = req.principal, plan = "free"})
}

Profile :: struct {
	subject: string `json:"sub"`,
	plan:    string `json:"plan"`,
}

// ---------------------------------------------------------------------------
// uploads
// ---------------------------------------------------------------------------

upload :: proc(req: ^web.Request, res: ^web.Response) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	stored := middlewares.request_uploads(req)
	if len(stored) == 0 {
		web.response_text(res, .OK, "no file parts\n")
		return
	}
	for u in stored {
		fmt.sbprintf(&sb, "%v: %v bytes at %v (as %v)\n", u.field, u.size, u.path, u.original)
	}
	web.response_text(res, .Created, strings.to_string(sb))
}

// ---------------------------------------------------------------------------
// gzip
// ---------------------------------------------------------------------------

big :: proc(req: ^web.Request, res: ^web.Response) {
	sb: strings.Builder
	strings.builder_init(&sb, context.temp_allocator)
	for _ in 0..<40 {
		strings.write_string(&sb, "the quick brown fox jumps over the lazy dog\n")
	}
	// say what it is: the compress filter only codes bodies whose
	// Content-Type is worth coding, and an untyped body has none
	web.response_set_content_type(res, "text/plain; charset=utf-8")
	web.response_write_string(res, strings.to_string(sb))
}

main :: proc() {
	address := "0.0.0.0:8080"
	if len(os.args) > 1 {
		address = os.args[1]
	}
	root := "examples/webapp/www"
	if len(os.args) > 2 {
		root = os.args[2]
	}

	web.static_init(&files, root)
	static_cfg.st = &files

	router: web.Router
	web.router_init(&router)

	// router-wide: identity, logging, security headers and the legacy URL
	// table. These are properties of the site, not of a route.
	web.router_use(&router, middlewares.middleware_request_id)
	web.router_use(&router, middlewares.middleware_logger)
	web.router_use(&router, middlewares.middleware_secure_headers)
	web.router_use(&router, middlewares.middleware_redirect, &redirect_cfg)

	// An internal rewrite: the URL the client asked for is replaced before
	// routing, so /intro is served by the / route and no redirect is sent.
	web.router_rewrite(&router, "/intro", "/", true)

	// routes are heap-allocated, so the pointers stay valid while the rest of
	// the table is registered; attaching in a second pass keeps the two
	// concerns separate
	web.router_get(&router, "/", index)

	login_route := web.router_post(&router, "/login", login)
	me_route := web.router_get(&router, "/me", me)
	logout_route := web.router_post(&router, "/logout", logout)

	web.router_get(&router, "/token", token)
	profile_route := web.router_get(&router, "/api/profile", profile)

	assets_route := web.router_all(&router, "/assets/*", web.router_fallthrough_not_found)
	upload_route := web.router_post(&router, "/upload", upload)
	big_route := web.router_get(&router, "/big", big)

	// route-local middleware: one purpose per route
	web.router_use_route(login_route, middlewares.middleware_session, &session_cfg)
	web.router_use_route(me_route, middlewares.middleware_session, &session_cfg)
	web.router_use_route(logout_route, middlewares.middleware_session, &session_cfg)

	web.router_use_route(profile_route, middlewares.middleware_jwt, &jwt_cfg)
	web.router_use_route(assets_route, middlewares.middleware_static, &static_cfg)
	web.router_use_route(upload_route, middlewares.middleware_upload, &upload_cfg)
	web.router_use_route(big_route, middlewares.middleware_gzip, &gzip_cfg)

	srv: web.Server
	if !web.server_init(&srv, address) {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.printf("webapp on http://%v (static root %v)\n", address, root)
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
