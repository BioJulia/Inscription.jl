# Dogfooding feedback: decisions

## Done

* `@inbounds` on `try_decode`, `decode` and `encode!`. The caller guarantees that `i ≥ 1`
  and that at least `max_encoded_size(T, enc)` bytes remain from `i`. Checks that the
  bytes are valid data are never skipped, and neither are the checks of hand-written
  codecs.
* An index argument: `try_decode(mem, i, T, enc)`, `decode(mem, i, T, enc)` and
  `encode!(mem, i, x, enc)`, equivalent to using `mem[i:end]`. `i` must be in
  `1:length(mem)+1`, otherwise a `LightBoundsError` is thrown.

## Decided, not yet implemented

### `encode!` throws; the current one becomes `try_encode!`

* `try_encode!(mem, [i,] x, enc)::Union{Int, Nothing}` is the current `encode!`.
* `encode!(mem, [i,] x, enc)::Int` throws a `LightBoundsError` if the encoding doesn't
  fit in `mem`.
  * A short buffer is the caller's mistake, not bad data, so it gets a bounds error and
    not a `DecodeError`. It also isn't an `IOError`, since no IO happens.
  * The `@inbounds` of `encode!` then skips a check that throws a bounds error, which is
    the usual use of `@boundscheck`. Only `try_encode!` and `try_decode` skip
    checks that would return a value instead of throwing.
  * The error holds no reference to `mem`, so the error branch doesn't make `mem` escape.
  * The requested indices in the error: `i:(i + n - 1)` for bits types, where `n` is the
    encoded size. A hand-written codec only says that the encoding didn't fit, so for
    those, report `i:(length(mem) + 1)`: the encoding needed at least one more byte.
* `encode!` still returns the number of bytes written. A return value can simply be
  ignored, so it doesn't cause the boilerplate that a tuple does.

### `decode` returns only the value; `decode_next` returns the next index too

```julia
decode(mem, [i,] T, enc)::T
try_decode(mem, [i,] T, enc)::Union{T, DecodeError}

decode_next(mem, i, T, enc)::Tuple{T, Int}                         # (value, next index)
try_decode_next(mem, i, T, enc)::Union{Tuple{T, Int}, DecodeError}
```

* The short names return only the value, as `load` and `try_load` already do.
* The `_next` functions only exist with an index, so returning the next index is natural,
  and walking a buffer reads like `iterate`:
  `(c, i) = decode_next(mem, i, Char, UTF8())`.
* Rejected: returning only `T` for bits types and `Tuple{T, Int}` for other codecs.
  Whether the size is fixed doesn't follow from the kind of codec: the `U29` test type
  has a hand-written codec, but is always 4 bytes. Generic code would have to handle both
  forms, and changing a type between `bits_kind` and a hand-written codec would break its
  users.
* The byte count can't in general be recovered from the value, so `_next` is needed.
  For example, in LEB128, `0x80 0x00` decodes to `0` using 2 bytes, but `0` is encoded
  in 1.
* No change for codec authors: `codec_try_decode` still returns `(x, n)`.
* Both changes are breaking, which is fine before the first release.

## Decided: opt-in support for isbits structs, and a new `is_valid_bits`

### Current state

Structs are not supported. `codec_kind` requires `isprimitivetype(T)`, so for a struct,
`bits_kind` is silently ignored and every function throws a `MethodError`. The test suite
checks this with the `Wrapped` type. Today, users must write a codec by hand, by calling
`try_decode` for each field.

### Opt-in, using the existing traits; no default codecs

* The author of a struct opts in by declaring `bits_kind(::Type{T})` to be `BitsLoadable()`
  or `BitsStorable()`, as for a primitive type. The package provides no codecs for
  structs that don't opt in, and none for tuples.
  * Encoding every isbits struct automatically would make its fields, which are private,
    into a wire format that its owner never promised.
  * Decoding skips the constructors of `T`, so only the owner can promise that this is
    valid.
* Declaring one of these traits on a type that is neither a primitive type nor an isbits
  struct throws an error, instead of being silently ignored as now. The `Wrapped` test
  changes accordingly.

### Byte order is applied to each field

With a non-native `Endianness`, the bytes of each field are swapped, recursing into nested
structs, and the order of the fields is kept. Swapping the struct as a whole would also
reverse the order of the fields.

Since structs that opt in have no padding (see below), the encoding is the memory layout
with each field's bytes swapped. With native byte order, it is exactly the memory layout,
so single values and arrays are copied with `memcpy`.

### No padding, enforced

A struct whose `bits_kind` is `BitsLoadable` or `BitsStorable` must not have padding. The
package checks this, and doesn't just advise it:

* The author can't reliably check it themselves, because the layout depends on the Julia
  version. Checked on this machine: in `Tuple{Int64, Int128}`, the `Int128` field is at
  offset 8 on Julia 1.11 (size 24, no padding) and at offset 16 on 1.12 (size 32, 8 bytes
  of padding). A struct that was correctly declared on 1.11 would silently change its
  wire format on 1.12. With the check, it throws an error instead.
* Padding bytes contain leftover memory, which encoding would write to the output.

The check only applies to types whose `bits_kind` is `BitsLoadable` or `BitsStorable`;
structs that don't opt in are never checked. It depends only on the type, and must be
constant-foldable, like `enum_range`:

* Each primitive field fills its bytes: `bit_size(F) == 8 * sizeof(F)`.
* Each struct field passes the same check, recursively.
* The sizes of the fields add up to `sizeof(T)`.

If the check fails, the codec of `T` is an unconditional throw.

A primitive type whose bit width isn't a multiple of 8, like `primitive type Foobar 60 end`,
therefore can't be a field of a `BitsLoadable` or `BitsStorable` struct: in memory, it
takes 8 bytes but uses only 60 bits. It can still be a field of any other struct, whose
hand-written codec decodes it with `try_decode(mem, i, Foobar, enc)` like any other
field.

Odd-width primitive types on their own are unaffected. `Foobar` is encoded in
`cld(60, 8) = 8` bytes, holding the value zero-extended: encoding writes the 4 unused
bits as zero, so no leftover memory is written, and decoding returns `InvalidData` if any
of them is set. To document: this is the only layout supported. Formats that store such
values in some other way, e.g. packed at the bit level or left-aligned, need a hand-written
codec, like the `U29` test type.

### `is_valid_bits` takes the bytes as `NTuple{N, UInt8}`

```julia
is_valid_bits(::Type{T}, bytes::NTuple{N, UInt8})::Bool
```

This replaces `is_valid_bits(::Type{T}, raw::Unsigned)`.

* `N` is the number of bytes that are loaded, `cld(bitsizeof(T), 8)`, and not
  `sizeof(T)`. For structs, the padding rule makes the two equal.
  `reinterpret` uses the size without padding: on Julia 1.14,
  `reinterpret(U24, ::NTuple{4, UInt8})` throws, but `NTuple{3, UInt8}` works.
* The bytes are in **native memory order**: the byte order of the encoding has already been
  undone, so `bytes == reinterpret(NTuple{N, UInt8}, x)` for the value `x` being decoded.
  * If the bit width of `T` is a multiple of 8, `reinterpret(T, bytes)` gives the value.
    This is true for structs that opt in, by the padding rule.
  * Otherwise, e.g. for a 60-bit type, `reinterpret` throws ("non-byte-aligned primitive
    fields"). The bytes are then the value zero-extended to `N` bytes, and the package
    has already checked that the unused bits are zero.
* Converting to an integer is free: `reinterpret(UInt16, bytes)` compiles to a single
  `i16` load, so checks like the range check of `Enum` stay as fast as now. To verify
  when implementing, by benchmarking decoding of `Bool` and `Enum` before and after.
* A new public helper, `BufferSerde.as_unsigned(bytes::NTuple{N, UInt8})`, returns the
  smallest unsigned integer of at least `N` bytes, holding the bytes zero-extended in
  native order. It works for every `N`, including those without an integer of exactly
  `N` bytes, e.g. a 44-bit type with `N = 6`, or a 24-bit type with `N = 3`. So authors
  never have to deal with the byte order of the host.
* The 128-bit limit of `raw_type` goes away, so wide `BitsStorable` types, like the
  `S144` test type, become supported. `raw_type` itself can be removed.

### The fields of a struct are checked by the package

`reinterpret` doesn't check validity: `reinterpret(S, bytes)` with `0x03` in the byte of a
`Bool` field succeeds, and an invalid `Bool` is undefined behaviour. So, when decoding a
`BitsStorable` struct:

1. The package calls `is_valid_bits` of each `BitsStorable` field on that field's bytes,
   recursing into nested structs.
2. Then the package calls `is_valid_bits` of the struct itself, for invariants that involve
   the whole value. At this point, all fields are valid, so the author can safely
   `reinterpret(T, bytes)` and check the value as a normal Julia object.

As a consequence:

* A `BitsLoadable` struct must have only `BitsLoadable` fields. This is enforced along with
  the padding rule, since `BitsLoadable` promises that every bit pattern is valid.
* A struct with a field that has invalid bit patterns, e.g. a `Bool`, must be
  `BitsStorable`. If it has no invariants of its own, its check is
  `is_valid_bits(::Type{S}, bytes) = true`.
