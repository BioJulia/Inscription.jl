# The bulk functions come in three kinds, named by their suffix:
# * `_into` encodes or decodes as many elements as one buffer of an IO holds.
# * `_all` encodes or decodes as many elements as possible.
# * `_every` encodes or decodes every element, or throws the error of the one that fails.
# The `_into` and `_all` functions return how far they got, as the number of elements
# and the number of bytes. The `_every` functions return the number of bytes, since the
# number of elements is that of the input.
# Memory isn't buffered, so there are no `_into` functions for memory.
# As for Base's `write`, a `!` marks that memory is written, not that an IO is advanced.
# So the loads end with `!`, and the stores don't.

# The bulk functions call each other and the scalar functions, which users may overload.
# So the counts they return are checked, before they are trusted with `@inbounds`.
@inline function check_count(f::F, n::Int, max::Int)::Int where {F}
    (n % UInt) ≤ (max % UInt) || throw_bulk_count_error(nameof(f), n, max)
    return n
end

@noinline function throw_bulk_count_error(name::Symbol, n::Int, max::Int)
    return error("A method of `$name` broke its contract: it returned a count of $n, which is not in 0:$max")
end

"""
    decode_all!(dst, src, enc::Encoding)::Tuple{Int, Int}

Decode elements from the start of the bytes `src` into `dst`, until `dst` is full or
the next element fails to decode.
Return `(n_elements_decoded, n_bytes_read)`.

To learn why decoding stopped before `dst` was full, call `try_decode` at the index after
the bytes used. To throw that error instead, use [`decode_every!`](@ref).

The arguments `dst` is converted to a `MutableMemoryView{T}`, and `src` to
`ImmutableMemoryView{UInt8}`. `dst` and `src` may not alias (overlap in memory).

The input `src` is treated as a complete input. That means that if a partial encoding
is trailing in `src`, it will be attempted to be decoded, which may or may not fail.
This means that if there is trailing data which is a prefix of an encoded element,
and this prefix happens to decode on its own without error, it will be decoded. 

See also: [`encode_all!`](@ref), [`load_all!`](@ref)

# Examples
```jldoctest
julia> dst = zeros(UInt16, 3); src = [0x01, 0x00, 0x02, 0x00, 0x03];

julia> decode_all!(dst, src, LittleEndian())
(2, 4)

julia> dst
3-element Vector{UInt16}:
 0x0001
 0x0002
 0x0000
```
"""
function decode_all!(
        dst::MutableMemoryView{T}, src::MemoryView{UInt8}, enc::Encoding
    )::Tuple{Int, Int} where {T}
    return decode_elements!(dst, ImmutableMemoryView(src), enc, true)
end

"""
    decode_every!(dst, src, enc::Encoding)::Int

Decode elements from the start of the bytes `src` until `dst` is full, and return the
number of bytes of `src` used. Bytes of `src` after those used are allowed, and are
ignored.

The arguments `dst` is converted to a `MutableMemoryView{T}`, and `src` to
`ImmutableMemoryView{UInt8}`. `dst` and `src` may not alias (overlap in memory).

If an element fails to decode, throw its [`DecodeError`](@ref), as [`decode`](@ref)
throws it at the index where the element starts.
So if `src` ends between two elements, the error is `EndOfInput`.
`Truncated` means that `src` ended partway through an element.
When `decode_every!` throws, the elements before the failing one have been
written to the start of `dst`.

See also: [`encode_every!`](@ref), [`load_every!`](@ref)

# Examples
```jldoctest
julia> dst = zeros(UInt16, 2);

julia> decode_every!(dst, [0x01, 0x00, 0x02, 0x00, 0x03], LittleEndian()), dst
(4, UInt16[0x0001, 0x0002])

julia> decode_every!(dst, [0x01, 0x00, 0x02], LittleEndian())
ERROR: DecodeError: Truncated input: the input ended partway through an encoded value
[...]
```
"""
function decode_every!(
        dst::MutableMemoryView{T}, src::MemoryView{UInt8}, enc::Encoding
    )::Int where {T}
    src = ImmutableMemoryView(src)
    n_elements = 0
    n_bytes = 0
    while true
        rest_dst = @inbounds dst[(n_elements + 1):end]
        rest_src = unsafe_suffix(src, n_bytes + 1)
        (k, n) = decode_all!(rest_dst, rest_src, enc)::Tuple{Int, Int}
        n_elements += check_count(decode_all!, k, length(rest_dst))
        n_bytes += check_count(decode_all!, n, length(rest_src))
        n_elements == length(dst) && return n_bytes
        # `decode_all!` stops before `dst` is full only if the next element fails
        # to decode, so this throws its error. If it decodes the element anyway, e.g.
        # because the codec is not pure, use the element.
        result = try_decode_next(src, n_bytes + 1, T, enc)
        result isa DecodeError && throw_decode_error(result)
        (x, next) = result
        n_elements += 1
        @inbounds dst[n_elements] = x
        n_bytes += check_count(try_decode_next, next - 1 - n_bytes, length(src) - n_bytes)
    end
    return
end

# Decode elements of src into dst. If `complete` is false, src is not the complete input,
# so only decode elements that the bytes in src decide, see `codec_try_decode`.
@inline function decode_elements!(
        dst::MutableMemoryView{T},
        src::ImmutableMemoryView{UInt8},
        enc::Encoding,
        complete::Bool,
    )::Tuple{Int, Int} where {T}
    kind = codec_kind(T, enc)
    if kind isa BitsScheme
        # Fixed size: each whole element in src is decided
        element_size = bits_encoded_size(T)
        n_max = min(length(dst), div(length(src), element_size))
        if kind isa BitsLoadable && is_dense_bits(T)
            unsafe_bulk_load!(dst, src, n_max, enc)
            return (n_max, n_max * element_size)
        end
        for i in 1:n_max
            x = unsafe_decode_bits(kind, src, (i - 1) * element_size, T, enc)
            x isa DecodeError && return (i - 1, (i - 1) * element_size)
            @inbounds dst[i] = x
        end
        return (n_max, n_max * element_size)
    end
    n_elements = 0
    n_bytes = 0
    while n_elements < length(dst)
        rest = @inbounds src[(n_bytes + 1):end]
        # With partial input, an element that is not decided yet also gives `TooShort`
        result = decode_start(rest, T, enc, complete)
        result isa Union{TooShort, Invalid} && break
        (x, n) = result
        n_elements += 1
        @inbounds dst[n_elements] = x
        n_bytes += n
    end
    return (n_elements, n_bytes)
end

# Decode the first n elements of src into dst. T must be BitsLoadable and dense bits.
# The caller must check the lengths.
@inline function unsafe_bulk_load!(
        dst::MutableMemoryView{T}, src::ImmutableMemoryView{UInt8}, n::Int, e::Endianness
    ) where {T}
    if sizeof(T) == 1 || e === NATIVE_ENDIAN
        GC.@preserve dst src unsafe_copyto!(Ptr{UInt8}(pointer(dst)), pointer(src), n * sizeof(T))
    else
        for i in 0:(n - 1)
            x = unsafe_decode_bits(BitsLoadable(), src, i * sizeof(T), T, e)::T
            unsafe_store_at!(dst, x, i * sizeof(T))
        end
    end
    return nothing
end

"""
    encode_all!(dst, src, enc::Encoding)::Tuple{Int, Int}

Encode elements of `src` into the start of the bytes `dst`, until `src` is exhausted,
`dst` has no room for the next element, or the next element can't be encoded.
Return `(n_elements_encoded, n_bytes_written)`

To learn why encoding stopped before `src` was exhausted, call [`try_encode!`](@ref) at
the index after the bytes written. To throw an error instead, use
[`encode_every!`](@ref).

The argument `dst` is converted to `MutableMemoryView{UInt8}`, and `src` to
`ImmutableMemoryView{T}`. These two arrays may not alias (overlap in memory).

If encoding stopped before `src` was exhausted, up to
[max_encoded_size(T, enc)](@ref max_encoded_size) bytes after the first
`n_bytes_written`, but not past the end of `dst`, may have been written, and their
contents are unspecified.

See also: [`decode_all!`](@ref), [`store_all`](@ref)

# Examples
```jldoctest
julia> dst = zeros(UInt8, 5);

julia> encode_all!(MemoryView(dst), MemoryView(UInt16[1, 2, 3]), BigEndian())
(2, 4)

julia> dst
5-element Vector{UInt8}:
 0x00
 0x01
 0x00
 0x02
 0x00
```
"""
function encode_all!(
        dst::MutableMemoryView{UInt8}, src::MemoryView{T}, enc::Encoding
    )::Tuple{Int, Int} where {T}
    if codec_kind(T, enc) isa BitsScheme
        element_size = bits_encoded_size(T)
        n_elements = min(length(src), div(length(dst), element_size))
        if is_dense_bits(T)
            unsafe_bulk_store!(dst, src, n_elements, enc)
        else
            for i in 1:n_elements
                unsafe_encode_bits!(dst, (i - 1) * element_size, (@inbounds src[i]), enc)
            end
        end
        return (n_elements, n_elements * element_size)
    end
    n_bytes = 0
    for n_elements in 0:(length(src) - 1)
        x = @inbounds src[n_elements + 1]
        n = encode_start(unsafe_suffix(dst, n_bytes + 1), x, enc)
        n isa Union{TooShort, Invalid} && return (n_elements, n_bytes)
        n_bytes += n
    end
    return (length(src), n_bytes)
end

"""
    encode_every!(dst, src, enc::Encoding)::Int

Encode every element of `src` into the start of the bytes `dst`, and return the number of
bytes written. 

The argument `dst` is converted to `MutableMemoryView{UInt8}`, and `src` to
`ImmutableMemoryView{T}`. These two arrays may not alias (overlap in memory).

If an element can't be encoded, throw an exception:
* `LightBoundsError` if `dst` has no room for the element
* [`EncodeError`](@ref) of kind `InvalidValue` if it can't be encoded at all.

If encode_every! throws, the elements before the failing one have been encoded
into the start of `dst`.
Then, the contents of up to
[`max_encoded_size`(T, enc)](@ref max_encoded_size) bytes from where the failing element
would start, but not past the end of `dst`, are unspecified.

See also: [`decode_every!`](@ref), [`store_every`](@ref)

# Examples
```jldoctest
julia> dst = zeros(UInt8, 5);

julia> encode_every!(dst, ['a', 'é'], UTF8()), dst
(3, UInt8[0x61, 0xc3, 0xa9, 0x00, 0x00])

julia> encode_every!(dst, ['a', 'é', '€'], UTF8())
ERROR: LightBoundsErrors.LightBoundsError: out-of-bounds indexing: `collection[4:6]`, where:
[...]
```
"""
function encode_every!(
        dst::MutableMemoryView{UInt8}, src::MemoryView{T}, enc::Encoding
    )::Int where {T}
    n_elements = 0
    n_bytes = 0
    while true
        rest_dst = unsafe_suffix(dst, n_bytes + 1)
        rest_src = unsafe_suffix(src, n_elements + 1)
        (k, n) = encode_all!(rest_dst, rest_src, enc)::Tuple{Int, Int}
        n_elements += check_count(encode_all!, k, length(rest_src))
        n_bytes += check_count(encode_all!, n, length(rest_dst))
        n_elements == length(src) && return n_bytes
        # `encode_all!` stops before `src` is exhausted only if the next element can't be
        # encoded, so this throws its error. If it encodes the element anyway, e.g.
        # because the codec is not pure, continue after it.
        n_elements += 1
        result = try_encode!(dst, n_bytes + 1, (@inbounds src[n_elements]), enc)
        result isa EncodeError && throw_encode_failure(dst, n_bytes + 1, T, enc, result)
        n_bytes += check_count(try_encode!, result, length(dst) - n_bytes)
    end
    return
end

# Encode the first n elements of src into dst. T must be a bits type with dense bits.
# The caller must check the lengths.
@inline function unsafe_bulk_store!(
        dst::MutableMemoryView{UInt8}, src::MemoryView{T}, n::Int, e::Endianness
    ) where {T}
    if sizeof(T) == 1 || e === NATIVE_ENDIAN
        GC.@preserve dst src unsafe_copyto!(pointer(dst), Ptr{UInt8}(pointer(src)), n * sizeof(T))
    else
        for i in 0:(n - 1)
            x = unsafe_load_at(src, T, i * sizeof(T))
            unsafe_encode_bits!(dst, i * sizeof(T), x, e)
        end
    end
    return nothing
end

"""
    load_into!(io::AbstractBufReader, dst, enc::Encoding)::Tuple{Int, Int}

Load elements from `io` into the start of `dst`.
Return `(n_elements_loaded, n_bytes_consumed)

The argument `dst` is converted to a `MutableMemoryView{T}`.

Load at least one element, unless `dst` is empty, `io` is EOF, or the next element in
`io` fails to load. Other than that, the number of elements depends on the internal
buffer size of `io`. Therefore, this function may choose a buffer size more optimal
for `io` than [`load_all!`](@ref) or [`load_every!`](@ref).

Each element is loaded all-or-nothing, as in [`try_load`](@ref):
loading stops at the first element that fails, and nothing of that element is consumed.
So a following `try_load(io, T, enc)` reports why.

For its buffering behaviour, see [`try_load`](@ref).

See also: [`load_all!`](@ref), [`load_every!`](@ref), [`store_into`](@ref)

# Examples
```jldoctest
julia> io = CursorReader([0x00, 0x01, 0x00, 0x02, 0x00]);

julia> dst = zeros(UInt16, 3);

julia> load_into!(io, MemoryView(dst), BigEndian()), dst
((2, 4), UInt16[0x0001, 0x0002, 0x0000])

julia> load_into!(io, MemoryView(dst), BigEndian())
(0, 0)

julia> try_load(io, UInt16, BigEndian())
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)
```
"""
function load_into!(
        io::AbstractBufReader, dst::MutableMemoryView{T}, enc::Encoding
    )::Tuple{Int, Int} where {T}
    isempty(dst) && return (0, 0)
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    holds_any(length(buffer), T, enc) || return @noinline load_into_slow!(io, dst, enc)
    (n_elements, n_bytes) = decode_elements!(dst, buffer, enc, false)
    @inbounds consume(io, n_bytes)
    return (n_elements, n_bytes)
end

# The slow path of `load_into!`, where `dst` is not empty. Load the first element, filling
# the buffer as needed, then the elements that are already buffered. At most one element,
# the last, is decoded in vain, so loading elements until EOF takes linear time.
function load_into_slow!(
        io::AbstractBufReader, dst::MutableMemoryView{T}, enc::Encoding
    )::Tuple{Int, Int} where {T}
    result = peek_value(io, T, enc)
    result isa DecodeError && return (0, 0)
    (x, n) = result
    @inbounds dst[1] = x
    rest = unsafe_suffix(get_buffer(io)::ImmutableMemoryView{UInt8}, n + 1)
    (k, m) = decode_elements!((@inbounds dst[2:end]), rest, enc, false)
    @inbounds consume(io, n + m)
    return (k + 1, n + m)
end

"""
    load_all!(io::AbstractBufReader, dst, enc::Encoding)::Tuple{Int, Int}

Load elements from `io` into `dst` until `dst` is full, `io` is EOF, or the next element
fails to load.
Return (`n_elements_loaded, n_bytes_consumed`).

The argument `dst` is converted to a `MutableMemoryView{UInt8}`.

Elements are loaded all-or-nothing, as in [`load_into!`](@ref).
If `load_into!` stops before filling `dst`, you can use [`try_load`] to learn
why loading failed.

For its buffering behaviour, see [`try_load`](@ref).

See also: [`store_all`](@ref), [`decode_all!`](@ref), [`load_every!`](@ref)

# Examples
```jldoctest
julia> io = CursorReader([0x01, 0x00, 0x02, 0x00, 0x03]);

julia> dst = zeros(UInt16, 4);

julia> load_all!(io, MemoryView(dst), LittleEndian()), dst
((2, 4), UInt16[0x0001, 0x0002, 0x0000, 0x0000])
```
"""
function load_all!(io::AbstractBufReader, dst::MutableMemoryView, enc::Encoding)::Tuple{Int, Int}
    n_elements = 0
    n_bytes = 0
    while !isempty(dst)
        (k, n) = load_into!(io, dst, enc)::Tuple{Int, Int}
        iszero(check_count(load_into!, k, length(dst))) && break
        n_elements += k
        n_bytes += n
        dst = @inbounds dst[(k + 1):end]
    end
    return (n_elements, n_bytes)
end

"""
    load_every!(io::AbstractBufReader, dst, enc::Encoding)::Int

Load elements from `io` until `dst` is full, and return the number of bytes consumed.
The argument `dst` is converted to a `MutableMemoryView{T}`.

If an element fails to load, throw a [`DecodeError`](@ref).

The elements are loaded all-or-nothing.
So when `load_every!` throws, the elements before the failing one have been
consumed from `io` and written to the start of `dst`,
and nothing of the failing element has been consumed.

For the `DecodeErrorKind` of the thrown `DecodeError`, and for buffering behaviour,
see [`try_load`](@ref).
From its throwing behaviour follows that if `io` ends between two elements,
the error is `EndOfInput`, even when some elements were loaded.

See also: [`load_all!`](@ref), [`load`](@ref), [`decode_every!`](@ref)

# Examples
```jldoctest
julia> io = CursorReader([0x00, 0x01, 0x00, 0x02, 0x00]);

julia> dst = zeros(UInt16, 2);

julia> load_every!(io, dst, BigEndian()), dst
(4, UInt16[0x0001, 0x0002])

julia> load_every!(io, dst, BigEndian())
ERROR: DecodeError: Truncated input: the input ended partway through an encoded value
[...]
```
"""
function load_every!(io::AbstractBufReader, dst::MutableMemoryView{T}, enc::Encoding)::Int where {T}
    n_total = 0
    while !isempty(dst)
        (n_elements, n_bytes) = load_into!(io, dst, enc)::Tuple{Int, Int}
        check_count(load_into!, n_elements, length(dst))
        if iszero(n_elements)
            # `load_into!` loads nothing only if the next element fails to load, so
            # this gets the error. If it loads an element anyway, e.g. because the codec
            # is not pure, use the element.
            result = load_failing(io, T, enc)
            result isa DecodeError && throw_decode_error(result)
            (x, n_bytes) = result
            @inbounds dst[1] = x
            n_elements = 1
        end
        n_total += n_bytes
        dst = @inbounds dst[(n_elements + 1):end]
    end
    return n_total
end

"""
    store_into(io::AbstractBufWriter, src, enc::Encoding)::Tuple{Int, Int}

Store elements of `src` into `io`.
Return `(n_elements_stored, n_bytes_written)`
The argument `src` is converted to a `MemoryView{T}`.

Store at least one element, unless `src` is empty or its first element can't be
encoded.
Each element is stored all-or-nothing: storing stops at the first element
that can't be encoded, and nothing of that element is consumed.
Use `try_store` of the failed element to find out why it couldn't be stored.

For buffering behaviour, see [`try_store`](@ref).

See also: [`store_all`](@ref), [`store_every`](@ref), [`load_into!`](@ref)

# Examples
```jldoctest
julia> io = VecWriter();

julia> store_into(io, MemoryView(UInt16[1, 2]), BigEndian())
(2, 4)

julia> io.vec
4-element Vector{UInt8}:
 0x00
 0x01
 0x00
 0x02
```
"""
function store_into(
        io::AbstractBufWriter, src::MemoryView{T}, enc::Encoding
    )::Tuple{Int, Int} where {T}
    isempty(src) && return (0, 0)
    max_encoded_size(T, enc) isa Unbounded && return store_into_unbounded(io, src, enc)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    max_size = max_encoded_size(T, enc)
    if length(buffer) < max_size
        # `@noinline` also applies to calls in the arguments, so there must be none
        buffer = @noinline write_buffer(io, max_size)
    end
    # The buffer has room for any element, so encoding stops before the first
    # element only if it can't be encoded, by the contract of `codec_try_encode!`.
    (n_elements, n_bytes) = encode_all!(buffer, src, enc)::Tuple{Int, Int}
    @inbounds consume(io, check_count(encode_all!, n_bytes, length(buffer)))
    return (n_elements, n_bytes)
end

# Store the elements there is room for, or else the first one, growing the buffer.
function store_into_unbounded(io::AbstractBufWriter, src::MemoryView, enc::Encoding)::Tuple{Int, Int}
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    (n_elements, n_bytes) = encode_all!(buffer, src, enc)::Tuple{Int, Int}
    if iszero(n_elements)
        n = store_unbounded(io, (@inbounds src[1]), enc)
        return n isa EncodeError ? (0, 0) : (1, n)
    end
    @inbounds consume(io, check_count(encode_all!, n_bytes, length(buffer)))
    return (n_elements, n_bytes)
end

"""
    store_all(io::AbstractBufWriter, src, enc::Encoding)::Tuple{Int, Int}

Store elements of `src` into `io` until `src` is exhausted or the next element can't be
encoded.
Return `(n_elements_stored, n_bytes_written)`.

The argument `src` is converted to an `ImmutableMemoryView{T}`.

Elements are stored all-or-nothing, so either a full element is stored, or else
none of it is.

If `store_all` stops before exhausting `src`, you can learn why it stopped by
calling [`try_store`](@ref).

For buffering behaviour, see [`try_store`](@ref).

See also: [`load_all!`](@ref), [`encode_all!`](@ref)

# Examples
```jldoctest
julia> io = VecWriter();

julia> store_all(io, MemoryView(['a', 'é']), UTF8())
(2, 3)

julia> String(io.vec)
"aé"
```
"""
function store_all(io::AbstractBufWriter, src::MemoryView, enc::Encoding)::Tuple{Int, Int}
    n_elements = 0
    n_bytes = 0
    while !isempty(src)
        (k, n) = store_into(io, src, enc)::Tuple{Int, Int}
        iszero(check_count(store_into, k, length(src))) && break
        n_elements += k
        n_bytes += n
        src = @inbounds src[(k + 1):end]
    end
    return (n_elements, n_bytes)
end

"""
    store_every(io::AbstractBufWriter, src, enc::Encoding)::Int

Store every element of `src` into `io`, and return the number of bytes written.
The argument `src` is converted to an `ImmutableMemoryView{T}`.
Throw an `IOError` if `io` cannot provide enough buffering,
and an [`EncodeError`](@ref) if an element can't be encoded.

For details on the buffering behaviour, see [`try_store`](@ref).

Each element is stored all-or-nothing.

See also: [`store_all`](@ref), [`store`](@ref), [`encode_every!`](@ref)

# Examples
```jldoctest
julia> io = VecWriter();

julia> store_every(io, MemoryView(['a', 'é']), UTF8())
3

julia> String(io.vec)
"aé"
```
"""
function store_every(io::AbstractBufWriter, src::MemoryView{T}, enc::Encoding)::Int where {T}
    n_total = 0
    while !isempty(src)
        (n_elements, n_bytes) = store_into(io, src, enc)::Tuple{Int, Int}
        check_count(store_into, n_elements, length(src))
        if iszero(n_elements)
            # `store_into` stores nothing only if the first element can't be
            # encoded, so `try_store` returns the error. If it stores the element anyway,
            # e.g. because the codec is not pure, use the element.
            result = try_store(io, (@inbounds src[1]), enc)
            result isa EncodeError && throw_encode_error(result)
            n_bytes = result
            n_elements = 1
        end
        n_total += n_bytes
        src = @inbounds src[(n_elements + 1):end]
    end
    return n_total
end
