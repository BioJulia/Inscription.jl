# The functions of the modules `Little` and `Big`, and their arguments, without the
# encoding argument.
const convenience_functions = (
    (:max_encoded_size, (:(T::Type),)),
    (:try_decode, (:mem, :(T::Type))),
    (:try_decode, (:mem, :(i::Integer), :(T::Type))),
    (:decode, (:mem, :(T::Type))),
    (:decode, (:mem, :(i::Integer), :(T::Type))),
    (:try_decode_next, (:mem, :(i::Integer), :(T::Type))),
    (:decode_next, (:mem, :(i::Integer), :(T::Type))),
    (:try_decode_exact, (:mem, :(T::Type))),
    (:try_decode_exact, (:mem, :(i::Integer), :(T::Type))),
    (:decode_exact, (:mem, :(T::Type))),
    (:decode_exact, (:mem, :(i::Integer), :(T::Type))),
    (:try_encode!, (:mem, :x)),
    (:try_encode!, (:mem, :(i::Integer), :x)),
    (:encode!, (:mem, :x)),
    (:encode!, (:mem, :(i::Integer), :x)),
    (:try_load, (:(io::AbstractBufReader), :(T::Type))),
    (:load, (:(io::AbstractBufReader), :(T::Type))),
    (:try_load_exact, (:(io::AbstractBufReader), :(nbytes::Integer), :(T::Type))),
    (:load_exact, (:(io::AbstractBufReader), :(nbytes::Integer), :(T::Type))),
    (:try_store, (:(io::AbstractBufWriter), :x)),
    (:store, (:(io::AbstractBufWriter), :x)),
    (:decode_all!, (:dst, :src)),
    (:decode_every!, (:dst, :src)),
    (:encode_all!, (:dst, :src)),
    (:encode_every!, (:dst, :src)),
    (:load_into!, (:(io::AbstractBufReader), :dst)),
    (:load_all!, (:(io::AbstractBufReader), :dst)),
    (:load_every!, (:(io::AbstractBufReader), :dst)),
    (:store_into, (:(io::AbstractBufWriter), :src)),
    (:store_all, (:(io::AbstractBufWriter), :src)),
    (:store_every, (:(io::AbstractBufWriter), :src)),
)

for (mod, E, desc) in (
        (:Little, :LittleEndian, "little-endian"),
        (:Big, :BigEndian, "big-endian"),
    )
    names = map(first, convenience_functions)
    doc = """
        module $mod

    The functions of BitScribbling, with the encoding fixed to `$E()`.
    Every function forwards to the function of the same name in BitScribbling,
    with `$E()` as the last argument.

    The module also exports various other names, so that `using BitScribbling.$mod`
    is all that is needed to use it.

    # Examples
    ```julia
    using BitScribbling.$mod: load, store

    load(io, UInt32) # loads a $desc UInt32
    ```
    """
    m = @eval begin
        @doc $doc module $mod
        using ..BitScribbling: BitScribbling, $E, MemoryView, MutableMemoryView,
            AbstractBufReader, AbstractBufWriter,
            DecodeError, DecodeErrorKinds, EncodeError, EncodeErrorKinds, @?

        export BitScribbling, $(names...), DecodeError, DecodeErrorKinds, EncodeError, EncodeErrorKinds, @?
        end
    end
    for (f, args) in convenience_functions
        arg_names = map(a -> a isa Symbol ? a : a.args[1], args)
        signature = join(map(string, args), ", ")
        fdoc = """
            $mod.$f($signature)

        Forward to [`BitScribbling.$f`](@ref) with `$E()` as the encoding.
        """
        Core.eval(m, :(@doc $fdoc Base.@propagate_inbounds $f($(args...)) = BitScribbling.$f($(arg_names...), $E())))
    end
end
