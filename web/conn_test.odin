package web

// Unit tests for the connection-level write path decisions, kept off the
// socket so the rules can be read as rules (see conn_batch_next).

import "core:testing"

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
	defer buf_destroy(&c.inbuf)
	c.state = .Write
	c.res.keep_alive = true
	c.batch_ok = true
	buf_init(&c.inbuf, context.allocator)
	buf_append_string(&c.inbuf, "GET /next HTTP/1.1\r\nHost: h\r\n\r\n")

	testing.expect(t, conn_batch_next(&c))

	// a second head, still buffered: batching continues
	buf_append_string(&c.inbuf, "GET /third HTTP/1.1\r\nHost: h\r\n\r\n")
	testing.expect(t, conn_batch_next(&c))

	// the request that finished left body bytes behind: the terminator found
	// in the buffer may belong to that body
	c.batch_ok = false
	testing.expect(t, !conn_batch_next(&c))
	c.batch_ok = true

	// nothing else to parse: flushing now is what the peer is waiting for
	buf_reset(&c.inbuf)
	testing.expect(t, !conn_batch_next(&c))

	// an incomplete head must not defer the flush either
	buf_append_string(&c.inbuf, "GET /partial HTTP/1.1\r\nHost: h\r\n")
	testing.expect(t, !conn_batch_next(&c))
	buf_reset(&c.inbuf)
	buf_append_string(&c.inbuf, "GET /next HTTP/1.1\r\nHost: h\r\n\r\n")

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
	for buf_len(&c.out) < WRITE_BATCH_BYTES {
		buf_append_string(&c.out, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
	}
	testing.expect(t, !conn_batch_next(&c))
	buf_destroy(&c.out)
}
