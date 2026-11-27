# Examples
### Reading and writing simple binary values
This works similarly to Base's `read` and `write` (for readers), and
`unsafe_load`, `unsafe_store!` (for memory), although these functions
are not unsafe.

```jldoctest
using BufferIO: CursorReader, VecWriter
using Inscription.Little # little endian encodings/decodings

mem = collect(b"abcdefgh")
rdr = CursorReader(mem)
wtr = VecWriter()

# Load a u32 from index 1 of mem
# Can also use `decode_exact`, `decode_next`, or try_* versions
# of each of these three - they have slightly different semantics.
u32 = decode(mem, 1, UInt32)

# Store that u32 back at index 5 of the same mem
# Can also use `try_encode!` (again, slightly different semantics)
encode!(mem, 5, u32)

@assert mem == b"abcdabcd"

# Load a u32 from the reader
# Can also use `load_exact`, `try_load` and `try_load_exact`
u32 = load(rdr, UInt32)
@assert read(rdr) == b"abcd" # the rest, which `encode!` wrote above

# Store that into the writer
# Can also use `try_store`
store(wtr, u32)

String(wtr.vec)

# output

"abcd"
```

### Reading simple binary values in bulk
This may be more efficient than the scalar operations above done in a loop.

```jldoctest
using BufferIO: CursorReader, VecWriter
using Inscription.Little # little endian encodings/decodings

u8s = rand(UInt8, 128)
f32s = rand(Float32, 32)
wtr = VecWriter()
rdr = CursorReader(u8s)

# Fill `f32s` with `Float32`s decoded from the bytes of `data`.
# Can also use `decode_all!`
data = UInt8[i for i in 1:128]
decode_every!(f32s, data)
@assert f32s == ltoh.(reinterpret(Float32, data))

# Encode all the f32s into the u8s byte array
# Can also use `encode_all!`
encode_every!(u8s, f32s)
@assert u8s == reinterpret(UInt8, htol.(f32s))

# Fill f32s with data loaded from the reader
# Could also use `load_into!` or `load_all!`
load_every!(rdr, f32s)

# Write data of f32s as byte encodings into writer
# Could also use `store_into` or `store_all`
store_every(wtr, f32s)

# output

128
```

### Reading a composite type
In this example, I read the top of a BGZF block header from an `AbstractBufReader`. This header consists of 8 integers of varying bit-widths, totaling 12 bytes in length.
The example shows how I get a buffer of the required size once,
then decode from the buffer with `@inbounds`, for maximal efficiency.

```jldoctest
using BufferIO: AbstractBufReader, get_nonempty_buffer, consume, CursorReader
using Inscription.Little # little endian encodings/decodings
using MemoryViews: ImmutableMemoryView

struct Header
    ID   ::NTuple{2, UInt8}
    CM   ::UInt8
    FLG  ::UInt8
    MTIME::UInt32
    XFL  ::UInt8
    OS   ::UInt8
    XLEN ::UInt16
end

# For example's sake, I don't do validation of individual fields here.
# If they truly didn't need validation, the above struct would be
# `BitsLoadable` (see below), and the implementation could be completely
# automatically derived.
function try_load_bgzip_header(io::AbstractBufReader)::Union{Header, Nothing}
    # `get_nonempty_buffer` promises 12 bytes, or to return `nothing`. But, since
    # `io` is generic, a user subtype may implement it incorrectly. So, I code
    # defensively: Typeassert, and check the length afterwards.
    # For a known AbstractBufReader type, these checks can be elided.
    buffer = get_nonempty_buffer(io, 12)::Union{Nothing, ImmutableMemoryView{UInt8}}
    buffer === nothing && return nothing # EOF before 12 bytes
    checkbounds(buffer, 12)
    # Call `decode` in an inbounds context, since we know we have 12 bytes now.
    header = @inbounds begin
        Header(
            decode(buffer, 1, NTuple{2, UInt8}),
            buffer[3], buffer[4],
            decode(buffer, 5, UInt32),
            buffer[9], buffer[10],
            decode(buffer, 11, UInt16),
        )
    end
    consume(io, 12)
    return header
end

rdr = CursorReader(collect(0x00:0xff))
header = try_load_bgzip_header(rdr)

# output

Header((0x00, 0x01), 0x02, 0x03, 0x07060504, 0x08, 0x09, 0x0b0a)
```

## Reading and writing custom types
Inscription.jl requires you to opt in to reading or writing a struct.
In the following examples, I'll demonstrate how to do so. I'll begin with structs that are easy to read/write, and each example will choose a type that has more complications when reading/writing than the previous one.


### Custom struct 1: Entirely transparent (`BitsLoadable`)
This type has no padding, all bit patterns are valid, and its encoding is the same as its constituent bytes.
So, it can be read and written via pointer operations.
We can make Inscription use those by opting into the `BitsLoadable` trait.
This will automatically make all reading and writing methods work.

```jldoctest
using Inscription.Little
using BufferIO: CursorReader

struct Point2D
    x::Float64
    y::Float64
end

# Just opt into this trait
function Inscription.codec_scheme(::Type{Point2D}, ::Inscription.Endianness)
    Inscription.BitsLoadable()
end

# Now all writer and reader functions work for big endian and little endian
# encodings
rdr = CursorReader(zeros(UInt8, 50))
point = load(rdr, Point2D)

# output

Point2D(0.0, 0.0)
```

### Custom struct 2: Transparent, but need validation (`BitsStorable`)
This type has no padding, and its encoding is the same as its constituent bytes.
However, not all bit patterns are valid.
That means it can be read and written via pointer ops, but read instances must be validated.
We can do that by opting into the `BitsStorable` trait, and implementing the validation function `validate_bits`, which returns `nothing` for valid bytes, and `Invalid()` otherwise:

```jldoctest
using Inscription.Little
using BufferIO: CursorReader

struct EvenInteger
    x::Int64

    EvenInteger(x::Int64) = isodd(x) ? throw(ArgumentError("nope!")) : new(x)
end

function Inscription.codec_scheme(::Type{EvenInteger}, ::Inscription.Endianness)
    Inscription.BitsStorable()
end

function Inscription.validate_bits(::Type{EvenInteger}, bytes::NTuple{8, UInt8})
    # Validate the bytes are those of an even integer. Here, I choose to use
    # the helper function as_unsigned
    u64 = Inscription.as_unsigned(bytes)
    iseven(u64) ? nothing : Inscription.Invalid()
end

# Now all writer and reader functions work for big endian and little endian
# encodings
rdr = CursorReader(b"44444444444444444")
even = load(rdr, EvenInteger)

# output

EvenInteger(3761688987579986996)
```

### Custom struct 3: Forward to an existing encoding (`Proxy`)
This type has padding and so cannot be pointer-loadable. However, we can declare it can be read and written like an equivalent `Tuple` (which is special-cased by Inscription.jl to ignore padding).
We implement the `Proxy` codec scheme and convert to/from that tuple.

An odd-sized primitive, such as a 17-bit integer, could use the same mechanism:
Load a 32-bit integer, and check the unused 15 bits are zeroed out in `try_from_proxy`.

```jldoctest
using Inscription.Little
using BufferIO: CursorReader

struct Padded
    a::UInt64
    b::UInt8
    # N.B: 7 bytes of padding
end

function Inscription.codec_scheme(::Type{Padded}, ::Inscription.Endianness)
    Inscription.Proxy{Tuple{UInt64, UInt8}}()
end

Inscription.try_to_proxy(x::Padded, ::Inscription.Endianness) = (x.a, x.b)

function Inscription.try_from_proxy(
        ::Type{Padded},
        x::Tuple{UInt64, UInt8},
        ::Inscription.Endianness
    )
    Padded(x[1], x[2])
end

# Now all writer and reader functions work for big endian and little endian
# encodings
rdr = CursorReader(b"123456789")
padded = load(rdr, Padded)

# output

Padded(0x3837363534333231, 0x39)
```

### Custom struct 4: Manual codec, fixed length
Here, I implement an encoding of `UInt32` that prints it as lowercase hexadecimal digits, left-padded with zeros to 8 characters.
Note that while `UInt32` in little/big endian encoding **is** pointer-readable/writable, its hexadecimal encoding obviously isn't, so this can be neither `BitsLoadable` nor `BitsStorable`. Also, there is no equivalent encoding, so it can't be a `Proxy`.

Note that this example needs to define a new `Encoding`, and can't simply be `LittleEndian`, as that means storing `UInt32` as binary data.

```jldoctest
using Inscription: Inscription, Encoding, decode, encode!, @?

struct LowerCaseHexadecimal <: Encoding end

function try_hex_digit(byte::UInt8)
    if in(byte, 0x30:0x39)
        return byte - 0x30
    elseif in(byte, 0x61:0x66)
        return byte - 0x57
    else
        return nothing
    end
end

function to_hex_digit(u::UInt32)
    (u < 0x0a ? u + 0x30 : u + 0x57) % UInt8
end

# `codec_scheme(UInt32, ::LowerCaseHexadecimal)` defaults to `Manual`,
# and needs three methods to make reading and writing work; implemented below

function Inscription.codec_max_encoded_size(::Type{UInt32}, ::LowerCaseHexadecimal)
    Val{8}() # Always 8 bytes, hence that's its max
end

function Inscription.codec_try_decode(
        # This type wraps the input memory, or the input reader
        input::Inscription.DecodeInput,
        ::Type{UInt32},
        ::LowerCaseHexadecimal
    )
    # Request exactly 8 bytes with `require_bytes`.
    # If the input ends before that, it returns `TooShort()`.
    # The `@? x` macro expands to `return x` if x is an error value like
    # `TooShort` or `Invalid`.
    # So, the line below means: Get me 8 bytes, or return `TooShort()` from
    # this function if not available. The latter signals that we need more
    # bytes to decode a UInt32 in hexadecimal
    bytes = @? Inscription.require_bytes(input, 8)
    # 8 hexadecimal digits are 32 bits, so this can't overflow
    result = UInt32(0)
    # `@inbounds` is safe here because `require_bytes` guarantees exactly
    # 8 bytes.
    @inbounds for i in 1:8
        byte = bytes[i]
        digit = @something try_hex_digit(byte) return Inscription.Invalid()
        result = (result << 4) | digit
    end
    # Return (value, n bytes read)
    return (result, 8)
end

function Inscription.codec_try_encode!(
        output::Inscription.EncodeOutput,
        x::UInt32,
        ::LowerCaseHexadecimal
    )
    # `reserve_bytes` is the same as `require_bytes` above, but for `EncodeOutput`
    bytes = @? Inscription.reserve_bytes(output, 8)
    @inbounds for i in 8:-1:1
        (x, r) = divrem(x, UInt32(16))
        bytes[i] = to_hex_digit(r)
    end
    return 8 # return n bytes written
end

mem = zeros(UInt8, 8)
encode!(mem, 0x0123abcf, LowerCaseHexadecimal())
(String(copy(mem)), decode(mem, UInt32, LowerCaseHexadecimal()))

# output

("0123abcf", 0x0123abcf)
```

### Custom struct 5: Manual codec, variable length, with error payloads
Here, I write `UInt32` in *decimal* and *without* left padding with zeros.
This adds two more complications compared to the example above:
* When decoding, the length can be arbitrarily long, since there can be any number of leading zeros
* Even when encoding, the output length is variable.

Decoding can fail for two reasons: the number may not fit in a `UInt32`, or there may be no digits.
The codec tells them apart with the payload of the `Invalid` it returns, so that a caller
can e.g. try again with a wider integer type. The type of the payloads is declared with
`codec_decode_invalid_type`, and the payload of the `DecodeError` is `Some(Overflow)` or `Some(NoDigits)`.

```jldoctest
using Inscription: Inscription, Encoding, DecodeError, load, store, try_load, @?
using BufferIO: CursorReader, VecWriter

struct ASCIIDecimal <: Encoding end

@enum ParseError::UInt8 NoDigits Overflow

Inscription.codec_decode_invalid_type(::Type{UInt32}, ::ASCIIDecimal) = ParseError

function Inscription.codec_max_encoded_size(::Type{UInt32}, ::ASCIIDecimal)
    # If the encoding had disallowed leading zeros, this could have been
    # Val{10}(), the maximal length of UInt32 in decimal.
    Inscription.Unbounded()
end

function Inscription.codec_try_decode(
        input::Inscription.DecodeInput,
        ::Type{UInt32},
        ::ASCIIDecimal
    )
    value = UInt64(0)
    n_bytes_read = 0
    while true
        # `peek_byte` loads a byte, or returns `nothing` if the input ends
        # before it. When loading from a reader, it buffers more bytes if
        # needed. It can also return `TooShort()`, which the `@?` macro
        # returns early, if the bytes are only the start of the input.
        byte = @? Inscription.peek_byte(input, n_bytes_read + 1)
        # Stop at the end of the input, or the first byte that isn't a digit
        (byte !== nothing && in(byte, 0x30:0x39)) || break
        value = value * 10 + (byte - 0x30)
        value > typemax(UInt32) && return Inscription.Invalid(Overflow)
        n_bytes_read += 1
    end
    iszero(n_bytes_read) && return Inscription.Invalid(NoDigits)
    return (value % UInt32, n_bytes_read)
end

# This is easier, since we always encode without leading zeros
function Inscription.codec_try_encode!(
        output::Inscription.EncodeOutput,
        x::UInt32,
        ::ASCIIDecimal
    )
    nd = ndigits(x)
    mem = @? Inscription.reserve_bytes(output, nd)
    for i in nd:-1:1
        (x, r) = divrem(x, UInt32(10))
        @inbounds mem[i] = (r + 0x30) % UInt8
    end
    return nd
end

wtr = VecWriter()
store(wtr, UInt32(123), ASCIIDecimal())
rdr = CursorReader("00456 ")
err = try_load(CursorReader("4294967296"), UInt32, ASCIIDecimal())
(String(wtr.vec), load(rdr, UInt32, ASCIIDecimal()), err.payload)

# output

("123", 0x000001c8, Some(Overflow))
```

