using Test
using BitScribbling
using BitScribbling: DecodeErrorKinds, EncodeErrorKinds, Little, Big
using BitScribbling: bits_kind, BitsLoadable, BitsStorable, ManualCodec, is_valid_bits, as_unsigned
using BitScribbling.DecodeErrorKinds: EndOfInput, Truncated, InvalidData
using BitScribbling.EncodeErrorKinds: InsufficientSpace, InvalidValue
using BufferIO
using BufferIO.Testing: BoundedReader, BoundedWriter, ChunkedReader
using MemoryViews: MemoryView, ImmutableMemoryView, MutableMemoryView
using LightBoundsErrors: LightBoundsError

const BITS_TYPES = (
    Int8, Int16, Int32, Int64, Int128,
    UInt8, UInt16, UInt32, UInt64, UInt128,
    Float16, Float32, Float64,
)

bytes_le(x) = collect(reinterpret(UInt8, [htol(x)]))
bytes_be(x) = collect(reinterpret(UInt8, [hton(x)]))

is_err(x, kind) = x isa DecodeError && x.kind === kind

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
BitScribbling.bits_kind(::Type{U24}) = BitsLoadable()
primitive type U144 144 end
BitScribbling.bits_kind(::Type{U144}) = BitsLoadable()
# The top bit must be zero
primitive type S24 24 end
BitScribbling.bits_kind(::Type{S24}) = BitsStorable()
BitScribbling.is_valid_bits(::Type{S24}, bytes::NTuple{3, UInt8}) = as_unsigned(bytes) < 0x00800000
# Wider than the largest unsigned integer. The top bit must be zero.
primitive type S144 144 end
BitScribbling.bits_kind(::Type{S144}) = BitsStorable()
function BitScribbling.is_valid_bits(::Type{S144}, bytes::NTuple{18, UInt8})
    top = NATIVE_ENDIAN === LittleEndian() ? bytes[18] : bytes[1]
    return top < 0x80
end
# BitsStorable, but doesn't implement `is_valid_bits`
primitive type NoCheck16 16 end
BitScribbling.bits_kind(::Type{NoCheck16}) = BitsStorable()

# The trait can't be declared for types that are neither primitive types nor isbits structs
struct Boxed
    x::Vector{UInt8}
end
BitScribbling.bits_kind(::Type{Boxed}) = BitsLoadable()

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
        primitive type U22 22 end
        BitScribbling.bits_kind(::Type{U22}) = BitsLoadable()
        primitive type U5 5 end
        BitScribbling.bits_kind(::Type{U5}) = BitsLoadable()
        # Encoded in 4 bytes, so loaded as a UInt32
        primitive type U30 30 end
        BitScribbling.bits_kind(::Type{U30}) = BitsLoadable()
        # Encoded in 4 bytes, so loaded as a UInt32. The top bit must be zero.
        primitive type S30 30 end
        BitScribbling.bits_kind(::Type{S30}) = BitsStorable()
        BitScribbling.is_valid_bits(::Type{S30}, bytes::NTuple{4, UInt8}) = as_unsigned(bytes) < 0x20000000
        # All ones is invalid
        primitive type S12 12 end
        BitScribbling.bits_kind(::Type{S12}) = BitsStorable()
        BitScribbling.is_valid_bits(::Type{S12}, bytes::NTuple{2, UInt8}) = as_unsigned(bytes) != 0x0fff

        # The design's example of a hand-written codec for a narrow type
        primitive type U29 29 end
        U29(x::UInt32) = Core.Intrinsics.trunc_int(U29, x)
        Base.UInt32(x::U29) = Core.Intrinsics.zext_int(UInt32, x)
    end
    # Codecs are defined for concrete encoding types only, so one per byte order
    for E in (LittleEndian, BigEndian)
        @eval begin
            BitScribbling.codec_max_encoded_size(::Type{U29}, ::$E) = 4
            BitScribbling.codec_encoded_size(::U29, ::$E) = 4
            function BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{U29}, e::$E)
                raw = @try_return try_decode(mem, UInt32, e)
                raw > 0x1fffffff && return DecodeError(InvalidData)
                return (U29(raw), 4)
            end
            function BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, x::U29, e::$E)
                return try_encode!(mem, UInt32(x), e)
            end
        end
    end
end

# A custom encoding defined by a format package
struct CBool <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{Bool}, ::CBool) = 1
BitScribbling.codec_encoded_size(::Bool, ::CBool) = 1
function BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Bool}, ::CBool)
    isempty(mem) && return DecodeError(EndOfInput)
    return (!iszero(mem[1]), 1)
end
function BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, x::Bool, ::CBool)
    isempty(mem) && return EncodeError(InsufficientSpace)
    mem[1] = x
    return 1
end

# A codec that reports whether its own `@boundscheck` blocks ran. `@inbounds` at the call
# of `try_decode` or `encode!` must not reach into the codec.
struct Probe <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{Bool}, ::Probe) = 1
BitScribbling.codec_encoded_size(::Bool, ::Probe) = 1
@inline function BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Bool}, ::Probe)
    isempty(mem) && return DecodeError(EndOfInput)
    checked = false
    @boundscheck checked = true
    return (checked, 1)
end
@inline function BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, ::Bool, ::Probe)
    isempty(mem) && return EncodeError(InsufficientSpace)
    checked = false
    @boundscheck checked = true
    @inbounds mem[1] = checked
    return 1
end

# A codec that breaks its contract, by returning byte counts out of range
struct Liar <: Encoding end
BitScribbling.codec_max_encoded_size(::Type{<:Union{Int8, Int16, UInt8}}, ::Liar) = 2
# More bytes than `mem` has
BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Int8}, ::Liar) = (Int8(0), length(mem) + 1)
BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, ::Int8, ::Liar) = length(mem) + 1
# A negative count
BitScribbling.codec_try_decode(::ImmutableMemoryView{UInt8}, ::Type{Int16}, ::Liar) = (Int16(0), -1)
BitScribbling.codec_encode!(::MutableMemoryView{UInt8}, ::Int16, ::Liar) = -1
# More bytes than `max_encoded_size`, but within `mem`: a bug, but no undefined behaviour,
# so it's not caught
BitScribbling.codec_try_decode(::ImmutableMemoryView{UInt8}, ::Type{UInt8}, ::Liar) = (0x00, 3)
BitScribbling.codec_encode!(::MutableMemoryView{UInt8}, ::UInt8, ::Liar) = 3

# An 8-bit character set, which can't encode most `Char`s
struct Latin1 <: Encoding end
is_latin1(c::Char) = isvalid(c) && codepoint(c) ≤ 0xff
BitScribbling.codec_max_encoded_size(::Type{Char}, ::Latin1) = 1
BitScribbling.codec_encoded_size(c::Char, ::Latin1) = is_latin1(c) ? 1 : EncodeError(InvalidValue)
function BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Char}, ::Latin1)
    isempty(mem) && return DecodeError(EndOfInput)
    return (Char(mem[1]), 1)
end
function BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, c::Char, ::Latin1)
    is_latin1(c) || return EncodeError(InvalidValue)
    isempty(mem) && return EncodeError(InsufficientSpace)
    mem[1] = codepoint(c) % UInt8
    return 1
end
# Pairs of characters, encoded one by one, so an invalid second character is only found
# after the first is written
BitScribbling.codec_max_encoded_size(::Type{Tuple{Char, Char}}, ::Latin1) = 2
function BitScribbling.codec_encoded_size(x::Tuple{Char, Char}, e::Latin1)
    a = @try_return try_encoded_size(x[1], e)
    b = @try_return try_encoded_size(x[2], e)
    return a + b
end
function BitScribbling.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Tuple{Char, Char}}, e::Latin1)
    (a, i) = @try_return try_decode_next(mem, 1, Char, e)
    second = try_decode_next(mem, i, Char, e)
    second isa DecodeError && return DecodeError(Truncated)
    (b, next) = second
    return ((a, b), next - 1)
end
function BitScribbling.codec_encode!(mem::MutableMemoryView{UInt8}, x::Tuple{Char, Char}, e::Latin1)
    # Nothing may be written when there is too little space, so check it first
    length(mem) < 2 && return EncodeError(InsufficientSpace)
    a = @try_return try_encode!(mem, x[1], e)
    b = @try_return try_encode!(mem, 1 + a, x[2], e)
    return a + b
end

# Structs that opt in
struct Header
    magic::UInt32
    version::UInt16
    flags::UInt8
    kind::UInt8
end
BitScribbling.bits_kind(::Type{Header}) = BitsLoadable()
struct Nested
    header::Header
    x::Float32
    y::Int16
    z::Int16
end
BitScribbling.bits_kind(::Type{Nested}) = BitsLoadable()
# The fields are checked, and then that the fruit is `apple` unless `on`
struct Flagged
    on::Bool
    other::UInt8
    fruit::Fruit
end
BitScribbling.bits_kind(::Type{Flagged}) = BitsStorable()
function BitScribbling.is_valid_bits(::Type{Flagged}, bytes::NTuple{4, UInt8})
    x = reinterpret(Flagged, bytes)
    return x.on || x.fruit === apple
end
struct Outer
    a::Flagged
    b::Flagged
end
BitScribbling.bits_kind(::Type{Outer}) = BitsStorable()
BitScribbling.is_valid_bits(::Type{Outer}, ::NTuple{8, UInt8}) = true
struct Empty end
BitScribbling.bits_kind(::Type{Empty}) = BitsLoadable()

# Structs that can't be bits types
struct Padded
    a::UInt8
    b::UInt32
end
BitScribbling.bits_kind(::Type{Padded}) = BitsLoadable()
struct LoadableWithBool
    a::Bool
end
BitScribbling.bits_kind(::Type{LoadableWithBool}) = BitsLoadable()
struct WithChar
    c::Char
end
BitScribbling.bits_kind(::Type{WithChar}) = BitsLoadable()
# Doesn't opt in
struct Plain
    x::UInt32
end
struct WithPlain
    p::Plain
end
BitScribbling.bits_kind(::Type{WithPlain}) = BitsLoadable()
struct WithPadded
    p::Padded
end
BitScribbling.bits_kind(::Type{WithPadded}) = BitsLoadable()
# Has padding on some platforms only: `b` follows 4 bytes, and is aligned to 8 on x86-64
struct Misaligned
    a::UInt32
    b::UInt64
end
BitScribbling.bits_kind(::Type{Misaligned}) = BitsLoadable()
# Its size, 12, is not a multiple of 8
struct TrailingPadding
    a::UInt64
    b::UInt32
end
BitScribbling.bits_kind(::Type{TrailingPadding}) = BitsLoadable()
# `h` follows 2 bytes, but contains a `UInt32`
struct MisalignedNested
    a::UInt16
    h::Header
end
BitScribbling.bits_kind(::Type{MisalignedNested}) = BitsLoadable()
# No padding on x86-64, where `U256` is aligned to 16 bytes, but a platform could align it
# to 32 bytes, its size
primitive type U256 256 end
BitScribbling.bits_kind(::Type{U256}) = BitsLoadable()
struct WithU256
    a::UInt128
    b::U256
end
BitScribbling.bits_kind(::Type{WithU256}) = BitsLoadable()
# Widths that are not powers of two are rejected on every Julia version, also where the
# bits of a `U24` fill its 3 bytes
struct WithU24
    x::U24
end
BitScribbling.bits_kind(::Type{WithU24}) = BitsLoadable()
# Accepted: ordered from largest to smallest, or with a field for the padding
struct Ordered
    b::UInt64
    a::UInt32
    c::UInt16
    d::UInt8
    e::UInt8
end
BitScribbling.bits_kind(::Type{Ordered}) = BitsLoadable()
struct ExplicitPadding
    a::UInt32
    pad::UInt32
    b::UInt64
end
BitScribbling.bits_kind(::Type{ExplicitPadding}) = BitsLoadable()
struct WithU256Aligned
    b::U256
    a::UInt128
    c::UInt128
end
BitScribbling.bits_kind(::Type{WithU256Aligned}) = BitsLoadable()
if HAS_NARROW
    @eval begin
        struct WithNarrow
            x::U30
        end
        BitScribbling.bits_kind(::Type{WithNarrow}) = BitsLoadable()
    end
end

# Pairs of a type and an encoding, covering every kind of codec
const CODEC_CASES = let
    types = (BITS_TYPES..., Bool, Fruit, Small, Signs, U24, S24, U144, S144, Header, Nested, Flagged, Outer, Empty)
    cases = Any[(T, e) for T in types for e in (LittleEndian(), BigEndian())]
    push!(cases, (Char, UTF8()), (Bool, CBool()), (Char, Latin1()), (Tuple{Char, Char}, Latin1()))
    if HAS_NARROW
        for T in (U22, U5, U30, S30, S12, U29), e in (LittleEndian(), BigEndian())
            push!(cases, (T, e))
        end
    end
    cases
end

# Whether `@inbounds` elides `@boundscheck` blocks. `--check-bounds=yes`, which `Pkg.test`
# uses, keeps them.
const ELIDES_BOUNDSCHECKS = Base.JLOptions().check_bounds != 1

@testset "BitScribbling" begin

    @testset "Encodings" begin
        @test NATIVE_ENDIAN === (ENDIAN_BOM == 0x04030201 ? LittleEndian() : BigEndian())
        @test LittleEndian() isa Endianness
        @test BigEndian() isa Endianness
        @test !(UTF8() isa Endianness)
        # No silently ignored arguments
        @test_throws MethodError store(VecWriter(), 'a', LittleEndian())
        @test_throws MethodError try_decode(MemoryView([0x61]), Char, BigEndian())
        @test_throws MethodError store(VecWriter(), 0x01, UTF8())
        @test_throws MethodError try_load(CursorReader([0x01]), UInt8, UTF8())
        @test_throws MethodError store(VecWriter(), Ptr{UInt8}(0), LittleEndian())
        @test_throws MethodError store(VecWriter(), (1, 2), LittleEndian())
    end

    @testset "Bits kinds" begin
        for T in BITS_TYPES
            @test bits_kind(T) === BitsLoadable()
        end
        @test bits_kind(Bool) === BitsStorable()
        @test bits_kind(Fruit) === BitsStorable()
        for T in (Char, Ptr{UInt8}, String, Tuple{Int, Int})
            @test bits_kind(T) === ManualCodec()
        end
        native(x) = reinterpret(NTuple{sizeof(x), UInt8}, x)
        @test is_valid_bits(Bool, (0x00,)) && is_valid_bits(Bool, (0x01,))
        @test !is_valid_bits(Bool, (0x02,))
        @test is_valid_bits(Fruit, native(0x0203)) && !is_valid_bits(Fruit, native(0x0204))
        @test is_valid_bits(Signs, native(0xffff)) && !is_valid_bits(Signs, native(0xfffe))
        # The trait can't be declared for types that are not bits types
        @test_throws ArgumentError max_encoded_size(Boxed, LittleEndian())
        @test_throws ArgumentError try_decode(MemoryView(zeros(UInt8, 8)), Boxed, LittleEndian())
        @test_throws ArgumentError store(VecWriter(), Boxed(UInt8[]), LittleEndian())
        # Only the Endianness encodings use the trait
        @test_throws MethodError max_encoded_size(UInt32, UTF8())
        @test_throws MethodError max_encoded_size(Boxed, UTF8())
    end

    @testset "as_unsigned" begin
        little = NATIVE_ENDIAN === LittleEndian()
        # The bytes are in native order
        for n in 1:16
            bytes = ntuple(UInt8, n)
            x = as_unsigned(bytes)
            @test sizeof(x) == (n ≤ 1 ? 1 : n ≤ 2 ? 2 : n ≤ 4 ? 4 : n ≤ 8 ? 8 : 16)
            least_first = little ? bytes : reverse(bytes)
            @test x == sum(UInt128(least_first[i]) << (8 * (i - 1)) for i in 1:n)
            if n == sizeof(x)
                @test x === reinterpret(typeof(x), bytes)
            end
        end
        @test as_unsigned(()) === 0x00
        @test as_unsigned(little ? (0xef, 0xcd, 0xab) : (0xab, 0xcd, 0xef)) === 0x00abcdef
        @test_throws ArgumentError as_unsigned(ntuple(UInt8, 17))
    end

    @testset "Bits types in memory" begin
        for T in BITS_TYPES, x in (zero(T), one(T), typemax(T), typemin(T), T(17))
            for (e, f) in ((LittleEndian(), bytes_le), (BigEndian(), bytes_be))
                bytes = f(x)
                @test max_encoded_size(T, e) == sizeof(T)
                @test try_encoded_size(x, e) === encoded_size(x, e) === sizeof(T)
                buf = zeros(UInt8, sizeof(T) + 3)
                @test encode!(MemoryView(buf), x, e) == sizeof(T)
                @test buf[1:sizeof(T)] == bytes
                @test isequal(try_decode_n(MemoryView(buf), T, e), (x, sizeof(T)))
                @test isequal(decode(MemoryView(buf), T, e), x)
                @test isequal(decode_next(MemoryView(buf), 1, T, e), (x, sizeof(T) + 1))
                # Unaligned
                @test encode!(MemoryView(buf)[2:end], x, e) == sizeof(T)
                @test buf[2:(sizeof(T) + 1)] == bytes
                @test isequal(try_decode_n(MemoryView(buf)[2:end], T, e), (x, sizeof(T)))
                # Too short
                @test try_encode!(MemoryView(zeros(UInt8, sizeof(T) - 1)), x, e) === EncodeError(InsufficientSpace)
                @test_throws LightBoundsError encode!(MemoryView(zeros(UInt8, sizeof(T) - 1)), x, e)
                @test is_err(try_decode(MemoryView(UInt8[]), T, e), EndOfInput)
                if sizeof(T) > 1
                    @test is_err(try_decode(MemoryView(bytes[1:(end - 1)]), T, e), Truncated)
                end
            end
        end
        @test decode(MemoryView([0x01, 0x02, 0x03]), UInt16, LittleEndian()) === 0x0201
        @test decode(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian()) === 0x0102
        @test decode(MemoryView([0xff]), Int8, BigEndian()) === Int8(-1)
        @test_throws DecodeError decode(MemoryView([0x01]), UInt16, BigEndian())
        @test_throws DecodeError decode_next(MemoryView([0x01]), 1, UInt16, BigEndian())

        # Accepts memory views of either mutability, and memory they can view
        @test try_decode(ImmutableMemoryView([0x01, 0x02]), UInt16, BigEndian()) === 0x0102
        @test try_decode(MemoryView([0x01, 0x02]), UInt16, BigEndian()) === 0x0102
        @test try_decode(MemoryView(b"\x01\x02"), UInt16, BigEndian()) === 0x0102
        @test decode(MemoryView("\x01\x02"), UInt16, BigEndian()) === 0x0102
        @test try_decode([0x01, 0x02], UInt16, BigEndian()) === 0x0102
        @test decode([0x01, 0x02], UInt16, BigEndian()) === 0x0102
        @test decode_next([0x01, 0x02], 1, UInt16, BigEndian()) === (0x0102, 3)
        @test_throws MethodError decode_next(MemoryView([0x01, 0x02]), UInt16, BigEndian())
        v = zeros(UInt8, 2)
        @test encode!(MemoryView(v), 0x0102, BigEndian()) == 2
        @test v == [0x01, 0x02]
        @test encode!(v, 0x0304, BigEndian()) == 2
        @test try_encode!(v, 0x0506, BigEndian()) == 2
        @test v == [0x05, 0x06]
        @test_throws TypeError encode!(ImmutableMemoryView(v), 0x0102, BigEndian())
        # Missing methods are MethodErrors, not stack overflows
        @test_throws MethodError try_decode(ImmutableMemoryView(v), String, BigEndian())
        @test_throws MethodError try_decode(MemoryView(v), String, BigEndian())
        @test_throws MethodError encode!(MemoryView(v), "abc", BigEndian())
        @test_throws MethodError try_encode!(MemoryView(v), "abc", BigEndian())
    end

    @testset "Bool" begin
        @test try_decode_n(MemoryView([0x00]), Bool, LittleEndian()) === (false, 1)
        @test try_decode_n(MemoryView([0x01]), Bool, BigEndian()) === (true, 1)
        for b in 0x02:0xff
            @test is_err(try_decode(MemoryView([b]), Bool, LittleEndian()), InvalidData)
        end
        @test is_err(try_decode(MemoryView(UInt8[]), Bool, LittleEndian()), EndOfInput)
        v = [0xaa, 0xaa]
        @test encode!(MemoryView(v), true, BigEndian()) == 1
        @test encode!(MemoryView(v)[2:end], false, BigEndian()) == 1
        @test v == [0x01, 0x00]
        @test max_encoded_size(Bool, LittleEndian()) == 1

        # Custom encoding
        @test try_decode_n(MemoryView([0x02]), Bool, CBool()) === (true, 1)
        @test load(CursorReader([0x00]), Bool, CBool()) === false
        io = VecWriter()
        @test store(io, true, CBool()) == 1
        @test io.vec == [0x01]
    end

    @testset "Enums" begin
        @test try_decode_n(MemoryView([0x00, 0x01]), Fruit, BigEndian()) === (apple, 2)
        @test try_decode_n(MemoryView([0x03, 0x02]), Fruit, LittleEndian()) === (banana, 2)
        @test try_decode_n(MemoryView([0xff, 0xff]), Fruit, LittleEndian()) === (cherry, 2)
        @test is_err(try_decode(MemoryView([0x00, 0x00]), Fruit, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x02, 0x03]), Fruit, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x01]), Fruit, LittleEndian()), Truncated)
        @test is_err(try_decode(MemoryView(UInt8[]), Fruit, LittleEndian()), EndOfInput)
        @test try_decode_n(MemoryView([0xc8]), Small, BigEndian()) === (wee, 1)
        @test is_err(try_decode(MemoryView([0x04]), Small, BigEndian()), InvalidData)
        # Contiguous
        @test try_decode_n(MemoryView([0xff, 0xff]), Signs, BigEndian()) === (negative, 2)
        @test try_decode_n(MemoryView([0x00, 0x00]), Signs, BigEndian()) === (neutral, 2)
        @test try_decode_n(MemoryView([0x00, 0x01]), Signs, BigEndian()) === (positive, 2)
        @test is_err(try_decode(MemoryView([0xff, 0xfe]), Signs, BigEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x00, 0x02]), Signs, BigEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x80, 0x00]), Signs, BigEndian()), InvalidData)
        for b in 0x00:0xff # every byte is a member, although `typemax - typemin` overflows
            @test try_decode_n(MemoryView([b]), Full8, LittleEndian()) === (reinterpret(Full8, b), 1)
        end
        v = zeros(UInt8, 2)
        @test encode!(MemoryView(v), banana, BigEndian()) == 2
        @test v == [0x02, 0x03]
        @test max_encoded_size(Fruit, LittleEndian()) == 2
    end

    # Test a bits type T whose encoding in little-endian is `le`, and whose value has the low
    # bits `value`.
    function test_odd_bits(T, le::Vector{UInt8}, value)
        n = length(le)
        be = reverse(le)
        @test max_encoded_size(T, LittleEndian()) == max_encoded_size(T, BigEndian()) == n
        (x, next) = decode_next(MemoryView(le), 1, T, LittleEndian())
        @test next == n + 1
        @test low_bits(x) == value
        (y, next) = decode_next(MemoryView(be), 1, T, BigEndian())
        @test next == n + 1
        @test low_bits(y) == value
        @test low_bits(decode(MemoryView(le), T, LittleEndian())) == value
        # Unaligned, and followed by other bytes
        buf = fill(0xaa, n + 3)
        @test encode!(MemoryView(buf)[2:end], x, LittleEndian()) == n
        @test buf[2:(n + 1)] == le
        @test encode!(MemoryView(buf)[2:end], x, BigEndian()) == n
        @test buf[2:(n + 1)] == be
        @test low_bits(decode(MemoryView(buf), 2, T, BigEndian())) == value
        # Too short
        @test is_err(try_decode(MemoryView(le[1:(n - 1)]), T, LittleEndian()), n == 1 ? EndOfInput : Truncated)
        @test try_encode!(MemoryView(zeros(UInt8, n - 1)), x, LittleEndian()) === EncodeError(InsufficientSpace)
        # Bulk, and loading byte by byte
        data = vcat(be, be, be[1:(n - 1)])
        dst = MemoryView(Vector{T}(undef, 3))
        @test decode_into!(dst, MemoryView(data), BigEndian()) == (2, 2n)
        @test all(==(value), map(low_bits, dst[1:2]))
        out = zeros(UInt8, 2n + 1)
        @test encode_into!(MemoryView(out), dst[1:2], BigEndian()) == (2, 2n)
        @test out[1:2n] == data[1:2n]
        io = ChunkedReader([[b] for b in data])
        @test load_all!(io, dst, BigEndian()) == 2
        @test is_err(try_load(io, T, BigEndian()), n == 1 ? EndOfInput : Truncated)
        w = VecWriter()
        @test store(w, x, LittleEndian()) == n
        @test store_all(w, dst[1:2], LittleEndian()) == 2n
        @test w.vec == vcat(le, le, le)
        return nothing
    end

    @testset "Odd-sized primitive types" begin
        test_odd_bits(U24, [0x01, 0x02, 0x83], 0x00830201)
        test_odd_bits(S24, [0xff, 0xfe, 0x7f], 0x007ffeff)
        le144 = UInt8.(1:18)
        test_odd_bits(U144, le144, reinterpret(UInt128, le144[1:16])[1])
        # Invalid bits
        @test is_err(try_decode(MemoryView([0x00, 0x00, 0x80]), S24, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x80, 0x00, 0x00]), S24, BigEndian()), InvalidData)
        @test decode_into!(MemoryView(Vector{S24}(undef, 3)), MemoryView([0x00, 0x00, 0x01, 0x00, 0x00, 0x80]), LittleEndian()) == (1, 3)
        # BitsStorable types wider than any integer
        test_odd_bits(S144, UInt8[1:17; 0x7f], reinterpret(UInt128, UInt8.(1:16))[1])
        @test is_err(try_decode(MemoryView([zeros(UInt8, 17); 0x80]), S144, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x80; zeros(UInt8, 17)]), S144, BigEndian()), InvalidData)
        # BitsStorable without `is_valid_bits`
        @test_throws MethodError try_decode(MemoryView(zeros(UInt8, 2)), NoCheck16, LittleEndian())
    end

    HAS_NARROW && @testset "Narrow primitive types" begin
        test_odd_bits(U22, [0x01, 0x02, 0x3f], 0x003f0201)
        test_odd_bits(U5, [0x1f], 0x1f)
        test_odd_bits(S12, [0xfe, 0x0f], 0x0ffe)
        test_odd_bits(U30, [0x01, 0x02, 0x03, 0x3f], 0x3f030201)
        test_odd_bits(S30, [0x01, 0x02, 0x03, 0x1f], 0x1f030201)
        # Nonzero padding bits are invalid
        @test is_err(try_decode(MemoryView([0x01, 0x02, 0x40]), U22, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x40, 0x02, 0x01]), U22, BigEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x20]), U5, LittleEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([0x00, 0x10]), S12, LittleEndian()), InvalidData)
        for b in (0x40, 0x80)
            @test is_err(try_decode(MemoryView([0x01, 0x02, 0x03, b]), U30, LittleEndian()), InvalidData)
            @test is_err(try_decode(MemoryView([b, 0x03, 0x02, 0x01]), U30, BigEndian()), InvalidData)
            @test is_err(try_decode(MemoryView([b, 0x00, 0x00, 0x00]), S30, BigEndian()), InvalidData)
        end
        @test is_err(try_decode(MemoryView([0x00, 0x00, 0x00, 0x20]), S30, LittleEndian()), InvalidData)
        @test decode_into!(MemoryView(Vector{U30}(undef, 3)), MemoryView(UInt8[0x3f, 0, 0, 0, 0x40, 0, 0, 0]), BigEndian()) == (1, 4)
        # Invalid bits
        @test is_err(try_decode(MemoryView([0xff, 0x0f]), S12, LittleEndian()), InvalidData)
        # Padding bits are written as zero
        buf = fill(0xff, 3)
        @test encode!(MemoryView(buf), decode(MemoryView([0xff, 0xff, 0x3f]), U22, LittleEndian()), LittleEndian()) == 3
        @test buf == [0xff, 0xff, 0x3f]

        # The design's example of a hand-written codec
        io = CursorReader([0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff])
        @test UInt32(load(io, U29, LittleEndian())) == 1
        @test is_err(try_load(io, U29, LittleEndian()), InvalidData)
        @test length(get_buffer(io)) == 4
        w = VecWriter()
        @test store(w, U29(0x1fffffff), BigEndian()) == 4
        @test w.vec == [0x1f, 0xff, 0xff, 0xff]
        dst = Vector{U29}(undef, 3)
        @test decode_into!(MemoryView(dst), MemoryView([0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x07, 0xff]), BigEndian()) == (2, 8)
        @test UInt32.(dst[1:2]) == [5, 7]
    end

    # Decode all of `bytes` as Chars, returning (char, index) pairs
    function decode_chars(bytes)
        result = Tuple{Char, Int}[]
        i = 1
        while true
            r = try_decode_next(MemoryView(bytes), i, Char, UTF8())
            if r isa DecodeError
                @assert r.kind === EndOfInput
                break
            end
            (c, next) = r
            push!(result, (c, i))
            i = next
        end
        return result
    end

    string_chars(bytes) = [(s[i], i) for s in (String(copy(bytes)),) for i in eachindex(s)]

    @testset "Char" begin
        @test max_encoded_size(Char, UTF8()) == 4
        @test is_err(try_decode(MemoryView(UInt8[]), Char, UTF8()), EndOfInput)

        # The examples of the design document
        examples = [
            ([0xe2, 0x82, 0xac], ['€']),
            ([0xc3, 0xff], ['\xc3', '\xff']),
            ([0xe2, 0x41], ['\xe2', 'A']),
            ([0xc3, 0xa9, 0x80], ['é', '\x80']),
            ([0xe2, 0x82], ['\xe2\x82']),
            ([0xe2], ['\xe2']),
            ([0xf0, 0x9f, 0x98], ['\xf0\x9f\x98']),
            ([0xff], ['\xff']),
            ([0x80], ['\x80']),
            ([0xf8, 0x80], ['\xf8', '\x80']),
            ([0xc0, 0x80], ['\xc0\x80']),
            ([0xe0, 0x80, 0x80], ['\xe0\x80\x80']),
            ([0xed, 0xa0, 0x80], ['\ud800']),
            ([0xf4, 0x90, 0x80, 0x80], ['\xf4\x90\x80\x80']),
            ([0xf7, 0xbf, 0xbf, 0xbf], ['\xf7\xbf\xbf\xbf']),
        ]
        for (bytes, chars) in examples
            @test first.(decode_chars(bytes)) == chars
        end

        # Exactly the same as String iteration, for all short sequences of interesting bytes
        interesting = [
            0x00, 0x41, 0x7f, 0x80, 0x8f, 0x9f, 0xa9, 0xbf, 0xc0, 0xc1, 0xc3, 0xdf, 0xe0,
            0xe2, 0xed, 0xef, 0xf0, 0xf4, 0xf5, 0xf7, 0xf8, 0xfe, 0xff,
        ]
        for len in 1:4
            for idx in CartesianIndices(ntuple(_ -> length(interesting), len))
                bytes = [interesting[i] for i in Tuple(idx)]
                @test decode_chars(bytes) == string_chars(bytes)
            end
        end
        # All two-byte sequences
        for a in 0x00:0xff, b in 0x00:0xff
            bytes = [a, b]
            @test decode_chars(bytes) == string_chars(bytes)
        end

        # Encoding
        for c in ['\0', 'a', 'é', '€', '😀', '\xe2', '\xe2\x82', '\xc0\x80', '\ud800', '\xf7\xbf\xbf\xbf']
            @test try_encoded_size(c, UTF8()) === encoded_size(c, UTF8()) === ncodeunits(c)
            for len in 0:6
                buf = fill(0xaa, len)
                n = try_encode!(MemoryView(buf), c, UTF8())
                if len < ncodeunits(c)
                    @test n === EncodeError(InsufficientSpace)
                    err = try
                        encode!(MemoryView(buf), c, UTF8())
                    catch e
                        e
                    end
                    @test err isa LightBoundsError
                    # The needed size is not known, so the error reports the first byte past the end
                    @test occursin("collection[1:$(len + 1)]", sprint(showerror, err))
                else
                    @test n == ncodeunits(c)
                    @test buf[1:n] == codeunits(string(c))
                    # Doesn't write past the encoding when the buffer is shorter than 4
                    len < 4 && @test all(==(0xaa), buf[(n + 1):end])
                    @test try_decode_n(MemoryView(buf[1:n]), Char, UTF8()) === (c, n)
                end
            end
        end
        # Round trip is not exact for Chars that no String can contain
        c = reinterpret(Char, typemax(UInt32))
        buf = zeros(UInt8, 4)
        @test encode!(MemoryView(buf), c, UTF8()) == 4
        @test first.(decode_chars(buf)) == fill('\xff', 4)

        s = "aé€😀 hello \xe2\x82 x"
        @test first.(decode_chars(codeunits(s))) == collect(s)
    end

    @testset "Char on readers" begin
        # Truncated at EOF decodes as a malformed char, as in String
        io = CursorReader([0x41, 0xe2, 0x82])
        @test load(io, Char, UTF8()) === 'A'
        @test load(io, Char, UTF8()) === '\xe2\x82'
        @test is_err(try_load(io, Char, UTF8()), EndOfInput)

        # With more data coming, a lead byte is never decoded alone
        io = ChunkedReader([[0x61, 0xe2], [0x82], [0xac, 0x62]])
        @test load(io, Char, UTF8()) === 'a'
        @test load(io, Char, UTF8()) === '€'
        @test load(io, Char, UTF8()) === 'b'
        @test is_err(try_load(io, Char, UTF8()), EndOfInput)

        for max_fill in 1:5
            s = "aé€😀\xe2\x82 x\xff"
            io = BoundedReader(s, 4; max_fill)
            chars = Char[]
            while true
                c = try_load(io, Char, UTF8())
                c isa DecodeError && break
                push!(chars, c)
            end
            @test chars == collect(s)
        end

        # Capacity too small
        @test_throws IOError load(BoundedReader("€", 3), Char, UTF8())
        # ... but this is data-dependent
        @test load(BoundedReader("é", 3), Char, UTF8()) === 'é'

        io = VecWriter()
        for c in "aé€😀"
            store(io, c, UTF8())
        end
        @test String(io.vec) == "aé€😀"
    end

    @testset "try_load / load" begin
        io = CursorReader([0x01, 0x02, 0x03, 0x04, 0x05, 0x02])
        @test try_load(io, UInt32, LittleEndian()) === 0x04030201
        @test is_err(try_load(io, UInt32, LittleEndian()), Truncated)
        @test is_err(try_load(io, Bool, LittleEndian()), InvalidData)
        @test length(get_buffer(io)) == 2 # nothing consumed
        @test try_load(io, UInt16, BigEndian()) === 0x0502
        @test is_err(try_load(io, UInt8, BigEndian()), EndOfInput)
        @test is_err(try_load(io, UInt64, BigEndian()), EndOfInput)
        @test_throws DecodeError load(io, UInt8, BigEndian())
        err = try
            load(io, UInt8, BigEndian())
        catch e
            e
        end
        @test err === DecodeError(EndOfInput)

        # Values straddling fills
        data = collect(UInt8, 1:64)
        for max_fill in 1:9, T in (UInt8, UInt16, UInt32, UInt64, UInt128)
            io = BoundedReader(data, 16; max_fill)
            expected = reinterpret(T, data)
            for x in expected
                @test load(io, T, LittleEndian()) === ltoh(x)
            end
            @test is_err(try_load(io, T, LittleEndian()), EndOfInput)
        end
        io = ChunkedReader([[0x01], [0x02, 0x03], [0x04, 0x05]])
        @test load(io, UInt32, BigEndian()) === 0x01020304
        @test is_err(try_load(io, UInt32, BigEndian()), Truncated)
        @test load(io, UInt8, BigEndian()) === 0x05

        # Capacity too small throws, regardless of where the value is
        io = BoundedReader(zeros(UInt8, 20), 4)
        err = try
            load(io, UInt64, LittleEndian())
        catch e
            e
        end
        @test err isa IOError
        @test err.kind === IOErrorKinds.BufferTooShort
        @test load(io, UInt32, LittleEndian()) === UInt32(0) # nothing consumed
        # ... but not if EOF comes first
        @test is_err(try_load(BoundedReader(zeros(UInt8, 3), 4), UInt64, LittleEndian()), Truncated)
        # expandable rules it out
        @test load(expandable(BoundedReader(collect(UInt8, 1:16), 4)), UInt128, BigEndian()) ===
            0x0102030405060708090a0b0c0d0e0f10

        # BufReader
        io = BufReader(IOBuffer(collect(UInt8, 1:9)), 4)
        @test load(io, UInt64, BigEndian()) === 0x0102030405060708
        @test is_err(try_load(io, UInt16, BigEndian()), Truncated)
    end

    @testset "store" begin
        io = VecWriter()
        @test store(io, 0x01020304, BigEndian()) == 4
        @test store(io, 0x0506, LittleEndian()) == 2
        @test store(io, Int8(-1), BigEndian()) == 1
        @test store(io, true, BigEndian()) == 1
        @test store(io, 1.0, LittleEndian()) == 8
        @test io.vec == [0x01, 0x02, 0x03, 0x04, 0x06, 0x05, 0xff, 0x01, bytes_le(1.0)...]

        # A writer whose buffer is too small throws, and stores nothing
        sink = UInt8[]
        io = BoundedWriter(sink, 4)
        @test store(io, 0x01020304, BigEndian()) == 4
        @test store(io, 0x05, BigEndian()) == 1 # flushes the first 4 bytes
        err = try
            store(io, UInt64(1), BigEndian())
        catch e
            e
        end
        @test err isa IOError
        @test err.kind === IOErrorKinds.BufferTooShort
        flush(io)
        @test sink == [0x01, 0x02, 0x03, 0x04, 0x05]

        sink = UInt8[]
        io = expandable(BoundedWriter(sink, 4))
        @test store(io, UInt64(1), BigEndian()) == 8
        flush(io)
        @test sink == bytes_be(UInt64(1))
    end

    @testset "@try_return" begin
        function load_pair(io)
            a = @try_return try_load(io, UInt16, BigEndian())
            b = @try_return try_load(io, Bool, BigEndian())
            return (a, b)
        end
        @test load_pair(CursorReader([0x00, 0x01, 0x01])) === (0x0001, true)
        @test is_err(load_pair(CursorReader([0x00, 0x01, 0x02])), InvalidData)
        @test is_err(load_pair(CursorReader([0x00])), Truncated)
        @test is_err(load_pair(CursorReader(UInt8[])), EndOfInput)

        function decode_pair(mem)
            (a, i) = @try_return try_decode_next(mem, 1, UInt8, LittleEndian())
            b = @try_return try_decode(mem, i, UInt8, LittleEndian())
            return a + b
        end
        @test decode_pair(MemoryView([0x01, 0x02])) === 0x03
        @test is_err(decode_pair(MemoryView([0x01])), EndOfInput)

        function encode_pair!(mem, a, b)
            n = @try_return try_encode!(mem, a, BigEndian())
            m = @try_return try_encode!(mem, 1 + n, b, BigEndian())
            return n + m
        end
        v = zeros(UInt8, 3)
        @test encode_pair!(MemoryView(v), 0x01, 0x0203) === 3
        @test v == [0x01, 0x02, 0x03]
        @test encode_pair!(MemoryView(zeros(UInt8, 2)), 0x01, 0x0203) === EncodeError(InsufficientSpace)
    end

    @testset "decode_into! / encode_into!" begin
        for T in (BITS_TYPES..., Bool, Fruit), e in (LittleEndian(), BigEndian())
            values = if T === Bool
                rand(Bool, 37)
            elseif T === Fruit
                rand(instances(Fruit), 37)
            else
                rand(T, 37)
            end
            bytes = zeros(UInt8, sizeof(T) * 37 + 5)
            # Misaligned
            @test encode_into!(MemoryView(bytes)[2:end], MemoryView(values), e) == (37, 37 * sizeof(T))
            for (i, x) in enumerate(values)
                r = try_decode(MemoryView(bytes), 2 + (i - 1) * sizeof(T), T, e)
                @test isequal(r, x)
            end
            dst = Vector{T}(undef, 40)
            src = MemoryView(bytes)[2:(1 + 37 * sizeof(T))]
            @test decode_into!(MemoryView(dst), src, e) == (37, 37 * sizeof(T))
            @test isequal(dst[1:37], values)
            # Limited by dst
            dst = Vector{T}(undef, 10)
            @test decode_into!(MemoryView(dst), MemoryView(bytes)[2:end], e) == (10, 10 * sizeof(T))
            @test isequal(dst, values[1:10])
            # Limited by dst bytes
            out = zeros(UInt8, 4 * sizeof(T) - 1)
            @test encode_into!(MemoryView(out), MemoryView(values), e) == (3, 3 * sizeof(T))
            @test decode_into!(MemoryView(Vector{T}(undef, 3)), MemoryView(out), e) == (3, 3 * sizeof(T))
            # Empty
            @test decode_into!(MemoryView(T[]), MemoryView(bytes), e) == (0, 0)
            @test encode_into!(MemoryView(UInt8[]), MemoryView(values), e) == (0, 0)
            @test encode_into!(MemoryView(bytes), MemoryView(T[]), e) == (0, 0)
        end

        # Stops at invalid data
        dst = zeros(Bool, 5)
        @test decode_into!(MemoryView(dst), MemoryView([0x01, 0x00, 0x02, 0x01]), LittleEndian()) == (2, 2)
        @test dst[1:2] == [true, false]

        # Memory that `MemoryView` can view is accepted too, see "Memory-like arguments"
        @test decode_into!(zeros(UInt8, 2), MemoryView([0x01]), LittleEndian()) == (1, 1)
        @test decode_into!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian()) == (1, 1)
        @test encode_into!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian()) == (1, 1)
        @test load_into!(CursorReader([0x01]), zeros(UInt8, 1), LittleEndian()) == 1
        @test store_all(VecWriter(), [0x01], LittleEndian()) == 1

        # Variable-length encodings
        s = "aé€😀\xe2\x82"
        dst = Vector{Char}(undef, 10)
        @test decode_into!(MemoryView(dst), MemoryView(s), UTF8()) == (length(s), ncodeunits(s))
        @test dst[1:length(s)] == collect(s)
        out = zeros(UInt8, 8)
        @test encode_into!(MemoryView(out), MemoryView(collect(s)), UTF8()) == (3, 6) # no room for the 4 bytes of 😀
        @test out[1:6] == codeunits("aé€")
        @test encode_into!(MemoryView(zeros(UInt8, 20)), MemoryView(collect(s)), UTF8()) == (length(s), ncodeunits(s))
    end

    @testset "load_into! / load_all!" begin
        data = collect(UInt8, 1:41)
        for max_fill in (1, 3, 8, 100), T in (UInt8, UInt16, UInt32, UInt64)
            n = div(41, sizeof(T))
            expected = [ltoh(x) for x in reinterpret(T, data[1:(n * sizeof(T))])]

            io = BoundedReader(data, 16; max_fill)
            dst = Vector{T}(undef, 50)
            @test load_all!(io, MemoryView(dst), LittleEndian()) == n
            @test dst[1:n] == expected
            r = try_load(io, T, LittleEndian())
            @test is_err(r, (41 % sizeof(T) == 0) ? EndOfInput : Truncated)

            io = BoundedReader(data, 16; max_fill)
            dst = Vector{T}(undef, 50)
            total = 0
            while true
                k = load_into!(io, MemoryView(dst)[(total + 1):end], LittleEndian())
                iszero(k) && break
                @test k ≥ 1
                total += k
            end
            @test total == n
            @test dst[1:n] == expected
        end

        @test load_into!(CursorReader([0x01]), MemoryView(UInt8[]), LittleEndian()) == 0
        @test load_all!(CursorReader([0x01]), MemoryView(UInt8[]), LittleEndian()) == 0
        @test load_into!(CursorReader(UInt8[]), MemoryView(zeros(UInt8, 3)), LittleEndian()) == 0

        # Stops at an invalid element, consuming nothing of it
        io = CursorReader([0x01, 0x00, 0x01, 0x05, 0x01])
        dst = zeros(Bool, 5)
        @test load_all!(io, MemoryView(dst), BigEndian()) == 3
        @test dst[1:3] == [true, false, true]
        @test is_err(try_load(io, Bool, BigEndian()), InvalidData)
        @test length(get_buffer(io)) == 2

        # Variable-length elements straddling the buffer
        s = "aé€😀\xe2\x82 x\xffyz€"
        for max_fill in 1:5, cap in 4:6
            io = BoundedReader(s, cap; max_fill)
            dst = Vector{Char}(undef, 30)
            @test load_all!(io, MemoryView(dst), UTF8()) == length(s)
            @test dst[1:length(s)] == collect(s)
            @test is_err(try_load(io, Char, UTF8()), EndOfInput)
        end
        io = ChunkedReader([[0x61, 0xe2], [0x82], [0xac, 0x62, 0xe2]])
        dst = Vector{Char}(undef, 10)
        @test load_all!(io, MemoryView(dst), UTF8()) == 4
        @test dst[1:4] == ['a', '€', 'b', '\xe2']

        # Too-small capacity
        @test_throws IOError load_into!(BoundedReader(zeros(UInt8, 8), 2), MemoryView(zeros(UInt32, 2)), LittleEndian())
    end

    @testset "load!" begin
        data = collect(UInt8, 1:40)
        for max_fill in (1, 3, 8, 100), T in (UInt8, UInt16, UInt32, UInt64)
            n = div(40, sizeof(T))
            expected = [ltoh(x) for x in reinterpret(T, data)]
            io = BoundedReader(data, 16; max_fill)
            dst = MemoryView(Vector{T}(undef, n))
            @test load!(io, dst, LittleEndian()) === dst
            @test collect(dst) == expected
            @test is_err(try_load(io, UInt8, LittleEndian()), EndOfInput)
        end
        # Variable-length elements straddling the buffer
        s = "aé€😀\xe2\x82 x\xffyz€"
        for max_fill in 1:5, cap in 4:6
            io = BoundedReader(s, cap; max_fill)
            dst = Vector{Char}(undef, length(s))
            load!(io, MemoryView(dst), UTF8())
            @test dst == collect(s)
        end
        # An empty `dst` loads nothing
        io = CursorReader([0x01])
        @test isempty(load!(io, MemoryView(UInt8[]), LittleEndian()))
        @test length(get_buffer(io)) == 1

        # No bytes at all
        @test_throws DecodeError(EndOfInput) load!(CursorReader(UInt8[]), MemoryView(zeros(UInt16, 2)), LittleEndian())
        # Ends between two elements, after some were loaded
        io = CursorReader([0x01, 0x00])
        dst = zeros(UInt16, 2)
        @test_throws DecodeError(EndOfInput) load!(io, MemoryView(dst), LittleEndian())
        @test dst[1] == 0x0001
        @test isempty(get_buffer(io))
        # Ends partway through an element, which is not consumed
        io = CursorReader([0x01, 0x00, 0x02])
        @test_throws DecodeError(Truncated) load!(io, MemoryView(zeros(UInt16, 2)), LittleEndian())
        @test length(get_buffer(io)) == 1
        # An invalid element, which is not consumed
        io = CursorReader([0x01, 0x00, 0x05, 0x01])
        dst = zeros(Bool, 4)
        @test_throws DecodeError(InvalidData) load!(io, MemoryView(dst), BigEndian())
        @test dst[1:2] == [true, false]
        @test length(get_buffer(io)) == 2
        # Too-small capacity
        @test_throws IOError load!(BoundedReader(zeros(UInt8, 8), 2), MemoryView(zeros(UInt32, 2)), LittleEndian())
        # The convenience modules
        dst = zeros(UInt16, 2)
        Big.load!(CursorReader([0x00, 0x01, 0x00, 0x02]), MemoryView(dst))
        @test dst == [0x0001, 0x0002]
    end

    @testset "store_all" begin
        values = rand(UInt32, 33)
        for cap in (4, 5, 7, 100)
            sink = UInt8[]
            io = BoundedWriter(sink, cap)
            @test store_all(io, MemoryView(values), BigEndian()) == 4 * 33
            flush(io)
            @test sink == reduce(vcat, bytes_be.(values))
        end
        sink = UInt8[]
        io = BoundedWriter(sink, 3)
        @test_throws IOError store_all(io, MemoryView(values), BigEndian())
        @test store_all(io, MemoryView(UInt32[]), BigEndian()) == 0

        s = "aé€😀\xe2\x82 x\xffyz€"
        for cap in 4:7
            sink = UInt8[]
            io = BoundedWriter(sink, cap)
            @test store_all(io, MemoryView(collect(s)), UTF8()) == ncodeunits(s)
            flush(io)
            @test String(sink) == s
        end
        io = VecWriter()
        @test store_all(io, MemoryView([true, false]), LittleEndian()) == 2
        @test store_all(io, MemoryView(Fruit[banana]), LittleEndian()) == 2
        @test io.vec == [0x01, 0x00, 0x03, 0x02]
    end

    @testset "Indices" begin
        # Decoding at an index is decoding from the slice
        for (T, e) in CODEC_CASES
            m = max_encoded_size(T, e)
            for len in 0:(2m + 1), _ in 1:3
                mem = MemoryView(rand(UInt8, len))
                for i in 1:(len + 1)
                    expected = try_decode_n(mem[i:end], T, e)
                    expected_next = expected isa DecodeError ? expected : (expected[1], i + expected[2])
                    @test isequal(try_decode_next(mem, i, T, e), expected_next)
                    @test isequal(try_decode_next(ImmutableMemoryView(mem), i, T, e), expected_next)
                    if expected isa DecodeError
                        @test isequal(try_decode(mem, i, T, e), expected)
                        @test_throws DecodeError decode(mem, i, T, e)
                        @test_throws DecodeError decode_next(mem, i, T, e)
                        continue
                    end
                    x = first(expected)
                    @test isequal(try_decode(mem, i, T, e), x)
                    @test isequal(decode(mem, i, T, e), x)
                    @test isequal(decode_next(mem, i, T, e), expected_next)
                    # Encoding at an index is encoding into the slice, and doesn't write
                    # before the index.
                    a = fill(0xaa, len)
                    b = fill(0xaa, len)
                    @test try_encode!(MemoryView(a), i, x, e) == try_encode!(MemoryView(b)[i:end], x, e)
                    @test a == b
                    @test all(==(0xaa), a[1:(i - 1)])
                    # With `max_encoded_size` bytes, encoding succeeds, and writes
                    # `encoded_size` bytes
                    @test try_encode!(MemoryView(zeros(UInt8, m)), x, e) === try_encoded_size(x, e)
                end
            end
        end

        bytes = [0x01, 0x02, 0x03, 0x04, 0x05]
        mem = MemoryView(bytes)
        @test decode(mem, 2, UInt32, BigEndian()) === 0x02030405
        @test decode_next(mem, 2, UInt32, BigEndian()) === (0x02030405, 6)
        @test try_decode(mem, 6, UInt8, BigEndian()) === DecodeError(EndOfInput)
        @test try_decode_next(mem, 6, UInt8, BigEndian()) === DecodeError(EndOfInput)
        @test try_decode(mem, 3, UInt32, BigEndian()) === DecodeError(Truncated)
        @test try_decode(mem, 6, Char, UTF8()) === DecodeError(EndOfInput)
        @test try_encode!(mem, 6, 0x01, BigEndian()) === EncodeError(InsufficientSpace)
        @test try_encode!(mem, 3, 0x01020304, BigEndian()) === EncodeError(InsufficientSpace)
        @test try_encode!(mem, 6, 'a', UTF8()) === EncodeError(InsufficientSpace)
        @test bytes == [0x01, 0x02, 0x03, 0x04, 0x05]
        # Any integer type of index
        @test decode(mem, UInt8(2), UInt16, LittleEndian()) === 0x0302
        @test decode_next(mem, Int32(4), UInt16, LittleEndian()) === (0x0504, 6)
        @test decode_next(mem, big(5), UInt8, LittleEndian()) === (0x05, 6)
        @test_throws InexactError decode(mem, typemax(UInt), UInt8, LittleEndian())

        # Indices outside 1:length(mem)+1 are out of bounds, for every kind of codec
        for i in (0, -1, 7, 100, typemin(Int), typemax(Int))
            for (T, e) in ((UInt8, LittleEndian()), (UInt32, BigEndian()), (Bool, LittleEndian()), (Char, UTF8()), (Header, BigEndian()))
                x = T === Char ? 'a' : T === Header ? Header(0, 0, 0, 0) : zero(T)
                @test_throws LightBoundsError try_decode(mem, i, T, e)
                @test_throws LightBoundsError decode(mem, i, T, e)
                @test_throws LightBoundsError try_decode_next(mem, i, T, e)
                @test_throws LightBoundsError decode_next(mem, i, T, e)
                @test_throws LightBoundsError try_encode!(mem, i, x, e)
                @test_throws LightBoundsError encode!(mem, i, x, e)
            end
            @test_throws LightBoundsError try_decode(MemoryView(UInt8[]), i, UInt8, LittleEndian())
        end
        @test bytes == [0x01, 0x02, 0x03, 0x04, 0x05]
        # Also when empty
        empty_mem = MemoryView(UInt8[])
        @test try_decode(empty_mem, 1, UInt8, LittleEndian()) === DecodeError(EndOfInput)
        @test try_decode(empty_mem, 1, Char, UTF8()) === DecodeError(EndOfInput)
        @test_throws LightBoundsError try_decode(empty_mem, 2, UInt8, LittleEndian())
        @test_throws LightBoundsError try_decode(empty_mem, 2, Char, UTF8())
    end

    @testset "encode! and try_encode!" begin
        # The error of a too short `mem` reports the indices the encoding needed
        error_message(f) =
        try
            f()
            nothing
        catch e
            e isa LightBoundsError ? sprint(showerror, e) : e
        end
        v = zeros(UInt8, 5)
        @test occursin("collection[3:6]", error_message(() -> encode!(MemoryView(v), 3, 0x01020304, BigEndian())))
        @test occursin("collection[1:8]", error_message(() -> encode!(MemoryView(v), UInt64(1), BigEndian())))
        @test occursin("collection[6:6]", error_message(() -> encode!(MemoryView(v), 6, 0x01, BigEndian())))
        @test occursin("collection[5:12]", error_message(() -> encode!(MemoryView(v), 5, Header(0, 0, 0, 0), LittleEndian())))
        # A hand-written codec doesn't say how many bytes it needed
        @test occursin("collection[4:6]", error_message(() -> encode!(MemoryView(v), 4, '€', UTF8())))
        @test occursin("collection[1:1]", error_message(() -> encode!(MemoryView(UInt8[]), false, CBool())))
        # An index out of bounds is reported as such
        @test occursin("collection[7]", error_message(() -> encode!(MemoryView(v), 7, 0x01, BigEndian())))
        @test occursin("collection[7]", error_message(() -> try_encode!(MemoryView(v), 7, 'a', UTF8())))
        @test v == zeros(UInt8, 5)
        # Only the bytes of the encoding are written, and nothing when it doesn't fit
        for (x, e) in (
                ('a', UTF8()), ('é', UTF8()), ('€', UTF8()), ('😀', UTF8()),
                (0x0102, BigEndian()), (true, CBool()), (Header(1, 2, 3, 4), LittleEndian()),
            )
            for len in 0:12, i in 1:(len + 1)
                buf = fill(0xaa, len)
                n = try_encode!(MemoryView(buf), i, x, e)
                written = n isa EncodeError ? 0 : n
                @test all(==(0xaa), buf[1:(i - 1)])
                @test all(==(0xaa), buf[(i + written):end])
            end
        end
        for (src, e) in ((['a', '€', 'é', '😀'], UTF8()), ([true, false, true], CBool()))
            for len in 0:12
                buf = fill(0xaa, len)
                (_, n_bytes) = encode_into!(MemoryView(buf), MemoryView(src), e)
                @test all(==(0xaa), buf[(n_bytes + 1):end])
            end
        end
        # The same as `try_encode!` when the encoding fits
        for (x, e) in ((0x0102, BigEndian()), ('€', UTF8()), (true, CBool()), (Header(1, 2, 3, 4), LittleEndian()))
            a = zeros(UInt8, 9)
            b = zeros(UInt8, 9)
            @test encode!(MemoryView(a), 2, x, e) === try_encode!(MemoryView(b), 2, x, e)
            @test a == b
            @test encode!(MemoryView(a), x, e) === try_encode!(MemoryView(b), x, e)
            @test a == b
        end
    end

    @testset "Values that can't be encoded" begin
        encode_inbounds!(mem, i, x, e) = @inbounds encode!(mem, i, x, e)
        @test max_encoded_size(Char, Latin1()) == 1
        for c in ('a', 'é', '\u00ff')
            @test try_encoded_size(c, Latin1()) === encoded_size(c, Latin1()) === 1
        end
        for c in ('λ', '€', '\u0100', '\xff', '\ud800')
            @test try_encoded_size(c, Latin1()) === EncodeError(InvalidValue)
            @test_throws EncodeError(InvalidValue) encoded_size(c, Latin1())
            for len in 0:2
                buf = fill(0xaa, len)
                @test try_encode!(MemoryView(buf), c, Latin1()) === EncodeError(InvalidValue)
                # Also when `mem` is too short, as this codec checks the value first
                @test_throws EncodeError(InvalidValue) encode!(MemoryView(buf), c, Latin1())
                if len ≥ 1
                    # The value is checked also in an `@inbounds` context
                    @test_throws EncodeError(InvalidValue) encode_inbounds!(MemoryView(buf), 1, c, Latin1())
                end
                # This codec checks the value before writing
                @test buf == fill(0xaa, len)
            end
            io = VecWriter()
            @test try_store(io, c, Latin1()) === EncodeError(InvalidValue)
            @test_throws EncodeError(InvalidValue) store(io, c, Latin1())
            @test isempty(io.vec)
        end
        # Too little space for a valid value
        @test try_encode!(MemoryView(UInt8[]), 'a', Latin1()) === EncodeError(InsufficientSpace)
        @test_throws LightBoundsError encode!(MemoryView(UInt8[]), 'a', Latin1())
        io = VecWriter()
        @test try_store(io, 'é', Latin1()) === 1
        @test store(io, 'a', Latin1()) === 1
        @test io.vec == [0xe9, 0x61]

        # Bulk functions stop at the value
        src = ['a', 'b', 'λ', 'c']
        buf = fill(0xaa, 6)
        @test encode_into!(MemoryView(buf), MemoryView(src), Latin1()) == (2, 2)
        @test buf[1:2] == [0x61, 0x62]
        @test try_encode!(MemoryView(buf), 3, src[3], Latin1()) === EncodeError(InvalidValue)
        for cap in (1, 2, 3, 100)
            sink = UInt8[]
            io = BoundedWriter(sink, cap)
            @test_throws EncodeError(InvalidValue) store_all(io, MemoryView(src), Latin1())
            flush(io)
            @test sink == [0x61, 0x62]
        end
        @test_throws EncodeError(InvalidValue) store_all(VecWriter(), MemoryView(['λ']), Latin1())

        # A codec may write before it finds out that the value is invalid, but not beyond
        # `max_encoded_size` bytes
        T = Tuple{Char, Char}
        @test max_encoded_size(T, Latin1()) == 2
        @test try_encoded_size(('a', 'b'), Latin1()) === 2
        @test try_encoded_size(('a', 'λ'), Latin1()) === EncodeError(InvalidValue)
        @test try_encoded_size(('λ', 'a'), Latin1()) === EncodeError(InvalidValue)
        buf = fill(0xaa, 5)
        @test try_encode!(MemoryView(buf), 2, ('a', 'λ'), Latin1()) === EncodeError(InvalidValue)
        @test buf == [0xaa, 0x61, 0xaa, 0xaa, 0xaa]
        @test_throws EncodeError(InvalidValue) encode!(MemoryView(buf), 2, ('b', 'λ'), Latin1())
        # ... but not when there is too little space
        buf = fill(0xaa, 3)
        @test try_encode!(MemoryView(buf), 3, ('a', 'b'), Latin1()) === EncodeError(InsufficientSpace)
        @test_throws LightBoundsError encode!(MemoryView(buf), 3, ('a', 'b'), Latin1())
        @test buf == fill(0xaa, 3)
        @test encode!(MemoryView(buf), 2, ('a', 'b'), Latin1()) === 2
        @test decode(MemoryView(buf), 2, T, Latin1()) === ('a', 'b')
        # Bytes written for an invalid value are not stored
        io = VecWriter()
        @test try_store(io, ('a', 'λ'), Latin1()) === EncodeError(InvalidValue)
        @test isempty(io.vec)
        @test store(io, ('x', 'y'), Latin1()) == 2
        @test io.vec == [0x78, 0x79]
    end

    @testset "Structs" begin
        # BitsLoadable: the fields are in order, each in the byte order of the encoding
        h = Header(0x01020304, 0x0506, 0x07, 0x08)
        @test max_encoded_size(Header, LittleEndian()) == max_encoded_size(Header, BigEndian()) == 8
        le = [0x04, 0x03, 0x02, 0x01, 0x06, 0x05, 0x07, 0x08]
        be = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        for (e, bytes) in ((LittleEndian(), le), (BigEndian(), be))
            buf = fill(0xaa, 10)
            @test encode!(MemoryView(buf), 2, h, e) == 8
            @test buf[2:9] == bytes
            @test buf[[1, 10]] == [0xaa, 0xaa]
            @test try_decode_n(MemoryView(bytes), Header, e) === (h, 8)
            @test decode(MemoryView(buf), 2, Header, e) === h
            @test is_err(try_decode(MemoryView(bytes[1:7]), Header, e), Truncated)
            @test is_err(try_decode(MemoryView(UInt8[]), Header, e), EndOfInput)
            @test load(CursorReader(bytes), Header, e) === h
            w = VecWriter()
            @test store(w, h, e) == 8
            @test w.vec == bytes
        end
        # Nested structs
        n = Nested(h, 1.5f0, Int16(-2), Int16(3))
        @test max_encoded_size(Nested, BigEndian()) == 16
        n_be = [be; bytes_be(1.5f0); bytes_be(Int16(-2)); bytes_be(Int16(3))]
        buf = zeros(UInt8, 16)
        @test encode!(MemoryView(buf), n, BigEndian()) == 16
        @test buf == n_be
        @test decode(MemoryView(n_be), Nested, BigEndian()) === n
        # Bulk
        for e in (LittleEndian(), BigEndian())
            values = [Nested(Header(rand(UInt32), rand(UInt16), rand(UInt8), rand(UInt8)), rand(Float32), rand(Int16), rand(Int16)) for _ in 1:20]
            bytes = zeros(UInt8, 16 * 20 + 3)
            @test encode_into!(MemoryView(bytes), MemoryView(values), e) == (20, 320)
            for (i, x) in enumerate(values)
                @test decode(MemoryView(bytes), 16 * (i - 1) + 1, Nested, e) === x
            end
            dst = Vector{Nested}(undef, 25)
            @test decode_into!(MemoryView(dst), MemoryView(bytes), e) == (20, 320)
            @test dst[1:20] == values
            dst = Vector{Nested}(undef, 25)
            @test load_all!(ChunkedReader([bytes[i:min(i + 6, end)] for i in 1:7:length(bytes)]), MemoryView(dst), e) == 20
            @test dst[1:20] == values
            w = VecWriter()
            @test store_all(w, MemoryView(values), e) == 320
            @test w.vec == bytes[1:320]
        end

        # BitsStorable: the fields are checked, then the whole value
        @test try_decode_n(MemoryView([0x01, 0x00, 0x02, 0x03]), Flagged, BigEndian()) === (Flagged(true, 0x00, banana), 4)
        @test try_decode(MemoryView([0x00, 0x07, 0x01, 0x00]), Flagged, LittleEndian()) === Flagged(false, 0x07, apple)
        @test is_err(try_decode(MemoryView([0x02, 0x00, 0x00, 0x01]), Flagged, BigEndian()), InvalidData) # Bool
        @test is_err(try_decode(MemoryView([0x01, 0x00, 0x00, 0x00]), Flagged, BigEndian()), InvalidData) # Fruit
        @test is_err(try_decode(MemoryView([0x00, 0x00, 0x02, 0x03]), Flagged, BigEndian()), InvalidData) # invariant
        buf = zeros(UInt8, 4)
        @test encode!(MemoryView(buf), Flagged(true, 0x05, cherry), BigEndian()) == 4
        @test buf == [0x01, 0x05, 0xff, 0xff]
        # The fields of nested structs are checked too
        valid = [0x01, 0x00, 0x02, 0x03]
        breaks_invariant = [0x00, 0x00, 0x02, 0x03]
        @test decode(MemoryView([valid; valid]), Outer, BigEndian()) === Outer(Flagged(true, 0x00, banana), Flagged(true, 0x00, banana))
        @test is_err(try_decode(MemoryView([valid; breaks_invariant]), Outer, BigEndian()), InvalidData)
        @test is_err(try_decode(MemoryView([valid; [0x03, 0x00, 0x02, 0x03]]), Outer, BigEndian()), InvalidData)
        @test decode_into!(MemoryView(Vector{Outer}(undef, 3)), MemoryView([valid; valid; valid; breaks_invariant]), BigEndian()) == (1, 8)

        # A struct without fields is encoded in zero bytes
        @test max_encoded_size(Empty, LittleEndian()) == 0
        @test try_decode_n(MemoryView(UInt8[]), Empty, LittleEndian()) === (Empty(), 0)
        @test decode_next(MemoryView([0x01]), 2, Empty, BigEndian()) === (Empty(), 2)
        @test encode!(MemoryView(UInt8[]), Empty(), BigEndian()) == 0

        # Structs that can't be bits types
        for T in (
                Padded, LoadableWithBool, WithChar, WithPlain, WithPadded, Misaligned,
                TrailingPadding, MisalignedNested, WithU256, WithU24, (HAS_NARROW ? (WithNarrow,) : ())...,
            )
            @test_throws ArgumentError max_encoded_size(T, LittleEndian())
            @test_throws ArgumentError try_decode(MemoryView(zeros(UInt8, 16)), T, BigEndian())
            @test_throws ArgumentError decode_into!(MemoryView(Vector{T}(undef, 1)), MemoryView(zeros(UInt8, 16)), BigEndian())
        end
        @test_throws ArgumentError encode!(MemoryView(zeros(UInt8, 8)), Padded(0x01, 0x02), LittleEndian())
        message(T) =
        try
            max_encoded_size(T, LittleEndian())
        catch e
            sprint(showerror, e)
        end
        @test occursin("`Padded` has padding on some or all platforms, so it can't be `BitsLoadable`: its field `b` follows 1 bytes of other fields, which is not a multiple of 4, the size of its type `UInt32`", message(Padded))
        @test occursin("`LoadableWithBool` is `BitsLoadable`, but its field `a` has the type `Bool`, which is `BitsStorable`", message(LoadableWithBool))
        @test occursin("field `c` of `WithChar` has the type `Char`, whose `bits_kind` is `ManualCodec`", message(WithChar))
        @test occursin("field `p` of `WithPlain` has the type `Plain`", message(WithPlain))
        @test occursin("`Padded` has padding", message(WithPadded))
        HAS_NARROW && @test occursin("whose bit width 30 is not a power of two of at least 8", message(WithNarrow))
        @test occursin("field `b` follows 4 bytes of other fields, which is not a multiple of 8", message(Misaligned))
        @test occursin("its fields have 12 bytes, which is not a multiple of 8, the size of its largest primitive field", message(TrailingPadding))
        @test occursin("field `h` follows 2 bytes of other fields, which is not a multiple of 4, the size of the largest primitive field of its type `Header`", message(MisalignedNested))
        @test occursin("field `b` follows 16 bytes of other fields, which is not a multiple of 32, the size of its type `U256`", message(WithU256))
        @test occursin("whose bit width 24 is not a power of two of at least 8", message(WithU24))
        # The stricter rule rejects `WithU256` although it has no padding on this platform
        @test fieldoffset(WithU256, 2) == 16 && sizeof(WithU256) == 48 || Base.datatype_alignment(U256) == 32
        # Accepted structs round-trip
        for x in (
                    Ordered(0x0102030405060708, 0x090a0b0c, 0x0d0e, 0x0f, 0x10),
                    ExplicitPadding(0x01020304, 0x00000000, 0x05060708090a0b0c),
                    WithU256Aligned(reinterpret(U256, ntuple(UInt8, 32)), 0x01, 0x02),
                ), e in (LittleEndian(), BigEndian())
            buf = zeros(UInt8, sizeof(x))
            @test encode!(buf, x, e) == sizeof(x)
            @test decode(buf, typeof(x), e) === x
        end
        # Not opted in: no codec
        @test_throws MethodError max_encoded_size(Plain, LittleEndian())
    end

    @testset "@inbounds" begin
        mem = MemoryView([0x01, 0x02, 0x03, 0x04, 0x05])
        # `@inbounds` only has an effect if the call is inlined, so the functions must
        # specialize on the type.
        decode_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds decode(mem, i, T, e)
        try_decode_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds try_decode(mem, i, T, e)
        next_inbounds(mem, i, ::Type{T}, e) where {T} = @inbounds try_decode_next(mem, i, T, e)
        encode_inbounds!(mem, i, x, e) = @inbounds encode!(mem, i, x, e)
        try_encode_inbounds!(mem, i, x, e) = @inbounds try_encode!(mem, i, x, e)
        start_inbounds(mem, ::Type{T}, e) where {T} = @inbounds decode(mem, T, e)
        little_inbounds(mem, i) = @inbounds Little.decode_next(mem, i, UInt16)

        # In bounds, the results are the same as without `@inbounds`
        for (T, e) in CODEC_CASES, i in 1:(length(mem) + 1 - max_encoded_size(T, e))
            @test isequal(try_decode_inbounds(mem, i, T, e), try_decode(mem, i, T, e))
            @test isequal(next_inbounds(mem, i, T, e), try_decode_next(mem, i, T, e))
        end
        @test decode_inbounds(mem, 2, UInt32, BigEndian()) === 0x02030405
        @test start_inbounds(mem, UInt16, BigEndian()) === 0x0102
        @test little_inbounds(mem, 4) === (0x0504, 6)
        v = zeros(UInt8, 6)
        @test encode_inbounds!(MemoryView(v), 3, 0x01020304, BigEndian()) === 4
        @test v == [0x00, 0x00, 0x01, 0x02, 0x03, 0x04]
        @test try_encode_inbounds!(MemoryView(v), 1, 0x0807, LittleEndian()) === 2
        @test v == [0x07, 0x08, 0x01, 0x02, 0x03, 0x04]

        # The data is still validated
        @test_throws DecodeError(InvalidData) decode_inbounds(MemoryView([0x02]), 1, Bool, LittleEndian())
        @test_throws DecodeError(InvalidData) decode_inbounds(MemoryView([0x00, 0x00]), 1, Fruit, LittleEndian())
        @test_throws DecodeError(InvalidData) decode_inbounds(MemoryView([0x00, 0x00, 0x02, 0x03]), 1, Flagged, BigEndian())
        @test try_decode_inbounds(MemoryView([0x02]), 1, Bool, LittleEndian()) === DecodeError(InvalidData)
        @test try_decode_inbounds(MemoryView([0x00, 0x00]), 1, Fruit, LittleEndian()) === DecodeError(InvalidData)
        @test try_decode_inbounds(MemoryView([0x00, 0x00, 0x02, 0x03]), 1, Flagged, BigEndian()) === DecodeError(InvalidData)

        # The checks of a hand-written codec are its own, and always run
        @test try_decode(MemoryView([0x00]), Bool, Probe()) === true
        @test try_decode_inbounds(MemoryView([0x00]), 1, Bool, Probe()) === true
        v = zeros(UInt8, 1)
        @test encode_inbounds!(MemoryView(v), 1, false, Probe()) === 1
        @test v == [0x01]
        # `store` skips its redundant length check, but not those of a codec
        io = VecWriter()
        @test store(io, false, Probe()) == 1
        @test io.vec == [0x01]

        if ELIDES_BOUNDSCHECKS
            # The length checks of the throwing functions are skipped. This breaks the
            # contract of `@inbounds`, which is only memory-safe here because the views
            # are within a larger memory.
            backing = MemoryView([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            short = backing[3:4]
            @test try_decode(short, 2, UInt32, BigEndian()) === DecodeError(Truncated)
            # The `try_` functions ignore `@inbounds`
            @test try_decode_inbounds(short, 2, UInt32, BigEndian()) === DecodeError(Truncated)
            @test next_inbounds(short, 2, UInt32, BigEndian()) === DecodeError(Truncated)
            @test try_decode_inbounds(short, 3, UInt32, BigEndian()) === DecodeError(EndOfInput)
            @test_throws LightBoundsError try_decode_inbounds(short, 0, UInt32, BigEndian())
            @test try_encode_inbounds!(backing[1:2], 2, 0xaabbccdd, BigEndian()) === EncodeError(InsufficientSpace)
            @test_throws LightBoundsError try_encode_inbounds!(backing[1:2], 4, 0xaabbccdd, BigEndian())
            @test decode_inbounds(short, 3, UInt16, BigEndian()) === 0x0506
            @test start_inbounds(short, UInt32, LittleEndian()) === 0x06050403
            @test little_inbounds(short, 2) === (0x0504, 4)
            @test try_encode!(backing[1:2], 2, 0xaabbccdd, BigEndian()) === EncodeError(InsufficientSpace)
            @test_throws LightBoundsError encode!(backing[1:2], 2, 0xaabbccdd, BigEndian())
            @test encode_inbounds!(backing[1:2], 2, 0xa1b1c1d1, BigEndian()) === 4
            @test collect(backing) == [0x01, 0xa1, 0xb1, 0xc1, 0xd1, 0x06, 0x07, 0x08]
        end
    end

    @testset "Codec contract checks" begin
        decode_inbounds(mem, ::Type{T}, e) where {T} = @inbounds decode(mem, T, e)
        encode_inbounds!(mem, x, e) = @inbounds encode!(mem, x, e)
        mem = MemoryView(zeros(UInt8, 10))
        for T in (Int8, Int16)
            @test_throws ErrorException try_decode(mem, T, Liar())
            @test_throws ErrorException try_decode_next(mem, 1, T, Liar())
            @test_throws ErrorException decode_inbounds(mem, T, Liar())
            @test_throws ErrorException decode_into!(MemoryView(zeros(T, 3)), mem, Liar())
            @test_throws ErrorException try_encode!(mem, zero(T), Liar())
            @test_throws ErrorException encode_inbounds!(mem, zero(T), Liar())
            @test_throws ErrorException encode_into!(mem, MemoryView(zeros(T, 3)), Liar())
            # Nothing is consumed from the reader or writer
            io = CursorReader(zeros(UInt8, 10))
            @test_throws ErrorException try_load(io, T, Liar())
            @test_throws ErrorException load_into!(io, MemoryView(zeros(T, 3)), Liar())
            @test load_all!(io, MemoryView(zeros(UInt8, 20)), LittleEndian()) == 10
            io = VecWriter()
            @test_throws ErrorException store(io, zero(T), Liar())
            @test_throws ErrorException store_all(io, MemoryView(zeros(T, 3)), Liar())
            @test isempty(io.vec)
        end
        # Only counts outside `mem` are caught
        @test try_decode_next(mem, 1, UInt8, Liar()) === (0x00, 4)
        @test try_encode!(mem, 0x00, Liar()) === 3
        @test_throws ErrorException try_decode(MemoryView(zeros(UInt8, 2)), UInt8, Liar())
        msg = try
            try_decode(mem, Int16, Liar())
        catch e
            sprint(showerror, e)
        end
        @test occursin("`codec_try_decode` for `Int16` with `Liar()` broke its contract", msg)
        @test occursin("byte count of -1", msg)
    end

    @testset "Memory-like arguments" begin
        bytes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
        mem = MemoryView(bytes)
        # The same results as with a `MemoryView`
        for b in (bytes, Memory{UInt8}(bytes), view(bytes, 1:6))
            @test try_decode(b, UInt32, BigEndian()) === try_decode(mem, UInt32, BigEndian())
            @test try_decode(b, 3, UInt32, BigEndian()) === try_decode(mem, 3, UInt32, BigEndian())
            @test try_decode(b, 4, UInt32, BigEndian()) === DecodeError(Truncated)
            @test decode(b, UInt16, LittleEndian()) === 0x0201
            @test decode(b, 5, UInt16, LittleEndian()) === 0x0605
            @test try_decode_next(b, 2, UInt16, BigEndian()) === (0x0203, 4)
            @test decode_next(b, 5, UInt16, BigEndian()) === (0x0506, 7)
        end
        @test decode(view(bytes, 3:6), UInt16, BigEndian()) === 0x0304
        v = zeros(UInt8, 5)
        @test try_encode!(v, 0x0102, BigEndian()) === 2
        @test try_encode!(v, 4, 0x0304, BigEndian()) === 2
        @test try_encode!(v, 5, 0x0304, BigEndian()) === EncodeError(InsufficientSpace)
        @test v == [0x01, 0x02, 0x00, 0x03, 0x04]
        @test encode!(view(v, 2:5), 'é', UTF8()) === 2
        @test encode!(v, 5, 0x09, BigEndian()) === 1
        @test v == [0x01, 0xc3, 0xa9, 0x03, 0x09]

        # Bulk functions
        dst = zeros(UInt16, 3)
        @test decode_into!(dst, bytes, LittleEndian()) == (3, 6)
        @test dst == [0x0201, 0x0403, 0x0605]
        out = zeros(UInt8, 6)
        @test encode_into!(out, dst, BigEndian()) == (3, 6)
        @test out == [0x02, 0x01, 0x04, 0x03, 0x06, 0x05]
        dst = zeros(UInt16, 2)
        @test load_into!(CursorReader(bytes), dst, LittleEndian()) == 2
        @test dst == [0x0201, 0x0403]
        dst = zeros(UInt16, 4)
        @test load_all!(CursorReader(bytes), dst, BigEndian()) == 3
        @test dst[1:3] == [0x0102, 0x0304, 0x0506]
        # `load!` returns its argument itself
        dst = zeros(UInt16, 3)
        @test load!(CursorReader(bytes), dst, BigEndian()) === dst
        @test dst == [0x0102, 0x0304, 0x0506]
        io = VecWriter()
        @test store_all(io, ['a', 'é'], UTF8()) == 3
        @test io.vec == [0x61, 0xc3, 0xa9]
        # The convenience modules
        @test Little.decode(bytes, 2, UInt16) === 0x0302
        @test Big.load!(CursorReader(bytes), zeros(UInt16, 3)) == [0x0102, 0x0304, 0x0506]

        # Strings are not converted implicitly, since that allocates
        s = "abcdef"
        for x in (s, SubString(s, 2), codeunits(s))
            @test_throws ArgumentError try_decode(x, UInt8, LittleEndian())
            @test_throws ArgumentError decode(x, 2, UInt8, LittleEndian())
            @test_throws ArgumentError try_decode_next(x, 1, Char, UTF8())
            @test_throws ArgumentError decode_into!(zeros(UInt8, 2), x, LittleEndian())
            @test_throws ArgumentError store_all(VecWriter(), x, LittleEndian())
        end
        @test_throws ArgumentError encode_into!(zeros(UInt8, 4), "ab", UTF8())
        # Memory of the wrong element type or mutability is an error, not an infinite
        # recursion
        @test_throws TypeError try_decode(Int8[1, 2], UInt8, LittleEndian())
        @test_throws TypeError try_decode(MemoryView(Int8[1, 2]), UInt8, LittleEndian())
        @test_throws TypeError encode!(ImmutableMemoryView(zeros(UInt8, 2)), 0x01, LittleEndian())
        @test_throws TypeError decode_into!(ImmutableMemoryView(zeros(UInt8, 2)), bytes, LittleEndian())
        @test_throws TypeError load!(CursorReader(bytes), ImmutableMemoryView(zeros(UInt16, 2)), LittleEndian())
        # Not memory at all
        @test_throws MethodError try_decode(0x01:0x05, UInt8, LittleEndian())

        # Converting a `Vector` doesn't allocate
        decode_vector(v, i) = decode(v, i, UInt32, LittleEndian())
        encode_vector!(v, x) = encode!(v, 2, x, BigEndian())
        decode_vector(bytes, 2)
        encode_vector!(v, 0x0102)
        @test (@allocated decode_vector(bytes, 2)) == 0
        @test (@allocated encode_vector!(v, 0x0102)) == 0
    end

    @testset "No method ambiguities" begin
        @test isempty(Test.detect_ambiguities(BitScribbling; recursive = true))
    end

    @testset "Little and Big" begin
        for (M, E) in ((Little, LittleEndian()), (Big, BigEndian()))
            bytes = [0x01, 0x02, 0x03, 0x04, 0x05]
            @test M.try_decode(MemoryView(bytes), UInt32) === try_decode(MemoryView(bytes), UInt32, E)
            @test M.decode(MemoryView(bytes), UInt16) === decode(MemoryView(bytes), UInt16, E)
            @test M.try_decode(MemoryView(bytes), 2, UInt32) === try_decode(MemoryView(bytes), 2, UInt32, E)
            @test M.decode(MemoryView(bytes), 4, UInt16) === decode(MemoryView(bytes), 4, UInt16, E)
            @test M.try_decode_next(MemoryView(bytes), 2, UInt32) === try_decode_next(MemoryView(bytes), 2, UInt32, E)
            @test M.decode_next(MemoryView(bytes), 4, UInt16) === decode_next(MemoryView(bytes), 4, UInt16, E)
            a = zeros(UInt8, 4)
            b = zeros(UInt8, 4)
            @test M.encode!(MemoryView(a), 0x0102) == encode!(MemoryView(b), 0x0102, E)
            @test a == b
            @test M.encode!(MemoryView(a), 3, 0x0304) == encode!(MemoryView(b), 3, 0x0304, E)
            @test a == b
            @test M.try_encode!(MemoryView(a), 0x0506) == try_encode!(MemoryView(b), 0x0506, E)
            @test a == b
            @test M.try_encode!(MemoryView(a), 4, 0x0708) === try_encode!(MemoryView(b), 4, 0x0708, E) === EncodeError(InsufficientSpace)
            @test M.load(CursorReader(bytes), UInt32) === load(CursorReader(bytes), UInt32, E)
            @test M.try_load(CursorReader(bytes), UInt64) === DecodeError(Truncated)
            w1 = VecWriter()
            w2 = VecWriter()
            @test M.store(w1, 0x0102) == store(w2, 0x0102, E)
            @test M.try_store(w1, 0x0304) === try_store(w2, 0x0304, E) === 2
            @test M.try_encoded_size(0x0102) === M.encoded_size(0x0102) === 2
            @test M.store_all(w1, MemoryView(UInt16[1, 2])) == store_all(w2, MemoryView(UInt16[1, 2]), E)
            @test w1.vec == w2.vec
            d1 = zeros(UInt16, 3)
            d2 = zeros(UInt16, 3)
            @test M.decode_into!(MemoryView(d1), MemoryView(bytes)) == decode_into!(MemoryView(d2), MemoryView(bytes), E)
            @test d1 == d2
            @test M.encode_into!(MemoryView(a), MemoryView(d1)) == encode_into!(MemoryView(b), MemoryView(d2), E)
            @test a == b
            @test M.load_into!(CursorReader(bytes), MemoryView(d1)) == load_into!(CursorReader(bytes), MemoryView(d2), E)
            @test M.load_all!(CursorReader(bytes), MemoryView(d1)) == load_all!(CursorReader(bytes), MemoryView(d2), E)
            @test d1 == d2
        end
        @test_throws MethodError Little.store(VecWriter(), 'a')
    end

    @testset "DecodeError" begin
        @test isbitstype(DecodeError)
        @test sizeof(DecodeError) == 1
        @test DecodeError <: Exception
        for kind in (EndOfInput, Truncated, InvalidData)
            str = sprint(showerror, DecodeError(kind))
            @test startswith(str, "DecodeError: ")
        end
    end

    @testset "EncodeError" begin
        @test isbitstype(EncodeError)
        @test sizeof(EncodeError) == 1
        @test EncodeError <: Exception
        for kind in (InsufficientSpace, InvalidValue)
            str = sprint(showerror, EncodeError(kind))
            @test startswith(str, "EncodeError: ")
        end
    end

    @testset "Allocations" begin
        function sum_loads(io)
            s = UInt64(0)
            while true
                x = try_load(io, UInt32, BigEndian())
                x isa DecodeError && break
                s += x
            end
            return s
        end
        function sum_chars(io)
            s = UInt32(0)
            while true
                x = try_load(io, Char, UTF8())
                x isa DecodeError && break
                s += reinterpret(UInt32, x)
            end
            return s
        end
        store_loop(io, n) = (
            for i in 1:n
                store(io, i % UInt32, LittleEndian())
            end; nothing
        )
        data = rand(UInt8, 1001)
        sum_loads(CursorReader(data))
        sum_chars(CursorReader(data))
        @test (@allocated sum_loads(CursorReader(data))) ≤ 64 # the reader itself
        @test (@allocated sum_chars(CursorReader(data))) ≤ 64
        io = VecWriter(sizehint!(UInt8[], 4000))
        store_loop(io, 1)
        empty!(io.vec)
        @test (@allocated store_loop(io, 900)) == 0
        function sum_indexed(mem)
            s = UInt64(0)
            i = 1
            while i ≤ length(mem) - 3
                s += @inbounds decode(mem, i, UInt32, LittleEndian())
                s += decode(mem, i, UInt32, BigEndian())
                i += 4
            end
            return s
        end
        sum_indexed(ImmutableMemoryView(data))
        @test (@allocated sum_indexed(ImmutableMemoryView(data))) == 0
        bulk_allocs(dst, mem) = @allocated decode_into!(dst, mem, BigEndian())
        dst = MemoryView(zeros(UInt32, 250))
        mem = ImmutableMemoryView(data)
        bulk_allocs(dst, mem)
        @test bulk_allocs(dst, mem) == 0
        # Returning an `EncodeError` doesn't allocate
        function count_invalid(io, chars)
            k = 0
            for c in chars
                try_store(io, c, Latin1()) isa EncodeError && (k += 1)
            end
            return k
        end
        chars = MemoryView(rand(['a', 'λ'], 100))
        io = VecWriter(sizehint!(UInt8[], 200))
        count_invalid(io, chars)
        @test (@allocated count_invalid(io, chars)) == 0
    end

    @testset "Doctests" begin
        using Documenter: DocMeta, doctest
        DocMeta.setdocmeta!(
            BitScribbling, :DocTestSetup, :(using BitScribbling, BufferIO; using MemoryViews: MemoryView);
            recursive = true,
        )
        doctest(BitScribbling; manual = false)
    end

end # testset BitScribbling
