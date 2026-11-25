@testset "Loading waits only for the bytes needed" begin
    # A character is loaded as soon as its bytes are buffered
    io = StallingReader([[0x61], [0xc3], [0xa9, 0xe2], [0x82, 0xac, 0x62]])
    @test load(io, Char, UTF8()) === 'a'
    @test load(io, Char, UTF8()) === 'é'
    @test load(io, Char, UTF8()) === '€'
    @test load(io, Char, UTF8()) === 'b'
    # Nothing is buffered, so the next load must fill
    @test_throws ErrorException load(io, Char, UTF8())
    # A malformed character is decided by the byte after it
    io = StallingReader([[0xe2], [0x41]])
    @test load(io, Char, UTF8()) === '\xe2'
    @test load(io, Char, UTF8()) === 'A'

    # The same for loading into memory
    io = StallingReader([[0x61, 0xc3], [0xa9]])
    dst = Vector{Char}(undef, 5)
    @test load_into!(io, MemoryView(dst), UTF8()) == (1, 1) # 'é' isn't decided yet
    @test dst[1] == 'a'
    @test load_into!(io, MemoryView(dst), UTF8()) == (1, 2)
    @test dst[1] == 'é'
    io = StallingReader([[0x61, 0x62, 0xe2], [0x82, 0xac]])
    @test load_every!(io, MemoryView(dst)[1:3], UTF8()) == 5
    @test dst[1:3] == ['a', 'b', '€']

    # A codec decided by the byte after its encoding waits for that byte, but not more
    @test load(StallingReader([[0x31, 0x32], [0x20]]), UInt8, Decimal()) === 0x0c
    @test_throws ErrorException load(StallingReader([[0x31, 0x32]]), UInt8, Decimal())
    @test load(StallingReader([[0x32, 0x35], [0x35]]), UInt8, Decimal()) === 0xff
    # At EOF, the buffered digits are the complete input
    @test load(CursorReader([0x31, 0x32]), UInt8, Decimal()) === 0x0c
    io = StallingReader([[0x37, 0x20, 0x34, 0x32], [0x20]])
    dst = zeros(UInt8, 3)
    @test load_into!(io, MemoryView(dst), Decimal()) == (1, 1)
    @test dst[1] == 7
    consume(io, 1) # the space
    @test load_into!(io, MemoryView(dst), Decimal()) == (1, 2)
    @test dst[1] == 42
    @test decode(MemoryView(b"42"), UInt8, Decimal()) === 0x2a
    @test is_err(try_decode(MemoryView(b"256"), UInt8, Decimal()), InvalidData)

    # Fixed-size values, and codecs that implement `codec_try_decode` without a mode,
    # wait for `max_encoded_size` bytes
    io = StallingReader([[0x00], [0x01]])
    @test load(io, UInt16, BigEndian()) === 0x0001
    io = StallingReader([[0x61]])
    @test_throws ErrorException load(io, Tuple{Char, Char}, Latin1())

    # Decode from partial input, with the result as a `DecodeError` like the public
    # functions give it
    function partial(bytes, T, e)
        result = BitScribbling.decode_start(ImmutableMemoryView(bytes), T, e, false)
        result isa TooShort && return DecodeError(Truncated)
        result isa Invalid && return DecodeError(InvalidData)
        return result
    end
    is_undecided(result) = result === DecodeError(Truncated)
    @test is_undecided(partial([0x61], Tuple{Char, Char}, Latin1()))
    for (T, e) in ((Char, UTF8()), (UInt16, BigEndian()), (Tuple{Bool, UInt32}, BigEndian()), (UInt8, Decimal()))
        @test partial(UInt8[], T, e) === DecodeError(Truncated)
        @test try_decode(MemoryView(UInt8[]), T, e) === DecodeError(EndOfInput)
    end

    # The functions that codecs read their input through. `L` is the number of bytes
    # the input is known to hold when the codec is compiled.
    bytes3 = ImmutableMemoryView([0x01, 0x02, 0x03])
    full = BitScribbling.MemoryInput{3}(bytes3, true)
    complete = BitScribbling.MemoryInput{0}(bytes3, true)
    part = BitScribbling.MemoryInput{0}(bytes3, false)
    empty_complete = BitScribbling.MemoryInput{0}(ImmutableMemoryView(UInt8[]), true)
    empty_partial = BitScribbling.MemoryInput{0}(ImmutableMemoryView(UInt8[]), false)
    for input in (full, complete, part)
        @test require_bytes(input, 2) == [0x01, 0x02]
        @test require_bytes(input, 3) == [0x01, 0x02, 0x03]
        @test isempty(require_bytes(input, 0))
        @test require_bytes(input, 4) === TooShort()
        @test require_bytes(input, typemax(Int)) === TooShort()
        @test_throws ArgumentError require_bytes(input, -1)
        @test peek_byte(input, 3) === 0x03
        @test_throws LightBoundsError peek_byte(input, 0)
    end
    @test require_bytes(empty_complete, 1) === TooShort()
    @test require_bytes(empty_partial, 1) === TooShort()
    @test peek_byte(complete, 4) === nothing
    @test peek_byte(full, 4) === nothing
    @test peek_byte(part, 4) === TooShort()
    @test peek_byte(empty_partial, 1) === TooShort()
    @test peek_byte(empty_complete, 1) === nothing

    (x, n, rest) = decode_field(full, UInt16, BigEndian())
    @test (x, n) === (0x0102, 2)
    @test rest isa BitScribbling.MemoryInput{1}
    @test require_bytes(rest, 1) == [0x03]
    (x, n, rest) = decode_field(complete, UInt16, BigEndian())
    @test (x, n) === (0x0102, 2)
    @test rest isa BitScribbling.MemoryInput{0}
    @test decode_field(rest, UInt16, BigEndian()) === TooShort()
    (x, n, rest) = decode_field(rest, Char, UTF8())
    @test (x, n) === ('\x03', 1)
    @test decode_field(rest, UInt8, BigEndian()) === TooShort()
    @test decode_field(rest, Char, UTF8()) === TooShort()
    @test require_bytes(rest, 2) === TooShort()
    @test decode_field(empty_partial, UInt8, BigEndian()) === TooShort()
    @test decode_field(BitScribbling.MemoryInput{0}(ImmutableMemoryView([0x02]), true), Even, BigEndian()) isa Tuple
    @test decode_field(BitScribbling.MemoryInput{0}(ImmutableMemoryView([0x01]), true), Even, BigEndian()) === Invalid()
    # Partial input passes on to the rest
    (_, _, rest) = decode_field(part, UInt16, BigEndian())
    @test peek_byte(rest, 2) === TooShort()

    # The same for outputs
    out_bytes = zeros(UInt8, 3)
    full_out = EncodeOutput{3}(MemoryView(out_bytes))
    short_out = EncodeOutput{0}(MemoryView(out_bytes))
    for output in (full_out, short_out)
        @test length(reserve_bytes(output, 2)) == 2
        @test reserve_bytes(output, 4) === TooShort(4)
        @test_throws ArgumentError reserve_bytes(output, -1)
    end
    (n, rest) = encode_field(full_out, 0x0102, BigEndian())
    @test n == 2
    @test rest isa EncodeOutput{1}
    @test out_bytes[1:2] == [0x01, 0x02]
    @test encode_field(rest, 0x0102, BigEndian()) === TooShort(4)
    @test encode_field(rest, 'é', UTF8()) === TooShort(4)
    @test reserve_bytes(rest, 3) === TooShort(5)
    @test encode_field(rest, Even(0x01), BigEndian()) === Invalid()
    (n, rest) = encode_field(rest, 'a', UTF8())
    @test n == 1
    @test out_bytes == [0x01, 0x02, 0x61]
    @test encode_field(short_out, 0x01020304, BigEndian()) === TooShort(4)

    # A reader buffers the bytes that a codec asks for at once, rather than one by one
    bytes = vcat(0xc8, fill(0x01, 200))
    PREFIXED_CALLS[] = 0
    @test load(ChunkedReader([[b] for b in bytes]), UInt64, Prefixed()) === UInt64(200)
    @test PREFIXED_CALLS[] ≤ 4
    PREFIXED_CALLS[] = 0
    @test load(StallingReader([bytes[1:1], bytes[2:end]]), UInt64, Prefixed()) === UInt64(200)
    @test PREFIXED_CALLS[] ≤ 4
    # A reader that ends early
    @test try_load(CursorReader(bytes[1:100]), UInt64, Prefixed()) === DecodeError(Truncated)

    # A codec that reads more than `max_encoded_size` bytes breaks its contract: it
    # can't, since the input ends after them
    @test_throws ErrorException try_decode(MemoryView(zeros(UInt8, 10)), UInt8, Greedy())
    @test_throws ErrorException try_load(CursorReader(zeros(UInt8, 10)), UInt8, Greedy())
    @test_throws ErrorException try_load(StallingReader([[0x00], [0x00]]), UInt8, Greedy())
    @test_throws ErrorException try_encode!(MemoryView(zeros(UInt8, 10)), 0x00, Greedy())
    # With less than `max_encoded_size` bytes, `TooShort` is allowed
    @test try_decode(MemoryView([0x00]), UInt8, Greedy()) === DecodeError(Truncated)
    @test try_encode!(MemoryView([0x00]), 0x00, Greedy()) === EncodeError(InsufficientSpace)

    # The contract for partial input: a decided result is the result for every input
    # that starts with the bytes, and `max_encoded_size` bytes always decide it
    for (T, e, x) in CODEC_CASES
        m = max_encoded_size(T, e)
        # The prefixes of an input of `m + 1` bytes have every length that matters. Where
        # the result is decided depends on the data for some codecs only, such as UTF-8,
        # which gets more inputs.
        is_utf8 = T === Char && e === UTF8()
        inputs = [rand(UInt8, m + 1) for _ in 1:(is_utf8 ? 100 : 5)]
        if is_utf8
            for bytes in inputs
                # Mostly bytes that can continue an encoding, so that the codec needs to
                # see several bytes
                for j in 2:length(bytes)
                    rand() < 0.7 && (bytes[j] = rand(0x80:0xbf))
                end
                bytes[1] = rand((0x41, 0xc3, 0xe2, 0xf0, 0x80, 0xff))
            end
        end
        # Random bytes are mostly invalid for some types
        push!(inputs, [encoding(x, e); rand(UInt8)])
        for bytes in inputs, l in 0:length(bytes)
            prefix = bytes[1:l]
            result = partial(prefix, T, e)
            # Where partial input ends is not known
            @test !isequal(result, DecodeError(EndOfInput))
            if is_undecided(result)
                @test l < m
                continue
            end
            @test isequal(result, try_decode_n(MemoryView(prefix), T, e))
            @test isequal(result, try_decode_n(MemoryView(bytes), T, e))
            @test isequal(result, try_decode_n(MemoryView(vcat(prefix, 0x80, 0x41)), T, e))
        end
    end
    # For UTF-8, the bytes of the character decide it, or the byte that ends it early
    decided_at(bytes) = findfirst(l -> !is_undecided(partial(bytes[1:l], Char, UTF8())), 0:length(bytes))
    decided_length(bytes) = (i = decided_at(bytes); i === nothing ? nothing : i - 1)
    @test decided_length(UInt8[]) === nothing
    @test decided_length([0x61, 0x80]) == 1
    @test decided_length([0xe2]) === nothing
    @test decided_length([0xe2, 0x82]) === nothing
    @test decided_length([0xe2, 0x82, 0xac]) == 3
    @test decided_length([0xe2, 0x41]) == 2
    @test decided_length([0xf0, 0x9f, 0x98, 0x80]) == 4
    @test partial([0xe2, 0x41], Char, UTF8()) === ('\xe2', 1)
end
