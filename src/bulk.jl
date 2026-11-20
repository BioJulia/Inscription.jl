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

"""
    decode_all!(dst, src, enc::Encoding)::Tuple{Int, Int}

Decode elements from the start of the bytes `src` into `dst`, until `dst` is full or
the next element fails to decode. Return the number of elements decoded, and the number
of bytes of `src` used. `src` is treated as the complete input, as in
[`try_decode`](@ref).

`dst` is mutable memory of elements, and `src` memory of bytes, either as `MemoryView`s
or as other memory that `MemoryView` can view, such as `Vector`s, see
[`try_decode`](@ref). They must not overlap.

To learn why decoding stopped before `dst` was full, call `try_decode` at the index after
the bytes used. To throw that error instead, use [`decode_every!`](@ref).

With an [`Endianness`](@ref) encoding, types whose [`bits_kind`](@ref) is
[`BitsLoadable`](@ref) are copied with `memcpy`, or a vectorized byte swap loop, when
an array of them is their encoding, up to byte order. Other types are decoded element by element.

See also: [`encode_all!`](@ref), [`load_all!`](@ref)

# Examples
```jldoctest
julia> dst = zeros(UInt16, 3);

julia> decode_all!(MemoryView(dst), MemoryView([0x01, 0x00, 0x02, 0x00, 0x03]), LittleEndian())
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
ignored. Like for [`decode_all!`](@ref), `dst` and `src` may be e.g. `MemoryView`s or
`Vector`s, and must not overlap.

If an element fails to decode, throw its [`DecodeError`](@ref), as [`decode`](@ref)
throws it at the index where the element starts. So if `src` ends between two elements,
the error is `EndOfInput`, and `Truncated` means that `src` ended partway through an
element. When `decode_every!` throws, the elements before the failing one have been
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
        (k, n) = decode_elements!(rest_dst, unsafe_suffix(src, n_bytes + 1), enc, true)
        n_elements += k
        n_bytes += n
        n_elements == length(dst) && return n_bytes
        # `decode_elements!` stops before `dst` is full only if the next element fails
        # to decode, so this throws its error. If it decodes the element anyway, e.g.
        # because the codec is not pure, use the element.
        (x, next) = decode_next(src, n_bytes + 1, T, enc)
        n_elements += 1
        @inbounds dst[n_elements] = x
        n_bytes = next - 1
    end
    return
end

# Decode elements of src into dst. If `complete` is false, src is not the complete input,
# so only decode elements that the bytes in src decide, see `codec_bytes_needed`.
@inline function decode_elements!(
        dst::MutableMemoryView{T},
        src::ImmutableMemoryView{UInt8},
        enc::Encoding,
        complete::Bool,
    )::Tuple{Int, Int} where {T}
    kind = codec_kind(T, enc)
    if !(kind isa Opaque)
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
    max_size = codec_max_encoded_size(T, enc)
    n_elements = 0
    n_bytes = 0
    while n_elements < length(dst)
        rest = @inbounds src[(n_bytes + 1):end]
        # By rule 4 of `codec_try_decode`, `max_size` bytes decide the element
        if !complete && length(rest) < max_size && codec_bytes_needed(rest, T, enc) > length(rest)
            break
        end
        result = call_codec_try_decode(rest, T, enc)
        result isa DecodeError && break
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
`dst` has no room for the next element, or the next element can't be encoded. Return the
number of elements encoded, and the number of bytes written.

`dst` is mutable memory of bytes, and `src` memory of elements, either as `MemoryView`s
or as other memory that `MemoryView` can view, such as `Vector`s, see
[`try_decode`](@ref). They must not overlap.

To learn why encoding stopped before `src` was exhausted, call [`try_encode!`](@ref) at
the index after the bytes written. To throw an error instead, use
[`encode_every!`](@ref).

Bytes of `dst` after the returned number of bytes are not written, unless encoding
stopped at an element that can't be encoded. Then, bytes after them may have been
written as by `try_encode!` for that element.

With an [`Endianness`](@ref) encoding, types whose [`bits_kind`](@ref) is
[`BitsLoadable`](@ref) or [`BitsStorable`](@ref) are copied with `memcpy`, or a
vectorized byte swap loop, when an array of them is their encoding, up to byte order. Other types are
encoded element by element.

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
    if !(codec_kind(T, enc) isa Opaque)
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
        n = call_codec_try_encode!((@inbounds dst[(n_bytes + 1):end]), x, enc)
        n isa EncodeError && return (n_elements, n_bytes)
        n_bytes += n
    end
    return (length(src), n_bytes)
end

"""
    encode_every!(dst, src, enc::Encoding)::Int

Encode every element of `src` into the start of the bytes `dst`, and return the number of
bytes written. Like for [`encode_all!`](@ref), `dst` and `src` may be e.g.
`MemoryView`s or `Vector`s, and must not overlap.

If an element can't be encoded, throw as [`encode!`](@ref) throws for it at the index
after the bytes written: a `LightBoundsError` if `dst` has no room for it, and an
[`EncodeError`](@ref) of kind `InvalidValue` if it can't be encoded at all. When
`encode_every!` throws, the elements before the failing one have been encoded into the
start of `dst`, and bytes after them may have been written, as by `encode!`.

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
        (k, n) = encode_all!(unsafe_suffix(dst, n_bytes + 1), unsafe_suffix(src, n_elements + 1), enc)
        n_elements += k
        n_bytes += n
        n_elements == length(src) && return n_bytes
        # `encode_all!` stops before `src` is exhausted only if the next element can't be
        # encoded, so this throws its error. If it encodes the element anyway, e.g.
        # because the codec is not pure, continue after it.
        n_elements += 1
        n_bytes += encode!(dst, n_bytes + 1, (@inbounds src[n_elements]), enc)
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

Load elements from `io` into the start of `dst`. Return the number of elements loaded,
and the number of bytes consumed from `io`. `dst` is a `MutableMemoryView`, or other
mutable memory that `MemoryView` can view, such as a `Vector`, see [`try_decode`](@ref).

Load at least one element, unless `dst` is empty, `io` is EOF, or the next element in
`io` fails to load. Each element is loaded all-or-nothing, as in [`try_load`](@ref):
loading stops at the first element that fails, and nothing of that element is consumed.
So a following `try_load(io, T, enc)` reports why.

Like `try_load`, wait only until the bytes buffered in `io` decide the next element, and
throw an `IOError` of kind `BufferTooShort` if `io` must buffer more bytes than its
capacity. This can only happen if the capacity is smaller than
[`max_encoded_size(T, enc)`](@ref max_encoded_size).

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
    complete = false
    if length(buffer) < max_encoded_size(T, enc)
        (buffer, complete) = @noinline buffer_decided(io, T, enc)
    end
    (n_elements, n_bytes) = decode_elements!(dst, buffer, enc, complete)
    @inbounds consume(io, n_bytes)
    return (n_elements, n_bytes)
end

"""
    load_all!(io::AbstractBufReader, dst, enc::Encoding)::Tuple{Int, Int}

Load elements from `io` into `dst` until `dst` is full, `io` is EOF, or the next element
fails to load. Return the number of elements loaded, and the number of bytes consumed
from `io`.
Elements are loaded all-or-nothing, as in [`load_into!`](@ref).

To throw an error unless `dst` is filled, use [`load_every!`](@ref).

See also: [`store_all`](@ref), [`decode_all!`](@ref)

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
        (k, n) = load_into!(io, dst, enc)
        iszero(k) && break
        n_elements += k
        n_bytes += n
        dst = @inbounds dst[(k + 1):end]
    end
    return (n_elements, n_bytes)
end

"""
    load_every!(io::AbstractBufReader, dst, enc::Encoding)::Int

Load elements from `io` until `dst` is full, and return the number of bytes consumed.
Like for [`load_into!`](@ref), `dst` may be e.g. a `MutableMemoryView` or a `Vector`.
If an element fails to load, throw a [`DecodeError`](@ref).

The elements are loaded all-or-nothing, as in [`load_into!`](@ref). So when
`load_every!` throws, the elements before the failing one have been consumed from `io`
and written to the start of `dst`, and nothing of the failing element has been consumed.

The error is that of the failing element, as [`try_load`](@ref) reports it. So if `io`
ends between two elements, the error is `EndOfInput`, also when some elements were
loaded, and `Truncated` means that `io` ended partway through an element. This is like
`read!` from Base, which throws an `EOFError` in both cases.

Like `try_load`, throw an `IOError` of kind `BufferTooShort` if `io` must buffer more
bytes than its capacity, which can only happen if the capacity is smaller than
[`max_encoded_size(T, enc)`](@ref max_encoded_size).

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
        (n_elements, n_bytes) = load_into!(io, dst, enc)
        if iszero(n_elements)
            # `load_into!` loads nothing only if the next element fails to load, so
            # this gets the error. If it loads an element anyway, e.g. because the codec
            # is not pure, use the element.
            result = try_load_sized(io, T, enc)
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

Store elements of `src` into `io`. Return the number of elements stored, and the number
of bytes written. `src` is a `MemoryView`, or other memory that `MemoryView` can view,
such as a `Vector`, see [`try_decode`](@ref).

Store at least one element, unless `src` is empty or its first element can't be
encoded. Each element is stored all-or-nothing, as in [`try_store`](@ref): storing stops
at the first element that can't be encoded, and nothing of that element is consumed.
So a following `try_store` of that element reports why.

Like `try_store`, throw an `IOError` of kind `BufferTooShort` if `io` can't provide a
buffer of [`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes. If `src` is
empty, nothing is stored, and this is not thrown.

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
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    if length(buffer) < max_encoded_size(T, enc)
        buffer = @noinline write_buffer(io, max_encoded_size(T, enc))
    end
    # The buffer has room for any element, so encoding stops before the first
    # element only if it can't be encoded, by the contract of `codec_try_encode!`.
    (n_elements, n_bytes) = encode_all!(buffer, src, enc)
    @inbounds consume(io, n_bytes)
    return (n_elements, n_bytes)
end

"""
    store_all(io::AbstractBufWriter, src, enc::Encoding)::Tuple{Int, Int}

Store elements of `src` into `io` until `src` is exhausted or the next element can't be
encoded. Return the number of elements stored, and the number of bytes written.
Elements are stored all-or-nothing, as in [`store_into`](@ref).

To throw an error unless every element is stored, use [`store_every`](@ref).

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
        (k, n) = store_into(io, src, enc)
        iszero(k) && break
        n_elements += k
        n_bytes += n
        src = @inbounds src[(k + 1):end]
    end
    return (n_elements, n_bytes)
end

"""
    store_every(io::AbstractBufWriter, src, enc::Encoding)::Int

Store every element of `src` into `io`, and return the number of bytes written. Like for
[`store_into`](@ref), `src` may be e.g. a `MemoryView` or a `Vector`.

Like [`store`](@ref), throw an `IOError` of kind `BufferTooShort` if `io` can't
provide a buffer of [`max_encoded_size(T, enc)`](@ref max_encoded_size) bytes, and
throw an [`EncodeError`](@ref) if an element can't be encoded.
Each element is stored all-or-nothing, but elements before the one that could not be
stored remain stored.

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
        (n_elements, n_bytes) = store_into(io, src, enc)
        if iszero(n_elements)
            # `store_into` stores nothing only if the first element can't be
            # encoded, so `store` throws the error. If it stores the element anyway,
            # e.g. because the codec is not pure, use the element.
            n_bytes = store(io, (@inbounds src[1]), enc)
            n_elements = 1
        end
        n_total += n_bytes
        src = @inbounds src[(n_elements + 1):end]
    end
    return n_total
end
