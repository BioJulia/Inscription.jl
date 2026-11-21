@testset "Indices" begin
    # Decoding at an index is decoding from the slice. The indices of one input cover
    # every number of remaining bytes, from none to more than `max_encoded_size`. Random
    # bytes are mostly invalid for some types, so valid encodings are tested too.
    for (T, e, x0) in CODEC_CASES
        m = max_encoded_size(T, e)
        len = 2m + 1
        for bytes in (rand(UInt8, len), rand(UInt8, len), first(repeat(encoding(x0, e), len), len))
            mem = MemoryView(bytes)
            for i in 1:(len + 1)
                expected = try_decode_n(mem[i:end], T, e)
                expected_next = expected isa DecodeError ? expected : (expected[1], i + expected[2])
                @test isequal(try_decode_next(mem, i, T, e), expected_next)
                @test isequal(try_decode_next(ImmutableMemoryView(mem), i, T, e), expected_next)
                # Decoding exactly is decoding, and checking that no bytes remain
                exact = if expected isa DecodeError
                    expected
                elseif expected[2] == len - i + 1
                    expected[1]
                else
                    DecodeError(TrailingData)
                end
                @test isequal(try_decode_exact(mem, i, T, e), exact)
                @test isequal(try_decode_exact(mem[i:end], T, e), exact)
                if exact isa DecodeError
                    @test_throws exact decode_exact(mem, i, T, e)
                else
                    @test isequal(decode_exact(mem, i, T, e), exact)
                end
                # ... and so is loading exactly, which consumes nothing on errors
                io = CursorReader(collect(mem[i:end]))
                @test isequal(try_load_exact(io, len - i + 1, T, e), exact)
                @test length(get_buffer(io)) == (exact isa DecodeError ? len - i + 1 : 0)
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
                # With `max_encoded_size` bytes, encoding succeeds, and writes the
                # same number of bytes as into longer memory
                @test try_encode!(MemoryView(zeros(UInt8, m)), x, e) === try_encode!(SCRATCH, x, e)
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
            @test_throws LightBoundsError try_decode_exact(mem, i, T, e)
            @test_throws LightBoundsError decode_exact(mem, i, T, e)
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
        # Every number of bytes before the index, and after it
        len = 2 * max_encoded_size(typeof(x), e)
        for i in 1:(len + 1)
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
            (_, n_bytes) = encode_all!(MemoryView(buf), MemoryView(src), e)
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

@testset "Exact decoding and loading" begin
    @test try_decode_exact(MemoryView([0x01, 0x02]), UInt16, BigEndian()) === 0x0102
    @test try_decode_exact(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian()) === DecodeError(TrailingData)
    @test try_decode_exact(MemoryView([0x01]), UInt16, BigEndian()) === DecodeError(Truncated)
    @test try_decode_exact(MemoryView(UInt8[]), UInt16, BigEndian()) === DecodeError(EndOfInput)
    # The errors of decoding come first
    @test try_decode_exact(MemoryView([0x02, 0x00]), Bool, LittleEndian()) === DecodeError(InvalidData)
    @test_throws DecodeError(TrailingData) decode_exact(MemoryView([0x01, 0x02, 0x03]), UInt16, BigEndian())
    @test_throws DecodeError(InvalidData) decode_exact(MemoryView([0x02, 0x00]), Bool, LittleEndian())
    # Variable-length encodings
    @test try_decode_exact(MemoryView("€"), Char, UTF8()) === '€'
    @test try_decode_exact(MemoryView("€a"), Char, UTF8()) === DecodeError(TrailingData)
    @test try_decode_exact(MemoryView("a€"), 2, Char, UTF8()) === '€'
    @test decode_exact(MemoryView("\xe2\x82"), Char, UTF8()) === '\xe2\x82'
    # Memory that `MemoryView` can view
    @test try_decode_exact([0x01, 0x02], UInt16, BigEndian()) === 0x0102
    @test decode_exact([0x00, 0x01, 0x02], 2, UInt16, BigEndian()) === 0x0102
    @test_throws ArgumentError try_decode_exact("ab", UInt16, BigEndian())

    io = CursorReader([0x00, 0x01, 0x02, 0x03, 0x04])
    @test try_load_exact(io, 2, UInt16, BigEndian()) === 0x0001
    @test try_load_exact(io, 3, UInt16, BigEndian()) === DecodeError(TrailingData)
    @test try_load_exact(io, 1, UInt16, BigEndian()) === DecodeError(Truncated)
    # EOF within the bytes
    @test try_load_exact(io, 4, UInt8, BigEndian()) === DecodeError(Truncated)
    @test length(get_buffer(io)) == 3 # nothing consumed
    @test_throws DecodeError(TrailingData) load_exact(io, 2, UInt8, BigEndian())
    @test load_exact(io, 1, UInt8, BigEndian()) === 0x02
    @test load_exact(io, 2, UInt16, BigEndian()) === 0x0304
    @test try_load_exact(io, 1, UInt8, BigEndian()) === DecodeError(EndOfInput)
    @test try_load_exact(io, 0, UInt8, BigEndian()) === DecodeError(EndOfInput)
    @test_throws ArgumentError try_load_exact(io, -1, UInt8, BigEndian())
    # Invalid data is not consumed
    io = CursorReader([0x02, 0x01])
    @test try_load_exact(io, 1, Bool, LittleEndian()) === DecodeError(InvalidData)
    @test length(get_buffer(io)) == 2
    # Bytes straddling fills
    io = ChunkedReader([[0xe2], [0x82], [0xac, 0x61]])
    @test try_load_exact(io, 3, Char, UTF8()) === '€'
    @test try_load_exact(io, 1, Char, UTF8()) === 'a'
    @test try_load_exact(io, 1, Char, UTF8()) === DecodeError(EndOfInput)
    for max_fill in 1:5
        io = BoundedReader(collect(UInt8, 1:12), 6; max_fill)
        @test [load_exact(io, 4, UInt32, BigEndian()) for _ in 1:3] == [0x01020304, 0x05060708, 0x090a0b0c]
    end
    # More bytes than the buffer capacity
    @test_throws IOError try_load_exact(BoundedReader(zeros(UInt8, 8), 2), 4, UInt32, LittleEndian())
    # More bytes than `max_encoded_size`
    @test try_load_exact(CursorReader(zeros(UInt8, 8)), 8, UInt32, LittleEndian()) === DecodeError(TrailingData)
end
