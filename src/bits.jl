"""
    abstract type BitsKind end

Zero-sized trait struct. 
By implementing the `BitScribbling.bits_kind(::Type{T})` function for your type `T`,
you can automatically generate a codec for `T` the [`LittleEndian`](@ref)
and [`BigEndian`](@ref) ("endian") encodings.

Currently, the options are [`BitsLoadable`](@ref), [`BitsStorable`](@ref) and [`Opaque`](@ref).

Implement with e.g. `BitScribbling.bits_kind(::Type{MyType}) = BitScribbling.BitsStorable()`.
Defaults to [`Opaque`](@ref), where no implementation is auto-generated.

If `isbitstype(T)`,
and `T` has a bit-size a multiple of 8 (i.e. occupies an integer number of bytes), 
and the little/big endian encoding of `T` is identical to the in-memory representation
of `T`, then `bits_kind(T)` can be `BitsLoadable` or `BitsStorable`.
Else, it must remain `Opaque`.

If all bitpatterns are valid, it can be `BitsLoadable`. Then, encoding, decoding, storing
and loading is automatically implemented as simply copying bytes in memory.
Examples of this include `UInt64` and `Float32`.

Else, if some bitpatterns are invalid, it can be `BitsStorable`. Then, the type also can be
encoded, decoded, loaded and stored by copying bytes directly, but after decoding or loading,
the bytes must be validated with [`is_valid_bits`](@ref), which then must be implemented.

See also: [`is_valid_bits`](@ref)

# Extended help
## Structs
An `isbitstype` struct `T` has three requirements to be `BitsLoadable` or `BitsStorable`,
in addition to the above requrement that its encoding must equal its memory representation:

1. All its fields must be `BitsLoadable` for `T` to be `BitsLoadable`, and its fields must
   be `BitsLoadable` or `BitsStorable` for `T` to be `BitsStorable`
2. `T` must not have size zero
3. `T` must have no padding on any platform. The padding check is done by assuming
   the alignment of any primitive is equal to the next power of two equal to or
   larger than its bitsize,
   and that the alignment of any struct is equal to its largest field.
   This is the most conservative possible rule.
"""
abstract type BitsKind end

"""
    BitsLoadable() <: BitsKind

Zero-sized trait. See See [`BitsKind`](@ref) for details.
"""
struct BitsLoadable <: BitsKind end

"""
    BitsStorable() <: BitsKind

Zero-sized trait. See See [`BitsKind`](@ref) for details.
"""
struct BitsStorable <: BitsKind end

"""
    Opaque() <: BitsKind

Zero-sized trait. See See [`BitsKind`](@ref) for details.
"""
struct Opaque <: BitsKind end

"""
    bits_kind(::Type{T})::BitsKind

Compute the `BitsKind` instance of `T`. This method should be constant foldable.

See also: [`BitsKind`](@ref)
"""
bits_kind(::Type)::BitsKind = Opaque()

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

Whether the bytes `bytes` are a valid `T`, for a type `T`.
This function is only called for types for which `bits_kind(T) === BitsStorable()`,
see [`BitsKind`](@ref).

`N` is the number of bytes of `T`.
The bytes are in given in native byte order, i.e. after any potential byte swapping.
So, if `bytes` are valid, they are the raw bits of `T`, and the instance of `T` may
be created with `reinterpret(T, bytes)`.

For easier bit manipulation, you can use the helper function [`as_unsigned`](@ref)
to convert `bytes` to an `Unsigned` integer in native byte order.
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
        any(x -> to_int(x) % typeof(raw) == raw, instances(T))
    end
end

# The bits of the smallest value of the enum `T`, the difference between the largest
# and smallest value, and whether the values are contiguous, all as `U`. Arithmetic in
# `U` wraps around, so `raw - lo ≤ span` is a range check also for signed base types.
# This doesn't use `typemin(T)` and `typemax(T)`: they go through the checked constructor
# of `T`, which looks the value up in a `Dict` at runtime when the values have gaps.
# This is constant-folded if `instances(T)` is, as it is for `@enum` types. The loop over
# the tuple of instances ends, but the compiler can't prove it, so that is assumed.
Base.@assume_effects :terminates_locally function enum_range(::Type{T}, ::Type{U}) where {T <: Enum, U}
    values = instances(T)
    lo = hi = to_int(first(values))
    for x in values
        lo = min(lo, to_int(x))
        hi = max(hi, to_int(x))
    end
    span = (hi - lo) % U
    return (lo % U, span, span == length(values) - 1)
end

# The value of the enum `x` as its base type. Unlike `Integer(x)`, this can't be
# overloaded by the owner of the enum type, so it is known to be foldable.
to_int(x::Enum{T}) where {T} = Core.Intrinsics.bitcast(T, x)

"""
    as_unsigned(bytes::NTuple{N, UInt8})::Unsigned

Convert `bytes`, to the smallest of `UInt8`, `UInt16`, `UInt32`, `UInt64` and `UInt128`
that has at least `N` bytes, zero-extended.
Throw an `ArgumentError` if `N > 16`.

This is a helper function that users can call in [`is_valid_bits`](@ref),
if they find it easier to operate on an `Unsigned` value rather than an `NTuple{N, UInt8}`.

The input `bytes` is given in native byte order. So, for example, if `N == 8`,
this function is equivalent to `reinterpret(UInt64, bytes)`.
When used inside `is_valid_bits`, the byte order has already been made native, so
users need not handle endianness.

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

# The kind of the codec for T with the encoding `enc`. `Opaque` means a hand-written
# codec, which every encoding other than the byte orders requires.
# Throw an `ArgumentError` if T is declared to be a bits type, but can't be one.
# The check is constant-folded, so this costs nothing at runtime.
@inline function codec_kind(::Type{T}, enc::Encoding)::BitsKind where {T}
    enc isa Endianness || return Opaque()
    kind = bits_kind(T)::BitsKind
    kind isa Opaque && return kind
    message = bits_type_error(T, kind)
    message === nothing || throw_bits_type_error(message)
    return kind
end

@noinline throw_bits_type_error(message::Tuple) = throw(ArgumentError(string(message...)))

kind_name(kind::BitsKind) = nameof(typeof(kind))

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

# Why T, whose `bits_kind` is `kind`, can't be a bits type, or `nothing` if it can.
# See the docstring of `BitsKind` for the requirements. The reason is a tuple of the
# parts of its message, e.g. strings and types, which `string` joins.
# The checks of the layout of T only use Base reflection, so they are done when the
# method is generated. The generated code only calls `bits_kind` of the fields, each with
# a constant type. So the result is constant-folded if those `bits_kind` methods are
# foldable, as the docstring of `bits_kind` requires, without assuming it. The message
# is not built here, since that prints types, whose `show` may be overloaded, which
# would prevent folding.
@generated function bits_type_error(::Type{T}, kind::BitsKind)::Union{Nothing, Tuple} where {T}
    return Expr(:block, bits_type_error_checks(T)..., :(return nothing))
end

# The statements of the body of `bits_type_error` for T. The generated code refers to
# the arguments `T` and `kind`. A check that fails for T regardless of the `bits_kind`
# of its fields becomes a `return` of the parts of its message, and ends the statements.
function bits_type_error_checks(T::Type)::Vector{Any}
    if isprimitivetype(T)
        n_bits = bit_size(T)
        n_bits % 8 == 0 && return []
        return [
            :(
                return tuple(
                    "`bits_kind(", T, ")` is `", kind_name(kind), "`, but the bit width ", $n_bits,
                    " of `", T, "` is not a multiple of 8, so `LittleEndian` and `BigEndian` can't ",
                    "encode it as its bits. To encode it in whole bytes, leave its `bits_kind` as ",
                    "`Opaque`, and write a codec for each byte order"
                )
            ),
        ]
    end
    if !(isstructtype(T) && isbitstype(T))
        return [
            :(
                return tuple(
                    "`bits_kind(", T, ")` is `", kind_name(kind), "`, but `", T,
                    "` is neither a primitive type nor an isbits struct"
                )
            ),
        ]
    end
    if iszero(sizeof(T))
        return [
            :(
                return tuple(
                    "`", T, "` has a size of zero bytes, so it can't be `", kind_name(kind),
                    "`: types of size zero are not supported"
                )
            ),
        ]
    end
    checks = []
    # The offset of the next field in the strictest layout, see the docstring of `BitsKind`
    offset = 0
    for i in 1:fieldcount(T)
        F = fieldtype(T, i)
        name = string(fieldname(T, i))
        field_kind = Symbol(:field_kind_, i)
        push!(
            checks, quote
                $field_kind = bits_kind($F)::BitsKind
                if $field_kind isa Opaque
                    return tuple(
                        "The field `", $name, "` of `", T, "` has the type `", $F,
                        "`, whose `bits_kind` is `Opaque`"
                    )
                elseif kind isa BitsLoadable && !($field_kind isa BitsLoadable)
                    return tuple(
                        "`", T, "` is `BitsLoadable`, but its field `", $name, "` has the type `",
                        $F, "`, which is `", kind_name($field_kind), "`"
                    )
                end
            end
        )
        if isprimitivetype(F)
            n_bits = bit_size(F)
            if !(n_bits ≥ 8 && ispow2(n_bits))
                push!(
                    checks, :(
                        return tuple(
                            "The field `", $name, "` of `", T, "` has the type `", $F,
                            "`, whose bit width ", $n_bits, " is not a power of two of at least 8"
                        )
                    )
                )
                return checks
            end
        else
            push!(
                checks, quote
                    message = bits_type_error($F, $field_kind)
                    message === nothing || return message
                end
            )
        end
        alignment = strictest_alignment(F)
        if offset % alignment != 0
            of_what = isprimitivetype(F) ? "its type `" : "the largest primitive field of its type `"
            push!(
                checks, :(
                    return tuple(
                        "`", T, "` has padding on some or all platforms, so it can't be `",
                        kind_name(kind), "`: its field `", $name, "` follows ", $offset,
                        " bytes of other fields, which is not a multiple of ", $alignment,
                        ", the size of ", $of_what, $F, "`"
                    )
                )
            )
            return checks
        end
        # This holds if every primitive type is aligned to at most its size
        if offset != fieldoffset(T, i)
            push!(
                checks, :(
                    return tuple(
                        "`", T, "` has padding before its field `", $name, "`, so it can't be `",
                        kind_name(kind), "`"
                    )
                )
            )
            return checks
        end
        offset += sizeof(F)
    end
    alignment = strictest_alignment(T)
    if offset % alignment != 0
        push!(
            checks, :(
                return tuple(
                    "`", T, "` has padding on some or all platforms, so it can't be `",
                    kind_name(kind), "`: its fields have ", $offset, " bytes, which is not a ",
                    "multiple of ", $alignment, ", the size of its largest primitive field"
                )
            )
        )
    elseif offset != sizeof(T)
        push!(
            checks, :(
                return tuple("`", T, "` has padding at its end, so it can't be `", kind_name(kind), "`")
            )
        )
    end
    return checks
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
