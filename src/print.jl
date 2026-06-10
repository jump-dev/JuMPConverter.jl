function Base.show(io::IO, variable::Variable)
    print(io, "@variable(model, ")
    name = variable.name * _format_axes(variable.axes)
    lb =
        isnothing(variable.lower_bound) ? nothing :
        _ampl_range_to_julia(variable.lower_bound)
    ub =
        isnothing(variable.upper_bound) ? nothing :
        _ampl_range_to_julia(variable.upper_bound)
    if !isnothing(variable.fixed_value)
        print(io, "$name == $(_ampl_range_to_julia(variable.fixed_value))")
    else
        if !isnothing(lb) && !isnothing(ub)
            print(io, "$lb <= ")
        end
        print(io, name)
        if isnothing(ub)
            if !isnothing(lb)
                print(io, " >= $lb")
            end
        else
            print(io, " <= $ub")
        end
    end
    if variable.binary
        print(io, ", Bin")
    elseif variable.integer
        print(io, ", Int")
    end
    print(io, ")")
    return
end

# AMPL `{t in T, k in K}` / `{T, K}` / `{t in T : cond}` becomes JuMP's
# bracketed indexing `[t in T, k in K]` / `[T, K]` / `[t in T; cond]`.
# Returns "" when there are no axes.
_format_axes(::Nothing) = ""

function _format_axes(axes::Axes)
    parts = String[]
    for axe in axes.axes
        set = _ampl_range_to_julia(axe.set)
        if axe.name == axe.set
            push!(parts, set)
        else
            push!(parts, "$(axe.name) in $set")
        end
    end
    body = join(parts, ", ")
    if !isnothing(axes.condition)
        body *= "; " * _ampl_range_to_julia(axes.condition)
    end
    return "[$body]"
end

# AMPL ranges use `..`; Julia's `UnitRange` uses `:` and has lower
# precedence than `+`, so `1..3+H` becomes `1:3+H` (= `1:(3+H)`).
_ampl_range_to_julia(s::AbstractString) = replace(s, ".." => ":")

# Build the keyword-argument fragment for a parameter. Precedence for
# the default value: inline `data;` value > explicit `default <expr>` in
# the `.mod` > none (i.e. required kwarg). For an indexed parameter with
# a scalar default the default must be wrapped in a container indexable
# by the parameter's axes, otherwise `ALPHA[k]` fails on a scalar.
function _format_param_kwarg(p::Parameter, inline::Bool)
    if inline
        return "$(p.name) = _INLINE_DATA[\"$(p.name)\"]"
    end
    if !isnothing(p.default_expr)
        # Expression default (`param h := 1/n;`).
        if isnothing(p.axes)
            return "$(p.name) = $(p.default_expr)"
        end
        # Indexed expression default — only the 1D simple-iter form
        # has a clean Julia rendering as a `DenseAxisArray`
        # comprehension. Multi-dim and tuple-iter forms (e.g. `param
        # dist{(i, j) in arcs} := …`) need more machinery; drop the
        # default and leave the kwarg required for now.
        if length(p.axes.axes) == 1
            a = p.axes.axes[1]
            if !startswith(a.name, "(")
                set = _ampl_range_to_julia(a.set)
                return "$(p.name) = JuMP.Containers.DenseAxisArray([$(p.default_expr) for $(a.name) in $set], $set)"
            end
        end
        return p.name
    end
    isnothing(p.default) && return p.name
    if isnothing(p.axes)
        return "$(p.name) = $(p.default)"
    end
    axes_strs = [_ampl_range_to_julia(a.set) for a in p.axes.axes]
    lengths = join(["length($a)" for a in axes_strs], ", ")
    fill_call = "fill($(p.default), $lengths)"
    return "$(p.name) = JuMP.Containers.DenseAxisArray($fill_call, $(join(axes_strs, ", ")))"
end

function _format_set_kwarg(s::Set, inline::Bool)
    if inline
        return "$(s.name) = _INLINE_DATA[\"$(s.name)\"]"
    end
    return isnothing(s.default) ? s.name : "$(s.name) = $(s.default)"
end

function Base.show(io::IO, objective::Objective)
    if objective.sense == MOI.MAX_SENSE
        sense = "Max"
    elseif objective.sense == MOI.MIN_SENSE
        sense = "Min"
    else
        @assert objective.sense == MOI.FEASIBILITY_SENSE
        return
    end
    print(io, "@objective(model, $sense, $(objective.expression))")
    return
end

function Base.show(io::IO, constraint::Constraint)
    name = constraint.name * _format_axes(constraint.axes)
    print(io, "@constraint(model, $name, $(constraint.expression))")
    return
end

# AMPL `fix [{ITER}] VAR[idx, …] := <something>;` → `JuMP.fix(...)`,
# wrapped in a `for ITER` loop when iter is set. `value_expr` is the
# Julia source for the fix's right-hand side: a literal (`"1.0"`) for
# inline fixes, a kwarg name (`"fix_H_y1_y2"`) for parametric ones.
function _print_fix(
    io::IO,
    fx::FixStatement,
    indent::AbstractString,
    value_expr::AbstractString,
)
    target = if isempty(fx.indices)
        "model[:$(fx.variable)]"
    else
        "model[:$(fx.variable)][$(_format_indices(fx.indices))]"
    end
    if fx.iter === nothing
        println(
            io,
            indent,
            "JuMP.fix(",
            target,
            ", ",
            value_expr,
            "; force = true)",
        )
        return
    end
    println(io, indent, "for ", fx.iter.var, " in ", fx.iter.set)
    println(
        io,
        indent,
        "    JuMP.fix(",
        target,
        ", ",
        value_expr,
        "; force = true)",
    )
    println(io, indent, "end")
    return
end

# Symbols (an iter var like `:i`) emit bare so they refer to the for-loop
# binding; literals (numbers / strings) emit as Julia source literals.
_format_index(i::Symbol) = string(i)
_format_index(i) = repr(i)

_format_indices(idxs) = join((_format_index(i) for i in idxs), ", ")

function Base.show(io::IO, model::JuMPConverter.Model)
    println(io, "using JuMP")
    has_data_loader = !isempty(model.parameters) || !isempty(model.sets)
    inline = model.inline_data_names
    # The path loader and the inline-data const both qualify against
    # `JuMPConverter.*`, so the file needs to bring `JuMPConverter`
    # into scope itself rather than relying on the includer.
    if has_data_loader || !isnothing(model.inline_data_text)
        println(io, "import JuMPConverter")
    end
    if !isnothing(model.inline_data_text)
        _print_inline_data_const(io, model)
        println(io)
    end
    print(io, "function build_model(")
    kwargs = String[]
    # Iterate sets + params in their original `.mod` declaration order
    # so a kwarg's default expression can rely on every name declared
    # above it being already bound (works in both directions:
    # `set nodes := 1..Nnd` after `param Nnd := …`, and
    # `param hl{i in nodes} := …` after `set nodes`).
    for (kind, name) in model.kwarg_order
        if kind === :param
            push!(
                kwargs,
                _format_param_kwarg(model.parameters[name], name in inline),
            )
        else
            push!(kwargs, _format_set_kwarg(model.sets[name], name in inline))
        end
    end
    for fx in model.parametric_fixes
        push!(kwargs, "$(JuMPConverter.AMPL.fix_kwarg_name(fx)) = nothing")
    end
    if !isempty(kwargs)
        print(io, "; ")
        join(io, kwargs, ", ")
    end
    println(io, ")")
    println(io, "    model = Model()")
    for variable in values(model.variables)
        println(io, "    ", variable)
    end
    for constraint in model.constraints
        println(io, "    ", constraint)
    end
    println(io, "    ", model.objective)
    for fx in model.fixes
        _print_fix(io, fx, "    ", repr(fx.value))
    end
    for fx in model.parametric_fixes
        kw = JuMPConverter.AMPL.fix_kwarg_name(fx)
        println(io, "    if ", kw, " !== nothing")
        _print_fix(io, fx, "        ", string(kw))
        println(io, "    end")
    end
    println(io, "    return model")
    print(io, "end")
    if has_data_loader
        println(io)
        println(io)
        _print_data_loader(io, model)
    end
    return
end

# Emit `const _INLINE_DATA = JuMPConverter.AMPL.parse_dat("…")` so the
# inline `data;` section becomes a Dict the generated kwargs can
# reference as their defaults. Re-parsed once at .jl load time.
# Schemaless on purpose: the schema-aware `parse_dat` has rough edges
# with set-of-tuples and multi-column tables that the schemaless path
# happens to handle for the inline-data forms we've seen.
function _print_inline_data_const(io::IO, model::JuMPConverter.Model)
    println(io, "const _INLINE_DATA = JuMPConverter.AMPL.parse_dat(")
    # `raw"…"` would fail on a trailing backslash or an embedded `"`,
    # so escape with `repr` to get a safe Julia string literal.
    println(io, "    ", repr(model.inline_data_text), ",")
    println(io, ")")
    return
end

# Emit a single `build_model(path::String)` that hard-codes the
# `DatSchema` derived from this model and dispatches between
# `read_dat` (for a `.dat` file) and `read_csv` (for a directory of
# CSVs) based on `isdir(path)`. Lets the generated `.jl` load data
# at runtime without re-parsing the `.mod`.
function _print_data_loader(io::IO, model::JuMPConverter.Model)
    println(io, "function build_model(path::String)")
    print(io, "    schema = ")
    _print_schema_expr(io, model; indent = "    ")
    println(io)
    println(io, "    data = if isdir(path)")
    println(io, "        JuMPConverter.AMPL.read_csv(path, schema)")
    println(io, "    else")
    println(io, "        JuMPConverter.AMPL.read_dat(path, schema)")
    println(io, "    end")
    if isempty(model.parametric_fixes)
        println(io, "    return build_model(; data...)")
        print(io, "end")
        return
    end
    # `parse_dat` stuffs structured `fix` statements under `:fixes`.
    # Route each one onto its pre-registered `fix_<…>` kwarg, erroring
    # if the runtime `.dat` contains a fix whose structure wasn't seen
    # in the example `.dat` (or explicit list) at conversion time.
    println(io, "    fixes = pop!(data, :fixes, JuMPConverter.FixStatement[])")
    println(io, "    fix_kwargs = Dict{Symbol,Any}()")
    println(io, "    for fx in fixes")
    println(io, "        kw = JuMPConverter.AMPL.fix_kwarg_name(fx)")
    print(io, "        kw in (")
    join(
        io,
        (
            ":$(JuMPConverter.AMPL.fix_kwarg_name(fx))" for
            fx in model.parametric_fixes
        ),
        ", ",
    )
    println(io, ") || error(")
    println(
        io,
        "            \"runtime .dat contains an unregistered fix `\$kw`; \" *",
    )
    println(
        io,
        "            \"re-run conversion with this .dat as `example_dat` \" *",
    )
    println(io, "            \"or list this variable explicitly.\",")
    println(io, "        )")
    println(io, "        fix_kwargs[kw] = fx.value")
    println(io, "    end")
    println(io, "    return build_model(; data..., fix_kwargs...)")
    print(io, "end")
    return
end

# `JuMPConverter.AMPL.DatSchema(Dict{Symbol,Int}(…), [:S1, :S2])`
# rendered as a multi-line expression. `indent` is the prefix for the
# closing `)` so the caller can align it with surrounding code.
function _print_schema_expr(
    io::IO,
    model::JuMPConverter.Model;
    indent::AbstractString = "",
)
    println(io, "JuMPConverter.AMPL.DatSchema(")
    println(io, indent, "    Dict{Symbol,Int}(")
    for (name, p) in model.parameters
        nd = isnothing(p.axes) ? 0 : length(p.axes.axes)
        println(io, indent, "        :$name => $nd,")
    end
    print(io, indent, "    )")
    if !isempty(model.sets)
        println(io, ",")
        print(io, indent, "    [")
        join(io, (":$n" for n in keys(model.sets)), ", ")
        println(io, "],")
    else
        println(io)
    end
    print(io, indent, ")")
    return
end
