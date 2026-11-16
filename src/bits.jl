"""
    abstract type BitsKind end

The kinds of [`bits_kind`](@ref), currently: [`BitsLoadable`](@ref),
[`BitsStorable`](@ref) and [`NotBits`](@ref).

These zero-sized trait structs signal how a primitive type `T` can be loaded/stored:
* If the serialization is the same as the in-memory representation, and all
  bitpatterns are valid, it can be loaded/stored with a pointer operations,
  and so `bits_kind(T)` should be `BitsLoadable()`. Examples: `UInt32`, `Float64`.
* Else, if serialization is the same as in-memory representation, but some
  bitpatterns are not valid, `bits_kind(T)` must return `BitsStorable()`.
  Examples: `Bool`.
* Else, `bits_kind(T)` should be `NotBits()`, which is the default for types.
  For such types
  Examples: `Char`.

See the docstring of the individual types for more details.
"""
abstract type BitsKind end

"""
    BitsLoadable() <: BitsKind

Implementing `bits_kind(T) = BitsLoadable()` signals instances of type `T`
can be loaded and stored via casting raw memory, e.g. with a pointer load.
Examples: `UInt32`, `Float64`, `UInt8`.

For such a type `T`, implement only:
* `bits_kind(T) = BitsLoadable()`
"""
struct BitsLoadable <: BitsKind end

"""
    BitsStorable() <: BitsKind

Implementing `bits_kind(T) = BitsStorable()` signals instances of `T` can be
stored by writing the `T` directly to memory, e.g. with a pointer store.
However, all bitpatterns may not be valid. Hence, when loading instances of `T`,
the data can be loaded as an integer, then validated via [`is_valid_bits`](@ref).

For such a type `T`, implement:
* `bits_kind(T) = BitsStorable()`
* `is_valid_bits(::T)::Bool`
"""
struct BitsStorable <: BitsKind end

"""
    NotBits() <: BitsKind

The default value of `bits_kind(T)` is `NotBits()`. It signals that the serialized data
of a `T` is not the same as its representation in memory. Therefore, storing and loading
requires hand-written load and store methods.

For such a type `T`, implement per supported `E::Encoding`:
* [`codec_max_encoded_size(::Type{T}, ::E)`](@ref codec_max_encoded_size)
* [`codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)`](@ref codec_try_decode)
* [`codec_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)`](@ref codec_encode!)
"""
struct NotBits <: BitsKind end

"""
    bits_kind(::Type{T})::BitsKind

Compute the `BitsKind` instance of `T`. This method should be constant foldable.

See also: [`BitsKind`](@ref)
"""
bits_kind(::Type)::BitsKind = NotBits()

bits_kind(
    ::Union{
        Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128},
        Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128},
        Type{Float16}, Type{Float32}, Type{Float64},
    }
) = BitsLoadable()

bits_kind(::Type{Bool}) = BitsStorable()
bits_kind(::Type{<:Enum}) = BitsStorable()

# TODO: This schema does not support more than 128 bits, but we should in the future.
# When Julia supports arbitrary bitsized, this should be an Unsigned which rounds
# bitsizeof(T) up to the nearest whole byte
"""
    is_valid_bits(::Type{T}, raw::Unsigned)::Bool

Whether the bits `raw` are a valid `T`, for a type `T` whose [`bits_kind`](@ref) is
[`BitsStorable`](@ref). The owner of such a type must implement this method.

`raw` holds the `Base.bitsizeof(T)` bits of the would-be `T` in the low bits of the
smallest of `UInt8`, `UInt16`, `UInt32`, `UInt64` or `UInt128` that can hold them.
Unused upper bits are zero.
"""
function is_valid_bits end

# Bool is always 0x00 or 0x01 in memory, but pointer-loading it keeps only the lowest
# bit, so the bits must be checked before a Bool is made from them.
is_valid_bits(::Type{Bool}, raw::UInt8) = raw ≤ 0x01

# If the values of `T` are contiguous, which is the common case, a range check suffices.
# `enum_range` is constant-folded, so only one of the branches is compiled.
@inline function is_valid_bits(::Type{T}, raw::Unsigned) where {T <: Enum}
    (lo, span, contiguous) = enum_range(T, typeof(raw))
    return if contiguous
        (raw - lo) ≤ span
    else
        any(x -> Integer(x) % typeof(raw) == raw, instances(T))
    end
end

# The bits of the smallest value of the enum `T`, the difference between the largest
# and smallest value, and whether the values are contiguous, all as `U`. Arithmetic in
# `U` wraps around, so `raw - lo ≤ span` is a range check also for signed base types.
# This doesn't use `typemin(T)` and `typemax(T)`: they go through the checked constructor
# of `T`, which looks the value up in a `Dict` at runtime when the values have gaps.
# The effects allow the compiler to evaluate this at compile time.
Base.@assume_effects :foldable function enum_range(::Type{T}, ::Type{U}) where {T <: Enum, U}
    values = instances(T)
    lo = hi = Integer(first(values))
    for x in values
        lo = min(lo, Integer(x))
        hi = max(hi, Integer(x))
    end
    span = (hi - lo) % U
    return (lo % U, span, span == length(values) - 1)
end

# The kind of the codec for T with the encoding `enc`. Hand-written codecs are `NotBits`.
@inline function codec_kind(::Type{T}, enc::Encoding)::BitsKind where {T}
    enc isa Endianness || return NotBits()
    isprimitivetype(T) || return NotBits()
    return bits_kind(T)::BitsKind
end

# The number of bits of T that hold its value. Before Julia 1.14, the bit width of
# primitive types is a multiple of 8, and their size is not rounded up.
@static if isdefined(Base, :bitsizeof)
    bit_size(T::Type) = Base.bitsizeof(T)
else
    bit_size(T::Type) = 8 * sizeof(T)
end

# The number of bytes of the encoding of a bits type.
bits_encoded_size(T::Type) = cld(bit_size(T), 8)

# Whether the bits of T fill its in-memory bytes, so that its memory is its encoding,
# up to byte order. Since Julia 1.14, the size of e.g. a 24-bit primitive type is rounded
# up to 4 bytes, and it is loaded with a 4-byte load.
fills_bytes(T::Type) = bit_size(T) == 8 * sizeof(T)

# Whether an array of T is its encoding, up to byte order: the bits of T fill its bytes,
# and the elements of arrays have no gaps between them. Before Julia 1.14, `sizeof`
# excluded the padding that the internal `Base.aligned_sizeof` includes, so e.g. a 24-bit
# primitive type has a size of 3 bytes, but its elements in arrays are 4 bytes apart.
# Julia 1.14 merged the two. `Base.elsize` is the public way to get the padded size.
is_dense_bits(T::Type) = fills_bytes(T) && Base.elsize(Memory{T}) == sizeof(T)

# The unsigned integer that `is_valid_bits` receives the bits of T in.
function raw_type(T::Type)
    n = bit_size(T)
    return if n ≤ 8
        UInt8
    elseif n ≤ 16
        UInt16
    elseif n ≤ 32
        UInt32
    elseif n ≤ 64
        UInt64
    elseif n ≤ 128
        UInt128
    else
        throw(ArgumentError("Decoding BitsStorable types wider than 128 bits is not supported"))
    end
end

# Whether the encoding of T is exactly as wide as its `raw_type`, so that it can be loaded
# as that integer with one load, e.g. a 30-bit type as a `UInt32`. LLVM doesn't combine
# the byte loads of the general path into one load when the padding check comes first,
# as it does for big-endian input.
function loads_as_raw(T::Type)
    bit_size(T) ≤ 128 || return false
    return bits_encoded_size(T) == sizeof(raw_type(T))
end

# Convert between native byte order and the byte order `e`.
@inline function byte_order(e::Endianness, x)
    return if sizeof(x) == 1 || e === NATIVE_ENDIAN
        x
    else
        Core.Intrinsics.bswap_int(x)
    end
end

# Unaligned, unchecked load of a `T` at byte offset `offset` from the start of `mem`,
# and the corresponding store. The caller must ensure that the sizeof(T) bytes are
# within `mem`.
# The memory-ref builtins are preferred over pointers, because their accesses carry the
# alias information of Memory data: they can't alias e.g. fields of a mutable struct,
# such as the position of a reader. They are not in a released Julia yet, so detect
# them rather than checking the version.
@static if isdefined(Core, :unsafe_memoryrefload) && isdefined(Core, :unsafe_memoryrefstore!)
    @inline function unsafe_load_at(mem::MemoryView, ::Type{T}, offset::Int) where {T}
        return Core.unsafe_memoryrefload(MemoryViews.unsafe_memoryref(mem), T, offset, false)::T
    end

    @inline function unsafe_store_at!(mem::MutableMemoryView, x, offset::Int)
        Core.unsafe_memoryrefstore!(MemoryViews.unsafe_memoryref(mem), x, offset, false)
        return nothing
    end
else
    @inline function unsafe_load_at(mem::MemoryView, ::Type{T}, offset::Int) where {T}
        return GC.@preserve mem unsafe_load(Ptr{T}(Ptr{UInt8}(pointer(mem)) + offset))
    end

    @inline function unsafe_store_at!(mem::MutableMemoryView, x::T, offset::Int) where {T}
        GC.@preserve mem unsafe_store!(Ptr{T}(Ptr{UInt8}(pointer(mem)) + offset), x)
        return nothing
    end
end

# Unaligned load of a T in byte order `e`, with the requirements of `unsafe_load_at`.
# T must fill its bytes.
@inline function unsafe_load_bits(mem::MemoryView, offset::Int, ::Type{T}, e::Endianness) where {T}
    return byte_order(e, unsafe_load_at(mem, T, offset))
end

# Unaligned store of x in byte order `e`, with the requirements of `unsafe_store_at!`.
# The type of x must fill its bytes.
@inline function unsafe_store_bits(mem::MutableMemoryView, offset::Int, x, e::Endianness)
    unsafe_store_at!(mem, byte_order(e, x), offset)
    return nothing
end

# Types whose bits don't fill their bytes are loaded and stored as the N encoded bytes,
# and converted with integer intrinsics, which don't depend on the memory layout of T.
# The bytes are ordered from least to most significant.

# Load the N bytes at `offset` in byte order `e`, least significant first.
@inline function unsafe_load_bytes(mem::MemoryView, offset::Int, ::Val{N}, e::Endianness) where {N}
    bytes = unsafe_load_at(mem, NTuple{N, UInt8}, offset)
    return e === LittleEndian() ? bytes : reverse(bytes)
end

# Store the N bytes, given least significant first, at `offset` in byte order `e`.
@inline function unsafe_store_bytes!(
        mem::MutableMemoryView, offset::Int, bytes::NTuple{N, UInt8}, e::Endianness
    ) where {N}
    unsafe_store_at!(mem, e === LittleEndian() ? bytes : reverse(bytes), offset)
    return nothing
end

# Whether the bits of the most significant byte that are not part of a T are zero.
@inline function has_zero_padding(::Type{T}, bytes::NTuple{N, UInt8}) where {T, N}
    n_padding = 8 * N - bit_size(T)
    return iszero(n_padding) || iszero(bytes[N] >> (8 - n_padding))
end

# Whether the bits of the integer `raw` that are not part of a T are zero.
@inline function has_zero_padding(::Type{T}, raw::Unsigned) where {T}
    return bit_size(T) == 8 * sizeof(raw) || iszero(raw >> bit_size(T))
end

# Assemble the primitive type X from bytes, least significant first. The bits of X must
# hold all the bits of the bytes, except zero padding bits of the most significant byte.
@inline function from_bytes(::Type{X}, bytes::NTuple{N, UInt8}) where {X, N}
    x = from_byte(X, bytes[N])
    for i in (N - 1):-1:1
        # Since N > 1, X has more than 8 bits.
        x = Core.Intrinsics.or_int(Core.Intrinsics.shl_int(x, 8), Core.Intrinsics.zext_int(X, bytes[i]))
    end
    return x
end

@inline function from_byte(::Type{X}, byte::UInt8) where {X}
    n = bit_size(X)
    return if n == 8
        Core.Intrinsics.bitcast(X, byte)
    elseif n < 8
        Core.Intrinsics.trunc_int(X, byte)
    else
        Core.Intrinsics.zext_int(X, byte)
    end
end

# The N bytes of the primitive value x, least significant first.
@inline function to_bytes(x::X, ::Val{N}) where {X, N}
    return ntuple(i -> to_byte(Core.Intrinsics.lshr_int(x, 8 * (i - 1))), Val(N))
end

@inline function to_byte(x::X) where {X}
    n = bit_size(X)
    return if n == 8
        Core.Intrinsics.bitcast(UInt8, x)
    elseif n < 8
        Core.Intrinsics.zext_int(UInt8, x)
    else
        Core.Intrinsics.trunc_int(UInt8, x)
    end
end

# Decode a T of kind `kind` at `offset` in `mem`. The caller must ensure that the
# `bits_encoded_size(T)` bytes are within `mem`.
@inline function unsafe_decode_bits(
        ::BitsLoadable, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, DecodeError} where {T}
    fills_bytes(T) && return unsafe_load_bits(mem, offset, T, e)
    if loads_as_raw(T)
        raw = unsafe_load_bits(mem, offset, raw_type(T), e)
        has_zero_padding(T, raw) || return DecodeError(InvalidData)
        return Core.Intrinsics.trunc_int(T, raw)
    end
    bytes = unsafe_load_bytes(mem, offset, Val(bits_encoded_size(T)), e)
    has_zero_padding(T, bytes) || return DecodeError(InvalidData)
    return from_bytes(T, bytes)
end

@inline function unsafe_decode_bits(
        ::BitsStorable, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, DecodeError} where {T}
    U = raw_type(T)
    # The bits are checked as a `U`, because they may not be a valid T.
    raw = if loads_as_raw(T)
        raw = unsafe_load_bits(mem, offset, U, e)
        has_zero_padding(T, raw) || return DecodeError(InvalidData)
        raw
    else
        bytes = unsafe_load_bytes(mem, offset, Val(bits_encoded_size(T)), e)
        has_zero_padding(T, bytes) || return DecodeError(InvalidData)
        from_bytes(U, bytes)
    end
    is_valid_bits(T, raw)::Bool || return DecodeError(InvalidData)
    return if bit_size(T) == 8 * sizeof(U)
        Core.Intrinsics.bitcast(T, raw)
    else
        Core.Intrinsics.trunc_int(T, raw)
    end
end

# Encode x at `offset` in `mem`. The caller must ensure that the
# `bits_encoded_size(T)` bytes are within `mem`.
@inline function unsafe_encode_bits!(mem::MutableMemoryView, offset::Int, x::T, e::Endianness) where {T}
    if fills_bytes(T)
        unsafe_store_bits(mem, offset, x, e)
    else
        unsafe_store_bytes!(mem, offset, to_bytes(x, Val(bits_encoded_size(T))), e)
    end
    return nothing
end
