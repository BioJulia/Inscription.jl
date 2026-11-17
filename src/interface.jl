"""
    max_encoded_size(::Type{T}, enc::Encoding)::Int

Upper bound on the number of bytes of any encoding of a value of type `T` with `enc`.
Defined whenever `T` can be encoded or decoded with `enc`.

This function is not an extension point: never add methods to it. Implement a codec
instead, see [`Encoding`](@ref).

# Examples
```jldoctest
julia> max_encoded_size(UInt32, LittleEndian())
4

julia> max_encoded_size(Char, UTF8())
4
```
"""
@inline function max_encoded_size(::Type{T}, enc::Encoding)::Int where {T}
    return if codec_kind(T, enc) isa ManualCodec
        codec_max_encoded_size(T, enc)
    else
        bits_encoded_size(T)
    end
end

"""
    try_decode(mem, [i::Integer,] ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Decode a `T` from `mem`, starting at index `i` (default: 1), treating the bytes from `i`
to the end of `mem` as the complete input. Return the value, or a
[`DecodeError`](@ref).

To also get the index after the encoding, e.g. for types whose encodings vary in size,
use [`try_decode_next`](@ref).

The result is the same as decoding from `mem[i:end]`, but without creating the slice.
`i` must be in `1:length(mem)+1`, or a `LightBoundsError` is thrown.
At `i == length(mem) + 1`, there is nothing to decode.

`mem` is a `MemoryView{UInt8}`, mutable or immutable, or other memory that `MemoryView`
can view as one, such as a `Vector{UInt8}`, a `Memory{UInt8}` or a contiguous view of
them. Strings, substrings and their `codeunits` are not accepted, since viewing them
allocates: convert them once with `MemoryView`, and use `i` to decode at different
positions. The same holds for the memory arguments of all functions of this package.

The error kind is:
* `EndOfInput` if no bytes remain, unless a `T` can be encoded in zero bytes;
* `Truncated` if `mem` ends partway through an encoding, unless the encoding defines a
  meaning for incomplete input, as [`UTF8`](@ref) does;
* `InvalidData` if the bytes are not a valid encoding.

This function ignores `@inbounds`, see the extended help.

This function is not an extension point: never add methods to it. Implement a codec
instead, see [`Encoding`](@ref).

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

# Extended help
## `@inbounds`
`try_decode` ignores `@inbounds`, like `get`: all its checks always run. Input that is
too short is a property of the data, and handling it is what this function is for, so an
`@inbounds` meant for other indexing in the same block must not turn it into undefined
behaviour. To skip the length checks, use [`decode`](@ref) in an `@inbounds` context.

## Char and UTF-8
`try_decode(mem, Char, UTF8())` follows `String` iteration exactly. The lead byte sets
the maximum length (`00`–`bf` and `f8`–`ff`: 1 byte, `c0`–`df`: 2, `e0`–`ef`: 3,
`f0`–`f7`: 4), and each following byte is taken while it is a continuation byte, until
the maximum length or the end of `mem` is reached. Validity is never checked, so
overlong encodings, surrogates and truncated sequences decode to a malformed `Char`.
Therefore, the only possible error is `EndOfInput`, when no bytes remain.
"""
@inline function try_decode(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Union{T, DecodeError} where {T}
    (x, _) = @try_return try_decode_sized(mem, i, T, enc)
    return x
end

@inline function try_decode(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return try_decode(mem, 1, T, enc)
end

"""
    decode(mem, [i::Integer,] ::Type{T}, enc::Encoding)::T

Like [`try_decode`](@ref), but throw the [`DecodeError`](@ref) instead of returning it.

In an `@inbounds` context, the caller guarantees that `i ≥ 1`, and that at least
[`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes remain from `i`, i.e.
`length(mem) - i + 1 ≥ max_encoded_size(T, enc)`. The checks of these conditions, which
would throw a `LightBoundsError` or an `EndOfInput` or `Truncated` error, may then be
skipped, and the behaviour is undefined if they don't hold.
Checks of the decoded bytes themselves are never skipped: for example, decoding a `Bool`
from the byte `0x02` throws an `InvalidData` error also in an `@inbounds` context.
The checks of a hand-written codec are its own, and always run.

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
    result = try_decode_sized(mem, i, T, enc)
    result isa DecodeError && throw_decode_error(result)
    return first(result)
end

Base.@propagate_inbounds function decode(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding) where {T}
    return decode(mem, 1, T, enc)
end

"""
    try_decode_next(mem, i::Integer, ::Type{T}, enc::Encoding)::Union{Tuple{T, Int}, DecodeError}

Like [`try_decode`](@ref), but return the value together with the index after its
encoding, which is where the next value starts. The index is `length(mem) + 1` if the
encoding ends at the end of `mem`.

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
    (x, n) = @try_return try_decode_sized(mem, i, T, enc)
    return (x, Int(i)::Int + n)
end

"""
    decode_next(mem, i::Integer, ::Type{T}, enc::Encoding)::Tuple{T, Int}

Like [`try_decode_next`](@ref), but throw the [`DecodeError`](@ref) instead of returning
it. Supports `@inbounds` in the same way as [`decode`](@ref).

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
    # Calls `try_decode_sized` directly, so that `@inbounds` reaches its checks
    result = try_decode_sized(mem, i, T, enc)
    result isa DecodeError && throw_decode_error(result)
    (x, n) = result
    return (x, Int(i)::Int + n)
end

# Decode a T from `mem[i:end]`, and return it with the number of bytes used, or a
# `DecodeError`. The public decoding functions are built on this.
# Its checks are in `@boundscheck` blocks, so an `@inbounds` in a caller that propagates
# it, such as `decode`, skips them. The `try_` functions don't propagate it.
@inline function try_decode_sized(
        mem::MemoryView{UInt8}, i::Integer, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    i = Int(i)::Int
    kind = codec_kind(T, enc)
    if kind isa ManualCodec
        @boundscheck check_start_index(mem, i)
        return call_codec_try_decode(unsafe_suffix(ImmutableMemoryView(mem), i), T, enc)
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return DecodeError(i > length(mem) ? EndOfInput : Truncated)
    end
    x = @try_return unsafe_decode_bits(kind, mem, i - 1, T, enc)
    return (x, n)
end

"""
    try_encode!(mem, [i::Integer,] x::T, enc::Encoding)::Union{Nothing, Int}

Encode `x` into `mem`, starting at index `i` (default: 1). Return the number of bytes
written, or `nothing` if the bytes from `i` to the end of `mem` are too few.

`i` must be in `1:length(mem)+1`, or a `LightBoundsError` is thrown.

`mem` is a `MutableMemoryView{UInt8}`, or other mutable memory that `MemoryView` can
view as one, such as a `Vector{UInt8}`, see [`try_decode`](@ref).

Only the bytes of the encoding are written. When `nothing` is returned, `mem` is not
written at all.

This function ignores `@inbounds`, like [`try_decode`](@ref). To skip the length checks,
use [`encode!`](@ref) in an `@inbounds` context.

This function is not an extension point: never add methods to it. Implement a codec
instead, see [`Encoding`](@ref).

See also: [`encode!`](@ref), [`store`](@ref)

# Examples
```jldoctest
julia> v = zeros(UInt8, 3);

julia> try_encode!(MemoryView(v), 0x0102, BigEndian()), v
(2, UInt8[0x01, 0x02, 0x00])

julia> try_encode!(MemoryView(v), 2, 0x0304, BigEndian()), v
(2, UInt8[0x01, 0x03, 0x04])

julia> try_encode!(MemoryView(v), 0x01020304, BigEndian()) # too short
```
"""
@inline function try_encode!(
        mem::MutableMemoryView{UInt8}, i::Integer, x, enc::Encoding
    )::Union{Nothing, Int}
    return _try_encode!(mem, i, x, enc)
end

@inline function try_encode!(mem::MutableMemoryView{UInt8}, x, enc::Encoding)
    return _try_encode!(mem, 1, x, enc)
end

# The implementation of `try_encode!`. Its checks are in `@boundscheck` blocks, so an
# `@inbounds` in a caller that propagates it, such as `encode!`, skips them.
# `try_encode!` doesn't propagate it.
@inline function _try_encode!(
        mem::MutableMemoryView{UInt8}, i::Integer, x::T, enc::Encoding
    )::Union{Nothing, Int} where {T}
    i = Int(i)::Int
    if codec_kind(T, enc) isa ManualCodec
        @boundscheck check_start_index(mem, i)
        return call_codec_encode!(unsafe_suffix(mem, i), x, enc)
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return nothing
    end
    unsafe_encode_bits!(mem, i - 1, x, enc)
    return n
end

"""
    encode!(mem, [i::Integer,] x::T, enc::Encoding)::Int

Like [`try_encode!`](@ref), but throw a `LightBoundsError` instead of returning `nothing`
when the bytes from `i` to the end of `mem` are too few.
The error reports the indices that the encoding needed, if they are known. Otherwise, it
reports the indices from `i` to `length(mem) + 1`, since at least one more byte was needed.

In an `@inbounds` context, the caller guarantees that `i ≥ 1`, and that at least
[`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes remain from `i`. The checks
that would throw may then be skipped, and the behaviour is undefined if the guarantees
don't hold. The checks of a hand-written codec are its own, and always run.

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
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks
    n = _try_encode!(mem, i, x, enc)
    n === nothing && throw_encode_error(mem, Int(i)::Int, T, enc)
    return n
end

Base.@propagate_inbounds function encode!(mem::MutableMemoryView{UInt8}, x, enc::Encoding)
    return encode!(mem, 1, x, enc)
end

# Throw the error of `encode!` for a T at the valid start index `i`, when `mem` is too
# short. A hand-written codec doesn't say how many bytes it needed, but at least one more
# byte than `mem` has. Inlined for the same reason as `check_start_index`.
@inline function throw_encode_error(mem::MemoryView, i::Int, ::Type{T}, enc::Encoding) where {T}
    stop = if codec_kind(T, enc) isa ManualCodec
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

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call [`max_encoded_size`](@ref).

Return an upper bound on the number of bytes of any encoding of a `T`. The result must
be constant-foldable. Loading and storing buffer this many bytes, if available, before
calling [`codec_try_decode`](@ref) or [`codec_encode!`](@ref).
"""
function codec_max_encoded_size end

"""
    codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E
    )::Union{Tuple{T, Int}, DecodeError}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call [`try_decode`](@ref) or
[`try_decode_next`](@ref).

Decode a `T` from the start of `mem`, as described for [`try_decode`](@ref), and return
it with the number of bytes used, `n`, or return a [`DecodeError`](@ref).
An implementation must follow this contract:
1. **Pure.** The result depends only on the contents of `mem`, and no reference to
   `mem` is kept.
2. **Bounded.** On success, `0 ≤ n ≤ min(length(mem), max_encoded_size(T, enc))`.
3. **`mem` is the complete input.** The end of `mem` is the end of the data.
   An empty `mem` gives `EndOfInput`, unless a `T` can be encoded in zero bytes.
   A `mem` that ends partway through an encoding gives `Truncated`, unless the
   encoding defines a meaning for incomplete input.
4. **Decided by the first `max_encoded_size(T, enc)` bytes.** If
   `length(mem) ≥ max_encoded_size(T, enc)`, the result is the same for every memory
   that starts with those bytes.

Rule 4 is what allows loading from a reader's buffer, which is not the complete input.

The rules are not checked, with one exception: an `ErrorException` is thrown if the
returned byte count is not in `0:length(mem)`, also in an `@inbounds` context. This is
because the byte count is used to consume bytes from readers, so a codec that broke its
contract in this way would otherwise corrupt memory.
"""
function codec_try_decode end

"""
    codec_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)::Union{Nothing, Int}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call [`try_encode!`](@ref) or
[`encode!`](@ref).

Encode `x` at the start of `mem`, and return the number of bytes written, or `nothing`
if `mem` is too short. An implementation must follow this contract:
* It must succeed if `length(mem) ≥ max_encoded_size(T, enc)`.
* It must not write to `mem` beyond the returned byte count, and must not write to
  `mem` at all when it returns `nothing`. The bytes after the encoding may belong to
  the caller, e.g. when patching a field into an existing buffer, or be written
  concurrently by another task. So it must not even write back the value it read.
* On success, the returned byte count `n` satisfies
  `0 ≤ n ≤ min(length(mem), max_encoded_size(T, enc))`.

The rules are not checked, with one exception: an `ErrorException` is thrown if the
returned byte count is not in `0:length(mem)`, also in an `@inbounds` context. This is
because the byte count is used to consume bytes from writers, so a codec that broke its
contract in this way would otherwise corrupt memory.
"""
function codec_encode! end

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

@inline function call_codec_encode!(
        mem::MutableMemoryView{UInt8}, x::T, enc::Encoding
    )::Union{Nothing, Int} where {T}
    n = codec_encode!(mem, x, enc)
    n === nothing && return nothing
    # Check only what keeps a broken codec from causing undefined behaviour, see
    # `call_codec_try_decode`.
    (n % UInt) ≤ (length(mem) % UInt) || throw_count_error(codec_encode!, T, enc, n, length(mem))
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
