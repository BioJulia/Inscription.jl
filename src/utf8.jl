codec_max_encoded_size(::Type{Char}, ::UTF8) = 4

# Every Char can be encoded, see `codec_try_encode!`
codec_try_encoded_size(c::Char, ::UTF8) = ncodeunits(c)

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

# Writes the code units of `c` as they are, without validating it.
@inline function codec_try_encode!(mem::MutableMemoryView{UInt8}, c::Char, ::UTF8)::Union{Int, EncodeError}
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
