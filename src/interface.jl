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
    return if codec_kind(T, enc) isa NotBits
        codec_max_encoded_size(T, enc)
    else
        bits_encoded_size(T)
    end
end

"""
    try_decode(
        mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError}

Decode a `T` from the start of `mem`, treating `mem` as the complete input.
Return the value and the number of bytes used, or a [`DecodeError`](@ref).

`mem` may be mutable or immutable. Other types of memory, such as `Vector{UInt8}` or
`String`, must be converted by the caller, e.g. with `MemoryView(v)`. To decode from an
offset, slice `mem`, e.g. `try_decode(mem[5:end], UInt16, LittleEndian())`.

The error kind is:
* `EndOfInput` if `mem` is empty, unless a `T` can be encoded in zero bytes;
* `Truncated` if `mem` ends partway through an encoding, unless the encoding defines a
  meaning for incomplete input, as [`UTF8`](@ref) does;
* `InvalidData` if the bytes are not a valid encoding.

This function is not an extension point: never add methods to it. Implement a codec
instead, see [`Encoding`](@ref).

See also: [`decode`](@ref), [`try_load`](@ref)

# Examples
```jldoctest
julia> try_decode(MemoryView([0x01, 0x02, 0x03]), UInt16, LittleEndian())
(0x0201, 2)

julia> try_decode(MemoryView([0x01]), UInt16, LittleEndian())
DecodeError(BufferSerde.DecodeErrorKinds.Truncated)

julia> try_decode(MemoryView([0x02]), Bool, LittleEndian())
DecodeError(BufferSerde.DecodeErrorKinds.InvalidData)
```

# Extended help
## Char and UTF-8
`try_decode(mem, Char, UTF8())` follows `String` iteration exactly. The lead byte sets
the maximum length (`00`–`bf` and `f8`–`ff`: 1 byte, `c0`–`df`: 2, `e0`–`ef`: 3,
`f0`–`f7`: 4), and each following byte is taken while it is a continuation byte, until
the maximum length or the end of `mem` is reached. Validity is never checked, so
overlong encodings, surrogates and truncated sequences decode to a malformed `Char`.
Therefore, the only possible error is `EndOfInput`, for an empty `mem`.
"""
@inline function try_decode(
        mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    mem = ImmutableMemoryView(mem)
    kind = codec_kind(T, enc)
    kind isa NotBits && return codec_try_decode(mem, T, enc)
    n = bits_encoded_size(T)
    length(mem) < n && return short_error(mem)
    x = @try_return unsafe_decode_bits(kind, mem, 0, T, enc)
    return (x, n)
end

"""
    decode(mem::MemoryView{UInt8}, ::Type{T}, enc::Encoding)::Tuple{T, Int}

Like [`try_decode`](@ref), but throw the [`DecodeError`](@ref) instead of returning it.

# Examples
```jldoctest
julia> decode(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian())
(0x0102, 2)

julia> decode(MemoryView(UInt8[]), UInt16, BigEndian())
ERROR: DecodeError: End of input: no bytes left to decode
[...]
```
"""
function decode(mem::MemoryView{UInt8}, T::Type, enc::Encoding)
    result = try_decode(mem, T, enc)
    result isa DecodeError && throw_decode_error(result)
    return result
end

"""
    encode!(mem::MutableMemoryView{UInt8}, x::T, enc::Encoding)::Union{Nothing, Int}

Encode `x` at the start of `mem`. Return the number of bytes written,
or `nothing` if `mem` is too short.

Other types of memory, such as `Vector{UInt8}`, must be converted by the caller, e.g.
with `MemoryView(v)`.

Bytes of `mem` beyond the returned number of bytes may also be overwritten, and so may
bytes of `mem` when `nothing` is returned.

This function is not an extension point: never add methods to it. Implement a codec
instead, see [`Encoding`](@ref).

See also: [`store`](@ref)

# Examples
```jldoctest
julia> v = zeros(UInt8, 3);

julia> encode!(MemoryView(v), 0x0102, BigEndian()), v
(2, UInt8[0x01, 0x02, 0x00])

julia> encode!(MemoryView(v), 0x01020304, BigEndian()) # too short
```
"""
@inline function encode!(mem::MutableMemoryView{UInt8}, x::T, enc::Encoding)::Union{Nothing, Int} where {T}
    codec_kind(T, enc) isa NotBits && return codec_encode!(mem, x, enc)
    n = bits_encoded_size(T)
    length(mem) < n && return nothing
    unsafe_encode_bits!(mem, 0, x, enc)
    return n
end

"""
    codec_max_encoded_size(::Type{T}, ::E)::Int

Extension point of a hand-written codec for the value type `T` and the encoding type
`E`, see [`Encoding`](@ref). Never call it directly; call [`max_encoded_size`](@ref).

Return an upper bound on the number of bytes of any encoding of a `T`. The result must
be constant-foldable. Loading and storing buffer this many bytes, if available, before
calling [`codec_try_decode`](@ref) or [`codec_encode!`](@ref).
"""
function codec_max_encoded_size end

"""
    codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E
    )::Union{Tuple{T, Int}, DecodeError}

Extension point of a hand-written codec for the value type `T` and the encoding type
`E`, see [`Encoding`](@ref). Never call it directly; call [`try_decode`](@ref).

Decode a `T` from the start of `mem`, as described for [`try_decode`](@ref).
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
"""
function codec_try_decode end

"""
    codec_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)::Union{Nothing, Int}

Extension point of a hand-written codec for the value type `T` and the encoding type
`E`, see [`Encoding`](@ref). Never call it directly; call [`encode!`](@ref).

Encode `x` at the start of `mem`, and return the number of bytes written, or `nothing`
if `mem` is too short. An implementation must follow this contract:
* It must succeed if `length(mem) ≥ max_encoded_size(T, enc)`.
* It may write to `mem` beyond the returned byte count, and may write to `mem` even
  when it returns `nothing`.
"""
function codec_encode! end
