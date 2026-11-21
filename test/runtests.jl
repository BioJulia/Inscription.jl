using Test
using Aqua: Aqua
using BitScribbling
using BitScribbling: DecodeErrorKinds, EncodeErrorKinds, Little, Big
using BitScribbling: bits_kind, BitsLoadable, BitsStorable, Opaque, is_valid_bits, as_unsigned
using BitScribbling: DecodeInput, EncodeOutput, TooShort, Invalid, require_bytes, peek_byte, decode_field, reserve_bytes, encode_field
using BitScribbling.DecodeErrorKinds: EndOfInput, Truncated, InvalidData, TrailingData
using BitScribbling.EncodeErrorKinds: InsufficientSpace, InvalidValue
using BufferIO
using BufferIO.Testing: BoundedReader, BoundedWriter, ChunkedReader
using MemoryViews: MemoryView, ImmutableMemoryView, MutableMemoryView
using LightBoundsErrors: LightBoundsError

include("setup.jl")

# The tests are in separate files, since Julia is slow to compile a single large testset
@testset "BitScribbling" begin
    include("basics.jl")
    include("utf8.jl")
    include("partial.jl")
    include("io.jl")
    include("bulk.jl")
    include("memory.jl")
    include("types.jl")
    include("misc.jl")

    @testset "Aqua" begin
        Aqua.test_all(BitScribbling)
    end

    @testset "Doctests" begin
        using Documenter: DocMeta, doctest
        DocMeta.setdocmeta!(
            BitScribbling, :DocTestSetup, :(using BitScribbling, BufferIO; using MemoryViews: MemoryView);
            recursive = true,
        )
        doctest(BitScribbling; manual = false)
    end

end # testset BitScribbling
