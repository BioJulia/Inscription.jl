"""
    try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Load a value of type `T` from `io`, and consume its bytes.
If the data does not hold a complete, valid encoding of a `T`, return a
[`DecodeError`](@ref).

A load either consumes a whole encoding and returns a value, or throws and consumes nothing.

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

# Extended help
## Buffering behaviour
This function calls `grow_buffer` until `io` is EOF, or enough bytes has been buffered
in IO to decode the value, or to decide the value is invalid.
By default, that is when [`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes
are buffered. [`Unbounded`](@ref) types are buffered as their codec reads them.
For variable-length encodings, like `Char`'s `UTF8` encoding, this can cause blocking.
Suppose `io` contains the single byte `'a'` (byte `0x61`) and blocks until that is read.
A char encodes in up to 4 bytes, so `io` would wait indefinitely for more bytes to arrive.
But the codec of `Char` for `UTF8` only reads the byte `0x61` to decode `'a'`, so `io`
doesn't wait for more, see [`DecodeInput`](@ref).

## Too short buffers
If `io` is not EOF, and its buffer contains fewer bytes than needed according to the
section above, and its buffer cannot grow, throw an `IOError` of kind `BufferTooShort`.
Therefore, you must ensure that a partial value is never in a non-growable buffer.
To handle generic `AbstractBufReader`s, you can use `BufferIO.expandable`, which 
guarantees this does not happen.

## Error kinds
The `DecodeErrorKind` in the thrown error is given by this table

| Situation                                     | Result                              |
|:--------------------------------------------- |:----------------------------------- |
| Complete, valid encoding available            | the value; its bytes are consumed   |
| EOF with no bytes left                        | `DecodeError(EndOfInput)`           |
| EOF partway through an encoding               | `DecodeError(Truncated)`            |
| Invalid encoding                              | `DecodeError(InvalidData)`          |


"""
@inline function try_load(io::AbstractBufReader, ::Type{T}, enc::Encoding)::Union{T, DecodeError} where {T}
    (x, _) = @? try_load_sized(io, T, enc)
    return x
end

# Like `try_load`, but also return the number of bytes consumed.
@inline function try_load_sized(
        io::AbstractBufReader, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    holds_any(length(buffer), T, enc) || return @inline load_slow(io, T, enc)
    result = try_decode_sized(buffer, 1, T, enc)
    result isa DecodeError && return result
    (_, n) = result
    @inbounds consume(io, n)
    return result
end

# `try_load_sized`, or, without a codec, `try_load`, which the user may have overloaded.
# Only called when loading is expected to fail.
function load_failing(
        io::AbstractBufReader, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    has_codec(T, enc) && return try_load_sized(io, T, enc)
    result = try_load(io, T, enc)
    result isa DecodeError && return result
    return throw_load_into_error(T, enc)
end

@noinline function throw_load_into_error(::Type{T}, enc::Encoding) where {T}
    return error(
        "The method of `load_into!` for `$T` with `$enc` broke its contract: it loaded no " *
            "elements, but `try_load` loaded the next element"
    )
end

# The slow path of `try_load_sized`
function load_slow(
        io::AbstractBufReader, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    (x, n) = @? peek_value(io, T, enc)
    @inbounds consume(io, n)
    return (x, n)
end

# Decode a T from the start of `io`, without consuming it. Its bytes are buffered as the
# codec reads them, so the codec runs once, and no more bytes are waited for than it reads.
# The bytes of the T are in the buffer afterwards.
function peek_value(
        io::AbstractBufReader, ::Type{T}, enc::Encoding
    )::Union{Tuple{T, Int}, DecodeError} where {T}
    # Measurably faster than calling `get_nonempty_buffer` also when bytes are buffered
    if isempty(get_buffer(io)::ImmutableMemoryView{UInt8})
        get_nonempty_buffer(io) === nothing && return DecodeError(EndOfInput)
    end
    input = ReaderInput(io, 0, typemax(Int))
    result = decode_reader(input, T, enc, max_encoded_size(T, enc))
    result isa TooShort && return DecodeError(Truncated)
    result isa Invalid && return DecodeError(InvalidData)
    return result
end

# Buffer at least n bytes, or everything up to EOF.
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
    try_load_exact(io::AbstractBufReader, nbytes::Integer, ::Type{T}, enc::Encoding)::Union{T, DecodeError}

Load a value of type `T` from the next `nbytes` bytes of `io`, which must be exactly one
encoding of a `T`, as for [`try_decode_exact`](@ref). On success, consume the `nbytes`
bytes. Otherwise, return a [`DecodeError`](@ref) and consume nothing.

Use it to load a value whose size is known from the data, such as a field with a length
prefix, or a column of a fixed width. Unlike [`try_load`](@ref), it waits for no more
than `nbytes` bytes, and doesn't need the codec to find the end of the encoding.

The error kind is:
* `EndOfInput` if `io` is at EOF;
* `Truncated` if `io` reaches EOF before `nbytes` bytes;
* otherwise, the error of `try_decode_exact` for the `nbytes` bytes. Since an encoding
  is at most [`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes, a larger
  `nbytes` always gives an error.

Throw an `ArgumentError` if `nbytes` is negative, and an `IOError` of kind
`BufferTooShort` if the buffer capacity of `io` is smaller than `nbytes`.

See also: [`load_exact`](@ref)

# Examples
```jldoctest
julia> io = CursorReader("éab");

julia> try_load_exact(io, 2, Char, UTF8())
'é': Unicode U+00E9 (category Ll: Letter, lowercase)

julia> try_load_exact(io, 2, Char, UTF8()) # 'a' is followed by 'b'
DecodeError(BitScribbling.DecodeErrorKinds.TrailingData)

julia> try_load_exact(io, 1, Char, UTF8()) # nothing was consumed
'a': ASCII/Unicode U+0061 (category Ll: Letter, lowercase)

julia> try_load_exact(io, 2, Char, UTF8())
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)
```
"""
@inline function try_load_exact(
        io::AbstractBufReader, nbytes::Integer, ::Type{T}, enc::Encoding
    )::Union{T, DecodeError} where {T}
    nbytes = Int(nbytes)::Int
    nbytes < 0 && throw_negative_nbytes_error(nbytes)
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    if length(buffer) < nbytes
        buffer = @noinline buffer_value(io, nbytes)
        # `buffer_value` returns fewer bytes only at EOF
        length(buffer) < nbytes && return DecodeError(isempty(buffer) ? EndOfInput : Truncated)
    end
    x = @? try_decode_exact((@inbounds buffer[1:nbytes]), T, enc)
    @inbounds consume(io, nbytes)
    return x
end

@noinline function throw_negative_nbytes_error(nbytes::Int)
    throw(ArgumentError("`nbytes` must not be negative, but it is $nbytes"))
end

"""
    load_exact(io::AbstractBufReader, nbytes::Integer, ::Type{T}, enc::Encoding)::T

Like [`try_load_exact`](@ref), but throw the [`DecodeError`](@ref) instead of returning
it.

# Examples
```jldoctest
julia> load_exact(CursorReader([0x00, 0x01]), 2, UInt16, BigEndian())
0x0001
```
"""
function load_exact(io::AbstractBufReader, nbytes::Integer, ::Type{T}, enc::Encoding)::T where {T}
    result = try_load_exact(io, Int(nbytes)::Int, T, enc)
    result isa DecodeError && throw_decode_error(result)
    return result
end

"""
    try_store(io::AbstractBufWriter, x, enc::Encoding)::Union{Int, EncodeError}

Store `x` into `io` with the encoding `enc`, and return the number of bytes written.
If `x` can't be encoded with `enc`, return an [`EncodeError`](@ref) of kind
`InvalidValue`, and consume nothing.

Throw an `IOError` of kind `BufferTooShort` if `io` can't provide a buffer of
[`max_encoded_size(typeof(x), enc)`](@ref max_encoded_size) bytes, or, for
[`Unbounded`](@ref) types, of the size of the encoding, either because it is
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
    max_encoded_size(T, enc) isa Unbounded && return store_unbounded(io, x, enc)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    max_size = max_encoded_size(T, enc)
    if length(buffer) < max_size
        # `@noinline` also applies to calls in the arguments, so there must be none
        buffer = @noinline write_buffer(io, max_size)
    end
    # The buffer holds at least `max_encoded_size` bytes, so the only error is that `x`
    # can't be encoded, also by the contract of `codec_try_encode!`.
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks.
    n = @inbounds _try_encode!(buffer, 1, x, enc)
    n isa EncodeError && return n
    @inbounds consume(io, n)
    return n
end

"""
    store(io::AbstractBufWriter, x, enc::Encoding)::Int

Like [`try_store`](@ref), but throw the [`EncodeError`](@ref) instead of returning it.

See also: [`encode!`](@ref), [`store_every`](@ref)

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
    # Only the fast path, where the buffer holds at least `max_encoded_size` bytes, is
    # inlined. The slow path, including its error, is handled by an outlined function that
    # returns the final result, so the caller's code has no error branch after the call.
    # This is faster, and the code smaller, than implementing `store` with `try_store`.
    # Doing the same for `try_store`, or the load functions, made them slower.
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    # Without a codec, `try_store` is the method that the user added
    has_codec(T, enc) || return @noinline store_slow(io, x, enc)
    max_encoded_size(T, enc) isa Unbounded && return @noinline store_slow(io, x, enc)
    length(buffer) < max_encoded_size(T, enc) && return @noinline store_slow(io, x, enc)
    # Calls `_try_encode!` directly, so that `@inbounds` reaches its checks, see `try_store`
    n = @inbounds _try_encode!(buffer, 1, x, enc)
    n isa EncodeError && throw_encode_error(n)
    @inbounds consume(io, n)
    return n
end

# `try_store` of unbounded types. Encode into the buffer, and grow it until there is room.
@noinline function store_unbounded(io::AbstractBufWriter, x, enc::Encoding)::Union{Int, EncodeError}
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    while true
        result = encode_short(buffer, x, enc)
        result isa Invalid && return EncodeError(InvalidValue)
        if result isa Int
            @inbounds consume(io, result)
            return result
        end
        # A codec that breaks its contract may ask for no more bytes than the buffer has
        needed = max(result.needed, length(buffer) + 1)
        # Growing doesn't wait for anything, so at least double the buffer, such that the
        # encodings of all attempts take linear time. A writer with a limited buffer may
        # have room for `needed` bytes, but not for twice the buffer.
        is_expandable(typeof(io)) && (needed = max(needed, 2 * length(buffer)))
        buffer = write_buffer(io, needed)
    end
    return
end

function store_slow(io::AbstractBufWriter, x, enc::Encoding)::Int
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

@noinline function throw_short_buffer_error(
        io::Union{AbstractBufReader, AbstractBufWriter}, n::Int, buffer_length::Int
    )
    return error(
        "`get_nonempty_buffer(io, $n)` for `$(typeof(io))` broke its contract: it returned " *
            "a buffer of $buffer_length bytes, fewer than the $n requested"
    )
end
