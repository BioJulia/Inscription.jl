codec_max_encoded_size(::Type{Char}, ::UTF8) = 4

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

function codec_try_encoded_size(c::Char, ::UTF8)::Union{Int, EncodeError}
    return is_decodable(c) ? ncodeunits(c) : EncodeError(InvalidValue)
end

# Follows `iterate(::String)` exactly, see the docstring of `try_decode`.
@inline function codec_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{Char}, ::UTF8
    )::Union{Tuple{Char, Int}, DecodeError}
    isempty(mem) && return DecodeError(EndOfInput)
    lead = @inbounds mem[1]
    u = UInt32(lead) << 24
    # ASCII, stray continuation bytes, and f8-ff are single bytes
    (lead < 0xc0 || lead ≥ 0xf8) && return (reinterpret(Char, u), 1)
    max_len = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
    stop = min(max_len, length(mem))
    n = 1
    while n < stop
        byte = @inbounds mem[n + 1]
        byte & 0xc0 == 0x80 || break
        u |= UInt32(byte) << (24 - 8 * n)
        n += 1
    end
    return (reinterpret(Char, u), n)
end

# The encoding ends at the first byte that is not a continuation byte, or at the length
# that the lead byte allows, as in `codec_try_decode`. The byte that ends it early decides
# the result too.
@inline function codec_bytes_needed(mem::ImmutableMemoryView{UInt8}, ::Type{Char}, ::UTF8)::Int
    isempty(mem) && return 1
    lead = @inbounds mem[1]
    (lead < 0xc0 || lead ≥ 0xf8) && return 1
    max_len = lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4
    for k in 2:max_len
        k > length(mem) && return k
        (@inbounds mem[k]) & 0xc0 == 0x80 || return k
    end
    return max_len
end

# Writes the code units of `c` as they are. Malformed Chars that `iterate(::String)` can
# produce are written, so that the Chars of any String encode to its code units.
@inline function codec_try_encode!(mem::MutableMemoryView{UInt8}, c::Char, ::UTF8)::Union{Int, EncodeError}
    is_decodable(c) || return EncodeError(InvalidValue)
    u = reinterpret(UInt32, c)
    n = ncodeunits(c)
    length(mem) < n && return EncodeError(InsufficientSpace)
    # The code units are the leading bytes of u, most significant first. Only they are
    # written: the bytes after them are not ours, by the contract of `codec_try_encode!`.
    for i in 1:n
        @inbounds mem[i] = (u >> (32 - 8 * i)) % UInt8
    end
    return n
end
