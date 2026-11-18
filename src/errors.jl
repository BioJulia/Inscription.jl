"""
    module DecodeErrorKinds

Used as a namespace for [`DecodeErrorKind`](@ref DecodeErrorKinds.DecodeErrorKind).
"""
module DecodeErrorKinds
    """
        DecodeErrorKind

    Enum indicating why decoding or loading a value failed. The current list is
    non-exhaustive, and more may be added in future releases.
    The integral values of these enums are subject to change in minor versions.

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
    should hold exactly one encoded value. Only returned by the functions that decode
    exactly, such as [`try_decode_exact`](@ref BitScribbling.try_decode_exact) and
    [`try_load_exact`](@ref BitScribbling.try_load_exact).
    """
    TrailingData

    public DecodeErrorKind, EndOfInput, Truncated, InvalidData, TrailingData
end

using .DecodeErrorKinds: DecodeErrorKind, EndOfInput, Truncated, InvalidData, TrailingData

"""
    DecodeError <: Exception

A failure to decode or load a value, caused by the data. It has the public property
`.kind::DecodeErrorKind`.

Functions prefixed with `try_` return a `DecodeError` instead of throwing it.
The functions without the prefix throw the same value.
`DecodeError` is a 1-byte isbits type, so returning `Union{T, DecodeError}` does not
allocate.

See also: [`DecodeErrorKinds.DecodeErrorKind`](@ref), [`@try_return`](@ref)

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
struct DecodeError <: Exception
    kind::DecodeErrorKind
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
    return nothing
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
    The integral values of these enums are subject to change in minor versions.

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
    [`max_encoded_size`](@ref BitScribbling.max_encoded_size) may have been written.
    """
    InvalidValue

    public EncodeErrorKind, InsufficientSpace, InvalidValue
end

using .EncodeErrorKinds: EncodeErrorKind, InsufficientSpace, InvalidValue

"""
    EncodeError <: Exception

A failure to encode or store a value. It has the public property
`.kind::EncodeErrorKind`.

Functions prefixed with `try_` return an `EncodeError` instead of throwing it:
* [`try_encode!`](@ref) returns either kind.
* [`try_store`](@ref) and [`try_encoded_size`](@ref) only return `InvalidValue`.

The functions without the prefix throw an `InvalidValue` error as it is. [`encode!`](@ref)
throws a `LightBoundsError` instead of an `InsufficientSpace` error.
`EncodeError` is a 1-byte isbits type, so returning `Union{Int, EncodeError}` does not
allocate.

Types that are [`BitsLoadable`](@ref) or [`BitsStorable`](@ref) can always be encoded,
so with them, an `EncodeError` always has the kind `InsufficientSpace`.

See also: [`EncodeErrorKinds.EncodeErrorKind`](@ref), [`@try_return`](@ref)

# Examples
```jldoctest
julia> try_encode!(MemoryView(zeros(UInt8, 3)), 0x01020304, BigEndian())
EncodeError(BitScribbling.EncodeErrorKinds.InsufficientSpace)
```
"""
struct EncodeError <: Exception
    kind::EncodeErrorKind
end

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
    return nothing
end

"""
    @try_return expr

Evaluate `expr`. If the result is a [`DecodeError`](@ref) or an [`EncodeError`](@ref),
return it from the enclosing function. Otherwise, the macro evaluates to the result.

!!! note
    The name of this macro is provisional.

# Examples
```jldoctest
julia> function load_pair(io)
           a = @try_return try_load(io, UInt16, BigEndian())
           b = @try_return try_load(io, UInt16, BigEndian())
           return (a, b)
       end;

julia> load_pair(BufferIO.CursorReader([0x00, 0x01, 0x00, 0x02]))
(0x0001, 0x0002)

julia> load_pair(BufferIO.CursorReader([0x00, 0x01, 0x00]))
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)
```
"""
macro try_return(expr)
    return quote
        result = $(esc(expr))
        result isa Union{DecodeError, EncodeError} && return result
        result
    end
end

# Throw `e`. Outlined, because throwing boxes the isbits error, which would otherwise be
# done at every call site that inlines the caller.
@noinline throw_decode_error(e::DecodeError) = throw(e)
@noinline throw_encode_error(e::EncodeError) = throw(e)
