package main

/*
Two-stage login: a password, then a code from an authenticator app.

The demo is the honest version of the flow `totp_auth.odin` supports:

	POST /login          password stage; a session with 2FA on stops here
	GET  /totp           the challenge page (a code or a backup code)
	POST /totp           second stage; only then is the session complete
	GET  /admin          protected by middleware_totp
	GET  /setup          enrollment (secret, otpauth URI, backup codes)
	POST /setup/start    generate the secret and show it once
	POST /setup/confirm  prove the secret reached the app
	POST /setup/disable  switch the second factor off

Run it (the state file keeps enrollments across restarts):

	TOTP_SECRET=$(openssl rand -hex 32) odin run examples/totp -- 127.0.0.1:8093

	# the digits an authenticator app would show, so the demo is scriptable
	code() { python3 - "$1" <<'PY'
	import base64, hmac, hashlib, struct, sys, time
	key = base64.b32decode(sys.argv[1])
	digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
	off = digest[-1] & 0xf
	print("%06d" % ((struct.unpack(">I", digest[off:off+4])[0] & 0x7fffffff) % 1000000))
	PY
	}

	curl -s -c /tmp/t -d 'user=admin&password=secret' localhost:8093/login    # no 2FA yet
	curl -s -b /tmp/t -X POST localhost:8093/setup/start                     # secret + codes
	curl -s -b /tmp/t -d "code=$(code SECRET)" localhost:8093/setup/confirm
	curl -s -b /tmp/t -c /tmp/t -d 'user=admin&password=secret' localhost:8093/login   # now /totp
	curl -s -b /tmp/t -d "code=$(code SECRET)" localhost:8093/totp
	curl -s -b /tmp/t localhost:8093/admin
*/

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "../../web"
import "../../web/middlewares"

// DEMO_MASTER_KEY is used when TOTP_SECRET is unset: a real deployment
// generates one with `openssl rand -hex 32` and keeps it out of the state
// file's backups.
DEMO_MASTER_KEY :: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

DEMO_STATE_PATH :: "./totp_state.json"

session_cfg := middlewares.Session_Config {
	name         = "sid",
	secret       = "demo-session-secret-change-me",
	max_age_secs = 8 * 3600,
}

// The gate config must outlive the server; `totp` is filled in by main.
gate_cfg := middlewares.Totp_Gate_Config {
	login_path     = "/login",
	challenge_path = "/totp",
}

totp_state: middlewares.Totp

// One account, because the point of the demo is the second factor, not a
// user database.
Demo_User :: struct {
	name:     string,
	password: string,
}

users := [1]Demo_User{{name = "admin", password = "secret"}}

// ---------------------------------------------------------------------------
// pages
// ---------------------------------------------------------------------------

WRAP_HEAD :: `<!doctype html><meta charset="utf-8"><title>TOTP demo</title>
<style>
	body { font: 15px/1.6 system-ui, sans-serif; margin: 2rem auto; max-width: 46rem; color: #222 }
	h1 { font-size: 1.4rem } code { background: #f3f3f3; padding: .1rem .35rem; border-radius: 3px }
	.err { color: #b00 } .ok { color: #070 }
	table { border-collapse: collapse } td, th { border: 1px solid #ddd; padding: .2rem .6rem; text-align: left }
	input { padding: .3rem .4rem; font: inherit } button { padding: .3rem .8rem; font: inherit }
</style>
`

WRAP_TAIL :: `
<hr><nav><a href="/">首页</a> · <a href="/admin">后台</a> · <a href="/setup">TOTP 设置</a></nav>
`

page :: proc(res: ^web.Response, status: web.Status, inner: string) {
	alloc := web.response_allocator(res)
	web.response_html(res, status, fmt.aprintf("%s%s%s", WRAP_HEAD, inner, WRAP_TAIL, allocator = alloc))
}

// ---------------------------------------------------------------------------
// index
// ---------------------------------------------------------------------------

index :: proc(req: ^web.Request, res: ^web.Response) {
	user := middlewares.totp_session_user(req, &gate_cfg)
	state := "未登录"
	if len(user) > 0 {
		if middlewares.totp_authenticated(req, &gate_cfg) {
			state = fmt.aprintf("已登录：%s（双因素已通过）", user, allocator = web.response_allocator(res))
		} else {
			state = fmt.aprintf("已登录：%s（等待验证码）", user, allocator = web.response_allocator(res))
		}
	}
	page(res, .OK, fmt.aprintf(`<h1>TOTP 两步验证示例</h1>
<p>当前状态：%s</p>
<pre>
  POST /login          第一阶段：用户名 + 密码
  GET  /totp           第二阶段：验证器 App 的 6 位数字，或恢复码
  GET  /admin          需要两阶段都通过（middleware_totp）
  GET  /setup          开启 / 关闭 TOTP，查看恢复码余额
</pre>
<p>演示账号：<code>admin</code> / <code>secret</code>。master key 来自环境变量
<code>TOTP_SECRET</code>，状态写在 <code>%s</code>。</p>`, state, DEMO_STATE_PATH,
		allocator = web.response_allocator(res)))
}

// ---------------------------------------------------------------------------
// stage 1: password
// ---------------------------------------------------------------------------

login_page :: proc(res: ^web.Response, status: web.Status, message: string) {
	note := ""
	if len(message) > 0 {
		note = fmt.aprintf(`<p class="err">%s</p>`, message, allocator = web.response_allocator(res))
	}
	page(res, status, fmt.aprintf(`<h1>登录</h1>%s
<form method="post" action="/login">
	<p><label>用户名 <input name="user" value="admin"></label></p>
	<p><label>密码 <input name="password" type="password"></label></p>
	<p><button type="submit">下一步</button></p>
</form>`, note, allocator = web.response_allocator(res)))
}

login_form :: proc(req: ^web.Request, res: ^web.Response) {
	login_page(res, .OK, "")
}

password_ok :: proc(user, password: string) -> bool {
	found := false
	for candidate in users {
		// compare both halves for every account so the timing does not say
		// which user exists
		user_ok := candidate.name == user
		pass_ok := candidate.password == password
		if user_ok && pass_ok {
			found = true
		}
	}
	return found
}

login_submit :: proc(req: ^web.Request, res: ^web.Response) {
	user, _ := web.request_form_value(req, "user")
	password, _ := web.request_form_value(req, "password")
	if !password_ok(user, password) {
		login_page(res, .Unauthorized, "用户名或密码不对")
		return
	}

	// The one call that decides whether the login is over. `true` means the
	// account has 2FA on and the session is only half authenticated.
	if middlewares.totp_after_password(req, &totp_state, user, &gate_cfg) {
		web.response_redirect(res, "/totp", .Found)
		return
	}
	web.response_redirect(res, "/admin", .Found)
}

// ---------------------------------------------------------------------------
// stage 2: the code
// ---------------------------------------------------------------------------

challenge_page :: proc(res: ^web.Response, status: web.Status, user, message: string) {
	note := ""
	if len(message) > 0 {
		note = fmt.aprintf(`<p class="err">%s</p>`, message, allocator = web.response_allocator(res))
	}
	page(res, status, fmt.aprintf(`<h1>第二步：验证码</h1>
<p>账号 <code>%s</code> 已通过密码校验，请输入验证器 App 里的 6 位数字。</p>%s
<form method="post" action="/totp">
	<p><input name="code" inputmode="numeric" autocomplete="one-time-code" placeholder="123456" autofocus></p>
	<p><button type="submit">验证</button></p>
</form>
<p>设备丢了？把其中一个恢复码填在同一个框里也能登录。</p>`, user, note,
		allocator = web.response_allocator(res)))
}

challenge_form :: proc(req: ^web.Request, res: ^web.Response) {
	user, pending := middlewares.totp_challenge_pending(req, &gate_cfg)
	if !pending {
		web.response_redirect(res, "/login", .Found)
		return
	}
	challenge_page(res, .OK, user, "")
}

// normalize_code strips the spaces and dashes a user types: "a1b2-c3d4" and
// "a1b2 c3d4" are the same recovery code.
normalize_code :: proc(code: string, alloc: mem.Allocator) -> string {
	b := strings.Builder{}
	strings.builder_init(&b, alloc)
	for i in 0..<len(code) {
		c := code[i]
		if c == ' ' || c == '-' || c == '\t' {
			continue
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

challenge_submit :: proc(req: ^web.Request, res: ^web.Response) {
	user, pending := middlewares.totp_challenge_pending(req, &gate_cfg)
	if !pending {
		web.response_redirect(res, "/login", .Found)
		return
	}
	raw, _ := web.request_form_value(req, "code")
	code := normalize_code(raw, web.request_allocator(req))

	#partial switch middlewares.totp_complete_challenge(req, &totp_state, code, &gate_cfg) {
	case .None:
		web.response_redirect(res, "/admin", .Found)
	case .Account_Locked:
		challenge_page(res, .Forbidden, user, "失败次数太多，这个账号被临时锁定 15 分钟。")
	case .Invalid_Backup_Code:
		challenge_page(res, .Unauthorized, user, "恢复码无效或已经用过。")
	case:
		challenge_page(res, .Unauthorized, user, "验证码不对，请检查手机时间后重试。")
	}
}

// ---------------------------------------------------------------------------
// admin: the protected area
// ---------------------------------------------------------------------------

admin :: proc(req: ^web.Request, res: ^web.Response) {
	user := middlewares.request_principal(req) // set by middleware_totp
	status := middlewares.totp_status(&totp_state, user)
	mode := "开启"
	if status.enabled {
		mode = fmt.aprintf("已开启（剩余恢复码 %d 个）", status.backup_codes, allocator = web.response_allocator(res))
	}
	page(res, .OK, fmt.aprintf(`<h1>后台</h1>
<p class="ok">%s，两步验证已通过。</p>
<table>
	<tr><th>账号</th><td>%s</td></tr>
	<tr><th>TOTP</th><td>%s</td></tr>
	<tr><th>请求 id</th><td>%s</td></tr>
</table>
<form method="post" action="/logout"><button type="submit">退出登录</button></form>`,
		user, user, mode, web.request_id(req), allocator = web.response_allocator(res)))
}

logout :: proc(req: ^web.Request, res: ^web.Response) {
	middlewares.totp_sign_out(req, &gate_cfg)
	middlewares.session_destroy(req, res, &session_cfg)
	web.response_redirect(res, "/login", .Found)
}

// ---------------------------------------------------------------------------
// enrollment
// ---------------------------------------------------------------------------

setup_page :: proc(res: ^web.Response, status: web.Status, user, message: string) {
	note := ""
	if len(message) > 0 {
		note = fmt.aprintf(`<p class="err">%s</p>`, message, allocator = web.response_allocator(res))
	}
	state := middlewares.totp_status(&totp_state, user)
	body := fmt.aprintf(`<h1>TOTP 设置</h1><p>账号 <code>%s</code>：%s%s</p>`,
		user, state.enabled ? "已开启" : (state.has_binding ? "已生成密钥，等待确认" : "未开启"), note,
		allocator = web.response_allocator(res))
	if state.enabled {
		body = fmt.aprintf(`%s
<p>剩余恢复码 %d 个。重新生成会作废全部旧码。</p>
<form method="post" action="/setup/disable">
	<p><label>当前验证码 <input name="code" placeholder="123456"></label>
	<button type="submit">关闭 TOTP</button></p>
</form>
<form method="post" action="/setup/start">
	<p><button type="submit">重新生成密钥（需先关闭）</button></p>
</form>`, body, state.backup_codes, allocator = web.response_allocator(res))
	} else {
		body = fmt.aprintf(`%s
<form method="post" action="/setup/start"><button type="submit">生成密钥</button></form>`, body,
			allocator = web.response_allocator(res))
	}
	page(res, status, body)
}

setup_show :: proc(req: ^web.Request, res: ^web.Response) {
	setup_page(res, .OK, middlewares.totp_session_user(req, &gate_cfg), "")
}

setup_start :: proc(req: ^web.Request, res: ^web.Response) {
	user := middlewares.totp_session_user(req, &gate_cfg)
	alloc := web.response_allocator(res)
	enrollment, err := middlewares.totp_setup(&totp_state, user, alloc)
	#partial switch err {
	case .None:
	case .Already_Enabled:
		setup_page(res, .Conflict, user, "TOTP 已经开启；要换密钥请先关闭。")
		return
	case:
		setup_page(res, .Internal_Error, user, "生成失败（状态文件写不进去？）")
		return
	}

	codes := strings.Builder{}
	strings.builder_init(&codes, alloc)
	for code, i in enrollment.backup_codes {
		if i > 0 {
			strings.write_string(&codes, ", ")
		}
		strings.write_string(&codes, code)
	}

	page(res, .OK, fmt.aprintf(`<h1>扫描或手动输入</h1>
<p>密钥（Base32，只显示这一次）：<br><code>%s</code></p>
<p>otpauth URI（二维码编码的就是它；本示例不画二维码，用 App 的「手动输入」粘贴密钥即可）：<br>
<code style="word-break:break-all">%s</code></p>
<p>恢复码（每个只能用一次，请存到密码管理器）：<br><code>%s</code></p>
<form method="post" action="/setup/confirm">
	<p><label>App 上显示的 6 位数字 <input name="code" placeholder="123456" autofocus></label>
	<button type="submit">确认开启</button></p>
</form>`,
		enrollment.secret, enrollment.otpauth_uri, strings.to_string(codes), allocator = alloc))
}

setup_confirm :: proc(req: ^web.Request, res: ^web.Response) {
	user := middlewares.totp_session_user(req, &gate_cfg)
	raw, _ := web.request_form_value(req, "code")
	code := normalize_code(raw, web.request_allocator(req))
	#partial switch middlewares.totp_confirm(&totp_state, user, code) {
	case .None:
		web.response_redirect(res, "/admin", .Found)
	case .Invalid_Code:
		setup_page(res, .Unauthorized, user, "验证码不对；确认 App 里加的是刚刚显示的密钥。")
	case:
		setup_page(res, .Bad_Request, user, "确认失败，请从「生成密钥」重来一次。")
	}
}

setup_disable :: proc(req: ^web.Request, res: ^web.Response) {
	user := middlewares.totp_session_user(req, &gate_cfg)
	raw, _ := web.request_form_value(req, "code")
	code := normalize_code(raw, web.request_allocator(req))

	// Closing the second factor is a login-strength action: the current code
	// has to be presented, not just the session.
	#partial switch middlewares.totp_verify(&totp_state, user, code) {
	case .None:
	case .Account_Locked:
		setup_page(res, .Forbidden, user, "失败次数太多，账号临时锁定。")
		return
	case:
		setup_page(res, .Unauthorized, user, "验证码不对，无法关闭。")
		return
	}
	if middlewares.totp_disable(&totp_state, user) != .None {
		setup_page(res, .Internal_Error, user, "关闭失败（状态文件写不进去？）")
		return
	}
	setup_page(res, .OK, user, "TOTP 已关闭，之后只需密码即可登录。")
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
	address := "0.0.0.0:8080"
	if len(os.args) > 1 {
		address = os.args[1]
	}

	master_key, from_env := os.lookup_env("TOTP_SECRET", context.allocator)
	defer if from_env {
		delete(master_key, context.allocator)
	}
	if !from_env {
		fmt.eprintln("TOTP_SECRET unset: using the demo key (never do that in production)")
		master_key = DEMO_MASTER_KEY
	}

	cfg := middlewares.Totp_Config {
		issuer     = "web-totp-demo",
		secret_hex = master_key,
		path       = DEMO_STATE_PATH,
	}
	if err := middlewares.totp_init(&totp_state, cfg); err != .None {
		fmt.eprintfln("totp_init: %v (TOTP_SECRET must be 64 hex chars)", err)
		return
	}
	defer middlewares.totp_destroy(&totp_state)
	if middlewares.totp_load_failed(&totp_state) {
		// Starting empty would silently turn 2FA off for every account; a
		// corrupt file is an operator problem, not something to paper over.
		fmt.eprintfln("%s is unreadable - fix or move it before starting", DEMO_STATE_PATH)
		return
	}
	gate_cfg.totp = &totp_state

	router: web.Router
	web.router_init(&router)
	defer web.router_destroy(&router)

	web.router_use(&router, middlewares.middleware_request_id)
	web.router_use(&router, middlewares.middleware_logger)
	web.router_use(&router, middlewares.middleware_secure_headers)
	web.router_use(&router, middlewares.middleware_session, &session_cfg)

	web.router_get(&router, "/", index)
	web.router_get(&router, "/login", login_form)
	web.router_post(&router, "/login", login_submit)
	web.router_get(&router, "/totp", challenge_form)
	web.router_post(&router, "/totp", challenge_submit)
	web.router_post(&router, "/logout", logout)

	admin_route := web.router_get(&router, "/admin", admin)
	setup_route := web.router_get(&router, "/setup", setup_show)
	start_route := web.router_post(&router, "/setup/start", setup_start)
	confirm_route := web.router_post(&router, "/setup/confirm", setup_confirm)
	disable_route := web.router_post(&router, "/setup/disable", setup_disable)

	// The gate goes on the routes that need *both* factors. The login and
	// challenge pages are not gated (they are how a session becomes
	// complete), and enrollment needs a fully authenticated session, so it
	// is mounted with the gate as well.
	for route in ([]^web.Route{admin_route, setup_route, start_route, confirm_route, disable_route}) {
		web.router_use_route(route, middlewares.middleware_totp, &gate_cfg)
	}

	srv: web.Server
	if !web.server_init(&srv, address) {
		return
	}
	srv.handler = web.router_handle
	srv.user_ptr = &router
	fmt.printf("totp demo on http://%v (state %v, %v)\n", address, DEMO_STATE_PATH,
		from_env ? "master key from TOTP_SECRET" : "DEMO master key")
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
