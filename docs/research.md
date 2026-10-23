# web 库调研与设计文档

本文记录 `web` 包（Odin 语言的 HTTP/1.1 基础服务库）的调研结论、设计取舍与实现要点。
代码本身即最终文档（`doc.odin` 是包级文档），本文解释**为什么这样设计**。

---

## 1. 调研对象与借鉴矩阵

| 来源 | 学什么 | 不学什么 |
|---|---|---|
| **lighttpd2** | 分层架构：连接级/请求级双层状态机、filter 输出管线、action 组合、stat 缓存 | 配置语言（angel/condition 的 Lua 式求值）、插件动态加载、worker 进程模型 |
| **Mongoose** (cesanta) | API 手感：一个 `Server` + 一个 `handler` + `user_ptr`；事件循环对用户透明；单包零依赖 | 自带 TLS/协议栈全家桶、`mg_mgr` 的手写 poller（我们有 `core:nbio`） |
| **odin-http** | Odin 社区对 `Server`/`Request`/`Response` 的命名习惯 | 其同步阻塞式 accept 循环（我们要事件驱动） |
| **core:nbio** | 事件循环本体：io_uring/kqueue/IOCP 统一抽象、`*_poly` 系列操作 | 不需要"学"——直接用 |

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

---

## 2. 架构分层

```
┌─────────────────────────────────────────────────────┐
│ 用户代码：Handler / Router / Middleware / Static      │  ← Mongoose 式 API
├─────────────────────────────────────────────────────┤
│ server.odin    Server：listen/accept/sweep/run       │  ← 生命周期与配置
│ router.odin    Router：两遍匹配 + 中间件链             │  ← lighttpd2 action 思想的
│ static.odin    Static：stat 缓存 + sendfile           │     宿主语言实现
├─────────────────────────────────────────────────────┤
│ conn.odin      Conn：双层状态机 + 每连接 arena         │  ← lighttpd2 骨架
│ request.odin   parse_request：零拷贝 header 视图        │
│ response.odin  response_build：序列化 + sendfile 切换  │
│ filter.odin    Filter 链 + chunked 编解码              │
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

| 决策 | 理由 |
|---|---|
| 用 `core:nbio` 而非手写 epoll/kqueue | nbio 统一了三平台后端，`*_poly` 回调省去 user_data 机制；重复造 poller 无收益 |
| 路由两遍扫描 | 先 method+path 精确匹配；第二遍 path-only 返回 `method_ok=false` 供 405 回答。比"单遍记录首个 path 匹配"更简单且行为正确 |
| 中间件用显式 `idx` 而非闭包 | Odin 过程是第一类值但闭包捕获写起来啰嗦；`router_next(r, idx+1, final, ...)` 显式续链，零捕获、零分配 |
| `path_match` 中 `*` 通配检查置于 query 分离之前 | 否则 `/*` 无法匹配 `/`（"/" 的 qs 边界判断会先失败） |
| HEAD 也发 `Content-Length` | RFC 7231 §4.3.2：HEAD 响应携带 GET 会有的长度，只是不带 body |
| 0 字节文件：关闭 handle 发 `Content-Length: 0` | 避免对空文件发起 sendfile(0) 的边界情况 |
| `nbio.Handle`(FD) 不可赋 nil | Odin distinct 整数类型语义；用 `file_open: bool` 标志表示"持有有效 handle" |
| socket 异步关闭，`Conn` 在 close 回调里 free | `nbio.close_poly(socket, c, on_socket_closed)`：先 `nbio.remove(c.op)` 撤销在途操作防 UAF，关闭完成回调里 `free(c)` |
| `server_run_until` 优雅 drain | 撤销 accept/sweep 操作后 tick 到 `nbio.num_waiting() == 0`，让在途关闭回调跑完，测试零泄漏 |
| 编译期 debug 开关 | `WEB_DEBUG :: #config(WEB_DEBUG, false)`，`-define:WEB_DEBUG=true` 打开 `log_debug`；release 构建零开销 |

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

## 5. 性能注意点

- **每请求分配次数**：arena reset 前是若干次 arena 分配（线性 bump），reset 后归零。
  header 解析本身零拷贝。
- **`Buf` 用 `[dynamic]byte`**：Odin dynamic slice 是 {data, len, cap}，append 语义与
  Go 类似；`buf_consume` 通过前移指针实现，不 memmove（保留管道化字节）。
- **recv 缓冲 16KB 定长**（`RECV_BUF_SIZE`）：`rbuf` 是 `Conn` 内嵌数组，避免每连接
  一次堆分配；超出部分进 `inbuf` 动态缓冲。
- **sweep 250ms**：idle 清理的粒度，同时是 `server_run_until` 观察 done 标志的粒度。
- **`max_conns` 超限直接拒收**（accept 后立即 close），不排队——防慢速连接耗尽 fd。

## 6. 路线图

已实现（v0.1）：

- [x] HTTP/1.1 解析（零拷贝 header）、keep-alive、pipelining
- [x] 请求体：Content-Length + chunked（含解码暂存与回滚）
- [x] 响应构建、HEAD/204/304 语义、自动 Date/Server/Connection
- [x] Filter 链 + 内置 chunked filter
- [x] Router：`:param` / `*` 模式、405 + Allow、Odin 原生中间件链
- [x] Static：TTL stat 缓存（含负缓存）、目录 index、sendfile 零拷贝、路径穿越防护
- [x] 每连接 arena、非阻塞写、多档超时、连接数上限、优雅 drain
- [x] 20 个测试（单测 + 集成），`odin test web/` 全过、零泄漏

后续（按优先级）：

1. **TLS filter**：以 `Filter` 形态挂接（socket 层包一层），不改状态机。
2. **Range 请求**：static 已发 `Accept-Ranges: none`，接通部分内容发送
   （sendfile 带 offset/length 即可）。
3. **gzip/deflate filter**：响应侧 chunked + Content-Encoding 组合。
4. **HTTP/1.1 严格模式**：如 `Transfer-Encoding` 与 `Content-Length` 同时出现
   时的 smuggling 防护（当前 TE 优先，需按 RFC 7230 §3.3.3 加固）。
5. **多 acceptor 线程**：`core:nbio` 是每线程事件循环，SO_REUSEPORT + N 个
   `server_run` 即可水平扩展；`Server` 需要变成 per-thread 实例或加锁。

## 7. 测试策略

`odin test web/` 覆盖三层：

- **纯函数单测**：parser（含畸形输入、OWS 修剪、URL 解码）、chunked 编解码、
  router（param/405/通配/中间件链顺序）、response 序列化（GET/HEAD/空文件）。
- **集成测试**：真实起服务（`thread.create` + `nbio` 事件循环线程）+ 阻塞 TCP
  客户端，覆盖请求响应闭环 + body 回显、畸形请求 400、chunked 请求体、
  pipelined 双请求、HEAD、空文件 sendfile。
- **泄漏检测**：Odin test runner 自带内存追踪；`integration_stop` 优雅 drain
  后连接全部关闭，测试结束时报零泄漏。

测试客户端注意：本机 8080 可能被其他服务（如 gorch）占用，curl 需
`--noproxy '*'` 并连 LAN IP 验证；集成测试一律用 `127.0.0.1:0` 临时端口。
