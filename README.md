# web — Odin HTTP/1.1 基础服务库

`web` 是一个可嵌入的 HTTP/1.1 服务库（Odin 编写，零第三方依赖）：骨架学
lighttpd2 的双层状态机与 filter 管线，皮肤学 Mongoose 的 `Server + handler`
极简集成，事件循环直接用 `core:nbio`（Linux io_uring / Darwin kqueue / Windows IOCP）。

```odin
package main

import "core:fmt"
import "web"

hello :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_header(res, "Content-Type", "text/plain")
	web.response_write_string(res, "hello from odin\n")
}

main :: proc() {
	srv: web.Server
	if !web.server_init(&srv, "0.0.0.0:8080") {
		return
	}
	srv.handler = hello
	if err := web.server_run(&srv); err != nil {
		fmt.eprintfln("server error: %v", err)
	}
}
```

设计取舍、架构分层图、Odin 踩坑记录与路线图见 [docs/research.md](docs/research.md)。

## 能力清单

- HTTP/1.1 解析（零拷贝 header 视图）、keep-alive、请求管道化（pipelining）
- 请求体：`Content-Length` 与 `chunked`（增量解码、畸形防护、413 上限）
- 严格分帧（RFC 7230 §3.3.3）：`Transfer-Encoding` 与 `Content-Length` 同时
  出现、非 chunked 结尾的 TE、重复/冲突的 CL 一律 400（防请求走私）；
  上游响应侧同样严格，违规回 502
- 非阻塞写 + `sendfile` 零拷贝文件流（两阶段：头 → 文件体）
- 每连接 arena：请求间一次性释放，峰值内存与连接数无关
- Filter 输出管线：chunked 编码与 gzip/deflate 内容编码内置且默认注册
  （按 `Accept-Encoding` 协商，只压可压缩类型、跳过 `sendfile` 文件路径）
- Router：`:param` / `*` 模式、Lua 模式子集（`(%w+)` / `(%d+)` / `[a-z]` / `.-`，
  回溯 VM + 捕获栈）、405 + `Allow`、Odin 原生中间件链（无闭包）
- Cookie：`response_set_cookie` / `request_cookie`，支持 Path/Domain/Expires/
  Max-Age/Secure/HttpOnly/SameSite，Set-Cookie 不折叠
- JSON：`response_json` 直接序列化任意 Odin 值（`core:encoding/json`）
- Static：TTL stat 缓存（含负缓存）、目录 index、路径穿越防护
- Range 请求（RFC 7233）：单 range 走 `sendfile` offset 零拷贝、多 range 回
  `multipart/byteranges`、不可满足回 416 + `Content-Range: bytes */size`；
  `Last-Modified` / `If-Modified-Since`（304）/ `If-Range` 条件请求
- **反向代理**：多上游 round-robin、前缀剥离、`X-Forwarded-*`/`Via`、
  hop-by-hop 头双向过滤、Content-Length/chunked/close-delimited 三种
  上游分帧如实中继、502/504 错误语义；**边收边转发**（头即时下发，body
  按帧流式中继，内存不随响应大小增长）；**上游 keep-alive 连接池**（空闲
  连接复用 + 失效连接对幂等方法自动重拨一次）
- **TLS**：`srv.tls = &cfg` 即把每条接入连接包进 OpenSSL 会话；OpenSSL 由
  `core:dynlib` 运行时加载（无构建期 C 依赖）；握手/读写/关闭全挂在既有连接
  状态机上，handler 一行不改；TLS 下文件体改为分块 read→encrypt→send
- **多 acceptor 线程**：`server_run_multi` 每线程一个 `Server` + 独立事件循环，
  共用地址靠 `SO_REUSEPORT`，accept/读/写跨核并行且库内无锁
- 多档超时（header/idle/write + 上游 dial/send/recv）、连接数上限、
  `server_run_until` 优雅 drain、`Server.on_stop` 关停钩子（关停代理池等
  属于事件循环的资源）
- 编译期调试开关：`-define:WEB_DEBUG=true`

## 环境要求

- Odin `dev-2026-10` 或更新（`core:nbio` 的 `*_poly` 系列 API 自 dev-2025-08 起提供）

## 构建与测试

```bash
# 编译验证库本身（库包没有 main，用 build 而非 check）
odin build web -build-mode:static

# 运行全部测试（单测 + 起真实服务的集成测试，含泄漏检测）
odin test web/

# 只跑某个测试
odin test web/ -define:ODIN_TEST_NAMES=web.test_integration_head_request,

# 打开调试日志重新测试
odin test web/ -define:WEB_DEBUG=true
```

## 运行示例

```bash
# 最小服务
odin run examples/hello
curl --noproxy '*' localhost:8080/

# REST 风格 API：router + :param + 模式捕获 + Cookie + JSON + 中间件
odin run examples/api
curl --noproxy '*' localhost:8080/users/42               # :param
curl --noproxy '*' localhost:8080/orders/2024/42         # (%d+) 模式捕获
curl --noproxy '*' -X POST localhost:8080/users -d '{"name":"ada"}'
curl --noproxy '*' -b 'token=xyz' localhost:8080/whoami  # 请求 Cookie
curl --noproxy '*' -i localhost:8080/login               # Set-Cookie
curl --noproxy '*' localhost:8080/stats                  # response_json

# 静态文件 + 动态路由（第二个参数是监听地址，默认 0.0.0.0:8080）
odin run examples/static -- ./examples/www 127.0.0.1:8099
curl --noproxy '*' localhost:8099/css/a.css   # sendfile
curl --noproxy '*' -H "Range: bytes=0-9" localhost:8099/css/a.css   # 206 部分内容
curl --noproxy '*' -H "Range: bytes=0-4,10-14" localhost:8099/css/a.css  # multipart
curl --noproxy '*' localhost:8099/time        # 动态 handler

# 反向代理（先起上游，如 api 示例）
odin run examples/api -- 127.0.0.1:9000 &        # 上游 :9000
odin run examples/proxy -- 127.0.0.1:9000 127.0.0.1:8090
curl --noproxy '*' localhost:8090/health        # 本地路由
curl --noproxy '*' localhost:8090/api/users/42  # 转发为上游 GET /users/42

# HTTPS（OpenSSL 运行时加载；默认用自带自签证书）
odin run examples/https
curl -k --noproxy '*' https://127.0.0.1:8443/
curl -k --noproxy '*' https://127.0.0.1:8443/ https://127.0.0.1:8443/  # keep-alive

# 多 acceptor 线程（4 线程跑 10 秒，退出时打印每线程请求数）
odin run examples/threads
odin run examples/threads -- 8 127.0.0.1:8099 10
```

> 本机 8080 若被其他服务占用，改 `server_init` 里的地址；curl 走代理时加
> `--noproxy '*'`。macOS 接受 `SO_REUSEPORT` 但会把所有新连接交给最后 bind 的
> listener，多 acceptor 的负载分散只在 Linux/BSD 上成立（`tests` 也只在 Linux
> 断言分发）。

## 目录结构

```
web/
  doc.odin       包文档（设计 DNA + 快速上手）
  server.odin    Server：listen/accept/sweep/run，配置与统计
  conn.odin      Conn：双层状态机、每连接 arena、读写驱动
  request.odin   parse_request：请求行 + 零拷贝 header
  response.odin  response_*：构建、sendfile 切换、自动头
  router.odin    Router：段式 + Lua 模式匹配、中间件链
  range.odin     Range：字节范围解析、multipart/byteranges、HTTP-date 解析
  static.odin    Static：stat 缓存、目录 index、MIME
  cookie.odin    Cookie：Set-Cookie 序列化、请求解析
  json.odin      response_json（core:encoding/json）
  proxy.odin     Proxy：上游转发、流式中继、keep-alive 连接池
  tls.odin       TLS：core:dynlib 加载 OpenSSL + memory BIO 双向泵
  threads.odin   多 acceptor：server_run_multi、关停钩子
  socket_posix.odin   SO_REUSEPORT / listen 的系统调用补充（非 Windows）
  socket_windows.odin 同名 stub（Windows 无连接分发语义）
  filter.odin    Filter 链 + chunked 编解码
  compress.odin  gzip/deflate 编码器 + 内容协商 filter
  http.odin      Method / Status / Header / mime / http_date
  buffer.odin    Buf 与字节工具
  log.odin       分级日志（WEB_DEBUG 门控）
  testdata/      TLS 自签证书（cert.pem / key.pem）
  web_test.odin  单测 + 集成测试
examples/
  hello/         最小服务
  api/           router + 中间件 + 模式捕获 + Cookie + JSON
  static/        静态文件 + catch-all 动态路由
  proxy/         反向代理（/api 前缀剥离转发 + 本地 /health + 连接池清理）
  https/         TLS（自签证书 + keep-alive）
  threads/       多 acceptor 线程（每线程请求数统计）
  www/           静态测试资源
docs/
  research.md    调研与设计文档
```

## API 速览

**服务生命周期**

| 过程 | 作用 |
|---|---|
| `server_init(s, "0.0.0.0:8080")` | 解析地址、填默认值（不触网） |
| `server_listen(s)` | bind + 开始 accept（须在事件循环线程调用） |
| `server_run(s)` | 阻塞运行直到进程停止 |
| `server_run_until(s, &done)` | 运行至 `done` 置真，优雅 drain 在途操作 |
| `server_run_multi(servers, &done)` | 多 acceptor：每线程一个 `Server`，`SO_REUSEPORT` 共享地址 |

**生命周期钩子**：`srv.on_stop`（事件循环停止时在循环线程上调用，用于释放代理
连接池这类属于循环的资源）、`srv.on_conn_open` / `srv.on_conn_close`。

**Handler**（Mongoose 式：`proc(req: ^Request, res: ^Response)`）

```odin
srv.handler = my_handler          // 单 handler
srv.handler = web.router_handle   // 或交给 router
srv.user_ptr = &router            // router/static 等用户状态挂这里
```

**请求侧**：`request_header` / `request_query` / `request_param` /
`request_cookie` / `request_cookies` / `request_body_string`；解析结果
`req.method`、`req.path`、`req.params`、`req.captures`。

**响应侧**：`response_status` / `response_set_header` / `response_add_header`
（Set-Cookie 等可重复头）/ `response_write` / `response_write_string` /
`response_send_file` / `response_redirect` / `response_json` /
`response_set_cookie`。
框架自动补 `Date`/`Server`/`Connection`/`Content-Length`。

**Cookie / JSON / 模式路由**

```odin
// Set-Cookie：Path / Domain / Expires / Max-Age / Secure / HttpOnly / SameSite
web.response_set_cookie(res, web.Cookie{name = "session", value = "abc", http_only = true, same_site = .Lax})
token, ok := web.request_cookie(req, "session")   // 读请求 Cookie

// JSON：任意 Odin 值直接序列化
web.response_json(res, User{name = "ada", id = 42})

// Lua 模式子集路由：捕获按位次取（1 起）
web.router_get(&router, "/users/(%d+)/posts/(%w+)", get_post)
id, _ := web.request_capture(req, 1)              // "42"
```

**Router**

```odin
web.router_init(&router)
web.router_use(&router, my_middleware, nil)
web.router_get(&router, "/users/:id", get_user)
web.router_post(&router, "/*", catch_all)
```

中间件签名（无闭包，显式索引续链）：

```odin
my_middleware :: proc(m: ^web.Middleware, r: ^web.Router, idx: int,
                      final: web.Handler, req: ^web.Request, res: ^web.Response) {
	// 前置处理……
	web.router_next(r, idx + 1, final, req, res)   // 注意 idx + 1
	// 后置处理……
}
```

**Static**

```odin
files: web.Static
web.static_init(&files, "./www")
srv.user_ptr = &files
srv.handler = web.static_serve
```

**Proxy**（反向代理）

```odin
proxy: web.Proxy
web.proxy_init(&proxy, {"127.0.0.1:9000", "127.0.0.1:9001"}) // round-robin
proxy.strip_prefix = "/api"   // 客户端 /api/x -> 上游 /x
proxy.timeout = 10 * time.Second
proxy.keep_alive = true       // 上游连接池（默认开）
proxy.max_idle_per_host = 16  // 每上游最多闲置连接数
proxy.idle_timeout = 30 * time.Second

srv.user_ptr = &proxy
srv.handler = web.proxy_serve
// 池里的 socket 属于事件循环，关停时要在循环线程上释放：
srv.on_stop = proc(s: ^web.Server) { web.proxy_close_idle(&proxy) }
// 或挂在 router 下：web.router_add(&router, .Get, "/api/*", forward)
```

行为要点：

- 上游连接复用：请求结束且上游未要求关闭时，socket 进池（按上游维度，默认
  闲置上限 16 条 / 30 s）；下个请求优先取池。取到的连接若已失效，幂等方法
  （GET/HEAD/OPTIONS）在尚未向客户端发字节时自动重拨一次
- 请求方向：`Host` 改写为上游；追加 `X-Forwarded-For`（保留原链）、
  `X-Forwarded-Proto`、`Via`；过滤 hop-by-hop 头；body 按实际长度重发
  `Content-Length`
- 响应方向：过滤 hop-by-hop 头；`Content-Length` 原样透传；chunked 分帧
  原样透传（按 chunk 大小走查判定完整性，不解码）；无长度分帧（HTTP/1.0
  close-delimited）重分帧为 chunked 发给 HTTP/1.1 客户端（HTTP/1.0 客户端
  仍以关闭连接结束）
- **流式**：响应头一到就下发，body 按帧边收边发，同一时刻只有一个方向在途，
  内存不随响应大小增长。头已发出后上游出错只断连接，不再追加错误页
- 1xx  informational 响应自动跳过；204/304/HEAD 不等待 body；未知状态码
  （如 599）连 reason phrase 一起透传
- 上游连接失败/写失败/读失败 → 502；上游读超时 → 504；错误响应后关连接

**TLS**

```odin
cfg: web.Tls_Config
if !web.tls_config_init(&cfg, "cert.pem", "key.pem") { return }
defer web.tls_config_destroy(&cfg)

srv.tls = &cfg          // 之后每条接入连接都包一层 OpenSSL
srv.handler = my_handler // handler 完全不用改
```

- OpenSSL 由 `core:dynlib` 在运行时加载（macOS 上只按绝对路径搜索：未签名
  二进制经 fallback 路径加载 libcrypto 会被 dyld 直接 abort）
- memory BIO 双向泵：socket → rbio → `SSL_read` → 请求缓冲；响应 → `SSL_write`
  → wbio → socket。握手是连接状态机的一个阶段
- TLS 下没有 `sendfile`，文件体按 64 KiB 分块 read → encrypt → send

**多 acceptor 线程**

```odin
servers: [4]^web.Server
for i in 0..<len(servers) {
	s := new(web.Server)
	web.server_init(s, "0.0.0.0:8080")
	s.handler = handler
	servers[i] = s
}
web.server_run_multi(servers[:], &done)   // 主线程跑 servers[0]
```

每线程独立事件循环 + 独立 `SO_REUSEPORT` listener，库内无锁。`user_ptr` 指向
的状态不是自动共享的：只读的 router 表可以直接共用，持有事件循环资源的状态
（如 `Proxy` 及其上游池）必须每线程一份。端口写 0 时由首个 server 先绑定，
其余线程回填同一端口。

**配置字段**（`server_init` 之后的默认值）

| 字段 | 默认 | 说明 |
|---|---|---|
| `keep_alive` | `true` | HTTP/1.1 默认长连接 |
| `max_requests_per_conn` | 1000 | 达到后响应带 `Connection: close` |
| `max_header_size` | 16 KB | 超出 431 |
| `max_body_size` | 10 MB | 超出 413 |
| `max_conns` | 1024 | 超出拒绝新连接 |
| `header_timeout` | 30 s | 收齐一个请求头的上限 |
| `write_timeout` | 30 s | 单次写操作上限 |
| `idle_timeout` | 5 s | keep-alive 空闲上限 |

**连接事件**：`srv.on_conn_open` / `srv.on_conn_close`，签名
`proc(s: ^Server, c: ^Conn)`。

## 测试覆盖

`odin test web/` 共 61 个用例：parser / chunked / router / response 序列化 /
proxy 解析与分帧决策 / cookie 序列化与解析 / JSON / Lua 模式匹配（22 组模式
用例）/ Range 解析（14 组语法用例）/ HTTP-date 解析 / If-Range / 严格分帧
（15 组用例）/ CRC32 与 deflate-gzip 往返 / 可压缩类型判定 单测，加 20 多个
真实起服务的集成测试（请求响应闭环 + body 回显、畸形请求 400、chunked 请求体、
pipelined 双请求、HEAD、空文件 sendfile、代理 GET/POST、chunked 上游中继、
close-delimited 上游重分帧、上游拒连 502、Cookie、JSON、模式路由、静态
Range 全路径：单 range 206 / 多 range multipart / 416 / 304 / If-Range、
gzip 内容协商与 chunked 组合、代理流式早发 / 失效池重试 / 池命中计数、
3 acceptor 共享端口、TLS 配置 / GET / keep-alive / 200 KiB 静态文件逐字节比对），
Odin test runner 内存追踪零泄漏。

## 与 odin-http 的关系

服务端能力已覆盖并超出 odin-http（laytan/odin-http）的主体：协议解析、
keep-alive、请求体（Content-Length/chunked）、路由、响应助手、静态文件、
Cookie、JSON，并在 filter 管线、中间件链、stat 缓存 + sendfile、流式反向代理、
TLS、多 acceptor、多档超时、连接上限等生产向细节上领先。剩余缺口只有 HTTP
客户端（odin-http 的 `client` 子包）。完整逐项对比见 `docs/research.md` §1.4。

## 明确不做

HTTP/2、配置文件语言、动态模块加载、多进程模型（交给外部 supervisor）。
TLS 采用「运行时加载 OpenSSL + socket 层包装」，不引入构建期 C 依赖，也不做
自研密码学实现。
