/*
Package codecs implements the content codings of RFC 7231 section 3.1.2.1 that
this library can produce: raw deflate (RFC 1951) and gzip (RFC 1952).

Odin's core library ships decompression only (`core:compress/zlib` and
`core:compress/gzip` both inflate), so the compressor lives here: a greedy
LZ77 (hash-chain match finder, 32 KiB window) feeding fixed Huffman blocks,
wrapped as a raw deflate stream or a gzip member. Fixed Huffman costs a few
percent of ratio versus dynamic Huffman but removes the entire tree-building
stage; correctness is verified by round-tripping every test payload through
`core:compress/zlib`'s inflater.

The package is pure: no socket, no `Conn`, no policy. It answers "these bytes,
in this coding" and nothing else. The two questions around it are answered
elsewhere, so that each has exactly one implementation:

  - *which coding should this response use* - `http.negotiate_coding`, from
    the request's `Accept-Encoding`, plus `http.content_type_compressible` for
    whether a media type is worth coding at all. Both are pure header rules.
  - *apply it to the response in flight* - `web.Coding_Filter`, the only place
    that can see a `Conn`, its scratch allocator and the response body.

File layout follows the formats rather than the call graph: `bits.odin` (the
LSB-first bit sink), `deflate.odin` (window, match finder, fixed-Huffman
symbols), `gzip.odin` (member wrapper), `crc32.odin` (the checksum gzip's
trailer needs).
*/
package codecs
