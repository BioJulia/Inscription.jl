# Tuples with the byte-order encodings. A tuple is encoded as the encodings of its
# elements, one after another, without padding.
#
# If the tuple type satisfies the requirements of a bits struct, see `BitsLoadable`, that
# is its memory representation, up to byte order. Then it is a bits type: `BitsLoadable`
# if all its element types are, else `BitsStorable` if all are bits types. Otherwise, e.g.
# if it has padding in memory, or an element type has a hand-written codec or a proxy, it
# is `Manual`, and the codec below encodes its elements one by one. Since the requirements are checked
# against the strictest layout of any platform, which one applies is the same on every
# platform.
#
# Both encode a value as the same bytes, and decode the same bytes as the same value. They
# may differ when decoding fails: a bits type is decided by all of its bytes, so input
# that is both too short and invalid gives `Truncated`. Element by element, an invalid
# element decides the result, so the same input may give `InvalidData`, and a load does
# not wait for the rest of the tuple.

codec_scheme(::Type{T}, enc::Endianness) where {T <: Tuple} = tuple_scheme(T, enc)

# `bits_type_error` checks the schemes of the elements, and the layout. It is constant-
# folded if the `codec_scheme` methods of the elements are foldable, and so is this.
function tuple_scheme(::Type{T}, enc::Endianness)::CodecScheme where {T}
    isbitstype(T) || return Manual()
    bits_type_error(T, BitsLoadable(), enc) === nothing && return BitsLoadable()
    bits_type_error(T, BitsStorable(), enc) === nothing && return BitsStorable()
    return Manual()
end

# A `BitsStorable` tuple has no invariants beyond those of its elements, which are
# checked before this is called.
validate_bits(::Type{<:Tuple}, ::NTuple{N, UInt8}) where {N} = nothing

# A tuple returns no `Invalid` of its own, but passes on those of its elements, so its
# payload type is the union of theirs. That is also so for `BitsStorable` tuples, whose
# payload type is that of the tuple and its elements, see `bits_decode_invalid_type`.
# The tuple codec converts the `Invalid` of an element to the payload type of the tuple,
# so that its result has the same concrete type, whichever element failed.

# The codec of `Manual` tuples. Its methods are generated from the element types, so they
# are unrolled and type stable. The generators only use the element types, not methods
# that may be added later.
for E in (LittleEndian, BigEndian)
    @eval begin
        @inline function codec_max_encoded_size(::Type{T}, enc::$E) where {T <: Tuple}
            return as_val(tuple_max_encoded_size(T, enc))
        end
        @inline function codec_try_decode(input::DecodeInput, ::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_try_decode(input, T, enc)
        end
        @inline function codec_try_encode!(output::EncodeOutput, x::Tuple, enc::$E)
            return tuple_try_encode!(output, x, enc)
        end
        @inline function codec_decode_invalid_type(::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_decode_invalid_type(T, enc)
        end
        @inline function codec_encode_invalid_type(::Type{T}, enc::$E) where {T <: Tuple}
            return tuple_encode_invalid_type(T, enc)
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
    return tuple_body(T, Fs -> (:(add_sizes($((:(max_encoded_size($F, enc)) for F in Fs)...))),))
end

@generated function tuple_decode_invalid_type(::Type{T}, enc::Endianness) where {T}
    return tuple_body(T, Fs -> (:(Union{$((:(decode_invalid_type($F, enc)) for F in Fs)...)}),))
end

@generated function tuple_encode_invalid_type(::Type{T}, enc::Endianness) where {T}
    return tuple_body(T, Fs -> (:(Union{$((:(encode_invalid_type($F, enc)) for F in Fs)...)}),))
end

# A tuple with an unbounded element is unbounded
@inline add_sizes(ns::Int...) = +(ns...)
@inline add_sizes(::Union{Int, Unbounded}...) = Unbounded()
@inline as_val(n::Int) = Val(n)
@inline as_val(n::Unbounded) = n

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
                    :(
                        ($(xs[i]), $(ns[i]), $(inputs[i + 1])) = @? widen_decode_invalid(
                            decode_field($(inputs[i]), $F, enc), codec_try_decode, T, enc
                        )
                    ) for (i, F) in enumerate(Fs)
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
                    :(
                        ($(ns[i]), $(outputs[i + 1])) = @? widen_encode_invalid(
                            encode_field($(outputs[i]), x[$i], enc), codec_try_encode!, $x, enc
                        )
                    ) for i in eachindex(Fs)
                ];
                :(return +($(ns...)))
            ]
        end
    )
end
