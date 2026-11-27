# Types without a codec, which overload the functions directly

# NUL-terminated strings. `Over{F}` overloads only the functions in the tuple of names `F`.
struct Over{F}
    s::String
end
struct Direct <: Encoding end

function direct_decode(mem, i)
    i > length(mem) && return DecodeError(EndOfInput)
    p = findnext(==(0x00), mem, i)
    p === nothing && return DecodeError(Truncated)
    return (String(mem[i:(p - 1)]), p + 1)
end
function direct_encode!(mem, i, s)
    n = ncodeunits(s)
    length(mem) - i + 1 < n + 1 && return EncodeError(InsufficientSpace)
    '\0' in s && return EncodeError(InvalidValue)
    copyto!(mem, i, codeunits(s), 1, n)
    mem[i + n] = 0x00
    return n + 1
end
function direct_load(io)
    buffer = buffer_until(io, 0x00)
    result = direct_decode(buffer, 1)
    result isa DecodeError && return result
    consume(io, length(buffer))
    return (result[1], length(buffer))
end
function direct_store(io, s)
    '\0' in s && return EncodeError(InvalidValue)
    n = direct_encode!(get_nonempty_buffer(io, ncodeunits(s) + 1), 1, s)
    consume(io, n)
    return n
end

# The methods, in terms of the types `T` and the encoding `E`
const OVERLOADS = Dict(
    :try_decode => :(
        function Inscription.try_decode(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            result = direct_decode(mem, Int(i))
            return result isa DecodeError ? result : T(result[1])
        end
    ),
    :try_decode_next => :(
        function Inscription.try_decode_next(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            result = direct_decode(mem, Int(i))
            return result isa DecodeError ? result : (T(result[1]), result[2])
        end
    ),
    :try_encode! => :(
        function Inscription.try_encode!(mem::MutableMemoryView{UInt8}, i::Integer, x::T, ::E)
            return direct_encode!(mem, Int(i), x.s)
        end
    ),
    :try_load => :(
        function Inscription.try_load(io::AbstractBufReader, ::Type{T}, ::E)
            result = direct_load(io)
            return result isa DecodeError ? result : T(result[1])
        end
    ),
    :try_load_exact => :(
        function Inscription.try_load_exact(io::AbstractBufReader, n::Integer, ::Type{T}, ::E)
            result = direct_load(io)
            return result isa DecodeError ? result : T(result[1])
        end
    ),
    :try_store => :(Inscription.try_store(io::AbstractBufWriter, x::T, ::E) = direct_store(io, x.s)),
    :decode => :(
        function Inscription.decode(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            return T(direct_decode(mem, Int(i))[1])
        end
    ),
    :decode_next => :(
        function Inscription.decode_next(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            (s, next) = direct_decode(mem, Int(i))
            return (T(s), next)
        end
    ),
    :try_decode_exact => :(
        function Inscription.try_decode_exact(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            return T(direct_decode(mem, Int(i))[1])
        end
    ),
    :decode_exact => :(
        function Inscription.decode_exact(mem::MemoryView{UInt8}, i::Integer, ::Type{T}, ::E)
            return T(direct_decode(mem, Int(i))[1])
        end
    ),
    :encode! => :(
        function Inscription.encode!(mem::MutableMemoryView{UInt8}, i::Integer, x::T, ::E)
            return direct_encode!(mem, Int(i), x.s)
        end
    ),
    :store => :(Inscription.store(io::AbstractBufWriter, x::T, ::E) = direct_store(io, x.s)),
    :decode_all! => :(
        function Inscription.decode_all!(dst::MutableMemoryView{T}, src::MemoryView{UInt8}, ::E)
            (k, i) = (0, 1)
            while k < length(dst)
                result = direct_decode(src, i)
                result isa DecodeError && break
                k += 1
                dst[k] = T(result[1])
                i = result[2]
            end
            return (k, i - 1)
        end
    ),
    :encode_all! => :(
        function Inscription.encode_all!(dst::MutableMemoryView{UInt8}, src::MemoryView{T}, ::E)
            n = 0
            for k in eachindex(src)
                result = direct_encode!(dst, n + 1, src[k].s)
                result isa EncodeError && return (k - 1, n)
                n += result
            end
            return (length(src), n)
        end
    ),
    :load_into! => :(
        function Inscription.load_into!(io::AbstractBufReader, dst::MutableMemoryView{T}, ::E)
            isempty(dst) && return (0, 0)
            result = direct_load(io)
            result isa DecodeError && return (0, 0)
            dst[1] = T(result[1])
            return (1, result[2])
        end
    ),
    :store_into => :(
        function Inscription.store_into(io::AbstractBufWriter, src::MemoryView{T}, ::E)
            isempty(src) && return (0, 0)
            n = direct_store(io, src[1].s)
            return n isa EncodeError ? (0, 0) : (1, n)
        end
    ),
)

# Define the overloads of `Over{F}`
function over(names...)
    T = Over{names}
    for name in names
        for E in (Direct, LittleEndian)
            @eval let T = $T, E = $E
                $(OVERLOADS[name])
            end
        end
    end
    return T
end

# Which functions use which method. This is the documented forwarding.
const FORWARDING = [
    over(:try_decode) => ["try_decode/2", "try_decode/3"],
    over(:decode) => ["decode"],
    over(:decode_next) => ["decode_next"],
    over(:try_decode_exact) => ["try_decode_exact", "try_load_exact", "load_exact"],
    over(:decode_exact) => ["decode_exact"],
    over(:try_decode_next) => [
        "try_decode/2", "try_decode/3", "decode", "try_decode_next", "decode_next",
        "try_decode_exact", "decode_exact", "try_load_exact", "load_exact",
    ],
    over(:try_encode!) => ["try_encode!/2", "try_encode!/3", "encode!"],
    over(:encode!) => ["encode!"],
    over(:store) => ["store"],
    over(:try_load) => ["try_load", "load"],
    over(:try_load_exact) => ["try_load_exact", "load_exact"],
    over(:try_store) => ["try_store", "store"],
    over(:decode_all!) => ["decode_all!", "decode_every!"],
    over(:encode_all!) => ["encode_all!", "encode_every!"],
    over(:load_into!) => ["load_into!", "load_all!", "load_every!"],
    over(:store_into) => ["store_into", "store_all", "store_every"],
]
const NO_OVERLOADS = Over{()}

const ONE = collect(b"hello\0")
const TWO = collect(b"hello\0world\0")
hello_world(T) = T[T("hello"), T("world")]

function entry_points(::Type{T}, e) where {T}
    dst() = Vector{T}(undef, 2)
    out() = zeros(UInt8, 12)
    x = T("hello")
    xs = hello_world(T)
    return Dict(
        "try_decode/2" => () -> try_decode(TWO, T, e) == x,
        "try_decode/3" => () -> try_decode(MemoryView(TWO), Int32(7), T, e) == T("world"),
        "decode" => () -> decode(TWO, T, e) == x,
        "try_decode_next" => () -> try_decode_next(TWO, 7, T, e) == (T("world"), 13),
        "decode_next" => () -> decode_next(TWO, 7, T, e) == (T("world"), 13),
        "try_decode_exact" => () -> try_decode_exact(ONE, T, e) == x,
        "decode_exact" => () -> decode_exact(ONE, T, e) == x,
        "try_encode!/2" => () -> (b = out(); try_encode!(b, x, e) == 6 && b[1:6] == ONE),
        "try_encode!/3" => () -> (b = out(); try_encode!(b, 2, x, e) == 6 && b[2:7] == ONE),
        "encode!" => () -> (b = out(); encode!(b, x, e) == 6 && b[1:6] == ONE),
        "decode_all!" => () -> (d = dst(); decode_all!(d, TWO, e) == (2, 12) && d == xs),
        "decode_every!" => () -> (d = dst(); decode_every!(d, TWO, e) == 12 && d == xs),
        "encode_all!" => () -> (b = out(); encode_all!(b, xs, e) == (2, 12) && b == TWO),
        "encode_every!" => () -> (b = out(); encode_every!(b, xs, e) == 12 && b == TWO),
        "try_load" => () -> try_load(CursorReader(TWO), T, e) == x,
        "load" => () -> load(CursorReader(TWO), T, e) == x,
        "try_load_exact" => () -> try_load_exact(CursorReader(TWO), 6, T, e) == x,
        "load_exact" => () -> load_exact(CursorReader(TWO), 6, T, e) == x,
        "load_into!" => () -> (d = dst(); load_into!(CursorReader(TWO), d, e) == (1, 6) && d[1] == x),
        "load_all!" => () -> (d = dst(); load_all!(CursorReader(TWO), d, e) == (2, 12) && d == xs),
        "load_every!" => () -> (d = dst(); load_every!(CursorReader(TWO), d, e) == 12 && d == xs),
        "try_store" => () -> (io = VecWriter(); try_store(io, x, e) == 6 && io.vec == ONE),
        "store" => () -> (io = VecWriter(); store(io, x, e) == 6 && io.vec == ONE),
        "store_into" => () -> (io = VecWriter(); store_into(io, xs, e) == (1, 6) && io.vec == ONE),
        "store_all" => () -> (io = VecWriter(); store_all(io, xs, e) == (2, 12) && io.vec == TWO),
        "store_every" => () -> (io = VecWriter(); store_every(io, xs, e) == 12 && io.vec == TWO),
    )
end

@testset "Overloading: forwarding" begin
    for e in (Direct(), LittleEndian()), (T, names) in [FORWARDING; NO_OVERLOADS => String[]]
        for (name, f) in entry_points(T, e)
            if name in names
                @test f()
            else
                msg = try
                    f()
                    ""
                catch err
                    err isa ArgumentError ? sprint(showerror, err) : rethrow()
                end
                @test occursin("There is no codec for", msg)
            end
        end
    end
    # The convenience modules forward to the methods
    T = Over{(:try_load,)}
    @test Little.load(CursorReader(TWO), T) == T("hello")
end

# Not in the testset, where methods can't be called in the world they are defined in
over(:load_into!, :try_load)
over(:decode_all!, :try_decode_next)
over(:encode_all!, :try_encode!)
over(:store_into, :try_store)

@testset "Overloading: errors" begin
    e = Direct()
    T = Over{(:load_into!, :try_load)}
    for bytes in (b"hello\0wor", b"hello\0")
        io = CursorReader(collect(bytes))
        kind = length(bytes) == 6 ? EndOfInput : Truncated
        @test_error DecodeError(kind) load_every!(io, Vector{T}(undef, 2), e)
        @test read(io) == bytes[7:end] # nothing of the failing element is consumed
    end
    @test_error DecodeError(Truncated) load(CursorReader(UInt8['a']), T, e)
    T = Over{(:decode_all!, :try_decode_next)}
    @test_error DecodeError(Truncated) decode_every!(Vector{T}(undef, 2), b"hello\0wor" |> collect, e)
    T = Over{(:encode_all!, :try_encode!)}
    @test_throws LightBoundsError encode_every!(zeros(UInt8, 8), hello_world(T), e)
    @test_error EncodeError(InvalidValue) encode_every!(zeros(UInt8, 20), [T("a"), T("b\0")], e)
    T = Over{(:store_into, :try_store)}
    io = VecWriter()
    @test_error EncodeError(InvalidValue) store_every(io, [T("a"), T("b\0")], e)
    @test io.vec == b"a\0"
    # Without the function that reports the error, the error is that there is no codec
    T = Over{(:load_into!,)}
    @test_throws ArgumentError load_every!(CursorReader(collect(b"hello\0wor")), Vector{T}(undef, 2), e)
    T = Over{(:encode_all!,)}
    @test_throws ArgumentError encode_every!(zeros(UInt8, 8), hello_world(T), e)
end

const FOUR = over(:try_decode_next, :try_encode!, :try_load, :try_store)

@testset "Overloading: the four basic functions" begin
    (e, T) = (Direct(), FOUR)
    for (name, f) in entry_points(T, e)
        if occursin(r"_all|_every|_into", name)
            @test_throws ArgumentError f()
        else
            @test f()
        end
    end
    mem = collect(b"hello")
    @test is_err(try_decode(mem, T, e), Truncated)
    @test is_err(try_decode(mem, 6, T, e), EndOfInput)
    @test_error DecodeError(Truncated) decode(mem, T, e)
    @test_error DecodeError(EndOfInput) decode_next(mem, 6, T, e)
    @test is_err(try_decode_exact(TWO, T, e), TrailingData)
    @test_error DecodeError(TrailingData) decode_exact(TWO, T, e)
    for f in (try_decode, decode, decode_next, try_decode_exact, decode_exact), i in (0, 7)
        @test_throws LightBoundsError f(mem, i, T, e)
    end
    @test is_err(try_load_exact(CursorReader(TWO), 5, T, e), Truncated)
    @test is_err(try_load_exact(CursorReader(TWO), 12, T, e), TrailingData)
    @test_throws LightBoundsError encode!(zeros(UInt8, 5), T("hello"), e)
    @test_error EncodeError(InvalidValue) encode!(zeros(UInt8, 5), T("a\0"), e)
    io = VecWriter()
    @test_error EncodeError(InvalidValue) store(io, T("a\0"), e)
    @test isempty(io.vec)
end

# Methods that return the counts in `BAD_COUNTS`
struct BadCounts <: Encoding end
const BAD_COUNTS = Ref((0, 0))
Inscription.load_into!(::AbstractBufReader, ::MutableMemoryView{Over{()}}, ::BadCounts) = BAD_COUNTS[]
Inscription.store_into(::AbstractBufWriter, ::MemoryView{Over{()}}, ::BadCounts) = BAD_COUNTS[]
Inscription.decode_all!(::MutableMemoryView{Over{()}}, ::MemoryView{UInt8}, ::BadCounts) = BAD_COUNTS[]
Inscription.encode_all!(::MutableMemoryView{UInt8}, ::MemoryView{Over{()}}, ::BadCounts) = BAD_COUNTS[]
# With a codec, `store_into` uses `encode_all!`
Inscription.codec_max_encoded_size(::Type{Over{()}}, ::BadCounts) = Val(4)
# `load_into!` loads nothing, but `try_load` does
struct LoadsAnyway <: Encoding end
Inscription.load_into!(::AbstractBufReader, ::MutableMemoryView{Over{()}}, ::LoadsAnyway) = (0, 0)
Inscription.try_load(::AbstractBufReader, ::Type{Over{()}}, ::LoadsAnyway) = Over{()}("")

@testset "Overloading: counts are checked" begin
    e = BadCounts()
    xs = hello_world(Over{()})
    for k in (-1, 3, typemin(Int), typemax(Int))
        BAD_COUNTS[] = (k, 0)
        @test_throws ErrorException load_all!(CursorReader(TWO), copy(xs), e)
        @test_throws ErrorException load_every!(CursorReader(TWO), copy(xs), e)
        @test_throws ErrorException store_all(VecWriter(), xs, e)
        @test_throws ErrorException store_every(VecWriter(), xs, e)
        @test_throws ErrorException decode_every!(copy(xs), TWO, e)
        @test_throws ErrorException encode_every!(zeros(UInt8, 12), xs, e)
    end
    for n in (-1, 13, typemin(Int), typemax(Int))
        BAD_COUNTS[] = (1, n)
        @test_throws ErrorException decode_every!(copy(xs), TWO, e)
        @test_throws ErrorException encode_every!(zeros(UInt8, 12), xs, e)
        writer = BoundedWriter(UInt8[], 12)
        @test_throws ErrorException invoke(
            store_into, Tuple{AbstractBufWriter, MemoryView{T}, Encoding} where {T}, writer, MemoryView(xs), e
        )
    end
    @test_throws ErrorException load_every!(CursorReader(TWO), copy(xs), LoadsAnyway())
end

# With a codec, an overload is an optimization, which the other functions use
struct Fast
    x::UInt8
end
Inscription.codec_scheme(::Type{Fast}, ::Endianness) = BitsLoadable()
const FAST_CALLS = Ref(0)
function Inscription.load_into!(io::AbstractBufReader, dst::MutableMemoryView{Fast}, ::BigEndian)
    FAST_CALLS[] += 1
    (isempty(dst) || eof(io)) && return (0, 0)
    dst[1] = Fast(read(io, UInt8))
    return (1, 1)
end

@testset "Overloading: with a codec" begin
    FAST_CALLS[] = 0
    dst = Vector{Fast}(undef, 3)
    @test load_every!(CursorReader([0x01, 0x02, 0x03]), dst, BigEndian()) == 3
    @test dst == [Fast(0x01), Fast(0x02), Fast(0x03)]
    @test FAST_CALLS[] == 3
    @test_error DecodeError(EndOfInput) load_every!(CursorReader([0x01]), dst, BigEndian())
    @test load(CursorReader([0x07]), Fast, BigEndian()) == Fast(0x07)
end
