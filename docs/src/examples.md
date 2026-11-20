# Examples

making a codec
deriving bitsloadable
deriving bitsstorable

loading odd sized primitives


1. An end-to-end parser. I'd put this first. Decode the header of a real format, such as a WAV header or a small made-up record format. It shows several things together:
- decode_next in a loop with the index moving forward;
- mixing endianness, e.g. a big-endian magic number followed by little-endian fields;
- turning the decoded fields into a struct;
- error handling for truncated input.

One example like this teaches more than several separate snippets.

2. try_ versus throwing, and @try_return. Show when to use try_decode and when to use decode, and how @try_return passes a DecodeError up through your own function. This is where the package's error design shows up, and readers won't guess it from the reference docs.

3. Reading a stream. Use load/store with a BufferIO reader or writer, e.g. reading length-prefixed records until EOF. Your odd-sized primitives example already uses BufferIO at a lower level (get_nonempty_buffer), so showing the high-level way first would help.

4. Bulk operations. Decode a whole array of Float32s with decode_all! / load_all!, and compare it with a loop. It's short and practical, and the gap between _all! and _every! is worth showing next to each other.

5. @inbounds and performance. Show that decode(mem, i, T, enc) with an index under @inbounds compiles to a single load. Include the @code_llvm output, or a sentence saying so. This links to the reason the index argument exists, which we discussed earlier.

6. Smaller ones that could go into existing examples:
- Decoding UTF-8 Chars with decode_next (there's already a decode_chars doctest in src/interface.jl:239 to reuse).
- Tuples, e.g. decode(mem, Tuple{UInt16, Float32}, LittleEndian()), as a lighter option than defining a struct.
- A rejected struct. Show what the error says for a padded struct like (UInt8, UInt32) and how to fix it. It fits next to your BitsLoadable item.

For your own items:
- "Implement a codec": choose a type that really needs one, such as a variable-length integer (LEB128/varint). It shows codec_max_encoded_size, a variable byte count and InvalidData errors.
- "BitsLoadable vs BitsStorable": the clearest pair is a struct of plain numbers (loadable) and a struct with a Bool or enum field (storable only, because some bit patterns are invalid). That explains why the distinction exists.

If you only add one, make it the end-to-end parser. If you'd like, I can draft the varint codec or the header parser and run it as a doctest.
