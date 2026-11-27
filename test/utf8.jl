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

    # Exactly the same as String iteration. The decoder only tells apart classes of bytes:
    # ASCII, continuation bytes, lead bytes of each length, and invalid lead bytes. So,
    # test every byte at each position of an encoding of each length, to check where
    # the classes start and end...
    for b in 0x00:0xff, encoded in ([0xc3, 0xa9], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80])
        for pos in eachindex(encoded)
            bytes = copy(encoded)
            bytes[pos] = b
            @test decode_chars(bytes) == string_chars(bytes)
        end
        @test decode_chars([b]) == string_chars([b])
    end
    # ... and every sequence of up to 4 bytes of one byte per class
    classes = [0x41, 0x80, 0xc3, 0xe2, 0xf0, 0xf8]
    for len in 1:4
        for idx in CartesianIndices(ntuple(_ -> length(classes), len))
            bytes = [classes[i] for i in Tuple(idx)]
            @test decode_chars(bytes) == string_chars(bytes)
        end
    end

    # Encoding
    for c in ['\0', 'a', 'é', '€', '😀', '\xe2', '\xe2\x82', '\xc0\x80', '\ud800', '\xf7\xbf\xbf\xbf']
        @test try_encode!(SCRATCH, c, UTF8()) === encode!(SCRATCH, c, UTF8()) === ncodeunits(c)
        # Scratch memory of exactly the size, or too short
        n = ncodeunits(c)
        @test try_encode!(zeros(UInt8, n), c, UTF8()) === n
        @test try_encode!(zeros(UInt8, n - 1), c, UTF8()) == EncodeError(InsufficientSpace)
        @test_throws LightBoundsError encode!(zeros(UInt8, n - 1), c, UTF8())
        for len in 0:6
            buf = fill(0xaa, len)
            n = try_encode!(MemoryView(buf), c, UTF8())
            if len < ncodeunits(c)
                @test n == EncodeError(InsufficientSpace)
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
    # Chars that no String can contain can't be encoded, since their code units
    # would decode to other Chars
    for u in (
            typemax(UInt32),  # f8-ff lead with more code units: would be four '\xff'
            0x41420000,       # ASCII lead with more code units
            0x80800000,       # stray continuation byte with more code units
            0xc3a9a900,       # more code units than the lead byte allows
            0xc3410000,       # non-continuation byte after the lead
            0xe2008200,       # zero byte inside the code units
        )
        c = reinterpret(Char, u)
        @test try_encode!(SCRATCH, c, UTF8()) == EncodeError(InvalidValue)
        # Unless the scratch memory is too short for any Char
        @test try_encode!(UInt8[], c, UTF8()) isa EncodeError
        buf = zeros(UInt8, 4)
        @test try_encode!(MemoryView(buf), c, UTF8()) == EncodeError(InvalidValue)
        @test_throws EncodeError encode!(MemoryView(buf), c, UTF8())
        @test_throws EncodeError encode!(SCRATCH, c, UTF8())
    end
    # Every Char that String iteration produces can be encoded, so encoding the Chars
    # of a String gives back its code units, even when it is malformed
    for s in ("aé€😀", "\xc3A\x80\xff\xe2\x82\xf8\xc0\x80", String([hash(i) % UInt8 for i in 1:10_000]))
        chars = collect(s)
        dst = zeros(UInt8, ncodeunits(s))
        @test encode_every!(MemoryView(dst), MemoryView(chars), UTF8()) == ncodeunits(s)
        @test dst == codeunits(s)
    end
    # But, as for Strings, malformed Chars may merge when encoded one after another
    buf = zeros(UInt8, 2)
    @test encode_every!(MemoryView(buf), MemoryView(['\xc3', '\xa9']), UTF8()) == 2
    @test first.(decode_chars(buf)) == ['é']

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

    # A capacity smaller than `max_encoded_size` is only too small for the characters
    # that need more bytes
    @test load(BoundedReader("é", 3), Char, UTF8()) === 'é'
    @test load(BoundedReader("€", 3), Char, UTF8()) === '€'
    @test_throws IOError load(BoundedReader("😀", 3), Char, UTF8())
    for max_fill in 1:3
        io = BoundedReader("aé€\xe2\x82!", 3; max_fill)
        dst = Vector{Char}(undef, 10)
        @test load_all!(io, MemoryView(dst), UTF8()) == (5, ncodeunits("aé€\xe2\x82!"))
        @test dst[1:5] == collect("aé€\xe2\x82!")
    end

    io = VecWriter()
    for c in "aé€😀"
        store(io, c, UTF8())
    end
    @test String(io.vec) == "aé€😀"
end
