"""
    abstract type CodecScheme end

Supertype of zero-sized trait structs that signals if a type / [`Encoding`](@ref) pair
can have auto-derived codec implementations.

For some types / encoding pairs like `Float32` being encoded in [`BigEndian`](@ref),
or [`LittleEndian`](@ref) the codec can be automatically implemented,
because the codec is simply loading/storing with a pointer, and maybe byte swapping.
For such a type `T`, users can declare:
```julia
Inscription.codec_scheme(::Type{T}, ::Endianness) = Inscription.BitsLoadable()
```
And then the codec T/Endianness is automatically implemented.

The fallback for `codec_scheme(T, E)` is [`Manual`](@ref). The current list of opt-in
codec schemes beyond `Manual` are:
* [`BitsLoadable`](@ref)
* [`BitsStorable`](@ref)
* [`Proxy`](@ref)

See extended help for which type / encoding pairs are eligible to opt into these
codec schemes, and which methods they must implement.

# Extended help
A custom type `T` can opt into the following codec schemes. It should generally opt into the
first applicable one on this list, as they are listed from most to least convenient.

Some methods are only needed for either decoding (reading) or encoding (writing).
A program that only decodes a type need not implement the methods that are only needed
for encoding it, and vice versa. Attempting to encode or decode without the
needed methods throws a `MethodError`.

## `BitsLoadable`
This codec scheme means `T` is transparently read/writable using a pointer load/store.
`BitsLoadable` must be declared for the [`Endianness`](@ref) encodings only.
To implement `BitsLoadable`, type `T` needs nothing other than to define:

```
codec_scheme(::Type{T}, ::Endianness) = BitsLoadable()
```

A type `T` can be `BitsLoadable` if:
* `isbitstype(T)`,
* `T` does not have size zero
* If `T` is a struct, all its fields must be `BitsLoadable`
* `T` must have no padding on any platform, i.e. [`is_padding_free(T)`](@ref is_padding_free)
  must be `true`.See [`is_padding_free(T)`](@ref is_padding_free) for details.
* Its [`NATIVE_ENDIAN`](@ref) encoding is the same as its in-memory representation,
  i.e. for `x::T`, the encoding is exactly equal to `reinterpret(UInt8, [x])`.
* Every bit pattern is a valid `T`.

## `BitsStorable`
This codec scheme means `T` is transparently writeable using a pointer store, and is readable using
a pointer load, except not all bitpatterns are valid, and therefore the bits must be checked before instantiation.
`BitsStorable` must be declared for the [`Endianness`](@ref) encodings only.
    
To implement `BitsStorable`, type `T` needs to implement:

```
codec_scheme(::Type{T}, ::Endianness) = BitsStorable()

# Only needed for decoding
validate_bits(::Type{T}, ::NTuple{sizeof(T), UInt8})::Union{Nothing, Invalid} = ...
# Optional, and only used for decoding: the type of the payloads of `validate_bits`
codec_decode_invalid_type(::Type{T}, ::Endianness) = ...
```

`BitsStorable` has the same restrictions as `BitsLoadable`, except:
* Not all bitpatterns need be valid
* If it's a struct, all fields must only be recursively `BitsLoadable` OR `BitsStorable`.

## `Proxy{P}`
This codec scheme means `T` can be encoded/decoded via an instance of `P`.
For example, a type
`struct Foo; x::UInt32; y::UInt8; end` may be decoded via a `Tuple{UInt32, UInt8}`.

To implement `Proxy{P}`, type `T` for encoding `E` needs to implement:

```julia
codec_scheme(::Type{T}, ::E) = Proxy{P}()

# Only needed for encoding
try_to_proxy(::T, ::E)::Union{P, Invalid} = ...
# Optional, and only used for encoding: the type of the payloads of `try_to_proxy`
codec_encode_invalid_type(::Type{T}, ::E) = ...

# Only needed for decoding
try_from_proxy(::Type{T}, ::P, ::E)::Union{T, Invalid} = ...
# Optional, and only used for decoding: the type of the payloads of `try_from_proxy`
codec_decode_invalid_type(::Type{T}, ::E) = ...
```

Any type can be `Proxy`, but it only makes sense to implement if `T` can be
easily created from / used to create a `P`, which already has an encoding.

## `Manual`
The fallback codec.

To implement a `Manual` codec for type `T` over encoding `E`, you should implement:

```julia
codec_max_encoded_size(::Type{T}, ::E)::Union{Val{N}, Unbounded()}

# Only needed for decoding
codec_try_decode(::DecodeInput, ::Type{T}, ::E)::Union{Tuple{T, Int}, Invalid, TooShort}
# Optional, and only used for decoding: the type of the payloads of `codec_try_decode`
codec_decode_invalid_type(::Type{T}, ::E) = ...

# Only needed for encoding
codec_try_encode!(::EncodeOutput, ::T, ::E)::Union{Int, Invalid, TooShort}
# Optional, and only used for encoding: the type of the payloads of `codec_try_encode!`
codec_encode_invalid_type(::Type{T}, ::E) = ...
```

The payload types default to `Nothing`, see [`codec_decode_invalid_type`](@ref).
"""
abstract type CodecScheme end

"""
    Manual() <: CodecScheme

The default [`CodecScheme`](@ref): the codec of a type with an encoding is implemented by hand.

See [`CodecScheme`](@ref), [`Encoding`](@ref).
"""
struct Manual <: CodecScheme end

"""
    BitsLoadable() <: CodecScheme

The fastest [`CodecScheme`](@ref): the encoding in [`NATIVE_ENDIAN`](@ref) is its in-memory representation.

See [`CodecScheme`](@ref), [`Encoding`](@ref).
"""
struct BitsLoadable <: CodecScheme end

"""
    BitsStorable() <: CodecScheme

The second-fastest [`CodecScheme`](@ref): For valid instances, the encoding in [`NATIVE_ENDIAN`](@ref)
are their in-memory representation.

See [`CodecScheme`](@ref), [`Encoding`](@ref).
"""
struct BitsStorable <: CodecScheme end

"""
    Proxy{P}() <: CodecScheme

[`CodecScheme`](@ref) of a type `T` that is encoded exactly as a value of the concrete type
`P` is, with the same encoding.

See [`CodecScheme`](@ref), [`Encoding`](@ref).
"""
struct Proxy{P} <: CodecScheme end

"""
    codec_scheme(::Type{T}, enc::Encoding)::CodecScheme

The [`CodecScheme`](@ref) of the type `T` with the encoding `enc`. Defaults to
[`Manual()`](@ref Manual).

Add methods to it for your own types, e.g.
`Inscription.codec_scheme(::Type{MyType}, ::Endianness) = Inscription.BitsLoadable()`.

Unlike the methods of a hand-written codec, its methods may be defined for abstract
encoding types, such as `Endianness` or `Encoding`.

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
    try_to_proxy(x::T, ::E)::Union{P, Invalid} where {E <: Encoding}

Try constructing a `P` from `x`, when `codec_scheme(T, ::E) == Proxy{P}()`.

This method should be implemented only when the `CodecScheme` of `(T, E)` has been chosen as `Proxy{P}`,
see [`CodecScheme`](@ref) for more details.

Return an [`Invalid`](@ref) if `x` can't be represented as a `P`.
Encoding `x` then fails with `InvalidValue`. The type of its payload must be
[`codec_encode_invalid_type(T, E())`](@ref codec_encode_invalid_type).

It is not called directly, but via the encoding or storing functions.
It is only needed for encoding: a proxied type that is only decoded need not implement it.

See also: [`try_from_proxy`](@ref), [`CodecScheme`](@ref)
"""
function try_to_proxy end

"""
    try_from_proxy(::Type{T}, p::P, enc::E)::Union{T, Invalid} where {E <: Encoding}

Try constructing a `T` from `p::P`, when `codec_scheme(T, ::E) == Proxy{P}()`.

This method should be implemented only when the `CodecScheme` of `(T, E)` has been chosen as `Proxy{P}`.

Return an [`Invalid`](@ref) if `p` can't be converted to a `T`.
Decoding a `T` then fails with `InvalidData`, even though the bytes are a valid encoding of a `P`.
The type of its payload must be
[`codec_decode_invalid_type(T, E())`](@ref codec_decode_invalid_type).

It is not called directly, but via the decoding or loading functions.
It is only needed for decoding: a proxied type that is only encoded need not implement it.

See also: [`try_to_proxy`](@ref)
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

# The payloads of both the proxy and the conversion are passed on, so the payload type of
# T is the union of their types, see `decode_invalid_type`.
@inline function proxy_try_decode(
        input::DecodeInput, ::Type{T}, ::Proxy{P}, enc::Encoding
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T, P}
    (p, n, _) = @? widen_decode_invalid(decode_field(input, P, enc), codec_try_decode, T, enc)
    x = try_from_proxy(T, p, enc)::Union{T, Invalid}
    x isa Invalid && return as_decode_invalid(x, try_from_proxy, T, enc)
    return (x, n)
end

@inline function proxy_try_encode!(
        output::EncodeOutput, x::T, ::Proxy{P}, enc::Encoding
    )::Union{Int, TooShort, Invalid} where {T, P}
    p = try_to_proxy(x, enc)::Union{P, Invalid}
    p isa Invalid && return as_encode_invalid(p, try_to_proxy, T, enc)
    (n, _) = @? widen_encode_invalid(encode_field(output, p, enc), codec_try_encode!, T, enc)
    return n
end

@inline function proxy_decode_invalid_type(::Type{T}, ::Proxy{P}, enc::Encoding)::Type where {T, P}
    return Union{codec_decode_invalid_type(T, enc)::Type, decode_invalid_type(P, enc)}
end

@inline function proxy_encode_invalid_type(::Type{T}, ::Proxy{P}, enc::Encoding)::Type where {T, P}
    return Union{codec_encode_invalid_type(T, enc)::Type, encode_invalid_type(P, enc)}
end

"""
    codec_decode_invalid_type(::Type{T}, enc::Encoding)::Type

The type of the payloads of the [`Invalid`](@ref)s that decoding a `T` with `enc`
returns, when the data is invalid. Defaults to `Nothing`, the type of `Invalid()`.

Add a method to it to give the errors of your codec payloads, e.g. for an enum
`ParseError`:

```julia
Inscription.codec_decode_invalid_type(::Type{MyInt}, ::Decimal) = ParseError
```

Return `Union{}` if decoding can't fail. The type is checked when the codec returns an
`Invalid{Q}`, and an `ErrorException` is thrown unless `Q <: ` this type. Since `Invalid()`
is an `Invalid{Nothing}`, a codec can only return it if the type includes `Nothing`, e.g.
`Union{Nothing, ParseError}`.
Like [`codec_scheme`](@ref), its methods must be constant-foldable, and may be defined
for abstract encoding types.
It is only used for decoding, so a type that is only encoded need not implement it, even
if it has payloads when it is encoded. Those are declared with
[`codec_encode_invalid_type`](@ref).

It is the type of the payloads that are returned by:
* [`codec_try_decode`](@ref) of a hand-written codec,
* [`validate_bits`](@ref) of a [`BitsStorable`](@ref) type,
* [`try_from_proxy`](@ref) of a [`Proxy`](@ref).

The payloads of other values decoded as part of a `T` are passed on: those of the fields of
a `BitsStorable` struct, and of the proxy type of a `Proxy`. So the payloads of the errors
of decoding a `T` may be of more types than this, see [`decode_invalid_type`](@ref).
A hand-written codec that decodes other values with [`decode_field`](@ref) must also
declare the types of their payloads, or return its own `Invalid` instead of theirs.

See also: [`codec_encode_invalid_type`](@ref)
"""
codec_decode_invalid_type(::Type, ::Encoding)::Type = Nothing

"""
    codec_encode_invalid_type(::Type{T}, enc::Encoding)::Type

The type of the payloads of the [`Invalid`](@ref)s that encoding a `T` with `enc`
returns, when the value can't be encoded. Defaults to `Nothing`, the type of `Invalid()`.

It is the type of the payloads that are returned by:
* [`codec_try_encode!`](@ref) of a hand-written codec,
* [`try_to_proxy`](@ref) of a [`Proxy`](@ref).

Like for [`codec_decode_invalid_type`](@ref), the payloads of the proxy type of a `Proxy` are passed on,
see [`encode_invalid_type`](@ref).
It is only used for encoding, so a type that is only decoded need not implement it.
"""
codec_encode_invalid_type(::Type, ::Encoding)::Type = Nothing

"""
    decode_invalid_type(::Type{T}, enc::Encoding)::Type

The type of the payloads of the errors of decoding a `T` with `enc`.
When decoding a `T` fails, the error is a
`DecodeError{decode_invalid_type(T, enc)}`, whose payload is `Some(x)`,
where `x` is the payload of the `Invalid` that decoding returned.
The type is known when the caller is compiled.

Do not add methods to this function. It is derived from the codec scheme of `T`, and from
[`codec_decode_invalid_type`](@ref):
* [`BitsLoadable`](@ref): `Union{}`, since all bit patterns are valid.
* [`BitsStorable`](@ref): the union of `codec_decode_invalid_type(T, enc)` and the
  `decode_invalid_type` of the types of its fields, if `T` is a struct.
* [`Proxy{P}`](@ref Proxy): the union of `codec_decode_invalid_type(T, enc)` and
  `decode_invalid_type(P, enc)`.
* Tuples: the union of the `decode_invalid_type` of their element types.
* [`Manual`](@ref): `codec_decode_invalid_type(T, enc)`.

# Examples
```jldoctest
julia> Inscription.decode_invalid_type(UInt32, LittleEndian())
Union{}

julia> Inscription.decode_invalid_type(Tuple{Bool, UInt8}, LittleEndian())
Nothing
```
"""
@inline function decode_invalid_type(::Type{T}, enc::Encoding)::Type where {T}
    scheme = codec_kind(T, enc)
    return if scheme isa BitsLoadable
        Union{}
    elseif scheme isa BitsStorable
        bits_decode_invalid_type(T, enc)
    elseif scheme isa Proxy
        proxy_decode_invalid_type(T, scheme, enc)
    else
        codec_decode_invalid_type(T, enc)::Type
    end
end

"""
    encode_invalid_type(::Type{T}, enc::Encoding)::Type

The type of the payloads of the errors of encoding a `T` with `enc`.
When encoding a `T` fails, the error is an
`EncodeError{encode_invalid_type(T, enc)}`, whose payload is `Some(x)`,
where `x` is the payload of the `Invalid` that encoding returned.

Do not add methods to this function. Like [`decode_invalid_type`](@ref), it is derived
from the codec scheme of `T`, and from [`codec_encode_invalid_type`](@ref):
* [`BitsLoadable`](@ref) and [`BitsStorable`](@ref): `Union{}`, since every value can be
  encoded.
* [`Proxy{P}`](@ref Proxy): the union of `codec_encode_invalid_type(T, enc)` and
  `encode_invalid_type(P, enc)`.
* Tuples: the union of the `encode_invalid_type` of their element types.
* [`Manual`](@ref): `codec_encode_invalid_type(T, enc)`.
"""
@inline function encode_invalid_type(::Type{T}, enc::Encoding)::Type where {T}
    scheme = codec_kind(T, enc)
    return if scheme isa BitsScheme
        Union{}
    elseif scheme isa Proxy
        proxy_encode_invalid_type(T, scheme, enc)
    else
        codec_encode_invalid_type(T, enc)::Type
    end
end

# `x`, returned by `f` when decoding or encoding a T with `enc`, as an `Invalid` of the
# payload type P of T. So the result has the same concrete type, whatever `Invalid` the
# codec of T returned, or passed on from the values it is made of. `x` must be an
# `Invalid{B}` with `B <: P`. The check is constant-folded when the type of `x` is known.
@inline function as_decode_invalid(x::Invalid{B}, f, ::Type{T}, enc::Encoding) where {B, T}
    P = decode_invalid_type(T, enc)
    B <: P || throw_payload_error(f, codec_decode_invalid_type, T, enc, B, P)
    return Invalid{P}(x.payload)
end

@inline function as_encode_invalid(x::Invalid{B}, f, ::Type{T}, enc::Encoding) where {B, T}
    P = encode_invalid_type(T, enc)
    B <: P || throw_payload_error(f, codec_encode_invalid_type, T, enc, B, P)
    return Invalid{P}(x.payload)
end

# `result`, but if it is an `Invalid`, then as in `as_decode_invalid`
@inline function widen_decode_invalid(result, f, ::Type{T}, enc::Encoding) where {T}
    return result isa Invalid ? as_decode_invalid(result, f, T, enc) : result
end

@inline function widen_encode_invalid(result, f, ::Type{T}, enc::Encoding) where {T}
    return result isa Invalid ? as_encode_invalid(result, f, T, enc) : result
end

@noinline function throw_payload_error(f, trait, ::Type{T}, enc::Encoding, B::Type, P::Type) where {T}
    advice = if B === Nothing
        "`Invalid()` is an `Invalid{Nothing}`. To return it, declare a payload type that " *
            "includes `Nothing`, e.g. `Union{Nothing, $P}`, with `$(nameof(trait))`, or " *
            "return an `Invalid` with a payload of type `$P`"
    else
        "Declare the type of its payloads with `$(nameof(trait))`, e.g. as `Union{$P, $B}`"
    end
    return error(
        "`$(nameof(f))` for `$T` with `$enc` broke its contract: it returned an `Invalid{$B}`, " *
            "but the payload type of `$T` with `$enc` is `$P`, so it must return an " *
            "`Invalid{Q}` with `Q <: $P`. " * advice
    )
end
