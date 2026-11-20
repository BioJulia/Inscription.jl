# Methods that accept memory of other types than `MemoryView`, such as `Vector{UInt8}`,
# by viewing it as a `MemoryView`. They are less specific than the methods for
# `MemoryView`, so a type of memory can later get methods of its own, e.g. methods that
# read a `String` through a pointer, without changing what the functions do.

# Strings and their code units are not viewed, because their bytes are not in a `Memory`,
# so viewing them allocates a `Memory` header. Done implicitly, that would happen on every
# call, e.g. for every value decoded from a string.
const StringLike = Union{AbstractString, Base.CodeUnits}

# `x` viewed as bytes that are only read.
@inline input_bytes(x) = MemoryView(x)::MemoryView{UInt8}
# `x` viewed as bytes that are written.
@inline output_bytes(x) = MemoryView(x)::MutableMemoryView{UInt8}
# `x` viewed as elements that are only read.
@inline input_elements(x) = MemoryView(x)::MemoryView
# `x` viewed as elements that are written.
@inline output_elements(x) = MemoryView(x)::MutableMemoryView

# The type assertions above also prevent an infinite recursion: a `MemoryView` of the
# wrong element type or mutability is its own view, so without them, e.g. the method of
# `try_decode` below would call itself with a `MemoryView{Int8}`.

for f in (:input_bytes, :output_bytes, :input_elements, :output_elements)
    @eval $f(x::StringLike) = throw_string_error(typeof(x))
end

@noinline function throw_string_error(T::Type)
    throw(
        ArgumentError(
            "A `$T` is not converted to a `MemoryView` implicitly, since that allocates, " *
                "which would happen on every call. Convert it once with `MemoryView`, " *
                "and use the index arguments to decode at different positions."
        )
    )
end

# The `try_` functions ignore `@inbounds`, and the others propagate it, as their methods
# for `MemoryView` do. Index arguments are converted to `Int` here, where they enter the
# package, so only `Int` indices are passed on.

@inline function try_decode(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return try_decode(input_bytes(mem), Int(i)::Int, T, enc)
end

@inline function try_decode(mem, ::Type{T}, enc::Encoding) where {T}
    return try_decode(input_bytes(mem), T, enc)
end

Base.@propagate_inbounds function decode(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return decode(input_bytes(mem), Int(i)::Int, T, enc)
end

Base.@propagate_inbounds function decode(mem, ::Type{T}, enc::Encoding) where {T}
    return decode(input_bytes(mem), T, enc)
end

@inline function try_decode_next(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return try_decode_next(input_bytes(mem), Int(i)::Int, T, enc)
end

Base.@propagate_inbounds function decode_next(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return decode_next(input_bytes(mem), Int(i)::Int, T, enc)
end

@inline function try_decode_exact(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return try_decode_exact(input_bytes(mem), Int(i)::Int, T, enc)
end

@inline function try_decode_exact(mem, ::Type{T}, enc::Encoding) where {T}
    return try_decode_exact(input_bytes(mem), T, enc)
end

Base.@propagate_inbounds function decode_exact(mem, i::Integer, ::Type{T}, enc::Encoding) where {T}
    return decode_exact(input_bytes(mem), Int(i)::Int, T, enc)
end

Base.@propagate_inbounds function decode_exact(mem, ::Type{T}, enc::Encoding) where {T}
    return decode_exact(input_bytes(mem), T, enc)
end

@inline function try_encode!(mem, i::Integer, x, enc::Encoding)
    return try_encode!(output_bytes(mem), Int(i)::Int, x, enc)
end

@inline function try_encode!(mem, x, enc::Encoding)
    return try_encode!(output_bytes(mem), x, enc)
end

Base.@propagate_inbounds function encode!(mem, i::Integer, x, enc::Encoding)
    return encode!(output_bytes(mem), Int(i)::Int, x, enc)
end

Base.@propagate_inbounds function encode!(mem, x, enc::Encoding)
    return encode!(output_bytes(mem), x, enc)
end

function decode_all!(dst, src, enc::Encoding)
    return decode_all!(output_elements(dst), input_bytes(src), enc)
end

function decode_every!(dst, src, enc::Encoding)
    return decode_every!(output_elements(dst), input_bytes(src), enc)
end

function encode_all!(dst, src, enc::Encoding)
    return encode_all!(output_bytes(dst), input_elements(src), enc)
end

function encode_every!(dst, src, enc::Encoding)
    return encode_every!(output_bytes(dst), input_elements(src), enc)
end

function load_into!(io::AbstractBufReader, dst, enc::Encoding)
    return load_into!(io, output_elements(dst), enc)
end

function load_all!(io::AbstractBufReader, dst, enc::Encoding)
    return load_all!(io, output_elements(dst), enc)
end

function load_every!(io::AbstractBufReader, dst, enc::Encoding)
    return load_every!(io, output_elements(dst), enc)
end

function store_into(io::AbstractBufWriter, src, enc::Encoding)
    return store_into(io, input_elements(src), enc)
end

function store_all(io::AbstractBufWriter, src, enc::Encoding)
    return store_all(io, input_elements(src), enc)
end

function store_every(io::AbstractBufWriter, src, enc::Encoding)
    return store_every(io, input_elements(src), enc)
end
