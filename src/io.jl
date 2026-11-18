"""
    try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Load a value of type `T` from `io`, and consume its bytes.
If the data does not hold a complete, valid encoding of a `T`, return a
[`DecodeError`](@ref) and consume nothing.

| Situation                                     | Result                              |
|:--------------------------------------------- |:----------------------------------- |
| Complete, valid encoding available            | the value; its bytes are consumed   |
| EOF with no bytes left                        | `DecodeError(EndOfInput)`           |
| EOF partway through an encoding               | `DecodeError(Truncated)`            |
| Invalid encoding                              | `DecodeError(InvalidData)`          |

A load either consumes a whole encoding and returns a value, or consumes nothing.

Throw an `IOError` of kind `BufferTooShort` if the buffer capacity of `io` is smaller
than [`max_encoded_size(T, enc)`](@ref max_encoded_size). This is a property of how
`io` was constructed, not of its data, and never happens for readers that can expand
their buffer, such as those returned by `BufferIO.expandable`.
Note that with such a too-small reader, `try_load` may still return a `DecodeError`
if the data ends before the buffer is filled.

See also: [`load`](@ref), [`try_decode`](@ref), [`load_into!`](@ref)

# Examples
```jldoctest
julia> io = CursorReader([0x01, 0x02, 0x03]);

julia> try_load(io, UInt16, LittleEndian())
0x0201

julia> try_load(io, UInt16, LittleEndian()) # nothing is consumed
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)

julia> try_load(io, UInt8, LittleEndian())
0x03

julia> try_load(io, UInt8, LittleEndian())
DecodeError(BitScribbling.DecodeErrorKinds.EndOfInput)
```
"""
@inline function try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError} where {T}
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline buffer_value(io, max_encoded_size(T, enc))
    end
    result = try_decode_sized(buffer, 1, T, enc)
    result isa DecodeError && return result
    (x, n) = result
    @inbounds consume(io, n)
    return x
end

# Buffer at least n bytes, or everything up to EOF. Either way, decoding from the
# result gives the right answer: with n bytes, rule 4 of `try_decode`'s contract means
# more bytes can't change it, and at EOF the buffer is the complete input.
# `get_nonempty_buffer` throws `BufferTooShort` if the capacity of `io` is smaller than n.
function buffer_value(io::AbstractBufReader, n::Int)::ImmutableMemoryView{UInt8}
    buffer = get_nonempty_buffer(io, n)
    # nothing means EOF before n bytes could be buffered
    return buffer === nothing ? get_buffer(io)::ImmutableMemoryView{UInt8} : buffer
end

"""
    load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::T

Like [`try_load`](@ref), but throw the [`DecodeError`](@ref) instead of returning it.

# Examples
```jldoctest
julia> io = CursorReader([0x01, 0x02, 0x03]);

julia> load(io, UInt16, BigEndian())
0x0102

julia> load(io, UInt16, BigEndian())
ERROR: DecodeError: Truncated input: the input ended partway through an encoded value
[...]
```
"""
function load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::T where {T}
    result = try_load(io, T, enc)
    result isa DecodeError && throw_decode_error(result)
    return result
end

"""
    try_store(io::AbstractBufWriter, x, enc::Encoding)::Union{Int, EncodeError}

Store `x` into `io` with the encoding `enc`, and return the number of bytes written.
If `x` can't be encoded with `enc`, return an [`EncodeError`](@ref) of kind
`InvalidValue`, and consume nothing.

Throw an `IOError` of kind `BufferTooShort` if `io` can't provide a buffer of
[`max_encoded_size(typeof(x), enc)`](@ref max_encoded_size) bytes, either because it is
full, or because its buffer can't grow large enough. Writers that can always grow, such
as those returned by `BufferIO.expandable`, never throw this. Like the buffer capacity
of a reader for [`try_load`](@ref), this is a property of how `io` was constructed, not
of `x`, so it is thrown rather than returned.
If `try_store` throws, nothing has been consumed.

When `x` can't be encoded, bytes of the buffer of `io` after the consumed bytes may have
been written, as by [`try_encode!`](@ref). Since they are not consumed, they are not
part of the output.

See also: [`store`](@ref), [`try_encode!`](@ref)

# Examples
```jldoctest
julia> io = VecWriter();

julia> try_store(io, 'é', UTF8())
2

julia> io.vec
2-element Vector{UInt8}:
 0xc3
 0xa9
```
"""
@inline function try_store(io::AbstractBufWriter, x::T, enc::Encoding)::Union{Int, EncodeError} where {T}
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline write_buffer(io, max_encoded_size(T, enc))
    end
    # The buffer holds at least `max_encoded_size` bytes, so the only error is that `x`
    # can't be encoded, also by the contract of `codec_encode!`.
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks.
    n = @inbounds _try_encode!(buffer, 1, x, enc)
    n isa EncodeError && return n
    @inbounds consume(io, n)
    return n
end

"""
    store(io::AbstractBufWriter, x, enc::Encoding)::Int

Like [`try_store`](@ref), but throw the [`EncodeError`](@ref) instead of returning it.

See also: [`encode!`](@ref), [`store_all`](@ref)

# Examples
```jldoctest
julia> io = VecWriter();

julia> store(io, 0x0102, BigEndian()), store(io, 'é', UTF8())
(2, 2)

julia> io.vec
4-element Vector{UInt8}:
 0x01
 0x02
 0xc3
 0xa9
```
"""
@inline function store(io::AbstractBufWriter, x, enc::Encoding)::Int
    result = try_store(io, x, enc)
    result isa EncodeError && throw_encode_error(result)
    return result
end

# Get a writer's buffer of at least n bytes, or throw `BufferTooShort`.
# Callers encode into the buffer with `@inbounds`, trusting that it holds n bytes. Since
# writers may implement `get_nonempty_buffer` themselves, check that they do, so a writer
# that breaks its contract can't make them write out of bounds. This is the slow path, so
# the check costs nothing on the fast path, where callers check the length themselves.
function write_buffer(io::AbstractBufWriter, n::Int)::MutableMemoryView{UInt8}
    buffer = get_nonempty_buffer(io, n)
    buffer === nothing && throw(IOError(IOErrorKinds.BufferTooShort))
    length(buffer) < n && throw_short_buffer_error(io, n, length(buffer))
    return buffer
end

@noinline function throw_short_buffer_error(io::AbstractBufWriter, n::Int, buffer_length::Int)
    return error(
        "`get_nonempty_buffer(io, $n)` for `$(typeof(io))` broke its contract: it returned " *
            "a buffer of $buffer_length bytes, fewer than the $n requested"
    )
end
