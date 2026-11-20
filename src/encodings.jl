"""
    abstract type Encoding end

`Encoding` are zero-sized trait structs used to signal how one `isbits` value
of a given type `T` is encoded to bytes, and decoded from bytes.
Thus, reading and writing behaviour is governed by the pair `(T, enc::Encoding)`.
Such an implementation over a pair is called a "codec".
Given a single implementation of a codec, encoding, and decoding to and from `MemoryView`,
and loading and storing to all `AbstractBufReader`s and `AbstractBufWriter`s automatically
work.

Users are free to define their own `Encoding`s and implement codecs for them.

Two `Encoding`s are special: [`LittleEndian`](@ref) and [`BigEndian`](@ref),
together referred to as Endian `Encoding`s.
Conceptually, these signal loading and storing the raw bits of the value of `T`.
For example, encoding the `UInt32` `0x01020304` in `LittleEndian` encodes it
to the following bytes `[0x04, 0x03, 0x02, 0x01]`.

Codecs for Endian `Encoding`s can be automatically implemented via the [`BitsKind`](@ref)
trait, see the `BitsKind` docstring for details how.

See also: [`Endianness`](@ref)

# Extended help
## Manually implementing a codec
Before doing so, check if you can opt into already-generated codecs via [`BitsKind`](@ref).

A hand-written codec for `T` and an encoding type `E` consists of four methods:
* [`codec_max_encoded_size(::Type{T}, ::E)`](@ref codec_max_encoded_size)
* [`codec_try_encoded_size(x::T, ::E)`](@ref codec_try_encoded_size)
* [`codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)`](@ref codec_try_decode)
* [`codec_try_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)`](@ref codec_try_encode!)

Optionally, it can also implement
[`codec_bytes_needed(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)`](@ref codec_bytes_needed),
so that loading a `T` doesn't wait for more bytes than it needs.

To avoid ambiguity errors, `E` must be a concrete encoding type. Do not implement
codecs for non-concrete types such as `Encoding` or `Endianness`.
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
