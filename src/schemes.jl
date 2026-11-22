"""
    abstract type CodecScheme end

Zero-sized trait struct, which says where the codec of a type `T` with an encoding comes
from. Set it by adding a method to [`codec_scheme`](@ref) for your type `T`.

The options are:
* [`Manual()`](@ref Manual), the default: the codec is implemented by hand, see
  [`Encoding`](@ref).
* [`BitsLoadable()`](@ref BitsLoadable) and [`BitsStorable()`](@ref BitsStorable): the
  codec copies the bits of `T` in memory. Only for the [`Endianness`](@ref) encodings.
* [`Proxy{P}()`](@ref Proxy): `T` is encoded exactly as a value of the type `P` is.

See also: [`codec_scheme`](@ref)
"""
abstract type CodecScheme end

"""
    Manual() <: CodecScheme

The default [`CodecScheme`](@ref): the codec of a type with an encoding is implemented by
hand, see [`Encoding`](@ref).
"""
struct Manual <: CodecScheme end

"""
    BitsLoadable() <: CodecScheme

[`CodecScheme`](@ref) of types whose [`Endianness`](@ref) encodings are their bits in
memory, and for which all bit patterns are valid. Examples include `UInt64` and `Float32`.
Encoding and decoding is implemented by copying bytes, and swapping their order if the
encoding is not [`NATIVE_ENDIAN`](@ref).

A type `T` can be `BitsLoadable` if:
* It is an `isbitstype` primitive type or struct;
* its bit size is a multiple of 8, i.e. it occupies an integer number of bytes;
* its little and big endian encodings are its in-memory representation, up to byte order;
* every bit pattern is a valid `T`.

It must only be declared for the `Endianness` encodings, e.g.
`BitScribbling.codec_scheme(::Type{MyType}, ::Endianness) = BitScribbling.BitsLoadable()`.
Declaring it for another encoding throws an `ArgumentError` when the codec is used.

Declaring a struct `BitsLoadable` makes its layout, i.e. the order, types and number of
its fields, part of its encoding. To encode a struct independently of its fields, use
[`Proxy`](@ref) instead.

See also: [`BitsStorable`](@ref)

# Extended help
## Structs
An `isbitstype` struct `T` has three requirements to be `BitsLoadable` or `BitsStorable`,
in addition to the above requrement that its encoding must equal its memory representation:

1. All its fields must be `BitsLoadable` for `T` to be `BitsLoadable`, and its fields must
   be `BitsLoadable` or `BitsStorable` for `T` to be `BitsStorable`. A field whose scheme
   is `Manual` or `Proxy` is not encoded as its bits, so `T` can't be either.
2. `T` must not have size zero
3. `T` must have no padding on any platform. The padding check is done by assuming
   the alignment of any primitive is equal to the next power of two equal to or
   larger than its bitsize,
   and that the alignment of any struct is equal to its largest field.
   This is the most conservative possible rule.
"""
struct BitsLoadable <: CodecScheme end

"""
    BitsStorable() <: CodecScheme

Like [`BitsLoadable`](@ref), but for types where some bit patterns are invalid, such as
`Bool`. The type can be encoded by copying its bytes, but after the bytes are decoded or
loaded, they must be validated with [`is_valid_bits`](@ref), which then must be
implemented.

The requirements are the same as for `BitsLoadable`, except that the fields of a struct
may be `BitsLoadable` or `BitsStorable`.

See also: [`is_valid_bits`](@ref)
"""
struct BitsStorable <: CodecScheme end

"""
    Proxy{P}() <: CodecScheme

[`CodecScheme`](@ref) of a type `T` that is encoded exactly as a value of the concrete type
`P` is, with the same encoding. Then `P` must have a codec for that encoding, and these
two functions must be implemented:

* [`to_proxy(x::T, enc)::P`](@ref to_proxy), which converts the value to its proxy, and
* [`try_from_proxy(::Type{T}, p::P, enc)::Union{T, Nothing}`](@ref try_from_proxy), which
  converts the proxy back, or returns `nothing` if `p` is not a valid `T`.

Proxies are the easiest way to encode a struct without making its fields part of its
encoding. A common proxy is a tuple, whose elements are encoded one after another
without padding. Unlike [`BitsLoadable`](@ref) structs, a proxied type is encoded element
by element also in bulk, so loading many values is not a single memory copy.

`P` must not be `T`, and `T` must not be part of a cycle of proxies.

# Examples
```jldoctest
julia> struct Interval
           lo::UInt16
           hi::UInt16
       end

julia> BitScribbling.codec_scheme(::Type{Interval}, ::Endianness) = BitScribbling.Proxy{NTuple{2, UInt16}}()

julia> BitScribbling.to_proxy(x::Interval, ::Endianness) = (x.lo, x.hi)

julia> function BitScribbling.try_from_proxy(::Type{Interval}, (lo, hi)::NTuple{2, UInt16}, ::Endianness)
           return lo ≤ hi ? Interval(lo, hi) : nothing
       end

julia> decode(MemoryView([0x00, 0x01, 0x00, 0x02]), Interval, BigEndian())
Interval(0x0001, 0x0002)

julia> try_decode(MemoryView([0x00, 0x02, 0x00, 0x01]), Interval, BigEndian())
DecodeError(BitScribbling.DecodeErrorKinds.InvalidData)
```
"""
struct Proxy{P} <: CodecScheme end

"""
    codec_scheme(::Type{T}, enc::Encoding)::CodecScheme

The [`CodecScheme`](@ref) of the type `T` with the encoding `enc`. Defaults to
[`Manual()`](@ref Manual).

Add methods to it for your own types, e.g.
`BitScribbling.codec_scheme(::Type{MyType}, ::Endianness) = BitScribbling.BitsLoadable()`.
Unlike the methods of a hand-written codec, its methods may be defined for abstract
encoding types, such as `Endianness` or `Encoding`. Its methods must be constant foldable.

See also: [`CodecScheme`](@ref)
"""
codec_scheme(::Type, ::Encoding)::CodecScheme = Manual()

codec_scheme(
    ::Union{
        Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128},
        Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128},
        Type{Float16}, Type{Float32}, Type{Float64},
    },
    ::Endianness,
) = BitsLoadable()

codec_scheme(::Type{Bool}, ::Endianness) = BitsStorable()
codec_scheme(::Type{<:Enum}, ::Endianness) = BitsStorable()

"""
    to_proxy(x::T, enc::Encoding)::P

Convert `x` to its proxy, when the [`codec_scheme`](@ref) of `T` with `enc` is
[`Proxy{P}()`](@ref Proxy). The result must be of type `P` exactly; it is not converted.

Never call it directly; call e.g. [`try_encode!`](@ref).

See also: [`try_from_proxy`](@ref)
"""
function to_proxy end

"""
    try_from_proxy(::Type{T}, p::P, enc::Encoding)::Union{T, Nothing}

Convert the proxy `p` back to a `T`, when the [`codec_scheme`](@ref) of `T` with `enc` is
[`Proxy{P}()`](@ref Proxy). Return `nothing` if `p` is not a valid `T`, which makes
decoding fail with `InvalidData`.

Never call it directly; call e.g. [`try_decode`](@ref).

See also: [`to_proxy`](@ref)
"""
function try_from_proxy end

const BitsScheme = Union{BitsLoadable, BitsStorable}

scheme_name(scheme::CodecScheme) = nameof(typeof(scheme))

# The codec scheme of T with `enc`, after checking that it can be used. Throw an
# `ArgumentError` if it can't, e.g. if T is declared to be a bits type, but can't be one.
# The checks are constant-folded, so this costs nothing at runtime.
@inline function codec_kind(::Type{T}, enc::Encoding)::CodecScheme where {T}
    scheme = codec_scheme(T, enc)::CodecScheme
    message = if scheme isa BitsScheme
        enc isa Endianness ? bits_type_error(T, scheme, enc) : bits_encoding_error(T, scheme, enc)
    elseif scheme isa Proxy
        proxy_error(T, scheme)
    else
        nothing
    end
    message === nothing || throw_scheme_error(message)
    return scheme
end

@noinline throw_scheme_error(message::Tuple) = throw(ArgumentError(string(message...)))

# The message parts are not joined here, since printing types can't be constant-folded
function bits_encoding_error(::Type{T}, scheme::BitsScheme, enc::Encoding)::Tuple where {T}
    return (
        "`codec_scheme(", T, ", ", enc, ")` is `", scheme_name(scheme), "`, but only the ",
        "`Endianness` encodings can encode values as their bits",
    )
end

function proxy_error(::Type{T}, ::Proxy{P})::Union{Nothing, Tuple} where {T, P}
    if !(P isa Type && isconcretetype(P))
        return ("The proxy `", P, "` of `", T, "` is not a concrete type")
    elseif P === T
        return ("`", T, "` can't be its own proxy")
    end
    return nothing
end

# The codec of proxied types. It is called where a hand-written codec would be, so that
# the proxy is decoded and encoded on the same fast and slow paths as its codec would be.
# The input or output holds `max_encoded_size(P, enc)` bytes on the fast path, so the
# proxy is decoded and encoded on its fast path too.

@inline function proxy_try_decode(
        input::DecodeInput, ::Type{T}, ::Proxy{P}, enc::Encoding
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T, P}
    (p, n, _) = @? decode_field(input, P, enc)
    x = try_from_proxy(T, p, enc)
    x === nothing && return Invalid()
    return (x::T, n)
end

@inline function proxy_try_encode!(
        output::EncodeOutput, x, ::Proxy{P}, enc::Encoding
    )::Union{Int, TooShort, Invalid} where {P}
    (n, _) = @? encode_field(output, to_proxy(x, enc)::P, enc)
    return n
end
