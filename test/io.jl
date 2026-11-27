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
    @test err == DecodeError(EndOfInput)

    # Values straddling fills
    data = collect(UInt8, 1:64)
    for max_fill in 1:9, T in (UInt8, UInt16, UInt32, UInt64, UInt128)
        io = BoundedReader(data, 16; max_fill)
        expected = reinterpret(T, data)
        @test [load(io, T, LittleEndian()) for _ in expected] == ltoh.(expected)
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

@testset "@?" begin
    function load_pair(io)
        a = @? try_load(io, UInt16, BigEndian())
        b = @? try_load(io, Bool, BigEndian())
        return (a, b)
    end
    @test load_pair(CursorReader([0x00, 0x01, 0x01])) === (0x0001, true)
    @test is_err(load_pair(CursorReader([0x00, 0x01, 0x02])), InvalidData)
    @test is_err(load_pair(CursorReader([0x00])), Truncated)
    @test is_err(load_pair(CursorReader(UInt8[])), EndOfInput)

    function decode_pair(mem)
        (a, i) = @? try_decode_next(mem, 1, UInt8, LittleEndian())
        b = @? try_decode(mem, i, UInt8, LittleEndian())
        return a + b
    end
    @test decode_pair(MemoryView([0x01, 0x02])) === 0x03
    @test is_err(decode_pair(MemoryView([0x01])), EndOfInput)

    function encode_pair!(mem, a, b)
        n = @? try_encode!(mem, a, BigEndian())
        m = @? try_encode!(mem, 1 + n, b, BigEndian())
        return n + m
    end
    v = zeros(UInt8, 3)
    @test encode_pair!(MemoryView(v), 0x01, 0x0203) === 3
    @test v == [0x01, 0x02, 0x03]
    @test encode_pair!(MemoryView(zeros(UInt8, 2)), 0x01, 0x0203) == EncodeError(InsufficientSpace)
end
