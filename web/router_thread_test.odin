package web

// router_thread_test —— 路由索引在多 acceptor 线程下的并发首次匹配。
//
// 契约来自一个真实故障：8 条事件循环线程 + 启动后的第一波并发请求，服务
// 从此丢掉任意几条路由（/api/caps 404、POST /api/auth/login/hash 405），其余
// 正常，且重启即好、串行访问不复现。
//
// 原因在 `router_match` 的惰性重建：多个线程同时看到 index_dirty 时，一个
// 线程正在 delete 旧 map、free 每条路由条目，另一个线程同时在读同一张表。
// 修法是 router_seal（启动期单线程建好）+ 重建串行化。这个用例不 seal，
// 直接让 N 个线程同时冲第一次匹配 —— 那正是故障现场。

import "core:fmt"
import "core:sync"
import "core:testing"
import "core:thread"

ROUTER_THREAD_ROUTES :: 64
ROUTER_THREAD_WORKERS :: 8
ROUTER_THREAD_ROUNDS :: 100

router_thread_handler :: proc(req: ^Request, res: ^Response) {}

Router_Thread_Probe :: struct {
	router:  ^Router,
	barrier: ^sync.Barrier,
	misses:  int,
	matched: int,
}

router_thread_worker :: proc(t: ^thread.Thread) {
	p := cast(^Router_Thread_Probe) t.data
	// 所有线程卡在同一个栅栏上，保证第一次匹配是真正并发发生的
	sync.barrier_wait(p.barrier)
	for _ in 0 ..< ROUTER_THREAD_ROUNDS {
		for i in 0 ..< ROUTER_THREAD_ROUTES {
			path := fmt.tprintf("/api/r/%d", i)
			req := Request {
				path   = path,
				method = .Get,
			}
			route, ok := router_match(p.router, &req, context.temp_allocator)
			if ok && route != nil {
				p.matched += 1
			} else {
				p.misses += 1
			}
		}
	}
}

@(test)
test_router_concurrent_first_match :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)
	defer router_destroy(&r)

	for i in 0 ..< ROUTER_THREAD_ROUTES {
		router_get(&r, fmt.tprintf("/api/r/%d", i), router_thread_handler)
	}
	// 故意的：不调用 router_seal，让第一次匹配走惰性重建
	testing.expect(t, r.index_dirty, "注册之后应当是 dirty 的")

	barrier: sync.Barrier
	sync.barrier_init(&barrier, ROUTER_THREAD_WORKERS + 1)

	probes: [ROUTER_THREAD_WORKERS]Router_Thread_Probe
	threads: [ROUTER_THREAD_WORKERS]^thread.Thread

	for i in 0 ..< ROUTER_THREAD_WORKERS {
		probes[i] = Router_Thread_Probe{router = &r, barrier = &barrier}
		threads[i] = thread.create(router_thread_worker)
		threads[i].data = &probes[i]
		thread.start(threads[i])
	}
	// 起跑
	sync.barrier_wait(&barrier)

	misses, matched := 0, 0
	for i in 0 ..< ROUTER_THREAD_WORKERS {
		thread.join(threads[i])
		misses += probes[i].misses
		matched += probes[i].matched
		thread.destroy(threads[i])
	}

	want := ROUTER_THREAD_WORKERS * ROUTER_THREAD_ROUNDS * ROUTER_THREAD_ROUTES
	testing.expectf(t, misses == 0,
		"%d 次并发匹配里有 %d 次没命中（命中 %d / 应为 %d）——索引在重建时被并发读坏了",
		want, misses, matched, want)
	testing.expect_value(t, matched, want)
	testing.expect(t, !r.index_dirty, "重建之后应当不再是 dirty")
}

// 封板之后，匹配路径上取的是同一张表，且不再重建 —— 这条守的是
// 「router_seal 之后 lazy 重建不会再被触发」这个前提。
@(test)
test_router_seal_is_idempotent :: proc(t: ^testing.T) {
	r: Router
	router_init(&r)
	defer router_destroy(&r)

	router_get(&r, "/api/one", router_thread_handler)
	router_post(&r, "/api/two", router_thread_handler)
	router_seal(&r)
	testing.expect(t, !r.index_dirty)

	first_len := len(r.index)
	router_seal(&r)
	testing.expect_value(t, len(r.index), first_len)

	req := Request{path = "/api/two", method = .Post}
	route, ok := router_match(&r, &req, context.temp_allocator)
	testing.expect(t, ok && route != nil)

	req_405 := Request{path = "/api/two", method = .Get}
	_, ok_405 := router_match(&r, &req_405, context.temp_allocator)
	testing.expect(t, !ok_405, "同路径不同方法应当走到 405 分支")
}
