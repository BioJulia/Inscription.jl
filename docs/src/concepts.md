# Concepts in Inscription.jl

#### Encoding
A given type may have many formats.
For example, the 16-bit integer `0x0102` can be written as `0x01 0x02` (in big-endian form),
as `0x02 0x01` (in little-endian form), or `0x32 0x35 0x38` (in ASCII decimal).
Inscription.jl uses the term "encoding" to mean the byte sequences used to represent a type.

Different encodings of the same type are expressed in Inscription.jl via subtypes of the abstract type [`Encoding`](@ref).
Each such subtype is zero-sized, such as the predefined `struct LittleEndian <: Encoding end`.

Users are encouraged to define serialization of their types for `LittleEndian`
and `BigEndian`, and may define new encodings at will. See the [Implementing a type](custom.md) page for how to do so.

#### Codec
Inscription.jl uses "codec" to mean the implementation of how to read and write
a given type under a given `Encoding`. See the [Implementing a type](custom.md) page.

#### Odd-sized primitive
An odd-sized primitive is a primitive value whose size in bits is not a multiple of 8.
These are supported in Julia 1.14 onwards. An example is `primitive type Foo 18 end`.
Such types are currently poorly supported by Inscription.jl, because it has no abstractions
for expressing "read 2 bytes and 2 bits from this `AbstractBufReader`".
Support for odd-sized primitives may be added in the future.

Users are free to define a codec/encoding that reads or writes odd-sized primitives
as a whole number of bytes, thus adding padding in the encoding. See the [Implementing a type](custom.md) page for details.

#### Endianness
[Endianness](https://en.wikipedia.org/wiki/Endianness) is the order in which bytes of a multi-byte
primitive type are encoded. This is not a Inscription.jl concept, but a generic computing concept
baked into the CPU. Practically all platforms are little-endian natively, but some binary formats
are big-endian. Inscription.jl represents the two byte orders as the [`LittleEndian`](@ref) and [`BigEndian`](@ref)
encodings, which together make up [`Endianness`](@ref).

#### [Codec schemes: `BitsLoadable`, `BitsStorable`, `Proxy` and `Manual`](@id bitskinds)
Every pair of a type and an encoding has a [`CodecScheme`](@ref Inscription.CodecScheme), which says where its codec comes from.
It is set by adding a method to [`Inscription.codec_scheme`](@ref Inscription.codec_scheme).

Some types like `UInt32` have a simple encoding: copy the data directly to and from memory, possibly
byte-swapping first to account for endianness.

Instead of needing users to implement a codec for such types, users may declare a type `MyType`
as being `BitsLoadable` via `Inscription.codec_scheme(::Type{MyType}, ::Endianness) = Inscription.BitsLoadable()`,
and then Inscription's functions automatically work for instances of `MyType` with the encodings
`LittleEndian` and `BigEndian`, by copying to and from memory directly.

Other types, like `Bool`, can be written directly to memory, but they cannot be loaded directly from memory,
as some bit patterns are invalid. Users can define such a type as `BitsStorable()`, in which case they
only need to add a method to `Inscription.validate_bits` to validate a given bit pattern for their type.
This method is only needed for decoding.
Then, all the functions in Inscription.jl will work for such types for encodings `LittleEndian` and `BigEndian`.

Many types can be converted to and from another type that already has a codec, often a tuple.
For example, a struct with padding can't be `BitsLoadable`, but it can be converted to a tuple of its parts,
whose elements are encoded one after another without padding.
Such a type can be declared a [`Proxy`](@ref Inscription.Proxy) of the other type, with `Proxy{P}()`, and implement
[`Inscription.try_to_proxy`](@ref Inscription.try_to_proxy) and [`Inscription.try_from_proxy`](@ref Inscription.try_from_proxy).
Then it is encoded exactly as the proxy is. This works with any encoding, and it doesn't make the fields
of a struct part of its encoding, so they can change without changing the encoding.

Finally, some types can't be read or written directly. For example, it makes little sense to store `Char`
as `LittleEndian` or `BigEndian` - this should probably be encoded via an encoding like [`UTF8`](@ref) or `UTF32`.
Other types may have custom, arbitrary serialization rules. For such types, the `codec_scheme` must stay
the default value of `Manual()`, and users must implement a codec.

#### Errors and payloads
Decoding fails with a [`DecodeError`](@ref), and encoding with an [`EncodeError`](@ref).
Their `kind` says what went wrong, e.g. that the input ended, or that the data is invalid.
When the data is invalid, or a value can't be encoded, the codec may say why with a
*payload*, such as an enum value `Overflow` from a codec that parses integers.
Inside a codec, a failure is an [`Invalid`](@ref Inscription.Invalid) value, which holds the payload.

The type of the payloads of a type and encoding is declared, and defaults to `Nothing`.
Values made of other values, such as tuples, structs and proxies, pass on the payloads of
their parts, so their payload type is the union of their parts' payload types.
Since the type is known in advance, an error has the same concrete type whatever went wrong,
so errors are as fast to return as values.
See [`Inscription.decode_invalid_type`](@ref).

#### Encode, decode, load, store
Inscription.jl uses [`encode!`](@ref) to store a value into a byte array, and [`decode`](@ref) to load it from a byte array.
The term `load` means loading from a `BufferIO.AbstractBufReader`, advancing the IO, and likewise `store` means writing to a `BufferIO.AbstractBufWriter`, advancing it.
See the [Usage](usage.md) page for how these functions are used.
