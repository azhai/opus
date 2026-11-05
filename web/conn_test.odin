package web

// Unit tests for the connection-level write path decisions, kept off the
// socket so the rules can be read as rules (see conn_batch_next).

import "core:testing"
import "../buffer"

/*
test_conn_batch_next: the batching gate is what turns a pipelined burst into
one send operation instead of one per response, so every condition that must
hold deserves a case. The `batch_ok` case is the one that is a correctness
rule rather than a performance one: without it the gate would look for the
next request's terminator inside a body that is still buffered.
*/
@(test)
test_conn_batch_next :: proc(t: ^testing.T) {
	c: Conn
	defer buffer.buf_destroy(&c.inbuf)
	c.state = .Write
	c.res.keep_alive = true
	c.batch_ok = true
	buffer.buf_init(&c.inbuf, context.allocator)
	buffer.buf_append_string(&c.inbuf, "GET /next HTTP/1.1\r\nHost: h\r\n\r\n")

	testing.expect(t, conn_batch_next(&c))

	// a second head, still buffered: batching continues
	buffer.buf_append_string(&c.inbuf, "GET /third HTTP/1.1\r\nHost: h\r\n\r\n")
	testing.expect(t, conn_batch_next(&c))

	// the request that finished left body bytes behind: the terminator found
	// in the buffer may belong to that body
	c.batch_ok = false
	testing.expect(t, !conn_batch_next(&c))
	c.batch_ok = true

	// nothing else to parse: flushing now is what the peer is waiting for
	buffer.buf_reset(&c.inbuf)
	testing.expect(t, !conn_batch_next(&c))

	// an incomplete head must not defer the flush either
	buffer.buf_append_string(&c.inbuf, "GET /partial HTTP/1.1\r\nHost: h\r\n")
	testing.expect(t, !conn_batch_next(&c))
	buffer.buf_reset(&c.inbuf)
	buffer.buf_append_string(&c.inbuf, "GET /next HTTP/1.1\r\nHost: h\r\n\r\n")

	// the response says the connection ends here
	c.res.keep_alive = false
	testing.expect(t, !conn_batch_next(&c))
	c.res.keep_alive = true

	// connection-level reasons to stop batching
	c.closing = true
	testing.expect(t, !conn_batch_next(&c))
	c.closing = false

	c.closed = true
	testing.expect(t, !conn_batch_next(&c))
	c.closed = false

	// enough is enough: the batch is flushed once it reaches the cap
	for buffer.buf_len(&c.out) < WRITE_BATCH_BYTES {
		buffer.buf_append_string(&c.out, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
	}
	testing.expect(t, !conn_batch_next(&c))
	buffer.buf_destroy(&c.out)
}

/*
test_conn_request_reset_trims_buffers: the reset runs between two requests on
the same keep-alive connection, which is exactly where a megabyte of response
would otherwise become permanent. Out is trimmed once it is empty; inbuf keeps
whatever the parser still owns (the head of a pipelined request) and is only
trimmed when drained.
*/
@(test)
test_conn_request_reset_trims_buffers :: proc(t: ^testing.T) {
	srv: Server
	srv.allocator = context.allocator
	c: Conn
	c.server = &srv
	buffer.buf_init(&c.inbuf, context.allocator)
	buffer.buf_init(&c.out, context.allocator)
	buffer.buf_init(&c.body_buf, context.allocator)
	buffer.buf_init(&c.proxy_req, context.allocator)
	buffer.buf_init(&c.proxy_buf, context.allocator)
	defer buffer.buf_destroy(&c.inbuf)
	defer buffer.buf_destroy(&c.out)
	defer buffer.buf_destroy(&c.body_buf)
	defer buffer.buf_destroy(&c.proxy_req)
	defer buffer.buf_destroy(&c.proxy_buf)

	big := make([]byte, 1 << 20, context.allocator)
	defer delete(big)
	buffer.buf_append(&c.out, big)
	buffer.buf_append(&c.body_buf, big)

	conn_request_reset(&c)
	testing.expect_value(t, len(c.out.data), 0)
	testing.expect(t, cap(c.out.data) <= BUF_KEEP_CAP, "out should be trimmed")
	testing.expect(t, cap(c.body_buf.data) <= BUF_KEEP_CAP, "body_buf should be trimmed")

	// a pipelined head waiting in inbuf survives the reset with its bytes
	pipelined := "GET /next HTTP/1.1\r\nHost: h\r\n\r\n"
	buffer.buf_append_string(&c.inbuf, pipelined)
	conn_request_reset(&c)
	testing.expect_value(t, len(c.inbuf.data), len(pipelined))
}
