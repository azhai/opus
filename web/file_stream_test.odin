package web

// file_stream_test —— 文件体发送路径的回归。
//
// 三个契约，各自对应一个真实缺陷：
//   1. 体超过 FILE_CHUNK 时逐块读→写仍然字节不差（分块状态机的核心）；
//   2. HEAD 必须只回头，**不带体** —— 带体就会把字节漏进 keep-alive 上的下一个响应；
//   3. 每次文件传输不多占一个描述符（Linux：core:nbio 的 sendfile 用两次 splice 过管道，
//      成功路径不关读端；1024 个 fd 的路由器上跑约一千次 Range 请求就再也 open 不出文件）。
//      macOS 的 sendfile 是原生实现、没有管道，这一条只在 Linux 上断言。

import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// STREAM_TEST_SIZE 跨过 FILE_CHUNK（64 KiB）才能覆盖多轮读→写与缓冲复用；
// 末尾故意留零头，让最后一块走 `remaining < chunk` 的分支。
STREAM_TEST_SIZE :: 204_803
STREAM_TEST_PATH :: "/tmp/web_file_stream_body.bin"

stream_body_handler :: proc(req: ^Request, res: ^Response) {
	if !response_send_file_range(res, STREAM_TEST_PATH, 0, STREAM_TEST_SIZE) {
		response_status(res, .Internal_Error)
	}
}

stream_write_fixture :: proc(t: ^testing.T) {
	buf := make([]byte, STREAM_TEST_SIZE, context.temp_allocator)
	defer delete(buf, context.temp_allocator)
	for i in 0 ..< STREAM_TEST_SIZE {
		// 251 是质数：错位、丢块、重复块都会立刻破坏序列，比全零文件更能抓问题
		buf[i] = u8(i % 251)
	}
	if err := os.write_entire_file(STREAM_TEST_PATH, buf); err != nil {
		testing.fail_now(t, "写测试夹具失败")
	}
}

// stream_send_read 发一个请求并读到对端关闭；调用方负责用 Connection: close。
stream_send_read :: proc(t: ^testing.T, client: net.TCP_Socket, request: string) -> []byte {
	if n, err := net.send_tcp(client, transmute([]byte)request); err != nil || n != len(request) {
		testing.fail_now(t, "请求没发完")
	}
	out: [dynamic]byte
	out = make([dynamic]byte, 0, 4096, context.temp_allocator)
	chunk := make([]byte, 64 << 10, context.temp_allocator)
	defer delete(chunk, context.temp_allocator)
	for {
		n, err := net.recv_tcp(client, chunk)
		if err != nil || n == 0 {
			break
		}
		append(&out, ..chunk[:n])
	}
	return out[:]
}

// stream_split 在 \r\n\r\n 处切头/体（测试里的响应头不含 body 字节）。
stream_split :: proc(raw: []byte) -> (head: string, body: []byte, ok: bool) {
	s := transmute(string)raw
	if i := strings.index(s, "\r\n\r\n"); i >= 0 {
		return s[:i+4], raw[i+4:], true
	}
	return s, nil, false
}

@(test)
test_integration_file_body_multi_chunk :: proc(t: ^testing.T) {
	stream_write_fixture(t)
	defer os.remove(STREAM_TEST_PATH)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = stream_body_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	raw := stream_send_read(t, client, "GET /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	head, body, ok := stream_split(raw)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expectf(t, strings.contains(head, "Content-Length: 204803\r\n"), "head: %v", head)
	testing.expect_value(t, len(body), STREAM_TEST_SIZE)
	if len(body) != STREAM_TEST_SIZE {
		return
	}
	mismatch := -1
	for i in 0 ..< STREAM_TEST_SIZE {
		if body[i] != u8(i % 251) {
			mismatch = i
			break
		}
	}
	testing.expectf(t, mismatch < 0, "第 %d 字节不对", mismatch)
}

// HEAD 只回头；并且同一个 keep-alive 连接上的下一个请求要能正常解析 ——
// 前者保证客户端不多读，后者保证服务端没往流里漏字节。
@(test)
test_integration_head_file_has_no_body :: proc(t: ^testing.T) {
	stream_write_fixture(t)
	defer os.remove(STREAM_TEST_PATH)

	srv := new(Server, context.allocator)
	testing.expect(t, server_init(srv, "127.0.0.1:0"))
	srv.handler = stream_body_handler
	srv.idle_timeout = 2 * time.Second
	ep, th, args := integration_spin_srv(t, srv)
	defer integration_stop(t, args, th)

	client, derr := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr == nil)
	defer net.close(client)

	// 1) Connection: close 的 HEAD：整条流里必须只有头
	head_only := stream_send_read(t, client, "HEAD /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	head, body, ok := stream_split(head_only)
	testing.expect(t, ok)
	testing.expect(t, strings.has_prefix(head, "HTTP/1.1 200 OK\r\n"))
	testing.expectf(t, strings.contains(head, "Content-Length: 204803\r\n"), "head: %v", head)
	testing.expect_value(t, len(body), 0)
	net.close(client)

	// 2) keep-alive 的 HEAD 后接 GET：GET 的响应必须以状态行开头
	client2, derr2 := net.dial_tcp_from_endpoint(ep)
	testing.expect(t, derr2 == nil)
	defer net.close(client2)

	head_req := "HEAD /body HTTP/1.1\r\nHost: x\r\n\r\n"
	if n, err := net.send_tcp(client2, transmute([]byte)head_req); err != nil || n != len(head_req) {
		testing.fail_now(t, "HEAD 请求没发完")
	}
	head_buf: [1024]byte
	got := 0
	for got < len(head_buf) {
		n, err := net.recv_tcp(client2, head_buf[got:])
		if err != nil || n == 0 {
			break
		}
		got += n
		if strings.contains(string(head_buf[:got]), "\r\n\r\n") {
			break
		}
	}
	testing.expect(t, strings.has_prefix(string(head_buf[:got]), "HTTP/1.1 200 OK\r\n"))

	// 若 HEAD 漏了体，下面这段读到的第一批字节就是文件内容而不是状态行
	rest := stream_send_read(t, client2, "GET /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	testing.expectf(t, strings.has_prefix(string(rest), "HTTP/1.1 "), "expected a status line, got %q", rest[:min(len(rest), 32)])
}

// stream_fd_count 数本进程的描述符（Linux 专用；读目录自身也会占一个 fd，
// 调用结束即释放，所以前后两次取样可比）。
stream_fd_count :: proc() -> int {
	when ODIN_OS == .Linux {
		infos, err := os.read_directory_by_path("/proc/self/fd", -1, context.temp_allocator)
		if err != nil {
			return -1
		}
		return len(infos)
	}
	return -1
}

@(test)
test_file_stream_fd_stable :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		stream_write_fixture(t)
		defer os.remove(STREAM_TEST_PATH)

		srv := new(Server, context.allocator)
		testing.expect(t, server_init(srv, "127.0.0.1:0"))
		srv.handler = stream_body_handler
		srv.idle_timeout = 2 * time.Second
		ep, th, args := integration_spin_srv(t, srv)
		defer integration_stop(t, args, th)

		// 一次预热：让「连接结构、缓冲区」这类一次性分配先发生
		if c, err := net.dial_tcp_from_endpoint(ep); err == nil {
			stream_send_read(t, c, "GET /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
			net.close(c)
		}
		time.sleep(100 * time.Millisecond)
		base := stream_fd_count()
		testing.expect(t, base > 0)

		for _ in 0 ..< 8 {
			c, err := net.dial_tcp_from_endpoint(ep)
			testing.expect(t, err == nil)
			stream_send_read(t, c, "GET /body HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
			net.close(c)
		}
		time.sleep(200 * time.Millisecond)
		after := stream_fd_count()
		// +1 的余量留给「最后一条连接还在异步收尾」
		testing.expectf(t, after <= base + 1, "8 次文件传输后描述符从 %d 涨到 %d（每次传输不该留下一个 fd）", base, after)
	}
}
