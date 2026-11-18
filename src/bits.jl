"""
    abstract type BitsKind end

The kinds of [`bits_kind`](@ref), currently: [`BitsLoadable`](@ref),
[`BitsStorable`](@ref) and [`ManualCodec`](@ref).

These zero-sized trait structs describe the bits of a primitive type or isbits struct
`T`, independent of any encoding:
* If a `T` is exactly its bits, and every bit pattern is a valid `T`, `bits_kind(T)`
  should be `BitsLoadable()`. Examples: `UInt32`, `Float64`.
* Else, if a `T` is exactly its bits, but some bit patterns are not valid, `bits_kind(T)`
  should be `BitsStorable()`. Examples: `Bool`, `Enum` types.
* Else, `bits_kind(T)` should be `ManualCodec()`, which is the default for all types.
  Examples: `Char`.

Each encoding decides whether it uses `bits_kind`. The byte-order encodings,
[`LittleEndian`](@ref) and [`BigEndian`](@ref), encode a `BitsLoadable` or `BitsStorable`
`T` as its bits, in the given byte order, if the bits of `T` fill whole bytes; see below
for the exact requirements. Other encodings, such as [`UTF8`](@ref), ignore `bits_kind`
and always use a hand-written codec.

Only the owner of `T` may declare it to be `BitsLoadable` or `BitsStorable`, since it
makes the bits of `T` part of its encodings.

# Extended help
## Primitive types
The byte-order encodings accept a `BitsLoadable` or `BitsStorable` primitive type `T`
only if its bit width, `Base.bitsizeof(T)` (before Julia 1.14: `8 * sizeof(T)`), is a
multiple of 8. Its encoding is then exactly its bits, in `bitsizeof(T) ÷ 8` bytes.
Since Julia 1.14, `sizeof` is rounded up, e.g. to 4 bytes for a 24-bit type, but that
padding is not part of the encoding.

Since Julia 1.14, primitive types may also have other bit widths, e.g. 18 bits. Encoding
such a type in whole bytes would need padding bits, so the byte-order encodings reject
it, and throw an `ArgumentError` when it is first encoded or decoded. The bits of such a
type may also be packed with the bits of other values, e.g. one 18-bit value starting in
the middle of the third byte of the previous one. This package works on whole bytes, so
it can't decode such data.

To encode such a type with a byte order anyway, leave its `bits_kind` as `ManualCodec`,
and write a codec for `LittleEndian` and `BigEndian`, see [`Encoding`](@ref). The codec
then decides how the value fills whole bytes, e.g. zero-extended to 3 bytes, and what
decoding does with bits that are not part of the value.

## Structs
An isbits struct `T` that is `BitsLoadable` or `BitsStorable` is encoded as its memory
representation, with the bytes of each primitive field, including those in nested
structs, in the byte order of the encoding. With the native byte order, this is
exactly its representation in memory.

Such a struct must satisfy these requirements, which are checked when it is first
encoded or decoded. If they don't hold, an `ArgumentError` is thrown:
* The [`bits_kind`](@ref) of each field is not `ManualCodec`, and the fields that are
  structs satisfy these requirements themselves.
* If `T` is `BitsLoadable`, all its fields are `BitsLoadable`.
* The bit width of each primitive field is a power of two, and at least 8, as for
  `UInt8`, `Float32` or `Int128`. So a field can't be e.g. a `primitive type Foo 24 end`.
* `T` has no padding on any platform.
* `T` is not of size zero, so it can't be e.g. a struct without fields.

Whether a struct has padding depends on the alignment of its fields, which depends on
the platform and the Julia version. For example, `UInt64` is aligned to 8 bytes on
x86-64, but may be aligned to 4 bytes on 32-bit platforms. Therefore, the last
requirement is checked against the strictest layout that any platform could give `T`:
the one in which every primitive type is aligned to its size. In this layout, the fields
follow each other without gaps, and
* each primitive field must start at a multiple of its size;
* each field that is a struct must start at a multiple of the size of its largest
  primitive field;
* the size of `T` must be a multiple of the size of its largest primitive field.

This makes the check, and so the encoding, the same on every platform and Julia version.
For example, a struct with the fields `a::UInt32` and `b::UInt64` is rejected also on
platforms where it has no padding. To satisfy the requirement, order the fields from
largest to smallest, or add fields for the padding, e.g. `pad::UInt32`.

Declare fields with explicit widths, such as `Int64`, never `Int` or `UInt`, whose
widths depend on the platform. This can't be checked, since `Int` is the same type as
`Int64` or `Int32`.
"""
abstract type BitsKind end

"""
    BitsLoadable() <: BitsKind

Implementing `bits_kind(::Type{T}) = BitsLoadable()` signals that a value of the primitive
type or isbits struct `T` is exactly its bits, and that every bit pattern is a valid `T`.
So a `T` can be made from any bits, e.g. by casting raw memory with a pointer load.
Examples: `UInt32`, `Float64`, `UInt8`.

For such a type `T`, implement only:
* `bits_kind(::Type{T}) = BitsLoadable()`

See [`BitsKind`](@ref) for which types the byte-order encodings accept, and for the
requirements of structs.
"""
struct BitsLoadable <: BitsKind end

"""
    BitsStorable() <: BitsKind

Implementing `bits_kind(::Type{T}) = BitsStorable()` signals that a value of the primitive
type or isbits struct `T` is exactly its bits, so it can be stored by writing them, e.g.
with a pointer store. However, not all bit patterns are valid. Hence, when decoding a
`T`, its bits are first checked with [`is_valid_bits`](@ref).

For such a type `T`, implement:
* `bits_kind(::Type{T}) = BitsStorable()`
* `is_valid_bits(::Type{T}, bytes::NTuple{N, UInt8})::Bool`

See [`BitsKind`](@ref) for which types the byte-order encodings accept, and for the
requirements of structs.
"""
struct BitsStorable <: BitsKind end

"""
    ManualCodec() <: BitsKind

The default value of `bits_kind(T)` is `ManualCodec()`. It signals that the encoding of a
`T` is not its representation in memory, so encoding and decoding it requires a
hand-written codec. This is the case for many bits types, e.g. `Char`, as well as for
types that are not bits types.

For such a type `T`, implement for each supported concrete encoding type `E`, see
[`Encoding`](@ref):
* [`codec_max_encoded_size(::Type{T}, ::E)`](@ref codec_max_encoded_size)
* [`codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)`](@ref codec_try_decode)
* [`codec_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)`](@ref codec_encode!)
"""
struct ManualCodec <: BitsKind end

"""
    bits_kind(::Type{T})::BitsKind

Compute the `BitsKind` instance of `T`. This method should be constant foldable.

See also: [`BitsKind`](@ref)
"""
bits_kind(::Type)::BitsKind = ManualCodec()

bits_kind(
    ::Union{
        Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128},
        Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128},
        Type{Float16}, Type{Float32}, Type{Float64},
    }
) = BitsLoadable()

bits_kind(::Type{Bool}) = BitsStorable()
bits_kind(::Type{<:Enum}) = BitsStorable()

"""
    is_valid_bits(::Type{T}, bytes::NTuple{N, UInt8})::Bool

Whether the bytes `bytes` are a valid `T`, for a type `T` whose [`bits_kind`](@ref) is
[`BitsStorable`](@ref). The owner of such a type must implement this method.

`N` is the number of bytes of the bits of `T`: `Base.bitsizeof(T) ÷ 8` for primitive
types, and `sizeof(T)` for structs. The bytes are in native byte order: the byte order of
the encoding has already been undone. So, if `bytes` are valid, they are the bits of the
value `x` that is being decoded:
* If `sizeof(T) == N`, `reinterpret(T, bytes)` gives the value. Since Julia 1.14,
  `sizeof` of e.g. a 24-bit primitive type is rounded up to 4, and `reinterpret` throws.
* For integer checks, use [`as_unsigned`](@ref).
* If `T` is a struct, `is_valid_bits` is called after the `is_valid_bits` of its
  `BitsStorable` fields. So, all fields are valid, and `reinterpret(T, bytes)` is safe.
  This method only needs to check the invariants that involve the whole value, and may
  simply return `true` if there are none.

# Examples
```julia
primitive type Digit 8 end # 0 to 9
BitScribbling.bits_kind(::Type{Digit}) = BitScribbling.BitsStorable()
BitScribbling.is_valid_bits(::Type{Digit}, bytes::NTuple{1, UInt8}) = bytes[1] ≤ 0x09
```
"""
function is_valid_bits end

# Bool is always 0x00 or 0x01 in memory, but pointer-loading it keeps only the lowest
# bit, so the bits must be checked before a Bool is made from them.
is_valid_bits(::Type{Bool}, bytes::NTuple{1, UInt8}) = bytes[1] ≤ 0x01

# If the values of `T` are contiguous, which is the common case, a range check suffices.
# `enum_range` is constant-folded, so only one of the branches is compiled.
@inline function is_valid_bits(::Type{T}, bytes::NTuple{N, UInt8}) where {T <: Enum, N}
    raw = as_unsigned(bytes)
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

"""
    as_unsigned(bytes::NTuple{N, UInt8})::Unsigned

Convert `bytes`, given in native byte order, to the smallest of `UInt8`, `UInt16`,
`UInt32`, `UInt64` and `UInt128` with at least `N` bytes, zero-extended.
Throw an `ArgumentError` if `N > 16`.

This is meant for implementing [`is_valid_bits`](@ref), whose bytes are in native byte
order, so that the byte order of the host doesn't matter. If `N` is the size of the
result, this is `reinterpret(U, bytes)`.

# Examples
```jldoctest
julia> x = 0x00ab_cdef;

julia> bytes = NATIVE_ENDIAN === LittleEndian() ? (0xef, 0xcd, 0xab) : (0xab, 0xcd, 0xef);

julia> BitScribbling.as_unsigned(bytes) === x
true
```
"""
@inline function as_unsigned(bytes::NTuple{N, UInt8}) where {N}
    U = uint_of_size(N)
    sizeof(U) == N && return reinterpret(U, bytes)
    least_first = NATIVE_ENDIAN === LittleEndian() ? bytes : reverse(bytes)
    x = zero(U)
    for i in N:-1:1
        x = (x << 8) | (least_first[i] % U)
    end
    return x
end

# The smallest unsigned integer type with at least n bytes.
function uint_of_size(n::Int)::Type{<:Unsigned}
    return if n ≤ 1
        UInt8
    elseif n ≤ 2
        UInt16
    elseif n ≤ 4
        UInt32
    elseif n ≤ 8
        UInt64
    elseif n ≤ 16
        UInt128
    else
        throw(ArgumentError("No unsigned integer type has $n bytes"))
    end
end

# The kind of the codec for T with the encoding `enc`. Hand-written codecs are
# `ManualCodec`.
# Throw an `ArgumentError` if T is declared to be a bits type, but can't be one.
# The check is constant-folded, so this costs nothing at runtime.
@inline function codec_kind(::Type{T}, enc::Encoding)::BitsKind where {T}
    enc isa Endianness || return ManualCodec()
    kind = bits_kind(T)::BitsKind
    kind isa ManualCodec && return kind
    message = bits_type_error(T, kind)
    message === nothing || throw(ArgumentError(message))
    return kind
end

kind_name(kind::BitsKind) = nameof(typeof(kind))

# Why T, whose `bits_kind` is `kind`, can't be a bits type, or `nothing` if it can.
# See the docstring of `BitsKind` for the requirements.
Base.@assume_effects :foldable function bits_type_error(
        ::Type{T}, kind::BitsKind
    )::Union{Nothing, String} where {T}
    if isprimitivetype(T)
        n_bits = bit_size(T)
        n_bits % 8 == 0 && return nothing
        return "`bits_kind($T)` is `$(kind_name(kind))`, but the bit width $n_bits of `$T` is not " *
            "a multiple of 8, so `LittleEndian` and `BigEndian` can't encode it as its bits. " *
            "To encode it in whole bytes, leave its `bits_kind` as `ManualCodec`, and write a codec " *
            "for each byte order"
    end
    if !(isstructtype(T) && isbitstype(T))
        return "`bits_kind($T)` is `$(kind_name(kind))`, but `$T` is neither a primitive type nor an isbits struct"
    end
    if iszero(sizeof(T))
        return "`$T` has a size of zero bytes, so it can't be `$(kind_name(kind))`: types of size zero are not supported"
    end
    # The offset of the next field in the strictest layout, see the docstring of `BitsKind`
    offset = 0
    for i in 1:fieldcount(T)
        F = fieldtype(T, i)
        name = fieldname(T, i)
        field_kind = bits_kind(F)::BitsKind
        if field_kind isa ManualCodec
            return "The field `$name` of `$T` has the type `$F`, whose `bits_kind` is `ManualCodec`"
        elseif kind isa BitsLoadable && !(field_kind isa BitsLoadable)
            return "`$T` is `BitsLoadable`, but its field `$name` has the type `$F`, which is `$(kind_name(field_kind))`"
        end
        if isprimitivetype(F)
            n_bits = bit_size(F)
            if !(n_bits ≥ 8 && ispow2(n_bits))
                return "The field `$name` of `$T` has the type `$F`, whose bit width $n_bits is not a power of two of at least 8"
            end
        else
            message = bits_type_error(F, field_kind)
            message === nothing || return message
        end
        alignment = strictest_alignment(F)
        if offset % alignment != 0
            of_what = isprimitivetype(F) ? "its type `$F`" : "the largest primitive field of its type `$F`"
            return "`$T` has padding on some or all platforms, so it can't be `$(kind_name(kind))`: " *
                "its field `$name` follows $offset bytes of other fields, which is not a multiple of " *
                "$alignment, the size of $of_what"
        end
        # This holds if every primitive type is aligned to at most its size
        if offset != fieldoffset(T, i)
            return "`$T` has padding before its field `$name`, so it can't be `$(kind_name(kind))`"
        end
        offset += sizeof(F)
    end
    alignment = strictest_alignment(T)
    if offset % alignment != 0
        return "`$T` has padding on some or all platforms, so it can't be `$(kind_name(kind))`: " *
            "its fields have $offset bytes, which is not a multiple of $alignment, the size of its " *
            "largest primitive field"
    end
    if offset != sizeof(T)
        return "`$T` has padding at its end, so it can't be `$(kind_name(kind))`"
    end
    return nothing
end

# The alignment of the bits type T in the strictest layout that any platform could give
# it, in which every primitive type is aligned to its size. The primitive fields of a
# struct must have been checked to have bit widths that are powers of two.
function strictest_alignment(T::Type)::Int
    isprimitivetype(T) && return sizeof(T)
    alignment = 1
    for i in 1:fieldcount(T)
        alignment = max(alignment, strictest_alignment(fieldtype(T, i)))
    end
    return alignment
end

# The number of bits of the primitive type T that hold its value. Before Julia 1.14, the
# bit width of primitive types is a multiple of 8, and their size is not rounded up.
@static if isdefined(Base, :bitsizeof)
    bit_size(T::Type) = Base.bitsizeof(T)
else
    bit_size(T::Type) = 8 * sizeof(T)
end

# The number of bytes of the encoding of a bits type. The bit width of primitive types
# has been checked to be a multiple of 8 by `bits_type_error`.
bits_encoded_size(T::Type) = isprimitivetype(T) ? bit_size(T) ÷ 8 : sizeof(T)

# Whether the bits of T fill its in-memory bytes, so that its memory is its encoding,
# up to byte order. Since Julia 1.14, the size of e.g. a 24-bit primitive type is rounded
# up to 4 bytes, and it is loaded with a 4-byte load. Structs that are bits types have
# no padding, as checked by `bits_type_error`.
fills_bytes(T::Type) = !isprimitivetype(T) || bit_size(T) == 8 * sizeof(T)

# Whether an array of T is its encoding, up to byte order: the bits of T fill its bytes,
# and the elements of arrays have no gaps between them. Before Julia 1.14, `sizeof`
# excluded the padding that the internal `Base.aligned_sizeof` includes, so e.g. a 24-bit
# primitive type has a size of 3 bytes, but its elements in arrays are 4 bytes apart.
# Julia 1.14 merged the two. `Base.elsize` is the public way to get the padded size.
is_dense_bits(T::Type) = fills_bytes(T) && Base.elsize(Memory{T}) == sizeof(T)

# Whether the encoding of the primitive type T is exactly as wide as an unsigned integer,
# so that its bits can be loaded as that integer with one load, and checked before a T
# is made from them.
loads_as_raw(T::Type) = bits_encoded_size(T) in (1, 2, 4, 8, 16)

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

# Unaligned load of a primitive T in byte order `e`, with the requirements of
# `unsafe_load_at`. T must fill its bytes.
@inline function unsafe_load_bits(mem::MemoryView, offset::Int, ::Type{T}, e::Endianness) where {T}
    return byte_order(e, unsafe_load_at(mem, T, offset))
end

# Unaligned store of the primitive x in byte order `e`, with the requirements of
# `unsafe_store_at!`. The type of x must fill its bytes.
@inline function unsafe_store_bits(mem::MutableMemoryView, offset::Int, x, e::Endianness)
    unsafe_store_at!(mem, byte_order(e, x), offset)
    return nothing
end

# Primitive types whose bits don't fill their bytes in memory, e.g. a 24-bit type, whose
# size is 4 bytes since Julia 1.14, are loaded and stored as the N encoded bytes, and
# converted with integer intrinsics, which don't depend on the memory layout of T.
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

# Assemble the primitive type X, whose bit width is 8 * N, from bytes, least significant
# first.
@inline function from_bytes(::Type{X}, bytes::NTuple{N, UInt8}) where {X, N}
    N == 1 && return Core.Intrinsics.bitcast(X, bytes[1])
    x = Core.Intrinsics.zext_int(X, bytes[N])
    for i in (N - 1):-1:1
        x = Core.Intrinsics.or_int(Core.Intrinsics.shl_int(x, 8), Core.Intrinsics.zext_int(X, bytes[i]))
    end
    return x
end

# The N bytes of the primitive value x, whose bit width is 8 * N, least significant first.
@inline function to_bytes(x::X, ::Val{N}) where {X, N}
    N == 1 && return (Core.Intrinsics.bitcast(UInt8, x),)
    return ntuple(i -> Core.Intrinsics.trunc_int(UInt8, Core.Intrinsics.lshr_int(x, 8 * (i - 1))), Val(N))
end

# Structs are loaded and stored as their bytes. Byte order is converted by reversing the
# bytes of each primitive field. Structs that are bits types have no padding, and their
# primitive fields fill their bytes, so this covers all bytes.

# Append to `order` the indices of the bytes of a T at `offset`, with the bytes of each
# primitive field reversed.
function append_swapped_order!(order::Vector{Int}, T::Type, offset::Int)
    if isprimitivetype(T)
        append!(order, (offset + sizeof(T)):-1:(offset + 1))
    else
        for i in 1:fieldcount(T)
            append_swapped_order!(order, fieldtype(T, i), offset + Int(fieldoffset(T, i)))
        end
    end
    return order
end

# The bytes of a struct T, with the bytes of each primitive field reversed. This converts
# between native byte order and the other byte order, in both directions. The generator
# only uses the layout of T, not methods that may be added later.
@generated function swap_fields(::Type{T}, bytes::NTuple{N, UInt8}) where {T, N}
    order = append_swapped_order!(Int[], T, 0)
    @assert sort(order) == 1:N
    return :(tuple($((:(bytes[$i]) for i in order)...)))
end

# Whether the bytes of a T in native byte order are valid, for a bits type T.
@inline function is_valid_value(::Type{T}, bytes::NTuple{N, UInt8}) where {T, N}
    bits_kind(T) isa BitsStorable || return true
    isprimitivetype(T) || fields_valid(T, bytes) || return false
    return is_valid_bits(T, bytes)::Bool
end

# Whether the bytes of each field of the struct T, in native byte order, are valid.
# The generator only uses the layout of T. `is_valid_value` is called in the generated
# code, since it calls methods that may be added later.
@generated function fields_valid(::Type{T}, bytes::NTuple{N, UInt8}) where {T, N}
    checks = map(1:fieldcount(T)) do i
        F = fieldtype(T, i)
        offset = Int(fieldoffset(T, i))
        field_bytes = :(tuple($((:(bytes[$(offset + j)]) for j in 1:sizeof(F))...)))
        :(is_valid_value($F, $field_bytes))
    end
    return foldr((a, b) -> :($a && $b), checks; init = true)
end

# Decode a T of kind `kind` at `offset` in `mem`. The caller must ensure that the
# `bits_encoded_size(T)` bytes are within `mem`.
@inline function unsafe_decode_bits(
        kind::Union{BitsLoadable, BitsStorable}, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, DecodeError} where {T}
    return if isprimitivetype(T)
        unsafe_decode_primitive(kind, mem, offset, T, e)
    else
        unsafe_decode_struct(kind, mem, offset, T, e)
    end
end

@inline function unsafe_decode_primitive(
        kind::Union{BitsLoadable, BitsStorable}, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, DecodeError} where {T}
    kind isa BitsLoadable && fills_bytes(T) && return unsafe_load_bits(mem, offset, T, e)
    N = bits_encoded_size(T)
    if loads_as_raw(T)
        raw = unsafe_load_bits(mem, offset, uint_of_size(N), e)
        if kind isa BitsStorable
            # `raw` is in native byte order, so this is a no-op
            bytes = reinterpret(NTuple{N, UInt8}, raw)
            is_valid_bits(T, bytes)::Bool || return DecodeError(InvalidData)
        end
        return Core.Intrinsics.bitcast(T, raw)
    end
    least_first = unsafe_load_bytes(mem, offset, Val(N), e)
    if kind isa BitsStorable
        bytes = NATIVE_ENDIAN === LittleEndian() ? least_first : reverse(least_first)
        is_valid_bits(T, bytes)::Bool || return DecodeError(InvalidData)
    end
    return from_bytes(T, least_first)
end

@inline function unsafe_decode_struct(
        kind::Union{BitsLoadable, BitsStorable}, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, DecodeError} where {T}
    kind isa BitsLoadable && e === NATIVE_ENDIAN && return unsafe_load_at(mem, T, offset)
    bytes = unsafe_load_at(mem, NTuple{sizeof(T), UInt8}, offset)
    if e !== NATIVE_ENDIAN
        bytes = swap_fields(T, bytes)
    end
    if kind isa BitsStorable
        is_valid_value(T, bytes) || return DecodeError(InvalidData)
    end
    return reinterpret(T, bytes)
end

# Encode x at `offset` in `mem`. The caller must ensure that the
# `bits_encoded_size(T)` bytes are within `mem`.
@inline function unsafe_encode_bits!(mem::MutableMemoryView, offset::Int, x::T, e::Endianness) where {T}
    if isprimitivetype(T)
        if fills_bytes(T)
            unsafe_store_bits(mem, offset, x, e)
        else
            unsafe_store_bytes!(mem, offset, to_bytes(x, Val(bits_encoded_size(T))), e)
        end
    elseif e === NATIVE_ENDIAN
        unsafe_store_at!(mem, x, offset)
    else
        unsafe_store_at!(mem, swap_fields(T, reinterpret(NTuple{sizeof(T), UInt8}, x)), offset)
    end
    return nothing
end
