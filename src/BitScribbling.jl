"""
    module BitScribbling

Encode and decode values of bits types, i.e. types for which `isbitstype` is true, to
and from byte arrays and BufferIO's IO types.
"""
module BitScribbling

using MemoryViews: MemoryViews, MemoryView, ImmutableMemoryView, MutableMemoryView, split_at
using LightBoundsErrors: throw_lightboundserror
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
    EncodeError,
    EncodeErrorKinds,
    @try_return,
    max_encoded_size,
    try_encoded_size,
    encoded_size,
    try_decode,
    decode,
    try_decode_next,
    decode_next,
    try_decode_exact,
    decode_exact,
    try_encode!,
    encode!,
    try_load,
    load,
    try_load_exact,
    load_exact,
    try_store,
    store,
    decode_into!,
    encode_into!,
    load_into!,
    load_all!,
    load!,
    store_all

public Little,
    Big,
    BitsKind,
    BitsLoadable,
    BitsStorable,
    ManualCodec,
    bits_kind,
    is_valid_bits,
    as_unsigned,
    codec_max_encoded_size,
    codec_encoded_size,
    codec_try_decode,
    codec_bytes_needed,
    codec_encode!

include("encodings.jl")
include("errors.jl")
include("interface.jl")
include("bits.jl")
include("utf8.jl")
include("io.jl")
include("bulk.jl")
include("memory.jl")
include("convenience.jl")

end # module BitScribbling
