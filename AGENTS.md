# AGENTS.md
This file provide guidance for coding agents working on the BitScribbling.jl repository.

BitScribbling is a Julia package that provides abstractions for reading and writing values whose encodings have a bounded size, such as integers, floats, `Char` and structs (`isbits` or not), to and from memory, and to and from the reader and writer types of the BufferIO package.

The major design criteria of the package are:
1. Low overhead. Using the abstractions should ideally be as fast as manual code loading and storing via pointers.
2. Pit of Success: Avoid APIs that makes implicit assumptions such as platform endianness, platform alignment or padding, and specific invalid bitpatterns of types. Also avoid slow fallback methods that may unexpectedly degrade performance, and APIs which encourage poor performance. 

Explicit non-goals of this package are:
1. A simple API. This package chooses complex pit-of-success APIs over a simple load/store abstraction that papers over the complexities mentioned above.
2. Encodings without a size bound, like those of `Dict`, `Vector` and `BigInt`, and general serialization of object graphs.
3. Support for specific formats unless particularly widespread. I.e., no explicit TOML or BSON support, but Char's UTF8 format is included.

## Code Conventions
Performance is very important for this codebase.

* Where codegen may improve, keep fast paths inline and extract slow/cold paths into `@noinline` helper functions. Especially check if error throwing code could be outlined.
* Design APIs that allow for use of `@inbounds` that is statically guaranteed to be correct.
* The code base is formatted by Runic. Run `runic -i .` after changes. If formatting fails, alert the user and do not attempt to install Runic.

### When committing
Do not add yourself (you, the agent) as a co-author.
