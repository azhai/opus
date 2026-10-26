package web

import "core:c"
import "core:nbio"
import "core:net"
import "core:thread"
import "core:time"

/*
Multi-acceptor mode: several Server instances, one per thread, each with its
own event loop, all serving the same address. Accept, read and write
parallelize without any locking in the library, because every per-connection
structure is already thread-local.

Usage:

	servers: [4]^web.Server
	for i in 0..<len(servers) {
		s := new(web.Server)
		web.server_init(s, "0.0.0.0:8080")
		s.handler = handler
		servers[i] = s
	}
	web.server_run_multi(servers[:], &done)

Everything per-connection (arena, buffers, state machine) is already
per-thread state; what is *not* shared automatically is user state reachable
through `user_ptr`. A router table is read-only after setup and therefore
fine, but a Proxy owns pooled upstream sockets that belong to one loop, so
each server needs its own Proxy instance.

A port of 0 is resolved by the first server before the others start, so all
of them end up on the same ephemeral port (useful in tests).

How the acceptors share the address is platform specific; see
MULTI_SHARE_LISTENER.
*/

/*
MULTI_SHARE_LISTENER selects how the acceptors of a group share the address.

Linux spreads new connections over a SO_REUSEPORT group by flow hash: evenly,
and without waking more than one listener. There each acceptor binds its own
socket.

macOS accepts SO_REUSEPORT but does not spread: every connection goes to a
single listener - measured at 4 acceptors with 100 concurrent connections,
the split was 0/0/0/621162 - so N-1 threads sat idle. There the extra
acceptors attach to the fd the first server bound (`server_adopt_listener`)
and the kernel wakes whichever loop is ready; the losers of that race get
EWOULDBLOCK and re-arm. The thundering herd is paid per *connection*, not per
request, so keep-alive traffic barely notices it.
*/
MULTI_SHARE_LISTENER :: ODIN_OS != .Linux

/*
macOS schedules on two kinds of core (M4: 4 performance, 6 efficiency) and
puts threads that look like background work on the efficiency ones, where the
same loop takes two to three times longer per request. An acceptor thread is
latency sensitive by definition, so it asks for the interactive class; the
kernel is still free to move it.
*/
when ODIN_OS == .Darwin {
	Thread_QoS :: enum u32 {
		User_Interactive = 0x21,
		User_Initiated   = 0x19,
	}
	foreign import _pthread "system:System"
	@(default_calling_convention = "c", link_prefix = "pthread_")
	foreign _pthread {
		set_qos_class_self_np :: proc(class: Thread_QoS, priority: c.int) -> c.int ---
	}
}

// boost_thread_qos raises the calling thread's scheduling class. No-op off
// Darwin, and harmless to call more than once.
boost_thread_qos :: proc() {
	when ODIN_OS == .Darwin {
		set_qos_class_self_np(.User_Interactive, 0)
	}
}

Server_Thread_Args :: struct {
	srv:  ^Server,
	done: ^bool,
	// listen_socket is the fd the first server bound. Only used when the
	// platform shares one listener instead of binding one per acceptor.
	listen_socket:  net.TCP_Socket,
	share_listener: bool,
}

/*
server_run_multi runs `servers` in parallel until `done` becomes true, with
the calling thread driving servers[0]. It returns false if the first server
could not listen; later failures are logged by the thread that hit them.

The listener is closed only after every acceptor thread has stopped: the
socket outlives the loops waiting on it, and closing it while a worker is
still in accept would hand that worker EBADF.
*/
server_run_multi :: proc(servers: []^Server, done: ^bool) -> bool {
	if len(servers) == 0 || done == nil {
		return false
	}
	for s in servers {
		s.done_flag = done
		s.reuse_port = !MULTI_SHARE_LISTENER && len(servers) > 1
	}

	boost_thread_qos()
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
			server_release(main)
			return false
		}
		for i in 1..<len(servers) {
			servers[i].endpoint.port = ep.port
			servers[i].bound_port = ep.port
		}
	}

	workers := len(servers) - 1
	threads := make([]^thread.Thread, workers, context.allocator)
	args := make([]^Server_Thread_Args, workers, context.allocator)
	defer delete(threads, context.allocator)
	defer delete(args, context.allocator)

	for i in 0..<workers {
		a := new(Server_Thread_Args, context.allocator)
		a.srv = servers[i + 1]
		a.done = done
		a.listen_socket = main.listen_socket
		a.share_listener = MULTI_SHARE_LISTENER
		args[i] = a
		th := thread.create(server_thread_proc)
		th.data = a
		thread.start(th)
		threads[i] = th
	}

	nbio.run_until(done)

	// join before releasing: the listener has to stay valid until the last
	// acceptor has removed its accept operation
	for i in 0..<workers {
		thread.join(threads[i])
	}
	server_release(main)

	for i in 0..<workers {
		thread.destroy(threads[i])
		free(args[i], context.allocator)
	}
	return true
}

server_thread_proc :: proc(t: ^thread.Thread) {
	a := cast(^Server_Thread_Args) t.data
	s := a.srv
	boost_thread_qos()
	if err := nbio.acquire_thread_event_loop(); err != nil {
		log_error("web: acceptor thread cannot acquire an event loop: %v", err)
		return
	}
	defer nbio.release_thread_event_loop()

	if a.share_listener {
		if !server_adopt_listener(s, a.listen_socket) {
			return
		}
	} else if !server_listen(s) {
		return
	}
	nbio.run_until(a.done)
	server_release(s)
}

// server_release runs the shutdown hooks on the loop thread and drains the
// loop so in-flight completions (socket close callbacks that free
// connections) still get to run.
//
// The listener is closed here rather than in `server_destroy`: the socket is
// owned by the event loop, so it has to be released on the loop thread and
// before the loop is dropped. Leaving it open kept the port bound after a
// server stopped, which showed up as "address in use" the second time the
// same process started a server on that port. With a shared listener only
// the owner closes it.
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
	if s.listening {
		s.listening = false
		if s.owns_listener {
			nbio.close(s.listen_socket)
		}
	}
	for i in 0..<200 {
		if nbio.num_waiting() == 0 {
			break
		}
		nbio.tick(10 * time.Millisecond)
	}
}
