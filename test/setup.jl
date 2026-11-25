const BITS_TYPES = (
    Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Float16, Float32, Float64,
)

bytes_le(x) = collect(reinterpret(UInt8, [htol(x)]))
bytes_be(x) = collect(reinterpret(UInt8, [hton(x)]))

is_err(x, kind) = x isa DecodeError && x.kind === kind

# Scratch memory to encode into, long enough for any value in these tests
const SCRATCH = MemoryView(zeros(UInt8, 64))

# Decode a T from the start of `mem`, and return it with the number of bytes used, or the
# error. Also check that `try_decode` and `try_decode_next` agree.
function try_decode_n(mem, ::Type{T}, e) where {T}
    r = try_decode_next(mem, 1, T, e)
    x = r isa DecodeError ? r : r[1]
    @test isequal(try_decode(mem, T, e), x)
    return r isa DecodeError ? r : (r[1], r[2] - 1)
end

@enum Fruit::UInt16 apple = 1 banana = 0x0203 cherry = 0xffff
@enum Small::UInt8 tiny = 3 wee = 200
# Contiguous enums are checked with a range check
@enum Signs::Int16 negative = -1 positive = 1 neutral = 0
@eval @enum Full8::Int8 $([:($(Symbol(:full, i + 128)) = $i) for i in -128:127]...)

# Primitive types of odd sizes. Since Julia 1.14, their size in memory is rounded up to a
# power of two bytes, but they are encoded in the bytes their bits need.
primitive type U24 24 end
BitScribbling.codec_scheme(::Type{U24}, ::Endianness) = BitsLoadable()
primitive type U144 144 end
BitScribbling.codec_scheme(::Type{U144}, ::Endianness) = BitsLoadable()
# The top bit must be zero
primitive type S24 24 end
BitScribbling.codec_scheme(::Type{S24}, ::Endianness) = BitsStorable()
BitScribbling.is_valid_bits(::Type{S24}, bytes::NTuple{3, UInt8}) = as_unsigned(bytes) < 0x00800000
# Wider than the largest unsigned integer. The top bit must be zero.
primitive type S144 144 end
BitScribbling.codec_scheme(::Type{S144}, ::Endianness) = BitsStorable()
function BitScribbling.is_valid_bits(::Type{S144}, bytes::NTuple{18, UInt8})
    top = NATIVE_ENDIAN === LittleEndian() ? bytes[18] : bytes[1]
    return top < 0x80
end
# BitsStorable, but doesn't implement `is_valid_bits`
primitive type NoCheck16 16 end
BitScribbling.codec_scheme(::Type{NoCheck16}, ::Endianness) = BitsStorable()

# The trait can't be declared for types that are neither primitive types nor isbits structs
struct Boxed
    x::Vector{UInt8}
end
BitScribbling.codec_scheme(::Type{Boxed}, ::Endianness) = BitsLoadable()

# The low 128 bits of a primitive value, as an integer
function low_bits(x::T) where {T}
    n = 8 * sizeof(T)
    isdefined(Base, :bitsizeof) && (n = Base.bitsizeof(T))
    return if n == 128
        Core.Intrinsics.bitcast(UInt128, x)
    elseif n < 128
        Core.Intrinsics.zext_int(UInt128, x)
    else
        Core.Intrinsics.trunc_int(UInt128, x)
    end
end

# Julia accepts bit widths that are not a multiple of 8 since 1.14.
const HAS_NARROW = VERSION ≥ v"1.14.0-"
if HAS_NARROW
    @eval begin
        # Bit widths that are not a multiple of 8 can't be encoded as their bits with a
        # byte order, since that would need padding bits
        primitive type U22 22 end
        BitScribbling.codec_scheme(::Type{U22}, ::Endianness) = BitsLoadable()
        primitive type U5 5 end
        BitScribbling.codec_scheme(::Type{U5}, ::Endianness) = BitsLoadable()
        primitive type U30 30 end
        BitScribbling.codec_scheme(::Type{U30}, ::Endianness) = BitsLoadable()
        primitive type S12 12 end
        BitScribbling.codec_scheme(::Type{S12}, ::Endianness) = BitsStorable()
        BitScribbling.is_valid_bits(::Type{S12}, bytes::NTuple{2, UInt8}) = true

        # The design's example of a hand-written codec for a narrow type
        primitive type U29 29 end
        U29(x::UInt32) = Core.Intrinsics.trunc_int(U29, x)
        Base.UInt32(x::U29) = Core.Intrinsics.zext_int(UInt32, x)
    end
    # Codecs are defined for concrete encoding types only, so one per byte order
    for E in (LittleEndian, BigEndian)
        @eval begin
            BitScribbling.codec_max_encoded_size(::Type{U29}, ::$E) = Val(4)
            function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{U29}, e::$E)
                (raw, n, _) = @? decode_field(input, UInt32, e)
                raw > 0x1fffffff && return Invalid()
                return (U29(raw), n)
            end
            function BitScribbling.codec_try_encode!(output::EncodeOutput, x::U29, e::$E)
                (n, _) = @? encode_field(output, UInt32(x), e)
                return n
            end
        end
    end
end

# A custom encoding defined by a format package
struct CBool <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{Bool}, ::CBool) = Val(1)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Bool}, ::CBool)
    b = @? require_bytes(input, 1)
    return (!iszero(b[1]), 1)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, x::Bool, ::CBool)
    mem = @? reserve_bytes(output, 1)
    mem[1] = x
    return 1
end

# A codec that reports whether its own `@boundscheck` blocks ran. `@inbounds` at the call
# of `try_decode` or `encode!` must not reach into the codec.
struct Probe <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{Bool}, ::Probe) = Val(1)
@inline function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Bool}, ::Probe)
    @? require_bytes(input, 1)
    checked = false
    @boundscheck checked = true
    return (checked, 1)
end
@inline function BitScribbling.codec_try_encode!(output::EncodeOutput, ::Bool, ::Probe)
    mem = @? reserve_bytes(output, 1)
    checked = false
    @boundscheck checked = true
    mem[1] = checked
    return 1
end

# An impure codec, which fails every other call. Bulk functions that throw must retry the
# element that failed, and use it if the retry succeeds.
struct Flaky <: Encoding end
const FLAKY_CALLS = Ref(0)
flaky_fails() = isodd(FLAKY_CALLS[] += 1)
BitScribbling.codec_max_encoded_size(::Type{Int8}, ::Flaky) = Val(1)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Int8}, ::Flaky)
    b = @? require_bytes(input, 1)
    flaky_fails() && return Invalid()
    return (b[1] % Int8, 1)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, x::Int8, ::Flaky)
    mem = @? reserve_bytes(output, 1)
    flaky_fails() && return Invalid()
    mem[1] = x % UInt8
    return 1
end

# A codec that breaks its contract, by returning byte counts out of range
struct Liar <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{<:Union{Int8, Int16, Int64, UInt8, UInt16}}, ::Liar) = Val(2)
# More bytes than the input has, which ends after `max_encoded_size` bytes
BitScribbling.codec_try_decode(::DecodeInput, ::Type{Int8}, ::Liar) = (Int8(0), 3)
BitScribbling.codec_try_encode!(output::EncodeOutput, ::Int8, ::Liar) = length(output.mem) + 1
# A negative count
BitScribbling.codec_try_decode(::DecodeInput, ::Type{Int16}, ::Liar) = (Int16(0), -1)
BitScribbling.codec_try_encode!(::EncodeOutput, ::Int16, ::Liar) = -1
# Zero, which would make loops until the end of the data never end
BitScribbling.codec_try_decode(::DecodeInput, ::Type{Int64}, ::Liar) = (Int64(0), 0)
BitScribbling.codec_try_encode!(::EncodeOutput, ::Int64, ::Liar) = 0
# More bytes than `max_encoded_size`. The input and output end after `max_encoded_size`
# bytes, so this is caught.
BitScribbling.codec_try_decode(::DecodeInput, ::Type{UInt8}, ::Liar) = (0x00, 3)
BitScribbling.codec_try_encode!(::EncodeOutput, ::UInt8, ::Liar) = 3
# More bytes than the input or output has, on the slow path, where it is shorter than
# `max_encoded_size`
BitScribbling.codec_try_decode(input::DecodeInput, ::Type{UInt16}, ::Liar) = (0x0000, length(input.mem) + 1)
BitScribbling.codec_try_encode!(output::EncodeOutput, ::UInt16, ::Liar) = length(output.mem) + 1
BitScribbling.codec_max_encoded_size(::Type{Int32}, ::Liar) = 4

# Decimal digits of a `UInt8`, without a terminator. The value is decided by the byte
# after its last digit, or by 3 digits.
struct Decimal <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{UInt8}, ::Decimal) = Val(3)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Decimal)
    @? require_bytes(input, 1)
    value = 0
    n = 0
    while n < 3
        byte = @? peek_byte(input, n + 1)
        (byte === nothing || !(UInt8('0') ≤ byte ≤ UInt8('9'))) && break
        value = 10 * value + (byte - UInt8('0'))
        n += 1
    end
    (n == 0 || value > 255) && return Invalid()
    return (UInt8(value), n)
end

# A length byte, followed by that many bytes, each 0x01. Decodes to the length. Counts its
# calls, to check that a reader buffers the bytes it asks for at once.
struct Prefixed <: Encoding end
const PREFIXED_CALLS = Ref(0)
BitScribbling.codec_max_encoded_size(::Type{UInt64}, ::Prefixed) = Val(256)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{UInt64}, ::Prefixed)
    PREFIXED_CALLS[] += 1
    k = Int((@? require_bytes(input, 1))[1])
    bytes = @? require_bytes(input, 1 + k)
    all(==(0x01), bytes[2:end]) || return Invalid()
    return (UInt64(k), 1 + k)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, x::UInt64, ::Prefixed)
    x ≤ 255 || return Invalid()
    mem = @? reserve_bytes(output, 1 + Int(x))
    mem[1] = x % UInt8
    fill!(mem[2:end], 0x01)
    return 1 + Int(x)
end

# Asks for more bytes than its `max_encoded_size`, which it never gets
struct Greedy <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{UInt8}, ::Greedy) = Val(2)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{UInt8}, ::Greedy)
    b = @? require_bytes(input, 3)
    return (b[3], 3)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, ::UInt8, ::Greedy)
    @? reserve_bytes(output, 3)
    return Invalid()
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, x::UInt8, ::Decimal)
    s = string(x)
    mem = @? reserve_bytes(output, ncodeunits(s))
    copyto!(mem, codeunits(s))
    return ncodeunits(s)
end

# An 8-bit character set, which can't encode most `Char`s
struct Latin1 <: Encoding end
is_latin1(c::Char) = isvalid(c) && codepoint(c) ≤ 0xff
BitScribbling.codec_max_encoded_size(::Type{Char}, ::Latin1) = Val(1)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Char}, ::Latin1)
    b = @? require_bytes(input, 1)
    return (Char(b[1]), 1)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, c::Char, ::Latin1)
    is_latin1(c) || return Invalid()
    mem = @? reserve_bytes(output, 1)
    mem[1] = codepoint(c) % UInt8
    return 1
end
# Pairs of characters, encoded one by one, so an invalid second character is only found
# after the first is written
BitScribbling.codec_max_encoded_size(::Type{Tuple{Char, Char}}, ::Latin1) = Val(2)
function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Tuple{Char, Char}}, e::Latin1)
    (a, n, input) = @? decode_field(input, Char, e)
    (b, m, _) = @? decode_field(input, Char, e)
    return ((a, b), n + m)
end
function BitScribbling.codec_try_encode!(output::EncodeOutput, x::Tuple{Char, Char}, e::Latin1)
    (a, output) = @? encode_field(output, x[1], e)
    (b, _) = @? encode_field(output, x[2], e)
    return a + b
end

# Structs that opt in
struct Header
    magic::UInt32
    version::UInt16
    flags::UInt8
    kind::UInt8
end
BitScribbling.codec_scheme(::Type{Header}, ::Endianness) = BitsLoadable()
struct Nested
    header::Header
    x::Float32
    y::Int16
    z::Int16
end
BitScribbling.codec_scheme(::Type{Nested}, ::Endianness) = BitsLoadable()
# The fields are checked, and then that the fruit is `apple` unless `on`
struct Flagged
    on::Bool
    other::UInt8
    fruit::Fruit
end
BitScribbling.codec_scheme(::Type{Flagged}, ::Endianness) = BitsStorable()
function BitScribbling.is_valid_bits(::Type{Flagged}, bytes::NTuple{4, UInt8})
    x = reinterpret(Flagged, bytes)
    return x.on || x.fruit === apple
end
struct Outer
    a::Flagged
    b::Flagged
end
BitScribbling.codec_scheme(::Type{Outer}, ::Endianness) = BitsStorable()
BitScribbling.is_valid_bits(::Type{Outer}, ::NTuple{8, UInt8}) = true
# Types of size zero are rejected, also as fields
struct Empty end
BitScribbling.codec_scheme(::Type{Empty}, ::Endianness) = BitsLoadable()
struct WithEmpty
    a::UInt32
    e::Empty
end
BitScribbling.codec_scheme(::Type{WithEmpty}, ::Endianness) = BitsLoadable()

# Structs that can't be bits types
struct Padded
    a::UInt8
    b::UInt32
end
BitScribbling.codec_scheme(::Type{Padded}, ::Endianness) = BitsLoadable()
struct LoadableWithBool
    a::Bool
end
BitScribbling.codec_scheme(::Type{LoadableWithBool}, ::Endianness) = BitsLoadable()
struct WithChar
    c::Char
end
BitScribbling.codec_scheme(::Type{WithChar}, ::Endianness) = BitsLoadable()
# Doesn't opt in
struct Plain
    x::UInt32
end
struct WithPlain
    p::Plain
end
BitScribbling.codec_scheme(::Type{WithPlain}, ::Endianness) = BitsLoadable()
struct WithPadded
    p::Padded
end
BitScribbling.codec_scheme(::Type{WithPadded}, ::Endianness) = BitsLoadable()
# Has padding on some platforms only: `b` follows 4 bytes, and is aligned to 8 on x86-64
struct Misaligned
    a::UInt32
    b::UInt64
end
BitScribbling.codec_scheme(::Type{Misaligned}, ::Endianness) = BitsLoadable()
# Its size, 12, is not a multiple of 8
struct TrailingPadding
    a::UInt64
    b::UInt32
end
BitScribbling.codec_scheme(::Type{TrailingPadding}, ::Endianness) = BitsLoadable()
# `h` follows 2 bytes, but contains a `UInt32`
struct MisalignedNested
    a::UInt16
    h::Header
end
BitScribbling.codec_scheme(::Type{MisalignedNested}, ::Endianness) = BitsLoadable()
# No padding on x86-64, where `U256` is aligned to 16 bytes, but a platform could align it
# to 32 bytes, its size
primitive type U256 256 end
BitScribbling.codec_scheme(::Type{U256}, ::Endianness) = BitsLoadable()
struct WithU256
    a::UInt128
    b::U256
end
BitScribbling.codec_scheme(::Type{WithU256}, ::Endianness) = BitsLoadable()
# Widths that are not powers of two are rejected on every Julia version, also where the
# bits of a `U24` fill its 3 bytes
struct WithU24
    x::U24
end
BitScribbling.codec_scheme(::Type{WithU24}, ::Endianness) = BitsLoadable()
# Accepted: ordered from largest to smallest, or with a field for the padding
struct Ordered
    b::UInt64
    a::UInt32
    c::UInt16
    d::UInt8
    e::UInt8
end
BitScribbling.codec_scheme(::Type{Ordered}, ::Endianness) = BitsLoadable()
struct ExplicitPadding
    a::UInt32
    pad::UInt32
    b::UInt64
end
BitScribbling.codec_scheme(::Type{ExplicitPadding}, ::Endianness) = BitsLoadable()
struct WithU256Aligned
    b::U256
    a::UInt128
    c::UInt128
end
BitScribbling.codec_scheme(::Type{WithU256Aligned}, ::Endianness) = BitsLoadable()

# An even byte, with a hand-written codec for the byte orders, which rejects odd bytes
# both ways
struct Even
    x::UInt8
end
for E in (LittleEndian, BigEndian)
    @eval begin
        BitScribbling.codec_max_encoded_size(::Type{Even}, ::$E) = Val(1)
        function BitScribbling.codec_try_decode(input::DecodeInput, ::Type{Even}, ::$E)
            b = @? require_bytes(input, 1)
            return iseven(b[1]) ? (Even(b[1]), 1) : Invalid()
        end
        function BitScribbling.codec_try_encode!(output::EncodeOutput, x::Even, ::$E)
            iseven(x.x) || return Invalid()
            mem = @? reserve_bytes(output, 1)
            mem[1] = x.x
            return 1
        end
    end
end

# A struct with a tuple field
struct WithTuple
    t::NTuple{2, UInt16}
    x::UInt32
end
BitScribbling.codec_scheme(::Type{WithTuple}, ::Endianness) = BitsLoadable()

# Proxied types
# Valid only if `lo ≤ hi`, encoded as a tuple
struct Span
    lo::UInt16
    hi::UInt16
end
BitScribbling.codec_scheme(::Type{Span}, ::Endianness) = Proxy{NTuple{2, UInt16}}()
BitScribbling.try_to_proxy(x::Span, ::Endianness) = (x.lo, x.hi)
function BitScribbling.try_from_proxy(::Type{Span}, (lo, hi)::NTuple{2, UInt16}, ::Endianness)
    return lo ≤ hi ? Span(lo, hi) : Invalid()
end
# Has padding in memory, but not in its encoding
struct Sparse
    a::UInt8
    b::UInt32
end
BitScribbling.codec_scheme(::Type{Sparse}, ::Endianness) = Proxy{Tuple{UInt8, UInt32}}()
BitScribbling.try_to_proxy(x::Sparse, ::Endianness) = (x.a, x.b)
BitScribbling.try_from_proxy(::Type{Sparse}, (a, b)::Tuple{UInt8, UInt32}, ::Endianness) = Sparse(a, b)
# Encodings of varying size, with an encoding other than the byte orders
struct Glyph
    c::Char
end
BitScribbling.codec_scheme(::Type{Glyph}, ::UTF8) = Proxy{Char}()
BitScribbling.try_to_proxy(x::Glyph, ::UTF8) = x.c
BitScribbling.try_from_proxy(::Type{Glyph}, c::Char, ::UTF8) = Glyph(c)
# A proxy of a proxied type
struct Nest
    s::Span
end
BitScribbling.codec_scheme(::Type{Nest}, ::Endianness) = Proxy{Span}()
BitScribbling.try_to_proxy(x::Nest, ::Endianness) = x.s
BitScribbling.try_from_proxy(::Type{Nest}, s::Span, ::Endianness) = Nest(s)
# A proxy for every encoding, which works for the encodings of the proxy
struct Wrapped
    c::Char
end
BitScribbling.codec_scheme(::Type{Wrapped}, ::Encoding) = Proxy{Char}()
BitScribbling.try_to_proxy(x::Wrapped, ::Encoding) = x.c
BitScribbling.try_from_proxy(::Type{Wrapped}, c::Char, ::Encoding) = Wrapped(c)
# Only values that fit in the proxy can be encoded
struct Narrow
    x::Int
end
BitScribbling.codec_scheme(::Type{Narrow}, ::Endianness) = Proxy{UInt16}()
function BitScribbling.try_to_proxy(x::Narrow, ::Endianness)
    return 0 ≤ x.x ≤ typemax(UInt16) ? x.x % UInt16 : Invalid()
end
BitScribbling.try_from_proxy(::Type{Narrow}, x::UInt16, ::Endianness) = Narrow(Int(x))
# A proxy of a type that can't always be encoded
struct NestNarrow
    x::Narrow
end
BitScribbling.codec_scheme(::Type{NestNarrow}, ::Endianness) = Proxy{Narrow}()
BitScribbling.try_to_proxy(x::NestNarrow, ::Endianness) = x.x
BitScribbling.try_from_proxy(::Type{NestNarrow}, x::Narrow, ::Endianness) = NestNarrow(x)

# Proxies that can't be used
# Return `nothing` instead of `Invalid()`
struct NothingProxy
    x::UInt8
end
BitScribbling.codec_scheme(::Type{NothingProxy}, ::Endianness) = Proxy{UInt16}()
BitScribbling.try_to_proxy(::NothingProxy, ::Endianness) = nothing
BitScribbling.try_from_proxy(::Type{NothingProxy}, ::UInt16, ::Endianness) = nothing
struct AbstractProxied end
BitScribbling.codec_scheme(::Type{AbstractProxied}, ::Endianness) = Proxy{Integer}()
struct SelfProxied
    x::UInt8
end
BitScribbling.codec_scheme(::Type{SelfProxied}, ::Endianness) = Proxy{SelfProxied}()
struct NotTypeProxied end
BitScribbling.codec_scheme(::Type{NotTypeProxied}, ::Endianness) = Proxy{1}()
# `try_to_proxy` returns a `UInt8`, not the proxy type
struct WrongProxy
    x::UInt8
end
BitScribbling.codec_scheme(::Type{WrongProxy}, ::Endianness) = Proxy{UInt16}()
BitScribbling.try_to_proxy(x::WrongProxy, ::Endianness) = x.x
BitScribbling.try_from_proxy(::Type{WrongProxy}, x::UInt16, ::Endianness) = WrongProxy(x % UInt8)
# A field with a proxy is not encoded as its bits
struct WithProxied
    s::Span
end
BitScribbling.codec_scheme(::Type{WithProxied}, ::Endianness) = BitsLoadable()
# Bits schemes are only for the byte orders
struct BitsEverywhere
    x::UInt8
end
BitScribbling.codec_scheme(::Type{BitsEverywhere}, ::Encoding) = BitsLoadable()

# Tuples of each kind: bits types, and tuples encoded element by element, because they
# have padding, an element type has a hand-written codec, or is a bits type that can't be
# a field of one
const BITS_TUPLES = (
    NTuple{2, UInt16}, Tuple{Header, UInt64}, Tuple{Tuple{UInt8, UInt8}, UInt16},
    Tuple{Fruit, Bool, Small}, Tuple{Flagged, Int32}, Tuple{UInt8},
)
const ELEMENTWISE_TUPLES = (
    Tuple{UInt8, UInt32}, Tuple{UInt16, UInt8}, Tuple{Bool, UInt32, S24}, Tuple{Even, UInt16},
    Tuple{Tuple{UInt8, UInt32}, Bool}, Tuple{U144, Flagged},
)
if HAS_NARROW
    @eval begin
        struct WithNarrow
            x::U30
        end
        BitScribbling.codec_scheme(::Type{WithNarrow}, ::Endianness) = BitsLoadable()
    end
end

# A reader of chunks that throws when it runs out, instead of returning EOF. It stands in
# for a socket whose peer waits for a reply: filling more would block forever.
mutable struct StallingReader <: AbstractBufReader
    chunks::Vector{Vector{UInt8}}
    buffer::Vector{UInt8}
end
StallingReader(chunks) = StallingReader(collect(Vector{UInt8}, chunks), UInt8[])
BufferIO.get_buffer(x::StallingReader) = ImmutableMemoryView(x.buffer)
function BufferIO.fill_buffer(x::StallingReader)
    isempty(x.chunks) && error("would block")
    chunk = popfirst!(x.chunks)
    append!(x.buffer, chunk)
    return length(chunk)
end
function BufferIO.consume(x::StallingReader, n::Int)
    in(n, 0:length(x.buffer)) || throw(IOError(IOErrorKinds.ConsumeBufferError))
    deleteat!(x.buffer, 1:n)
    return nothing
end
Base.close(::StallingReader) = nothing

# The bytes `x` encodes to
encoding(x, e) = (buf = zeros(UInt8, max_encoded_size(typeof(x), e)); buf[1:encode!(buf, x, e)])

# A type, an encoding and a value of the type, for each kind of codec. The tests of
# properties that every codec has use these. The byte orders share their codecs, so they
# alternate.
const CODEC_CASES = let
    s24 = decode([0x01, 0x02, 0x03], S24, BigEndian())
    u144 = decode(collect(0x01:0x12), U144, BigEndian())
    cases = Any[
        # Primitive types
        (UInt8, LittleEndian(), 0x2a),
        (UInt32, BigEndian(), 0x01020304),
        (Int128, LittleEndian(), Int128(-12345)),
        (Float16, BigEndian(), Float16(1.5)),
        (Bool, LittleEndian(), true),
        (Fruit, BigEndian(), banana),
        (Signs, LittleEndian(), negative),
        (U24, BigEndian(), decode([0x01, 0x02, 0x83], U24, BigEndian())),
        (S24, LittleEndian(), s24),
        (S144, BigEndian(), decode(collect(0x01:0x12), S144, BigEndian())),
        # Structs
        (Header, LittleEndian(), Header(0x01020304, 0x0506, 0x07, 0x08)),
        (Flagged, BigEndian(), Flagged(true, 0x05, cherry)),
        (Outer, LittleEndian(), Outer(Flagged(true, 0x05, cherry), Flagged(false, 0x07, apple))),
        # Hand-written codecs
        (Even, BigEndian(), Even(0x04)),
        (Bool, CBool(), true),
        (Char, UTF8(), '€'),
        (Char, Latin1(), 'é'),
        (Tuple{Char, Char}, Latin1(), ('a', 'é')),
        # Tuples, which are bits types, or encoded element by element
        (Tuple{Fruit, Bool, Small}, LittleEndian(), (banana, true, wee)),
        (Tuple{Bool, UInt32, S24}, BigEndian(), (true, 0x01020304, s24)),
        (Tuple{U144, Flagged}, LittleEndian(), (u144, Flagged(false, 0x07, apple))),
        (Tuple{Even, UInt16}, BigEndian(), (Even(0x04), 0x0102)),
        # Proxies
        (Span, LittleEndian(), Span(0x0102, 0x0304)),
        (Sparse, BigEndian(), Sparse(0x01, 0x02030405)),
        (Glyph, UTF8(), Glyph('€')),
        (Nest, BigEndian(), Nest(Span(0x0102, 0x0304))),
        (Wrapped, Latin1(), Wrapped('é')),
        (Tuple{Span, UInt8}, LittleEndian(), (Span(0x0001, 0x0002), 0x03)),
    ]
    HAS_NARROW && push!(cases, (U29, LittleEndian(), U29(0x01234567)))
    cases
end

# Whether `@inbounds` elides `@boundscheck` blocks. `--check-bounds=yes`, which `Pkg.test`
# uses, keeps them.
const ELIDES_BOUNDSCHECKS = Base.JLOptions().check_bounds != 1
