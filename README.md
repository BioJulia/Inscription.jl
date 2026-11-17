# <img src="./assets/sticker.svg" width="30%" align="right" /> BitScribbling.jl

[![Latest Release](https://img.shields.io/github/release/BioJulia/BitScribbling.jl.svg)](https://github.com/BioJulia/BitScribbling.jl/releases/latest)
[![MIT license](https://img.shields.io/badge/license-MIT-green.svg)](https://github.com/BioJulia/BitScribbling.jl/blob/master/LICENSE)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://biojulia.github.io/BitScribbling.jl/dev)
[![](https://codecov.io/gh/BioJulia/BitScribbling.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/BioJulia/BitScribbling.jl)

BitScribbling encodes and decodes primitive values to and from bytes, either in memory
(as `MemoryView`s) or by loading and storing them from and to the buffered IO types of
[BufferIO.jl](https://github.com/BioJulia/BufferIO.jl).

```julia
using BitScribbling
using MemoryViews: MemoryView

buf = zeros(UInt8, 4)
encode!(MemoryView(buf), 0x01020304, BigEndian())
buf == [0x01, 0x02, 0x03, 0x04] # true
decode(MemoryView(buf), UInt32, BigEndian()) # 0x01020304
```

## Contributing
We appreciate contributions from users including reporting bugs, fixing
issues, improving performance and adding new features.

See the [contributing files](https://github.com/BioJulia/Contributing) for detailed
contributor and maintainer guidelines and the code of conduct.

## Questions?
If you have a question about contributing or using BioJulia software,
join us on [the Julia Slack workspace](https://julialang.org/slack/), or visit the
[Bio category on Julia Discourse](https://discourse.julialang.org/c/domain/bio).
