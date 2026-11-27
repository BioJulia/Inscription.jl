# AGENTS.md
This file provide guidance for coding agents working on the Inscription.jl repository.

Inscription is a Julia package that provides abstractions for reading and writing values, such as integers, floats, `Char` and structs (`isbits` or not), to and from memory, and to and from the reader and writer types of the BufferIO package.

The major design goals of this package are:
1. High performance. The abstractions of this package should be roughly on par with manual implementations using pointer operations and `reinterpret`. Users should rarely be discouraged from using Inscription abstractions due to performance.
2. Present a hard-to-misuse API. Inscription APIs avoid making important behaviour implicit, such as platform endianness, platform-dependent struct padding, or performance traps due to slow fallback definitions. It attempts to guide users away from bugs.

Explicit **non**-goals of this package are:
1. A simple API. This package prefers semantically consistent, precise, efficient, and hard-to-misuse APIs over easy APIs.
2. Reading/writing any type automatically via introspection, like Serialization.jl does.
3. Reading/writing nested types like nested dicts, common in e.g. JSON, TOML and BSON formats.
4. Support for any specific format like JSON or CSV. Instead, this package is for generic I/O of individual values, and can be used to implement formats.

## Code Conventions
Performance is very important for this codebase.

* Where codegen may improve, keep fast paths inline and extract slow/cold paths into `@noinline` helper functions. Especially check if error throwing code could be outlined.
* Design APIs that allow for use of `@inbounds` that is statically guaranteed to be correct.
* The code base is formatted by Runic. Run `runic -i .` after changes. If formatting fails, alert the user and do not attempt to install Runic.

### When committing
Do not add yourself (you, the agent) as a co-author.
