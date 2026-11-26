"""
    abstract type CodecScheme end

Supertype of zero-sized trait structs that signals if a type / [`Encoding`](@ref) pair
can have auto-derived codec implementations.

For some types / encoding pairs like `Float32` being encoded in [`BigEndian`](@ref),
or [`LittleEndian`](@ref) the codec can be automatically implemented,
because the codec is simply loading/storing with a pointer, and maybe byte swapping.
For such a type `T`, users can declare:
```julia
BitScribbling.codec_scheme(::Type{T}, ::Endianness) = BitScribbling.BitsLoadable()
```
And then the codec T/Endianness is automatically implemented.

The fallback for `codec_scheme(T, E)` is [`Manual`](@ref). The current list of opt-in
codec schemes beyond `Manual` are:
* [`BitsLoadable`](@ref)
* [`BitsStorable`](@ref)
* [`Proxy`](@ref)

See extended help for which type / encoding pairs are eligible to opt into these
codec schemes.

# Extended help
A custom type `T` can opt into the following codec schemes. It should generally opt into the
first applicable one on this list, as they are listed from most to least convenient.

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
* `T` must have no padding on any platform. The padding check is done by assuming
   the alignment of any primitive is equal to the next power of two equal to or
   larger than its bitsize, and that the alignment of any struct is equal to its largest field.
   This is the most conservative possible rule.
   This also rules out primitive types whose bit size is not a multiple of 8.
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
is_valid_bits(::Type{T}, ::NTuple{sizeof(T), UInt8}) = ...
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
try_to_proxy(::T, ::E)::Union{P, Invalid} = ...
try_from_proxy(::Type{T}, ::P, ::E)::Union{T, Invalid} = ...
```

Any type can be `Proxy`, but it only makes sense to implement if `T` can be
easily created from / used to create a `P`, which already has an encoding.

## `Manual`
The fallback codec.

To implement a `Manual` codec for type `T` over encoding `E`, you should implement:

```julia
codec_max_encoded_size(::Type{T}, ::E)::Union{Val{N}, Unbounded()}
codec_try_decode(::DecodeInput, ::Type{T}, ::E)::Union{Tuple{T, Int}, Invalid, TooShort}
codec_try_encode!(::EncodeOutput, ::T, ::E)::Union{Int, Invalid, TooShort}
```
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
`BitScribbling.codec_scheme(::Type{MyType}, ::Endianness) = BitScribbling.BitsLoadable()`.

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

Return [`Invalid()`](@ref Invalid) if `x` can't be represented as a `P`.
Encoding `x` then fails with `InvalidValue`.

It is not called directly, but via the encoding or storing functions.

See also: [`try_from_proxy`](@ref), [`CodecScheme`](@ref)
"""
function try_to_proxy end

"""
    try_from_proxy(::Type{T}, p::P, enc::E)::Union{T, Invalid} where {E <: Encoding}

Try constructing a `T` from `p::P`, when `codec_scheme(T, ::E) == Proxy{P}()`.

This method should be implemented only when the `CodecScheme` of `(T, E)` has been chosen as `Proxy{P}`.

Return [`Invalid()`](@ref Invalid) if `p` can't be converted to a `T`.
Decoding a `T` then fails with `InvalidData`, even though the bytes are a valid encoding of a `P`.

It is not called directly, but via the decoding or loading functions.

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

@inline function proxy_try_decode(
        input::DecodeInput, ::Type{T}, ::Proxy{P}, enc::Encoding
    )::Union{Tuple{T, Int}, TooShort, Invalid} where {T, P}
    (p, n, _) = @? decode_field(input, P, enc)
    x = @? try_from_proxy(T, p, enc)::Union{T, Invalid}
    return (x, n)
end

@inline function proxy_try_encode!(
        output::EncodeOutput, x, ::Proxy{P}, enc::Encoding
    )::Union{Int, TooShort, Invalid} where {P}
    p = @? try_to_proxy(x, enc)::Union{P, Invalid}
    (n, _) = @? encode_field(output, p, enc)
    return n
end
