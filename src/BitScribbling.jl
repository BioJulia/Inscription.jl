"""
    module BitScribbling

Encode and decode values of bitstypes, i.e. types for which `isbitstype` is true, to
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
    BitsKind,
    BitsLoadable,
    BitsStorable,
    Opaque,
    bits_kind,
    is_valid_bits,
    as_unsigned,
    codec_max_encoded_size,
    codec_try_decode,
    codec_try_encode!,
    DecodeInput,
    EncodeOutput,
    TooShort,
    Invalid,
    require_bytes,
    peek_byte,
    decode_field,
    reserve_bytes,
    encode_field

include("encodings.jl")
include("errors.jl")
include("interface.jl")
include("bits.jl")
include("utf8.jl")
include("tuples.jl")
include("io.jl")
include("bulk.jl")
include("memory.jl")
include("convenience.jl")

end # module BitScribbling
