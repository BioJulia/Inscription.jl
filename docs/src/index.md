```@meta
DocTestSetup = quote
    using BitScribbling, BufferIO
    using MemoryViews: MemoryView
end
```

# BitScribbling.jl
BitScribbling.jl provides binary I/O interfaces, used for reading and writing `isbits` values to and from
byte arrays (via MemoryViews.jl) and I/O objects (via BufferIO.jl).

Its design is guided by two principles:
1. Low overhead: BitScribbling abstractions should be roughly as fast as a
   manual implementation doing loading/storing via pointers.
2. Hard-to-misuse API: Its API is complicated, but guides users towards success
   and avoids pitfalls such as those arising from padding, endianness, and
   odd-sized primitives.

## When to use this package
BitScribbling.jl is intended for doing low-level binary I/O, such as when implementing readers or writers
for binary formats like BSON or BAM.

If you want to read or write such formats, use a package dedicated to the format, like BSON.jl or XAM.jl.
For general I/O, see BufferIO.jl.

## Where to start
* Want to jump right in? **See the examples** on the [Usage](usage.md) page.
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
as mappings and arrays, whereas BitScribbling.jl only supports bitstypes.

#### Serialization.jl
Serialization.jl can read and write any Julia value, including recursive types, and types with references
like `Dict` and `Array`, whereas BitScribbling.jl only supports bitstypes.
Also, Serialization.jl functions work for all types without specifying how to implement them, whereas
BitScribbling.jl requires users to specify how each type should be serialized and deserialized.
The latter is what makes BitScribbling.jl format-agnostic.
BitScribbling.jl is more fundamental, in the sense that it could be used to implement Serialization.jl.

## Limitations
* BitScribbling.jl currently has poor support for packed binary values, such as reading a 22-bit and a 44-bit
  struct from 64 bits in total. For now, the package assumes types are read or written as an integer number of bytes.
  Users can opt-in to padding to e.g. read/write an 18-bit primitive value as 24 bits (3 whole bytes).
  See the [Implementing a type](custom.md) page for details.

* BitScribbling.jl only supports `isbits` types, and discourages reading and writing `Ptr`.

* BitScribbling.jl requires Julia 1.11 or newer.
