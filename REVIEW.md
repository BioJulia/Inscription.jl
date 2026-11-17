# Design review (2026-11-17)

### 7. Struct support crosses the design's own "guard against snowballing"

Struct support is defensible as bytemuck-style "memory layout is the wire format"
support, but it should be a deliberate decision. Whether a struct has padding depends on
the platform (for example, the alignment of `Int128` differs), so a struct can encode
fine on one machine and throw an `ArgumentError` on another.

**Recommendation:** document that, and treat structs as the line where layer 2 begins.

## Smaller API points

- **Missing codecs give a confusing error.** `load(io, Char, LittleEndian())` fails with a
  `MethodError` on `codec_max_encoded_size`, a function the user never called. A fallback
  method that throws "no codec for `Char` with `LittleEndian`" would be clearer, and adds
  no ambiguity.

## Something to watch: buffering up to `max_encoded_size`

On a stream that isn't at EOF, `try_load` waits until `max_encoded_size` bytes are
buffered. For a variable-length codec in a request/response protocol, such as a
protobuf-style varint at the end of a message on a socket, that is a deadlock, not just a
terminal-keypress problem. Today the blocking fill of `BufReader` hides it. If that is
fixed in BufferIO (the side finding in DESIGN.md §3), this becomes the limit.

Adding `bytes_needed` later is non-breaking, so the current decision is fine for now. But
the `try_load` docstring should say that it may wait for bytes beyond the value.
