using Test
using BufferSerde
using BufferSerde: DecodeErrorKinds, Little, Big
using BufferSerde: bits_kind, BitsLoadable, BitsStorable, ManualCodec, is_valid_bits, as_unsigned
using BufferSerde.DecodeErrorKinds: EndOfInput, Truncated, InvalidData
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
BufferSerde.bits_kind(::Type{U24}) = BitsLoadable()
primitive type U144 144 end
BufferSerde.bits_kind(::Type{U144}) = BitsLoadable()
# The top bit must be zero
primitive type S24 24 end
BufferSerde.bits_kind(::Type{S24}) = BitsStorable()
BufferSerde.is_valid_bits(::Type{S24}, bytes::NTuple{3, UInt8}) = as_unsigned(bytes) < 0x00800000
# Wider than the largest unsigned integer. The top bit must be zero.
primitive type S144 144 end
BufferSerde.bits_kind(::Type{S144}) = BitsStorable()
function BufferSerde.is_valid_bits(::Type{S144}, bytes::NTuple{18, UInt8})
    top = NATIVE_ENDIAN === LittleEndian() ? bytes[18] : bytes[1]
    return top < 0x80
end
# BitsStorable, but doesn't implement `is_valid_bits`
primitive type NoCheck16 16 end
BufferSerde.bits_kind(::Type{NoCheck16}) = BitsStorable()

# The trait can't be declared for types that are neither primitive types nor isbits structs
struct Boxed
    x::Vector{UInt8}
end
BufferSerde.bits_kind(::Type{Boxed}) = BitsLoadable()

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
        BufferSerde.bits_kind(::Type{U22}) = BitsLoadable()
        primitive type U5 5 end
        BufferSerde.bits_kind(::Type{U5}) = BitsLoadable()
        # Encoded in 4 bytes, so loaded as a UInt32
        primitive type U30 30 end
        BufferSerde.bits_kind(::Type{U30}) = BitsLoadable()
        # Encoded in 4 bytes, so loaded as a UInt32. The top bit must be zero.
        primitive type S30 30 end
        BufferSerde.bits_kind(::Type{S30}) = BitsStorable()
        BufferSerde.is_valid_bits(::Type{S30}, bytes::NTuple{4, UInt8}) = as_unsigned(bytes) < 0x20000000
        # All ones is invalid
        primitive type S12 12 end
        BufferSerde.bits_kind(::Type{S12}) = BitsStorable()
        BufferSerde.is_valid_bits(::Type{S12}, bytes::NTuple{2, UInt8}) = as_unsigned(bytes) != 0x0fff

        # The design's example of a hand-written codec for a narrow type
        primitive type U29 29 end
        U29(x::UInt32) = Core.Intrinsics.trunc_int(U29, x)
        Base.UInt32(x::U29) = Core.Intrinsics.zext_int(UInt32, x)
        BufferSerde.codec_max_encoded_size(::Type{U29}, ::Endianness) = 4
        function BufferSerde.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{U29}, e::Endianness)
            raw = @try_return try_decode(mem, UInt32, e)
            raw > 0x1fffffff && return DecodeError(InvalidData)
            return (U29(raw), 4)
        end
        function BufferSerde.codec_encode!(mem::MutableMemoryView{UInt8}, x::U29, e::Endianness)
            return try_encode!(mem, UInt32(x), e)
        end
    end
end

# A custom encoding defined by a format package
struct CBool <: Encoding end
BufferSerde.codec_max_encoded_size(::Type{Bool}, ::CBool) = 1
function BufferSerde.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Bool}, ::CBool)
    isempty(mem) && return DecodeError(EndOfInput)
    return (!iszero(mem[1]), 1)
end
function BufferSerde.codec_encode!(mem::MutableMemoryView{UInt8}, x::Bool, ::CBool)
    isempty(mem) && return nothing
    mem[1] = x
    return 1
end

# A codec that reports whether its own `@boundscheck` blocks ran. `@inbounds` at the call
# of `try_decode` or `encode!` must not reach into the codec.
struct Probe <: Encoding end
BufferSerde.codec_max_encoded_size(::Type{Bool}, ::Probe) = 1
@inline function BufferSerde.codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{Bool}, ::Probe)
    isempty(mem) && return DecodeError(EndOfInput)
    checked = false
    @boundscheck checked = true
    return (checked, 1)
end
@inline function BufferSerde.codec_encode!(mem::MutableMemoryView{UInt8}, ::Bool, ::Probe)
    isempty(mem) && return nothing
    checked = false
    @boundscheck checked = true
    @inbounds mem[1] = checked
    return 1
end

# Structs that opt in
struct Header
    magic::UInt32
    version::UInt16
    flags::UInt8
    kind::UInt8
end
BufferSerde.bits_kind(::Type{Header}) = BitsLoadable()
struct Nested
    header::Header
    x::Float32
    y::Int16
    z::Int16
end
BufferSerde.bits_kind(::Type{Nested}) = BitsLoadable()
# The fields are checked, and then that the fruit is `apple` unless `on`
struct Flagged
    on::Bool
    other::UInt8
    fruit::Fruit
end
BufferSerde.bits_kind(::Type{Flagged}) = BitsStorable()
function BufferSerde.is_valid_bits(::Type{Flagged}, bytes::NTuple{4, UInt8})
    x = reinterpret(Flagged, bytes)
    return x.on || x.fruit === apple
end
struct Outer
    a::Flagged
    b::Flagged
end
BufferSerde.bits_kind(::Type{Outer}) = BitsStorable()
BufferSerde.is_valid_bits(::Type{Outer}, ::NTuple{8, UInt8}) = true
struct Empty end
BufferSerde.bits_kind(::Type{Empty}) = BitsLoadable()

# Structs that can't be bits types
struct Padded
    a::UInt8
    b::UInt32
end
BufferSerde.bits_kind(::Type{Padded}) = BitsLoadable()
struct LoadableWithBool
    a::Bool
end
BufferSerde.bits_kind(::Type{LoadableWithBool}) = BitsLoadable()
struct WithChar
    c::Char
end
BufferSerde.bits_kind(::Type{WithChar}) = BitsLoadable()
# Doesn't opt in
struct Plain
    x::UInt32
end
struct WithPlain
    p::Plain
end
BufferSerde.bits_kind(::Type{WithPlain}) = BitsLoadable()
struct WithPadded
    p::Padded
end
BufferSerde.bits_kind(::Type{WithPadded}) = BitsLoadable()
if HAS_NARROW
    @eval begin
        struct WithNarrow
            x::U30
        end
        BufferSerde.bits_kind(::Type{WithNarrow}) = BitsLoadable()
    end
end

# Pairs of a type and an encoding, covering every kind of codec
const CODEC_CASES = let
    types = (BITS_TYPES..., Bool, Fruit, Small, Signs, U24, S24, U144, S144, Header, Nested, Flagged, Outer, Empty)
    cases = Any[(T, e) for T in types for e in (LittleEndian(), BigEndian())]
    push!(cases, (Char, UTF8()), (Bool, CBool()))
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

@testset "BufferSerde" begin

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
                @test try_encode!(MemoryView(zeros(UInt8, sizeof(T) - 1)), x, e) === nothing
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

        # Accepts memory views of either mutability, and only memory views
        @test try_decode(ImmutableMemoryView([0x01, 0x02]), UInt16, BigEndian()) === 0x0102
        @test try_decode(MemoryView([0x01, 0x02]), UInt16, BigEndian()) === 0x0102
        @test try_decode(MemoryView(b"\x01\x02"), UInt16, BigEndian()) === 0x0102
        @test decode(MemoryView("\x01\x02"), UInt16, BigEndian()) === 0x0102
        @test_throws MethodError try_decode([0x01, 0x02], UInt16, BigEndian())
        @test_throws MethodError decode([0x01, 0x02], UInt16, BigEndian())
        @test_throws MethodError decode_next([0x01, 0x02], 1, UInt16, BigEndian())
        @test_throws MethodError decode_next(MemoryView([0x01, 0x02]), UInt16, BigEndian())
        v = zeros(UInt8, 2)
        @test encode!(MemoryView(v), 0x0102, BigEndian()) == 2
        @test v == [0x01, 0x02]
        @test_throws MethodError encode!(v, 0x0102, BigEndian())
        @test_throws MethodError encode!(ImmutableMemoryView(v), 0x0102, BigEndian())
        @test_throws MethodError try_encode!(v, 0x0102, BigEndian())
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
        @test try_encode!(MemoryView(zeros(UInt8, n - 1)), x, LittleEndian()) === nothing
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
            for len in 0:6
                buf = fill(0xaa, len)
                n = try_encode!(MemoryView(buf), c, UTF8())
                if len < ncodeunits(c)
                    @test n === nothing
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

        # Only memory views are accepted
        @test_throws MethodError decode_into!(zeros(UInt8, 2), MemoryView([0x01]), LittleEndian())
        @test_throws MethodError decode_into!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian())
        @test_throws MethodError encode_into!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian())
        @test_throws MethodError load_into!(CursorReader([0x01]), zeros(UInt8, 1), LittleEndian())
        @test_throws MethodError store_all(VecWriter(), [0x01], LittleEndian())

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
        @test try_encode!(mem, 6, 0x01, BigEndian()) === nothing
        @test try_encode!(mem, 3, 0x01020304, BigEndian()) === nothing
        @test try_encode!(mem, 6, 'a', UTF8()) === nothing
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
        for T in (Padded, LoadableWithBool, WithChar, WithPlain, WithPadded, (HAS_NARROW ? (WithNarrow,) : ())...)
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
        @test occursin("3 bytes of padding", message(Padded))
        @test occursin("`LoadableWithBool` is `BitsLoadable`, but its field `a` has the type `Bool`, which is `BitsStorable`", message(LoadableWithBool))
        @test occursin("field `c` of `WithChar` has the type `Char`, whose `bits_kind` is `ManualCodec`", message(WithChar))
        @test occursin("field `p` of `WithPlain` has the type `Plain`", message(WithPlain))
        @test occursin("`Padded` has 3 bytes of padding", message(WithPadded))
        HAS_NARROW && @test occursin("whose bits don't fill its bytes", message(WithNarrow))
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
            # The length checks are skipped. This breaks the contract of `@inbounds`, which
            # is only memory-safe here because the views are within a larger memory.
            backing = MemoryView([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            short = backing[3:4]
            @test try_decode(short, 2, UInt32, BigEndian()) === DecodeError(Truncated)
            @test try_decode_inbounds(short, 2, UInt32, BigEndian()) === 0x04050607
            @test next_inbounds(short, 2, UInt32, BigEndian()) === (0x04050607, 6)
            @test decode_inbounds(short, 3, UInt16, BigEndian()) === 0x0506
            @test start_inbounds(short, UInt32, LittleEndian()) === 0x06050403
            @test little_inbounds(short, 2) === (0x0504, 4)
            @test try_encode!(backing[1:2], 2, 0xaabbccdd, BigEndian()) === nothing
            @test_throws LightBoundsError encode!(backing[1:2], 2, 0xaabbccdd, BigEndian())
            @test try_encode_inbounds!(backing[1:2], 2, 0xaabbccdd, BigEndian()) === 4
            @test encode_inbounds!(backing[1:2], 2, 0xa1b1c1d1, BigEndian()) === 4
            @test collect(backing) == [0x01, 0xa1, 0xb1, 0xc1, 0xd1, 0x06, 0x07, 0x08]
        end
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
            @test M.try_encode!(MemoryView(a), 4, 0x0708) === try_encode!(MemoryView(b), 4, 0x0708, E) === nothing
            @test M.load(CursorReader(bytes), UInt32) === load(CursorReader(bytes), UInt32, E)
            @test M.try_load(CursorReader(bytes), UInt64) === DecodeError(Truncated)
            w1 = VecWriter()
            w2 = VecWriter()
            @test M.store(w1, 0x0102) == store(w2, 0x0102, E)
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
    end

    @testset "Doctests" begin
        using Documenter: DocMeta, doctest
        DocMeta.setdocmeta!(
            BufferSerde, :DocTestSetup, :(using BufferSerde, BufferIO; using MemoryViews: MemoryView);
            recursive = true,
        )
        doctest(BufferSerde; manual = false)
    end

end # testset BufferSerde
