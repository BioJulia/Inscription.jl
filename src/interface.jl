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
        val_size(codec_max_encoded_size(T, enc), T, enc)
    else
        bits_encoded_size(T)
    end
end

# The size in the `Val` returned by `codec_max_encoded_size`. It is checked here, and the
# check is constant-folded.
@inline function val_size(::Val{N}, ::Type{T}, enc::Encoding)::Int where {N, T}
    N isa Int && N ≥ 1 || throw_max_size_error(T, enc, N)
    return N
end

val_size(x, ::Type{T}, enc::Encoding) where {T} = throw_max_size_error(T, enc, x)

@noinline function throw_max_size_error(::Type{T}, enc::Encoding, x) where {T}
    return error(
        "`codec_max_encoded_size` for `$T` with `$enc` broke its contract: it must return " *
            "`Val(n)` for a positive `n::Int`, but returned the size `$(repr(x))`"
    )
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
* `EndOfInput` if no bytes remain;
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
        rest = unsafe_suffix(ImmutableMemoryView(mem), i)
        length(rest) ≥ max_encoded_size(T, enc) || return decode_memory_short(rest, T, enc)
        result = decode_full(rest, T, enc)
        result isa Invalid && return DecodeError(InvalidData)
        return result
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return DecodeError(i > length(mem) ? EndOfInput : Truncated)
    end
    x = @? unsafe_decode_bits(kind, mem, i - 1, T, enc)
    return (x, n)
end

# The slow path of `try_decode_sized`: decode a T from all of `mem`, which is too short for
# any encoding.
@inline function decode_memory_short(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    isempty(mem) && return DecodeError(EndOfInput)
    result = decode_short(mem, T, enc, true)
    result isa TooShort && return DecodeError(Truncated)
    result isa Invalid && return DecodeError(InvalidData)
    return result
end

# Decode a T from the start of `mem`. If `ends` is false, more bytes may follow `mem`,
# as when loading from a reader's buffer, and `TooShort` means that the result is not
# decided yet.
@inline function decode_start(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding, ends::Bool
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    kind = codec_kind(T, enc)
    if kind isa Opaque
        length(mem) ≥ max_encoded_size(T, enc) && return decode_full(mem, T, enc)
        return decode_short(mem, T, enc, ends)
    end
    # A bits type is decided by all of its bytes, so it's decoded the same either way
    length(mem) < bits_encoded_size(T) && return TooShort(bits_encoded_size(T))
    return decode_bits(kind, mem, T, enc)
end

# Decode a bits type T from the start of `mem`, which must hold its encoding
@inline function decode_bits(
        kind, mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Endianness
    )::Union{Tuple{T, Int}, Invalid} where {T}
    x = unsafe_decode_bits(kind, mem, 0, T, enc)
    x isa DecodeError && return Invalid()
    return (x, bits_encoded_size(T))
end

# The fast path: decode with a codec from `mem`, which must hold at least
# `max_encoded_size(T, enc)` bytes. Those decide the result, so the input ends after them,
# also if more bytes may follow. The codec is compiled for a `DecodeInput{L}` with `L` the
# size, so the checks of its reads within the first `L` bytes are removed.
@inline function decode_full(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, Invalid} where {T}
    L = max_encoded_size(T, enc)
    input = DecodeInput{L}(@inbounds(MemoryViews.truncate(mem, L)), true)
    result = call_codec_try_decode(input, T, enc)
    result isa TooShort && throw_too_short_error(codec_try_decode, T, enc)
    return result
end

# The slow path: decode with a codec from `mem`, which may be shorter than any encoding.
# It is inlined like the fast path. Outlining it was measured to be slower: passing `mem`
# to a non-inlined function makes the caller set up a GC frame on every call, and the
# union result is returned through memory, also on the fast path.
@inline function decode_short(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding, ends::Bool
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    return call_codec_try_decode(DecodeInput{0}(mem, ends), T, enc)
end

"""
    try_encode!(mem, [i::Integer,] x::T, enc::Encoding)::Union{Int, EncodeError}

Encode `x` into `mem`, starting at index `i` (default: 1).
Return the number of bytes written, or an [`EncodeError`](@ref).
`mem` is converted to a `MutableMemoryView{UInt8}`.

The error kind is:
* `InsufficientSpace` if the bytes from `i` to the end of `mem` are too few for the
  encoding of `x`;
* `InvalidValue` if `x` can't be encoded with `enc`.

On error, the bytes from `i` up to [`max_encoded_size(T, enc)`](@ref max_encoded_size)
bytes later, but not beyond the end of `mem`, may have been written, and their contents
are unspecified. For `InsufficientSpace`, these are the bytes that a successful encoding
would have covered.

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
        rest = unsafe_suffix(mem, i)
        length(rest) ≥ max_encoded_size(T, enc) || return encode_memory_short(rest, x, enc)
        result = encode_full(rest, x, enc)
        result isa Invalid && return EncodeError(InvalidValue)
        return result
    end
    n = bits_encoded_size(T)
    @boundscheck if !has_bytes(mem, i, n)
        check_start_index(mem, i)
        return EncodeError(InsufficientSpace)
    end
    unsafe_encode_bits!(mem, i - 1, x, enc)
    return n
end

# The slow path of `_try_encode!`: encode `x` into `mem`, which is shorter than
# `max_encoded_size`.
@inline function encode_memory_short(mem::MutableMemoryView{UInt8}, x, enc::Encoding)::Union{Int, EncodeError}
    result = encode_short(mem, x, enc)
    result isa TooShort && return EncodeError(InsufficientSpace)
    result isa Invalid && return EncodeError(InvalidValue)
    return result
end

# Encode `x` at the start of `mem`, the counterpart of `decode_start`
@inline function encode_start(mem::MutableMemoryView{UInt8}, x::T, enc::Encoding)::Union{Int, TooShort, Invalid} where {T}
    if codec_kind(T, enc) isa Opaque
        length(mem) ≥ max_encoded_size(T, enc) && return encode_full(mem, x, enc)
        return encode_short(mem, x, enc)
    end
    n = bits_encoded_size(T)
    length(mem) < n && return TooShort(n)
    unsafe_encode_bits!(mem, 0, x, enc)
    return n
end

# The fast path: encode with a codec into `mem`, which must hold at least
# `max_encoded_size(T, enc)` bytes, see `decode_full`.
@inline function encode_full(mem::MutableMemoryView{UInt8}, x::T, enc::Encoding)::Union{Int, Invalid} where {T}
    L = max_encoded_size(T, enc)
    output = EncodeOutput{L}(@inbounds(MemoryViews.truncate(mem, L)))
    result = call_codec_try_encode!(output, x, enc)
    result isa TooShort && throw_too_short_error(codec_try_encode!, T, enc)
    return result
end

# The slow path: encode with a codec into `mem`, which may be too short
@inline function encode_short(mem::MutableMemoryView{UInt8}, x, enc::Encoding)::Union{Int, TooShort, Invalid}
    return call_codec_try_encode!(EncodeOutput{0}(mem), x, enc)
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
    codec_max_encoded_size(::Type{T}, ::E)::Val{N}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call
[`max_encoded_size`](@ref).

Return `Val(N)`, where `N::Int` is the maximum number of bytes of any encoding of a `T`.
`N` must be positive, since every encoding takes at least one byte. It must be a
constant, since codecs are compiled for inputs and outputs of `N` bytes, see
[`DecodeInput`](@ref).

Storing into `AbstractBufWriter` buffers this many bytes before encoding.
The input of [`codec_try_decode`](@ref) ends after this many bytes, also if more
bytes follow.
"""
function codec_max_encoded_size end

"""
    codec_try_decode(input::DecodeInput, ::Type{T}, ::E)::Union{Tuple{T, Int}, TooShort, Invalid}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call e.g. [`try_decode`](@ref).

Decode a `T` from the start of `input`, and return it with the number of bytes it was
decoded from. Return [`Invalid()`](@ref Invalid) if the bytes are not a valid encoding.

Read `input` only through [`require_bytes`](@ref), [`peek_byte`](@ref) and
[`decode_field`](@ref), and return their [`TooShort`](@ref) with [`@?`](@ref). The codec
never handles a short input itself: the caller decides what `TooShort` means, e.g.
an error for memory, or to wait for more bytes for a reader.

An implementation must follow this contract:
* **Pure.** The result depends only on the bytes it read from `input`.
* **Counted.** On success, the returned byte count is positive, and at most the number of
  bytes read. Bytes after the encoding that decide the result, e.g. a terminator, are
  read but not counted.

For example, for a 24-bit unsigned integer `U24` encoded in 3 bytes:

```julia
BitScribbling.codec_max_encoded_size(::Type{U24}, ::BigEndian) = Val(3)

@inline function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{U24}, ::BigEndian)
    b = @? require_bytes(input, 3)
    # `b` has length 3, so these are in bounds, and their checks are removed
    return (U24((UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])), 3)
end
```

An encoding whose end is decided by the byte after it looks at that byte with
`peek_byte`. For example, for the decimal digits of a `UInt8`:

```julia
@inline function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Decimal)
    value = 0
    n = 0
    while n < 3
        byte = @? peek_byte(input, n + 1)
        (byte === nothing || !(UInt8('0') ≤ byte ≤ UInt8('9'))) && break
        value = 10 * value + (byte - UInt8('0'))
        n += 1
    end
    (n == 0 || value > 255) && return Invalid()
    return (UInt8(value), n)
end
```

When loading from a reader whose buffer holds the bytes `"12"`, `peek_byte(input, 3)`
returns `TooShort(3)`, so the reader buffers a third byte, which may be another digit.
When `"12"` is the complete input, it returns `nothing`, and the result is `12`.
"""
function codec_try_decode end

"""
    require_bytes(input::DecodeInput, n::Integer)::Union{ImmutableMemoryView{UInt8}, TooShort}

Get the first `n` bytes of `input`, as a memory view of length `n`, or
[`TooShort`](@ref) if the input has fewer bytes. Use with [`@?`](@ref) in
[`codec_try_decode`](@ref).

When `n` is a constant of at most [`max_encoded_size`](@ref), this can't fail on the
fast path, and is compiled to no code. The view's length is then a constant, so indexing
it with constant indices needs no `@inbounds`.
"""
@inline function require_bytes(input::DecodeInput{L}, n::Integer) where {L}
    n = Int(n)::Int
    n < 0 && throw_negative_count(n)
    mem = input.mem
    # `n ≤ L` is decided when the codec is compiled, if `n` is a constant
    (n ≤ L || n ≤ length(mem)) || return TooShort(input.offset + n)
    return @inbounds MemoryViews.truncate(mem, n)
end

"""
    peek_byte(input::DecodeInput, i::Integer)::Union{UInt8, Nothing, TooShort}

Get the byte at index `i` of `input`, or `nothing` if the input ends before it. `i` must
be positive. Use with [`@?`](@ref) in [`codec_try_decode`](@ref).

If the input is partial, see [`DecodeInput`](@ref), and byte `i` hasn't arrived yet,
return [`TooShort`](@ref), meaning that more bytes are needed. So `nothing`
always means that the input ends before byte `i`.
"""
@inline function peek_byte(input::DecodeInput{L}, i::Integer) where {L}
    i = Int(i)::Int
    mem = input.mem
    @boundscheck i ≥ 1 || throw_lightboundserror(mem, i)
    (i ≤ L || i ≤ length(mem)) && return @inbounds mem[i]
    return input.ends ? nothing : TooShort(input.offset + i)
end

"""
    decode_field(input::DecodeInput, ::Type{T}, enc::Encoding)

Decode a `T` with the encoding `enc` from the start of `input`. Return
`(x, n, rest)`, where `x::T` was decoded from `n` bytes, and `rest` is the input after
them. Else, return [`TooShort`](@ref) or [`Invalid()`](@ref Invalid). Use
with [`@?`](@ref) in [`codec_try_decode`](@ref), for encodings that contain the
encodings of other values.

When `input` is a `DecodeInput{L}` with `L` at least `max_encoded_size(T, enc)`, the `T`
is decoded on the fast path, and `rest` is a `DecodeInput{L - max_encoded_size(T, enc)}`.
So the fast path is known when the codec is compiled, for every field in turn.
"""
@inline function decode_field(input::DecodeInput{L}, ::Type{T}, enc::Encoding) where {L, T}
    N = max_encoded_size(T, enc)
    mem = input.mem
    kind = codec_kind(T, enc)
    # `L ≥ N` is decided when the codec is compiled
    if L ≥ N || length(mem) ≥ N
        result = kind isa Opaque ? decode_full(mem, T, enc) : decode_bits(kind, mem, T, enc)
        result isa Invalid && return result
        (x, n) = result
        # `n ≤ N`, so the rest has at least `L - N` bytes
        return (x, n, DecodeInput{max(L - N, 0)}(unsafe_suffix(mem, n + 1), input.ends, input.offset + n))
    end
    result = decode_start(mem, T, enc, input.ends)
    # The count of `TooShort` is from the start of `mem`
    result isa TooShort && return TooShort(input.offset + result.needed)
    result isa Invalid && return result
    (x, n) = result
    return (x, n, DecodeInput{0}(unsafe_suffix(mem, n + 1), input.ends, input.offset + n))
end

@noinline throw_negative_count(n::Int) = throw(ArgumentError("expected a non-negative count, got $n"))

"""
    codec_try_encode!(output::EncodeOutput, x::T, ::E)::Union{Int, TooShort, Invalid}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call [`try_encode!`](@ref) or
[`encode!`](@ref).

Encode `x` at the start of `output`, and return the number of bytes written. Return
[`Invalid()`](@ref Invalid) if `x` can't be encoded.

Write `output` only through [`reserve_bytes`](@ref) and [`encode_field`](@ref), and return
their [`TooShort`](@ref) with [`@?`](@ref). Don't read the bytes of `output`.

An implementation must follow this contract:
* On success, the returned byte count `n` is positive, and the codec wrote no bytes after
  the first `n`. They may belong to the caller, e.g. when patching a field into an
  existing buffer, or be written concurrently by another task.
* When it returns `TooShort` or `Invalid`, it may have written to any byte of `output`.
  Since `output` never holds more than `max_encoded_size(T, enc)` bytes, see
  [`EncodeOutput`](@ref), these are at most the first `max_encoded_size(T, enc)` bytes
  of the caller's memory.

For example, for a 24-bit unsigned integer `struct U24; x::UInt32; end` encoded in 3 bytes:

```julia
@inline function BitScribbling.codec_try_encode!(output::EncodeOutput, v::U24, ::BigEndian)
    mem = @? reserve_bytes(output, 3)
    mem[1] = (v.x >> 16) % UInt8
    mem[2] = (v.x >> 8) % UInt8
    mem[3] = v.x % UInt8
    return 3
end
```

## Checked rules
The rules are not checked, with one exception: an `ErrorException` is thrown if the
returned byte count is not in `0:length(mem)`, also in an `@inbounds` context. This is
because the byte count is used to consume bytes from writers, so a codec that broke its
contract in this way would otherwise corrupt memory.
"""
function codec_try_encode! end

"""
    reserve_bytes(output::EncodeOutput, n::Integer)::Union{MutableMemoryView{UInt8}, TooShort}

Get the first `n` bytes of `output`, as a mutable memory view of length `n`, for the
codec to write, or [`TooShort`](@ref) if the output has fewer bytes. Use with
[`@?`](@ref) in [`codec_try_encode!`](@ref).

As for [`require_bytes`](@ref), when `n` is a constant of at most
[`max_encoded_size`](@ref), this is compiled to no code on the fast path.
"""
@inline function reserve_bytes(output::EncodeOutput{L}, n::Integer) where {L}
    n = Int(n)::Int
    n < 0 && throw_negative_count(n)
    mem = output.mem
    (n ≤ L || n ≤ length(mem)) || return TooShort(output.offset + n)
    return @inbounds MemoryViews.truncate(mem, n)
end

"""
    encode_field(output::EncodeOutput, x::T, enc::Encoding)

Encode `x` with the encoding `enc` at the start of `output`. Return `(n, rest)`, where
`n` is the number of bytes written, and `rest` is the output after them. Else, return
[`TooShort`](@ref) or [`Invalid()`](@ref Invalid). Use with [`@?`](@ref) in
[`codec_try_encode!`](@ref), for encodings that contain the encodings of other values.

As for [`decode_field`](@ref), when `output` is an `EncodeOutput{L}` with `L` at least
`max_encoded_size(T, enc)`, `x` is encoded on the fast path, and `rest` is an
`EncodeOutput{L - max_encoded_size(T, enc)}`.
"""
@inline function encode_field(output::EncodeOutput{L}, x::T, enc::Encoding) where {L, T}
    N = max_encoded_size(T, enc)
    mem = output.mem
    if L ≥ N || length(mem) ≥ N
        n = if codec_kind(T, enc) isa Opaque
            @? encode_full(mem, x, enc)
        else
            unsafe_encode_bits!(mem, 0, x, enc)
            N
        end
        return (n, EncodeOutput{max(L - N, 0)}(unsafe_suffix(mem, n + 1), output.offset + n))
    end
    result = encode_start(mem, x, enc)
    # The count of `TooShort` is from the start of `mem`
    result isa TooShort && return TooShort(output.offset + result.needed)
    result isa Invalid && return result
    return (result, EncodeOutput{0}(unsafe_suffix(mem, result + 1), output.offset + result))
end

# The package calls hand-written codecs only through these two functions, which check the
# byte count a codec returns. Callers trust it with `@inbounds`, e.g. to consume it from a
# reader or writer, or to slice the rest of a memory view.

@inline function call_codec_try_decode(
        input::DecodeInput, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    result = codec_try_decode(input, T, enc)
    result isa Union{TooShort, Invalid} && return result
    (x, n) = result
    # Check only what keeps a broken codec from causing undefined behaviour, namely that
    # `n` is in `0:length(input.mem)`. Since the input ends after `max_encoded_size`
    # bytes, this also checks that `n` is at most that. LLVM often removes this check,
    # when the codec has checked the length itself. Its other contract violations are its
    # own bugs, and are not caught here.
    len = length(input.mem)
    (n % UInt) ≤ (len % UInt) || throw_count_error(codec_try_decode, T, enc, n, len)
    return (x, n)
end

@inline function call_codec_try_encode!(
        output::EncodeOutput, x::T, enc::Encoding
    )::Union{Int, TooShort, Invalid} where {T}
    n = codec_try_encode!(output, x, enc)
    n isa Union{TooShort, Invalid} && return n
    # Check only what keeps a broken codec from causing undefined behaviour, see
    # `call_codec_try_decode`.
    len = length(output.mem)
    (n % UInt) ≤ (len % UInt) || throw_count_error(codec_try_encode!, T, enc, n, len)
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

@noinline function throw_too_short_error(f, ::Type{T}, enc::Encoding) where {T}
    return error(
        "`$(nameof(f))` for `$T` with `$enc` broke its contract: it returned `TooShort` " *
            "although it was given `max_encoded_size` bytes"
    )
end
