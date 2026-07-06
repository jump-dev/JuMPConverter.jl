Base.@kwdef struct Axe
    name::String
    set::String
end

Base.@kwdef struct Axes
    axes::Vector{Axe}
    condition::Union{Nothing,String} = nothing
end

Base.@kwdef struct Parameter
    name::String
    axes::Union{Nothing,Axes} = nothing
    integer::Bool
    default::Union{Nothing,Float64} = nothing
    # AMPL's `param NAME := EXPR;` form lets the value be any AMPL
    # expression (`param h := 1/n;`). When `EXPR` isn't a numeric
    # literal we store it here as a Julia source string so the
    # generated kwarg can carry the expression itself as its default.
    default_expr::Union{Nothing,String} = nothing
end

Base.@kwdef struct Set
    name::String
    default::Union{Nothing,String} = nothing
end

Base.@kwdef struct Variable
    name::String
    axes::Union{Nothing,Axes} = nothing
    lower_bound::Union{Nothing,String} = nothing
    upper_bound::Union{Nothing,String} = nothing
    fixed_value::Union{Nothing,String} = nothing
    binary::Bool = false
    integer::Bool = false
end

Base.@kwdef struct Objective
    name::Union{Nothing,String} = nothing
    sense::MOI.OptimizationSense
    expression::String
end

Base.@kwdef struct Constraint
    name::String
    axes::Union{Nothing,Axes} = nothing
    expression::String
end

# AMPL `fix [{i in SET}] VAR[idx, …] := VALUE;` parsed into structured
# pieces so the emitter can apply it via `JuMP.fix(model[:VAR][idx…],
# VALUE; force = true)` without ever needing to `eval` a string.
#
# `indices` entries are either a `String` (from AMPL `'foo'`), an
# `Int` (clnlbeam's `fix x[0]`), or a `Symbol` referring to `iter.var`
# — that's the index shape real `.dat`s exercise (bar-truss-3).
# `iter.set` is the set name to iterate over (resolved from the local
# `build_model` scope at the call site).
Base.@kwdef struct FixIter
    var::Symbol
    set::Symbol
end

# `value` is a `Float64` for a literal RHS; a non-literal RHS
# (optmass's `fix v[1,0] := speed;` where `speed` is a param) is kept
# as its Julia expression source in a `String` and emitted verbatim
# into the `JuMP.fix` call, where it resolves against `build_model`'s
# kwargs.
Base.@kwdef struct FixStatement
    variable::Symbol
    indices::Vector{Any} = Any[]
    value::Union{Float64,String}
    iter::Union{Nothing,FixIter} = nothing
end

mutable struct Model
    sets::OrderedCollections.OrderedDict{String,Set}
    parameters::OrderedCollections.OrderedDict{String,Parameter}
    # Original `.mod` declaration order for sets + params combined,
    # so the generated `build_model`'s kwargs land in dependency-safe
    # order (a set default can reference a param declared above it
    # and vice versa).
    kwarg_order::Vector{Tuple{Symbol,String}}
    variables::OrderedCollections.OrderedDict{String,Variable}
    objective::Union{Nothing,Objective}
    constraints::Vector{Constraint}
    # AMPL `fix` statements seen in the `.mod`'s model section — values
    # are known at codegen time and emitted as inline `JuMP.fix(...)`.
    fixes::Vector{FixStatement}
    # Data-section `fix` *structures* (variable + indices + iter, no
    # value) discovered from an example `.dat`. Each becomes a
    # `fix_<…> = nothing` kwarg of the generated `build_model`; passing
    # a value applies the fix, leaving it `nothing` skips.
    parametric_fixes::Vector{FixStatement}
    # Raw text of an inline `data; ...` section, if any. Embedded
    # verbatim in the emitted `.jl` and re-parsed at load time so the
    # values defined inline become defaults for `build_model`'s kwargs.
    inline_data_text::Union{Nothing,String}
    # Names of sets/parameters assigned in the inline `data;` section.
    # Drives which kwargs of the emitted `build_model` get a default
    # pulled from the inline data.
    inline_data_names::OrderedCollections.OrderedSet{String}
    function Model()
        return new(
            OrderedCollections.OrderedDict{String,Set}(),
            OrderedCollections.OrderedDict{String,Parameter}(),
            Tuple{Symbol,String}[],
            OrderedCollections.OrderedDict{String,Variable}(),
            nothing,
            Constraint[],
            FixStatement[],
            FixStatement[],
            nothing,
            OrderedCollections.OrderedSet{String}(),
        )
    end
end

function Base.push!(model::Model, set::Set)
    haskey(model.sets, set.name) || push!(model.kwarg_order, (:set, set.name))
    model.sets[set.name] = set
    return model
end

function Base.push!(model::Model, parameter::Parameter)
    haskey(model.parameters, parameter.name) ||
        push!(model.kwarg_order, (:param, parameter.name))
    model.parameters[parameter.name] = parameter
    return model
end

function Base.push!(model::Model, variable::Variable)
    model.variables[variable.name] = variable
    return model
end

function Base.push!(model::Model, constraint::Constraint)
    push!(model.constraints, constraint)
    return model
end

function Base.push!(model::Model, fix::FixStatement)
    push!(model.fixes, fix)
    return model
end
