@testset "decode_all! / encode_all!" begin
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
        @test encode_all!(MemoryView(bytes)[2:end], MemoryView(values), e) == (37, 37 * sizeof(T))
        @test isequal([try_decode(MemoryView(bytes), 2 + (i - 1) * sizeof(T), T, e) for i in 1:37], values)
        dst = Vector{T}(undef, 40)
        src = MemoryView(bytes)[2:(1 + 37 * sizeof(T))]
        @test decode_all!(MemoryView(dst), src, e) == (37, 37 * sizeof(T))
        @test isequal(dst[1:37], values)
        # Limited by dst
        dst = Vector{T}(undef, 10)
        @test decode_all!(MemoryView(dst), MemoryView(bytes)[2:end], e) == (10, 10 * sizeof(T))
        @test isequal(dst, values[1:10])
        # Limited by dst bytes
        out = zeros(UInt8, 4 * sizeof(T) - 1)
        @test encode_all!(MemoryView(out), MemoryView(values), e) == (3, 3 * sizeof(T))
        @test decode_all!(MemoryView(Vector{T}(undef, 3)), MemoryView(out), e) == (3, 3 * sizeof(T))
        # Empty
        @test decode_all!(MemoryView(T[]), MemoryView(bytes), e) == (0, 0)
        @test encode_all!(MemoryView(UInt8[]), MemoryView(values), e) == (0, 0)
        @test encode_all!(MemoryView(bytes), MemoryView(T[]), e) == (0, 0)
    end

    # Stops at invalid data
    dst = zeros(Bool, 5)
    @test decode_all!(MemoryView(dst), MemoryView([0x01, 0x00, 0x02, 0x01]), LittleEndian()) == (2, 2)
    @test dst[1:2] == [true, false]

    # Memory that `MemoryView` can view is accepted too, see "Memory-like arguments"
    @test decode_all!(zeros(UInt8, 2), MemoryView([0x01]), LittleEndian()) == (1, 1)
    @test decode_all!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian()) == (1, 1)
    @test encode_all!(MemoryView(zeros(UInt8, 2)), [0x01], LittleEndian()) == (1, 1)
    @test load_into!(CursorReader([0x01]), zeros(UInt8, 1), LittleEndian()) == (1, 1)
    @test store_every(VecWriter(), [0x01], LittleEndian()) == 1
    @test decode_every!(zeros(UInt8, 1), [0x01], LittleEndian()) == 1
    @test encode_every!(zeros(UInt8, 1), [0x01], LittleEndian()) == 1
    @test store_into(VecWriter(), [0x01], LittleEndian()) == (1, 1)
    @test store_all(VecWriter(), [0x01], LittleEndian()) == (1, 1)

    # Variable-length encodings
    s = "aé€😀\xe2\x82"
    dst = Vector{Char}(undef, 10)
    @test decode_all!(MemoryView(dst), MemoryView(s), UTF8()) == (length(s), ncodeunits(s))
    @test dst[1:length(s)] == collect(s)
    out = zeros(UInt8, 8)
    @test encode_all!(MemoryView(out), MemoryView(collect(s)), UTF8()) == (3, 6) # no room for the 4 bytes of 😀
    @test out[1:6] == codeunits("aé€")
    @test encode_all!(MemoryView(zeros(UInt8, 20)), MemoryView(collect(s)), UTF8()) == (length(s), ncodeunits(s))
end

@testset "decode_every! / encode_every!" begin
    for T in (BITS_TYPES..., Bool, Fruit), e in (LittleEndian(), BigEndian())
        values = if T === Bool
            rand(Bool, 37)
        elseif T === Fruit
            rand(instances(Fruit), 37)
        else
            rand(T, 37)
        end
        bytes = zeros(UInt8, sizeof(T) * 37 + 5)
        # Misaligned, with room to spare
        @test encode_every!(MemoryView(bytes)[2:end], MemoryView(values), e) == 37 * sizeof(T)
        dst = Vector{T}(undef, 37)
        # Trailing bytes are ignored
        @test decode_every!(MemoryView(dst), MemoryView(bytes)[2:end], e) == 37 * sizeof(T)
        @test isequal(dst, values)
        # Empty
        @test decode_every!(MemoryView(T[]), MemoryView(UInt8[]), e) == 0
        @test encode_every!(MemoryView(UInt8[]), MemoryView(T[]), e) == 0
        # Too few bytes to decode, or room to encode
        dst = Vector{T}(undef, 4)
        src = MemoryView(bytes)[2:(1 + 3 * sizeof(T))]
        @test_throws DecodeError(EndOfInput) decode_every!(MemoryView(dst), src, e)
        @test isequal(dst[1:3], values[1:3])
        if sizeof(T) > 1
            src = MemoryView(bytes)[2:(3 * sizeof(T))]
            @test_throws DecodeError(Truncated) decode_every!(MemoryView(dst), src, e)
        end
        out = zeros(UInt8, 4 * sizeof(T) - 1)
        @test_throws LightBoundsError encode_every!(MemoryView(out), MemoryView(values[1:4]), e)
        @test out[1:(3 * sizeof(T))] == bytes[2:(1 + 3 * sizeof(T))]
    end

    # Invalid data
    dst = zeros(Bool, 3)
    @test_throws DecodeError(InvalidData) decode_every!(MemoryView(dst), MemoryView([0x01, 0x00, 0x02, 0x01]), LittleEndian())
    @test dst[1:2] == [true, false]

    # Variable-length encodings
    s = "aé€😀\xe2\x82"
    dst = Vector{Char}(undef, length(s))
    @test decode_every!(MemoryView(dst), MemoryView(s), UTF8()) == ncodeunits(s)
    @test dst == collect(s)
    out = zeros(UInt8, ncodeunits(s) + 2)
    @test encode_every!(MemoryView(out), MemoryView(collect(s)), UTF8()) == ncodeunits(s)
    @test out[1:ncodeunits(s)] == codeunits(s)
    # Ends between two characters
    @test_throws DecodeError(EndOfInput) decode_every!(MemoryView(Vector{Char}(undef, 4)), MemoryView(codeunits(s)[1:6]), UTF8())
    # No room for the 4 bytes of 😀. The error reports the index where it starts.
    err = try
        encode_every!(MemoryView(zeros(UInt8, 8)), MemoryView(collect(s)), UTF8())
    catch e
        e
    end
    @test err isa LightBoundsError
    @test occursin("collection[7:9]", sprint(showerror, err))

    # An impure codec, which fails every other call: the elements it decodes or
    # encodes when retried are used
    FLAKY_CALLS[] = 0
    dst = zeros(Int8, 5)
    @test decode_every!(MemoryView(dst), MemoryView(UInt8[1, 2, 3, 4, 5]), Flaky()) == 5
    @test dst == 1:5
    out = zeros(UInt8, 5)
    @test encode_every!(MemoryView(out), MemoryView(dst), Flaky()) == 5
    @test out == 1:5
    dst = zeros(Int8, 5)
    @test load_every!(CursorReader(UInt8[1, 2, 3, 4, 5]), MemoryView(dst), Flaky()) == 5
    @test dst == 1:5
    io = VecWriter()
    @test store_every(io, MemoryView(dst), Flaky()) == 5
    @test io.vec == 1:5
end

@testset "load_into! / load_all!" begin
    data = collect(UInt8, 1:41)
    for max_fill in (1, 3, 8, 100), T in (UInt8, UInt16, UInt32, UInt64)
        n = div(41, sizeof(T))
        expected = [ltoh(x) for x in reinterpret(T, data[1:(n * sizeof(T))])]

        io = BoundedReader(data, 16; max_fill)
        dst = Vector{T}(undef, 50)
        @test load_all!(io, MemoryView(dst), LittleEndian()) == (n, n * sizeof(T))
        @test dst[1:n] == expected
        r = try_load(io, T, LittleEndian())
        @test is_err(r, (41 % sizeof(T) == 0) ? EndOfInput : Truncated)

        io = BoundedReader(data, 16; max_fill)
        dst = Vector{T}(undef, 50)
        total = 0
        while true
            (k, b) = load_into!(io, MemoryView(dst)[(total + 1):end], LittleEndian())
            iszero(k) && break
            @test k ≥ 1
            @test b == k * sizeof(T)
            total += k
        end
        @test total == n
        @test dst[1:n] == expected
    end

    @test load_into!(CursorReader([0x01]), MemoryView(UInt8[]), LittleEndian()) == (0, 0)
    @test load_all!(CursorReader([0x01]), MemoryView(UInt8[]), LittleEndian()) == (0, 0)
    @test load_into!(CursorReader(UInt8[]), MemoryView(zeros(UInt8, 3)), LittleEndian()) == (0, 0)

    # Stops at an invalid element, consuming nothing of it
    io = CursorReader([0x01, 0x00, 0x01, 0x05, 0x01])
    dst = zeros(Bool, 5)
    @test load_all!(io, MemoryView(dst), BigEndian()) == (3, 3)
    @test dst[1:3] == [true, false, true]
    @test is_err(try_load(io, Bool, BigEndian()), InvalidData)
    @test length(get_buffer(io)) == 2

    # Variable-length elements straddling the buffer
    s = "aé€😀\xe2\x82 x\xffyz€"
    for max_fill in 1:5, cap in 4:6
        io = BoundedReader(s, cap; max_fill)
        dst = Vector{Char}(undef, 30)
        @test load_all!(io, MemoryView(dst), UTF8()) == (length(s), ncodeunits(s))
        @test dst[1:length(s)] == collect(s)
        @test is_err(try_load(io, Char, UTF8()), EndOfInput)
    end
    io = ChunkedReader([[0x61, 0xe2], [0x82], [0xac, 0x62, 0xe2]])
    dst = Vector{Char}(undef, 10)
    @test load_all!(io, MemoryView(dst), UTF8()) == (4, 6)
    @test dst[1:4] == ['a', '€', 'b', '\xe2']

    # Too-small capacity
    @test_throws IOError load_into!(BoundedReader(zeros(UInt8, 8), 2), MemoryView(zeros(UInt32, 2)), LittleEndian())
end

@testset "load_every!" begin
    data = collect(UInt8, 1:40)
    for max_fill in (1, 3, 8, 100), T in (UInt8, UInt16, UInt32, UInt64)
        n = div(40, sizeof(T))
        expected = [ltoh(x) for x in reinterpret(T, data)]
        io = BoundedReader(data, 16; max_fill)
        dst = MemoryView(Vector{T}(undef, n))
        @test load_every!(io, dst, LittleEndian()) == 40
        @test collect(dst) == expected
        @test is_err(try_load(io, UInt8, LittleEndian()), EndOfInput)
    end
    # Variable-length elements straddling the buffer
    s = "aé€😀\xe2\x82 x\xffyz€"
    for max_fill in 1:5, cap in 4:6
        io = BoundedReader(s, cap; max_fill)
        dst = Vector{Char}(undef, length(s))
        @test load_every!(io, MemoryView(dst), UTF8()) == ncodeunits(s)
        @test dst == collect(s)
    end
    # An empty `dst` loads nothing
    io = CursorReader([0x01])
    @test load_every!(io, MemoryView(UInt8[]), LittleEndian()) == 0
    @test length(get_buffer(io)) == 1

    # No bytes at all
    @test_throws DecodeError(EndOfInput) load_every!(CursorReader(UInt8[]), MemoryView(zeros(UInt16, 2)), LittleEndian())
    # Ends between two elements, after some were loaded
    io = CursorReader([0x01, 0x00])
    dst = zeros(UInt16, 2)
    @test_throws DecodeError(EndOfInput) load_every!(io, MemoryView(dst), LittleEndian())
    @test dst[1] == 0x0001
    @test isempty(get_buffer(io))
    # Ends partway through an element, which is not consumed
    io = CursorReader([0x01, 0x00, 0x02])
    @test_throws DecodeError(Truncated) load_every!(io, MemoryView(zeros(UInt16, 2)), LittleEndian())
    @test length(get_buffer(io)) == 1
    # An invalid element, which is not consumed
    io = CursorReader([0x01, 0x00, 0x05, 0x01])
    dst = zeros(Bool, 4)
    @test_throws DecodeError(InvalidData) load_every!(io, MemoryView(dst), BigEndian())
    @test dst[1:2] == [true, false]
    @test length(get_buffer(io)) == 2
    # Too-small capacity
    @test_throws IOError load_every!(BoundedReader(zeros(UInt8, 8), 2), MemoryView(zeros(UInt32, 2)), LittleEndian())
    # The convenience modules
    dst = zeros(UInt16, 2)
    @test Big.load_every!(CursorReader([0x00, 0x01, 0x00, 0x02]), MemoryView(dst)) == 4
    @test dst == [0x0001, 0x0002]
end

@testset "store_into / store_all" begin
    values = rand(UInt32, 33)
    expected = reduce(vcat, bytes_be.(values))
    for cap in (4, 5, 7, 100)
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test store_all(io, MemoryView(values), BigEndian()) == (33, 4 * 33)
        flush(io)
        @test sink == expected
        # `store_into` stores as many elements as fit in one buffer, at least one
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        rest = MemoryView(values)
        while !isempty(rest)
            (n, b) = store_into(io, rest, BigEndian())
            @test 1 ≤ n ≤ max(1, div(cap, 4))
            @test b == 4n
            rest = rest[(n + 1):end]
        end
        flush(io)
        @test sink == expected
    end
    # Empty `src` stores nothing, and doesn't need a buffer
    io = BoundedWriter(UInt8[], 3)
    @test store_into(io, MemoryView(UInt32[]), BigEndian()) == (0, 0)
    @test store_all(io, MemoryView(UInt32[]), BigEndian()) == (0, 0)
    # Too-small capacity
    @test_throws IOError store_into(io, MemoryView(values), BigEndian())
    @test_throws IOError store_all(io, MemoryView(values), BigEndian())

    s = "aé€😀\xe2\x82 x\xffyz€"
    for cap in 4:7
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test store_all(io, MemoryView(collect(s)), UTF8()) == (length(s), ncodeunits(s))
        flush(io)
        @test String(sink) == s
    end
end

@testset "store_every" begin
    values = rand(UInt32, 33)
    for cap in (4, 5, 7, 100)
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test store_every(io, MemoryView(values), BigEndian()) == 4 * 33
        flush(io)
        @test sink == reduce(vcat, bytes_be.(values))
    end
    sink = UInt8[]
    io = BoundedWriter(sink, 3)
    @test_throws IOError store_every(io, MemoryView(values), BigEndian())
    @test store_every(io, MemoryView(UInt32[]), BigEndian()) == 0

    s = "aé€😀\xe2\x82 x\xffyz€"
    for cap in 4:7
        sink = UInt8[]
        io = BoundedWriter(sink, cap)
        @test store_every(io, MemoryView(collect(s)), UTF8()) == ncodeunits(s)
        flush(io)
        @test String(sink) == s
    end
    io = VecWriter()
    @test store_every(io, MemoryView([true, false]), LittleEndian()) == 2
    @test store_every(io, MemoryView(Fruit[banana]), LittleEndian()) == 2
    @test io.vec == [0x01, 0x00, 0x03, 0x02]
end
