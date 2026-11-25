@testset "Encodings" begin
    @test NATIVE_ENDIAN === (ENDIAN_BOM == 0x04030201 ? LittleEndian() : BigEndian())
    @test LittleEndian() isa Endianness
    @test BigEndian() isa Endianness
    @test !(UTF8() isa Endianness)
    # No silently ignored arguments
    @test_throws ArgumentError store(VecWriter(), 'a', LittleEndian())
    @test_throws ArgumentError try_decode(MemoryView([0x61]), Char, BigEndian())
    @test_throws ArgumentError store(VecWriter(), 0x01, UTF8())
    @test_throws ArgumentError try_load(CursorReader([0x01]), UInt8, UTF8())
    @test_throws ArgumentError store(VecWriter(), Ptr{UInt8}(0), LittleEndian())
    @test_throws ArgumentError store(VecWriter(), ('a', 'b'), LittleEndian())
end

@testset "Codec schemes" begin
    for T in BITS_TYPES
        @test codec_scheme(T, LittleEndian()) === BitsLoadable()
    end
    @test codec_scheme(Bool, LittleEndian()) === BitsStorable()
    @test codec_scheme(Fruit, LittleEndian()) === BitsStorable()
    for T in (Char, Ptr{UInt8}, String, Tuple{Char, Char})
        @test codec_scheme(T, LittleEndian()) === Manual()
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
    @test_throws ArgumentError max_encoded_size(UInt32, UTF8())
    @test_throws ArgumentError max_encoded_size(Boxed, UTF8())
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
    # A value with distinct bytes shows their order, and `typemin` has the sign bit set
    for T in BITS_TYPES, x in (reinterpret(T, ntuple(UInt8, sizeof(T))), typemin(T))
        for (e, f) in ((LittleEndian(), bytes_le), (BigEndian(), bytes_be))
            bytes = f(x)
            @test max_encoded_size(T, e) == sizeof(T)
            @test try_encode!(SCRATCH, x, e) === encode!(SCRATCH, x, e) === sizeof(T)
            @test try_encode!(zeros(UInt8, sizeof(T) - 1), x, e) === EncodeError(InsufficientSpace)
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
    @test_throws ArgumentError try_decode(ImmutableMemoryView(v), String, BigEndian())
    @test_throws ArgumentError try_decode(MemoryView(v), String, BigEndian())
    @test_throws ArgumentError encode!(MemoryView(v), "abc", BigEndian())
    @test_throws ArgumentError try_encode!(MemoryView(v), "abc", BigEndian())
end

@testset "Bool" begin
    @test try_decode_n(MemoryView([0x00]), Bool, LittleEndian()) === (false, 1)
    @test try_decode_n(MemoryView([0x01]), Bool, BigEndian()) === (true, 1)
    for b in (0x02, 0x80, 0xff)
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
    # Every byte is a member, although `typemax - typemin` overflows
    for b in (0x00, 0x7f, 0x80, 0xff)
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
    @test decode_all!(dst, MemoryView(data), BigEndian()) == (2, 2n)
    @test all(==(value), map(low_bits, dst[1:2]))
    out = zeros(UInt8, 2n + 1)
    @test encode_all!(MemoryView(out), dst[1:2], BigEndian()) == (2, 2n)
    @test out[1:2n] == data[1:2n]
    io = ChunkedReader([[b] for b in data])
    @test load_all!(io, dst, BigEndian()) == (2, 2n)
    @test is_err(try_load(io, T, BigEndian()), n == 1 ? EndOfInput : Truncated)
    w = VecWriter()
    @test store(w, x, LittleEndian()) == n
    @test store_every(w, dst[1:2], LittleEndian()) == 2n
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
    @test decode_all!(MemoryView(Vector{S24}(undef, 3)), MemoryView([0x00, 0x00, 0x01, 0x00, 0x00, 0x80]), LittleEndian()) == (1, 3)
    # BitsStorable types wider than any integer
    test_odd_bits(S144, UInt8[1:17; 0x7f], reinterpret(UInt128, UInt8.(1:16))[1])
    @test is_err(try_decode(MemoryView([zeros(UInt8, 17); 0x80]), S144, LittleEndian()), InvalidData)
    @test is_err(try_decode(MemoryView([0x80; zeros(UInt8, 17)]), S144, BigEndian()), InvalidData)
    # BitsStorable without `is_valid_bits`
    @test_throws MethodError try_decode(MemoryView(zeros(UInt8, 2)), NoCheck16, LittleEndian())
end

HAS_NARROW && @testset "Primitive types narrower than whole bytes" begin
    # Rejected by the byte-order encodings
    for T in (U22, U5, U30, S12), e in (LittleEndian(), BigEndian())
        @test_throws ArgumentError max_encoded_size(T, e)
        @test_throws ArgumentError try_decode(MemoryView(zeros(UInt8, 8)), T, e)
        @test_throws ArgumentError decode_all!(MemoryView(Vector{T}(undef, 1)), MemoryView(zeros(UInt8, 8)), e)
        @test_throws ArgumentError try_load(CursorReader(zeros(UInt8, 8)), T, e)
    end
    x = Core.Intrinsics.trunc_int(U22, 0x00012345)
    @test_throws ArgumentError encode!(MemoryView(zeros(UInt8, 8)), x, LittleEndian())
    @test_throws ArgumentError try_encode!(SCRATCH, x, BigEndian())
    @test_throws ArgumentError store(VecWriter(), x, LittleEndian())
    message(T) =
    try
        max_encoded_size(T, LittleEndian())
    catch e
        sprint(showerror, e)
    end
    @test occursin("`codec_scheme(U22, LittleEndian())` is `BitsLoadable`, but the bit width 22 of `U22` is not a multiple of 8", message(U22))
    @test occursin("`codec_scheme(S12, LittleEndian())` is `BitsStorable`", message(S12))

    # The design's example of a hand-written codec
    io = CursorReader([0x01, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff])
    @test UInt32(load(io, U29, LittleEndian())) == 1
    @test is_err(try_load(io, U29, LittleEndian()), InvalidData)
    @test length(get_buffer(io)) == 4
    w = VecWriter()
    @test store(w, U29(0x1fffffff), BigEndian()) == 4
    @test w.vec == [0x1f, 0xff, 0xff, 0xff]
    dst = Vector{U29}(undef, 3)
    @test decode_all!(MemoryView(dst), MemoryView([0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x07, 0xff]), BigEndian()) == (2, 8)
    @test UInt32.(dst[1:2]) == [5, 7]
end
