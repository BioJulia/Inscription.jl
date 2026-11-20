# Tuples with the byte-order encodings. A tuple is encoded as the encodings of its
# elements, one after another, without padding.
#
# If the tuple type satisfies the requirements of a bits struct, see `BitsKind`, that is
# its memory representation, up to byte order. Then it is a bits type: `BitsLoadable` if
# all its element types are, else `BitsStorable` if none is `Opaque`. Otherwise, e.g. if
# it has padding in memory, or an element type has a hand-written codec, it is `Opaque`,
# and the codec below encodes its elements one by one. Since the requirements are checked
# against the strictest layout of any platform, which one applies is the same on every
# platform.
#
# Both encode a value as the same bytes, and decode the same bytes as the same value. They
# may differ when decoding fails: a bits type is decided by all of its bytes, so input
# that is both too short and invalid gives `Truncated`. Element by element, an invalid
# element decides the result, so the same input may give `InvalidData`, and a load does
# not wait for the rest of the tuple.

bits_kind(::Type{T}) where {T <: Tuple} = tuple_bits_kind(T)

# `bits_type_error` checks the kinds of the elements, and the layout. It is constant-
# folded if the `bits_kind` methods of the elements are foldable, and so is this.
function tuple_bits_kind(::Type{T})::BitsKind where {T}
    isbitstype(T) || return Opaque()
    bits_type_error(T, BitsLoadable()) === nothing && return BitsLoadable()
    bits_type_error(T, BitsStorable()) === nothing && return BitsStorable()
    return Opaque()
end

# A `BitsStorable` tuple has no invariants beyond those of its elements, which are
# checked before this is called.
is_valid_bits(::Type{<:Tuple}, ::NTuple{N, UInt8}) where {N} = true

# The codec of `Opaque` tuples. Its methods are generated from the element types, so they
# are unrolled and type stable. The generators only use the element types, not methods
# that may be added later.
for E in (LittleEndian, BigEndian)
    @eval begin
        @inline function codec_max_encoded_size(::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_max_encoded_size(T, enc)
        end
        @inline function codec_try_encoded_size(x::Tuple, enc::$E)
            return tuple_try_encoded_size(x, enc)
        end
        @inline function codec_try_decode(mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_try_decode(mem, T, enc)
        end
        @inline function codec_bytes_needed(mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_bytes_needed(mem, T, enc)
        end
        @inline function codec_try_encode!(mem::MutableMemoryView{UInt8}, x::Tuple, enc::$E)
            return tuple_try_encode!(mem, x, enc)
        end
    end
end

# Why the tuple type T can't be encoded element by element, or `nothing` if it can.
function tuple_type_error(T::Type)::Union{Nothing, String}
    isconcretetype(T) || return "`$T` is not a concrete tuple type, so it can't be encoded"
    fieldcount(T) == 0 && return "`$T` has no elements: types of size zero are not supported"
    return nothing
end

# The body of a generated function for the tuple type T: `body`, or a throw if T can't be
# encoded element by element
function tuple_body(T::Type, body::Function)::Expr
    message = tuple_type_error(T)
    message === nothing || return :(throw(ArgumentError($message)))
    return Expr(:block, Expr(:meta, :inline), body(fieldtypes(T))...)
end

@generated function tuple_max_encoded_size(::Type{T}, enc::Endianness) where {T}
    return tuple_body(T, Fs -> (:(+($((:(max_encoded_size($F, enc)) for F in Fs)...))),))
end

@generated function tuple_try_encoded_size(x::Tuple, enc::Endianness)
    return tuple_body(
        x, Fs -> [
            :(n = 0);
            [:(n += @try_return try_encoded_size(x[$i], enc)) for i in eachindex(Fs)];
            :(return n)
        ]
    )
end

@generated function tuple_try_decode(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Endianness
    ) where {T}
    return tuple_body(
        T, Fs -> begin
            xs = [Symbol(:x, i) for i in eachindex(Fs)]
            [
                :(offset = 0);
                [
                    :(($(xs[i]), offset) = @try_return try_decode_element(mem, offset, $F, enc))
                        for (i, F) in enumerate(Fs)
                ];
                :(return (tuple($(xs...)), offset))
            ]
        end
    )
end

# Decode the element type F at byte offset `offset` of `mem`, which is at most the
# length of `mem`, and return it with the offset after it, or the error of the tuple
@inline function try_decode_element(
        mem::ImmutableMemoryView{UInt8}, offset::Int, ::Type{F}, enc::Endianness
    )::Union{Tuple{F, Int}, DecodeError} where {F}
    result = try_decode_sized(unsafe_suffix(mem, offset + 1), 1, F, enc)
    if result isa DecodeError
        # The input ended after the encodings of the elements before, so within the tuple
        result.kind === EndOfInput && offset > 0 && return DecodeError(Truncated)
        return result
    end
    (x, n) = result
    return (x, offset + n)
end

# The bytes that decide the result of decoding a T are those that decide each element,
# up to the first one that fails to decode, see `codec_bytes_needed`. Elements are only
# decoded from bytes that decide them, so they decode as from the complete input.
@generated function tuple_bytes_needed(
        mem::ImmutableMemoryView{UInt8}, ::Type{T}, enc::Endianness
    ) where {T}
    return tuple_body(
        T, Fs -> [
            :(offset = 0);
            # An element may need bytes after its encoding, e.g. a terminator
            :(decided = 0);
            [
                quote
                    rest = unsafe_suffix(mem, offset + 1)
                    needed = bytes_needed(rest, $F, enc)
                    decided = max(decided, offset + needed)
                    needed > length(rest) && return decided
                    result = try_decode_sized(rest, 1, $F, enc)
                    result isa DecodeError && return decided
                    offset += last(result)
                end
                    for F in Fs
            ];
            :(return decided)
        ]
    )
end

# Nothing may be written when there is too little space, so check the size first, unless
# there is room for any encoding. Then, the elements can only fail if they can't be
# encoded.
@generated function tuple_try_encode!(mem::MutableMemoryView{UInt8}, x::Tuple, enc::Endianness)
    return tuple_body(
        x, Fs -> [
            quote
                if length(mem) < max_encoded_size($x, enc)
                    size = @try_return try_encoded_size(x, enc)
                    length(mem) < size && return EncodeError(InsufficientSpace)
                end
                offset = 0
            end;
            [:(offset += @try_return _try_encode!(unsafe_suffix(mem, offset + 1), 1, x[$i], enc)) for i in eachindex(Fs)];
            :(return offset)
        ]
    )
end
