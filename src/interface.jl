"""
    max_encoded_size(::Type{T}, enc::Encoding)::Int

Upper bound on the number of bytes of any encoding of a value of type `T` with `enc`.

Do not add methods to this function. Implement a codec instead, see [`Encoding`](@ref).

# Examples
```jldoctest
julia> max_encoded_size(UInt32, LittleEndian())
4

julia> max_encoded_size(Char, UTF8())
4
```
"""
@inline function max_encoded_size(::Type{T}, enc::Encoding)::Int where {T}
    return if codec_kind(T, enc) isa Opaque
        codec_max_encoded_size(T, enc)
    else
        bits_encoded_size(T)
    end
end

"""
    try_encoded_size(x::T, enc::Encoding)::Union{Int, EncodeError}

Return the number of bytes of the encoding of `x` with `enc`, or an
[`EncodeError`](@ref) of kind `InvalidValue` if `x` can't be encoded with `enc`.

The size is exactly the number of bytes that [`try_encode!`](@ref) writes for `x`, and is
at most [`max_encoded_size(T, enc)`](@ref max_encoded_size). Since `x` is not encoded,
this is the way to check whether it can be, or to find the size of a buffer to encode
it into.

Do not add methods to this function. Implement a codec instead, see [`Encoding`](@ref).

See also: [`encoded_size`](@ref)

# Examples
```jldoctest
julia> try_encoded_size(0x0102, BigEndian())
2

julia> try_encoded_size('€', UTF8())
3
```
"""
@inline function try_encoded_size(x::T, enc::Encoding)::Union{Int, EncodeError} where {T}
    return if codec_kind(T, enc) isa Opaque
        codec_try_encoded_size(x, enc)
    else
        bits_encoded_size(T)
    end
end

"""
    encoded_size(x::T, enc::Encoding)::Int

Like [`try_encoded_size`](@ref), but throw the [`EncodeError`](@ref) instead of
returning it.

# Examples
```jldoctest
julia> encoded_size('a', UTF8())
1
```
"""
@inline function encoded_size(x, enc::Encoding)::Int
    result = try_encoded_size(x, enc)
    result isa EncodeError && throw_encode_error(result)
    return result
end

"""
    try_decode(mem, [i::Integer,] ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Decode a `T` from `mem`, starting at index `i` (default: 1).
Return the value, or a [`DecodeError`](@ref).
`mem` is converted to `ImmutableMemoryView{UInt8}`.

The result is the same as decoding from `mem[i:end]`, but without creating the slice.
`i` must be in `1:length(mem)+1`, or a `LightBoundsError` is thrown.

To also get the index after the encoding, e.g. for types whose encodings vary in size,
use [`try_decode_next`](@ref). Bytes after the encoding are ignored. To require that the
encoding ends at the end of `mem`, use [`try_decode_exact`](@ref).

The error kind is:
* `EndOfInput` if no bytes remain, unless a `T` can be encoded in zero bytes;
* `Truncated` if `mem` ends partway through an encoding;
* `InvalidData` if the bytes are not a valid encoding.

Do not add methods to this function. Implement a codec instead, see [`Encoding`](@ref).

See also: [`decode`](@ref), [`try_load`](@ref)

# Examples
```jldoctest
julia> try_decode(MemoryView([0x01, 0x02, 0x03]), UInt16, LittleEndian())
0x0201

julia> try_decode(MemoryView([0x01, 0x02, 0x03]), 2, UInt16, LittleEndian())
0x0302

julia> try_decode(MemoryView([0x01]), UInt16, LittleEndian())
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)

julia> try_decode(MemoryView([0x02]), Bool, LittleEndian())
DecodeError(BitScribbling.DecodeErrorKinds.InvalidData)
```
"""
@inline function try_decode(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Union{T, DecodeError} where {T}
    (x, _) = @? try_decode_sized(mem, Int(i)::Int, T, enc)
    return x
end

@inline function try_decode(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return try_decode(mem, 1, T, enc)
end

"""
    decode(mem, [i::Integer,] ::Type{T}, enc::Encoding)::T

Like [`try_decode`](@ref), but throw the [`DecodeError`](@ref) instead of returning it.
`mem` is converted to `ImmutableMemoryView{UInt8}`.

In `@inbounds` context, the caller must guarantee that `i ≥ 1`, and that at the `MemoryView`
has at least length `length(mem) ≥ i - 1 + max_encoded_size(T, enc)`.

See also: [`decode_next`](@ref)

# Examples
```jldoctest
julia> decode(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian())
0x0102

julia> decode(MemoryView([0x01, 0x02, 0x03]), 2, UInt16, BigEndian())
0x0203

julia> decode(MemoryView(UInt8[]), UInt16, BigEndian())
ERROR: DecodeError: End of input: no bytes left to decode
[...]
```
"""
Base.@propagate_inbounds function decode(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::T where {T}
    # Calls `try_decode_sized` directly, so that `@inbounds` reaches its checks
    result = try_decode_sized(mem, Int(i)::Int, T, enc)
    result isa DecodeError && throw_decode_error(result)
    return first(result)
end

Base.@propagate_inbounds function decode(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return decode(mem, 1, T, enc)
end

"""
    try_decode_next(mem, i::Integer, ::Type{T}, enc::Encoding)::Union{Tuple{T, Int}, DecodeError}

Like [`try_decode`](@ref), but return the value together with the index after its
encoding, which is where the next value starts.
`mem` is converted to `ImmutableMemoryView{UInt8}`.

This is meant for decoding a sequence of values, in particular of types whose encodings
vary in size, such as `Char` with [`UTF8`](@ref). Like `try_decode`, it ignores
`@inbounds`.

# Examples
```jldoctest
julia> mem = MemoryView("aé");

julia> try_decode_next(mem, 1, Char, UTF8())
('a', 2)

julia> try_decode_next(mem, 2, Char, UTF8())
('é', 4)

julia> try_decode_next(mem, 4, Char, UTF8())
DecodeError(BitScribbling.DecodeErrorKinds.EndOfInput)
```
"""
@inline function try_decode_next(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    i = Int(i)::Int
    (x, n) = @? try_decode_sized(mem, i, T, enc)
    return (x, i + n)
end

"""
    decode_next(mem, i::Integer, ::Type{T}, enc::Encoding)::Tuple{T, Int}

Like [`try_decode_next`](@ref), but throw the [`DecodeError`](@ref) instead of returning
it. `mem` is converted to `ImmutableMemoryView{UInt8}`.

Supports `@inbounds` in the same way as [`decode`](@ref).

# Examples
```jldoctest
julia> function decode_chars(mem::MemoryView{UInt8})
           chars = Char[]
           i = 1
           while i ≤ length(mem)
               (c, i) = decode_next(mem, i, Char, UTF8())
               push!(chars, c)
           end
           return chars
       end;

julia> decode_chars(MemoryView("a€!"))
3-element Vector{Char}:
 'a': ASCII/Unicode U+0061 (category Ll: Letter, lowercase)
 '€': Unicode U+20AC (category Sc: Symbol, currency)
 '!': ASCII/Unicode U+0021 (category Po: Punctuation, other)
```
"""
Base.@propagate_inbounds function decode_next(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Tuple{T, Int} where {T}
    i = Int(i)::Int
    # Calls `try_decode_sized` directly, so that `@inbounds` reaches its checks
    result = try_decode_sized(mem, i, T, enc)
    result isa DecodeError && throw_decode_error(result)
    (x, n) = result
    return (x, i + n)
end

"""
    try_decode_exact(mem, [i::Integer,] ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Like [`try_decode`](@ref), but the bytes from `i` (default: 1) to the end of `mem` must
be exactly one encoding of a `T`. If the encoding ends before the end of `mem`, return a
[`DecodeError`](@ref) of kind `TrailingData`.

This function is useful when you need *a priori* information to determine when the
encoding ends. For example, when decoding the decimal string `"12"` to a `UInt8`,
this could be the concatenated encodings for `0x01`, then `0x02`, or the encoding
of `UInt8(12)`.

See also [`try_load_exact`](@ref).

# Examples
```jldoctest
julia> try_decode_exact(MemoryView([0x01, 0x02]), UInt16, BigEndian())
0x0102

julia> try_decode_exact(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian())
DecodeError(BitScribbling.DecodeErrorKinds.TrailingData)

julia> try_decode_exact(MemoryView([0x01, 0x02, 0x03]), 2, UInt16, BigEndian())
0x0203

julia> try_decode_exact(MemoryView([0x01]), UInt16, BigEndian())
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)
```
"""
@inline function try_decode_exact(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Union{T, DecodeError} where {T}
    i = Int(i)::Int
    (x, n) = @? try_decode_sized(mem, i, T, enc)
    # `try_decode_sized` checked that `i` is valid and that `n` bytes remain from it
    n == length(mem) - i + 1 || return DecodeError(TrailingData)
    return x
end

@inline function try_decode_exact(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return try_decode_exact(mem, 1, T, enc)
end

"""
    decode_exact(mem, [i::Integer,] ::Type{T}, enc::Encoding)::T

Like [`try_decode_exact`](@ref), but throw the [`DecodeError`](@ref) instead of returning
it. Supports `@inbounds` in the same way as [`decode`](@ref).

# Examples
```jldoctest
julia> decode_exact(MemoryView("é"), Char, UTF8())
'é': Unicode U+00E9 (category Ll: Letter, lowercase)

julia> decode_exact(MemoryView("éa"), Char, UTF8())
ERROR: DecodeError: Trailing data: the input continues after the encoded value
[...]
```
"""
Base.@propagate_inbounds function decode_exact(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::T where {T}
    i = Int(i)::Int
    # Calls `try_decode_sized` directly, so that `@inbounds` reaches its checks
    result = try_decode_sized(mem, i, T, enc)
    result isa DecodeError && throw_decode_error(result)
    (x, n) = result
    n == length(mem) - i + 1 || throw_decode_error(DecodeError(TrailingData))
    return x
end

Base.@propagate_inbounds function decode_exact(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return decode_exact(mem, 1, T, enc)
end

# Decode a T from `mem[i:end]`, and return it with the number of bytes used, or a
# `DecodeError`. The public decoding functions are built on this. They convert their
# index argument to an `Int`, so the internal functions only handle `Int` indices.
# Its checks are in `@boundscheck` blocks, so an `@inbounds` in a caller that propagates
# it, such as `decode`, skips them. The `try_` functions don't propagate it.
@inline function try_decode_sized(
        mem::MemoryView{UInt8}, i::Int, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    kind = codec_kind(T, enc)
    if kind isa Opaque
        @boundscheck check_start_index(mem, i)
        return call_codec_try_decode(unsafe_suffix(ImmutableMemoryView(mem), i), T, enc)
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return DecodeError(i > length(mem) ? EndOfInput : Truncated)
    end
    x = @? unsafe_decode_bits(kind, mem, i - 1, T, enc)
    return (x, n)
end

"""
    try_encode!(mem, [i::Integer,] x::T, enc::Encoding)::Union{Int, EncodeError}

Encode `x` into `mem`, starting at index `i` (default: 1).
Return the number of bytes written, or an [`EncodeError`](@ref).
`mem` is converted to a `MutableMemoryView{UInt8}`.

The error kind is:
* `InsufficientSpace` if the bytes from `i` to the end of `mem` are too few for the
  encoding of `x`. Then, nothing is written.
* `InvalidValue` if `x` can't be encoded with `enc`. Then, the bytes from `i` up to
  [`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes later, but not beyond the
  end of `mem`, may have been written, and their contents are unspecified.

On success, only the bytes of the encoding are written, no extra bytes.

Do not add methods to this function. Implement a codec instead, see [`Encoding`](@ref).

See also: [`encode!`](@ref), [`store`](@ref)

# Examples
```jldoctest
julia> v = zeros(UInt8, 3);

julia> try_encode!(MemoryView(v), 0x0102, BigEndian()), v
(2, UInt8[0x01, 0x02, 0x00])

julia> try_encode!(MemoryView(v), 2, 0x0304, BigEndian()), v
(2, UInt8[0x01, 0x03, 0x04])

julia> try_encode!(MemoryView(v), 0x01020304, BigEndian()) # too short
EncodeError(BitScribbling.EncodeErrorKinds.InsufficientSpace)
```
"""
@inline function try_encode!(
        mem::MutableMemoryView{UInt8}, i::Integer, x, enc::Encoding
    )::Union{Int, EncodeError}
    return _try_encode!(mem, Int(i)::Int, x, enc)
end

@inline function try_encode!(mem::MutableMemoryView{UInt8}, x, enc::Encoding)
    return _try_encode!(mem, 1, x, enc)
end

# The implementation of `try_encode!`. Its checks are in `@boundscheck` blocks, so an
# `@inbounds` in a caller that propagates it, such as `encode!`, skips them.
# `try_encode!` doesn't propagate it.
@inline function _try_encode!(
        mem::MutableMemoryView{UInt8}, i::Int, x::T, enc::Encoding
    )::Union{Int, EncodeError} where {T}
    if codec_kind(T, enc) isa Opaque
        @boundscheck check_start_index(mem, i)
        return call_codec_try_encode!(unsafe_suffix(mem, i), x, enc)
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return EncodeError(InsufficientSpace)
    end
    unsafe_encode_bits!(mem, i - 1, x, enc)
    return n
end

"""
    encode!(mem, [i::Integer,] x::T, enc::Encoding)::Int

Like [`try_encode!`](@ref), but throw instead of returning an [`EncodeError`](@ref):
* When the bytes from `i` to the end of `mem` are too few, throw a `LightBoundsError`.
* When `x` can't be encoded, throw the `EncodeError` of kind `InvalidValue`.

As for `try_encode!`, if both apply, either may be thrown.

`i` must be in `1:length(mem) - `max_encoded_size(T, enc)` + 1`.

# Examples
```jldoctest
julia> v = zeros(UInt8, 3);

julia> encode!(MemoryView(v), 2, 0x0102, BigEndian()), v
(2, UInt8[0x00, 0x01, 0x02])

julia> encode!(MemoryView(v), 2, 0x01020304, BigEndian())
ERROR: LightBoundsErrors.LightBoundsError: out-of-bounds indexing: `collection[2:5]`, where:
[...]
```
"""
Base.@propagate_inbounds function encode!(
        mem::MutableMemoryView{UInt8}, i::Integer, x::T, enc::Encoding
    )::Int where {T}
    i = Int(i)::Int
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks
    result = _try_encode!(mem, i, x, enc)
    result isa EncodeError && throw_encode_failure(mem, i, T, enc, result)
    return result
end

Base.@propagate_inbounds function encode!(mem::MutableMemoryView{UInt8}, x, enc::Encoding)
    return encode!(mem, 1, x, enc)
end

# Throw the error of `encode!` for `err`, returned when encoding a T at the valid start
# index `i`. For lack of space, that is a `LightBoundsError`. A hand-written codec doesn't
# say how many bytes it needed, but at least one more byte than `mem` has.
# Inlined for the same reason as `check_start_index`.
@inline function throw_encode_failure(
        mem::MemoryView, i::Int, ::Type{T}, enc::Encoding, err::EncodeError
    ) where {T}
    err.kind === InsufficientSpace || throw_encode_error(err)
    stop = if codec_kind(T, enc) isa Opaque
        length(mem) + 1
    else
        i + bits_encoded_size(T) - 1
    end
    return @inline throw_lightboundserror(mem, i:stop)
end

# Whether `i` is a valid start index of `mem`, and at least n bytes remain from it.
# For i ≥ 1, `length(mem) - i + 1` can't overflow.
@inline has_bytes(mem::MemoryView, i::Int, n::Int) = i ≥ 1 && length(mem) - i + 1 ≥ n

# Throw a `LightBoundsError` unless `i` is in `1:length(mem)+1`, the start indices of
# `mem[i:end]`. Unlike a `BoundsError`, the error holds no reference to `mem`, so the
# error branch doesn't make `mem` escape. Otherwise, the caller would also have to set up
# a GC frame for `mem`, on the fast path too, e.g. when it created `mem` from a `Vector`.
# The `@inline` keeps `mem` from being passed to a non-inlined function.
@inline function check_start_index(mem::MemoryView, i::Int)
    ((i - 1) % UInt) > (length(mem) % UInt) && @inline throw_lightboundserror(mem, i)
    return nothing
end

# `mem[i:end]`, without checking that `i` is in `1:length(mem)+1`.
# Unlike slicing, this returns `mem` itself for i == 1, which is constant-folded.
@inline unsafe_suffix(mem::MemoryView, i::Int) = last(@inbounds split_at(mem, i))

"""
    codec_max_encoded_size(::Type{T}, ::E)::Int

Get maximum number of bytes which an instance of `T` can be encoded into
in the encoding `E`.

Adding a method to this function is mandatory to implement when manually implementing a
codec.
Storing into `AbstractBufWriter` buffers this many bytes before encoding.
Loading from `AbstractBufReader` buffers this many bytes before decoding, unless
the codec implements [`codec_bytes_needed`](@ref).

It should not be called directly. Call [`max_encoded_size`](@ref) instead.
"""
function codec_max_encoded_size end

"""
    codec_try_encoded_size(x::T, ::E)::Union{Int, EncodeError}

Compute the number of bytes in the encoding of `x`, in an `E <: Encoding`,
or an error if `x` cannot be encoded into E.

Adding a method to this function is mandatory to implement when manually implementing a
codec.
An implementation must follow this contract:
* It agrees with [`codec_try_encode!`](@ref): it returns a size exactly when `codec_try_encode!`
  can encode `x`, and the size is the byte count that `codec_try_encode!` returns.
* It returns no other error kind than `InvalidValue`.
"""
function codec_try_encoded_size end

"""
    codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E
    )::Union{Tuple{T, Int}, DecodeError}

Decode a `T` from the start of `mem`, an return it along with the number of bytes
decoded, or return a [`DecodeError`](@ref) on error.

Adding a method to this function is mandatory to implement when manually implementing a
codec.
It should not be called directly. Decoding methods call this implicitly.

An implementation should have the following properties:
* It should be pure, in the sense that the result should depend only at most the `n`
  bytes read, where `n` is the number returned from the function.
* On success, `0 ≤ n ≤ min(length(mem), max_encoded_size(T, enc))`.

The errors returned should have the following [`DecodeErrorKind`](@ref):
* An empty `mem` gives `EndOfInput`, unless the `T` is decoded from zero bytes.
* Otherwise, a too short `mem` should return `Truncated`.

`mem` may have any length, including zero, and may not contain a full `T`.

To index `mem` without bounds checks, check its length once, then use `@inbounds`. For
example, for a 24-bit unsigned integer `U24` below:

```julia
struct U24
    x::UInt32
end

@inline function BitScribbling.codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{U24}, ::BigEndian
    )
    isempty(mem) && return DecodeError(DecodeErrorKinds.EndOfInput)
    length(mem) < 3 && return DecodeError(DecodeErrorKinds.Truncated)
    x = @inbounds (UInt32(mem[1]) << 16) | (UInt32(mem[2]) << 8) | UInt32(mem[3])
    return (U24(x), 3)
end
```
"""
function codec_try_decode end

"""
    codec_bytes_needed(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)::Int

Compute the 

Optional extension point of a hand-written codec for the value type `T` and the concrete
encoding type `E`, see [`Encoding`](@ref). Never call it directly.

`mem` holds the bytes that are available so far: the start of the input, but not
necessarily all of it. Return the number of bytes `k` from the start of the input that
decide the result of [`codec_try_decode`](@ref):
* If `k ≤ length(mem)`, the result is decided: `codec_try_decode` returns the same for
  every memory that starts with the first `k` bytes of `mem`, whether more bytes follow
  or not.
* Otherwise, it is not decided yet, and at least `k` bytes are needed in total, unless
  the input ends before that.

Since `k` is the number of bytes that decide the result, it may be larger than the
encoding: for example, the decimal encoding of an integer is only decided by the byte
after its last digit. By rule 4 of `codec_try_decode`, the first
`max_encoded_size(T, enc)` bytes always decide the result, so `k` must be at most that.
Like `codec_try_decode`, the result must depend only on the contents of `mem`, and no
reference to `mem` may be kept.

When fewer than `max_encoded_size(T, enc)` bytes are buffered, [`try_load`](@ref) and
[`load_into!`](@ref) use this to wait only for the bytes that decide the next value.
Otherwise, they wait until `max_encoded_size(T, enc)` bytes are buffered, or the input
ends. This matters when more input may not arrive until the value has been used, e.g.
for the last value of a request on a socket, or a key press on a terminal.

The default method returns `max_encoded_size(T, enc)`, which is always correct.

The contract is not checked. Breaking it can't make loading memory-unsafe, but loads may
then return wrong results, or wait for more bytes than needed.
"""
function codec_bytes_needed(mem, ::Type{T}, enc::Encoding) where {T}
    return codec_max_encoded_size(T, enc)
end

# The number of bytes that decide the result of decoding a T from the start of `mem`,
# see `codec_bytes_needed`.
@inline function bytes_needed(mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding)::Int where {T}
    return if codec_kind(T, enc) isa Opaque
        codec_bytes_needed(mem, T, enc)
    else
        bits_encoded_size(T)
    end
end

"""
    codec_try_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)::Union{Int, EncodeError}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call [`try_encode!`](@ref) or
[`encode!`](@ref).

Encode `x` at the start of `mem`, and return the number of bytes written, or an
[`EncodeError`](@ref): of kind `InsufficientSpace` if `mem` is too short, or of kind
`InvalidValue` if `x` can't be encoded. If both apply, either may be returned.
An implementation must follow this contract:
* It must succeed if `x` can be encoded and `length(mem) ≥ max_encoded_size(T, enc)`.
* It must not write to `mem` beyond the returned byte count on success, and must not
  write to `mem` at all when it returns an `InsufficientSpace` error. The bytes after the
  encoding may belong to the caller, e.g. when patching a field into an existing buffer,
  or be written concurrently by another task. So it must not even write back the value
  it read.
* When it returns an `InvalidValue` error, it may have written to the first
  `min(length(mem), max_encoded_size(T, enc))` bytes of `mem`, but not beyond. This
  allows a codec to find out that `x` is invalid while encoding it, e.g. a codec that
  encodes the fields of a struct one by one.
* On success, the returned byte count `n` satisfies
  `0 ≤ n ≤ min(length(mem), max_encoded_size(T, enc))`, and equals
  [`codec_try_encoded_size(x, enc)`](@ref codec_try_encoded_size).
* It returns no other error kinds than these two.

## The length of `mem`
`mem` may have any length, including zero, so it may not have room for the encoding of
`x`. Not even `max_encoded_size(T, enc)` bytes are guaranteed: [`try_encode!`](@ref)
passes the rest of the caller's view, whatever its length. An `@inbounds` in the caller
does not apply to the codec, so the codec must check the length of `mem` itself.

To index `mem` without bounds checks, check its length once, then use `@inbounds`. For
example, for a 24-bit unsigned integer `struct U24; x::UInt32; end` encoded in 3 bytes:

```julia
@inline function BitScribbling.codec_try_encode!(
        mem::MutableMemoryView{UInt8}, v::U24, ::BigEndian
    )
    length(mem) < 3 && return EncodeError(EncodeErrorKinds.InsufficientSpace)
    @inbounds begin
        mem[1] = (v.x >> 16) % UInt8
        mem[2] = (v.x >> 8) % UInt8
        mem[3] = v.x % UInt8
    end
    return 3
end
```

If the codec is `@inline`, the compiler usually removes the length check when the caller
already knows the length, e.g. [`store`](@ref) reserves `max_encoded_size(T, enc)` bytes
before calling the codec.

## Checked rules
The rules are not checked, with one exception: an `ErrorException` is thrown if the
returned byte count is not in `0:length(mem)`, also in an `@inbounds` context. This is
because the byte count is used to consume bytes from writers, so a codec that broke its
contract in this way would otherwise corrupt memory.
"""
function codec_try_encode! end

# The package calls hand-written codecs only through these two functions, which check the
# byte count a codec returns. Callers trust it with `@inbounds`, e.g. to consume it from a
# reader or writer, or to slice the rest of a memory view.

@inline function call_codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    result = codec_try_decode(mem, T, enc)
    result isa DecodeError && return result
    (x, n) = result
    # Check only what keeps a broken codec from causing undefined behaviour, namely that
    # `n` is in `0:length(mem)`. Its other contract violations are its own bugs, and are
    # not caught here. Comparing to `max_encoded_size` too would cost measurably, while
    # LLVM often removes this check, when the codec has checked the length itself.
    # A negative `n` wraps around to a large unsigned value.
    (n % UInt) ≤ (length(mem) % UInt) || throw_count_error(codec_try_decode, T, enc, n, length(mem))
    return (x, n)
end

@inline function call_codec_try_encode!(
        mem::MutableMemoryView{UInt8}, x::T, enc::Encoding
    )::Union{Int, EncodeError} where {T}
    n = codec_try_encode!(mem, x, enc)
    n isa EncodeError && return n
    # Check only what keeps a broken codec from causing undefined behaviour, see
    # `call_codec_try_decode`.
    (n % UInt) ≤ (length(mem) % UInt) || throw_count_error(codec_try_encode!, T, enc, n, length(mem))
    return n
end

# Outlined, and given the length rather than `mem`, so the error path doesn't make `mem`
# escape, see `check_start_index`.
@noinline function throw_count_error(f, ::Type{T}, enc::Encoding, n, mem_length::Int) where {T}
    return error(
        "`$(nameof(f))` for `$T` with `$enc` broke its contract: it returned a byte count " *
            "of $n, which is not in 0:length(mem), where length(mem) == $mem_length"
    )
end
