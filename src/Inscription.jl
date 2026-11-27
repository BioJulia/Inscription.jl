"""
    module Inscription

Encode and decode values, such as integers, floats, `Char`, structs
to and from byte arrays and BufferIO's I/O types.
"""
module Inscription

using MemoryViews: MemoryViews, MemoryView, ImmutableMemoryView, MutableMemoryView, split_at
using LightBoundsErrors: throw_lightboundserror
using BufferIO: BufferIO,
    AbstractBufReader,
    AbstractBufWriter,
    IOError,
    IOErrorKinds,
    get_buffer,
    get_nonempty_buffer,
    is_expandable,
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
    @?,
    max_encoded_size,
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
    decode_all!,
    decode_every!,
    encode_all!,
    encode_every!,
    load_into!,
    load_all!,
    load_every!,
    store_into,
    store_all,
    store_every

public Little,
    Big,
    CodecScheme,
    BitsLoadable,
    BitsStorable,
    Manual,
    Proxy,
    codec_scheme,
    try_to_proxy,
    try_from_proxy,
    validate_bits,
    is_padding_free,
    as_unsigned,
    codec_max_encoded_size,
    Unbounded,
    codec_try_decode,
    codec_try_encode!,
    DecodeInput,
    EncodeOutput,
    TooShort,
    Invalid,
    codec_decode_invalid_type,
    codec_encode_invalid_type,
    decode_invalid_type,
    encode_invalid_type,
    require_bytes,
    peek_byte,
    decode_field,
    reserve_bytes,
    encode_field

include("encodings.jl")
include("errors.jl")
include("schemes.jl")
include("interface.jl")
include("bits.jl")
include("utf8.jl")
include("tuples.jl")
include("io.jl")
include("bulk.jl")
include("memory.jl")
include("convenience.jl")

end # module Inscription
