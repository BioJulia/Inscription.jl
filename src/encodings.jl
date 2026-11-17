"""
    abstract type Encoding end

An encoding says how *one primitive value* maps to bytes. Encodings are singletons,
passed as the last argument of every function in this package, and resolved at compile
time.

This package defines [`LittleEndian`](@ref), [`BigEndian`](@ref) and [`UTF8`](@ref).
Other packages may define their own encodings, for example
`struct CBool <: Encoding end` for C-style booleans ("nonzero is true").

See also: [`Endianness`](@ref)

# Extended help
## Implementing a codec
A *codec* makes a value type `T` encodable with an encoding. Once it exists, `T` works
with every function of this package, such as [`try_decode`](@ref), [`load`](@ref),
[`store`](@ref) and the bulk functions. Never add methods to those functions directly.

There are three ways to provide a codec, depending on `T`:

| `T` is                                                          | The owner of `T` implements                    |
|:--------------------------------------------------------------- |:---------------------------------------------- |
| A primitive type or isbits struct; every bit pattern is a valid `T` | `bits_kind(::Type{T}) = BitsLoadable()`        |
| A primitive type or isbits struct; its bits are its encoding, but some are invalid | `bits_kind(::Type{T}) = BitsStorable()` and [`is_valid_bits`](@ref) |
| Anything else, or used with other encodings                     | A hand-written codec, see below                |

The first two only apply to [`LittleEndian`](@ref) and [`BigEndian`](@ref), see
[`BitsKind`](@ref), which also lists the requirements for structs.

A hand-written codec for `T` and an encoding type `E` consists of three methods:
* [`codec_max_encoded_size(::Type{T}, ::E)`](@ref codec_max_encoded_size)
* [`codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, ::E)`](@ref codec_try_decode)
* [`codec_encode!(mem::MutableMemoryView{UInt8}, x::T, ::E)`](@ref codec_encode!)

A codec must be defined by the owner of either `T` or `E`, so as not to commit type
piracy.

`E` must be a concrete encoding type, such as `LittleEndian` or `UTF8`, never an abstract
type or a union such as `Encoding` or [`Endianness`](@ref). To support several
encodings, define the methods for each of them, e.g. in a loop over the encoding types.
`T`, on the other hand, may be abstract.

This rule prevents method ambiguities between the codecs of different owners. For
example, the owner of an encoding `E` may define a codec for all `T <: Integer`, and the
owner of `MyInt <: Integer` may define one for `MyInt` with `E`. Since both methods are
for the same concrete `E`, the one for `MyInt` is more specific, and is chosen. If the
owner of `MyInt` had defined its codec for all encodings instead, neither method would be
more specific, and calls would throw an ambiguity error.

## Codecs provided by this package
* `Char` with `UTF8()`.
* With `LittleEndian()` and `BigEndian()`: the built-in integer and floating-point
  types, which are `BitsLoadable`, and `Bool` and `Enum` types, which are
  `BitsStorable`.
"""
abstract type Encoding end

"""
    LittleEndian() <: Encoding

Encode fixed-size values with the least significant byte first.

See also: [`BigEndian`](@ref), [`NATIVE_ENDIAN`](@ref), [`Endianness`](@ref)
"""
struct LittleEndian <: Encoding end

"""
    BigEndian() <: Encoding

Encode fixed-size values with the most significant byte first.

See also: [`LittleEndian`](@ref), [`NATIVE_ENDIAN`](@ref), [`Endianness`](@ref)
"""
struct BigEndian <: Encoding end

"""
    Endianness = Union{LittleEndian, BigEndian}

The byte-order encodings.

When the byte order is only known at runtime, e.g. from a file header, the endianness
value is of type `Endianness`. Use a function barrier, so the code that uses it is
specialised and branch-free:

```julia
e = magic == 0x4949 ? LittleEndian() : BigEndian()
parse_body(io, e)
```
"""
const Endianness = Union{LittleEndian, BigEndian}

"""
    NATIVE_ENDIAN::Endianness

The byte order of the host, either `LittleEndian()` or `BigEndian()`.

Host byte order is never used implicitly by this package. Code that really needs it,
e.g. for memory-mapped files or same-machine IPC, can use this constant explicitly.
"""
const NATIVE_ENDIAN = ENDIAN_BOM == 0x04030201 ? LittleEndian() : BigEndian()

"""
    UTF8() <: Encoding

The UTF-8 encoding of `Char`.

Decoding follows the iteration of `String` exactly, also for malformed or truncated
input: decoding never fails on non-empty input, but may produce a malformed `Char`.
See [`try_decode`](@ref) for details.

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
