@testset "Proxies" begin
    @test codec_scheme(Span, LittleEndian()) === Proxy{NTuple{2, UInt16}}()
    @test codec_scheme(Glyph, LittleEndian()) === Manual()
    @test max_encoded_size(Span, BigEndian()) == 4
    @test max_encoded_size(Sparse, LittleEndian()) == 5
    @test max_encoded_size(Glyph, UTF8()) == 4
    @test max_encoded_size(Nest, LittleEndian()) == 4

    # Encoded as the proxy
    for e in (LittleEndian(), BigEndian())
        @test encoding(Span(0x0102, 0x0304), e) == encoding((0x0102, 0x0304), e)
        @test encoding(Sparse(0x01, 0x02030405), e) == encoding((0x01, 0x02030405), e)
        @test encoding(Nest(Span(0x0102, 0x0304)), e) == encoding((0x0102, 0x0304), e)
    end
    @test encoding(Glyph('€'), UTF8()) == codeunits("€")
    @test encoding(Wrapped('é'), UTF8()) == codeunits("é")
    @test encoding(Wrapped('é'), Latin1()) == [0xe9]
    @test decode(MemoryView([0x00, 0x01, 0x00, 0x02]), Span, BigEndian()) === Span(0x0001, 0x0002)
    @test try_decode_next(MemoryView("é!"), 1, Glyph, UTF8()) === (Glyph('é'), 3)

    # `try_from_proxy` rejects values with `Invalid()`, also nested and in bulk
    invalid = [0x00, 0x02, 0x00, 0x01]
    @test is_err(try_decode(MemoryView(invalid), Span, BigEndian()), InvalidData)
    @test is_err(try_decode(MemoryView(invalid), Nest, BigEndian()), InvalidData)
    @test is_err(try_load(CursorReader(invalid), Span, BigEndian()), InvalidData)
    valid = [0x00, 0x01, 0x00, 0x02]
    @test decode_all!(MemoryView(Vector{Span}(undef, 3)), MemoryView([valid; valid; invalid]), BigEndian()) == (2, 8)
    # The proxy decides the error kinds
    @test is_err(try_decode(MemoryView(valid[1:3]), Span, BigEndian()), Truncated)
    @test is_err(try_decode(MemoryView(UInt8[]), Span, BigEndian()), EndOfInput)
    @test is_err(try_decode(MemoryView(UInt8[]), Glyph, UTF8()), EndOfInput)
    for bytes in ([0xe2, 0x82], [0xff], [0xe2, 0x82, 0xac, 0x21])
        @test try_decode_next(MemoryView(bytes), 1, Glyph, UTF8()) ===
            ((c, i) -> (Glyph(c), i))(try_decode_next(MemoryView(bytes), 1, Char, UTF8())...)
    end

    # Bulk and IO
    spans = [Span(0x0001, 0x0002), Span(0x0003, 0x0004), Span(0x0005, 0x0005)]
    io = VecWriter()
    store_every(io, MemoryView(spans), LittleEndian())
    @test io.vec == reduce(vcat, [encoding(s, LittleEndian()) for s in spans])
    dst = Vector{Span}(undef, 3)
    load_every!(CursorReader(io.vec), MemoryView(dst), LittleEndian())
    @test dst == spans
    glyphs = Glyph.(collect("a€é"))
    buf = zeros(UInt8, 16)
    @test encode_all!(MemoryView(buf), MemoryView(glyphs), UTF8()) == (3, 6)
    @test String(buf[1:6]) == "a€é"
    @test decode_all!(MemoryView(Vector{Glyph}(undef, 3)), MemoryView(buf[1:6]), UTF8()) == (3, 6)

    # `try_to_proxy` rejects values with `Invalid()`, also nested, in bulk and with IO
    e = BigEndian()
    @test encoding(Narrow(0x0102), e) == [0x01, 0x02]
    @test decode(MemoryView([0x01, 0x02]), Narrow, e) === Narrow(0x0102)
    @test encoding(NestNarrow(Narrow(0x0102)), e) == [0x01, 0x02]
    for bad in (Narrow(-1), NestNarrow(Narrow(65536)), (0x01, Narrow(-1)))
        @test try_encode!(MemoryView(zeros(UInt8, 8)), bad, e) === EncodeError(InvalidValue)
        @test try_encode!(MemoryView(zeros(UInt8, 3)), bad, e) === EncodeError(InvalidValue)
        @test_throws EncodeError(InvalidValue) encode!(MemoryView(zeros(UInt8, 8)), bad, e)
        io = VecWriter()
        @test try_store(io, bad, e) === EncodeError(InvalidValue)
        @test_throws EncodeError(InvalidValue) store(io, bad, e)
        @test isempty(io.vec)
    end
    narrows = [Narrow(1), Narrow(2), Narrow(-1), Narrow(3)]
    buf = zeros(UInt8, 16)
    @test encode_all!(MemoryView(buf), MemoryView(narrows), e) == (2, 4)
    @test buf[1:4] == [0x00, 0x01, 0x00, 0x02]
    io = VecWriter()
    @test store_all(io, narrows, e) == (2, 4)
    @test io.vec == [0x00, 0x01, 0x00, 0x02]

    # Proxies that can't be used
    message(T) =
    try
        max_encoded_size(T, LittleEndian())
    catch e
        sprint(showerror, e)
    end
    @test occursin("The proxy `Integer` of `AbstractProxied` is not a concrete type", message(AbstractProxied))
    @test occursin("`SelfProxied` can't be its own proxy", message(SelfProxied))
    @test occursin("The proxy `1` of `NotTypeProxied` is not a concrete type", message(NotTypeProxied))
    for T in (AbstractProxied, SelfProxied, NotTypeProxied)
        @test_throws ArgumentError try_decode(MemoryView(zeros(UInt8, 8)), T, LittleEndian())
    end
    @test_throws ArgumentError encode!(SCRATCH, SelfProxied(0x01), BigEndian())
    @test_throws TypeError try_encode!(SCRATCH, WrongProxy(0x01), LittleEndian())
    @test_throws TypeError try_encode!(SCRATCH, NothingProxy(0x01), LittleEndian())
    @test_throws TypeError try_decode(MemoryView(zeros(UInt8, 8)), NothingProxy, LittleEndian())

    # A struct with a proxied field can't be a bits type, but a tuple can hold it
    @test_throws ArgumentError max_encoded_size(WithProxied, LittleEndian())
    @test occursin(
        "field `s` of `WithProxied` has the type `Span`, whose `codec_scheme` with `LittleEndian()` is `Proxy`",
        message(WithProxied),
    )
    @test codec_scheme(Tuple{Span, UInt8}, LittleEndian()) === Manual()

    # Bits schemes are only for the byte orders
    @test decode([0x05], BitsEverywhere, LittleEndian()) === BitsEverywhere(0x05)
    @test_throws ArgumentError max_encoded_size(BitsEverywhere, UTF8())
    err = try
        try_decode(MemoryView([0x05]), BitsEverywhere, UTF8())
    catch e
        sprint(showerror, e)
    end
    @test occursin("`codec_scheme(BitsEverywhere, UTF8())` is `BitsLoadable`, but only the `Endianness` encodings", err)
end
