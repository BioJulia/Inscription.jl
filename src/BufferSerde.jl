module BufferSerde

using MemoryViews: ImmutableMemoryView, MutableMemoryView
using BufferIO: AbstractBufReader, AbstractBufWriter

struct LittleEndian end
struct BigEndian end
const Endianness = Union{LittleEndian, BigEndian}

# Note that this is separate from Base.bswap since this works for _all_
# primitive types.
@static if ENDIAN_BOM === 0x04030201
    byte_order(::LittleEndian, x) = x
    byte_order(::BigEndian, x) = Core.Intrinsics.bswap_int(x)
else
    byte_order(::BigEndian, x) = x
    byte_order(::LittleEndian, x) = Core.Intrinsics.bswap_int(x)
end

"""
    abstract type PrimitiveSerialization

Trait type to control if a primitive type is readable by loading and/or storing
its binary represenation directly using a pointer.

Currently, three options are available:
* `NonSerializablePrimitive` for types which require custom serialization
  such as `Char`, whose serialization depends on the number of UTF8 codepoints
* `WriteOnlyPrimitive` for types whose serialization matches its in-memory
  representation, but where not all bitpatterns are valid instances. Hence, they
  require custom loading, but storing an instance can be done with a pointer store.
* `SerializablePrimitive` for types whose serialization match its in-memory
  representation, and where all bitpatterns are valid.

`PrimitiveSerialization(::Type)` defaults to `NonSerializablePrimitive()`.
Implement `PrimitiveSerialization(::T) = ReadablePrimitive()` for your primitive `T`
to enable BufferIO de/serialization.

See also: [`ReadablePrimitive`](@ref), [`NonReadablePrimitive`](@ref)
"""
abstract type PrimitiveSerialization end

"""
    SerializablePrimitive <: PrimitiveSerialization

Trait object controlling BufferIO serializability of primitive types.
See [`PrimitiveSerialization`](@ref) for more details.
"""
struct SerializablePrimitive <: PrimitiveSerialization end

"""
    NonSerializablePrimitive <: PrimitiveSerialization

Trait object controlling BufferIO serializability of primitive types.
See [`PrimitiveSerialization`](@ref) for more details.
"""
struct NonSerializablePrimitive <: PrimitiveSerialization end

"""
    WriteOnlyPrimitive <: PrimitiveSerialization

Trait object controlling BufferIO serializability of primitive types.
See [`PrimitiveSerialization`](@ref) for more details.
"""
struct WriteOnlyPrimitive <: PrimitiveSerialization end

function PrimitiveSerialization(T::Type)
    if !isprimitivetype(T)
        throw(ArgumentError("Type must be a primitive type, or a zero-sized immutable struct"))
    end
    return NonSerializablePrimitive()
end

function PrimitiveSerialization(
        ::Union{
            # Julia has special codegen to make Bool pointer-loadable without
            # being able to create invalid instances (the pointer load will
            # mask out all bits but the lowest one), so this is surprisingly correct
            Type{Bool},
            Type{UInt8}, Type{UInt16}, Type{UInt32}, Type{UInt64}, Type{UInt128},
            Type{Int8}, Type{Int16}, Type{Int32}, Type{Int64}, Type{Int128},
            Type{Float16}, Type{Float32}, Type{Float64},
        }
    )
    return SerializablePrimitive()
end

"""
    load(io::AbstractBufReader, T::Type, ::Endianness)::Union{T, Nothing}

Load a value of `T` from `io`, and consume the bytes from `io`.
Return `nothing` if `io` reaches EOF before providing enough bytes.

Throw an `IOError` with kind `EOF `if its buffer does not contain a whole `T`,
and repeated calls to `fill_buffer` returns `nothing` before it does so,
and `io` reaches EOF after consuming a partial `T`.

# Examples
```jldoctest
julia> io = CursorReader(b"abcde");

julia> load(io, UInt32, LittleEndian())
0x64636261

julia> load(io, UInt32, LittleEndian()) === nothing
true
```

# Extended help
`T` must be a primitive type.

Structs, and primitive types with non-trivial serialization such as `Char`
are intentionally not supported, and will require an external serialization package.

`PrimitiveSerialization(T)` is used to determine if the value can be loaded,
and `Base.sizeof(T)` is used to determine how many bytes to load.

The endianness of the serialized data is given by the argument; if this differs from the platform,
the value will be byte swapped.
Endianness is typically format-specific. Custom types `B` implementing `AbstractBufReader`
may want to define a custom convenience method
`BufferIO.load(io::B, T::Type) = load(io, T, BufferIO.LittleEndian())`
or similar, to avoid repeatedly having to repeat the endianness for every call.

Custom primitive types `C` can implement
`load(::AbstractBufReader, ::Type{C}, ::Endianness)`. If the implementation simply
loads `sizeof(C)` through a pointer, implementing `PrimitiveSerialization(T)` instead will
make the generic `load` method work.
"""
function load(
        io::AbstractBufReader,
        T::Type,
        endianness::Endianness
    )
    return _load(PrimitiveSerialization(T), io, T, endianness)
end

function _load(
        ::SerializablePrimitive,
        io::AbstractBufReader,
        T::Type,
        endianness::Endianness
    )
    sz = UInt(sizeof(T))::UInt
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    # Fast path: The requisite bytes are immediately available
    return if length(buffer) % UInt ≥ sz
        value = GC.@preserve buffer unsafe_load(Ptr{T}(pointer(buffer)))
        value = byte_order(endianness, value)
        @inbounds consume(io, sz % Int)
        value
    else
        @noinline _load_slow_path(io, T, endianness)
    end
end

function _load_slow_path(
        io::AbstractBufReader,
        T::Type,
        endianness::Endianness
    )
    # Second-fastest path: We continually fill buffer until we have enough bytes,
    # or it cannot expand further.
    # We reload buffer here instead of passing it in order to keep the stack space
    # needed by the caller (fast path) smaller
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    buffer_length = length(buffer) % UInt
    sz = UInt(sizeof(T))::UInt
    while true
        n_filled = fill_buffer(io)::Union{Nothing, Int}
        # Buffer cannot expand - use even slower more complex path
        isnothing(n_filled) && return @noinline _load_slower_path(io, buffer, T, endianness)
        iszero(n_filled) && return nothing
        buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
        if n_filled < 0 || (buffer_length % Int) + n_filled != length(buffer)
            error("Bad implementation of io")
        end
        buffer_length = length(buffer) % UInt
        if buffer_length ≥ sz
            value = GC.@preserve buffer unsafe_load(Ptr{T}(pointer(buffer)))
            value = byte_order(endianness, value)
            @inbounds consume(io, sz % Int)
            return value
        end
    end
    error("Unreachable")
end

# Even slower path: We build the T byte-by-byte by bitshifting.
function _load_slower_path(
        io::AbstractBufReader,
        buffer::ImmutableMemoryView{UInt8},
        T::Type,
        endianness::Endianness
    )
    # Create instance of T made of zeros
    result = Core.Intrinsics.zext_int(T, 0x00)
    sz = UInt(sizeof(T))::UInt
    remaining = sz
    while true
        to_read = min((remaining % Int), length(buffer))
        for i in 1:to_read
            # Add the byte from the buffer to the right of the integer.
            # This builds it big-endian
            byte = @inbounds buffer[i]
            result = Core.Intrinsics.shl_int(result, 8)
            result = Core.Intrinsics.or_int(result, Core.Intrinsics.zext_int(T, byte))
        end
        remaining -= to_read % UInt
        @inbounds consume(io, to_read)
        # Since we built it big-endian, we need to swap it if necessary
        if iszero(remaining)
            return endianness === LittleEndian() ? Core.Intrinsics.bswap_int(result) : result
        end
        n_filled = fill_buffer(io)::Union{Nothing, Int}
        # This should never happen:
        # If the buffer is equal to or larger than remaining, then we should have
        # returned above, and don't reach this.
        # If buffer is smaller than remaining, we just consumed it entirely in the consume
        # above. Hence, the buffer is empty. AbstractBufReader documents that fill_buffer
        # should never return nothing when the buffer is empty.
        (n_filled === nothing || n_filled < 0) && error("Bad IO implementation")
        iszero(n_filled) && throw(IOError(IOErrorKinds.EOF))
        buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
        length(buffer) == n_filled || error("Bad IO implementation")
    end
    error("Unreachable")
end

function load(io::AbstractBufWriter, ::Type{UInt8})
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    if isempty(buffer)
        fill_buffer(io)
        buffer = get_buffer(io)
        isempty(buffer) && return nothing
    end
    return @inbounds buffer[1]
end

# TODO: When throwing, need to communicate how much has been consumed
"""
    load_into!(io::AbstractBufReader, mem::MutableMemory{T}, endianness::Endianness)::Int

Returns number of elements loaded. Obtain bytes by multiplying with sizeof(T).
Document serializability
Similar to calling load repeatedly, but may be more efficient
"""
function load_into!(io::AbstractBufWriter, mem::MutableMemoryView{T}, endianness::Endianness) where {T}
    return _load_into!(PrimitiveSerialization(T), io, mem, endianness)
end

function _load_into!(
        ::SerializablePrimitive,
        io::AbstractBufReader,
        mem::MutableMemoryView{T},
        endianness::Endianness,
    ) where {T}
    sz = UInt(sizeof(T))::UInt
    iszero(sz) && return length(mem)
    buffer = get_buffer(io)::ImmutableMemoryView{UInt8}
    len = length(buffer) % UInt
    if len % UInt ≥ sz
        n_elem = div(len, sz)
        n_bytes = (n_elem * sz) % Int
        GC.@preserve buffer mem begin
            src = pointer(buffer)
            dst = Ptr{UInt8}(pointer(mem))
            # TODO: This only works for native
            unsafe_copyto!(dst, src, n_bytes)
        end
        @inbounds consume(io, n_bytes)
        return n_elem % Int
    else
        return @noinline _load_into_slowpath!() # TODO
    end
end

"""
    store(io::AbstractBufWriter, x, endianness::Endianness)::Nothing

Store `x` into `io`, and consume the stored bytes from `io`.
If the buffer cannot grow to the size of `x`, throw an `IOError` with kind `BufferTooShort`.

# Extended help
`T` must be a zero-sized immutable struct or a primitive type.
Structs are intentionally not supported, and requires an external serialization package.
`PrimitiveSerialization(T)` is used to determine if the value can be loaded,
and `Base.sizeof(T)` is used to determine how many bytes to load.

The endianness of the serialized data is given by the argument; if this differs from the platform,
the value will be byte swapped.
Endianness is typically format-specific. Custom types `W` implementing `AbstractBufWriter`
may want to define a custom convenience method
`BufferIO.store(io::W, x::SomeType) = store(io, x, BufferIO.LittleEndian())`
or similar, to avoid repeatedly having to repeat the endianness for every call.

Custom primitive types `C` can implement
`store(::AbstractBufWriter, x::C, ::Endianness)`. If the implementation simply
loads `sizeof(C)` through a pointer, implementing `PrimitiveSerialization(T)` instead will
make the generic `store` method work.
"""
function store(io::AbstractBufWriter, x, endianness::Endianness)
    return _store(PrimitiveSerialization(typeof(x)), io, x, endianness)
end

function store(io::AbstractBufWriter, x::UInt8, endianness::Endianness)
    return store(io, x)
end

function store(io::AbstractBufWriter, x::UInt8)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    isempty(buffer) && return @noinline _store(io, x)
    @inbounds buffer[1] = x
    @inbounds consume(io, 1)
    return nothing
end

function _store(io::AbstractBufWriter, x::UInt8)
    grow_buffer(io)
    buffer = get_buffer(io)::MutableMemoryView{UInt8}
    isempty(buffer) && throw(IOError(IOErrorKinds.BufferTooShort))
    @inbounds buffer[1] = x
    @inbounds consume(io, 1)
    return nothing
end

function _store(
        ::Union{SerializablePrimitive, WriteOnlyPrimitive},
        io::AbstractBufWriter,
        x::T,
        endianness::Endianness
    ) where {T}
    sz = UInt(sizeof(T))::UInt
    buffer = get_minimum_buffer(io, sz)
    buffer isa IOError && throw(buffer)
    x = byte_order(endianness, x)
    GC.@preserve buffer unsafe_store!(Ptr{T}(pointer(buffer)), x)
    @inbounds consume(io, sz % Int)
    return nothing
end

store(io::AbstractBufWriter, c::Char, ::Endianness) = store(io, c)

function store(io::AbstractBufWriter, c::Char)
    ncu = ncodeunits(c)
    buffer = get_minimum_buffer(io, ncu % UInt)
    buffer isa IOError && throw(buffer)
    u = bswap(reinterpret(UInt32, c))
    n_written = 0
    while n_written < ncu
        buffer[n_written + 1] = u % UInt8
        u >>>= 8
        n_written += 1
    end
    @inbounds consume(io, ncu)
    return
end


end # module BufferSerde
