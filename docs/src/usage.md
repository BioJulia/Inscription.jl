# Reading and writing with BitScribbling.jl
Reading and writing happens fundamentally via encoding into, and decoding from, MemoryViews.jl's `MemoryView` type.
Loading from, and storing to BufferIO.jl's `AbstractBufReader` and `AbstractBufWriter` works via encoding and decoding from memory views into their buffer.

When loading and storing from BufferIO I/O types, you can always manually request their buffer, encode into/decode from the buffer, then call `BufferIO.consume`. This can be used as an escape hatch to load and store types not easily handled by BitScribbling.jl, such as bit-packed types.
It can also be used in extremely performance sensitive situations when you can request a large buffer, do a single boundscheck, then load many values inbounds.
However, most users should just use the BitScribbling functions below, as they are usually fast enough, and cover most use cases.

## Endian convenience namespaces
A given format is typically only little endian or big endian. When working with exclusively little endian data, it's annoying to have to pass `LittleEndian()` as the `Encoding` to all functions.
BitScribbling provides the modules `BitScribbling.Little` and `BitScribbling.Big`, which exports convenience functions which automatically forward `LittleEndian()` and `BigEndian()`, such that e.g.:

```julia
using BitScribbling.Little: encode!

encode!(mem, UInt32(123))
```

Is shorthand for:

```julia
using BitScribbling: encode!

encode!(mem, UInt32(123), LittleEndian())
```

In all examples below, I will use the more verbose `encode!(mem, UInt32(123), LittleEndian())` for clarity.

# Encoding and decoding
The functions mentioned below: `encode!`, `decode`, `decode_exact` and `decode_next` each have `try_*` versions. The former throws exceptions on errors, and the latter returns the exception on error. On the happy path, the throwing versions are slightly more efficient, so use the `try_` versions only if you plan to actually handle errors.

### Encoding values
Encoding functions generally have the signature `(try_)encode!(mem, [i::Integer], x::Type{T}, ::Encoding)`, and they mean: Encode `x` into `mem` starting at position `i` with the given `Encoding`, and return how many bytes were written (or an error, for the `try_` variant).
The argument `mem` is converted to a `MutableMemoryView{UInt8}`. 
If `i` is omitted, it defaults to `1`.

Example: `encode!(zeros(UInt8, 4), UInt32(55), LittleEndian()) === 4`

To check the number of bytes a value `x` would take up for some encoding (here, `LittleEndian()`), use `try_encoded_size(x, LittleEndian())`.

### Decoding values
The decoding signature is generally: `(try_)decode(_exact,_next)(mem, [i::Integer,] ::Type{T}, enc::Encoding)`, and they mean: Decode a `T` from `mem` starting at position `i`, with the given `Encoding`, and return the `T`, (or an error, for the `try_` variant).
Like the encoding functions, `mem` is converted to an `ImmutableMemoryView{UInt8}`, and `i` defaults to 1 if omitted.

Example: `decode(UInt8[1,2,3,4], UInt32, LittleEndian()) === 0x04030201`

The function `decode_next` returns `Tuple{T, Int}` (or an error, for the `try_` variant), with the `Int` giving the index immediately after the `T`, in `mem`. This way, you know how many bytes were read.
This is useful if the `T` is stored in a variable number of bytes, e.g. like a `Char` in a `UTF8` encoding.

The function `decode_exact` throws an error if `mem` contains any trailing data. This can be used to ensure `mem` contains exactly the `T`.
E.g. a hypothetical decimal integer decoder would fail on the input memory "123abc", as "abc" is not a valid decimal integer, whereas the normal `decode` would read the three bytes and return `123`.

## Bulk encoding and decoding
When encoding or decoding mutliple values together, it can be more efficient to encode or decode entire arrays of values in bulk.
For trivial codecs, this may be compiled to a `memmove`, or be vectorized.

`encode_every!(dst, src, ::Encoding)::Int` constructs a `MutableMemoryView{UInt8}` from `dst`, an `ImmutableMemoryView{T}` from `src`, and then encodes all values from `src` to `dst`, returning the number of bytes written. If `dst` cannot hold all values, throw a bounds error. For other errors, throw a `EncodeError`.

The function `decode_every!` is analogous, except returning the number of bytes read, and throwing a `DecodeError` on lack of space, or an invalid encoding.

If you don't want to handle exceptions, `encode_all!` and `decode_all!` stop at the first error, and return `(n_elements_encoded, n_bytes_written)` and `(n_elements_decoded, n_bytes_read)`, respecitively. These bulk functions have no `try_` equivalent functions: To see the error the stopped it, use `try_encode` or `try_decode` at the first index after the bytes used.

# Loading and storing
As mentioned above, you 

`load(::AbstractBufReader, ::Type{T}, ::Encoding)` and `store(::AbstractBufWriter, x::T, ::Encoding)` are similar to encoding and decoding, except that they load from and store to, the reader and writer, respectively, and advances their state (i.e. calls `consume` internally).
These loads and stores are all or nothing, not in the sense of promising to be single atomic operations on a CPU level, but in that, if the operations are failed, no bytes are read from, or written to, the I/O objects.

The above throwing functions also have `try_load` and `try_store` equivalents. Like the encoding/decoding functions, they are slightly less efficient.

In the rare case the stream you read from is not self-syncronizing - that is, it's not clear from the data when the value begins, `load_exact(::AbstractBufReader, n::Integer, ::Type{T}, ::Encoding)` and `try_load_exact` reads a `T` from exactly `n` bytes of the reader.
Consider a hypothetical `Decimal` integer codec where the string "123", can be read as (1, 2, 3), or (12, 3) or (1, 23) or 123.
Using `load` or `try_load`, the maximal length would be read, so 123 would be returned. To load (12, 3) instead, use `load_exact(io, 2, Int, Decimal())` then `load_exact(io, 1, Int, Decimal())`.

Loading with `load` or `try_load` reads a suffix of 

## Bulk loading and storing
These functions internally use the bulk encoding and decoding functions and so may be more efficient to e.g. fill arrays.

The function `load_into!(::AbstractBufReader, dst, ::Encoding)` builds a `MutableMemoryView{T}` from `dst`, then reads data of type `T` into `dst`, and returns `(n_elements_loaded, n_bytes_read)`.
It stops, without throwing, if `dst` has no more space, the reader is EOF, or the next element cannot be decoded.
Like the bulk encoding/decoding functions, it has no `try_` equivalent. To see why it stopped, check the length of `dst`, if the reader is EOF, and call `try_load` to see the error.

The number of elements loaded is decided by the implementation of the reader. The reader knows the optimal buffer size, so delegating the amount read per call to the reader improves performance.
However, to guarantee forward progress, this function load zero elements only if it is stopped by any of the above reasons, i.e. the reader cannot decide a buffer size of zero. 

Use this function when you process a larger array in chunks, but have no strong opinion on the chunk size yourself.
For example, a hashing function might need to process a large byte array, but operate on chunks of only 8 `UInt64` at a time, per round.
Here, you could call `load_into!` in a loop until at least 64 bytes have been loaded (which, in the vast majority of cases, will happen after a single call), then process that chunk.

The function `store_into` is the mirror image: It writer to an `AbstractBufWriter`, reads from `src` converted to `ImmutableMemory{T}` and returns `(n_elements_read, n_bytes_written)`. Like `load_into!`, the number of elements is an implementation detail (but nonzero, unless prevented), and there is no `try_` equivalent.

The functions `load_every!` and `store_every` are similar to `load_into!` and `store_into!`, but continue until `dst` is filled, or `src` is exhausted. If an element cannot be decoded or encoded, or there is no room in the writer, or enough bytes in the reader, throw an exception.
That is, these functions use the entire array passed to it instead of delegating choice of buffer size to the reader/writer type.
Use these functions if you need to process the entire array before continuing.

Finally, `load_all!` and `store_all` are similar to `load_every!` and `store_every`, but stops early instead of throwing when an elements cannot be encoded/decoded, or there are not enough bytes in the reader or room in the writer. You can then use `try_load` and `try_store` to get the error.

### Boundschecks when loading and storing
Unlike the encode and decode functions, load and store functions do not respect `@inbounds` (they always boundscheck).
This may be undesirable when reading many small chunks of data, and where optimal performance is needed.
In these cases, consider getting a buffer, then decoding with `@inbounds`, then calling `consume` manually.

For example, to read 3 `UInt64` from a reader, you may do:

```julia
using BufferIO: AbstractBufReader, get_nonempty_buffer
using BitScribbling: BitScribbling, decode, LittleEndian, DecodeError
using BitScribbling.DecodeErrorKinds: EndOfInput

function get_three_u64(io::AbstractBufReader)
    # Return `nothing` if EOF before 24 bytes
    buffer = @something get_nonempty_buffer(io, 24) throw(DecodeError(EndOfInput))
    @inbounds begin
        return (
            decode(buffer,  1, UInt64, LittleEndian()),
            decode(buffer,  9, UInt64, LittleEndian()),
            decode(buffer, 17, UInt64, LittleEndian()),
        )
    end
end
```

The above could also done directly with `try_load(io, NTuple{3, UInt64}, LittleEndian())`,
so the above is just for demonstration purposes.
