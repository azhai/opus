# web 库调研与设计文档

本文记录 `web` 包（Odin 语言的 HTTP/1.1 基础服务库）的调研结论、设计取舍与实现要点。  
代码本身即最终文档（`doc.odin` 是包级文档），本文解释**为什么这样设计**。

---

## 1. 调研对象与借鉴矩阵

| 来源                     | 学什么                                                            | 不学什么                                               |
| ---------------------- | -------------------------------------------------------------- | -------------------------------------------------- |
| **lighttpd2**          | 分层架构：连接级/请求级双层状态机、filter 输出管线、action 组合、stat 缓存                | 配置语言（angel/condition 的 Lua 式求值）、插件动态加载、worker 进程模型 |
| **Mongoose** (cesanta) | API 手感：一个 `Server` + 一个 `handler` + `user_ptr`；事件循环对用户透明；单包零依赖 | 自带 TLS/协议栈全家桶、`mg_mgr` 的手写 poller（我们有 `core:nbio`） |
| **odin-http**          | Odin 社区对 `Server`/`Request`/`Response` 的命名习惯                   | 其同步阻塞式 accept 循环（我们要事件驱动）                          |
| **core:nbio**          | 事件循环本体：io_uring/kqueue/IOCP 统一抽象、`*_poly` 系列操作                 | 不需要"学"——直接用                                        |

### 1.1 lighttpd2：抄骨架

lighttpd2 最值得抄的是**连接状态机与请求解析的分离**：

```
Conn_State:  Read_Head → Read_Body → Process → Write → Read_Head → ...
```

- 外层是连接级状态机（`web/conn.odin` 的 `Conn_State`），驱动 keep-alive 与 pipelining；
- 内层是请求级解析（`parse_request` + chunked 解码器），只关心"字节流 → 请求结构"。

两层分离后，管道化（pipelining）自然成立：一次 `conn_drive` 循环里  
`Read_Head → Process → Write` 走完，`inbuf` 里若还有下一个请求的字节，  
直接继续 `drive`，不需要任何额外机制。

**抄**：

- 双层状态机
- filter 管线思想（响应写出前经过一条 `Filter` 链，chunked 编码是内置 filter）
- stat 缓存（`Static` 的 TTL 缓存 + 负缓存）

**不抄**：

- 条件求值器（condition evaluation）：那是为配置文件服务的。Odin 宿主语言本身就是  
  最好的求值器——路由匹配、鉴权判断直接用 Odin 代码写，即"action stack 的编译期版本"。
- worker 进程/angel 进程模型：多进程部署交给 supervisor（如 gorch），库内只做单线程事件循环。

### 1.2 Mongoose：抄皮肤

Mongoose 的成功一半在 API：

```c
struct mg_mgr mgr;
mg_mgr_init(&mgr);
mg_http_listen(&mgr, "http://0.0.0.0:8000", fn, &data);
for (;;) mg_mgr_poll(&mgr, 1000);
```

`web` 包的对应物：

```odin
srv: web.Server
web.server_init(&srv, "0.0.0.0:8080")
srv.handler = my_handler
web.server_run(&srv)
```

集成表面只有一个 `server_run`，`Server.user_ptr` 携带用户状态（router、static root）。  
事件循环、连接管理、超时全部藏在库里。

**抄**：`Server` + `handler: proc(req, res)` + `user_ptr` 三件套；  
连接生命周期回调（`on_conn_open`/`on_conn_close`）对应 Mongoose 的 event 位。

**不抄**：Mongoose 把 TLS、WebSocket、MQTT 全塞进一个 `mg_mgr`。`web` 只做 HTTP/1.1，  
TLS 明确留给未来以 filter 形式挂接。

### 1.3 core:nbio：站在巨人肩膀上

`core:nbio` 已经提供：

- 每线程事件循环：`acquire_thread_event_loop` / `tick` / `run` / `run_until`
- 统一 `^Operation` + 单回调类型 `proc(op: ^Operation)`
- `*_poly` 系列：`recv_poly`/`send_poly`/`accept_poly`/`sendfile_poly`/`timeout_poly`/`close_poly`，  
  把类型安全的用户数据直接绑到操作上，**不需要手写 user_data 联合体和分发 switch**
- 平台后端：Linux io_uring / Darwin kqueue / Windows IOCP

这意味着 `web` 不需要写一行 epoll/kqueue 代码。自研 poller（Mongoose 路线）在 2026 年  
没有意义。

`*_poly` 的多态回调是本次设计的关键使能器：`Conn` 的每个异步操作（recv/send/sendfile/  
socket close）都能直接把 `^Conn` 传进回调，省掉了 C 风格 `void *user_data` + 强制转换 +  
手动生命周期管理。

### 1.4 odin-http：功能覆盖对比

odin-http（laytan/odin-http，MIT）是 Odin 社区最完整的 HTTP/1.1 实现，**服务端 +  
客户端双端**（客户端在独立 `client` 子包，HTTPS 靠 OpenSSL）。它自我定位是  
"not intended for production use" 的 beta / Odin core 收录前 PoC。逐项对比  
（2026-10 现状）：

| 能力                           | odin-http                                                    | web（本库）                                                   | 说明                                                         |
| ---------------------------- | ------------------------------------------------------------ | --------------------------------------------------------- | ---------------------------------------------------------- |
| HTTP/1.1 服务端                 | ✅ `listen_and_serve` + Router                                | ✅ `Server` + `Handler`                                    | 我们都覆盖；odin-http 用 Lua 模式路由（`%w+`/`%d+` 类），我们用 `:param`/`*` |
| keep-alive / pipelining      | ✅                                                            | ✅                                                         | 本库显式支持单连接多请求管道化（集成测试覆盖）                                    |
| 请求体 Content-Length + chunked | ✅（`http.body` 回调式读取，`Body_Error` → `body_error_status`）      | ✅（增量解码 + 413 上限）                                          | 读取模型不同：odin-http 流式回调，本库缓冲到 `req.body` 后给 handler          |
| 响应构建 / 静态文件                  | ✅ `respond_plain/json/html`、`respond_file`、`respond_dir`     | ✅ `response_*` + `Static`（TTL stat 缓存、sendfile 零拷贝）       | 静态文件本库更强（缓存 + 零拷贝）；odin-http 强在便捷助手多                       |
| Cookie                       | ✅ `res.cookies`，`Cookie{same_site, http_only, max_age_secs}` | ✅ `response_set_cookie`/`request_cookie`，全属性              | Set-Cookie 不折叠（每个 cookie 一行头）；请求侧零拷贝扫描                     |
| JSON 响应助手                    | ✅ `respond_json`                                             | ✅ `response_json`（`core:encoding/json`）                   | 任意 Odin 值 → body + Content-Type；marshal 失败转 500            |
| 路由模式                         | ✅ Lua 模式（正则子集）                                               | ✅ Lua 模式子集（回溯 VM）                                         | 类/集合/量词/捕获组/惰性全支持，捕获经 `request_capture` 按位次取               |
| 中间件                          | ⬜ handler 可包装 route                                          | ✅ 显式中间件链（`router_next` 索引续链）                              | 本库原生支持                                                     |
| Filter 输出管线 / chunked 响应编码   | ❌                                                            | ✅（`Filter` 链，`server_listen` 自动注册 chunked + gzip/deflate） | lighttpd2 式管线，odin-http 无对应概念                              |
| 反向代理                         | ❌                                                            | ✅ round-robin + 前缀剥离 + 流式中继 + 上游连接池                       | v0.4 起边收边转发                                                |
| TLS                          | ⬜ 仅客户端 HTTPS（OpenSSL，链接期依赖）                                  | ✅ 服务端 TLS（`core:dynlib` 运行时加载 OpenSSL）                    | 本库握手挂在连接状态机上，handler 无感                                    |
| 多 acceptor                   | ❌                                                            | ✅ `server_run_multi` + `SO_REUSEPORT`                     | 每线程独立事件循环，库内无锁                                             |
| HTTP 客户端                     | ✅ `client.get/request` + 连接池 + cookie                        | ❌                                                         | odin-http 独有；本库定位纯服务端                                      |
| 优雅停机                         | ✅ `server_shutdown_on_interrupt`（信号）                         | ✅ `server_run_until` + drain + `on_stop`                  | 本库是程序化的，不绑信号                                               |
| 多档超时 / 连接上限                  | ⬜                                                            | ✅ header/idle/write 超时 + `max_conns`                      | 生产向细节                                                      |
| 定位                           | beta / PoC，明示勿上生产                                            | 按 lighttpd2 骨架设计，目标生产可用                                   | 61 测试零泄漏                                                   |

**结论：服务端核心能力（协议解析、keep-alive、请求体、路由、Cookie、JSON  
响应助手、静态文件、TLS、反向代理、多线程扩展）已全覆盖，并在 filter 管线、  
中间件链、stat 缓存 + sendfile、流式代理 + 连接池、多档超时、连接上限等  
生产向细节上超出；剩余缺口只有 HTTP 客户端。**

---

## 2. 架构分层

```
┌─────────────────────────────────────────────────────┐
│ 用户代码：Handler / Router / Middleware / Static /    │  ← Mongoose 式 API
│           Proxy                                      │
├─────────────────────────────────────────────────────┤
│ server.odin    Server：listen/accept/sweep/run       │  ← 生命周期与配置
│ threads.odin   多 acceptor：server_run_multi / on_stop│
│ router.odin    Router：段式 + Lua 模式匹配 + 中间件链    │  ← lighttpd2 action 思想的
│                + 内部重写（路由表之前改路径）           │     宿主语言实现
│ middleware/    中间件子包（import ".."）：               │
│   middleware   id/日志/CORS/限额/安全头/禁缓存/反缓冲    │
│   auth         Basic / Bearer / API-Key                │
│   range        Range/ETag（handler 无感）               │
│   form         middleware_form（解析留在父包）          │
│   gzip         middleware_gzip / _no_gzip               │
│   session      签名 Cookie 会话                         │
│   jwt          HS256 校验与签发                         │
│   static       目录树挂载（可 SPA 回落）                │
│   redirect     规则重定向 / https 重定向                 │
│   upload       multipart 落盘（可流式，见 upload.odin）  │
│   token        base64url + HMAC-SHA256 原语             │
│ static.odin    Static：stat 缓存 + sendfile           │
│ proxy.odin     Proxy：流式中继 + 上游连接池            │
│ proxy_health.odin  权重 / 摘除 / 半开探测 / fail-open  │
│ async.odin     延迟响应：response_defer / request_resume│
│ hub.odin       SSE 广播：每订阅者一个结构体 + 有界队列   │
│ cookie.odin    Cookie：Set-Cookie 序列化 / 请求解析   │
│ json.odin      response_json（core:encoding/json）   │
├─────────────────────────────────────────────────────┤
│ conn.odin      Conn：双层状态机 + 每连接 arena + body  │  ← lighttpd2 骨架
│                sink（正文边收边交出去）                 │
│ request.odin   parse_request：零拷贝 header 视图        │
│ response.odin  response_build：序列化 + sendfile 切换  │
│ filter.odin    Filter 链 + chunked 编解码（可流式交出） │
│ multipart_stream.odin  增量 multipart 解析            │
│ upload.odin    Upload_Sink：part 写临时文件 + 清理     │
│ compress.odin  gzip/deflate 编码器 + 内容协商          │
│ tls.odin       TLS：OpenSSL 运行时加载 + memory BIO    │
│ sse.odin       SSE：chunked 帧 + 事件/注释/重连        │
│ stream.odin    hijack 后的裸 socket 写辅助             │
│ socket_*.odin  SO_REUSEPORT / listen（posix/windows）  │
├─────────────────────────────────────────────────────┤
│ buffer.odin    Buf + 工具函数                          │
│ http.odin      Method/Status/Header/mime/date          │
├─────────────────────────────────────────────────────┤
│ core:nbio      io_uring / kqueue / IOCP                │  ← 事件循环
└─────────────────────────────────────────────────────┘
```

### 2.1 内存模型：每连接一个 arena

`Conn` 持有一个 `mem.Dynamic_Arena`。所有每请求的临时内存——

- head 的 clone（`clone_string`）
- header 表（`parse_request` 的 `[dynamic]Header`）
- URL 解码后的 path
- 请求 body 的 clone、chunked 解码暂存
- 响应 body、header 表、`int_to_string` 等序列化中间产物

——全部从 arena 分配。keep-alive 连接处理完一个请求后  
`dynamic_arena_reset` **一次性全部释放**（`conn_request_reset`）。

这直接抄自 Odin 自己的 arena 哲学（也是 lighttpd2 per-connection 内存池思想的  
Odin 原生版）。收益：

1. 请求路径上零 `free` 调用；
2. 不可能出现"响应还没写出 body 就被请求处理释放了"这类跨请求 UAF；
3. 峰值内存 = 单连接单请求峰值，与连接数、请求数无关。

注意 `conn_request_reset` **不重置 `inbuf`**——管道化场景下它可能已持有下一个  
请求的字节，由后续的 head/body 解析器消费。

### 2.2 零拷贝

- header 值：`parse_request` 的切片直接指向 head clone 缓冲区，不复制；
- 静态文件：`response_send_file` 后 body 走 `nbio.sendfile_poly`，用户态零拷贝  
  （Linux 上是真正的 `sendfile(2)`，io_uring 的 `sendfile` 变体）。

### 2.3 非阻塞写与背压

`nbio.send_poly(all = true)` 保证"要么全部发出、要么报错"，配合 `write_timeout`。  
响应头先入 `c.out`，文件体在头写完后切到 sendfile 阶段（`on_sent` → `Send_Phase.File`），  
两阶段提交。

---

## 3. 关键设计决策记录

| 决策                                         | 理由                                                                                                                                                                                                                                                                    |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 用 `core:nbio` 而非手写 epoll/kqueue            | nbio 统一了三平台后端，`*_poly` 回调省去 user_data 机制；重复造 poller 无收益                                                                                                                                                                                                               |
| 路由两遍扫描                                     | 先 method+path 精确匹配；第二遍 path-only 返回 `method_ok=false` 供 405 回答。比"单遍记录首个 path 匹配"更简单且行为正确                                                                                                                                                                              |
| 中间件用显式 `idx` 而非闭包                          | Odin 过程是第一类值但闭包捕获写起来啰嗦；`router_next(r, idx+1, final, ...)` 显式续链，零捕获、零分配                                                                                                                                                                                               |
| `path_match` 中 `*` 通配检查置于 query 分离之前       | 否则 `/*` 无法匹配 `/`（"/" 的 qs 边界判断会先失败）                                                                                                                                                                                                                                   |
| HEAD 也发 `Content-Length`                   | RFC 7231 §4.3.2：HEAD 响应携带 GET 会有的长度，只是不带 body                                                                                                                                                                                                                         |
| 0 字节文件：关闭 handle 发 `Content-Length: 0`     | 避免对空文件发起 sendfile(0) 的边界情况                                                                                                                                                                                                                                            |
| chunked filter 在 `server_listen` 自动注册      | handler 只需 `res.chunked = true`，不该被迫知道 filter 注册机制；chunked 编码是 HTTP 基础能力不是可选插件                                                                                                                                                                                        |
| 代理复用上游 keep-alive 连接（池化）                   | 每请求一次 TCP（+TLS）握手在反代场景是主要开销；池按上游维度、闲置上限 16 条 / 30 s，取到失效连接时对幂等方法在「尚未向客户端发字节」前提下重拨一次，兼顾吞吐与正确性。socket 归事件循环所有，故关停由 `Server.on_stop` 在循环线程上 `proxy_close_idle` 释放，`proxy_destroy` 只放内存                                                                                   |
| 代理边收边转发而非整响应缓冲                             | head 一到就下发、body 按帧流式中继，内存与响应大小无关；代价是需要显式维护分帧状态（CL 计数 / 增量 chunked 扫描 / close-delimited 重分帧），以及「同一时刻只有一个方向在途」的不变式来保证缓冲有界                                                                                                                                               |
| chunked 上游响应**透传分帧**而非解码重编码                | 避免二次拷贝，且天然支持 `TE: gzip, chunked` 等复合 codings；完整性判定用增量扫描器 `Chunk_Scan`（Size/Size_CR/Data/Data_CR/Data_LF/Trailer 七态，trailer 用 4 态区分空行与行尾 CR），不会被 payload 里的假终止序列骗到                                                                                                     |
| close-delimited 上游响应重分帧为 chunked           | 流式路径不必缓冲到 EOF，客户端 keep-alive 也不被破坏；HTTP/1.0 客户端无法解析 chunked，退回「以关闭连接结束」（`Raw_To_Close`）                                                                                                                                                                               |
| TLS 用 `core:dynlib` 运行时加载 OpenSSL          | 库本身保持「零构建期依赖」：没有 openssl 的系统照样能编译，只是不能用 TLS。握手/读写/关闭全挂在既有连接状态机的一个阶段上，handler 完全无感；TLS 下 `sendfile` 退化为 64 KiB 分块 read→encrypt→send                                                                                                                                    |
| 多 acceptor 用 `SO_REUSEPORT` + 每线程 `Server` | `core:nbio` 是每线程事件循环，天然适合 N 个 loop；库内不加锁、不共享连接表。`SO_REUSEPORT` 是唯一能让内核把连接分发到多个 listener 的机制，因此在 `server_open_listener` 里手写 socket+bind+listen（`nbio.listen_tcp` 没暴露该选项）                                                                                               |
| `SO_REUSEPORT` 失败即拒绝监听                     | 静默降级成单 listener 会让「多线程」变成假象，不如启动即报错                                                                                                                                                                                                                                   |
| 未知上游状态码（599 等）连 reason phrase 透传           | `Status` 枚举只是常用子集；`Response.reason` 覆盖字段 + 整数→枚举强转实现完整透传                                                                                                                                                                                                              |
| 请求分帧按 RFC 7230 §3.3.3 严格判定                 | TE+CL 同现、非 chunked 结尾的 TE、冲突/列表型 CL 都是请求走私向量，静默取其一（旧行为 TE 优先）等于替攻击者做选择；直接 400，与 nginx/lighttpd 一致。相同规则应用到上游响应头解析，违规代理回 502 而非中继                                                                                                                                       |
| `nbio.Handle`(FD) 不可赋 nil                  | Odin distinct 整数类型语义；用 `file_open: bool` 标志表示"持有有效 handle"                                                                                                                                                                                                            |
| socket 异步关闭，`Conn` 在 close 回调里 free        | `nbio.close_poly(socket, c, on_socket_closed)`：先 `nbio.remove(c.op)` 撤销在途操作防 UAF，关闭完成回调里 `free(c)`                                                                                                                                                                    |
| `server_run_until` 优雅 drain                | 撤销 accept/sweep 操作后 tick 到 `nbio.num_waiting() == 0`，让在途关闭回调跑完，测试零泄漏                                                                                                                                                                                                  |
| 编译期 debug 开关                               | `WEB_DEBUG :: #config(WEB_DEBUG, false)`，`-define:WEB_DEBUG=true` 打开 `log_debug`；release 构建零开销                                                                                                                                                                        |
| 模式路由用回溯 VM 而非直接递归                          | 首版直接递归匹配器在 `(.-)%.html` 上暴露"组体不回溯"缺陷——惰性量词在组内、续链在组外，子级匹配看不见外层续链。编译成 Char/Split/Jmp/Save/Match 指令 + 捕获 undo 栈后，组体自然对外层续链回溯，且免费获得 Lua 的"量化组捕获保留最后一次重复"语义。指令数/步数/undo 均有上限（128/8192/256），路由模式远够                                                                          |
| 段式与模式路由共存                                  | 模式含 `(`/`%`/`[` 才进模式引擎，其余保持段式（`:param` + `*`）——`/v1.0/status` 里的字面点不会被当成任意字符；`*` 也不会和量词撞车                                                                                                                                                                             |
| Set-Cookie 不折叠                             | RFC 6265 多个 cookie 必须是多个头行；为此加 `response_add_header`（始终追加），`response_set_header` 仍是替换语义                                                                                                                                                                               |
| JSON 走 `core:encoding/json`                | Odin 核心库自带，无需自研序列化；marshal 在连接 scratch arena 上完成后立即拷入 response body，不延命                                                                                                                                                                                               |
| 测试起服务用栈上 arena 传 `router_match`            | 该过程用传入 allocator 建 params/captures 数组且不负责释放（正常路径由每连接 arena 重置代管）；单测里传 `context.allocator` 会泄漏，照旧例传 `mem.arena_allocator(&arena)`                                                                                                                                      |
| 压缩器状态从 `context.allocator` 分配              | 匹配表（hash head + prev）共 256 KiB，放栈上会撞穿测试线程的 arena（表现为 payload 第 0 字节就段错误）；`prev` 无需清零——只能经 `head` 项读到                                                                                                                                                                  |
| 内容编码先于传输编码                                 | filter 链顺序为 compress → chunked：先把 body 压缩（`Content-Encoding`），再由 chunked filter 分帧（`Transfer-Encoding`）。`sendfile` 文件体与不可压缩类型直接跳过压缩，保住零拷贝                                                                                                                             |
| 中间件分「通用」与「专用」，并且能按路由挂载                     | 全局链适合跨切面（id/日志/安全头），鉴权与正文解析往往只对一两条路由有意义——全局注册等于给所有路由加成本。做法：`Route.middlewares` 存路由级链，`router_handle` 命中后在全局链末端（`router_route_terminal`）把路由指针交给 `req.route`，`router_use_route` 追加；`router_next(nil, ...)` 表示「走请求上挂的链」，因此同一个 `Middleware_Proc` 既能服务全局链也能服务单路由链，中间件实现零改动 |
| 认证只做「令牌表 + 等时比较」，不做会话/用户库                  | Basic/Bearer/API-Key 覆盖的是服务间调用与单一管理凭据；引入用户表、密码哈希、会话存储是另一个产品（且会拖进持久化与迁移）。三种方案都写 `req.principal`，日志可归因；`WWW-Authenticate` 文案区分「没带凭据」与 `error="invalid_token"`（RFC 6750 §3）                                                                                              |
| `middleware_range` 放在 handler 之后改写响应       | Range/ETag 的正确性与「正文从哪来」无关，只与「正文是什么」有关：handler 照常写完整正文，中间件按 `Range` 切片、按内容哈希算 ETag。这样 CSV 导出、生成的 JSON、模板页都能白拿 206/304，而 `sendfile`/chunked 响应自动跳过（前者已零拷贝、后者没有长度）。ETag 用正文 FNV-1a 64 而非 mtime：生成型响应没有 mtime，且跨重启稳定                                                      |
| multipart 解析全内存，限额而非流式落盘                   | `Server.max_body_size` 已经给整包设上限，`MAX_FORM_FILE_SIZE` 再压单个 part；在这个量级（联系表单、头像、CSV 导入）流式落盘只增加复杂度。判定「文件」看 `filename` 参数而不是 Content-Type：浏览器给文本字段不发 Content-Type、给空文件框发 `filename=""`，按类型判定会把空文件变成字段                                                                      |
| SSE 走 hijack + chunked，而不是「chunked 普通响应」   | handler 是同步的，普通响应只有在 handler 返回后才能落盘，做不出「持续推送」。hijack 拿到底层 socket 后自己写 chunked 帧，客户端仍看到合法 HTTP/1.1 响应与干净的结束块（`0\r\n\r\n`），不必靠关连接表达结束。代价是那条事件循环线程被占用，缓解手段是多 acceptor 线程（v0.6 又给了「不用占线程」的答案：`response_defer` + `Hub`）                                                                      |
| TLS 会话复用只设 `SSL_CTX`，不碰 session 回调          | 复用是「上下文属性」而不是「连接属性」：`SSL_CTX_set_session_cache_mode` + ticket 数 + timeout 设一次，之后每条连接自动命中/自动发 ticket。要让 TLS 1.2 的 cache 真正生效必须调 `SSL_CTX_set_session_id_context`（不调则静默失效），值取证书路径的 FNV-1a——重启后同一张证书仍能命中。`SSL_CTX_ctrl` 的命令号在头文件里是宏（没有导出符号），只能硬编码 `42/44`                                                                                                                                     |
| 会话复用不去断言「客户端真的复用了」                          | TLS 1.3 的 `NewSessionTicket` 是**握手后**记录：`SSL_get1_session` 拿到的是 ticket 之前的会话（`SSL_SESSION_is_resumable` = 0），可复用的那个只经 `new_session_cb` 到达，且客户端 CTX 必须打开 `SSL_SESS_CACHE_CLIENT`。因此服务端契约只到「我发了 session」——测试统计签发数（`stats.tls_handshakes` + ticket 计数），重放依赖客户端配合，用 `openssl s_client -sess_out` 手工验证过 `Reused, TLSv1.3`                                                                                                                                     |
| 代理健康检查选「摘除 + 半开 + fail-open」而非「全挂 503」  | 熔断的责任是「别把请求送给已知坏掉的上游」，不是「替上游宕机下结论」。全摘除时挑最早恢复的那台（`time.diff` 方向要小心：`diff(a,b)` 是 `b-a`），比自造 503 更接近用户期望；被动失败（请求路径）+ 主动探测（`on_tick` 里 TCP 连通性）两条腿，因为「取到失效连接再重拨」只能发现已经坏了的                                                                                                                                     |
| 权重用 nginx 式平滑加权轮询                          | `current_weight += weight` 后取最大并减去总权重：3:1 的比例在每 4 次内兑现，且小权重上游不会被连续饿死（朴素权重轮询会）。`weight = 0` 等于「摘出轮转」但仍在 `upstreams` 里，便于运行期 `proxy_set_weight` 调回来                                                                                                                                     |
| 异步响应用「状态机 + 续延」而不是「再开一个线程」          | 一条长流占一条线程是线程模型的固有代价；把 handler 变成 `Async_Proc` 续延后，暂停的连接只是一个 `Async_State` 结构体。关键是**收尾不分叉**：续延跑完仍调用同步路径的 `conn_process_tail`，再重新进 `conn_drive` 把 `.Write` 推下去（忘了这一步的后果是响应体永远不发送）                                                                                                                                     |
| `request_resume` 明确不支持跨线程                  | 库内所有状态都在一个事件循环线程上，加锁等于把「谁来同步」的问题推给读者。规则写死：别的线程先把活交给循环（`on_tick` 里排空队列），再在循环线程上唤醒。代价是生产者要自己排一次队，好处是数据竞争在类型层面就不存在                                                                                                                                     |
| Hub 用「每订阅者有界队列 + 丢弃」而不是「阻塞发布者」        | 一个慢客户端不该让整个广播卡住。队列上限 64 KB，满了就丢给这一个人并计 `skipped`；keep-alive 注解让死活订阅者在 15 s 内暴露。发布时**倒序**遍历：一次 flush 可能关闭并 `unordered_remove` 订阅者，正序会跳过元素                                                                                                                                     |
| multipart 流式解析的保留规则：只留 `len(sep)-1` 字节      | 分隔符跨块是流式解析唯一真正难的地方。做法是每次喂完只保留可能是「分隔符前缀」的尾巴（长度不可能超过分隔符本身-1），其余全部可以先交出去——这样内存是 `一块 + 分隔符`，与 part 大小无关，且不需要 KMP：尾巴短到可以直接重扫                                                                                                                                     |
| 但 `\r\n--boundary` 还得看后面是什么                | 只按分隔符切会在 `\r\n--bndarincomplete` 这类正文上误判（`--bnd` 是边界的**前缀**，整行却不是分隔行），后果是先交出一半数据再报 malformed——比两种极端都糟。故候选命中后要看后续是 padding+CRLF 还是 `--`（RFC 2046），都不是就当正文继续往后找，字节不够就先等                                                                                                                                     |
| 上传落盘用通用 body sink，而不是在 multipart 里特判         | `Body_Sink`（write/finish/teardown 三个过程指针）把「正文去哪」从连接状态机里抽出来，`conn_try_body` 只需在装了 sink 时改喂数据、不攒缓冲。sink 活在连接 arena 上，`teardown` 由 `conn_close` 或 keep-alive 复位触发一次——临时文件的生死由此有唯一出口                                                                                                                                     |
| 装了 sink 就放开 `max_body_size`                | 那个上限本质是**内存**上限；流式路径的内存由 `threshold` 决定，大小上限由 sink 的 `max_part_size` 决定。保留旧上限会让 20 MiB 的上传在 10 MiB 处被 413——正是这个特性要解决的场景                                                                                                                                     |
| 流式 part 用 `Form_File.path` 而不是新类型            | 同一个 `request_file` 要能服务两种存储（内存 / 磁盘），否则调用方得知道「这个 part 有多大」才能选 API。加 `path` + `size` 两个字段后，小文件读 `data`、大文件读 `path`，取值处只看一个字段是否为空                                                                                                                                     |


---

## 4. Odin 实现注意事项（踩坑记录）

以下全是实际编译中撞过的问题，写新代码前值得扫一遍：

1. **`in` 是关键字**——不能做字段名/参数名。`web` 用 `inbuf`/`data`/`src`。
2. **过程参数不可变**——`proc(w: ^Response)` 里 `width -= 1` 非法；先复制到局部变量。
3. **常量数组不能用变量索引**——`WEEKDAY_NAMES[dow]` 要求 `::` 数组改包级 `:=` 变量。
4. **`nbio.Handle` 是 FD distinct 类型**，没有 nil 值；需要"可选"语义时配 bool 标志。
5. **`odin check web/` 对库包误报缺 main**——验证库用 `odin build web -build-mode:static`；  
   测试用 `odin test web/`。
6. **子目录 import 不解析包名**——`examples/` 里必须 `import "../../web"` 相对路径。
7. **`transmute([]byte)"字面量"` 不允许**——方向是 `transmute([]byte)string(...)`。
8. **方法调用糖不存在**——`w.file_pending()` 要写 `file_pending(w)`。
9. **测试里起服务线程：栈局部变量会悬空**——`integration_spin` 把 `Server`/`done`  
   堆分配后传给线程，线程退出前 free。
10. **`net.parse_endpoint`/`nbio.bound_endpoint` 返回多值**——注意 `ep, ok :=` 形式。
11. **map 字面量语法是 `=` 不是 `:`**（dev-2026-10）：`map[string]string{"k" = "v"}`；  
    且动态复合字面量默认关闭，文件头要加 `#+feature dynamic-literals`——库代码里  
    干脆别用 map 字面量，`response_json` 传结构体即可。
12. **过程参数不可变（再次踩到）**——`vm_run_inner` 的循环变量 `pc`/`si` 必须是  
    局部副本；写状态机/匹配器类代码时默认加 `x_in` 参数 + 本地副本。
13. **`integration_stop` 已负责 free `Server`/`args`**——测试里再  
    `defer free(srv, ...)` 就是 double free（Odin test runner 报 bad free）；  
    自己 `new(Server)` 起服务的测试只 `defer integration_stop` 即可。
14. **私有字段跨包不可见**——`time.Time{_nsec = ...}` 编不过，用  
    `time.unix(sec, nsec)` 构造。
15. **块注释会嵌套**——注释里出现 `/*` 序列（如文档示例中的路由模式  
    `"/api/*"`）会打开嵌套注释，必须自行配平或避开。写 doc.odin 的代码示例时  
    用字符串拼接 `"/api/" + "*"` 代替字面量。
16. **nbio 操作的错误类型不统一**——`op.dial.err` 是 `Network_Error` 联合体  
    （`#shared_nil`），`op.recv.err`/`op.send.err` 是 `Recv_Error`/`Send_Error`  
    联合体（TCP/UDP 两个变体）。`.Timeout` 直接比较会因歧义报错，要先类型断言：  
    `if re, ok := op.recv.err.(net.TCP_Recv_Error); ok && re == .Timeout`。
17. **整数→枚举强转可行**——`Status(u16(code))` 让代理能透传枚举外的状态码  
    （599 等），配合 `Response.reason` 覆盖字段保留上游 reason phrase。
18. **`fmt.bprintf` 返回 string 不是长度**——`addr := fmt.bprintf(buf, ...)`，  
    结果视图在 buf 上，需要长期持有得 clone。
19. **doc 注释里不能出现 `*/` 序列**——块注释不嵌套，文档示例写  
    `Content-Range: bytes */size` 会直接提前闭合注释（报 "Expected a package  
    declaration"）。描述这类头时改述语序或拆开写。
20. **异步回调里"需要更多数据"必须自己重新武装**——`conn_drive` 的状态机模式下  
    各状态（head/body 解析）自己 arm recv；代理的 `proxy_advance` 是纯判断函数，  
    `on_proxy_recv` 必须在它返回后检查连接是否仍停在 `.Proxy`，是则重新  
    `proxy_recv_arm`。漏了这一步的征兆是 chunked/close-delimited 上游场景挂死。
21. **`defer` 绑定的是"块"作用域，不是函数作用域**——`for i in 0..<n { s := new(T);
    defer free(s) }` 会在**每轮迭代结束**就释放 `s`，循环体里存进数组的指针立刻  
    悬空（征兆是 0.005 s 内 SIGTRAP，且 `core:log` 的输出因为进程 abort 全部  
    丢失，看起来像"什么都没跑就死了"）。循环里要延迟释放就自己收集，循环外释放。
22. **不要在还有 send 在途时再排一次 send**——两个 `send_poly` 会共用 `c.op`  
    指向的同一份缓冲：第一个完成时 `buf_reset(&c.out)` 把第二个要发的内容清掉  
    （实测现象是客户端收到一个正常响应头 + 响应头本身作为 body）。代理侧的  
    不变式是「同一时刻只有一个方向在途」，`proxy_pump` 用 `c.op != nil` 守卫，  
    且 `proxy_stream_begin` 之后不再补一次 pump（head 已经由它发出去了）。
23. **`core:net` 的 `Reuse_Port` 在所有平台都映射成 -1**——想真正设置  
    `SO_REUSEPORT` 必须自己 `posix.setsockopt`，值也不同：Linux `15`，  
    Darwin `0x0200`。设完仍要自己 `posix.listen`（`nbio.listen_tcp` 不暴露该选项）。
24. **macOS 的 `SO_REUSEPORT` 不按 4 元组分发**——选项被接受，但内核把*所有*  
    新连接交给最后 bind 的那个 listener（Python 实测 sequential `[0,0,1]`、  
    concurrent `[0,0,30]`）。多 acceptor 的负载分散只在 Linux/BSD 成立，  
    测试里的分发断言要 `when ODIN_OS == .Linux`。
25. **macOS 上未签名二进制不能经 fallback 路径加载 libcrypto**——dyld 直接  
    abort（`WARNING: ... is loading libcrypto in an unsafe way`）。库里  
    `TLS_SSL_NAMES` / `TLS_CRYPTO_NAMES` 只列绝对路径，绝不写裸名  
    `"libssl.dylib"`：一旦 dyld 走到搜索路径就崩。
26. **`dynlib.symbol` 不存在**——`core:dynlib` 只提供 `symbol_address`，装载  
    函数指针要 `ptr, found := dynlib.symbol_address(lib, name)` 再  
    `target^ = cast(T) ptr`。
27. **参数名 `c` 与 `c.int(...)` 冲突**——Odin 里 `c` 是核心包名，过程参数  
    取名为 `c` 时 `c.int(x)` 会被解析成参数，用 `i32(x)` 代替。
28. **router 的 `Handler` 没有 user data，路由级链只能挂在请求上**——  
    `router_route_terminal` 拿不到"当前是哪条路由"，只能让 `router_handle`  
    先把 `req.route = route` 记下，再由末端把 `route.middlewares` 挂到  
    `req.chain`。`router_next` 因此要多一个分支：`r == nil` 时走 `req.chain`。
29. **`router_*` 返回的 `^Route` 会被后续注册搬走**——`routes` 是 dynamic array，  
    `append` 扩容即搬家，之前拿到的指针悬空。规矩：先注册完全部路由，再  
    `router_use_route` 挂中间件（示例与文档都这么写）。
30. **HEAD 不会自动落到 GET 路由**——路由器第一遍按 method 精确匹配，GET-only  
    的路由上 `curl -I` 得到 405。RFC 7231 §4.3.2 要求 GET 存在处 HEAD 必须可用，  
    因此在精确匹配失败后补一遍「HEAD → `.Get`」，body 由 `response_build`  
    统一裁掉（长度仍按 GET 计算）。
31. **`%v` 日志里 `req.principal` 为空是正常的**——认证中间件在全局链上通常排在  
    logger 之后，logger 是在 `router_next` 返回后才写日志，所以能拿到主体；  
    若把 logger 排在 auth 之前仍然可见，但把 auth 放在 *路由级* 链上时，  
    只有进入该路由的请求才有 `user=`。排查"日志没有 user"先看注册位置。
32. **`transmute([]byte)` 需要已定型表达式**——`transmute([]byte) "0\r\n\r\n"`  
    报 "Cannot transmute untyped expression"，先 `s := "0..."` 再  
    `transmute([]byte) s`（或 `[]byte(s)` 走复制）。

## 5. 性能注意点

- **每请求分配次数**：arena reset 前是若干次 arena 分配（线性 bump），reset 后归零。  
  header 解析本身零拷贝。
- **`Buf` 用 `[dynamic]byte`**：Odin dynamic slice 是 {data, len, cap}，append 语义与  
  Go 类似；`buf_consume` 用一次 `memcopy` 把剩余字节前移（不留空洞），残留通常  
  只有几个到几十字节（管道化的下一个请求、上游已超前的 body），代价可忽略。
- **recv 缓冲 16KB 定长**（`RECV_BUF_SIZE`）：`rbuf` 是 `Conn` 内嵌数组，避免每连接  
  一次堆分配；超出部分进 `inbuf` 动态缓冲。
- **sweep 250ms**：idle 清理的粒度，同时是 `server_run_until` 观察 done 标志的粒度。
- **`max_conns` 超限直接拒收**（accept 后立即 close），不排队——防慢速连接耗尽 fd。
- **代理的缓冲上界**：同一时刻只有一个方向在途，`proxy_buf` / `out` 不会同时  
  无限增长；吞吐受限于「发完才收」，胜在内存恒定。
- **TLS 的额外拷贝**：每个方向多一次 `SSL_write`/`SSL_read` 与一份 `tls_out`  
  缓冲；文件体无 `sendfile`，按 64 KiB 分块加密发送。
- **`middleware_range` 的哈希成本**：每条启用了 `etag = true` 的路由，每个响应  
  过一次 FNV-1a（1 GB/s 量级，45 字节的 CSV 只有几十纳秒）；范围切片只在命中  
  `Range` 时复制一次，其余路径零额外分配。它先于 compress filter 计算 ETag，  
  两个编码变体共用一个标签——压缩 filter 会加 `Vary: Accept-Encoding`，  
  对缓存安全，但严格按编码区分标签需要 filter 后再打标（暂未做）。

## 6. 路线图

已实现（v0.4，含 v0.2/v0.3 全部）：

- [x] HTTP/1.1 解析（零拷贝 header）、keep-alive、pipelining
- [x] 请求体：Content-Length + chunked（含解码暂存与回滚）
- [x] 响应构建、HEAD/204/304 语义、自动 Date/Server/Connection
- [x] Filter 链 + 内置 chunked filter（listen 时自动注册，`res.chunked = true` 开箱即用）
- [x] Router：`:param` / `*` 模式、405 + Allow、Odin 原生中间件链
- [x] Static：TTL stat 缓存（含负缓存）、目录 index、sendfile 零拷贝、路径穿越防护
- [x] 反向代理：多上游 round-robin、前缀剥离、X-Forwarded-*/Via、hop-by-hop  
  双向过滤、三种上游分帧（CL 透传 / chunked 透传 / close-delimited 重分帧）  
  如实中继、1xx 跳过、未知状态码连 reason 透传、502/504 错误语义
- [x] 每连接 arena、非阻塞写、多档超时（含上游 dial/send/recv）、连接数上限、优雅 drain
- [x] Cookie：`response_set_cookie`/`request_cookie`，Path/Domain/Expires/  
  Max-Age/Secure/HttpOnly/SameSite 全属性，Set-Cookie 不折叠
- [x] JSON：`response_json` 接 `core:encoding/json`，任意 Odin 值直接序列化
- [x] Lua 模式子集路由：类/集合/量词/捕获组/惰性，回溯 VM + 捕获 undo，  
  `request_capture` 按位次取；与 `:param`/`*` 段式路由共存（含 `(`/`%`/`[` 才进模式引擎）
- [x] Range 请求（RFC 7233）：单 range 走 `sendfile` offset 零拷贝（206 +  
  Content-Range），多 range 回 multipart/byteranges（内存路径），  
  不可满足回 416 + `Content-Range` 带完整长度；畸形/异种单位按  
  RFC 忽略回 200；附带 `Last-Modified` / `If-Modified-Since`（304）/  
  `If-Range`（仅日期校验器，不产 ETag）条件请求支持
- [x] HTTP/1.1 严格模式（RFC 7230 §3.3.3）：TE+CL 同现、非 chunked 结尾的  
  TE、重复/列表型/冲突 CL 一律 400（请求走私防护）；代理侧对上游响应  
  同样严格，违规回 502
- [x] gzip/deflate 内容编码：greedy LZ77 + 固定 Huffman 的自研编码器（无第三方  
  依赖），`Compress_Filter` 按 `Accept-Encoding` 协商、与 chunked 串成  
  「先编码后分帧」，跳过 `sendfile` 文件体与不可压缩类型
- [x] 代理流式化：head 即时下发、body 按帧边收边发，内存不随响应大小增长；  
  增量 chunked 扫描器 + close-delimited 重分帧（HTTP/1.0 回退关闭连接）
- [x] 上游 keep-alive 连接池：按上游维度复用，闲置上限 16 条 / 30 s，  
  失效连接对幂等方法重拨一次；`Server.on_stop` 在循环线程上释放池
- [x] TLS：`core:dynlib` 运行时加载 OpenSSL + memory BIO 双工，握手/读写/关闭  
  挂在既有连接状态机上（handler 无感），文件体分块加密发送
- [x] 多 acceptor 线程：`SO_REUSEPORT`（手写 posix） + 每线程 `Server`/事件循环，  
  `server_run_multi` 一次拉起，端口 0 时回填共享
- [x] 专用中间件：auth（Basic / Bearer / API-Key，等时比较 + `principal`）、  
  form（urlencoded + multipart，解析一次并缓存，字段/文件限额）、  
  range（普通 handler 也能 206/416，内容哈希 ETag + 304）、  
  no-buffer（阻止代理缓冲流式响应）
- [x] 路由级中间件链：`router_use_route` 把任意 `Middleware_Proc` 只挂到一条  
  路由（`router_next(nil, ...)` 走请求上挂的链，中间件实现零改动）
- [x] HEAD 自动回落到同名 GET 路由（RFC 7231 §4.3.2）
- [x] SSE：`sse_start/event/comment/retry/close`，chunked 分帧 + 重连语义；  
  `Sse_Writer` 自带复用缓冲（逐事件零分配）+ `sse_last_event_id` 读重连游标
- [x] 117 个测试（`web` 77 + `web/middleware` 40），全过、零泄漏

已实现（v0.5，中间件按用途成型 + 目录结构整理）：

- [x] 中间件拆成 `web/middleware` 子包（`import ".."`，父包不反向依赖）：  
  父包只留解析与请求状态，中间件全部下沉；跨包状态用 `Request.session` /  
  `Request.uploads` 两个 `rawptr` 槽位传递
- [x] 会话：HMAC-SHA256 签名的 Cookie 会话。服务端零状态（多 acceptor 无需  
  共享、重启不踢人、无清扫），代价是载荷可读、登出非吊销。handler 返回后  
  只在有改动时回写 Cookie；`secret` 为空则整条直通（fail-closed）
- [x] JWT（HS256）：先查 `alg` 再验签（拒 `alg: none`），再核对签名与  
  `exp`/`nbf`/`iss`/`aud`（含时钟容差）；401 带 `error="invalid_token"`。  
  与会话分工：会话管浏览器登录，JWT 管服务间调用
- [x] 静态挂载：目录树挂到单条路由（剥前缀、可 SPA 回落），未命中继续走链；  
  发送仍走父包 `static_serve_root`（stat 缓存 + sendfile + Range + 304）
- [x] 重定向与内部重写：中间件发 3xx（默认 308，按段边界匹配，不留双斜杠），  
  `router_rewrite` 在路由表之前改路径、不发响应——两者是「告诉客户端」与  
  「不告诉客户端」的区别
- [x] 上传落盘：multipart 文件写磁盘（目录按需建、文件名消毒+时间戳），  
  handler 拿路径与大小；非 multipart 正文放行给下一个中间件
- [x] gzip 开关：`middleware_gzip` / `middleware_no_gzip` 按响应设  
  「压/不压/阈值」（`Response.compress` / `compress_min`），压缩本身仍由  
  内置 `Compress_Filter` 做；`Vary: Accept-Encoding` 提前到决策之前加
- [x] 路由表改成 `[dynamic]^Route`：路由堆分配、表只存指针，`router_add`  
  返回的 `^Route` 不再因后续注册而失效（原先会静默写进已释放内存）
- [x] 测试文件按主题拆分（原 `web_test.odin` 3300+ 行 → 14 个主题文件），  
  `static` 二进制退出版本控制

已实现（v0.6，把「占了线程/占了内存」的两处结构性代价补掉）：

- [x] TLS 会话复用：`SSL_CTX` 级 session cache + TLS 1.3 ticket，默认开  
  （`TLS_RESUMPTION_DEFAULT`），`TLS_RESUMPTION_OFF` 关；`session_id_context`  
  由证书路径派生，重启后仍可命中；`Stats.tls_handshakes` / `tls_resumed`  
  可算复用率
- [x] 代理权重 + 健康检查：`weight`（平滑加权轮询，nginx 算法）、连续失败  
  摘除 + 指数退避 + 上限 + 半开探测、全摘除时 fail-open 到最早恢复的一台；  
  `proxy_health_poll` 在 `Server.on_tick` 上跑 TCP 连通性探测
- [x] 异步 handler / 并发流：`Conn_State.Async` + `response_defer` /  
  `request_resume` / 超时续延；续延与同步响应共用 `conn_process_tail`；  
  `Hub` 在其上做 SSE 广播（每订阅者一个结构体 + 64 KB 有界队列，慢客户端  
  丢自己的消息，不拖累发布者）
- [x] 流式上传落盘：`Body_Sink` 抽象 + 增量 multipart 解析  
  （`multipart_stream`，只保留分隔符尾部，且校验分隔行后缀）+ `Upload_Sink`  
  （超过阈值写临时文件，请求结束由 `teardown` 清理）；`Server.on_head`  
  在正文读之前接管；160 个测试（`web` 118 + `web/middleware` 42），全过、零泄漏


后续（按优先级）：

1. **HTTP 客户端**（对标 odin-http 的 `client` 子包）：`client.get/request` +  
   连接池，服务端库暂不做，列为远期方向。
2. **服务端会话存储**：签名 Cookie 会话无法吊销；需要一个可插拔的 store  
   （内存 / Redis）来支撑「踢下线」与大于 4 KB 的会话。
3. **非 multipart 正文也走 sink**：现在只有 multipart 装了 sink，其它正文仍  
   受 `max_body_size` 约束；补一个「整包 spool 到临时文件」的 sink（`req.body_file`）  
   就能让任意大正文（JSON 大对象、CSV 导入）也不进军内存。
4. **chunked 请求体的 part 级流式**：`chunked_try_decode` 已能逐 chunk 交出，  
   但当单个 chunk 本身很大时仍会攒满一块；按「数据段」而非「chunk」交出即可。
5. **Hub 按主题索引订阅者**：目前 `hub_publish` 广播给所有订阅者；万人级、多  
   channel 的场景需要 per-channel 索引，否则每次发布都要遍历全集。
6. **多进程模型**：继续交给外部 supervisor（gorch 等），库不介入。


## 7. 测试策略

`odin test web/`（118 个）+ `odin test web/middleware`（42 个）覆盖三层：

- **纯函数单测**：parser（含畸形输入、OWS 修剪、URL 解码）、chunked 编解码、  
  router（param/405/通配/中间件链顺序）、response 序列化（GET/HEAD/空文件）、  
  proxy 解析（hop-by-hop 过滤表、chunked 走查、上游头解析的四种分帧决策 +  
  1xx 跳过 + 未知状态码、round-robin）。
- **集成测试**：真实起服务（`thread.create` + `nbio` 事件循环线程）+ 阻塞 TCP  
  客户端，覆盖请求响应闭环 + body 回显、畸形请求 400、chunked 请求体、  
  pipelined 双请求、HEAD、空文件 sendfile。
- **代理集成测试**：同时起两个 web 服务器（一个作上游 echo、一个作代理），  
  客户端穿代理验证 GET/POST body、前缀剥离、X-Forwarded-*/Via/Host 改写；  
  chunked 上游透传；用 core:net 阻塞式"原始上游"夹具验证 close-delimited  
  重分帧、流式早发（首字节 < 250 ms）、失效池连接重试；另有池命中计数测试  
  （3 个客户端请求只应开 1 条上游连接）与上游拒连（502）。  
  正向断言会切开 head/body 检查 body 里没有第二份响应头——双 send 的回归  
  只有这样才抓得到。
- **TLS 集成测试**：自带自签证书（`web/testdata/`），客户端走 `SSL_set_fd`  
  的阻塞式 OpenSSL 连接，覆盖 GET、keep-alive 双请求、200 KiB 静态文件  
  逐字节比对；OpenSSL 不可用时整段跳过而不是失败。
- **TLS 复用测试**：`tls_ticket_probe` 起服务、客户端打开 `SSL_SESS_CACHE_CLIENT`  
  并装 `new_session_cb`，做一次 keep-alive 请求（TLS 1.3 的 ticket 是握手后  
  记录），在 500 ms 上限内数收到的 session；同时断言 `tls_handshakes == 1`。  
  只统计「服务端签发了会话」——重放要靠客户端重新出示，服务端测不了。
- **多 acceptor 测试**：3 个 `Server` 共享一个临时端口，30 个连接全部拿到  
  200 且 `bound_port` 一致；分发到多个 acceptor 的断言只在 Linux 生效。
- **异步 / Hub 测试**：都走真实 socket。延迟响应用「到期超时」与「另一条连接  
  唤醒」两条路径，断言续延真的写了响应且连接回到 keep-alive；另有三条把状态机  
  的边界钉住：**续延里再次停车**（二段续延，唯一会从 `conn_async_run` 带着  
  `.Async` 返回的形状）、**同一 handler 两次停车被拒**（第二次返回 false 且不  
  破坏第一次）、**超时后再唤醒返回 false**（迟到的生产者不能往已经往前走的  
  连接上写第二个响应）。Hub 测试两个订阅者 + 一个发布者，断言成帧  
  （`event:`/`id:`/`data:` 一个 chunk）、统计计数与关闭订阅者后被摘除，另有  
  `hub_close` 发出终止块、`hub_tick` 的 keep-alive 注解、多行 `data` 拆成多行  
  `data:`、以及**背压**：把 `max_queue` 压到比一帧还小，事件被跳过（`skipped`  
  计数、订阅者收不到、发布者不受阻），放宽后同一个订阅者恢复；关闭订阅者之后  
  `skipped` 不因 sink 析构而再加一遍。这里踩过两个坑：读缓冲若是栈上局部变量，  
  返回的切片会悬垂，`testing.expectf` 一调用就把「收到的字节」覆盖掉（表现为  
  状态行凭空消失）；续延写完响应后必须重新进 `conn_drive`，否则 `.Write` 永远  
  不会被推进。
- **流式上传测试**：20 MiB 级的正文穿真实 socket，sink 阈值调小以强制落盘，  
  用 FNV-1a 比对临时文件与客户端字节、断言 `req.body` 为空（确实没攒）、  
  请求结束后临时目录为空；另有 chunked 正文（7919 字节的质数步长）、超限 413  
  （part 与字段两条限额）、`keep_temp` 保留、非 multipart 不受影响、  
  **两个文件各归其位**（同一请求里两条临时路径、各自字节、都随请求清掉）、  
  **keep-alive 上的清理**（socket 还开着，请求一结束文件就没，且连接还能继续  
  服务）、以及「1..N 字节窗口逐个喂」的增量解析等价测试（分隔符跨界、正文内含  
  分隔符前缀、空 part、无尾 CRLF、多 part 顺序与 `index`/`size`、前导/后置  
  垃圾、分隔行尾判定与 transport padding）。
- **中间件测试**（`web/middleware/*_test.odin`，42 个）：不建 socket，  
  用合成 `Conn` 走真实 `router_handle` 派发，所以链的顺序、短路与  
  路由级链都按生产路径执行。覆盖 Bearer 的三种 challenge 文案与 principal  
  传递、API-Key 的头/query 两种取法、表单 urlencoded 与 multipart（含  
  「文件名去路径」「类型保留」）、415/400/413 三条错误分支、表单惰性解析  
  与缓存命中、Range 的 206（含 suffix range）/416/多 range 忽略、ETag 与  
  `If-None-Match`/`*`、`If-Range` 命中与过期两种走向、跳过 `sendfile` 响应、  
  路由级中间件隔离（同一 handler 只有挂了 auth 的路由才 401）；会话的往返与  
  伪造/过期 Cookie 拒绝、**栈缓冲值必须被复制**（Cookie 在 handler 返回后才写，  
  那时 handler 的栈帧已被复用）；JWT 的错误 alg / 错密钥 / 过期 / 错 iss/aud；  
  静态挂载的命中、回落、前缀剥离、SPA；重定向的状态码与 Location（含双斜杠）；  
  上传的文件名消毒与限额、`upload_store` 的交接语义（流式落盘的 part 是  
  `rename` 过去而不是复制，源文件随之消失——rename 就是所有权转移）。
- **SSE 集成测试**：真实 socket 上跑一遍 `sse_start/retry/comment/event/close`，  
  断言响应头、chunked 帧内的 `event:`/`id:`/`data:` 字段、终止块 `0\r\n\r\n`。
- **泄漏检测**：Odin test runner 自带内存追踪；`integration_stop` 优雅 drain  
  后连接全部关闭，测试结束时报零泄漏。

测试客户端注意：本机 8080 可能被其他服务（如 gorch）占用，curl 需  
`--noproxy '*'` 并连 LAN IP 验证；集成测试一律用 `127.0.0.1:0` 临时端口。
