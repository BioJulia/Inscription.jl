"""
    abstract type Encoding end

`Encoding` are zero-sized trait structs used to signal how one value
of a given type `T` is encoded to a given encoding, i.e. sequence of bytes,
and decoded from the encodings.

Thus, reading and writing behaviour is governed by the pair `(T, enc::Encoding)`.
Such an implementation over a pair is called a "codec".
BitScribbling's functions like `load`, `store_all`, `decode_every`,
etc. use the codecs as their inner kernel.

Users are free to define their own `Encoding`s and implement codecs for them.

Two `Encoding`s are special: [`LittleEndian`](@ref) and [`BigEndian`](@ref),
together referred to as Endian `Encoding`s (`Endianness`).
Conceptually, these signal loading and storing the raw bits of the value of `T`.
For example, encoding the `UInt32` `0x01020304` in `LittleEndian` encodes it
to the following bytes `[0x04, 0x03, 0x02, 0x01]`.

Codecs for Endian `Encoding`s can be automatically implemented by declaring the type
[`BitsLoadable`](@ref) or [`BitsStorable`](@ref), and a type can be encoded as another
type with any encoding by declaring a [`Proxy`](@ref). See [`CodecScheme`](@ref).

See also: [`Endianness`](@ref), [`CodecScheme`](@ref)
"""
abstract type Encoding end

"""
    LittleEndian() <: Encoding

Encoding signifying copying the raw bytes of the value in little-endian byte order.
See [`Encoding`](@ref) for more details.

See also: [`BigEndian`](@ref), [`NATIVE_ENDIAN`](@ref), [`Endianness`](@ref)
"""
struct LittleEndian <: Encoding end

"""
    BigEndian() <: Encoding

Encoding signifying copying the raw bytes of the value in big-endian byte order.
See [`Encoding`](@ref) for more details.

See also: [`LittleEndian`](@ref), [`NATIVE_ENDIAN`](@ref), [`Endianness`](@ref)
"""
struct BigEndian <: Encoding end

"""
    Endianness = Union{LittleEndian, BigEndian}

See also: [`Encoding`](@ref) [`LittleEndian`](@ref), [`BigEndian`](@ref) [`NATIVE_ENDIAN`](@ref)
```
"""
const Endianness = Union{LittleEndian, BigEndian}

"""
    NATIVE_ENDIAN::Endianness

The byte order of the host, either `LittleEndian()` or `BigEndian()`.
As a rule of thumb, avoid implementing codecs for this constant, since it
makes the implementation platform-dependent in surprising ways.
Implement a codec for `LittleEndian` or `BigEndian`

See also: [`Encoding`](@ref) [`LittleEndian`](@ref), [`BigEndian`](@ref) [`Endianness`](@ref)
"""
const NATIVE_ENDIAN = ENDIAN_BOM == 0x04030201 ? LittleEndian() : BigEndian()

"""
    UTF8() <: Encoding

UTF-8 encoding, e.g. of `Char`.

Encoding and decoding follows the iteration of `Base.String`. In details, the rules
are as follows:

For decoding, the rules are:
* A lead byte c0-df, e0-ef or f0-f7 starts a `Char` of at most 2, 3 or 4 bytes,
  respectively.
  The following bytes are part of the `Char` while they are continuation bytes
  (80-bf), up to that length.
* Any other byte (ASCII, a continuation byte, or f8-ff) is decoded alone as a `Char`.
* The bytes are not validated further, so the decoded `Char` may be malformed or invalid.
  For example, `[0xe4, 0xb8, 0x30]` decodes as `'\\xe4\\xb8'` followed by `'0'`,
  and the overlong `[0xc0, 0x80]` as the single Char `'\\xc0\\x80'`.
* If the input ends partway through a `Char`, as in `[0xc3]`,
  the bytes so far are decoded as a malformed Char.

For encoding, the codeunits are written in UTF8 form, including for invalid
UTF8, with the following notable behaviour:
* A `Char` which could never be decoded according to the above rules, such as
  `reinterpret(Char, typemax(UInt32))`, can not be encoded and will give an 
  [`EncodeError`](@ref) of kind `InvalidValue`.
* The concatenated encoding of multiple invalid `Char`s may be
  decoded as one valid `Char`. E.g. the concatenated encoding of `'\\xc3'`
  followed by `'\\xb8'` is `[0xc3, 0xb8]`, which decodes as `'ø'`.

# Examples
```jldoctest
julia> encode!(MemoryView(zeros(UInt8, 4)), 'é', UTF8())
2

julia> decode_next(MemoryView("€!"), 1, Char, UTF8())
('€', 4)

julia> decode(MemoryView(b"\\xe2\\x82"), Char, UTF8()) # truncated input: a malformed Char
'\\xe2\\x82': Malformed UTF-8 (category Ma: Malformed, bad data)
```
"""
struct UTF8 <: Encoding end

"""
    Unbounded()

Marker struct that signals an encoding has no, or a large, upper limit on
number of encoded bytes, e.g. for null-terminated strings.

This signals that when loading from an `AbstractBufReader`, BitScribbling should
not attempt to buffer the maximal size up front.
Implemented as `codec_max_encoded_size(::Type{T}, ::SomeEncoding) = Unbounded()`,
with the encoding typically being `Endianness`.

Also returned by [`max_encoded_size`](@ref).

See also: [`codec_max_encoded_size`](@ref).
"""
struct Unbounded end

# Returned by the default method of `codec_max_encoded_size`: there is no codec.
struct NoCodec end

"""
    abstract type DecodeInput

The input of [`codec_try_decode`](@ref): the bytes to decode a value from.
This abstracts over `Memory`-backed input and `AbstractBufReader`-backed input.

A codec reads from `DecodeInput` only through these functions:
* [`require_bytes(input, n)`](@ref require_bytes): the first `n` bytes, as a memory view
  of length `n`,
* [`peek_byte(input, i)`](@ref peek_byte): the byte at index `i`, or `nothing` if the
  input ends before it,
* [`decode_field(input, T, enc)`](@ref decode_field): a value of type `T` from the start,
  the number of bytes it used, and the input after them.

These functions may return [`TooShort`](@ref), which can conveniently be returned
early with [`@?`](@ref), as in `@? peek_byte(input, 1)`.

When backed by a reader, these functions buffer more bytes from the reader as needed.
They then return `TooShort` only if the input ends too early.

# Extended help
## Invalidated views
When backed by a reader, buffering more bytes may invalidate previous views of the
`DecodeInput`'s data from `require_bytes`.
To be correct for all inputs, a codec must follow these rules:

* A call to [`require_bytes`](@ref), [`peek_byte`](@ref) or [`decode_field`](@ref) which
  reaches beyond all earlier reads may invalidate all previous views. E.g. if the
  earlier reads reached index 10, reads reaching indices > 10 may invalidate previous
  views, but not reads reaching only indices < 11.
* All views are invalidated when `codec_try_decode` returns. So, do not return views,
  or otherwise let views escape from `codec_try_decode`.
"""
abstract type DecodeInput end

# Memory known to hold at least `L` bytes.
struct MemoryInput{L} <: DecodeInput
    mem::ImmutableMemoryView{UInt8}
    # Whether the input ends at the end of `mem`. If not, more bytes may follow `mem`.
    ends::Bool
    # Internal. The caller must ensure that `length(mem) ≥ L`.
    function MemoryInput{L}(mem::ImmutableMemoryView{UInt8}, ends::Bool) where {L}
        L isa Int && L ≥ 0 || error("L must be a non-negative Int")
        return new{L}(mem, ends)
    end
end

# The bytes after the first `offset` bytes of the buffer of `io`, which is filled as needed.
# Nothing is consumed. The input ends after the first `stop` bytes of the buffer, counted
# from the start of the buffer, or at EOF.
struct ReaderInput{R <: AbstractBufReader} <: DecodeInput
    io::R
    offset::Int
    stop::Int
end

"""
    EncodeOutput{L}

The output of [`codec_try_encode!`](@ref): the bytes to encode a value into.
It is guaranteed to hold holds at least `L` bytes, and may contain more bytes.
A codec should to to `EncodeOutput` only through the following functions:
* [`reserve_bytes(output, n)`](@ref reserve_bytes): the first `n` bytes, as a mutable
  memory view of length `n`, for the codec to write;
* [`encode_field(output, x, enc)`](@ref encode_field): encode `x` at the start, and
  return the number of bytes written, and the output after them.

These functions may return [`TooShort`](@ref), which can conveniently be returned
early with [`@?`](@ref), as in `@? reserve_bytes(output, 10)`.
"""
struct EncodeOutput{L}
    mem::MutableMemoryView{UInt8}
    # The number of bytes before `mem` in the output that the package gave to the codec.
    # Outputs after fields, made by `encode_field`, start after the start of that output.
    # `TooShort` counts from there.
    offset::Int
    # Internal. The caller must ensure that `length(mem) ≥ L`.
    function EncodeOutput{L}(mem::MutableMemoryView{UInt8}, offset::Int = 0) where {L}
        L isa Int && L ≥ 0 || error("L must be a non-negative Int")
        return new{L}(mem, offset)
    end
end
