"""
    module BufferSerde

Load and store primitive values to and from byte arrays and BufferIO's IO types.
"""
module BufferSerde

using MemoryViews: MemoryViews, MemoryView, ImmutableMemoryView, MutableMemoryView
using BufferIO: BufferIO,
    AbstractBufReader,
    AbstractBufWriter,
    IOError,
    IOErrorKinds,
    get_buffer,
    get_nonempty_buffer,
    consume

export Encoding,
    LittleEndian,
    BigEndian,
    Endianness,
    NATIVE_ENDIAN,
    UTF8,
    DecodeError,
    DecodeErrorKinds,
    @try_return,
    max_encoded_size,
    try_decode,
    decode,
    encode!,
    try_load,
    load,
    store,
    decode_into!,
    encode_into!,
    load_into!,
    load_all!,
    store_all

public Little,
    Big,
    BitsKind,
    BitsLoadable,
    BitsStorable,
    NotBits,
    bits_kind,
    is_valid_bits,
    codec_max_encoded_size,
    codec_try_decode,
    codec_encode!

include("encodings.jl")
include("errors.jl")
include("interface.jl")
include("bits.jl")
include("utf8.jl")
include("io.jl")
include("bulk.jl")
include("convenience.jl")

end # module BufferSerde
