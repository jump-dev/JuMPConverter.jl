module JuMPConverter

import OrderedCollections
import MathOptInterface as MOI
import JuMP

include("model.jl")
include("print.jl")
include("utils.jl")

include("AMPL/AMPL.jl")
include("GAMS/GAMS.jl")

"""
    read_from_file(model_path::String, dat_path = nothing; kwargs...) -> JuMP.Model

Parse an AMPL `.mod` or GAMS `.gms` file and return the corresponding
`JuMP.Model`. Internally, this generates the same Julia source that
`Base.show(io, ::JuMPConverter.Model)` produces, evaluates it into a
fresh anonymous module, and calls the generated `build_model`.

# Arguments
- `model_path`: path to a `.mod` (AMPL) or `.gms` (GAMS) file.
- `dat_path`: optional path to an AMPL `.dat` file. When provided, the
  generated `build_model(::String)` overload is invoked, which reads
  the data through the embedded `DatSchema`. Mutually exclusive with
  `kwargs` (mix them by calling `build_model` directly instead).
- `kwargs...`: forwarded to the kwarg form of `build_model` to override
  individual parameters/sets (or to supply ones without `.mod` defaults).
"""
function read_from_file(
    model_path::String,
    dat_path::Union{Nothing,String} = nothing;
    kwargs...,
)
    if dat_path !== nothing && !isempty(kwargs)
        error(
            "Cannot pass both `dat_path` and `kwargs`; call the generated `build_model` directly to mix the two.",
        )
    end
    ext = lowercase(splitext(model_path)[2])
    reader = if ext == ".mod"
        AMPL.read_model
    elseif ext == ".gms"
        GAMS.read_model
    else
        error("Unsupported extension '$ext' for $model_path; expected .mod or .gms")
    end
    # When loading an AMPL `.mod` alongside its `.dat`, treat the
    # `.dat` as the example for discovering data-section fixes — its
    # `fix` statements become `fix_<…>` kwargs of the generated
    # `build_model`, and the path-loader matches the same `.dat`'s
    # fixes onto them at runtime.
    parsed = if reader === AMPL.read_model && dat_path !== nothing
        AMPL.read_model(model_path; example_dat = dat_path)
    else
        reader(model_path)
    end
    # Evaluate the generated source in a fresh module with nothing
    # pre-imported, so any `using JuMP` / `import JuMPConverter` the
    # generated file needs must appear in the file itself — anything
    # missing surfaces here rather than when the file is later
    # `include`d by an unrelated consumer.
    sandbox = Module(:JuMPConverterSandbox)
    src = sprint(print, parsed)
    Core.eval(sandbox, Meta.parseall(src))
    return Base.invokelatest() do
        fn = getfield(sandbox, :build_model)
        return dat_path === nothing ? fn(; kwargs...) : fn(dat_path)
    end
end

end # module JuMPConverter
