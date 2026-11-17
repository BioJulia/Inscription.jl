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
    """
    @enum DecodeErrorKind::UInt8 begin
        EndOfInput
        Truncated
        InvalidData
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

    public DecodeErrorKind, EndOfInput, Truncated, InvalidData
end

using .DecodeErrorKinds: DecodeErrorKind, EndOfInput, Truncated, InvalidData

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
    else
        "Unknown decoding error"
    end
    print(io, "DecodeError: ", str)
    return nothing
end

"""
    @try_return expr

Evaluate `expr`. If the result is a [`DecodeError`](@ref), return it from the enclosing
function. Otherwise, the macro evaluates to the result.

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
        result isa DecodeError && return result
        result
    end
end

# Throw `e`. Outlined, because throwing boxes the isbits `DecodeError`, which would
# otherwise be done at every call site that inlines the caller.
@noinline throw_decode_error(e::DecodeError) = throw(e)
