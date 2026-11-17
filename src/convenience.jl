# The functions of the modules `Little` and `Big`, and their arguments, without the
# encoding argument.
const convenience_functions = (
    (:max_encoded_size, (:(T::Type),)),
    (:try_decode, (:(mem::MemoryView{UInt8}), :(T::Type))),
    (:try_decode, (:(mem::MemoryView{UInt8}), :(i::Integer), :(T::Type))),
    (:decode, (:(mem::MemoryView{UInt8}), :(T::Type))),
    (:decode, (:(mem::MemoryView{UInt8}), :(i::Integer), :(T::Type))),
    (:encode!, (:(mem::MutableMemoryView{UInt8}), :x)),
    (:encode!, (:(mem::MutableMemoryView{UInt8}), :(i::Integer), :x)),
    (:try_load, (:(io::AbstractBufReader), :(T::Type))),
    (:load, (:(io::AbstractBufReader), :(T::Type))),
    (:store, (:(io::AbstractBufWriter), :x)),
    (:decode_into!, (:(dst::MutableMemoryView), :(src::MemoryView{UInt8}))),
    (:encode_into!, (:(dst::MutableMemoryView{UInt8}), :(src::MemoryView))),
    (:load_into!, (:(io::AbstractBufReader), :(dst::MutableMemoryView))),
    (:load_all!, (:(io::AbstractBufReader), :(dst::MutableMemoryView))),
    (:store_all, (:(io::AbstractBufWriter), :(src::MemoryView))),
)

for (mod, E, desc) in (
        (:Little, :LittleEndian, "little-endian"),
        (:Big, :BigEndian, "big-endian"),
    )
    names = map(first, convenience_functions)
    doc = """
        module $mod

    The functions of BufferSerde, with the encoding fixed to `$E()`.
    Every function forwards to the function of the same name in BufferSerde,
    with `$E()` as the last argument. The forwarding propagates `@inbounds`.

    The module also exports various other names, so that `using BufferSerde.$mod`
    is all that is needed to use it.

    # Examples
    ```julia
    using BufferSerde.$mod: load, store

    load(io, UInt32) # loads a $desc UInt32
    ```
    """
    m = @eval begin
        @doc $doc module $mod
        using ..BufferSerde: BufferSerde, $E, MemoryView, MutableMemoryView,
            AbstractBufReader, AbstractBufWriter,
            DecodeError, DecodeErrorKinds, @try_return

        export $(names...), DecodeError, DecodeErrorKinds, @try_return
        end
    end
    for (f, args) in convenience_functions
        arg_names = map(a -> a isa Symbol ? a : a.args[1], args)
        signature = join(map(string, args), ", ")
        fdoc = """
            $mod.$f($signature)

        Forward to [`BufferSerde.$f`](@ref) with `$E()` as the encoding.
        """
        Core.eval(m, :(@doc $fdoc Base.@propagate_inbounds $f($(args...)) = BufferSerde.$f($(arg_names...), $E())))
    end
end
