# AMPL allows Julia reserved words as declaration names (dirichlet's
# `s.t. end {n in N}: …`, lukvle5's `s.t. begin: …`); escape them with
# `var"…"` so the emitted macro call parses.
const _JULIA_KEYWORDS = Base.Set([
    "baremodule",
    "begin",
    "break",
    "catch",
    "const",
    "continue",
    "do",
    "else",
    "elseif",
    "end",
    "export",
    "false",
    "finally",
    "for",
    "function",
    "global",
    "if",
    "import",
    "let",
    "local",
    "macro",
    "module",
    "quote",
    "return",
    "struct",
    "true",
    "try",
    "using",
    "while",
])

function _julia_name(name::AbstractString)
    return name in _JULIA_KEYWORDS ? "var\"$name\"" : String(name)
end

function Base.show(io::IO, variable::Variable)
    print(io, "@variable(model, ")
    name = _julia_name(variable.name) * _format_axes(variable.axes)
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
        # Full axis-set conversion (brace literals, `by` steps,
        # `floor(Int, …)` for `/`-computed endpoints) — svanberg
        # constrains over `{i in 6..n-4 by 2}`, lukvle12 over
        # `{k in 1..3*(n-1)/4}`.
        set = JuMPConverter.AMPL._axis_set_to_julia(axe.set)
        if axe.name == axe.set
            push!(parts, set)
        else
            push!(parts, "$(axe.name) in $set")
        end
    end
    body = join(parts, ", ")
    if !isnothing(axes.condition)
        cond = _ampl_range_to_julia(axes.condition)
        body *= "; " * JuMPConverter.AMPL._boolify_condition(cond)
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
        # Indexed expression default: independent iters become a
        # `DenseAxisArray` comprehension; a tuple iter (`param dist
        # {(i, j) in arcs} := …`) or an axis depending on an earlier
        # one (qcqp's `LQ{i in 1..n, j in 1..i}`) becomes a
        # `SparseAxisArray`.
        if length(p.axes.axes) > 1
            return _format_multi_axis_expr_kwarg(p)
        end
        if length(p.axes.axes) == 1
            a = p.axes.axes[1]
            set = JuMPConverter.AMPL._axis_set_to_julia(a.set)
            if occursin(Regex("\\b" * p.name * "\\["), p.default_expr)
                # Recursive default (liswet1's
                # `param B{i in 0..K} := if i==0 then 1 else B[i-1]*i`):
                # the expression indexes the parameter being defined, so
                # a comprehension would reference `B` before it exists.
                # Emit a sequential fill in element order instead.
                return string(
                    "$(p.name) = let $(p.name) = ",
                    "JuMP.Containers.DenseAxisArray(",
                    "Vector{Float64}(undef, length($set)), $set)\n",
                    "        for $(a.name) in $set\n",
                    "            $(p.name)[$(a.name)] = $(p.default_expr)\n",
                    "        end\n",
                    "        $(p.name)\n",
                    "    end",
                )
            end
            if startswith(a.name, "(")
                return "$(p.name) = JuMP.Containers.SparseAxisArray(Dict($(a.name) => $(p.default_expr) for $(a.name) in $set))"
            else
                return "$(p.name) = JuMP.Containers.DenseAxisArray([$(p.default_expr) for $(a.name) in $set], $set)"
            end
        end
        return _unset_kwarg(p.name)
    end
    isnothing(p.default) && return _unset_kwarg(p.name)
    rendered_default = _render_number(p.default)
    if isnothing(p.axes)
        return "$(p.name) = $rendered_default"
    end
    axes_strs = [_ampl_range_to_julia(a.set) for a in p.axes.axes]
    lengths = join(["length($a)" for a in axes_strs], ", ")
    fill_call = "fill($rendered_default, $lengths)"
    return "$(p.name) = JuMP.Containers.DenseAxisArray($fill_call, $(join(axes_strs, ", ")))"
end

# `param NAME{i in A, j in B, …} := EXPR;` — independent axes become
# an N-d `DenseAxisArray` comprehension; when a later axis references
# an earlier one (qcqp's triangular `LQ{i in 1..n, j in 1..i}`) the
# shape is ragged, so emit a `SparseAxisArray` over the flattened
# generator instead.
function _format_multi_axis_expr_kwarg(p::Parameter)
    axes = p.axes.axes
    names = [a.name for a in axes]
    sets = [JuMPConverter.AMPL._axis_set_to_julia(a.set) for a in axes]
    dependent = any(
        k -> any(
            j -> occursin(Regex("\\b" * names[j] * "\\b"), axes[k].set),
            1:(k-1),
        ),
        2:length(axes),
    )
    if dependent
        key = "(" * join(names, ", ") * ")"
        iters = join(
            ("for $(names[k]) in $(sets[k])" for k in eachindex(axes)),
            " ",
        )
        return "$(p.name) = JuMP.Containers.SparseAxisArray(Dict($key => $(p.default_expr) $iters))"
    end
    iters = join(("$(names[k]) in $(sets[k])" for k in eachindex(axes)), ", ")
    return "$(p.name) = JuMP.Containers.DenseAxisArray([$(p.default_expr) for $iters], $(join(sets, ", ")))"
end

# A Float64 whose value happens to be integral (`param NS := 12`)
# renders as `12` rather than `12.0` so `1..NS` becomes a JuMP-friendly
# `UnitRange{Int}` instead of `StepRangeLen{Float64, …}`.
function _render_number(v::Float64)
    if isfinite(v) && isinteger(v) && abs(v) < 2.0^53
        return string(Int(v))
    end
    return string(v)
end

# A set or parameter with no default and no data-section value is
# supplied by the `.dat` at build time. Rather than a bare required
# keyword (which Julia errors on when omitted, even if the model never
# uses it — MacMPEC's vestigial `InitPoints`/`rho_0`), default it to an
# `Unset{:name}` sentinel: unused ⇒ harmless, used ⇒ a `MethodError`
# whose type names the missing value. `build_model(path)` populates real
# values, so the sentinel only ever survives for genuinely-unset data.
_unset_kwarg(name) = "$name = JuMPConverter.AMPL.Unset{:$name}()"

function _format_set_kwarg(s::Set, inline::Bool)
    if inline
        return "$(s.name) = _INLINE_DATA[\"$(s.name)\"]"
    end
    return isnothing(s.default) ? _unset_kwarg(s.name) :
           "$(s.name) = $(s.default)"
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
    name = _julia_name(constraint.name) * _format_axes(constraint.axes)
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

# A `Float64` fix value emits as a literal; a `String` value is already
# Julia expression source (`speed`) and emits verbatim.
_format_fix_value(v::Float64) = repr(v)
_format_fix_value(v::AbstractString) = String(v)

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
    # AMPL parameters with a `default` return it for any index the data
    # leaves unset; wrap each indexed one so a missing-key access falls
    # back to the default instead of throwing (the shim is transparent
    # for a fully-populated container). Done before the variables, whose
    # bounds may reference such a parameter (`var z >= zl[k], <= zu[k]`).
    for (kind, name) in model.kwarg_order
        kind === :param || continue
        p = model.parameters[name]
        (isnothing(p.default) || isnothing(p.axes)) && continue
        println(
            io,
            "    $name = JuMPConverter.AMPL.with_default($name, $(_render_number(p.default)))",
        )
    end
    println(io, "    model = Model()")
    for variable in values(model.variables)
        println(io, "    ", variable)
    end
    for constraint in model.constraints
        println(io, "    ", constraint)
    end
    println(io, "    ", model.objective)
    for fx in model.fixes
        _print_fix(io, fx, "    ", _format_fix_value(fx.value))
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
