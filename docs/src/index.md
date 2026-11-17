```@meta
DocTestSetup = quote
    using BitScribbling, BufferIO
    using MemoryViews: MemoryView
end
```

# BitScribbling
BitScribbling encodes and decodes primitive values to and from bytes, either in memory
(as `MemoryView`s) or by loading and storing them from and to the buffered IO types of
[BufferIO.jl](https://github.com/BioJulia/BufferIO.jl).

```jldoctest
julia> buf = zeros(UInt8, 4);

julia> encode!(MemoryView(buf), 0x01020304, BigEndian());

julia> buf
4-element Vector{UInt8}:
 0x01
 0x02
 0x03
 0x04

julia> decode(MemoryView(buf), UInt32, BigEndian())
0x01020304
```
