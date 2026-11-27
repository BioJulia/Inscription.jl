codec_max_encoded_size(::Type{Char}, ::UTF8) = Val(4)

# Any bytes decode as a Char, possibly malformed, see the docstring of `UTF8`
codec_decode_invalid_type(::Type{Char}, ::UTF8) = Union{}

# Whether `c` is a Char that `codec_try_decode` can return, i.e. one that
# `iterate(::String)` can produce. Other Chars can only be made with e.g. `reinterpret`,
# and their code units don't decode to themselves, so they can't be encoded.
@inline function is_decodable(c::Char)::Bool
    u = reinterpret(UInt32, c)
    n = ncodeunits(c)
    lead = (u >> 24) % UInt8
    (lead < 0xc0 || lead ≥ 0xf8) && return n == 1
    max_len = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
    n ≤ max_len || return false
    # Code units 2:n must be continuation bytes. The bytes after them are zero.
    return ((u & 0x00c0c0c0) ⊻ 0x00808080) >> (8 * (4 - n)) == 0
end

# Follows `iterate(::String)` exactly, see the docstring of `UTF8`. The encoding ends at
# the first byte that is not a continuation byte, or at the length that the lead byte
# allows. If the input ends before either, the bytes so far are a malformed Char.
@inline function codec_try_decode(input::DecodeInput, ::Type{Char}, ::UTF8)
    lead = (@? require_bytes(input, 1))[1]
    u = UInt32(lead) << 24
    # ASCII, stray continuation bytes, and f8-ff are single bytes
    (lead < 0xc0 || lead ≥ 0xf8) && return (reinterpret(Char, u), 1)
    max_len = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
    n = 1
    while n < max_len
        byte = @? peek_byte(input, n + 1)
        (byte === nothing || byte & 0xc0 != 0x80) && break
        u |= UInt32(byte) << (24 - 8 * n)
        n += 1
    end
    return (reinterpret(Char, u), n)
end

# Writes the code units of `c` as they are. Malformed Chars that `iterate(::String)` can
# produce are written, so that the Chars of any String encode to its code units.
@inline function codec_try_encode!(output::EncodeOutput, c::Char, ::UTF8)
    is_decodable(c) || return Invalid()
    u = reinterpret(UInt32, c)
    n = ncodeunits(c)
    mem = @? reserve_bytes(output, n)
    # The code units are the leading bytes of u, most significant first. `mem` has length
    # `n`, so the bounds checks are removed.
    mem[1] = (u >> 24) % UInt8
    n ≥ 2 && (mem[2] = (u >> 16) % UInt8)
    n ≥ 3 && (mem[3] = (u >> 8) % UInt8)
    n ≥ 4 && (mem[4] = u % UInt8)
    return n
end
