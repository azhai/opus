package web

import "core:nbio"
import "core:thread"
import "core:time"

/*
Multi-acceptor mode: several Server instances, one per thread, each with its
own event loop and its own listen socket bound to the same address with
SO_REUSEPORT. The kernel spreads incoming connections over them, so accept,
read and write all parallelize without any locking in the library.

Usage:

	servers: [4]^web.Server
	for i in 0..<len(servers) {
		s := new(web.Server)
		web.server_init(s, "0.0.0.0:8080")
		s.handler = handler
		servers[i] = s
	}
	web.server_run_multi(servers[:])

Everything per-connection (arena, buffers, state machine) is already
per-thread state; what is *not* shared automatically is user state reachable
through `user_ptr`. A router table is read-only after setup and therefore
fine, but a Proxy owns pooled upstream sockets that belong to one loop, so
each server needs its own Proxy instance.

A port of 0 is resolved by the first server before the others start, so all
of them end up on the same ephemeral port (useful in tests).
*/

Server_Thread_Args :: struct {
	srv:  ^Server,
	done: ^bool,
}

/*
server_run_multi runs `servers` in parallel until `done` becomes true, with
the calling thread driving servers[0]. It returns false if the first server
could not listen; later failures are logged by the thread that hit them.
*/
server_run_multi :: proc(servers: []^Server, done: ^bool) -> bool {
	if len(servers) == 0 || done == nil {
		return false
	}
	for s in servers {
		s.done_flag = done
		s.reuse_port = len(servers) > 1
	}

	if err := nbio.acquire_thread_event_loop(); err != nil {
		log_error("web: cannot acquire event loop: %v", err)
		return false
	}
	defer nbio.release_thread_event_loop()

	main := servers[0]
	if !server_listen(main) {
		return false
	}

	// pin every other server to the port the first one actually got
	if len(servers) > 1 {
		ep, oerr := nbio.bound_endpoint(main.listen_socket)
		if oerr != nil {
			log_error("web: cannot read bound endpoint: %v", oerr)
			return false
		}
		for i in 1..<len(servers) {
			servers[i].endpoint.port = ep.port
		}
	}

	workers := len(servers) - 1
	threads := make([]^thread.Thread, workers, context.allocator)
	args := make([]^Server_Thread_Args, workers, context.allocator)
	defer delete(threads)
	defer delete(args)

	for i in 0..<workers {
		a := new(Server_Thread_Args, context.allocator)
		a.srv = servers[i + 1]
		a.done = done
		args[i] = a
		th := thread.create(server_thread_proc)
		th.data = a
		thread.start(th)
		threads[i] = th
	}

	nbio.run_until(done)
	server_release(main)

	for i in 0..<workers {
		thread.join(threads[i])
		thread.destroy(threads[i])
		free(args[i], context.allocator)
	}
	return true
}

server_thread_proc :: proc(t: ^thread.Thread) {
	a := cast(^Server_Thread_Args) t.data
	s := a.srv
	if err := nbio.acquire_thread_event_loop(); err != nil {
		log_error("web: acceptor thread cannot acquire an event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	if !server_listen(s) {
		return
	}
	nbio.run_until(a.done)
	server_release(s)
}

// server_release runs the shutdown hooks on the loop thread and drains the
// loop so in-flight completions (socket close callbacks that free
// connections) still get to run.
server_release :: proc(s: ^Server) {
	if s.on_stop != nil {
		s.on_stop(s)
	}
	if s.accept_op != nil {
		nbio.remove(s.accept_op)
		s.accept_op = nil
	}
	if s.sweep_op != nil {
		nbio.remove(s.sweep_op)
		s.sweep_op = nil
	}
	for i in 0..<200 {
		if nbio.num_waiting() == 0 {
			break
		}
		nbio.tick(10 * time.Millisecond)
	}
}
