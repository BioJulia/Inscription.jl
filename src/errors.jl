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
    that decode exactly, such as [`try_decode_exact`](@ref BitScribbling.try_decode_exact)
    and [`try_load_exact`](@ref BitScribbling.try_load_exact).
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
* [`try_store`](@ref) only returns `InvalidValue`.

The functions without the prefix throw an `InvalidValue` error as it is. [`encode!`](@ref)
throws a `LightBoundsError` instead of an `InsufficientSpace` error.

Types that are [`BitsLoadable`](@ref) or [`BitsStorable`](@ref) can always be encoded,
so with them, an `EncodeError` always has the kind `InsufficientSpace`.

See also: [`EncodeErrorKinds.EncodeErrorKind`](@ref), [`@?`](@ref)

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
    TooShort

Returned by the functions that a codec reads or writes bytes through, when the input or
output is too short, and returned by the codec with [`@?`](@ref). See
[`DecodeInput`](@ref) and [`EncodeOutput`](@ref). A codec does not construct it itself.

The public property `.needed::Int` is the number of bytes that were asked for, counted
from the start of the input or output that the package gave to the codec. It is larger
than that input or output.

When decoding partial input, as when loading from a reader, `TooShort` means that more
bytes are needed to decide the result, and a reader buffers `needed` bytes before it
calls the codec again. A codec never returns it when its input or output has
[`max_encoded_size`](@ref) bytes.

See also: [`Invalid`](@ref)
"""
struct TooShort
    needed::Int
end

"""
    Invalid()

Returned by a codec when the input is not a valid encoding, or when the value can't be
encoded.

See also: [`TooShort`](@ref)
"""
struct Invalid end

"""
    @? expr

Evaluate `expr`. If the result is a [`DecodeError`](@ref), an [`EncodeError`](@ref),
[`TooShort`](@ref) or [`Invalid`](@ref), return it from the enclosing function.
Otherwise, the macro evaluates to the result.

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
DecodeError(BitScribbling.DecodeErrorKinds.Truncated)
```
"""
macro var"?"(expr)
    return quote
        result = $(esc(expr))
        result isa Union{DecodeError, EncodeError, TooShort, Invalid} && return result
        result
    end
end

# Throw `e`. Outlined, because throwing boxes the isbits error, which would otherwise be
# done at every call site that inlines the caller.
@noinline throw_decode_error(e::DecodeError) = throw(e)
@noinline throw_encode_error(e::EncodeError) = throw(e)
