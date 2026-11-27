"""
    module DecodeErrorKinds

Used as a namespace for [`DecodeErrorKind`](@ref DecodeErrorKinds.DecodeErrorKind).
"""
module DecodeErrorKinds
    """
        DecodeErrorKind

    Enum indicating why decoding or loading a value failed. The current list is
    non-exhaustive, and more may be added in future releases.
    The integral values of these enums are subject to change in minor versions,
    but its type is guaranteed `UInt8`.

    Current kinds:
    * [`DecodeErrorKinds.EndOfInput`](@ref)
    * [`DecodeErrorKinds.Truncated`](@ref)
    * [`DecodeErrorKinds.InvalidData`](@ref)
    * [`DecodeErrorKinds.TrailingData`](@ref)
    """
    @enum DecodeErrorKind::UInt8 begin
        EndOfInput
        Truncated
        InvalidData
        TrailingData
    end

    """
        EndOfInput

    There were no bytes at all to decode from: a clean end of input.
    """
    EndOfInput

    """
        Truncated

    The input ended partway through an encoded value.
    """
    Truncated

    """
        InvalidData

    The bytes are not a valid encoding of a value of the requested type.
    """
    InvalidData

    """
        TrailingData

    A value was decoded, but the input continues after its encoding, where the input
    should hold exactly one encoded value. Only returned or thrown by the functions
    that decode exactly, such as [`try_decode_exact`](@ref Inscription.try_decode_exact)
    and [`try_load_exact`](@ref Inscription.try_load_exact).
    """
    TrailingData

    public DecodeErrorKind, EndOfInput, Truncated, InvalidData, TrailingData
end

using .DecodeErrorKinds: DecodeErrorKind, EndOfInput, Truncated, InvalidData, TrailingData

"""
    DecodeError{P} <: Exception
    DecodeError(kind::DecodeErrorKind)
    DecodeError(kind::DecodeErrorKind, payload::Some)
    DecodeError{P}(kind::DecodeErrorKind, [payload::Union{Nothing, Some}])

A failure to decode or load a value, caused by the data. It has the public properties
`.kind::DecodeErrorKind` and `.payload::Union{Nothing, Some{P}}`.

The payload is `Some(x)` exactly when the kind is `InvalidData`, where `x::P` is the
payload of the [`Invalid`](@ref) that the codec returned, and `nothing` for the other
kinds. It tells why the data is invalid: for example, `Some(Overflow)` from a codec that
parses integers. When the codec gave no reason, by returning `Invalid()`, it is
`Some(nothing)`.

When decoding a `T` with the encoding `enc`, `P` is
[`decode_invalid_type(T, enc)`](@ref decode_invalid_type), whatever the kind. So functions
such as [`try_load`](@ref) return a union of only two types. For types that can't be
invalid, such as `UInt32` with `LittleEndian`, `P` is `Union{}`.

`DecodeError(kind)` is a `DecodeError{Nothing}`, whose payload is `Some(nothing)` if the
kind is `InvalidData`, else `nothing`. `DecodeError{P}(kind)` is the same, with the type
`P`. Constructing an error whose payload is not `Some` exactly when the kind is
`InvalidData` throws an `ArgumentError`.

Two `DecodeError`s are `==` if their kinds and payloads are, whatever their types. So
`err == DecodeError(EndOfInput)` tells if an error of any type is a clean end of input,
and `err == DecodeError(InvalidData, Some(Overflow))` if the data is invalid because of
an overflow.

Functions prefixed with `try_` return a `DecodeError` instead of throwing it.
The functions without the prefix throw the same value.

See also: [`DecodeErrorKinds.DecodeErrorKind`](@ref), [`@?`](@ref)

# Examples
```jldoctest
julia> using BufferIO: CursorReader

julia> io = CursorReader([0x01, 0x00, 0x02]);

julia> while true
           x = try_load(io, UInt16, LittleEndian())
           if x isa DecodeError
               x.kind === DecodeErrorKinds.EndOfInput && break
               println("Error: ", x.kind)
               break
           end
           println(x)
       end
1
Error: Truncated
```
"""
struct DecodeError{P} <: Exception
    kind::DecodeErrorKind
    payload::Union{Nothing, Some{P}}

    function DecodeError{P}(kind::DecodeErrorKind, payload::Union{Nothing, Some}) where {P}
        (payload isa Some) === (kind === InvalidData) || throw_payload_kind_error(kind, InvalidData, payload)
        return new{P}(kind, payload)
    end
end

function DecodeError{P}(kind::DecodeErrorKind) where {P}
    return DecodeError{P}(kind, kind === InvalidData ? Some{P}(nothing) : nothing)
end

DecodeError(kind::DecodeErrorKind) = DecodeError{Nothing}(kind)
DecodeError(kind::DecodeErrorKind, payload::Some{P}) where {P} = DecodeError{P}(kind, payload)

Base.show(io::IO, err::DecodeError{P}) where {P} = show_error(io, err, DecodeError, P)

# Errors are equal if their kinds and payloads are, whatever their payload types. So
# `err == DecodeError(EndOfInput)` holds for errors of any type that are at the end of input.
Base.:(==)(a::DecodeError, b::DecodeError) = a.kind === b.kind && payload_isequal(a.payload, b.payload)
Base.hash(x::DecodeError, h::UInt) = payload_hash(x.payload, hash(x.kind, hash(DecodeError, h)))

# Compare and hash payloads by their values, not their types. Before Julia 1.12,
# `isequal(Some{Union{Nothing, Int}}(1), Some(1))` is `false`, since `Some` has no
# `isequal` or `hash` method there, so `isequal` on the payloads directly would be too
# strict.
function payload_isequal(a::Union{Nothing, Some}, b::Union{Nothing, Some})
    a === nothing && return b === nothing
    b === nothing && return false
    return isequal(something(a), something(b))
end

function payload_hash(payload::Union{Nothing, Some}, h::UInt)
    payload === nothing && return hash(nothing, h)
    return hash(something(payload), hash(Some, h))
end

function Base.showerror(io::IO, err::DecodeError)
    kind = err.kind
    str = if kind === EndOfInput
        "End of input: no bytes left to decode"
    elseif kind === Truncated
        "Truncated input: the input ended partway through an encoded value"
    elseif kind === InvalidData
        "Invalid data: the bytes are not a valid encoding of the requested type"
    elseif kind === TrailingData
        "Trailing data: the input continues after the encoded value"
    else
        "Unknown decoding error"
    end
    print(io, "DecodeError: ", str)
    show_payload(io, err.payload)
    return nothing
end

# Show the error `err` of the type `name{P}` as the call that constructs it. If its
# payload follows from its kind, the payload is left out: then the error is
# `name(kind)` if `P` is `Nothing`, else `name{P}(kind)`.
function show_error(io::IO, err, name::UnionAll, P::Type)
    payload = err.payload
    implied = payload === nothing || something(payload) === nothing
    show(io, implied && P === Nothing ? name : typeof(err))
    print(io, '(')
    show(io, err.kind)
    if !implied
        print(io, ", ")
        show(io, payload)
    end
    print(io, ')')
    return nothing
end

# Show the payload in `showerror`, unless it is `nothing` or `Some(nothing)`, which
# give no reason
function show_payload(io::IO, payload::Union{Nothing, Some})
    (payload === nothing || something(payload) === nothing) && return nothing
    print(io, " (payload: ")
    show(io, something(payload))
    print(io, ')')
    return nothing
end

@noinline function throw_payload_kind_error(kind, invalid_kind, payload)
    throw(
        ArgumentError(
            "the payload of an error must be `Some` exactly when its kind is `$invalid_kind`, " *
                "but the kind is `$kind`, and the payload is `$(repr(payload))`"
        )
    )
end

"""
    module EncodeErrorKinds

Used as a namespace for [`EncodeErrorKind`](@ref EncodeErrorKinds.EncodeErrorKind).
"""
module EncodeErrorKinds
    """
        EncodeErrorKind

    Enum indicating why encoding or storing a value failed. The current list is
    non-exhaustive, and more may be added in future releases.
    The integral values of these enums are subject to change in minor versions,
    but its type is guaranteed `UInt8`.

    Current kinds:
    * [`EncodeErrorKinds.InsufficientSpace`](@ref)
    * [`EncodeErrorKinds.InvalidValue`](@ref)
    """
    @enum EncodeErrorKind::UInt8 begin
        InsufficientSpace
        InvalidValue
    end

    """
        InsufficientSpace

    The memory to encode into is too short for the encoding of the value.
    Nothing has been written.
    """
    InsufficientSpace

    """
        InvalidValue

    The value can't be encoded with the encoding, for example a `Char` that is not in
    an 8-bit character set. Bytes up to the value's
    [`max_encoded_size`](@ref Inscription.max_encoded_size) may have been written.
    """
    InvalidValue

    public EncodeErrorKind, InsufficientSpace, InvalidValue
end

using .EncodeErrorKinds: EncodeErrorKind, InsufficientSpace, InvalidValue

"""
    EncodeError{P} <: Exception
    EncodeError(kind::EncodeErrorKind)
    EncodeError(kind::EncodeErrorKind, payload::Some)
    EncodeError{P}(kind::EncodeErrorKind, [payload::Union{Nothing, Some}])

A failure to encode or store a value. It has the public properties
`.kind::EncodeErrorKind` and `.payload::Union{Nothing, Some{P}}`.

As for [`DecodeError`](@ref), the payload is `Some(x)` exactly when the kind is
`InvalidValue`, where `x::P` is the payload of the [`Invalid`](@ref) that the codec
returned, and `Some(nothing)` for `Invalid()`. It is `nothing` for `InsufficientSpace`.

When encoding a `T` with the encoding `enc`, `P` is
[`encode_invalid_type(T, enc)`](@ref encode_invalid_type), whatever the kind. For types that
can always be encoded, such as bits types, it is `Union{}`. `EncodeError(kind)` is an
`EncodeError{Nothing}`, whose payload is `Some(nothing)` if the kind is `InvalidValue`.
As for `DecodeError`, errors are `==` if their kinds and payloads are.

Functions prefixed with `try_` return an `EncodeError` instead of throwing it:
* [`try_encode!`](@ref) returns either kind.
* [`try_store`](@ref) only returns `InvalidValue`.

The functions without the prefix throw an `InvalidValue` error as it is. [`encode!`](@ref)
throws a `LightBoundsError` instead of an `InsufficientSpace` error.

Types that are [`BitsLoadable`](@ref) or [`BitsStorable`](@ref) can always be encoded,
so with them, an `EncodeError` always has the kind `InsufficientSpace`.

See also: [`EncodeErrorKinds.EncodeErrorKind`](@ref), [`@?`](@ref)

# Examples
```jldoctest
julia> try_encode!(MemoryView(zeros(UInt8, 3)), 0x01020304, BigEndian())
EncodeError{Union{}}(Inscription.EncodeErrorKinds.InsufficientSpace)
```
"""
struct EncodeError{P} <: Exception
    kind::EncodeErrorKind
    payload::Union{Nothing, Some{P}}

    function EncodeError{P}(kind::EncodeErrorKind, payload::Union{Nothing, Some}) where {P}
        (payload isa Some) === (kind === InvalidValue) || throw_payload_kind_error(kind, InvalidValue, payload)
        return new{P}(kind, payload)
    end
end

function EncodeError{P}(kind::EncodeErrorKind) where {P}
    return EncodeError{P}(kind, kind === InvalidValue ? Some{P}(nothing) : nothing)
end

EncodeError(kind::EncodeErrorKind) = EncodeError{Nothing}(kind)
EncodeError(kind::EncodeErrorKind, payload::Some{P}) where {P} = EncodeError{P}(kind, payload)

Base.show(io::IO, err::EncodeError{P}) where {P} = show_error(io, err, EncodeError, P)

# As for `DecodeError`
Base.:(==)(a::EncodeError, b::EncodeError) = a.kind === b.kind && payload_isequal(a.payload, b.payload)
Base.hash(x::EncodeError, h::UInt) = payload_hash(x.payload, hash(x.kind, hash(EncodeError, h)))

function Base.showerror(io::IO, err::EncodeError)
    kind = err.kind
    str = if kind === InsufficientSpace
        "Insufficient space: the memory is too short for the encoding of the value"
    elseif kind === InvalidValue
        "Invalid value: the value can't be encoded with the encoding"
    else
        "Unknown encoding error"
    end
    print(io, "EncodeError: ", str)
    show_payload(io, err.payload)
    return nothing
end

"""
    TooShort

Returned by the functions that a codec reads or writes bytes through, when the input or
output is too short, and returned by the codec with [`@?`](@ref). See
[`DecodeInput`](@ref) and [`EncodeOutput`](@ref). A codec does not construct it itself.

When decoding, `TooShort` may also mean that more bytes are needed to decide the result
than are available yet. A codec never returns it when its input or output has [`max_encoded_size`](@ref)
bytes.

See also: [`Invalid`](@ref)
"""
struct TooShort
    # When encoding, the number of bytes that were asked for, counted from the start of the
    # output that the package gave to the codec. It is larger than that output. A writer
    # grows its buffer to at least this size. Not used when decoding, then it is zero.
    needed::Int
end

TooShort() = TooShort(0)

"""
    Invalid{P}(payload::P)
    Invalid(payload)
    Invalid()

Returned by a codec when the input is not a valid encoding, or when the value can't be
encoded. `Invalid()` is `Invalid(nothing)`, an `Invalid{Nothing}`.

The payload tells why. It becomes the payload of the [`DecodeError`](@ref) of kind
`InvalidData`, or the [`EncodeError`](@ref) of kind `InvalidValue`, that the functions
which use the codec return. For example, a codec that parses decimal integers may return
`Invalid(Overflow)`, where `Overflow` is a value of an enum, so that its caller can try
again with a wider integer type.

Its type must be declared: every `Invalid` that the codec of a type `T` with an encoding
`E` returns must be an `Invalid{Q}`, where `Q` is a subtype of the payload type
[`codec_decode_invalid_type(T, E())`](@ref codec_decode_invalid_type) when decoding, or
[`codec_encode_invalid_type(T, E())`](@ref codec_encode_invalid_type) when encoding.
Otherwise, an `ErrorException` is thrown. Both default to `Nothing`, so a codec that is
not declared to have payloads returns `Invalid()`. A codec that declares a payload type
can only return `Invalid()` if the type includes `Nothing`, e.g. `Union{Nothing, MyError}`.

The `Invalid` is converted to the declared type, so a codec whose payload type is a union,
e.g. `Union{Nothing, MyError}`, may return both `Invalid()` and `Invalid(MyError(...))`.
But it is faster to construct the declared type, e.g.
`Invalid{Union{Nothing, MyError}}(nothing)`: if a codec returns `Invalid`s of different
types, its result type is a union of too many types for the compiler to keep it
concrete, so the errors are slower to return.

Payloads should be `isbits`, so that errors can be returned without allocating.

See also: [`TooShort`](@ref)
"""
struct Invalid{P}
    payload::P
end

Invalid() = Invalid(nothing)

# Shown as the call that constructs it, `Invalid()` if it is that
function Base.show(io::IO, x::Invalid{P}) where {P}
    if P === Nothing
        show(io, Invalid)
        print(io, "()")
    else
        show(io, typeof(x))
        print(io, '(')
        show(io, x.payload)
        print(io, ')')
    end
    return nothing
end

"""
    @? expr

Expands to the equivalent of the following, except that the variable is an
anonymous local variable and so cannot clash with any variable from the enclosing scope:

```julia
x = expr
if x isa Union{DecodeError, EncodeError, TooShort, Invalid}
    return x
else
    x
end
```

# Examples
```jldoctest
julia> function load_pair(io)
           a = @? try_load(io, UInt16, BigEndian())
           b = @? try_load(io, UInt16, BigEndian())
           return (a, b)
       end;

julia> load_pair(BufferIO.CursorReader([0x00, 0x01, 0x00, 0x02]))
(0x0001, 0x0002)

julia> load_pair(BufferIO.CursorReader([0x00, 0x01, 0x00]))
DecodeError{Union{}}(Inscription.DecodeErrorKinds.Truncated)
```
"""
macro var"?"(expr)
    return quote
        result = $(esc(expr))
        result isa Union{DecodeError, EncodeError, TooShort, Invalid} && return result
        result
    end
end

# The errors of decoding or encoding a T with `enc`, as a `DecodeError` or `EncodeError`
# of the same concrete type for every kind, see `decode_invalid_type`. The kinds passed
# alone are never `InvalidData` or `InvalidValue`, which have the payload of an `Invalid`.
@inline function decode_error(::Type{T}, enc::Encoding, kind::DecodeErrorKind) where {T}
    return DecodeError{decode_invalid_type(T, enc)}(kind, nothing)
end

@inline function decode_error(::Type{T}, enc::Encoding, x::Invalid) where {T}
    P = decode_invalid_type(T, enc)
    return DecodeError{P}(InvalidData, Some{P}(x.payload))
end

@inline function encode_error(::Type{T}, enc::Encoding, kind::EncodeErrorKind) where {T}
    return EncodeError{encode_invalid_type(T, enc)}(kind, nothing)
end

@inline function encode_error(::Type{T}, enc::Encoding, x::Invalid) where {T}
    P = encode_invalid_type(T, enc)
    return EncodeError{P}(InvalidValue, Some{P}(x.payload))
end

# Throw `e`. Outlined, because throwing boxes the isbits error, which would otherwise be
# done at every call site that inlines the caller.
@noinline throw_decode_error(e::DecodeError) = throw(e)
@noinline throw_encode_error(e::EncodeError) = throw(e)
