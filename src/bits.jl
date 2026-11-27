"""
    validate_bits(::Type{T}, bytes::NTuple{N, UInt8})::Union{Nothing, Invalid}

Check that the bytes `bytes` are a valid `T`, for a type `T`. Return `nothing` if they
are, else an [`Invalid`](@ref), whose payload may tell why. The type of the payload must
be [`codec_decode_invalid_type(T, enc)`](@ref codec_decode_invalid_type) for the
[`Endianness`](@ref) encodings `enc`, which defaults to `Nothing`, the type of
`Invalid()`.

This function is only called for types whose [`codec_scheme`](@ref) is
[`BitsStorable()`](@ref BitsStorable).
It is only called when decoding, so a type that is only encoded need not implement it.

`N` is the number of bytes of `T`.
The bytes are in given in native byte order, i.e. after any potential byte swapping.
So, if `bytes` are valid, they are the raw bits of `T`, and the instance of `T` may
be created with `reinterpret(T, bytes)`.
If `T` is a struct, the fields of `T` are checked before this is called, and the
payloads of their errors are passed on, see [`decode_invalid_type`](@ref).

For easier bit manipulation, you can use the helper function [`as_unsigned`](@ref)
to convert `bytes` to an `Unsigned` integer in native byte order.

# Examples
```julia
primitive type Odd64 64 end
Inscription.codec_scheme(::Type{Odd64}, ::Endianness) = Inscription.BitsStorable()
function Inscription.validate_bits(::Type{Odd64}, bytes::NTuple{8, UInt8})
    return isodd(Inscription.as_unsigned(bytes)) ? nothing : Inscription.Invalid()
end
```
"""
function validate_bits end

# Bool is always 0x00 or 0x01 in memory, but pointer-loading it keeps only the lowest
# bit, so the bits must be checked before a Bool is made from them.
validate_bits(::Type{Bool}, bytes::NTuple{1, UInt8}) = bytes[1] ≤ 0x01 ? nothing : Invalid()

# If the values of `T` are contiguous, which is the common case, a range check suffices.
# `enum_range` is constant-folded, so only one of the branches is compiled.
@inline function validate_bits(::Type{T}, bytes::NTuple{N, UInt8}) where {T <: Enum, N}
    raw = as_unsigned(bytes)
    (lo, span, contiguous) = enum_range(T, typeof(raw))
    valid = if contiguous
        (raw - lo) ≤ span
    else
        any(x -> to_int(x) % typeof(raw) == raw, instances(T))
    end
    return valid ? nothing : Invalid()
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

This is a helper function that users can call in [`validate_bits`](@ref),
if they find it easier to operate on an `Unsigned` value rather than an `NTuple{N, UInt8}`.

The input `bytes` is given in native byte order. So, for example, if `N == 8`,
this function is equivalent to `reinterpret(UInt64, bytes)`.
When used inside `validate_bits`, the byte order has already been made native, so
users need not handle endianness.

# Examples
```jldoctest
julia> x = 0x00ab_cdef;

julia> bytes = NATIVE_ENDIAN === LittleEndian() ? (0xef, 0xcd, 0xab) : (0xab, 0xcd, 0xef);

julia> Inscription.as_unsigned(bytes) === x
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

# Why T, whose `codec_scheme` with the byte order `enc` is `kind`, can't be a bits type,
# or `nothing` if it can. See the docstring of `BitsLoadable` for the requirements. The reason is a tuple of the
# parts of its message, e.g. strings and types, which `string` joins.
# The checks of the layout of T only use Base reflection, so they are done when the
# method is generated. The generated code only calls `codec_scheme` of the fields, each
# with a constant type. So the result is constant-folded if those `codec_scheme` methods
# are foldable, as the docstring of `codec_scheme` requires, without assuming it. The message
# is not built here, since that prints types, whose `show` may be overloaded, which
# would prevent folding.
@generated function bits_type_error(
        ::Type{T}, kind::BitsScheme, enc::Endianness
    )::Union{Nothing, Tuple} where {T}
    return Expr(:block, bits_type_error_checks(T)..., :(return nothing))
end

# The statements of the body of `bits_type_error` for T. The generated code refers to
# the arguments `T`, `kind` and `enc`. A check that fails for T regardless of the scheme
# of its fields becomes a `return` of the parts of its message, and ends the statements.
function bits_type_error_checks(T::Type)::Vector{Any}
    if isprimitivetype(T)
        n_bits = bit_size(T)
        n_bits % 8 == 0 && return []
        return [
            :(
                return tuple(
                    "`codec_scheme(", T, ", ", enc, ")` is `", scheme_name(kind), "`, but the bit width ", $n_bits,
                    " of `", T, "` is not a multiple of 8, so `LittleEndian` and `BigEndian` can't ",
                    "encode it as its bits. To encode it in whole bytes, leave its `codec_scheme` as ",
                    "`Manual`, and write a codec for each byte order"
                )
            ),
        ]
    end
    if !(isstructtype(T) && isbitstype(T))
        return [
            :(
                return tuple(
                    "`codec_scheme(", T, ", ", enc, ")` is `", scheme_name(kind), "`, but `", T,
                    "` is neither a primitive type nor an isbits struct"
                )
            ),
        ]
    end
    if iszero(sizeof(T))
        return [
            :(
                return tuple(
                    "`", T, "` has a size of zero bytes, so it can't be `", scheme_name(kind),
                    "`: types of size zero are not supported"
                )
            ),
        ]
    end
    padding = padding_error(T)
    if padding !== nothing
        S, reason = padding
        return [
            if S === T
                :(
                    return tuple(
                        "`", T, "` has padding on some or all platforms, so it can't be `",
                        scheme_name(kind), "`: ", $(reason...)
                    )
                )
            else
                :(
                    return tuple(
                        "`", T, "` can't be `", scheme_name(kind), "`, since `", $S,
                        "` has padding on some or all platforms: ", $(reason...)
                    )
                )
            end,
        ]
    end
    checks = []
    for i in 1:fieldcount(T)
        F = fieldtype(T, i)
        name = string(fieldname(T, i))
        field_kind = Symbol(:field_kind_, i)
        push!(
            checks, quote
                $field_kind = codec_scheme($F, enc)::CodecScheme
                if !($field_kind isa BitsScheme)
                    return tuple(
                        "The field `", $name, "` of `", T, "` has the type `", $F,
                        "`, whose `codec_scheme` with `", enc, "` is `", scheme_name($field_kind),
                        "`, so it is not encoded as its bits"
                    )
                elseif kind isa BitsLoadable && !($field_kind isa BitsLoadable)
                    return tuple(
                        "`", T, "` is `BitsLoadable`, but its field `", $name, "` has the type `",
                        $F, "`, which is `", scheme_name($field_kind), "`"
                    )
                end
            end
        )
        if !isprimitivetype(F)
            push!(
                checks, quote
                    message = bits_type_error($F, $field_kind, enc)
                    message === nothing || return message
                end
            )
        end
    end
    return checks
end

"""
    is_padding_free(T::Type)::Bool

Return whether the bits type `T` is guaranteed to have no padding on any platform.
This is one of the requirements for `T` to be [`BitsLoadable`](@ref) or [`BitsStorable`](@ref).
Throw an `ArgumentError` if `T` is not a bits type, i.e. if `isbitstype(T)` is `false`.

Since the alignment of types differs between platforms, `T` is checked against the
strictest layout any platform could give it:
* A primitive type is aligned to its size. Primitive types must have a bit width that is a
  multiple of 8, and primitive fields of structs a bit width that is a power of two of
  at least 8.
* A struct is aligned to the alignment of its most aligned field.

`T` is padding-free if each of its fields begins right where the previous one ends, its
size is the sum of the sizes of its fields, and each of its fields is padding-free.
Therefore, a type that has no padding on the current platform may still not be padding-free.

This function only depends on the layout of `T`, not on its [`codec_scheme`](@ref).
Calls with a constant `T` are constant-folded.

# Examples
```jldoctest
julia> struct Unordered; a::UInt32; b::UInt64; end

julia> struct Ordered; b::UInt64; a::UInt32; c::UInt32; end

julia> Inscription.is_padding_free(Unordered)
false

julia> Inscription.is_padding_free(Ordered)
true

julia> Inscription.is_padding_free(Tuple{UInt16, Tuple{UInt8, UInt8}})
true
```

See also: [`CodecScheme`](@ref)
"""
@generated function is_padding_free(::Type{T})::Bool where {T}
    isbitstype(T) || return :(throw_not_bits_type(T))
    return padding_error(T) === nothing
end

@noinline function throw_not_bits_type(@nospecialize(T::Type))
    throw(ArgumentError(lazy"`$T` is not a bits type, so its padding is not defined"))
end

# Where the bits type T has padding in the strictest layout of any platform, see
# `is_padding_free`, or `nothing` if it has none. The padding is found in `S`, which is
# T or the type of a field nested in T, and `reason` is a tuple of the parts of a message
# saying where in `S` the padding is. This only uses Base reflection, so it can be used
# in generators.
function padding_error(T::Type)::Union{Nothing, Tuple{Type, Tuple}}
    if isprimitivetype(T)
        n_bits = bit_size(T)
        n_bits % 8 == 0 && return nothing
        return (T, ("its bit width ", n_bits, " is not a multiple of 8"))
    end
    # The offset of the next field in the strictest layout
    offset = 0
    for i in 1:fieldcount(T)
        F = fieldtype(T, i)
        name = string(fieldname(T, i))
        if isprimitivetype(F)
            n_bits = bit_size(F)
            if !(n_bits ≥ 8 && ispow2(n_bits))
                return (
                    T, (
                        "its field `", name, "` has the type `", F, "`, whose bit width ",
                        n_bits, " is not a power of two of at least 8",
                    ),
                )
            end
        else
            padding = padding_error(F)
            padding === nothing || return padding
        end
        alignment = strictest_alignment(F)
        if offset % alignment != 0
            of_what = isprimitivetype(F) ? "its type `" : "the largest primitive field of its type `"
            return (
                T, (
                    "its field `", name, "` follows ", offset, " bytes of other fields, which ",
                    "is not a multiple of ", alignment, ", the size of ", of_what, F, "`",
                ),
            )
        end
        # This holds if every primitive type is aligned to at most its size
        offset == fieldoffset(T, i) || return (T, ("it has padding before its field `", name, "`"))
        offset += sizeof(F)
    end
    alignment = strictest_alignment(T)
    if offset % alignment != 0
        return (
            T, (
                "its fields have ", offset, " bytes, which is not a multiple of ", alignment,
                ", the size of its largest primitive field",
            ),
        )
    end
    offset == sizeof(T) || return (T, ("it has padding at its end",))
    return nothing
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

# Check that the bytes of a T in native byte order are valid, for a bits type T with the
# byte order `e`. Return `nothing` if they are, else an `Invalid` of the payload type of T.
@inline function check_value(
        ::Type{T}, bytes::NTuple{N, UInt8}, e::Endianness
    )::Union{Nothing, Invalid} where {T, N}
    codec_scheme(T, e) isa BitsStorable || return nothing
    if !isprimitivetype(T)
        result = check_fields(T, bytes, e)
        result === nothing || return result
    end
    result = validate_bits(T, bytes)::Union{Nothing, Invalid}
    result === nothing && return nothing
    return as_decode_invalid(result, validate_bits, T, e)
end

# Check the bytes of each field of the struct T, in native byte order, as `check_value`.
# The generator only uses the layout of T. `check_value` is called in the generated
# code, since it calls methods that may be added later.
@generated function check_fields(::Type{T}, bytes::NTuple{N, UInt8}, e::Endianness) where {T, N}
    checks = map(1:fieldcount(T)) do i
        F = fieldtype(T, i)
        offset = Int(fieldoffset(T, i))
        field_bytes = :(tuple($((:(bytes[$(offset + j)]) for j in 1:sizeof(F))...)))
        quote
            result = check_value($F, $field_bytes, e)
            result === nothing || return as_decode_invalid(result, validate_bits, T, e)
        end
    end
    return Expr(:block, Expr(:meta, :inline), checks..., :(return nothing))
end

# The payload type of a BitsStorable type T, see `decode_invalid_type`: that of T itself,
# and those of its fields, if it is a struct. Generated, so it is constant-folded for any
# number of fields. The generator only uses the layout of T.
@generated function bits_decode_invalid_type(::Type{T}, e::Endianness) where {T}
    Fs = isprimitivetype(T) ? () : fieldtypes(T)
    return quote
        $(Expr(:meta, :inline))
        Union{codec_decode_invalid_type(T, e)::Type, $((:(decode_invalid_type($F, e)) for F in Fs)...)}
    end
end

# Decode a T of kind `kind` at `offset` in `mem`. The caller must ensure that the
# `bits_encoded_size(T)` bytes are within `mem`. If the bytes are invalid, return an
# `Invalid` of the payload type of T.
@inline function unsafe_decode_bits(
        kind::BitsScheme, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, Invalid} where {T}
    return if isprimitivetype(T)
        unsafe_decode_primitive(kind, mem, offset, T, e)
    else
        unsafe_decode_struct(kind, mem, offset, T, e)
    end
end

@inline function unsafe_decode_primitive(
        kind::BitsScheme, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, Invalid} where {T}
    kind isa BitsLoadable && fills_bytes(T) && return unsafe_load_bits(mem, offset, T, e)
    N = bits_encoded_size(T)
    if loads_as_raw(T)
        raw = unsafe_load_bits(mem, offset, uint_of_size(N), e)
        if kind isa BitsStorable
            # `raw` is in native byte order, so this is a no-op
            bytes = reinterpret(NTuple{N, UInt8}, raw)
            result = check_value(T, bytes, e)
            result === nothing || return result
        end
        return Core.Intrinsics.bitcast(T, raw)
    end
    least_first = unsafe_load_bytes(mem, offset, Val(N), e)
    if kind isa BitsStorable
        bytes = NATIVE_ENDIAN === LittleEndian() ? least_first : reverse(least_first)
        result = check_value(T, bytes, e)
        result === nothing || return result
    end
    return from_bytes(T, least_first)
end

@inline function unsafe_decode_struct(
        kind::BitsScheme, mem::MemoryView, offset::Int, ::Type{T}, e::Endianness
    )::Union{T, Invalid} where {T}
    kind isa BitsLoadable && e === NATIVE_ENDIAN && return unsafe_load_at(mem, T, offset)
    bytes = unsafe_load_at(mem, NTuple{sizeof(T), UInt8}, offset)
    if e !== NATIVE_ENDIAN
        bytes = swap_fields(T, bytes)
    end
    if kind isa BitsStorable
        result = check_value(T, bytes, e)
        result === nothing || return result
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
