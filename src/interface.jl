"""
    max_encoded_size(::Type{T}, enc::Encoding)::Union{Int, Unbounded}

Upper bound on the number of bytes of any encoding of a value of type `T` with `enc`,
or [`Unbounded()`](@ref Unbounded) if there is none.
Which of them is known when the caller is compiled.
Throw an `ArgumentError` if there is no codec for `T` with `enc`.

Do not add methods to this function. Implement a codec instead, see [`Encoding`](@ref).

# Examples
```jldoctest
julia> max_encoded_size(UInt32, LittleEndian())
4

julia> max_encoded_size(Char, UTF8())
4
```
"""
@inline function max_encoded_size(::Type{T}, enc::Encoding)::Union{Int, Unbounded} where {T}
    scheme = codec_kind(T, enc)
    return if scheme isa BitsScheme
        bits_encoded_size(T)
    elseif scheme isa Proxy
        proxy_max_encoded_size(scheme, enc)
    else
        val_size(codec_max_encoded_size(T, enc), T, enc)
    end
end

@inline proxy_max_encoded_size(::Proxy{P}, enc::Encoding) where {P} = max_encoded_size(P, enc)

# The size in the `Val` returned by `codec_max_encoded_size`. It is checked here, and the
# check is constant-folded.
@inline function val_size(::Val{N}, ::Type{T}, enc::Encoding)::Int where {N, T}
    N isa Int && N ≥ 1 || throw_max_size_error(T, enc, N)
    return N
end

@inline val_size(x::Unbounded, ::Type, ::Encoding) = x
val_size(::NoCodec, ::Type{T}, enc::Encoding) where {T} = throw_no_codec_error(T, enc)
val_size(x, ::Type{T}, enc::Encoding) where {T} = throw_max_size_error(T, enc, x)

# Whether T has a codec with `enc`. Constant-folded.
@inline function has_codec(::Type{T}, enc::Encoding)::Bool where {T}
    scheme = codec_kind(T, enc)
    return if scheme isa BitsScheme
        true
    elseif scheme isa Proxy
        proxy_has_codec(scheme, enc)
    else
        !(codec_max_encoded_size(T, enc) isa NoCodec)
    end
end

@inline proxy_has_codec(::Proxy{P}, enc::Encoding) where {P} = has_codec(P, enc)

@noinline function throw_no_codec_error(::Type{T}, enc::Encoding) where {T}
    throw(
        ArgumentError(
            "There is no codec for `$T` with `$enc`. To add one, see `BitScribbling.codec_scheme` " *
                "and `BitScribbling.Encoding`. If you added a method for this type to a function of " *
                "BitScribbling, then the function you called doesn't use that method."
        )
    )
end

# Whether `len` bytes are known to hold any encoding of a T. Never so for unbounded types.
@inline function holds_any(len::Int, ::Type{T}, enc::Encoding)::Bool where {T}
    N = max_encoded_size(T, enc)
    return N isa Int && len ≥ N
end

@noinline function throw_max_size_error(::Type{T}, enc::Encoding, x) where {T}
    return error(
        "`codec_max_encoded_size` for `$T` with `$enc` broke its contract: it must return " *
            "`Val(n)` for a positive `n::Int`, or `Unbounded()`, but returned the size `$(repr(x))`"
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

To customize it for your own type, implement a codec, see [`Encoding`](@ref), or add a method
to it, see [Overloading functions](@ref overloading).

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
has at least length `length(mem) ≥ i - 1 + max_encoded_size(T, enc)`. If that is
[`Unbounded`](@ref), the caller must guarantee only that `i` is in `1:length(mem)+1`.

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
    # Without a codec, `try_decode_sized` calls the method of this function that the user
    # added. There is none, or this method wouldn't have been called.
    has_codec(T, enc) || throw_no_codec_error(T, enc)
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
# Without a codec, calls the method of `try_decode_next` that the user added.
@inline function try_decode_sized(
        mem::MemoryView{UInt8}, i::Int, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    if !has_codec(T, enc)
        check_start_index(mem, i)
        (x, next) = @? try_decode_next(mem, i, T, enc)
        return (x::T, next - i)
    end
    kind = codec_kind(T, enc)
    if !(kind isa BitsScheme)
        @boundscheck check_start_index(mem, i)
        imem = ImmutableMemoryView(mem)
        # The suffix is made after its length is checked, since it's cheaper to make when
        # it is known not to be empty. `i` is compared to the length of `mem`, like callers
        # that loop over `mem` do, so the compiler can remove the comparison.
        if !holds_any(length(imem) - i + 1, T, enc)
            i > length(imem) && return DecodeError(EndOfInput)
            return decode_memory_short(nonempty_suffix(imem, i), T, enc)
        end
        result = decode_full(nonempty_suffix(imem, i), T, enc)
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

# The slow path of `try_decode_sized`: decode a T from all of `mem`, which is not empty, but
# not known to hold any encoding of a T.
@inline function decode_memory_short(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    # Since `mem` is not empty, the check of a codec that reads one byte is removed
    result = call_codec_try_decode(MemoryInput{1}(mem, true), T, enc)
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
    if !(kind isa BitsScheme)
        holds_any(length(mem), T, enc) && return decode_full(mem, T, enc)
        return decode_short(mem, T, enc, ends)
    end
    # A bits type is decided by all of its bytes, so it's decoded the same either way
    length(mem) < bits_encoded_size(T) && return TooShort()
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
# also if more bytes may follow. The codec is compiled for a `MemoryInput{L}` with `L` the
# size, so the checks of its reads within the first `L` bytes are removed.
@inline function decode_full(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, Invalid} where {T}
    L = max_encoded_size(T, enc)
    input = MemoryInput{L}(@inbounds(MemoryViews.truncate(mem, L)), true)
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
    return call_codec_try_decode(MemoryInput{0}(mem, ends), T, enc)
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

To customize it for your own type, implement a codec, see [`Encoding`](@ref), or add a method
to it, see [Overloading functions](@ref overloading).

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
    return try_encode!(mem, 1, x, enc)
end

# The implementation of `try_encode!`. Its checks are in `@boundscheck` blocks, so an
# `@inbounds` in a caller that propagates it, such as `encode!`, skips them.
# `try_encode!` doesn't propagate it.
@inline function _try_encode!(
        mem::MutableMemoryView{UInt8}, i::Int, x::T, enc::Encoding
    )::Union{Int, EncodeError} where {T}
    if !(codec_kind(T, enc) isa BitsScheme)
        @boundscheck check_start_index(mem, i)
        # As in `try_decode_sized`, make the suffix after its length is checked. If `mem` has
        # no room, the codec must still run, since it may return `Invalid`.
        if !holds_any(length(mem) - i + 1, T, enc)
            return encode_memory_short(unsafe_suffix(mem, i), x, enc)
        end
        result = encode_full(nonempty_suffix(mem, i), x, enc)
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
    if !(codec_kind(T, enc) isa BitsScheme)
        holds_any(length(mem), T, enc) && return encode_full(mem, x, enc)
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
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks. Without a codec,
    # calls the method of `try_encode!` that the user added.
    result = if has_codec(T, enc)
        _try_encode!(mem, i, x, enc)
    else
        try_encode!(mem, i, x, enc)::Union{Int, EncodeError}
    end
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
    stop = if codec_kind(T, enc) isa BitsScheme
        i + bits_encoded_size(T) - 1
    else
        length(mem) + 1
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

# `mem[i:end]`, without checking that `i` is in `1:length(mem)`.
# Cheaper than `unsafe_suffix`, which must handle that the suffix may be empty.
@inline function nonempty_suffix(mem::ImmutableMemoryView{UInt8}, i::Int)
    ref = @inbounds memoryref(MemoryViews.unsafe_memoryref(mem), i)
    return ImmutableMemoryView(MemoryViews.unsafe_from_parts(ref, length(mem) - i + 1))
end

@inline function nonempty_suffix(mem::MutableMemoryView{UInt8}, i::Int)
    ref = @inbounds memoryref(memoryref(mem), i)
    return MemoryViews.unsafe_from_parts(ref, length(mem) - i + 1)
end

# `mem[i:end]`, without checking that `i` is in `1:length(mem)+1`.
# Unlike slicing, this returns `mem` itself for i == 1, which is constant-folded.
@inline unsafe_suffix(mem::MemoryView, i::Int) = last(@inbounds split_at(mem, i))


"""
    codec_max_encoded_size(::Type{T}, ::E)::Union{Val{N}, Unbounded}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call
[`max_encoded_size`](@ref).

Return `Val(N)`, where `N::Int` is the maximum number of bytes of any encoding of a `T`.
`N` must be positive, since every encoding takes at least one byte. It must be a
constant, since codecs are compiled for inputs and outputs of `N` bytes, see
[`DecodeInput`](@ref). If the encodings have no maximal size, return
[`Unbounded()`](@ref Unbounded).

Storing into `AbstractBufWriter` buffers this many bytes before encoding.
The input of [`codec_try_decode`](@ref) ends after this many bytes, also if more
bytes follow.
"""
codec_max_encoded_size(::Type, ::Encoding) = NoCodec()

"""
    codec_try_decode(input::DecodeInput, ::Type{T}, ::E)::Union{Tuple{T, Int}, TooShort, Invalid}

Extension point of a hand-written codec for the value type `T` and the concrete encoding
type `E`, see [`Encoding`](@ref). Never call it directly; call e.g. [`try_decode`](@ref).

Decode a `T` from the start of `input`, and return it with the number of bytes it was
decoded from. Return [`Invalid()`](@ref Invalid) if the bytes are not a valid encoding.

Read `input` only through [`require_bytes`](@ref), [`peek_byte`](@ref) and
[`decode_field`](@ref), and return their [`TooShort`](@ref) with [`@?`](@ref). The codec
never handles a short input itself, see [`DecodeInput`](@ref).

An implementation must follow this contract:
* **Pure.** The result depends only on the bytes it read from `input`. The codec may be
  run more than once for the same bytes, e.g. again after returning `TooShort`, once
  more bytes are available.
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

When only the bytes `"12"` are available, but the input may continue after them,
`peek_byte(input, 3)` gets the third byte, which may be another digit, or returns
`TooShort` if it is not available. When the input ends after `"12"`, it returns
`nothing`, and the result is `12`.
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

The view may be invalidated by later reads of the input, and this function may invalidate
earlier views, see [`DecodeInput`](@ref).
"""
@inline function require_bytes(input::MemoryInput{L}, n::Integer) where {L}
    n = byte_count(n)
    mem = input.mem
    # `n ≤ L` is decided when the codec is compiled, if `n` is a constant
    (n ≤ L || n ≤ length(mem)) || return TooShort()
    return @inbounds MemoryViews.truncate(mem, n)
end

@inline function require_bytes(input::ReaderInput, n::Integer)
    n = byte_count(n)
    (; io, offset, stop) = input
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    # If the input ends before `n` bytes, buffer all of it, so that a codec that asks for
    # more bytes than its maximal size is told apart from a reader that is at EOF
    ends_before = n > stop - offset
    needed = ends_before ? stop : offset + n
    if length(buffer) < needed
        buffer = fill_at_least(io, needed)
        length(buffer) < needed && return TooShort()
    end
    ends_before && return TooShort()
    return @inbounds buffer[(offset + 1):needed]
end

# The count given to `require_bytes`, e.g. a length read from the data. No input has more
# than `typemax(Int)` bytes, so larger counts make the input too short, and don't overflow.
@inline function byte_count(n::Integer)::Int
    n < 0 && throw_negative_count(n)
    return n > typemax(Int) ? typemax(Int) : Int(n)::Int
end

# Buffer at least `n` bytes of `io`, or all bytes up to EOF, and return the buffer.
# `n` may come from corrupt data, and readers may allocate all of the requested size, so
# the buffer is filled in steps proportional to the bytes that have arrived.
# Inlined, like `load_slow`, since refilling was measured to be slower with them outlined.
# `peek_value` is not inlined, so the callers' code stays small.
@inline function fill_at_least(io::AbstractBufReader, n::Int)::ImmutableMemoryView{UInt8}
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    while length(buffer) < n
        step = min(n, max(2 * length(buffer), MIN_FILL_STEP))
        new_buffer = get_nonempty_buffer(io, step)
        new_buffer === nothing && return get_buffer(io)::ImmutableMemoryView{UInt8}
        length(new_buffer) < step && throw_short_buffer_error(io, step, length(new_buffer))
        buffer = new_buffer
    end
    return buffer
end

const MIN_FILL_STEP = 1 << 16

"""
    peek_byte(input::DecodeInput, i::Integer)::Union{UInt8, Nothing, TooShort}

Get the byte at index `i` of `input`, or `nothing` if the input ends before it. `i` must
be positive. Use with [`@?`](@ref) in [`codec_try_decode`](@ref).

If byte `i` is not available yet, return [`TooShort`](@ref), see [`DecodeInput`](@ref).
So `nothing` always means that the input ends before byte `i`, and not that its bytes are
not available yet.

May invalidate views of the input, see [`DecodeInput`](@ref).
"""
@inline function peek_byte(input::MemoryInput{L}, i::Integer) where {L}
    i = Int(i)::Int
    mem = input.mem
    @boundscheck i ≥ 1 || throw_lightboundserror(mem, i)
    (i ≤ L || i ≤ length(mem)) && return @inbounds mem[i]
    return input.ends ? nothing : TooShort()
end

@inline function peek_byte(input::ReaderInput, i::Integer)
    i = Int(i)::Int
    (; io, offset, stop) = input
    @boundscheck i ≥ 1 || throw_lightboundserror(1:(stop - offset), i)
    i > stop - offset && return nothing
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    needed = offset + i
    if length(buffer) < needed
        buffer = fill_at_least(io, needed)
        length(buffer) < needed && return nothing
    end
    return @inbounds buffer[needed]
end

"""
    decode_field(input::DecodeInput, ::Type{T}, enc::Encoding)

Decode a `T` with the encoding `enc` from the start of `input`. Return
`(x, n, rest)`, where `x::T` was decoded from `n` bytes, and `rest` is the input after
them. Else, return [`TooShort`](@ref) or [`Invalid()`](@ref Invalid). Use
with [`@?`](@ref) in [`codec_try_decode`](@ref), for encodings that contain the
encodings of other values.

May invalidate views of the input, see [`DecodeInput`](@ref).

When `input` is known to hold at least `max_encoded_size(T, enc)` bytes, the `T` is decoded
on the fast path, and `rest` is known to hold the number of bytes that remain.
So the fast path is known when the codec is compiled, for every field in turn.
"""
@inline function decode_field(input::MemoryInput{L}, ::Type{T}, enc::Encoding) where {L, T}
    N = max_encoded_size(T, enc)
    mem = input.mem
    kind = codec_kind(T, enc)
    # `L ≥ N` is decided when the codec is compiled
    if N isa Int && (L ≥ N || length(mem) ≥ N)
        result = kind isa BitsScheme ? decode_bits(kind, mem, T, enc) : decode_full(mem, T, enc)
        result isa Invalid && return result
        (x, n) = result
        # `n ≤ N`, so the rest has at least `L - N` bytes
        return (x, n, MemoryInput{max(L - N, 0)}(unsafe_suffix(mem, n + 1), input.ends))
    end
    result = decode_start(mem, T, enc, input.ends)
    result isa Union{TooShort, Invalid} && return result
    (x, n) = result
    return (x, n, MemoryInput{0}(unsafe_suffix(mem, n + 1), input.ends))
end

@inline function decode_field(input::ReaderInput, ::Type{T}, enc::Encoding) where {T}
    result = decode_reader(input, T, enc, max_encoded_size(T, enc))
    result isa Union{TooShort, Invalid} && return result
    (x, n) = result
    return (x, n, ReaderInput(input.io, input.offset + n, input.stop))
end

# Decode a T from the start of `input`, filling the buffer of its reader as needed.
@inline function decode_reader(
        input::ReaderInput, ::Type{T}, enc::Encoding, ::Unbounded
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    return call_codec_try_decode(input, T, enc)
end

@inline function decode_reader(
        input::ReaderInput, ::Type{T}, enc::Encoding, N::Int
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    kind = codec_kind(T, enc)
    if kind isa BitsScheme
        return decode_bits(kind, (@? require_bytes(input, N)), T, enc)
    elseif n_buffered(input) ≥ N
        # No need to fill the buffer, so use the fast path
        buffer = get_buffer(input.io)::ImmutableMemoryView{UInt8}
        return decode_full(unsafe_suffix(buffer, input.offset + 1), T, enc)
    end
    # As for memory, the input of a bounded codec ends after N bytes
    field = ReaderInput(input.io, input.offset, min(input.stop, input.offset + N))
    result = call_codec_try_decode(field, T, enc)
    result isa TooShort && n_buffered(field) ≥ N && throw_too_short_error(codec_try_decode, T, enc)
    return result
end

# The number of bytes that the codec may have read from the input
@inline n_buffered(input::MemoryInput) = length(input.mem)
@inline function n_buffered(input::ReaderInput)
    return min(input.stop, length(get_buffer(input.io)::ImmutableMemoryView{UInt8})) - input.offset
end

@noinline throw_negative_count(n::Integer) = throw(ArgumentError("expected a non-negative count, got $n"))

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
  Since `output` never holds more than `max_encoded_size(T, enc)` bytes, these are at most the first `max_encoded_size(T, enc)` bytes
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
returned byte count is not in `1:length(mem)`, also in an `@inbounds` context. This is
because the byte count is used to consume bytes from writers, so a codec that broke its
contract in this way would otherwise corrupt memory, or, by returning zero, make loops
that decode or encode until the end of the data never end.
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

As for [`decode_field`](@ref), when `output` is known to hold at least
`max_encoded_size(T, enc)` bytes, `x` is encoded on the fast path, and `rest` is known to
hold the number of bytes that remain.
"""
@inline function encode_field(output::EncodeOutput{L}, x::T, enc::Encoding) where {L, T}
    N = max_encoded_size(T, enc)
    mem = output.mem
    if N isa Int && (L ≥ N || length(mem) ≥ N)
        n = if codec_kind(T, enc) isa BitsScheme
            unsafe_encode_bits!(mem, 0, x, enc)
            N
        else
            @? encode_full(mem, x, enc)
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
# byte count a codec returns. They also call the codec of proxied types, which is part of
# the package, so its byte count is not checked. Callers trust it with `@inbounds`, e.g. to consume it from a
# reader or writer, or to slice the rest of a memory view.

@inline function call_codec_try_decode(
        input::DecodeInput, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T}
    scheme = codec_kind(T, enc)
    scheme isa Proxy && return proxy_try_decode(input, T, scheme, enc)
    result = codec_try_decode(input, T, enc)
    result isa Union{TooShort, Invalid} && return result
    (x, n) = result
    # Check only what keeps a broken codec from causing undefined behaviour or endless
    # loops, see `valid_count`. LLVM often removes this check, when the codec has checked
    # the length itself. Its other contract violations are its own bugs, and are not
    # caught here.
    len = n_buffered(input)
    valid_count(n, len) || throw_count_error(codec_try_decode, T, enc, n, len)
    return (x, n)
end

@inline function call_codec_try_encode!(
        output::EncodeOutput, x::T, enc::Encoding
    )::Union{Int, TooShort, Invalid} where {T}
    scheme = codec_kind(T, enc)
    scheme isa Proxy && return proxy_try_encode!(output, x, scheme, enc)
    n = codec_try_encode!(output, x, enc)
    n isa Union{TooShort, Invalid} && return n
    # Check only what keeps a broken codec from causing undefined behaviour or endless
    # loops, see `call_codec_try_decode`.
    len = length(output.mem)
    valid_count(n, len) || throw_count_error(codec_try_encode!, T, enc, n, len)
    return n
end

# Whether the byte count `n` returned by a codec for memory of length `len` is in
# `1:len`. A count above `len` would make callers read or consume bytes beyond the
# memory. Since the input or output ends after `max_encoded_size` bytes, this also checks
# that `n` is at most that. A count of zero would make loops that decode or encode until
# the end of the data never end. One comparison checks both bounds.
@inline valid_count(n::Int, len::Int) = ((n - 1) % UInt) < (len % UInt)

# Outlined, and given the length rather than `mem`, so the error path doesn't make `mem`
# escape, see `check_start_index`.
@noinline function throw_count_error(f, ::Type{T}, enc::Encoding, n, mem_length::Int) where {T}
    return error(
        "`$(nameof(f))` for `$T` with `$enc` broke its contract: it returned a byte count " *
            "of $n, which is not in 1:length(mem), where length(mem) == $mem_length"
    )
end

@noinline function throw_too_short_error(f, ::Type{T}, enc::Encoding) where {T}
    return error(
        "`$(nameof(f))` for `$T` with `$enc` broke its contract: it returned `TooShort` " *
            "although it was given `max_encoded_size` bytes"
    )
end
