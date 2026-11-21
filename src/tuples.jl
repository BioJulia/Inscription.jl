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
            return Val(tuple_max_encoded_size(T, enc))
        end
        @inline function codec_try_decode(input::DecodeInput, ::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_try_decode(input, T, enc)
        end
        @inline function codec_try_encode!(output::EncodeOutput, x::Tuple, enc::$E)
            return tuple_try_encode!(output, x, enc)
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

# The elements are decoded with `decode_field`, which passes on the input after each
# element. On the fast path, the input of each element is known to hold its
# `max_encoded_size` bytes when the codec is compiled, also after elements whose
# encodings vary in size. With partial input, the result is decided when an element
# fails, or all elements are decided.
@generated function tuple_try_decode(input::DecodeInput, ::Type{T}, enc::Endianness) where {T}
    return tuple_body(
        T, Fs -> begin
            xs = [Symbol(:x, i) for i in eachindex(Fs)]
            ns = [Symbol(:n, i) for i in eachindex(Fs)]
            inputs = [Symbol(:input, i) for i in 0:length(Fs)]
            [
                :($(inputs[1]) = input);
                [
                    :(($(xs[i]), $(ns[i]), $(inputs[i + 1])) = @? decode_field($(inputs[i]), $F, enc))
                        for (i, F) in enumerate(Fs)
                ];
                :(return (tuple($(xs...)), +($(ns...))))
            ]
        end
    )
end

# As for decoding. If the output is too short, the elements before the one that didn't
# fit have been written, which the contract of `codec_try_encode!` allows.
@generated function tuple_try_encode!(output::EncodeOutput, x::Tuple, enc::Endianness)
    return tuple_body(
        x, Fs -> begin
            ns = [Symbol(:n, i) for i in eachindex(Fs)]
            outputs = [Symbol(:output, i) for i in 0:length(Fs)]
            [
                :($(outputs[1]) = output);
                [
                    :(($(ns[i]), $(outputs[i + 1])) = @? encode_field($(outputs[i]), x[$i], enc))
                        for i in eachindex(Fs)
                ];
                :(return +($(ns...)))
            ]
        end
    )
end
