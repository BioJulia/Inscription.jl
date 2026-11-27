using Test
using Aqua: Aqua
using Inscription
using Inscription: DecodeErrorKinds, EncodeErrorKinds, Little, Big
using Inscription: codec_scheme, BitsLoadable, BitsStorable, Manual, Proxy, validate_bits, as_unsigned
using Inscription: Unbounded, DecodeInput, EncodeOutput, TooShort, Invalid, require_bytes, peek_byte, decode_field, reserve_bytes, encode_field
using Inscription.DecodeErrorKinds: EndOfInput, Truncated, InvalidData, TrailingData
using Inscription.EncodeErrorKinds: InsufficientSpace, InvalidValue
using BufferIO
using BufferIO.Testing: BoundedReader, BoundedWriter, ChunkedReader
using MemoryViews: MemoryView, ImmutableMemoryView, MutableMemoryView
using LightBoundsErrors: LightBoundsError

include("setup.jl")

# The tests are in separate files, since Julia is slow to compile a single large testset
@testset "Inscription" begin
    include("basics.jl")
    include("utf8.jl")
    include("partial.jl")
    include("io.jl")
    include("bulk.jl")
    include("memory.jl")
    include("types.jl")
    include("proxy.jl")
    include("unbounded.jl")
    include("overloading.jl")
    include("payloads.jl")
    include("misc.jl")

    @testset "Aqua" begin
        Aqua.test_all(Inscription)
    end

    @testset "Doctests" begin
        using Documenter: DocMeta, doctest
        DocMeta.setdocmeta!(
            Inscription, :DocTestSetup, :(using Inscription, BufferIO; using MemoryViews: MemoryView);
            recursive = true,
        )
        doctest(Inscription; manual = false)
    end

end # testset Inscription
