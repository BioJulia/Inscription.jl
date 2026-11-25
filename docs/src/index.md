```@meta
DocTestSetup = quote
    using BitScribbling, BufferIO
    using MemoryViews: MemoryView
end
```

# BitScribbling.jl
BitScribbling.jl provides abstractions for reading and writing values to byte arrays (via [MemoryViews.jl](https://github.com/BioJulia/MemoryViews.jl).jl) or to I/O (via [BufferIO.jl](https://github.com/BioJulia/BufferIO.jl).jl).

It can be considered a more powerful version of Base's `read(::IO, T)`, `write(::IO, ::T)` as well as `unsafe_load`/`unsafe_store!`.
Alternatively, it can be viewed as an extension of BufferIO.jl, which only supports IO on bytes, to support IO for all types.

You might want to use this package if you find yourself:
* Using `unsafe_load`, `unsafe_store!` a lot,
* Caring about how much `write(::IO, ::Float32)` allocates,
* Find yourself writing non-`UInt8` data into `Vector{UInt8}`s for IO performance reasons.

You probably don't need this package if:
* Mostly do I/O by writing strings or raw arrays e.g. to log files,
* Read/write specific formats like JSON, in which case you should use a package specific to that format.


The major design goals of this package are:
1. High performance. The abstractions of this package should be roughly on par with manual implementations using pointer operations and `reinterpret`. Users should rarely be discouraged from using BitScribbling abstractions due to performance.
2. Present a hard-to-misuse API. BitScribbling APIs avoid making important behaviour implicit, such as platform endianness, platform-dependent struct padding, or performance traps due to slow fallback definitions. It attempts to guide users away from bugs.

Explicit **non**-goals of this package are:
1. A simple API. This package prefers semantically consistent, precise, efficient, and hard-to-misuse APIs over easy APIs.
2. Reading/writing any type automatically via introspection, like Serialization.jl does.
3. Reading/writing nested types like nested dicts, common in e.g. JSON, TOML and BSON formats.
4. Support for any specific format like JSON or CSV. Instead, this package is for generic I/O of individual values, and can be used to implement formats.

## Where to start
* Want to jump right in? **See the examples** on the [Examples](examples.md) page.
* Want a more thorough understanding of the package? Begin by **reading the [Concepts](concepts.md) page**.
* If you are **reading or writing common types** like `Float64`, `UInt32`, etc., see the [Usage](usage.md) page.
* To implement reading or writing of your own **custom type**, see the [Implementing a type](custom.md) page.

## Comparison to other packages
#### BufferIO.jl
BufferIO.jl provides I/O abstractions that are *byte-oriented*, meaning that BufferIO.jl types read and write
`UInt8` or `MemoryView{UInt8}`.
Reading and writing other types such as `Float32` is intentionally left out of BufferIO.jl.
BitScribbling.jl builds on BufferIO.jl and depends on it.

#### JSON.jl, TOML.jl, BSON.jl, etc.
These packages implement specific formats, whereas BitScribbling.jl provides abstractions for
binary I/O *in general*.
Also, the formats of these packages support variable-length containers and nested types such
as mappings and arrays, whereas BitScribbling.jl has no built-in encodings of these.
Users can implement encodings of variable length for their own types.

#### Serialization.jl
Serialization.jl can read and write any Julia value, including recursive types, and types with references
like `Dict` and `Array`, whereas BitScribbling.jl has no built-in encodings of these, and doesn't preserve references.
Also, Serialization.jl functions work for all types without specifying how to implement them, whereas
BitScribbling.jl requires users to specify how each type should be serialized and deserialized.
The latter is what makes BitScribbling.jl format-agnostic.
BitScribbling.jl is more fundamental, in the sense that it could be used to implement Serialization.jl.

## Limitations
* BitScribbling.jl currently has poor support for packed binary values, such as reading a 22-bit and a 44-bit
  struct from 64 bits in total. For now, the package assumes types are read or written as an integer number of bytes.
  Users can opt-in to padding to e.g. read/write an 18-bit primitive value as 24 bits (3 whole bytes).
  See the [Implementing a type](custom.md) page for details.

* There are no built-in encodings of types like `String`, whose encodings have no upper limit on their length.
  You can implement them for your own types, see [`BitScribbling.Unbounded`](@ref), but loading such a value
  from a reader buffers all of its bytes before any are consumed.
  To read data too large to buffer, load its length, then use [`load_every!`](@ref).

* BitScribbling.jl requires Julia 1.11 or newer.
