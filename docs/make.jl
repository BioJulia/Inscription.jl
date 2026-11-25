using Documenter, BitScribbling

# This code is executed in the environment in which doctests in the package's
# docstrings run. Use it to define global variables that docstrings can refer
# to.
meta = quote
    using BitScribbling, BufferIO
    using MemoryViews: MemoryView
end

DocMeta.setdocmeta!(BitScribbling, :DocTestSetup, meta; recursive = true)

makedocs(
    modules = [BitScribbling],
    repo = Documenter.Remotes.GitHub("BioJulia", "BitScribbling.jl"),
    sitename = "BitScribbling.jl",
    doctest = true,
    # These two pages are recommended, you can add more as you wish
    pages = [
        "BitScribbling" => "index.md",
        "Concepts" => "concepts.md",
        "Usage" => "usage.md",
        "Examples" => "examples.md",
        "Implementing a type" => "custom.md",
        "Reference" => "reference.md",
    ],
    authors = "Jakob Nybo Andersen",
    checkdocs = :public,
)

deploydocs(;
    repo = "github.com/BioJulia/BitScribbling.jl.git",
    push_preview = true,
    deps = nothing,
    make = nothing,
)
