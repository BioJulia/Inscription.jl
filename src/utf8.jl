codec_max_encoded_size(::Type{Char}, ::UTF8) = 4

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

# Writes the code units of `c` as they are, without validating it.
@inline function codec_encode!(mem::MutableMemoryView{UInt8}, c::Char, ::UTF8)::Union{Nothing, Int}
    u = reinterpret(UInt32, c)
    n = ncodeunits(c)
    if length(mem) ≥ 4
        # The code units are the leading bytes of u in big-endian order. The bytes
        # after them are scratch space, as allowed by the contract of `codec_encode!`.
        unsafe_store_bits(mem, 0, u, BigEndian())
        return n
    end
    # Don't outline this: passing `mem` to a non-inlined function makes every call
    # store it to the stack as a GC root, also on the fast path. Inline, LLVM compiles
    # this loop to a masked store.
    length(mem) < n && return nothing
    for i in 1:n
        @inbounds mem[i] = (u >> (32 - 8 * i)) % UInt8
    end
    return n
end
