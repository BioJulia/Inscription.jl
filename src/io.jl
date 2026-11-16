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
DecodeError(BufferSerde.DecodeErrorKinds.Truncated)

julia> try_load(io, UInt8, LittleEndian())
0x03

julia> try_load(io, UInt8, LittleEndian())
DecodeError(BufferSerde.DecodeErrorKinds.EndOfInput)
```
"""
@inline function try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError} where {T}
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline buffer_value(io, max_encoded_size(T, enc))
    end
    result = try_decode(buffer, T, enc)
    result isa DecodeError && return result
    (x, n) = result
    @inbounds consume(io, n)
    return x
end

# Buffer at least n bytes, or everything up to EOF. Either way, `try_decode` on the
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
    store(io::AbstractBufWriter, x, enc::Encoding)::Int

Store `x` into `io` with the encoding `enc`, and return the number of bytes written.

Throw an `IOError` of kind `BufferTooShort` if `io` can't provide a buffer of
[`max_encoded_size(typeof(x), enc)`](@ref max_encoded_size) bytes, either because it is
full, or because its buffer can't grow large enough. Writers that can always grow, such
as those returned by `BufferIO.expandable`, never throw this.
If `store` throws, nothing has been consumed.

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
@inline function store(io::AbstractBufWriter, x::T, enc::Encoding)::Int where {T}
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline write_buffer(io, max_encoded_size(T, enc))
    end
    n = encode!(buffer, x, enc)::Int # guaranteed for codecs of bits types, and by the contract of `codec_encode!`
    @inbounds consume(io, n)
    return n
end

# Get a writer's buffer of at least n bytes, or throw `BufferTooShort`.
function write_buffer(io::AbstractBufWriter, n::Int)::MutableMemoryView{UInt8}
    buffer = get_nonempty_buffer(io, n)
    buffer === nothing && throw(IOError(IOErrorKinds.BufferTooShort))
    return buffer
end
