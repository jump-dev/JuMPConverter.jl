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

mutable struct Model
    sets::OrderedCollections.OrderedDict{String,Set}
    parameters::OrderedCollections.OrderedDict{String,Parameter}
    variables::OrderedCollections.OrderedDict{String,Variable}
    objective::Union{Nothing,Objective}
    constraints::Vector{Constraint}
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
            OrderedCollections.OrderedDict{String,Variable}(),
            nothing,
            Constraint[],
            nothing,
            OrderedCollections.OrderedSet{String}(),
        )
    end
end

function Base.push!(model::Model, set::Set)
    model.sets[set.name] = set
    return model
end

function Base.push!(model::Model, parameter::Parameter)
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
