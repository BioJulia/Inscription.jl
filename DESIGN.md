# BufferSerde.jl design

Living draft, refined iteratively. Labels:
* **Decision**: agreed upon.
* **Proposal**: recommended, not yet agreed.
* **Open**: unresolved; see [§12](#12-open-questions).

Facts marked *(verified)* were checked on Julia 1.14.0-beta1 against BufferIO 0.3.4,
unless they say Julia 1.15.0-DEV, which means a build of Julia master at commit
`70ec442ebc` (2026-11-15).

## 1. Purpose and scope
BufferIO deliberately only handles bytes (see its page "Why doesn't BufferIO support
non-`UInt8` types?"). This package provides the missing piece: encoding and decoding
primitive values to and from bytes, and loading and storing them from and to
`AbstractBufReader` / `AbstractBufWriter`.

There are three distinguishable layers:

| Layer | What | Prior art |
|-------|------|-----------|
| 0 | Decode / encode a value from / to bytes in memory | .NET `BinaryPrimitives`, Rust `u32::from_le_bytes` |
| 1 | Load / store a value from / to a buffered IO | Rust `byteorder`, Go `encoding/binary` |
| 2 | A format-agnostic data model: types map to the model, formats map the model to bytes | Rust `serde`; StructTypes.jl, StructUtils.jl |

**Decision:**
* This package covers layers 0 and 1. Layer 2 is out of scope
  ([§10](#10-relationship-to-serde)).
* It is an unregistered prototype that will eventually be folded into BufferIO
  ([§11](#11-package-name-and-home)).
* Layer 0 is the extension point, and layer 1 is generic code on top of it
  ([§3](#3-architecture-memory-level-codecs-as-the-extension-point)).

### Goals
* The encoding, including endianness, is always explicit. Host byte order is never used
  implicitly.
* No allocations. The hot path of a load is one length compare, one unaligned load,
  an optional `bswap`, and one `consume`.
* Precisely specified behaviour on EOF, truncated input, invalid bit patterns and
  too-small buffers, in the spirit of BufferIO.
* A user type implements one method per direction and gets decoding from memory, loading
  from readers and bulk loading, all at full speed.

### Non-goals
These are the guard against the package snowballing into a serde:
* Structs, strings and arrays as values. Bulk loading of primitives into arrays is in
  scope ([§7](#7-bulk-loads-and-stores)). **Decision:** structs are deferred; primitives
  only for now.
* Composite encodings. An encoding ([§2](#2-encodings)) says how *one primitive value*
  maps to bytes, never how values nest.
* Variable-length integer encodings such as LEB128. **Decision:** out of scope for now,
  although the §3 interface could express them.
* Error values carrying more than a kind, such as positions, messages or partial values
  ([§3](#failure-values)).

## 2. Encodings
**Decision:** the last argument of every function is an *encoding*: a singleton value
that says how a value maps to bytes. Endianness is one kind of encoding, and UTF-8 is
another.

```julia
abstract type Encoding end

struct LittleEndian <: Encoding end
struct BigEndian <: Encoding end
const Endianness = Union{LittleEndian, BigEndian}

const NATIVE_ENDIAN = ENDIAN_BOM == 0x04030201 ? LittleEndian() : BigEndian()

struct UTF8 <: Encoding end
```

```julia
load(io, UInt32, LittleEndian())
store(io, x, BigEndian())
try_decode(mem, Char, UTF8())
store(io, 'é', UTF8())
```

* **One extension point for everything.** Byte order and UTF-8 share all the generic
  code, and so would a future encoding such as UTF-16. There is no family of `_utf8`
  functions.
* **No silently ignored arguments.** `store(io, 'a', LittleEndian())` is a `MethodError`.
  `Char` has no byte-order encoding, so endianness can't be silently ignored, as the
  prototype did.
* **Formats can define encodings without piracy.** A format package that needs, say,
  C-style booleans ("nonzero is true") defines `struct CBool <: Encoding end` and methods
  for `(Bool, CBool)`. It owns the encoding type, so this is not type piracy. The rule:
  a codec method must be defined by the owner of either the value type or the encoding
  type.
* **The guard against snowballing:** an encoding describes one primitive value. This is
  what keeps it from turning into a serde "format".
* **Compile-time dispatch.** Encodings are singletons, resolved at compile time. Byte
  order compiles to a `bswap` or to nothing.
* **No `HostEndian`.** Code that really wants host order, e.g. for mmap or same-machine
  IPC, uses `NATIVE_ENDIAN`. That is explicit and greppable, and it is an alias of one of
  the two real cases, so it adds no new case to handle.
* **1-byte types.** Byte order is the identity for them *(verified:
  `Core.Intrinsics.bswap_int` throws for 8-bit types, so this needs a special case)*.

### Argument order and arity
**Decision:**
* The IO or memory comes first, and the encoding last, following Julia and BufferIO
  conventions.
* The encoding is **always** required. There is no two-argument `load(io, T)`, not even
  for 1-byte types, because it is too confusing to have some types need an encoding and
  others not.

### Names
**Decision:** `load` and `store` keep their names. The clash with FileIO's `load` is
accepted.

### Convenience submodules `Little` and `Big`
**Decision:**

```julia
module Little
    using ..BufferSerde: BufferSerde, LittleEndian
    try_load(io, T::Type) = BufferSerde.try_load(io, T, LittleEndian())
    load(io, T::Type) = BufferSerde.load(io, T, LittleEndian())
    store(io, x) = BufferSerde.store(io, x, LittleEndian())
    try_decode(mem, T::Type) = BufferSerde.try_decode(mem, T, LittleEndian())
    decode(mem, T::Type) = BufferSerde.decode(mem, T, LittleEndian())
    encode!(mem, x) = BufferSerde.encode!(mem, x, LittleEndian())
    # ... same for bulk functions
end
# module Big: likewise
```

Usage is `using BufferSerde.Little: load, store`, or qualified calls such as
`Little.load(io, UInt32)`. Formats that mix byte orders would use the qualified form.

* The submodule functions only forward their arguments. Users never add methods to
  them ([§3](#3-architecture-memory-level-codecs-as-the-extension-point)).
* These two-argument forms are unambiguous, because the module name states the encoding.
  They are not the two-argument `load` rejected above.

Drop the current docstring's suggestion that reader types define
`load(io::MyReader, T) = load(io, T, LittleEndian())`. It ties byte order to an IO type,
so the default silently disappears when the reader is wrapped (for example by
`expandable`), and it makes endianness implicit again.

### Endianness known only at runtime
Some formats, such as TIFF (`II`/`MM`) and pcap, determine byte order from a header. The
endianness value then has type `Union{LittleEndian, BigEndian}`. The docs should
recommend a function barrier, so that the body is specialised and branch-free:

```julia
e = magic == 0x4949 ? LittleEndian() : BigEndian()
parse_body(io, e)
```

## 3. Architecture: memory-level codecs as the extension point
**Decision (in principle), Proposal (details).** Users never add methods to `load` or
`store`. They add methods to functions that work on memory views, and this package's
generic code gets the memory view from the reader or writer. One method per direction
gives decoding from bytes, loading from any reader, and bulk loading.

### Failure values
**Decision:** failures caused by the data are returned as a small isbits value, never
thrown, and are distinguishable. A clean EOF is its own kind.

```julia
@enum DecodeErrorKind::UInt8 begin
    EndOfInput   # no bytes at all: a clean EOF
    Truncated    # the input ends partway through an encoding
    InvalidData  # the bytes are not a valid encoding
end

struct DecodeError <: Exception
    kind::DecodeErrorKind
end
```

* `DecodeError` is a 1-byte isbits struct. A `Union{T, DecodeError}` return allocates
  nothing, even when the call is not inlined *(verified)*.
* It is an `Exception`, so the throwing convenience functions throw the same value that
  the `try_` functions return.
* The kinds are non-exhaustive, like BufferIO's `IOErrorKind`.
* A loop such as "load records until EOF" reads directly:
  `r isa DecodeError && r.kind === EndOfInput && break`.

**Decision:** a macro propagates a `DecodeError` to the caller, because `@something`
doesn't work with `Union{T, DecodeError}`. Its name is **Open**; `@try_return` is used
here as a placeholder.

```julia
x = @try_return try_load(io, UInt32, LittleEndian())
# expands to
r = try_load(io, UInt32, LittleEndian())
r isa DecodeError && return r
x = r
```

It works the same on `try_decode`, whose success value is a tuple:
`(x, n) = @try_return try_decode(mem, T, enc)`. The macro only checks
`isa DecodeError`, so it doesn't care what the success type is.

### The interface
```julia
# Upper bound on the encoded size of any T in this encoding. Must be constant-foldable.
max_encoded_size(::Type{T}, ::Encoding)::Int

# Decode a T from the start of mem, treating mem as the COMPLETE input. Return the value
# and the number of bytes used, or a DecodeError.
try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::Encoding)::Union{Tuple{T, Int}, DecodeError}

# Encode x at the start of mem. Return the number of bytes written,
# or nothing if mem is too short (the only way encoding can fail).
encode!(mem::MutableMemoryView{UInt8}, x::T, ::Encoding)::Union{Nothing, Int}
```

For types covered by the bits traits ([§4](#4-the-bits-traits)) with an `Endianness`
encoding, this package provides all of these. A custom codec implements them directly.
Everything else is generic:

| Function | Layer | On a data failure |
|----------|-------|-------------------|
| `try_decode(mem, T, enc)` | 0 | returns `DecodeError` (users implement this) |
| `decode(mem, T, enc)` | 0 | throws the `DecodeError` |
| `try_load(io, T, enc)` | 1 | returns `DecodeError` |
| `load(io, T, enc)` | 1 | throws the `DecodeError` |

This follows Julia's `tryparse` / `parse` convention.

**Decision:** `decode` / `try_decode` take no offset argument. Users slice the memory
view instead, e.g. `try_decode(mem[5:end], UInt16, LittleEndian())`.

### Contract for `try_decode`
1. **Pure.** The result depends only on the contents of `mem`, and no reference to
   `mem` is kept.
2. **Bounded.** On success, `0 ≤ n ≤ min(length(mem), max_encoded_size(T, enc))`.
3. **`mem` is the complete input.** The end of `mem` is treated as the end of the data.
   An empty `mem` gives `EndOfInput`. A `mem` that ends partway through an encoding gives
   `Truncated`, unless the encoding defines a meaning for incomplete input, as UTF-8 does
   ([§8](#char)).
4. **Decided by the first `max_encoded_size(T, enc)` bytes.** If `length(mem) ≥
   max_encoded_size(T, enc)`, the result is the same for every memory that starts with
   those bytes. In other words, `try_decode` never looks further than
   `max_encoded_size(T, enc)` bytes.

Rule 4 is what lets layer 1 decode from a reader's buffer even though the buffer is not
the complete input (see below). It replaces the earlier rules ("success is
prefix-stable", "`InvalidData` is final", "`NotEnoughBytes` is honest"). Those assumed
that a decoder never needs to know where the input ends, and UTF-8 with `String`
semantics does need to know.

### Contract for `encode!`
* It must succeed if `length(mem) ≥ max_encoded_size(T, enc)`.
* It may write to `mem` beyond the returned byte count, and may write to `mem` even when
  it returns `nothing`. Those bytes are scratch space, because nothing is consumed.

### Generic reader and writer code
```julia
@inline function try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError} where {T}
    buffer = get_buffer(io)
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline _buffer_value(io, max_encoded_size(T, enc))
    end
    r = try_decode(buffer, T, enc)
    r isa DecodeError && return r
    (x, n) = r
    @inbounds consume(io, n)
    return x
end

# Buffer at least n bytes, or everything up to EOF. Either way, try_decode on the result
# gives the right answer: with n bytes, rule 4 means more bytes can't change it, and at
# EOF the buffer is the complete input. get_nonempty_buffer throws BufferTooShort if the
# reader's capacity is smaller than n.
function _buffer_value(io::AbstractBufReader, n::Int)
    buffer = get_nonempty_buffer(io, n)
    return buffer === nothing ? get_buffer(io) : buffer  # nothing: EOF before n bytes
end

function load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::T where {T}
    r = try_load(io, T, enc)
    r isa DecodeError && throw(r)
    return r
end

@inline function store(io::AbstractBufWriter, x::T, enc::Encoding) where {T}
    buffer = get_buffer(io)
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @something(
            @noinline(get_nonempty_buffer(io, max_encoded_size(T, enc))),
            throw(IOError(IOErrorKinds.BufferTooShort)),  # also when full, see §6
        )
    end
    n = encode!(buffer, x, enc)::Int  # guaranteed by the contract
    @inbounds consume(io, n)
    return n
end
```

* **Fast path.** If the buffer holds at least `max_encoded_size(T, enc)` bytes, rule 4
  makes `try_decode`'s answer final. For bits types this is a length check and an
  unaligned load. `try_decode`'s own length check repeats the precheck and LLVM removes
  it *(verified: a toy version compiles to a single compare and a single load)*.
* **Slow path: buffer `max_encoded_size(T, enc)` bytes, or up to EOF, then decode
  once.** This is just `get_nonempty_buffer(io, n)`, which already has the right
  semantics: it returns `nothing` at EOF and throws `BufferTooShort` if the reader's
  capacity is too small. A variable-length value that happens to sit in the last few bytes
  of the buffer takes the slow path even when it could be decoded from what is there.
  That happens about once per buffer refill, which is cheap.
* **Every failure is decided by one `try_decode` call,** with no retries.

The bulk functions (§7) handle an element that straddles the end of the buffer the same
way.

### Rejected for now: `bytes_needed`
**Decision (rejected for now).** A previous revision had an optional function
`bytes_needed(mem, T, enc)`: how many bytes, *given those already buffered*, must be
present before the result can't change. For an ASCII byte that is 1, while
`max_encoded_size(Char, UTF8())` is 4. The slow path filled one call at a time until
`bytes_needed` was met, instead of always filling to `max_encoded_size`.

Both approaches give the same result for every input. They differ only in how long a load
waits on a stream that is not at EOF but has no more data yet. If a peer sends one ASCII
character and then waits for a reply, filling to 4 bytes blocks until 3 more bytes arrive
or the stream closes; `bytes_needed` would return the character at once. The typical
victim would be reading single keypresses from a terminal.

That only helps if `fill_buffer` can return with fewer bytes than requested. BufferIO's
own reader doesn't *(verified)*: `BufReader`'s `fill_buffer` blocks until its whole
buffer is full, both on a libuv `Pipe` and on an `IOStream` FIFO. A peer sent 1 byte,
and `fill_buffer` was still blocked seconds later. So today, `bytes_needed` would only
help with custom readers that return early. And UTF-8 is the only variable-length encoding
in scope; for fixed-size types the two approaches are identical.

So it adds a function and a contract for no observable benefit. Adding it later is
non-breaking: an optional method whose default is `max_encoded_size` changes nothing for
existing codecs.

**Side finding for BufferIO:** because `BufReader` blocks until its buffer is full, it
can't currently be used for interactive input, such as line-by-line reading from a pipe.
A peer that sends one line and waits for a reply deadlocks with it. Terminals were not
tested. This may be worth an issue in BufferIO, independent of this package.

## 4. The bits traits
**Decision:** start with Bool-valued trait functions; redesign within 0.x if they turn
out to be too hard to extend.

The trait answers one question: *is the encoding of `T` exactly its in-memory bytes, up
to byte order?* That question splits by direction:

* **Storable as bits**: for every `x::T`, the in-memory bytes of `x` are its encoding.
  This requires an isbits type with no padding, whose layout is the wire format.
* **Loadable from bits**: in addition, every pattern of `sizeof(T)` bytes is a valid `T`
  with the intended meaning.

```julia
is_bits_storable(::Type)::Bool  # default false
is_bits_loadable(::Type)::Bool  # default false; true implies is_bits_storable
```

Rust has the same split: bytemuck's `NoUninit` / `AnyBitPattern`, and zerocopy's
`IntoBytes` / `FromBytes`.

Both require `Base.bitsizeof(T) == 8 * sizeof(T)`. Julia rounds `sizeof` up for
primitive types whose width is not a power of two: a 24-bit primitive has
`sizeof == 4` but `Base.bitsizeof == 24` *(verified)*. `Base.bitsizeof` is public in
Julia 1.14, and the comparison constant-folds *(verified)*. Generic code should check it
rather than trust the trait blindly. See [§8](#bit-widths-that-are-not-a-multiple-of-8).

* `Base.bitsizeof(Bool) == 8`, so this check does not exclude `Bool`; the trait itself
  does.
* BufferIO supports Julia 1.11, so before 1.14 a fallback is needed, e.g.
  `8 * sizeof(T)`. That is correct for all of Base's types, and narrow primitive types
  are rare that early.

When the traits are `true`, this package provides, for `Endianness` encodings:
* `max_encoded_size(T, ::Endianness) = sizeof(T)`;
* `encode!` (if storable) and `try_decode` (if loadable), using unaligned loads and
  stores ([§9](#9-performance-notes));
* `memcpy`-based bulk loads and stores ([§7](#7-bulk-loads-and-stores)).

So the traits are a shortcut for implementing the §3 interface, plus permission to use
bulk `memcpy`. A type that is storable but not loadable, such as `Bool`, implements
`try_decode` itself and gets the rest.

Contract:
* The trait is a property of the type, and must be constant-foldable.
* Only the owner of a type should define it.

Base types:

| Type | Loadable | Storable | Notes |
|------|:-:|:-:|-------|
| `Int8`–`Int128`, `UInt8`–`UInt128` | ✓ | ✓ | |
| `Float16`, `Float32`, `Float64` | ✓ | ✓ | |
| `Bool` | ✗ | ✓ | [§8](#bool) |
| `@enum` types | ✗ | ✓ | primitive, but not every bit pattern is valid *(verified)* |
| Primitives of other widths (24-bit, 29-bit, ...) | ✗ | ✗ | [§8](#bit-widths-that-are-not-a-multiple-of-8) |
| `Char` | ✗ | ✗ | encoded with `UTF8()`, [§8](#char) |
| `Ptr` | ✗ | ✗ | meaningless across processes |

## 5. Loading: semantics
```julia
try_load(io::AbstractBufReader, ::Type{T}, ::Encoding)::Union{T, DecodeError}
load(io::AbstractBufReader, ::Type{T}, ::Encoding)::T  # throws the DecodeError
```

**Decision:** `try_load` never throws because of the data, and its failures are
distinguishable. Hitting EOF, anywhere, is a property of the data, never an exception.

| Situation | Caused by | `try_load` behaviour |
|-----------|-----------|----------------------|
| Complete, valid encoding available | | return the value, consume its bytes |
| EOF with no bytes left | data | return `DecodeError(EndOfInput)`, consume nothing |
| EOF partway through an encoding | data | return `DecodeError(Truncated)`, consume nothing (UTF-8: see [§8](#char)) |
| Invalid encoding | data | return `DecodeError(InvalidData)`, consume nothing |
| The reader's buffer capacity is smaller than `max_encoded_size(T, enc)` | IO configuration | throw `IOError(BufferTooShort)` |

### All-or-nothing consumption
**Decision:** a load either consumes a whole encoding and returns a value, or consumes
nothing.

* No bytes are lost on failure. BufferIO's serde page names lost bytes as the worst
  outcome of its options 1–3.
* After any failure, the stream is exactly where it was. The caller can retry with a
  different type, skip bytes, or report the position.

### Reader capacity too small: throw
**Decision.** Only one situation throws: the reader's buffer **capacity** cannot hold
`max_encoded_size(T, enc)` bytes. EOF, including EOF partway through a value, is not this
case. *(An early draft titled this section "Short buffers" and said "throw if the IO
cannot buffer a whole value", which read as if truncated input threw. It never did.)*

Why throwing is acceptable here: with the compaction guarantee below, `fill_buffer`
returns `nothing` only when the buffer is full. `try_load` only fills while the buffer
holds fewer than `max_encoded_size(T, enc)` bytes, so the reader's capacity must be
smaller than that. That is a property of how the IO was
constructed, not of the bytes it contains.
* A reader whose capacity is at least `max_encoded_size(T, enc)` never throws, whatever
  the input. That is 16 bytes for all of Base's primitive types and 4 for UTF-8.
* `expandable(io)` rules the case out statically.

With a too-small reader, *whether* the error surfaces depends on the data. If the input
ends before the buffer fills, `try_load` returns a `DecodeError` instead. That makes it a
latent bug, like an out-of-bounds index that only some inputs hit. It doesn't make it a
data error.

**Upstream item (BufferIO):** the `fill_buffer` docs say "If the buffer is not empty,
and cannot be expanded, return `nothing`". Tighten this to: *return `nothing` only if
the buffer holds its maximum number of bytes. A reader with spare capacity must move or
compact its data instead.* Without that guarantee, a reader that does not compact could
fail depending on where in its buffer a value happens to straddle the end.

## 6. Storing
```julia
store(io::AbstractBufWriter, x, ::Encoding)::Int  # returns bytes written, like `write`
```

* A store never involves bad data, so throwing is fine for every failure.
* It is all-or-nothing too: if it throws, nothing has been consumed.
* **Decision:** if the writer can't provide `max_encoded_size(T, enc)` bytes, `store`
  throws `IOError(BufferTooShort)`. It doesn't matter whether that is because the writer
  is full or because its buffer can't grow large enough.
  * `get_nonempty_buffer(::AbstractBufWriter, n)` can't tell the two apart, and callers
    don't need it to.
  * `BufferTooShort` matches the reader side (§5), and BufferIO's description of it:
    thrown by functions that need a minimum buffer size.
  * The remedy is the same either way: use a writer with a growable buffer, e.g.
    `expandable(io)`. Full writers are probably rare in practice.

## 7. Bulk loads and stores
**Decision:** there are bulk functions at both layers, named as below.

### Between memory views (layer 0)
Copy N values of type `T` from bytes into typed memory, and back. For example, from a
`Vector{UInt8}` into a `Vector{T}`.

```julia
# Decode elements from the start of src (the complete input) into dst, until dst is full
# or the next element fails to decode. Returns (elements decoded, bytes used).
decode_into!(dst::MutableMemoryView{T}, src::ImmutableMemoryView{UInt8}, ::Encoding)::Tuple{Int, Int}

# Encode elements of src into dst until src is exhausted or dst has no room for the
# next element. Returns (elements encoded, bytes written).
encode_into!(dst::MutableMemoryView{UInt8}, src::ImmutableMemoryView{T}, ::Encoding)::Tuple{Int, Int}
```

* Both counts are returned because, for variable-length encodings, the byte count isn't
  derivable from the element count.
* The arguments should accept anything MemoryViews can view, such as `Vector`, `Memory`
  and their views, so that `decode_into!(v, bytes, LittleEndian())` works on vectors
  directly.
* Bits types use `memcpy` in native order, and otherwise a `bswap` loop. Other
  types loop over `try_decode` / `encode!`, so every codec that implements the §3
  interface gets bulk functions without further code.
* The bulk functions return counts, not a `DecodeError`. To learn why decoding stopped
  short, call `try_decode` on the remaining bytes. It gives the same answer the bulk
  function saw, and is only paid for when the caller asks.
* *(verified, Zen 4)* LLVM vectorizes the `bswap` loop: it runs at the same throughput as
  `memcpy`, about 65 GB/s in L1, 30 GB/s in L2 and 4–6 GB/s from DRAM.

### Between readers / writers and memory (layer 1)
Mirror BufferIO's `read_into!` / `read_all!`:

```julia
# Load at least one element unless dst is empty or io is EOF. Returns elements loaded.
load_into!(io::AbstractBufReader, dst::MutableMemoryView{T}, ::Encoding)::Int
# Load until dst is full or io is EOF. Returns elements loaded.
load_all!(io::AbstractBufReader, dst::MutableMemoryView{T}, ::Encoding)::Int
```

* A reader's buffer is not the complete input. So the bulk decode runs only while at
  least `max_encoded_size(T, enc)` bytes remain; for fixed-size types, that is every
  whole element in the buffer. The tail goes through `_buffer_value` from §3, one
  element at a time.
* Each element is all-or-nothing. Loading stops at the first element that fails,
  including an invalid one, and returns the count loaded so far. Nothing of the failing
  element is consumed, so a following `try_load(io, T, enc)` reports why.
* Bulk stores to a writer are the mirror image, built on `encode_into!`. Their name is
  **Open**.

## 8. Types with non-trivial encodings
### Bool
*(verified)* A pointer load of `Bool` keeps only the lowest bit: `0x02` loads as
`false`, while `0x03` and `0xff` load as `true`. That silently decodes the common C
convention ("nonzero is true") wrongly for every even byte.

**Decision:** `Bool` is bits-storable, written as `0x00` / `0x01`, but not bits-loadable.
Its `try_decode` with an `Endianness` encoding is strict: `0x00` decodes as `false`,
`0x01` as `true`, and any other byte gives `InvalidData`. Formats with C semantics can
decode a `UInt8` and test `!iszero`, or define their own encoding (§2).

### Enums
`@enum` types are bits-storable. Their `try_decode` decodes the base type and checks that
the value is a member, giving `InvalidData` otherwise. It can be implemented generically
for `T <: Enum`.

### Char
**Decision:** `Char` is encoded with `UTF8()`, the same as `String`.

```julia
try_decode(mem, Char, UTF8())::Union{Tuple{Char, Int}, DecodeError}
encode!(mem, c::Char, UTF8())::Union{Nothing, Int}
try_load(io, Char, UTF8()); load(io, Char, UTF8()); store(io, c, UTF8())
max_encoded_size(::Type{Char}, ::UTF8) = 4
```

**Decoding follows `String` iteration exactly,** including for malformed and truncated
input. `String` iteration (Base's `iterate_continued`) reads byte by byte and only looks
at the *shape* of the bytes, never at whether the resulting character is valid:

1. **The lead byte sets the maximum length:**
   * `00`–`7f` (ASCII), `80`–`bf` (a stray continuation byte) and `f8`–`ff`: 1 byte;
   * `c0`–`df`: up to 2 bytes;
   * `e0`–`ef`: up to 3 bytes;
   * `f0`–`f7`: up to 4 bytes.
2. **Each following byte is taken if it is a continuation byte** (`b & 0xc0 == 0x80`).
3. **The `Char` ends** at the first byte that is not a continuation byte, at the end of
   the input, or when the maximum length is reached. The next `Char` starts at the first
   byte not taken.

Validity is never checked. Overlong encodings, surrogates, code points above U+10FFFF and
lead bytes that are never valid in UTF-8 (`c0`, `c1`, `f5`–`f7`) all form a single
`Char` with `isvalid == false`, as long as the continuation bytes are there.

Examples *(verified)*:

| Bytes | `String` iteration yields |
|-------|---------------------------|
| `e2 82 ac` | `'€'` (3 bytes) |
| `c3 ff` | `'\xc3'` (1 byte), then `'\xff'`: `ff` is not a continuation byte |
| `e2 41` | `'\xe2'` (1 byte), then `'A'` |
| `c3 a9 80` | `'é'` (2 bytes, maximum length reached), then `'\x80'` |
| `e2 82` at end of input | `'\xe2\x82'` (2 bytes, malformed) |
| `e2` at end of input | `'\xe2'` (1 byte, malformed) |
| `f0 9f 98` at end of input | `'\xf0\x9f\x98'` (3 bytes, malformed) |
| `ff` / `80` | `'\xff'` / `'\x80'` (1 byte each) |
| `f8 80` | `'\xf8'`, then `'\x80'`: `f8` has maximum length 1 |
| `c0 80` | `'\xc0\x80'`: one `Char`, an overlong encoding, invalid |
| `e0 80 80` | `'\xe0\x80\x80'`: one `Char`, an overlong encoding, invalid |
| `ed a0 80` | `'\ud800'`: one `Char`, a surrogate, invalid |
| `f4 90 80 80` | `'\U110000'`: one `Char`, above U+10FFFF, invalid |
| `f7 bf bf bf` | `'\U1fffff'`: one `Char`, lead byte never valid in UTF-8, invalid |

Consequences:
* **`try_decode(mem, Char, UTF8())` only fails on an empty `mem`, with `EndOfInput`.**
  Every non-empty input decodes to some `Char`, so `Truncated` and `InvalidData` never
  occur. In particular, input that seems truncated at EOF does **not** give an error: it
  decodes to a malformed `Char`, as a `String` would.
* **On a reader:** `try_load(io, Char, UTF8())` buffers 4 bytes, or everything up to EOF
  if fewer remain, and then decodes once (§3).
  * With 4 bytes buffered, the result can't depend on later bytes, because a `Char` is
    at most 4 bytes.
  * At EOF, the buffer is the complete input, so `String` semantics apply directly. A
    lone `e2` at EOF decodes as `'\xe2'`.
  * With more data still coming, `e2` is never decoded alone, because 4 bytes are
    buffered first.
* **Capacity.** If the reader can't buffer 4 bytes before EOF, `try_load` throws
  `BufferTooShort`, as for every type (§5).
* **Round-tripping is not exact, intentionally.** `encode!` writes a `Char`'s code units
  as they are, but decoding only produces `Char`s that `String` iteration can produce.
  For example, `reinterpret(Char, typemax(UInt32))` encodes as `ff ff ff ff`, which
  decodes as four `'\xff'`. That is acceptable: no `String` can contain such a `Char`,
  and creating one should be discouraged.
* A strict variant that rejects malformed UTF-8 as `InvalidData` could be a separate
  encoding, e.g. `StrictUTF8()`, if needed.

### Bit widths that are not a multiple of 8
Julia 1.14 already accepts `primitive type U29 29 end` *(verified)*. Two different
things could be meant by "supporting" such a type, and they need different answers.

**1. A narrow value stored in whole bytes.** For example, a 29-bit integer stored in a
4-byte field, or 24-bit PCM audio stored in 3 bytes. **Proposal: in scope, through the
§3 interface, with no special machinery.**

How Julia handles these types *(verified)*:
* `sizeof(U24) == sizeof(U29) == 4`, and arrays use a stride of 4. So `sizeof` is the
  padded in-memory size, which need not match the wire size; a 24-bit format is usually
  3 bytes. The real width is `Base.bitsizeof` (24 and 29).
* A pointer load of `U29` loads 32 bits and truncates, silently dropping the top 3 bits.
  That is exactly the `Bool` problem.
* A pointer store zero-extends, so the padding bits written are deterministic.
* `bswap_int` throws for widths that aren't a multiple of 16.

Consequences:
* Such types are never bits-loadable or bits-storable (§4). Generic code would get the
  encoded size and the treatment of padding bits wrong.
* The type's owner implements `try_decode` / `encode!` in terms of a whole-byte integer:
  load a `UInt32`, then check or mask, and convert.

  ```julia
  max_encoded_size(::Type{U29}, ::Endianness) = 4
  function try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{U29}, e::Endianness)
      r = try_decode(mem, UInt32, e)
      r isa DecodeError && return r
      (raw, n) = r
      # Padding bits must be zero; masking them off instead is the owner's choice
      raw > 0x1fffffff && return DecodeError(InvalidData)
      return (Core.Intrinsics.trunc_int(U29, raw), n)
  end
  ```

  The owner then gets `load`, `store` and bulk functions from the generic code. The two
  choices that are genuinely format-specific stay with the owner: the wire size (3 or 4
  bytes for a 24-bit type), and whether set padding bits are invalid or ignored.
* **Decision:** no helper for `n`-byte integers in wider containers for now.

**2. Values packed at arbitrary bit offsets.** For example, a bitstream where a 29-bit
value starts at bit 3, as in Huffman-coded data, FLAC or H.264. **Proposal: out of
scope.** This doesn't fit the model:
* BufferIO consumes whole bytes, and all-or-nothing consumption (§5) has no meaning for
  half a byte.
* A bit reader has to carry a partial-byte accumulator between calls. That makes it a
  different stateful type wrapping a reader, not a function on one.

If it is ever needed, a bit reader can be built on top of this package (filling a
`UInt64` accumulator with `load`), as a separate type.

## 9. Performance notes
* The fast path is `get_buffer` plus an inlined length check. The fill loop is
  `@noinline`.
* `Union{T, DecodeError}` and `Union{Tuple{T, Int}, DecodeError}` for isbits `T` are
  isbits unions, returned without allocation *(verified, including non-inlined calls)*.
  BufferIO's caveat about pointer-ful unions before 1.14 only affects the slow path of
  `get_nonempty_buffer`.
* Every `load` pays one length check and one `consume`. For a fixed-size header of many
  fields, layer 0 lets the user pay the check once:

  ```julia
  buf = get_nonempty_buffer(io, 8)
  buf === nothing && return DecodeError(isempty(get_buffer(io)) ? EndOfInput : Truncated)
  # Integers can't be invalid and 8 bytes are buffered, so these can't fail
  (magic, _)   = decode(buf, UInt32, LittleEndian())
  (version, _) = decode(buf[5:end], UInt16, LittleEndian())
  # ...
  consume(io, 8)
  ```
* Benchmarks to write: compare against `read(::IOBuffer, UInt32)`, and against a
  hand-written `unsafe_load` + `consume`. The target is parity with the hand-written
  version.

### Unaligned loads and stores: pointers now, memory refs on Julia 1.15+
**Proposal:** implement the unaligned accesses (scalar and bulk) with
`Core.unsafe_memoryrefload` / `Core.unsafe_memoryrefstore!` where they exist, and with
`unsafe_load` / `unsafe_store!` on pointers under `GC.@preserve` otherwise.

Pointers *(verified, 1.14)*: `unsafe_load(::Ptr{T})` emits `load ..., align 1`, so
unaligned access is correct and compiles to a single instruction on x86-64 and AArch64.

Memory refs *(verified, 1.15.0-DEV)*:
* **Correct for unaligned access:** `unsafe_memoryrefload(ref, UInt32, 1, false)` on a
  `Memory{UInt8}` emits `load i32, ..., align 1`, and the store emits
  `store i32, ..., align 1`. The offset is in bytes from `ref`, and the value at offset 1
  is correct.
* **Same speed as pointers in bulk:** an unchecked `bswap` decode loop vectorizes.

  | Working set | Pointer loop (offset 0 / 1) | Memory-ref loop, unchecked (offset 0 / 1) | Memory-ref loop, bounds-checked |
  |-------------|------|------|------|
  | 16 KiB (L1) | 91.0 / 78.0 GB/s | 91.0 / 74.5 GB/s | 7.0 GB/s |
  | 1 MiB (L2) | 59.1 / 57.5 GB/s | 57.4 / 55.3 GB/s | 7.3 GB/s |

  These numbers come from a different Julia build than the 1.14 tables, so compare
  within one table only.
* **Bounds-check once, outside the loop:** with `boundscheck = true` per element, the
  loop does not vectorize and is about 13× slower. Bulk functions check lengths once, up
  front, then pass `false`.

Why switch, given no speedup:
* No `GC.@preserve` and no raw pointers. There is less unsafe code to get wrong, and the
  memory stays rooted automatically.
* It fits MemoryViews directly. A `MemoryView` stores a `MemoryRef` plus a length, so the
  ref can be used as is. The ref of an *empty* view may point anywhere, which is fine
  because every access is behind a length check.

How to select the implementation: detect the feature with
`@static if isdefined(Core, :unsafe_memoryrefload)`, not with a `VERSION` check. The
builtins are unreleased and could still be reverted or renamed. The pointer path stays as
the fallback for Julia 1.11–1.14.

### Alignment
**Proposal:** alignment is not part of the API. All loads and stores use `align 1`.
Revisit only for targets that need it, and only after benchmarking.

Measurements *(verified, x86-64 / Zen 4, Julia 1.14, single machine)*:
* **Scalar loads:** `align 1` and `align 8` loads compile to the same instruction
  (`mov rax, qword ptr [rdi]`). Declaring alignment gains nothing.
* **Bulk decode of `UInt32`,** with and without `bswap`, from a source offset by 0, 1 or
  3 bytes:

  | Working set | Aligned | Misaligned |
  |-------------|---------|------------|
  | 16 KiB (L1) | 65.5 GB/s | 56.5–58.5 GB/s |
  | 1 MiB (L2) | 30.6 GB/s | 30.1–30.3 GB/s |
  | 64 MiB (DRAM) | 4.2–5.2 GB/s | 4.3–6.3 GB/s (noise) |

  Misalignment only costs about 11%, and only when the data is already in L1.

Why an alignment guarantee would buy little:
* **The cost is the address, not the instruction.** On x86-64 and AArch64, unaligned
  load instructions run at full speed on aligned addresses. The roughly 11% above comes
  from loads that really do cross cache lines. Promising alignment therefore can't speed
  up data that is already aligned; only the data actually being aligned helps, and the
  hardware already rewards that.
* **IO buffers can't promise it.** Where a value starts in a reader's buffer depends on
  everything consumed before it. After an odd-sized field, every later value is
  misaligned, and `BufReader` may compact its data to any offset. An alignment guarantee
  could only cover the start of a user-supplied memory view at layer 0.
* **Julia already aligns fresh arrays.** A fresh `Vector{UInt8}` was 64-byte aligned in
  the test above, so bulk functions on whole arrays usually see aligned data anyway.

Where alignment does matter: on strict-alignment targets, such as RISC-V without fast
unaligned access, LLVM splits `align 1` loads into byte loads. If that becomes relevant,
the cheap fix needs no API change: one runtime check per bulk call selects a loop
compiled with `align = sizeof(T)`.

A bigger speedup than alignment is skipping the copy altogether, by viewing bytes in
native order as a typed array. That ties the lifetime of the typed view to the IO's
buffer, so it is out of scope for now.

## 10. Relationship to serde
**Decision:** serde is out of scope.

* Rust's `serde` core knows nothing about bytes or endianness. `Serialize` maps a type
  into serde's data model, and a `Serializer` (a format) maps that model to output.
  Whether an `i32` becomes 4 little-endian bytes, a varint or decimal text is the
  format's decision. Code like this package is something binary *format implementations*
  use internally.
* The two meet in only two places:
  * Binary formats would use this package's codecs.
  * Bulk data: a serde could use the bits traits to `memcpy` whole arrays. Rust's serde
    lacks this, which is why `serde_bytes` exists.
* The closest Julia prior art for layer 2 is StructTypes.jl and StructUtils.jl.
* Encodings (§2) are the part of this design closest to serde's "formats". The rule that
  an encoding describes a single primitive value is what keeps them apart.

## 11. Package name and home
**Decision:**
* This is a separate package, **not registered** in General. It exists so the design can
  be prototyped and iterated on quickly, without BufferIO releases.
* Once the design is stable, it will be **folded into BufferIO**.
* It keeps the name **BufferSerde**. The name matters little for a temporary package.

Consequences for the design:
* **Names are chosen as BufferIO names.** Every public name (`load`, `store`,
  `try_decode`, `encode!`, `load_into!`, `LittleEndian`, `UTF8`, ...) should read well
  and not clash as a BufferIO export. They should also fit BufferIO's existing naming:
  `read_into!` / `read_all!` are mirrored by `load_into!` / `load_all!`.
* **The upstream item in §5 becomes an internal change** once the code is folded
  in. Until then, it can be prototyped here against BufferIO's documented behaviour.
* **Error kinds.** While separate, this package defines its own `DecodeError` (§3),
  because it can't add kinds to BufferIO's `IOErrorKind`. After folding in, `DecodeError`
  could merge into `IOError`:
  * `EndOfInput` maps to the existing `EOF`;
  * `Truncated` and `InvalidData` become new kinds.

  That requires `IOError` to stay isbits, which it is today (a single `UInt8` enum
  field).
* **Julia version.** BufferIO supports Julia 1.11, so the design must not require newer
  features without a fallback: `Base.bitsizeof` (1.14, §4) and the memory-ref builtins
  (1.15, §9).
* **Breaking changes are free** while the package is unregistered. That is the reason to
  try the simple Bool-valued traits first (§4).

## 12. Open questions
1. **The name of the error-propagating macro** (§3); `@try_return` is a placeholder.
2. **The name of the bulk store to a writer** (§7), e.g. `store_all`.
3. **Upstream BufferIO item:** the `fill_buffer` compaction guarantee (§5).

## Appendix A: state of the prototype (2026-11-15)
Problems found while reviewing `src/BufferSerde.jl`. Most become moot with the
architecture in §3; they are listed so none survive a rewrite.

* **The package does not precompile:** `_load_into_slowpath!` (line 292) uses `T`
  without `where {T}`.
* Missing imports: `fill_buffer`, `grow_buffer`, `IOError`, `IOErrorKinds`. Also,
  `get_minimum_buffer` no longer exists in BufferIO; it is now
  `get_nonempty_buffer(io, n)`.
* `[compat]` is stale: it lists BufferIO `0.2.5` and MemoryViews `0.4.1`. BufferIO is now
  at 0.3.4 and uses MemoryViews 0.5.
* `byte_order` calls `bswap_int` on 1-byte types, which throws, so
  `store(io, Int8(1), BigEndian())` fails on little-endian hosts.
* `_load_slower_path`:
  * treats `HostEndian` as big-endian;
  * returns the wrong result on big-endian hosts;
  * calls `zext_int(T, 0x00)`, which is invalid for 1-byte `T`.
* `load(io::AbstractBufWriter, ::Type{UInt8})` should take a reader, and it does not
  consume the byte.
* `_load_into!`:
  * `memlen < sz` compares an element count with a byte count;
  * it errors instead of filling when the buffer holds less than one element.
* The `PrimitiveSerialization` docstring refers to `ReadablePrimitive` and
  `NonReadablePrimitive`, which do not exist.
* Pointer-loading `Bool` keeps only the lowest bit ([§8](#bool)).
* `store(io, ::Char, ::Endianness)` silently ignores its endianness argument
  ([§2](#2-encodings)).
