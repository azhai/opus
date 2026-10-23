# web — Odin HTTP/1.1 基础服务库

`web` 是一个可嵌入的 HTTP/1.1 服务库（Odin 编写，零第三方依赖）：骨架学
lighttppd2 的双层状态机与 filter 管线，皮肤学 Mongoose 的 `Server + handler`
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
- 非阻塞写 + `sendfile` 零拷贝文件流（两阶段：头 → 文件体）
- 每连接 arena：请求间一次性释放，峰值内存与连接数无关
- Filter 输出管线（chunked 编码内置且默认注册；gzip/TLS 是预留扩展点）
- Router：`:param` / `*` 模式、405 + `Allow`、Odin 原生中间件链（无闭包）
- Static：TTL stat 缓存（含负缓存）、目录 index、路径穿越防护
- **反向代理**：多上游 round-robin、前缀剥离、`X-Forwarded-*`/`Via`、
  hop-by-hop 头双向过滤、Content-Length/chunked/close-delimited 三种
  上游分帧如实中继、502/504 错误语义
- 多档超时（header/idle/write + 上游 dial/send/recv）、连接数上限、
  `server_run_until` 优雅 drain
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

# REST 风格 API：router + :param + 中间件
odin run examples/api
curl --noproxy '*' localhost:8080/users/42
curl --noproxy '*' -X POST localhost:8080/users -d '{"name":"ada"}'

# 静态文件 + 动态路由
odin run examples/static -- ./examples/www
curl --noproxy '*' localhost:8080/css/a.css   # sendfile
curl --noproxy '*' localhost:8080/time        # 动态 handler

# 反向代理（先起上游，如 api 示例）
odin run examples/api -- 9000 &                # 上游 :9000
odin run examples/proxy -- 127.0.0.1:9000      # 代理 :8080
curl --noproxy '*' localhost:8080/health       # 本地路由
curl --noproxy '*' localhost:8080/api/users/42 # 转发为上游 GET /users/42
```

> 本机 8080 若被其他服务占用，改 `server_init` 里的地址；curl 走代理时加
> `--noproxy '*'`。

## 目录结构

```
web/
  doc.odin       包文档（设计 DNA + 快速上手）
  server.odin    Server：listen/accept/sweep/run，配置与统计
  conn.odin      Conn：双层状态机、每连接 arena、读写驱动
  request.odin   parse_request：请求行 + 零拷贝 header
  response.odin  response_*：构建、sendfile 切换、自动头
  router.odin    Router：两遍匹配、中间件链
  static.odin    Static：stat 缓存、目录 index、MIME
  proxy.odin     Proxy：上游转发、hop-by-hop 过滤、分帧中继
  filter.odin    Filter 链 + chunked 编解码
  http.odin      Method / Status / Header / mime / http_date
  buffer.odin    Buf 与字节工具
  log.odin       分级日志（WEB_DEBUG 门控）
  web_test.odin  单测 + 集成测试
examples/
  hello/         最小服务
  api/           router + 中间件 + 请求体回显
  static/        静态文件 + catch-all 动态路由
  proxy/         反向代理（/api 前缀剥离转发 + 本地 /health）
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

**Handler**（Mongoose 式：`proc(req: ^Request, res: ^Response)`）

```odin
srv.handler = my_handler          // 单 handler
srv.handler = web.router_handle   // 或交给 router
srv.user_ptr = &router            // router/static 等用户状态挂这里
```

**请求侧**：`request_header` / `request_query` / `request_param` /
`request_body_string`；解析结果 `req.method`、`req.path`、`req.params`。

**响应侧**：`response_status` / `response_set_header` / `response_write` /
`response_write_string` / `response_send_file` / `response_redirect`。
框架自动补 `Date`/`Server`/`Connection`/`Content-Length`。

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

srv.user_ptr = &proxy
srv.handler = web.proxy_serve
// 或挂在 router 下：web.router_add(&router, .Get, "/api/*", forward)
```

行为要点：

- 每个请求新开一条上游连接并发 `Connection: close`，无上游连接池，
  上游 socket 生命周期恰好一个请求
- 请求方向：`Host` 改写为上游；追加 `X-Forwarded-For`（保留原链）、
  `X-Forwarded-Proto`、`Via`；过滤 hop-by-hop 头；body 按实际长度重发
  `Content-Length`
- 响应方向：过滤 hop-by-hop 头；`Content-Length` 原样透传；chunked 分帧
  原样透传（按 chunk 大小走查判定完整性，不解码）；两者都没有时缓冲到
  上游 EOF 后由代理补 `Content-Length` 重新分帧
- 1xx  informational 响应自动跳过；204/304/HEAD 不等待 body；未知状态码
  （如 599）连 reason phrase 一起透传
- 上游连接失败/写失败/读失败 → 502；上游读超时 → 504；错误响应后关连接

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

`odin test web/` 共 30 个用例：parser / chunked / router / response 序列化 /
proxy 解析（hop-by-hop 过滤、chunked 走查、上游头解析、round-robin）单测，
加 11 个真实起服务的集成测试（请求响应闭环 + body 回显、畸形请求 400、
chunked 请求体、pipelined 双请求、HEAD、空文件 sendfile、代理 GET/POST、
chunked 上游中继、close-delimited 上游重分帧、上游拒连 502），Odin test
runner 内存追踪零泄漏。

## 明确不做

TLS（预留 filter 挂接点）、HTTP/2、配置文件语言、动态模块加载、多进程模型
（交给外部 supervisor）。
