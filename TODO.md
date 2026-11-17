* Play around with it
    Dogfood all users of BufferIO with it

* Read all docstrings and review them

* Review the code

* Scan the tests

* Write an AGENTS
    Speed is important
    Prefer speeds on 1.14 and 1.13, not master (regresions likely), not old versions (to be outdated)

* Make package-like
    See BioJuliaTemplate
    Also add box tests (Test.detect_closure_boxes) or whatever it's called

Considr supporting ::Any in e.g. load(::Any), converting to MemoryView.
This is a convenience method but may be nice to have.

Rename package
    PrimitiveIO
    BinaryPrimitives

Serialize structs?

Wishlist
    inbounds decode / encode / load / store, which skips length checks

    decode_at a fixed position, to avoid slicing in e.g. `decode(a[b:c], UInt32)`
        this can be more efficient due to MemoryView needing that extra branch

    decode returns two items - for most loads it only needs one, not the one
    with the number of bytes loaded. That is only for non bitsloadable/storable types

    an encode! which throws, and does not return nothing.
        rename existing to try_encode



