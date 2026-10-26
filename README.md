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
  回溯 VM + 捕获栈）、405 + `Allow`、HEAD 自动回落到同名 GET 路由、Odin 原生  
  中间件链（无闭包，支持全局链 + 路由级链）；未命中路径也走中间件链，末端才回  
  404/405
- 应用层 helper（对标 Fiber/Echo 的 context）：`request_hostname` /  
  `request_scheme` / `request_client_ip` / `request_content_type` /  
  `request_is_ajax` / `request_accepts` / `request_json`、`response_json_status` /  
  `response_error` / `response_download` / `response_clear_cookie` 等
- 内置中间件（`web/middlewares` 子包）：request id、访问日志、CORS（含预检）、  
  Basic/Bearer/API-Key 认证、正文限额、安全响应头、禁缓存、表单解析、  
  Range+ETag、流式反缓冲、**gzip 开关**、**签名 Cookie 会话**、**JWT(HS256) 校验**、  
  **静态目录挂载**、**重定向规则**、**multipart 落盘上传**；可全局注册，也可用  
  `router_use_route` **只挂到某一条路由**（认证只护 `/admin`）
- 表单正文：`middleware_form` 一次解析 `application/x-www-form-urlencoded` 与  
  `multipart/form-data`，字段进 `request_form` / `request_form_value`，上传文件  
  进 `request_files` / `request_file`（限字段数与单文件大小，超限 413）；  
  `middleware_upload` 再把文件落盘（`request_uploads` 拿到路径与大小）
- **流式上传落盘**：`upload_sink_attach` 在请求体读之前接管它，multipart 解析器  
  边收边解析，大 part 直接写临时文件（内存只留一个 recv 块 + 阈值内的前缀），  
  因此上传大小不再受 `max_body_size` 约束；`Form_File` 多了 `path` / `size`，  
  小 part 仍在内存（`data`），`request_file` 两者通用
- **内部重写**：`router_rewrite` 在路由表之前改写路径（不发响应、不改地址栏），  
  与之相对的是 `middleware_redirect`（真发 3xx，让客户端再请求一次）
- SSE：`sse_start` / `sse_event` / `sse_comment` / `sse_retry` / `sse_last_event_id` /  
  `sse_close`，chunked 分帧 + 浏览器自动重连语义，handler 不需要自己拼帧；  
  `Sse_Writer` 自带复用缓冲，逐事件零分配
- Cookie：`response_set_cookie` / `request_cookie`，支持 Path/Domain/Expires/  
  Max-Age/Secure/HttpOnly/SameSite，Set-Cookie 不折叠
- JSON：`response_json` 直接序列化任意 Odin 值（`core:encoding/json`）
- Static：TTL stat 缓存（含负缓存）、目录 index、路径穿越防护
- Range 请求（RFC 7233）：单 range 走 `sendfile` offset 零拷贝、多 range 回  
  `multipart/byteranges`、不可满足回 416 + `Content-Range: bytes */size`；  
  `Last-Modified` / `If-Modified-Since`（304）/ `If-Range` 条件请求
- **反向代理**：多上游平滑加权轮询（`weight` + nginx 式 current_weight）、  
  前缀剥离、`X-Forwarded-*`/`Via`、hop-by-hop 头双向过滤、Content-Length/  
  chunked/close-delimited 三种上游分帧如实中继、502/504 错误语义；**边收边  
  转发**（头即时下发，body 按帧流式中继，内存不随响应大小增长）；**上游  
  keep-alive 连接池**（空闲连接复用 + 失效连接对幂等方法自动重拨一次）；  
  **主动健康检查**：连续失败摘除 + 指数退避 + 半开探测 + 全摘除时 fail-open
- **TLS**：`srv.tls = &cfg` 即把每条接入连接包进 OpenSSL 会话；OpenSSL 由  
  `core:dynlib` 运行时加载（无构建期 C 依赖）；握手/读写/关闭全挂在既有连接  
  状态机上，handler 一行不改；TLS 下文件体改为分块 read→encrypt→send；  
  **会话复用**（`SSL_CTX` session cache + TLS 1.3 ticket，`stats.tls_resumed`  
  可观测，重启后仍能复用的 `session_id_context`）
- **异步 handler / 并发流**：`response_defer` 把连接停在 `Async` 态并交出一条  
  续延，事件循环线程立刻去服务别的连接；`request_resume`（或到期超时）跑续延，  
  之后与同步响应走同一条收尾路径。`Hub` 在其上做 SSE 广播：一个订阅者是一个  
  结构体 + 一个队列，不是一条线程
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
odin build web/middlewares -build-mode:static

# 运行全部测试（单测 + 起真实服务的集成测试，含泄漏检测）
# THREADS=1 不是可选项：集成测试各自在自己线程上跑一个 nbio 事件循环，而 nbio 的
# 操作归创建它的线程所有，多线程并行会 panic「nbio.remove called on different
# thread」，连带把 hub / async 的用例一起带崩
odin test web/ -define:ODIN_TEST_THREADS=1
odin test web/middlewares -define:ODIN_TEST_THREADS=1

# 只跑某个测试
odin test web/ -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=web.test_integration_head_request

# 打开调试日志重新测试
odin test web/ -define:ODIN_TEST_THREADS=1 -define:WEB_DEBUG=true
```

## 运行示例

```bash
# 最小服务
odin run examples/hello
curl --noproxy '*' localhost:8080/

# REST 风格 API：router + :param + 模式捕获 + Cookie + JSON 绑定/响应 +
# 内置 request-id/access-log 中间件；错误与 404 也是 JSON
odin run examples/api
curl --noproxy '*' localhost:8080/users/42               # :param
curl --noproxy '*' localhost:8080/orders/2024/42         # (%d+) 模式捕获
curl --noproxy '*' -X POST localhost:8080/users -H 'Content-Type: application/json' -d '{"name":"ada"}'   # request_json -> 201
curl --noproxy '*' localhost:8080/users/abc              # {"error":"id must be an integer"} + 400
curl --noproxy '*' -i localhost:8080/nope                # JSON 404
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

# 专用中间件（按路由挂载：认证 / 表单上传 / Range+ETag / SSE / 流式上传）
odin run examples/middlewares -- 127.0.0.1:8091
curl --noproxy '*' -r 10-19 localhost:8091/report.csv          # 206
curl --noproxy '*' -I localhost:8091/report.csv                # ETag / Accept-Ranges
curl --noproxy '*' -u admin:secret localhost:8091/admin         # 401 -> 200
curl --noproxy '*' -H 'X-API-Key: key-live-1' localhost:8091/api/keys
curl --noproxy '*' -F name=ada -F avatar=@README.md localhost:8091/submit
curl --compressed --noproxy '*' localhost:8091/big             # 单路由 gzip
curl -N --noproxy '*' localhost:8091/events                    # SSE
curl --noproxy '*' -F doc=@big.bin localhost:8091/upload        # 边收边落盘

# 一个小型应用：会话 / JWT / 静态挂载 / 重写 / 重定向 / 上传 / gzip
odin run examples/webapp -- 127.0.0.1:8092
curl --noproxy '*' -c /tmp/c -d user=ada localhost:8092/login   # 会话 Cookie
curl --noproxy '*' -b /tmp/c -c /tmp/c localhost:8092/me        # 计数递增
TOK=$(curl -s --noproxy '*' localhost:8092/token)               # 签发 JWT
curl --noproxy '*' -H "Authorization: Bearer $TOK" localhost:8092/api/profile
curl -i --noproxy '*' localhost:8092/old                        # 308 -> /
curl    --noproxy '*' localhost:8092/intro                      # 内部重写到 /
curl    --noproxy '*' localhost:8092/assets/app.css             # 静态挂载
curl --noproxy '*' -F doc=@README.md localhost:8092/upload      # 落盘到 ./uploads

# 多 acceptor 线程（4 线程跑 10 秒，退出时打印每线程请求数）
odin run examples/threads
odin run examples/threads -- 8 127.0.0.1:8099 10
```

> 本机 8080 若被其他服务占用，改 `server_init` 里的地址；curl 走代理时加  
> `--noproxy '*'`。macOS 接受 `SO_REUSEPORT` 但会把所有新连接交给最后 bind 的  
> listener，多 acceptor 的负载分散只在 Linux/BSD 上成立（`tests` 也只在 Linux  
> 断言分发）。

## 性能

`bench/` 是随仓库维护的测量工具，不参与库构建：一半是微基准（直接调库函数，  
逐项报告 ns/op、分配次数与字节数），一半是起真实服务 + 客户端打真实请求（报  
req/s 与每请求耗时）。两者都必须用 `-o:speed` 编译——默认的调试构建慢一个数量  
级，量出来的数字没有意义：

```bash
odin run bench -o:speed
```

### 一次实测（Apple Silicon，单核，环回 TCP）

| 微基准 | 耗时 | 分配 |
| --- | --- | --- |
| `parse_request`（9 个头 / 240 B） | 262 ns | 1.3 /op |
| `router_match` 静态路由（120 条表的第 1 / 第 120 条） | 6.1 / 8.0 ns | 0 |
| `router_match` `:param` 路由 | 157 ns | 1.3 /op |
| `router_match` 未命中（404 两趟） | 160 ns | 0 |
| `response_build`（4 KiB JSON + Date） | 254 ns | 6.0 /op |
| `gzip_compress` 64 KiB JSON | 378 µs（115 MiB/s，压缩比 14.4%） | 2.2 /op |
| multipart 增量解析（1 MiB part） | 404 µs（2474 MiB/s） | 7.9 /op |

| 负载（单 loop 线程） | 吞吐 | 每请求 |
| --- | --- | --- |
| pipelined 静态路由（512 深度） | 1.3 M req/s | 0.78 µs |
| pipelined 4 KiB JSON | 261 k req/s | 3.8 µs |
| pipelined 4 KiB JSON + gzip | 66 k req/s | 15.2 µs |
| pipelined 404（stat 缓存负命中） | 1.2 M req/s | 0.84 µs |
| 串行 keep-alive（一次一个请求） | 60 k req/s | 17 µs / RTT |
| sendfile 4 KiB 文件 | 25 k req/s | 40 µs |

pipelined 与串行的差距全部来自系统调用：单个请求的库内 CPU 只有几百纳秒（上面  
几个微基准之和），而一次 send/recv 在环回上就要一两微秒。结论很直接——优化的  
着力点不是「算得更快」，而是「少进出内核、少重复算」。

### 已经做掉的优化（按收益排序）

| 问题 | 做法（数据结构 / 算法） | 前后 |
| --- | --- | --- |
| 路由逐条线性扫描，代价随路由表长度增长 | literal 路径建哈希索引：`map[string]^Route_Entry`，entry 内按 HTTP 方法分槽，模式路由另存列表只在未命中时走 | 120 条表的末位 3.18 µs → 8 ns；404 3.51 µs → 160 ns |
| 每响应清空 128 KiB 匹配表 | 匹配表改用「滚动位置 + 基址」，上一条响应的遗留项靠 `cand >= limit` 自然失效（zlib 的 `strstart` 同法），只做一次重归一 | 64 KiB JSON 890 → 378 µs（2.3×），pipelined gzip 场景 +100% |
| 每请求一次 send，流水线里就是每响应一次系统调用 | 已排队且无 body 的请求把响应攒进 `c.out` 合并写（上限 16 KiB）；有 body / 有文件体 / TLS / `Connection: close` / 下一个头未到齐都不合并 | pipelined 63 k → 1.3 M req/s（20×）；串行路径 0 变化 |
| `Date` 头每个响应都格式化一次 | 每秒缓存一次（`Date_Cache`），`http_date_buf` 写栈缓冲再 copy | `response_build` 302 → 254 ns |
| 子串搜索逐字节比较 | Boyer-Moore-Horspool（needle ≥ 3 且 haystack ≥ 64 才启用，短串仍走朴素扫描），配 256 项位移表 | 大正文的 multipart / chunked 边界搜索 |
| 头部逐块到达时每次 recv 都从 0 重扫 | 扫描游标 `head_scanned`，只在跨界处回退 3 字节 | 8 KiB 头分 16 段到达：16 次全扫 → 一次 |
| stat 缓存无上限，404 洪水能撑爆内存 | `max_cache_entries`（默认 8192）+ 批量淘汰：先放过期项，再收敛到 `limit/2` | 内存有界，命中率不变 |
| Hub 广播每个订阅者两次拷贝；注销要线性扫 | 空闲订阅者直写 `c.out` 少一次拷贝；`index` 字段 + 末位换位删除 O(1)；背压按「队列 + 在途」合并计 | 大扇出时每事件少一次 memcpy，注销 O(n) → O(1) |
| 响应头动态数组反复扩容 | `response_init`/`response_reset` 后 `reserve(8)` | 4 KiB JSON 少 2~3 次扩容 |

一条反向经验也记在这里：给**请求**头数组预留同样 12 个槽位，让 `Request` 变大、  
L1 压力上升，`parse_request` 从 253 ns 退到 272 ns，已回退。不是延迟加载的分配  
器上，「预留」不是免费的。  

复现与关掉：`WRITE_BATCH_BYTES = 0` 可关闭响应合并，用来做 A/B；  
`bench/load.odin` 里每个场景就是一个 handler + 一行 `run_scenario`，加场景比改库  
便宜。

## 目录结构

```
web/
  doc.odin       包文档（设计 DNA + 快速上手）
  server.odin    Server：listen/accept/sweep/run，配置与统计
  conn.odin      Conn：双层状态机、每连接 arena、读写驱动
  request.odin   parse_request：请求行 + 零拷贝 header
  response.odin  response_*：构建、sendfile 切换、自动头
  router.odin    Router：段式 + Lua 模式匹配、全局链 + 路由级链、内部重写
  form.odin      表单解析（urlencoded + multipart）+ 访问器（中间件只做编排）
  range.odin     Range：字节范围解析、multipart/byteranges、HTTP-date 解析
  static.odin    Static：stat 缓存、目录 index、MIME
  cookie.odin    Cookie：Set-Cookie 序列化、请求解析
  json.odin      response_json（core:encoding/json）
  proxy.odin     Proxy：上游转发、流式中继、keep-alive 连接池
  proxy_health.odin  上游权重（平滑加权轮询）、摘除/半开探测、fail-open
  tls.odin       TLS：core:dynlib 加载 OpenSSL + memory BIO 双向泵 + 会话复用
  async.odin     延迟响应：response_defer / request_resume / 超时续延
  hub.odin       SSE 广播：一个订阅者 = 一个结构体 + 有界队列（非一线程）
  multipart_stream.odin  增量 multipart 解析（边收边解析，保留分隔符尾部）
  upload.odin    body sink：multipart part 边收边落盘（临时文件 + 清理）
  threads.odin   多 acceptor：server_run_multi、关停钩子
  socket_posix.odin   SO_REUSEPORT / listen 的系统调用补充（非 Windows）
  socket_windows.odin 同名 stub（Windows 无连接分发语义）
  filter.odin    Filter 链 + chunked 编解码（含流式 emit 模式）
  stream.odin    Hijack 后的流式辅助：写头、写帧、对端探测
  sse.odin       SSE：sse_start/event/comment/retry/close（chunked 帧）
  compress.odin  gzip/deflate 编码器 + 内容协商 filter
  http.odin      Method / Status / Header / mime / http_date
  uri.odin       url_decode/url_encode + url_path_clean（路径规范化）
  html.odin      html_escape
  buffer.odin    Buf 与字节工具
  log.odin       分级日志（WEB_DEBUG 门控）
  testdata/      TLS 自签证书（cert.pem / key.pem）
  middlewares/   中间件子包（import ".."）：见下
  *_test.odin    按主题拆分的测试：parser / router / response / proxy / cookie /
                 json / pattern / range / framing / compress / tls / http /
                 sse / multipart_stream / upload / hub / buffer / static /
                 conn / integration / support
bench/
  main.odin      微基准（parse/router/response/compress/multipart）+ fixtures
  load.odin      起真实服务 + pipelined / 串行客户端，报 req/s 与每请求耗时
examples/
  hello/         最小服务
  api/           router + 内置中间件 + 模式捕获 + Cookie + JSON（错误也是 JSON）
  static/        静态文件 + catch-all 动态路由
  proxy/         反向代理（/api 前缀剥离转发 + 本地 /health + 连接池清理）
  https/         TLS（自签证书 + keep-alive）
  threads/       多 acceptor 线程（每线程请求数统计）
  middlewares/   按路由挂载的专用中间件：认证 / 表单 / Range+ETag / gzip / SSE /
                 流式上传
  webapp/        一个小型应用：会话 / JWT / 静态挂载 / 重写 / 重定向 / 上传
  www/           静态测试资源
docs/
  research.md    调研与设计文档
```

```
web/middlewares/              中间件子包（package middlewares，import ".."）
  middleware.odin  通用：request id、访问日志、CORS、限额、安全头、禁缓存、反缓冲
  auth.odin        Basic / Bearer / API-Key + principal
  range.odin       Range + ETag（handler 只写完整正文）
  form.odin        middleware_form（解析留在父包的 form.odin，避免循环 import）
  gzip.odin        middleware_gzip / middleware_no_gzip（按响应开关压缩）
  session.odin     签名 Cookie 会话：session_get / set / delete / destroy
  jwt.odin         HS256：middleware_jwt / jwt_sign / jwt_verify
  static.odin      目录树挂载（可 SPA 回落），复用父包的 stat 缓存 + sendfile
  redirect.odin    middleware_redirect / middleware_https_redirect
  upload.odin      multipart 落盘：request_uploads / request_upload；stream 模式下
                   由 upload_stream_hook 在请求体读之前接管（见 README 流式上传）
  token.odin       共享原语：base64url + HMAC-SHA256 签名/验签
  *_test.odin     中间件单测（42 个）
```


## API 速览

**服务生命周期**

| 过程                                 | 作用                                            |
| ---------------------------------- | --------------------------------------------- |
| `server_init(s, "0.0.0.0:8080")`   | 解析地址、填默认值（不触网）                                |
| `server_listen(s)`                 | bind + 开始 accept（须在事件循环线程调用）                  |
| `server_run(s)`                    | 阻塞运行直到进程停止                                    |
| `server_run_until(s, &done)`       | 运行至 `done` 置真，优雅 drain 在途操作                   |
| `server_run_multi(servers, &done)` | 多 acceptor：每线程一个 `Server`，`SO_REUSEPORT` 共享地址 |

**生命周期钩子**：`srv.on_stop`（事件循环停止时在循环线程上调用，用于释放代理  
连接池这类属于循环的资源）、`srv.on_conn_open` / `srv.on_conn_close`、  
`srv.on_head`（请求头解析完、请求体读之前；返回 `false` 表示钩子自己回了响应）  
与 `srv.on_tick`（每 250 ms 在循环线程上跑一次，代理健康探测/缓存过期/指标采样）。

**Handler**（Mongoose 式：`proc(req: ^Request, res: ^Response)`）

```odin
srv.handler = my_handler          // 单 handler
srv.handler = web.router_handle   // 或交给 router
srv.user_ptr = &router            // router/static 等用户状态挂这里
```

**请求侧**：`request_header` / `request_query` / `request_query_all` /  
`request_query_params` / `request_param` / `request_capture` /  
`request_cookie` / `request_cookies` / `request_body_string` /  
`request_json`（正文反序列化到任意 Odin 值）；解析结果 `req.method`、  
`req.path`、`req.params`、`req.captures`。

上下文类（对齐 Echo 的 `Host/Hostname/RealIP/IsAjax/Accepts`、Fiber 的  
`Hostname/IP/BodyParser`）：`request_host` / `request_hostname` /  
`request_scheme` / `request_remote_addr` / `request_client_ip` /  
`request_content_type` / `request_is_ajax` / `request_accepts` /  
`request_id`。

**响应侧**：`response_status` / `response_set_header` / `response_add_header`  
（Set-Cookie 等可重复头）/ `response_remove_header` / `response_set_content_type`  
/ `response_write` / `response_write_string` / `response_send_file` /  
`response_redirect` / `response_json` / `response_json_status` /  
`response_error` / `response_download`（附件）/ `response_set_disposition` /  
`response_set_cookie` / `response_clear_cookie`。  
框架自动补 `Date`/`Server`/`Connection`/`Content-Length`；`response_body_size`  
给日志/计量用（内存体或 sendfile 文件大小）。

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

未命中的路径也要过中间件链（末端回 404/405）：这样 CORS 预检（一个没有路由  
注册的 `OPTIONS`）、404 的访问日志、统一的安全头都能生效。`router_all` 注册  
的路由对所有方法生效。

**内置中间件**都在 `web/middlewares` 子包里（`router_use` 全局注册，或  
`router_use_route` 挂到单条路由；需要配置的从 `ud` 传 `^Xxx_Config`，`nil`  
即默认值）：

```odin
import "web"
import "web/middlewares"     // 父包不能反向 import 子包，所以两边都要写

web.router_use(&router, middlewares.middleware_request_id)
```

| 过程                                       | 作用                                                                                                           | 配置                      |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------- |
| `middleware_request_id`                  | 复用/生成 `X-Request-Id`，写回响应头并挂到 `request_id(req)`                                                              | —                       |
| `middleware_logger`                      | 每请求一行：状态、方法、路径、字节数、耗时、id、客户端 IP、认证主体                                                                         | —                       |
| `middleware_secure_headers`              | `nosniff` / `X-Frame-Options` / `Referrer-Policy`，可加 CSP、HSTS                                                | `Secure_Headers_Config` |
| `middleware_no_cache`                    | `Cache-Control: no-store` 等，给登录页/API 用                                                                       | —                       |
| `middleware_cors`                        | 预检直接回 204 不跑路由；按 Origin 白名单决定回 `*` 还是回显 + `Vary: Origin`                                                     | `CORS_Config`           |
| `middleware_basic_auth`                  | `Authorization: Basic`，等时比较，401 带 `WWW-Authenticate`                                                         | `Basic_Auth_Config`     |
| `middleware_bearer_auth`                 | `Authorization: Bearer <token>`，令牌表白名单，401 带 `error="invalid_token"`                                         | `Bearer_Auth_Config`    |
| `middleware_api_key`                     | 自定义头（默认 `X-API-Key`）+ 可选 query 兜底                                                                            | `API_Key_Config`        |
| `middleware_jwt`                         | `Authorization: Bearer <jwt>`，HS256 校验 `alg`→签名→`exp`/`nbf`/`iss`/`aud`；401 带 `error="invalid_token"`        | `Jwt_Config`            |
| `middleware_session`                     | 签名 Cookie 会话：验签后挂到请求，handler 返回后只在有改动时回写 Cookie                                                              | `Session_Config`        |
| `middleware_body_limit`                  | 按 `Content-Length` 提前回 413（chunked 仍由 `Server.max_body_size` 兜底）                                             | `Body_Limit_Config`     |
| `middleware_form`                        | 解析 urlencoded / multipart 正文一次并缓存；非表单正文 415、畸形 400、超限 413                                                    | `Form_Config`           |
| `middleware_upload`                      | multipart 文件落盘（目录按需创建、文件名消毒+时间戳）；超限 413，非 multipart 放行                                                       | `Upload_Config`         |
| `middleware_range`                       | handler 只管写完整正文：单 range → 206 + `Content-Range`，不可满足 → 416，`etag = true` 再加内容哈希 ETag + `If-None-Match` → 304 | `Range_Config`          |
| `middleware_static`                      | 把目录树挂到某条路由（可剥前缀、可 SPA 回落），命中就 serve，未命中继续走链                                                                  | `Static_Mount_Config`   |
| `middleware_redirect`                    | 规则表命中就发 3xx（默认 308，方法保持），未命中继续走链                                                                             | `Redirect_Config`       |
| `middleware_https_redirect`              | 同一 URL 改 https 发回（Host 取自请求）                                                                                 | `Https_Redirect_Config` |
| `middleware_gzip` / `middleware_no_gzip` | 按路由开/关内容编码（`no_gzip` 用于图片、已压资源、流式响应、Range 响应）                                                                | `Gzip_Config`           |
| `middleware_no_buffer`                   | `X-Accel-Buffering: no` + `no-transform`，阻止代理缓冲流式响应                                                          | —                       |

三种认证都会把认证主体写到 `req.principal`（`request_principal(req)` 读取），  
`middleware_logger` 的日志行里带 `user=`，401 与 200 都能追到同一个令牌。

```odin
cors_cfg := middlewares.CORS_Config {
	origins           = []string{"https://admin.example"},
	allow_credentials = true,
	expose_headers    = "X-Total-Count",
}
web.router_use(&router, middlewares.middleware_request_id)     // 先：id 进日志
web.router_use(&router, middlewares.middleware_logger)
web.router_use(&router, middlewares.middleware_secure_headers)
web.router_use(&router, middlewares.middleware_cors, &cors_cfg) // 配置要活得比 server 长
```

顺序即执行顺序（`router_use` 追加）；跨切面的放前面，鉴权/路由相关的放后面，  
被拒的请求也还能有 id 和日志。`ud` 里的配置必须是包级变量或堆分配，别传栈上  
临时值。没有 recover 中间件——Odin 没有异常，断言失败直接结束进程，进程级  
容错交给 supervisor。

**按路由挂载**（`router_use_route`：同一套中间件，只护一条路由）

```odin
report := web.router_get(&router, "/report.csv", report_handler)
admin  := web.router_get(&router, "/admin", admin_handler)
submit := web.router_add(&router, web.Method.Post, "/submit", submit_handler)
web.router_use_route(report, middlewares.middleware_range, &range_cfg)     // Range + ETag
web.router_use_route(admin,  middlewares.middleware_basic_auth, &admin_cfg)
web.router_use_route(submit, middlewares.middleware_form, &form_cfg)
```

路由级链在全局链之后、handler 之前执行；中间件实现不用改（`router_next` 对  
`r == nil` 走请求上挂的链）。所以 `middleware_basic_auth` 既能在全局链里保护  
整个站点，也能只保护 `/admin`。

路由本身是堆分配的，路由表只存指针，所以 `router_add` 返回的 `^Route` 之后  
再注册多少条路由都不会失效——先注册整张表再统一挂中间件，或边注册边挂，都行。

**表单与上传**

```odin
// 单字段
name, ok := web.request_form_value(req, "name")
// 全部字段 / 上传文件
for p in web.request_form(req) { ... }
if f, ok := web.request_file(req, "avatar"); ok {
	// f.filename 已去掉路径成分，f.content_type 可能为空，f.data 是请求体的视图
}
```

`request_form` / `request_files` 自己也会惰性解析（默认限额），`middleware_form`  
只是把这一步提前，并让错误变成 400/413/415 而不是空结果。

**上传落盘**（文件不进内存：解析后直接写磁盘，handler 拿到路径）

```odin
up_cfg := middlewares.Upload_Config { dir = "./uploads", max_file_bytes = 4 << 20, max_files = 4 }
web.router_use_route(upload_route, middlewares.middleware_upload, &up_cfg)

upload_handler :: proc(req: ^web.Request, res: ^web.Response) {
	for u in middlewares.request_uploads(req) {
		// u.field / u.original / u.path / u.size / u.content_type
	}
	if u, ok := middlewares.request_upload(req, "doc"); ok { ... }
}
```

存储名是「时间戳 + 消毒后的原文件名」，原始名只在 `original` 里用于展示；  
非 multipart 正文直接放行给下一个中间件或 handler。

**Range + ETag（普通 handler 也能 206/304）**

```odin
range_cfg := web.Range_Config{etag = true}
web.router_use_route(report, middlewares.middleware_range, &range_cfg)

report_handler :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_write_string(res, csv)   // 照常写完整正文
}
```

中间件在 handler 之后按请求头改写响应：单 range 切片 + 206 + `Content-Range`、  
不可满足 416 + `bytes */size`、多 range 忽略（回 200 全文）、`If-None-Match` 命中  
304。`sendfile`/chunked 响应自动跳过（前者已由 static 零拷贝处理，后者没有长度）。  
ETag 是正文的 FNV-1a 64 哈希，弱比较、跨重启稳定。

**SSE（服务端事件）**

```odin
events :: proc(req: ^web.Request, res: ^web.Response) {
	w, ok := web.sse_start(res)       // hijack + chunked 响应头
	if !ok { return }
	defer web.sse_close(&w)          // 写终止块并关连接，幂等
	_ = web.sse_retry(&w, 2000)      // 客户端断线后 2s 重连
	for i in 0..<10 {
		if !web.sse_event(&w, "tick", "tick", "1") { return }  // false = 对端已断
	}
}
```

`data` 里的换行会自动拆成多行 `data:`；`sse_comment` 兼作 keep-alive（客户端  
忽略 `:` 行，但代理不会因空闲断开）。代价要说清：handler 跑在事件循环线程上，  
一条 SSE 流会占住那条线程直到结束——少量仪表盘没问题，公开广播流请用  
`server_run_multi` 让其它线程继续服务，或另起专门的流服务。

**会话（签名 Cookie）**

```odin
session_cfg := middlewares.Session_Config { name = "sid", secret = SECRET, max_age_secs = 3600 }
web.router_use_route(login_route, middlewares.middleware_session, &session_cfg)

login :: proc(req: ^web.Request, res: ^web.Response) {
	middlewares.session_set(req, "user", "ada")        // 值会被复制进请求 arena
}
me :: proc(req: ^web.Request, res: ^web.Response) {
	user, ok := middlewares.session_get(req, "user")   // 读不到 = 新访客
	_ = middlewares.session_id(req)                    // 日志/关联用
	// middlewares.session_destroy(req, res, &session_cfg)  // 登出：清值 + 过期 Cookie
}
```

服务端不存任何东西：状态全部装在一个 HMAC-SHA256 签名 Cookie 里，因此多  
acceptor 线程无需共享状态、重启不会把人踢下线、也没有东西需要清扫。代价要  
说清：载荷是 base64，可被持有者读（防篡改、不保密，别放密钥）；登出只是  
「不再发这个 Cookie」，之前被拿走的 Cookie 到过期前仍然有效，所以 `max_age`  
别设太长，需要真正吊销的东西放你自己的库里。

`secret` 为空时中间件整条直通（配置来自没设的环境变量也不会退化成「空密钥  
签名 → 任何 Cookie 都通过」，这是 fail-closed 方向）。Cookie 写在 handler  
返回之后，且**只在会话被改过时才写**，所以只读请求一次验签、零写入。

**JWT（HS256）**

```odin
jwt_cfg := middlewares.Jwt_Config { secret = SECRET, issuer = "api", audience = "web" }
web.router_use_route(profile_route, middlewares.middleware_jwt, &jwt_cfg)

// 签发（登录端点）：exp 由调用方负责，不带 exp 的令牌永久有效
claims := middlewares.Jwt_Claims{sub = "service-a", exp = time.time_to_unix(time.now()) + 3600}
tok, ok := middlewares.jwt_sign(claims, SECRET)

// 校验：middleware_jwt 已做过，handler 直接用 req.principal（= sub）
```

先查 `alg` 再验签（`alg: none` 与空 alg 直接拒），然后按顺序核对签名、  
`exp` / `nbf`（带 `leeway_secs` 时钟容差）、`issuer` / `audience`。被拒的请求  
回 401 + `WWW-Authenticate: Bearer realm="api", error="invalid_token"`。  
会话用于浏览器登录，JWT 用于服务间调用与短时效 API 访问——它一旦签发出去  
就收不回来，声明也会过期。

**静态挂载（挂到一条路由上，而不是接管整个服务）**

```odin
files: web.Static
web.static_init(&files, "./examples/webapp/www")
mount := middlewares.Static_Mount_Config{st = &files, prefix = "/assets"}
assets := web.router_all(&router, "/assets/*", web.router_fallthrough_not_found)
web.router_use_route(assets, middlewares.middleware_static, &mount)
// spa = true 时未命中的路径渲染 index.html（单页应用的客户端路由）
```

命中才 serve，未命中继续走链（回落由 `router_fallthrough_not_found` 决定）。  
真正的发送仍然走父包的 `static_serve_root`，所以 stat 缓存、`sendfile`、  
Range、`Last-Modified`/304 全都一样；中间件只决定「要不要发」和「发哪个路径」  
（`prefix` 先剥掉）。判定用缓存的 stat，一次回落只花一次缓存查询，不是一次  
失败的 open。

**重定向与内部重写**

```odin
// 真发 3xx：客户端要再请求一次，地址栏会变，搜索引擎/书签会跟着走
redir_cfg := middlewares.Redirect_Config {
	rules = []middlewares.Redirect_Rule{
		{from = "/old",  to = "/",          exact = true},
		{from = "/docs", to = "/assets/"},              // 前缀，拼后缀且不留双斜杠
	},                                                   // code 默认 308（方法保持）
}
web.router_use(&router, middlewares.middleware_redirect, &redir_cfg)

// 内部重写：路由表之前改写路径，不发响应，客户端看不出来
web.router_rewrite(&router, "/intro", "/", true)
web.router_rewrite(&router, "/static", "/assets")     // 前缀版，按段边界匹配
```

规则按注册顺序取第一条命中，所以具体路径要写在泛前缀前面。绝对 URL 目标  
（`https://...`）原样使用，不拼后缀。

**gzip 开关（按路由）**

```odin
gz := middlewares.Gzip_Config{min_size = 256}   // 只改这一条路由的阈值
web.router_use_route(big_route, middlewares.middleware_gzip, &gz)
web.router_use_route(img_route, middlewares.middleware_no_gzip, nil)
```

压缩本身由父包内置且默认注册的 `Compress_Filter` 做（按 `Accept-Encoding`  
协商、只压可压缩类型、自动加 `Vary: Accept-Encoding`、压缩后不比原文小就发  
原文）。中间件只是给这条响应设「压 / 不压 / 阈值」：`no_gzip` 用在已压缩的  
资源、流式响应和 Range 响应（字节偏移指的是原文）上。handler 记得设  
`Content-Type`——没有类型的正文会被协商逻辑跳过。

**Static**

```odin
files: web.Static
web.static_init(&files, "./www")
srv.user_ptr = &files
srv.handler = web.static_serve
```

**Hijack / 流式**（SSE、长轮询：响应跨请求，只能把 socket 接管过来）

```odin
sock, ok := web.response_hijack(res)   // 之后 server 不再管这条连接，由调用方关
if ok {
	_ = net.set_blocking(sock, true)
	// content_length = -1：无长度、close 分帧（自己带 Connection 头则不覆盖）
	web.stream_write_head(sock, .OK, []web.Header{{"Content-Type", "text/event-stream"}}, -1)
	for {
		if !web.stream_write(sock, frame) { break }   // false = 对端已断
		if web.stream_peer_closed(sock) { break }     // 空闲期探测断开
	}
}
```

SSE 不必手写这些：`sse_start` / `sse_event` / `sse_comment` / `sse_retry` /  
`sse_close` 已经在 hijack 之上做好 chunked 分帧与响应头（见上一节）。

**异步响应**（handler 不能在一次调用里给出答案时）

```odin
front :: proc(req: ^web.Request, res: ^web.Response) {
	web.response_set_content_type(res, "text/plain")
	// 停在这里：handler 返回后连接进 Async 态，循环线程立刻去服务别的连接
	web.response_defer(res, on_wake, req, 5 * time.Second) // 5s 后超时兜底
}

on_wake :: proc(req: ^web.Request, res: ^web.Response, ud: rawptr, why: web.Async_Reason) {
	if why == .Timeout {
		web.response_text(res, .Gateway_Timeout, "still working\n")
		return
	}
	web.response_text(res, .OK, "done\n")
}

// 生产者在事件循环线程上唤醒它（队列在 on_tick 里排空，见下）
web.request_resume(req)
```

- 续延里照常 `response_write_string`/`response_json`，收尾走与同步响应**同一条**  
  路径（`conn_process_tail`）：头协商、filter、序列化都不分叉
- 续延可以再 `response_defer` 一次，这就是「多事件状态机」的写法
- `on_close` 回调（`response_defer` 第 5 个参数）在连接关闭时恰好跑一次，用来把  
  自己从订阅表里摘掉
- **不提供**跨 OS 线程的 `request_resume`：库内一切都在一个事件循环线程上，  
  别的线程要先把活交给循环（比如 `on_tick` 里排空自己的队列）再唤醒。规则写死  
  在文档里，而不是藏在读代码才能发现的 mutex 后面

**Hub**（SSE 广播：万人订阅不是一个订阅者一个线程）

```odin
hub: web.Hub
web.hub_init(&hub)            // 默认每订阅者 64 KB 队列、15 s keep-alive
defer web.hub_destroy(&hub)

events :: proc(req: ^web.Request, res: ^web.Response) {
	web.hub_subscribe(&hub, req, res)   // 设好 SSE 头 + chunked，然后返回
}

// 任意时刻、在循环线程上：一次成帧，广播给所有订阅者
web.hub_publish(&hub, "chat", `{"user":"ada"}`, id)
web.hub_tick(&hub)            // 在 on_tick 里调：发 keep-alive 注解
web.hub_close(&hub)           // 优雅结束所有流（发 0 长度块）
```

单个订阅者队列满时**丢给它的消息**（`Hub_Stats.skipped` 计数），而不是让发布者  
卡住——慢客户端不该拖累其他人。

**流式上传**（大文件不进军内存）

```odin
upload_cfg := web.Upload_Sink_Config {
	dir       = "./uploads",   // 空 = 系统临时目录
	threshold = 256 << 10,     // 每个 part 内存里留多少，超了写盘
	max_part_size = 512 << 20,
}

// 请求体读之前接管它：只看 multipart，其它请求原样放过
srv.on_head = proc(s: ^web.Server, c: ^web.Conn, ud: rawptr) -> bool {
	#partial switch web.upload_sink_attach(c, upload_cfg) {
	case .None, .Not_A_Form:
		return true
	case:
		web.response_error_for_conn(c, .Payload_Too_Large)
		return false
	}
}

handler :: proc(req: ^web.Request, res: ^web.Response) {
	f, ok := web.request_file(req, "doc")   // 与内存路径同一个 API
	// f.path 是临时文件（请求结束自动删），f.data 为空；小 part 反过来
}
```

- 临时文件名自己生成（时间+pid+序号+消毒后的原名），客户端的名字只用于展示
- 请求结束（keep-alive 复位或 `conn_close`）由 sink 的 `teardown` 清理；被  
  `os.rename` 移走的文件自然就「被收养」了
- 只对流式路径放开 `max_body_size`：它本来是个内存上限，而流式路径的内存由  
  `threshold` 决定，大小上限由 `max_part_size` 决定

**Proxy**（反向代理）

```odin
proxy: web.Proxy
web.proxy_init(&proxy, {"127.0.0.1:9000", "127.0.0.1:9001"}) // 平滑加权轮询
proxy.strip_prefix = "/api"   // 客户端 /api/x -> 上游 /x
proxy.timeout = 10 * time.Second
proxy.keep_alive = true       // 上游连接池（默认开）
proxy.max_idle_per_host = 16  // 每上游最多闲置连接数
proxy.idle_timeout = 30 * time.Second
web.proxy_set_weight(&proxy, 0, 3)   // 3:1 分流；权重只影响比例，不饿死小上游

// 健康检查：2 s 探测一轮；连续 5 次失败摘除 5 s，之后翻倍、上限 60 s
proxy.health.probe_interval = 2 * time.Second
srv.user_ptr = &proxy
srv.on_tick = proc(s: ^web.Server) {
	web.proxy_health_poll(cast(^web.Proxy) s.user_ptr) // TCP 连通性探测
}

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
- **健康检查**：被动（请求路径上的失败累计）+ 主动（`proxy_health_poll` 在  
  `on_tick` 里跑 TCP 连通性探测）。连续 `max_failures` 次失败摘除，退避  
  翻倍到 `max_eject` 封顶，窗口到期进半开——探测成功才回到轮转，失败续摘。  
  **全摘除时 fail-open**：挑最早恢复的那台上，而不是自己造一个 503
- **权重**：`proxy_set_weight` 设 0 即摘出轮转；平滑加权轮询保证 3:1 的  
  比例在每 4 次请求内兑现，小权重上游不会被大权重饿死

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
- **会话复用**默认开（`TLS_RESUMPTION_DEFAULT`）：`SSL_CTX` 级 session cache  
  + TLS 1.3 ticket。`stats.tls_handshakes` / `stats.tls_resumed` 可直接算复用率；  
  `session_id_context` 由证书路径派生，进程重启后仍能命中旧会话。要关就传  
  `web.TLS_RESUMPTION_OFF`。注意 TLS 1.3 的 `NewSessionTicket` 是**握手后**  
  记录：握手计数在 ticket 之前就 +1，客户端也要等一等才拿得到可复用会话

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

| 字段                      | 默认     | 说明                         |
| ----------------------- | ------ | -------------------------- |
| `keep_alive`            | `true` | HTTP/1.1 默认长连接             |
| `max_requests_per_conn` | 1000   | 达到后响应带 `Connection: close` |
| `max_header_size`       | 16 KB  | 超出 431                     |
| `max_body_size`         | 10 MB  | 超出 413（装了 body sink 时改由 sink 判） |
| `max_conns`             | 1024   | 超出拒绝新连接                    |
| `header_timeout`        | 30 s   | 收齐一个请求头的上限                 |
| `write_timeout`         | 30 s   | 单次写操作上限                    |
| `idle_timeout`          | 5 s    | keep-alive 空闲上限            |

**连接事件**：`srv.on_conn_open` / `srv.on_conn_close`，签名  
`proc(s: ^Server, c: ^Conn)`。

## 测试覆盖

```bash
odin test web/               # 146 个
odin test web/middlewares     # 48 个
```

`web` 侧是 parser / chunked / router（含重写）/ response 序列化 /  
proxy 解析与分帧决策 / cookie 序列化与解析 / JSON / Lua 模式匹配（22 组模式  
用例）/ Range 解析（14 组语法用例）/ HTTP-date 解析 / If-Range / 严格分帧  
（15 组用例）/ CRC32 与 deflate-gzip 往返 / 可压缩类型判定 / 平滑加权轮询与  
熔断状态机（摘除窗口倍增与封顶）/ 增量 multipart 解析（**同一正文按 1..N 字节  
窗口逐个喂进去结果必须一致**，覆盖分隔符跨界、正文内含分隔符前缀、空 part、  
无尾 CRLF、多 part 顺序与 index/size、前导与后置垃圾、分隔行尾判定与 transport  
padding）/ 流式解析内存上界 / 文件名消毒 单测，加 30 多个真实起服务的集成测试  
（请求响应闭环 + body 回显、畸形请求 400、chunked 请求体、pipelined 双请求、  
24 深度流水线合并写且响应顺序不乱、流水线中间夹带 body 的请求、流水中途出现  
坏请求时前面已合并的响应不丢、  
HEAD、空文件 sendfile、代理 GET/POST、chunked 上游中继、close-delimited 上游  
重分帧、上游拒连 502、Cookie、JSON、模式路由、静态 Range 全路径：单 range 206  
/ 多 range multipart / 416 / 304 / If-Range、gzip 内容协商与 chunked 组合、  
代理流式早发 / 失效池重试 / 池命中计数 / 健康探测、3 acceptor 共享端口、TLS  
配置 / GET / keep-alive / 200 KiB 静态文件逐字节比对 / ticket 签发 / 关闭复用 /  
session id context 稳定性、SSE 事件流、Hub 广播与优雅关闭 / 多行事件成帧 /  
背压丢消息与恢复 / keep-alive 心跳、延迟响应的超时续延与唤醒 / 二段续延 /  
重复停车被拒 / 超时后迟到唤醒、流式上传落盘 / 阈值内不落盘 / 两个文件各归其位 /  
chunked 正文 / 超限 413（part 与字段）/ keep_temp / 非 multipart 不受影响 /  
临时文件在请求结束（含 keep-alive）即清理）。

`web/middlewares` 侧是 Basic/Bearer/API-Key 认证（含 challenge 文案与  
principal 传递）、表单 urlencoded/multipart/限额/415/400/413、Range 中间件的  
206/416/ETag/304/If-Range/跳过文件响应、路由级中间件隔离、会话的往返与  
伪造 Cookie 拒绝 / 过期 / 栈缓冲值被复制、JWT 的签发与验签（错误 alg、  
错密钥、过期、错 iss/aud）、静态挂载的命中 / 回落 / 前缀剥离 / SPA、  
重定向的状态码与 Location（含双斜杠）、上传的文件名消毒与限额 / 流式 part  
的改名交接（rename 即所有权转移）。  
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
