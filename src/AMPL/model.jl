"""
    _read_axes!(lex::Lexer)

Parse an indexing expression `{i in S, j in T : condition}` from tokens.
Returns `(Axes, nothing)` or `(nothing, nothing)` if no `{` is next.
"""
function _read_axes!(lex::Lexer)
    if peek(lex).kind != TOKEN_LBRACE
        return nothing
    end
    read_token!(lex)  # consume {
    # Read everything until }, tracking brace depth for nested expressions
    content = read_balanced!(lex, TOKEN_LBRACE, TOKEN_RBRACE; compact = true)
    # Split on `:` for condition (but not `::` or `:=`)
    # The condition is after the last top-level `:` that is not inside braces
    axes_str, cond = _split_condition(content)
    axes = _parse_axe.(_split_axes(axes_str))
    return JuMPConverter.Axes(axes, isempty(cond) ? nothing : cond)
end

function _split_condition(s::AbstractString)
    # Find the last `:` not inside braces/brackets/parens
    depth = 0
    last_colon = 0
    for (i, c) in enumerate(s)
        if c in ('{', '[', '(')
            depth += 1
        elseif c in ('}', ']', ')')
            depth -= 1
        elseif c == ':' && depth == 0
            last_colon = i
        end
    end
    if last_colon == 0
        return strip(s), ""
    end
    return strip(s[1:(last_colon-1)]), strip(s[(last_colon+1):end])
end

function _split_axes(s::AbstractString)
    # Split on commas not inside braces/brackets/parens
    parts = String[]
    depth = 0
    start = 1
    for (i, c) in enumerate(s)
        if c in ('{', '[', '(')
            depth += 1
        elseif c in ('}', ']', ')')
            depth -= 1
        elseif c == ',' && depth == 0
            push!(parts, strip(s[start:(i-1)]))
            start = i + 1
        end
    end
    push!(parts, strip(s[start:end]))
    return filter(!isempty, parts)
end

function _parse_axe(s::AbstractString)
    s = strip(s)
    # Find the ` in` keyword at depth 0, handling tuple indices like
    # "(i, j) in S". The following char is normally a space, but the
    # lexer glues an opening bracket right after (`k in{-1,1}`,
    # `i in(1..n)`), so accept a delimiter there too.
    depth = 0
    n = lastindex(s)
    i = firstindex(s)
    while i <= n
        c = s[i]
        if c in ('(', '{', '[')
            depth += 1
        elseif c in (')', '}', ']')
            depth -= 1
        elseif c == ' ' && depth == 0
            j2 = nextind(s, i)
            j3 = j2 <= n ? nextind(s, j2) : (n + 1)
            j4 = j3 <= n ? nextind(s, j3) : (n + 1)
            if j3 <= n &&
               s[j2] == 'i' &&
               s[j3] == 'n' &&
               (j4 > n || s[j4] in (' ', '{', '(', '['))
                name = strip(s[firstindex(s):prevind(s, i)])
                set = j4 > n ? "" : strip(s[j4:n])
                return JuMPConverter.Axe(name, isempty(set) ? name : set)
            end
        end
        i = nextind(s, i)
    end
    # No "in" found at depth 0 — bare set or range reference
    return JuMPConverter.Axe(s, s)
end

"""
    _read_expression!(lex::Lexer, stops)

Read tokens until a stop token kind is reached, returning the expression
text. Handles balanced braces/brackets/parens within.
"""
function _read_expression!(
    lex::Lexer,
    stops::NTuple{N,TokenKind};
    stop_keywords::Tuple{Vararg{String}} = (),
) where {N}
    parts = String[]
    prev_kind = nothing
    while true
        t = peek(lex)
        if t.kind in stops || t.kind == TOKEN_EOF
            break
        end
        # When called from `_read_summation!`, stop at keywords that
        # belong to an enclosing construct: `complements` (the variable
        # side of a complementarity constraint) and `else`/`then` (the
        # `if` conditional the sum is a branch of, NARX_CFy-style
        # `if j==1 then sum{u in 1..Nu}(…) else sum{u in 1..Nu}(…)`).
        if t.kind == TOKEN_IDENTIFIER && t.value in stop_keywords
            break
        end
        # AMPL `sum {idx} body` (also `prod`/`max`/`min`) → Julia
        # generator syntax; `max`/`min` over an index set are Julia's
        # `maximum`/`minimum` (qcqp's `max{k in 1..n} abs(A0[i,k])`).
        reducer =
            t.kind == TOKEN_IDENTIFIER ? get(_REDUCERS, t.value, nothing) :
            nothing
        if reducer !== nothing && peek(lex, 2).kind == TOKEN_LBRACE
            read_token!(lex)  # consume the reducer keyword
            if !isempty(parts) && _needs_space(prev_kind, t.kind)
                push!(parts, " ")
            end
            push!(parts, _read_summation!(lex, reducer, stops))
            prev_kind = TOKEN_RPAREN
            continue
        end
        read_token!(lex)
        val = emit_token(t)
        # Insert spacing intelligently
        if !isempty(parts) && _needs_space(prev_kind, t.kind)
            push!(parts, " ")
        end
        if t.kind == TOKEN_LBRACE
            push!(parts, "{")
            inner =
                read_balanced!(lex, TOKEN_LBRACE, TOKEN_RBRACE; compact = true)
            push!(parts, inner)
            push!(parts, "}")
            prev_kind = TOKEN_RBRACE
        elseif t.kind == TOKEN_LBRACKET
            push!(parts, "[")
            inner = read_balanced!(
                lex,
                TOKEN_LBRACKET,
                TOKEN_RBRACKET;
                compact = true,
            )
            push!(parts, inner)
            push!(parts, "]")
            prev_kind = TOKEN_RBRACKET
        elseif t.kind == TOKEN_LPAREN
            push!(parts, "(")
            push!(parts, _read_paren_contents!(lex))
            push!(parts, ")")
            prev_kind = TOKEN_RPAREN
        else
            push!(parts, val)
            prev_kind = t.kind
        end
    end
    return join(parts)
end

# Read tokens up to a matching `)`, treating commas as argument separators
# so each argument is itself processed by `_read_expression!` (and gets sum
# expansion).
function _read_paren_contents!(lex::Lexer)
    args = String[]
    while true
        seg = _read_expression!(lex, (TOKEN_RPAREN, TOKEN_COMMA))
        push!(args, seg)
        if peek(lex).kind == TOKEN_COMMA
            read_token!(lex)
        else
            break
        end
    end
    expect!(lex, TOKEN_RPAREN)
    return join(args, ", ")
end

const _REDUCERS = Dict(
    "sum" => "sum",
    "prod" => "prod",
    "max" => "maximum",
    "min" => "minimum",
)

const _SUM_TERMINATORS = (
    TOKEN_PLUS,
    TOKEN_MINUS,
    TOKEN_EQ,
    TOKEN_GEQ,
    TOKEN_LEQ,
    TOKEN_LT,
    TOKEN_GT,
    TOKEN_NEQ,
    TOKEN_AND,
    TOKEN_OR,
    TOKEN_COMMA,
    TOKEN_RPAREN,
    TOKEN_RBRACE,
    TOKEN_RBRACKET,
)

# Read `sum {IDX} BODY` and return Julia text `sum(BODY for IDX)`.
# `sum` has already been consumed; `{` is the next token.
function _read_summation!(lex::Lexer, op::String, outer_stops)
    expect!(lex, TOKEN_LBRACE)
    idx = read_balanced!(lex, TOKEN_LBRACE, TOKEN_RBRACE)
    # AMPL `sum` binds at multiplicative precedence: body extends through
    # `*`, `/`, `^` and indexing/parens but stops at `+`, `-`, comparisons,
    # commas, or the outer expression's stop tokens.
    body_stops = (outer_stops..., _SUM_TERMINATORS...)
    body = strip(
        _read_expression!(
            lex,
            body_stops;
            stop_keywords = ("complements", "else", "then"),
        ),
    )
    # Keep the outer parens around an `(if … then … [else …])` body so
    # the ternary-conversion regex matches the if/then pair, not the
    # enclosing `sum(... for …)` parens.
    if !startswith(body, "(if ") && !startswith(body, "(if(")
        body = _strip_outer_parens(body)
    end
    idx = _ampl_index_to_julia(idx)
    return "$op($body for $idx)"
end

function _strip_outer_parens(s::AbstractString)
    (startswith(s, "(") && endswith(s, ")")) || return s
    depth = 0
    for (i, c) in enumerate(s)
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            if depth == 0 && i < lastindex(s)
                return s
            end
        end
    end
    return strip(s[(nextind(s, 1)):prevind(s, lastindex(s))])
end

# An index-set filter condition as a Julia `Bool`. AMPL treats a bare
# arithmetic condition as true when nonzero (dirichlet's
# `{n in N : BNDRY[n]}` with `BNDRY` a 0/1 param), but JuMP's generator
# filter needs an actual `Bool`, so wrap a condition that carries no
# relational/logical/membership operator in `!= 0`. `x != 0` also works
# when `x` is already a `Bool`, so this is safe to apply unconditionally.
function _boolify_condition(cond::AbstractString)
    c = strip(cond)
    isempty(c) && return String(c)
    occursin(r"[<>]|==|!=|&&|\|\||\bin\b", c) && return String(c)
    return "($c) != 0"
end

# AMPL parameters declared with `default V` return `V` for any index the
# `.dat` leaves unset — `param A{J,I} default 0;` populated with `.`
# entries (hs044-i, siouxfls). JuMP containers throw on a missing key
# instead, so the generated `build_model` wraps every defaulted indexed
# parameter in this shim, which falls back to the default on a
# `KeyError`/`BoundsError`. The underlying container (`SparseAxisArray`,
# `DenseAxisArray`, `Array`, `Dict`, scalar) is left untouched otherwise.
struct DefaultArray{D,T}
    data::D
    default::T
end

with_default(data, default) = DefaultArray(data, default)

function Base.getindex(a::DefaultArray, idx...)
    try
        return a.data[idx...]
    catch err
        (err isa KeyError || err isa BoundsError) && return a.default
        rethrow()
    end
end

# A single axis' set expression as Julia source: brace literals become
# vectors (ex4_160's `sum{k in {-1,1}}` — Julia's `{}` vector syntax is
# discontinued), `A..B [by S]` ranges become `A:B` / `A:S:B`, and range
# endpoints computed with `/` are wrapped in `floor(Int, …)` — AMPL
# ranges iterate integers (lukvle2's `{i in 1..n/2}`), while a Julia
# range with a Float64 endpoint iterates Float64s that then fail as
# array indices.
function _axis_set_to_julia(s::AbstractString)
    s = strip(s)
    if startswith(s, "{") && endswith(s, "}")
        return "[" * strip(s[2:prevind(s, lastindex(s))]) * "]"
    end
    m = match(r"^(.+?)\s*\.\.\s*(.+?)(?:\s+by\s+(\S+))?$", s)
    m === nothing && return String(s)
    lo, hi, step = m.captures
    wrap(x) = occursin("/", x) ? "floor(Int, $x)" : String(x)
    lo, hi = wrap(lo), wrap(hi)
    return step === nothing ? "$lo:$hi" : "$lo:$step:$hi"
end

# Translate AMPL index syntax to Julia generator syntax: each axis'
# set is converted via `_axis_set_to_julia` and a `:` that separates
# the indices from a condition becomes ` if `.
function _ampl_index_to_julia(idx::AbstractString)
    axes_str, cond = _split_condition(idx)
    parts = String[]
    for a in _parse_axe.(_split_axes(axes_str))
        set = _axis_set_to_julia(a.set)
        push!(parts, a.name == a.set ? set : "$(a.name) in $set")
    end
    body = join(parts, ", ")
    return isempty(cond) ? body : string(body, " if ", _boolify_condition(cond))
end

"""
    _parse_param!(lex::Lexer, model::JuMPConverter.Model)

Parse: `param name [{axes}] [integer] [binary] [default expr] [check...] ;`
"""
function _parse_param!(lex::Lexer, model::JuMPConverter.Model)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    axes = _read_axes!(lex)
    default = nothing
    default_expr = nothing
    integer = false
    # Parse optional qualifiers until semicolon
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_IDENTIFIER && t.value == "default"
            # The default may be an expression rather than a literal
            # (cont5_1's `param m default n;`, ex6_160's
            # `param pi default 4*atan(1);`) — treat it exactly like
            # `:=` below.
            read_token!(lex)
            rhs = strip(_read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA)))
            parsed = tryparse(Float64, rhs)
            if parsed !== nothing
                default = parsed
            else
                default_expr = clean_expression(String(rhs))
            end
        elseif t.kind == TOKEN_ASSIGN
            # `param NAME := VALUE;` — inline assignment. Numeric
            # literal becomes the `default` (design-cent-1's
            # `pi := 3.141592654`); an expression becomes
            # `default_expr` so the generated kwarg can carry it
            # (incid-set1's `h := 1/n`). Stop at `,` too because AMPL
            # allows trailing qualifiers (taxmcp's
            # `param kbar := 1, > 0;`).
            read_token!(lex)
            rhs = strip(_read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA)))
            parsed = tryparse(Float64, rhs)
            if parsed !== nothing
                default = parsed
            else
                default_expr = clean_expression(String(rhs))
            end
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "integer"
            read_token!(lex)
            integer = true
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "binary"
            read_token!(lex)
            # binary param (rare, treat as integer)
            integer = true
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "symbolic"
            read_token!(lex)
        elseif t.kind == TOKEN_GEQ ||
               t.kind == TOKEN_LEQ ||
               t.kind == TOKEN_GT ||
               t.kind == TOKEN_LT
            # `param T > 0 default 1 integer;` — the check value sits between
            # the comparison and the next qualifier. Skip until a qualifier
            # keyword, comma, or semicolon.
            read_token!(lex)
            while true
                nx = peek(lex)
                if nx.kind in
                   (TOKEN_SEMICOLON, TOKEN_COMMA, TOKEN_EOF, TOKEN_ASSIGN)
                    break
                elseif nx.kind == TOKEN_IDENTIFIER && nx.value in
                       ("default", "integer", "binary", "symbolic", "in")
                    break
                end
                read_token!(lex)
            end
            if peek(lex).kind == TOKEN_COMMA
                read_token!(lex)
            end
        elseif t.kind == TOKEN_EQ
            # Computed param: `param total = expr;` — read expression
            read_token!(lex)
            _read_expression!(lex, (TOKEN_SEMICOLON,))
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "in"
            # `param name symbolic in SET;` or an interval check like
            # qcqp's `param ml integer in [0,n);` / `param sq in (0,1];`.
            # Half-open intervals mix `[`/`(` with `)`/`]`, so a
            # balanced expression read would run past the statement —
            # skip raw tokens up to the next qualifier keyword, `:=`,
            # or `;` instead. (Not `,`: intervals contain one.)
            read_token!(lex)
            while true
                nx = peek(lex)
                if nx.kind in (TOKEN_SEMICOLON, TOKEN_EOF, TOKEN_ASSIGN)
                    break
                elseif nx.kind == TOKEN_IDENTIFIER &&
                       nx.value in ("default", "integer", "binary", "symbolic")
                    break
                end
                read_token!(lex)
            end
        elseif t.kind == TOKEN_COMMA
            read_token!(lex)
        else
            # Unknown qualifier — skip token
            read_token!(lex)
        end
    end
    push!(
        model,
        JuMPConverter.Parameter(; name, axes, integer, default, default_expr),
    )
    return
end

"""
    _parse_var!(lex::Lexer, model::JuMPConverter.Model)

Parse: `var name [{axes}] [>= lb] [<= ub] [binary] [integer] [:= init] ;`
"""
function _parse_var!(lex::Lexer, model::JuMPConverter.Model)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    axes = _read_axes!(lex)
    lower_bound = nothing
    upper_bound = nothing
    fixed_value = nothing
    binary = false
    integer = false
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_GEQ
            read_token!(lex)
            # Stop at the opposite-direction comparator too (`var x
            # >= LB <= UB;` needs to split into two bounds, not one
            # swallowed `"LB <= UB"`) and at `:=` so the trailing
            # initial value (`var x >= 0 := x0;`) doesn't get glued
            # onto the lower bound.
            lower_bound = _read_expression!(
                lex,
                (
                    TOKEN_SEMICOLON,
                    TOKEN_COMMA,
                    TOKEN_LEQ,
                    TOKEN_GEQ,
                    TOKEN_ASSIGN,
                ),
            )
        elseif t.kind == TOKEN_LEQ
            read_token!(lex)
            upper_bound = _read_expression!(
                lex,
                (
                    TOKEN_SEMICOLON,
                    TOKEN_COMMA,
                    TOKEN_LEQ,
                    TOKEN_GEQ,
                    TOKEN_ASSIGN,
                ),
            )
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "binary"
            read_token!(lex)
            binary = true
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "integer"
            read_token!(lex)
            integer = true
        elseif t.kind == TOKEN_ASSIGN
            # Initial value: `:= expr` — skip for now
            read_token!(lex)
            _read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA))
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "default"
            read_token!(lex)
            _read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA))
        elseif t.kind == TOKEN_EQ
            read_token!(lex)
            # Defined variable: `var Total = expr;`
            _read_expression!(lex, (TOKEN_SEMICOLON,))
        elseif t.kind == TOKEN_COMMA
            read_token!(lex)
        else
            read_token!(lex)
        end
    end
    push!(
        model,
        JuMPConverter.Variable(;
            name,
            axes,
            lower_bound,
            upper_bound,
            fixed_value,
            binary,
            integer,
        ),
    )
    return
end

"""
    _parse_set!(lex::Lexer, model::JuMPConverter.Model)

Parse: `set name [within ...] [= ...] [dimen n] [ordered] ;`
Skip set declarations (not stored in model currently).
"""
function _parse_set!(lex::Lexer, model::JuMPConverter.Model)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    default = nothing
    within = false
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        # `:=` is initialization, `=` is a derived-set definition; both
        # supply a default for our purposes.
        if t.kind == TOKEN_ASSIGN || t.kind == TOKEN_EQ
            read_token!(lex)
            raw = strip(_read_expression!(lex, (TOKEN_SEMICOLON,)))
            default = _set_default_to_julia(String(raw))
        elseif t.kind == TOKEN_IDENTIFIER && t.value == "within"
            # `set X within Y;` — X is a subset of Y. MacMPEC `.dat`s
            # usually populate it via `let X := { }; let X := X union
            # { k };` which we skip; default to empty so the kwarg is
            # at least not required.
            within = true
            read_token!(lex)
        else
            read_token!(lex)
        end
    end
    if isnothing(default) && within
        default = "Int[]"
    end
    push!(model, JuMPConverter.Set(; name, default))
    return
end

# A `set NAME := <expr>;` default as Julia source. A brace form with
# iterators — ex1_160's `set P := {i in 1..n2, j in 1..n2: COND};` —
# becomes a comprehension over index tuples with the condition as its
# filter; a plain brace literal (`{ 3, 4 }`) becomes a `Vector` (Julia's
# `{}` vector syntax is discontinued); anything else just gets ranges
# and set operators translated.
function _set_default_to_julia(raw::String)
    s = strip(raw)
    if startswith(s, "{") && endswith(s, "}")
        inner = strip(s[2:prevind(s, lastindex(s))])
        axes_str, cond = _split_condition(inner)
        axes = _parse_axe.(_split_axes(axes_str))
        if any(a -> a.name != a.set, axes)
            names = [a.name for a in axes]
            element =
                length(names) == 1 ? names[1] : "(" * join(names, ", ") * ")"
            iters = join(
                ("$(a.name) in $(_axis_set_to_julia(a.set))" for a in axes),
                ", ",
            )
            filter =
                isempty(cond) ? "" :
                " if " * _boolify_condition(clean_expression(cond))
            return "[$element for $iters$filter]"
        end
        # No iterators: a single range `{1..NODES}` is that range;
        # an enumeration `{3, 4}` / `{-1, 1}` is a vector literal
        # (Julia's `{}` vector syntax is discontinued).
        inner_s = String(inner)
        if occursin("..", inner_s) && !occursin(",", inner_s)
            return _axis_set_to_julia(inner_s)
        end
        return "[" * inner_s * "]"
    end
    cleaned = replace(s, ".." => ":")
    return _ampl_set_ops_to_julia(cleaned)
end

# AMPL binary set operators → Julia equivalents. Only handles
# simple-identifier operands (`A diff B`), which is what the MacMPEC
# `.mod`s exercise; more general operands would need actual operator
# parsing rather than a regex sub.
function _ampl_set_ops_to_julia(s::AbstractString)
    for (kw, jl) in (
        "diff" => "setdiff",
        "symdiff" => "symdiff",
        "union" => "union",
        "inter" => "intersect",
    )
        s = replace(
            s,
            Regex(raw"(\w+)\s+" * kw * raw"\s+(\w+)") =>
                SubstitutionString(jl * raw"(\1, \2)"),
        )
    end
    return s
end

"""
    _parse_objective!(lex::Lexer, model::JuMPConverter.Model, sense)

Parse: `maximize|minimize name : expression ;`
"""
function _parse_objective!(
    lex::Lexer,
    model::JuMPConverter.Model,
    sense::MOI.OptimizationSense,
)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    expect!(lex, TOKEN_COLON)
    expression = _read_expression!(lex, (TOKEN_SEMICOLON,))
    expression = clean_expression(expression)
    model.objective = JuMPConverter.Objective(; name, sense, expression)
    return
end

"""
    _parse_constraint!(lex::Lexer, model::JuMPConverter.Model)

Parse: `name [{axes}] : expression ;`
"""
function _parse_constraint!(lex::Lexer, model::JuMPConverter.Model)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    axes = _read_axes!(lex)
    expect!(lex, TOKEN_COLON)
    expression = _read_expression!(lex, (TOKEN_SEMICOLON,))
    expression = clean_expression(expression)
    push!(model, JuMPConverter.Constraint(; name, axes, expression))
    return
end

# Parse `fix [{i in SET}] VAR[idx, …] := VALUE;` into a structured
# `FixStatement`. Covers both `parse_model` (model-section fix in the
# .mod) and `parse_dat` (fix in a data section / .dat file).
#
# Supported syntax matches what real `.mod`/`.dat`s exercise: taxmcp's
# scalar `fix PL := 1;`, bar-truss-3's `fix{i in m} H[i,'y1','y2'] := 0;`,
# clnlbeam's numeric indices `fix x[0] := 0.0;`, optmass's expression
# value `fix v[1,0] := speed;`, and dtoc1nd's range iter
# `fix {i in 1..ny} y[1,i] := 0.0;`.
function _parse_fix!(lex::Lexer)
    iter = nothing
    if peek(lex).kind == TOKEN_LBRACE
        read_token!(lex)  # consume `{`
        iter = _parse_fix_iter!(lex)
    end
    variable = Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    indices = Any[]
    if peek(lex).kind == TOKEN_LBRACKET
        read_token!(lex)
        while peek(lex).kind != TOKEN_RBRACKET
            push!(indices, _parse_fix_index!(lex))
            if peek(lex).kind == TOKEN_COMMA
                read_token!(lex)
            end
        end
        read_token!(lex)  # consume `]`
    end
    expect!(lex, TOKEN_ASSIGN)
    # A literal RHS becomes a `Float64` (this also covers `-1.0`, which
    # lexes as two tokens but round-trips through `tryparse`); anything
    # else (optmass's `fix v[1,0] := speed;`) is kept as a Julia
    # expression string.
    rhs = strip(_read_expression!(lex, (TOKEN_SEMICOLON,)))
    parsed = tryparse(Float64, rhs)
    value = parsed === nothing ? clean_expression(String(rhs)) : parsed
    return JuMPConverter.FixStatement(; variable, indices, value, iter)
end

function _parse_fix_iter!(lex::Lexer)
    var = Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    in_tok = expect!(lex, TOKEN_IDENTIFIER)
    @assert in_tok.value == "in"
    # The set is either a bare name (bar-truss-3's `{i in m}`) or an
    # inline expression (dtoc1nd's `{i in 1..ny}` → `1:ny`).
    rhs = strip(_read_expression!(lex, (TOKEN_RBRACE,)))
    expect!(lex, TOKEN_RBRACE)
    set = if occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", rhs)
        Symbol(rhs)
    else
        clean_expression(String(rhs))
    end
    return JuMPConverter.FixIter(; var, set)
end

# Each fix index is either an iter-bound symbol (`i`), an AMPL
# string literal (`'y1'`), or a number (clnlbeam's `fix x[0]`).
function _parse_fix_index!(lex::Lexer)
    t = read_token!(lex)
    if t.kind == TOKEN_STRING
        return t.value
    elseif t.kind == TOKEN_IDENTIFIER
        return Symbol(t.value)
    elseif t.kind == TOKEN_NUMBER
        int = tryparse(Int, t.value)
        return int === nothing ? parse(Float64, t.value) : int
    end
    return error("unexpected token in fix index: $(t.kind) `$(t.value)`")
end

function _is_keyword(value::AbstractString)
    return value in (
        "param",
        "var",
        "set",
        "maximize",
        "minimize",
        "subject",
        "check",
        "data",
        "display",
        "option",
        "model",
        "solve",
        "fix",
        "let",
        "drop",
        "restore",
        "problem",
        "environ",
        "suffix",
        "redeclare",
    )
end

"""
    parse_model(mod::AbstractString)

Parse an AMPL `.mod` file into a `JuMPConverter.Model`.
Uses a tokenizer so that newlines are treated as spaces.
"""
function parse_model(mod::AbstractString)
    model = JuMPConverter.Model()
    lex = Lexer(mod)
    while peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_SEMICOLON
            read_token!(lex)
            continue
        end
        if t.kind != TOKEN_IDENTIFIER
            read_token!(lex)
            continue
        end
        kw = t.value
        if kw == "param"
            read_token!(lex)
            _parse_param!(lex, model)
        elseif kw == "var"
            read_token!(lex)
            _parse_var!(lex, model)
        elseif kw == "set"
            read_token!(lex)
            _parse_set!(lex, model)
        elseif kw == "maximize"
            read_token!(lex)
            _parse_objective!(lex, model, MOI.MAX_SENSE)
        elseif kw == "minimize"
            read_token!(lex)
            _parse_objective!(lex, model, MOI.MIN_SENSE)
        elseif kw == "subject"
            read_token!(lex)
            # Expect "to"
            t2 = peek(lex)
            if t2.kind == TOKEN_IDENTIFIER && t2.value == "to"
                read_token!(lex)
            end
            # Parse first constraint if on same line (after "subject to")
            if peek(lex).kind == TOKEN_IDENTIFIER &&
               !_is_keyword(peek(lex).value)
                _parse_constraint!(lex, model)
            end
        elseif kw == "s" &&
               peek(lex, 2).kind == TOKEN_DOT &&
               peek(lex, 3).kind == TOKEN_IDENTIFIER &&
               peek(lex, 3).value == "t" &&
               peek(lex, 4).kind == TOKEN_DOT
            # `s.t.` constraint prefix
            read_token!(lex)  # s
            read_token!(lex)  # .
            read_token!(lex)  # t
            read_token!(lex)  # .
            if peek(lex).kind == TOKEN_IDENTIFIER &&
               !_is_keyword(peek(lex).value)
                _parse_constraint!(lex, model)
            end
        elseif kw == "check"
            read_token!(lex)
            # Skip check statements
            _read_expression!(lex, (TOKEN_SEMICOLON,))
        elseif kw == "fix"
            read_token!(lex)
            fx = _parse_fix!(lex)
            fx === nothing || push!(model, fx)
        elseif kw == "data"
            # Switch to AMPL's data section: everything from here to EOF
            # is values for already-declared params/sets, not model code.
            # Capture the raw text so the emitted `.jl` can re-parse it
            # at load time and use the values as kwarg defaults.
            read_token!(lex)               # `data`
            expect!(lex, TOKEN_SEMICOLON)  # AMPL requires `data;`
            text = lex.input[lex.pos:end]
            model.inline_data_text = text
            # Parse without a schema: `_dat_parse_multi_column!` has
            # rough edges with set-of-tuples indexing and multi-column
            # tables that the schemaless path sidesteps. We only need
            # the names here, so the looser typing is fine.
            for name in keys(parse_dat(text))
                push!(model.inline_data_names, name)
            end
            # Scalar `let NAME := EXPR;` in the data section (camshape's
            # `let d_theta := 2*pi/(5*(n+1));`) assigns a value whose
            # expression may reference model params, so `parse_dat`
            # can't evaluate it — record it as the param's default
            # instead so it lands in the kwargs.
            for m in eachmatch(r"\blet\s+([A-Za-z_]\w*)\s*:=\s*([^;]+);", text)
                _apply_let_default!(
                    model,
                    String(m.captures[1]),
                    strip(m.captures[2]),
                )
            end
            # Indexed `let {iter in SET} NAME[iter] := RHS;` over a
            # simple set. A constant RHS (dirichlet's
            # `let {n in N} b[n] := 1;`) is the same value at every
            # element — a scalar default the emitter fills over the
            # param's axes. An index-referencing RHS (henon's
            # `let {n in N} c[n] := sqrt(COORDS[n,1]^2 + COORDS[n,2]^2);`)
            # becomes a comprehension default over `iter in SET`. An
            # RHS that references a *variable* (`let {n in N} u[n] :=
            # x[n];`) is a post-solve initialiser, not data — but we
            # can't tell those apart here, so we capture any param whose
            # kwarg would otherwise be required and let a genuine
            # initialiser simply be an unused default.
            for m in eachmatch(
                r"\blet\s*\{\s*(\w+)\s+in\s+(\w+)\s*\}\s*([A-Za-z_]\w*)\s*\[[^\]]*\]\s*:=\s*([^;]+);",
                text,
            )
                iter, set = String(m.captures[1]), String(m.captures[2])
                name, rhs = String(m.captures[3]), strip(m.captures[4])
                _apply_indexed_let_default!(model, name, iter, set, rhs)
            end
            return model
        elseif _is_keyword(kw)
            # Other keywords: skip until semicolon
            read_token!(lex)
            while peek(lex).kind != TOKEN_SEMICOLON &&
                  peek(lex).kind != TOKEN_EOF
                read_token!(lex)
            end
        else
            # Not a keyword — must be a constraint name
            _parse_constraint!(lex, model)
        end
        # Consume trailing semicolon if present
        if peek(lex).kind == TOKEN_SEMICOLON
            read_token!(lex)
        end
    end
    return model
end

# Record a data-section `let` assignment as parameter `name`'s default
# (a numeric literal → `default`, any other expression → `default_expr`)
# so it becomes a `build_model` kwarg default rather than a required
# argument. No-ops for an unknown param or one already supplied by an
# inline `data;` table.
function _apply_let_default!(
    model::JuMPConverter.Model,
    name::AbstractString,
    rhs::AbstractString,
)
    haskey(model.parameters, name) || return
    name in model.inline_data_names && return
    parsed = tryparse(Float64, rhs)
    old = model.parameters[name]
    model.parameters[name] = JuMPConverter.Parameter(;
        name = old.name,
        axes = old.axes,
        integer = old.integer,
        default = parsed,
        default_expr = parsed === nothing ? clean_expression(String(rhs)) :
                       nothing,
    )
    return
end

# Record an indexed data-section `let {iter in set} NAME[iter] := rhs;`
# as parameter `name`'s default. A numeric constant fills the param's
# existing axes; an index-referencing expression becomes a
# comprehension over `iter in set`, so the param's axes are rebound to
# that single iterator (the `.mod` declared them anonymously, e.g.
# `param c{N}`, but the comprehension needs the name `iter` to index by).
function _apply_indexed_let_default!(
    model::JuMPConverter.Model,
    name::AbstractString,
    iter::AbstractString,
    set::AbstractString,
    rhs::AbstractString,
)
    haskey(model.parameters, name) || return
    name in model.inline_data_names && return
    old = model.parameters[name]
    parsed = tryparse(Float64, rhs)
    if parsed !== nothing
        model.parameters[name] = JuMPConverter.Parameter(;
            name = old.name,
            axes = old.axes,
            integer = old.integer,
            default = parsed,
        )
        return
    end
    axes = JuMPConverter.Axes(
        [JuMPConverter.Axe(String(iter), String(set))],
        nothing,
    )
    model.parameters[name] = JuMPConverter.Parameter(;
        name = old.name,
        axes = axes,
        integer = old.integer,
        default_expr = clean_expression(String(rhs)),
    )
    return
end

"""
    read_model(path::AbstractString;
               example_dat::Union{Nothing,AbstractString} = nothing) -> Model

Parse an AMPL `.mod` and (optionally) an example `.dat` whose `fix`
statements declare which variables should become tunable `fix_<…>`
kwargs of the generated `build_model`.

The example `.dat`'s data values are ignored — only the `fix`
*structure* (variable, indices, iter pattern) is kept. Runtime `.dat`
files passed to `build_model(path::String)` may carry the same fixes
with different values; any fix whose structure wasn't pre-registered
this way is an error at load time.
"""
function read_model(
    path::AbstractString;
    example_dat::Union{Nothing,AbstractString} = nothing,
)
    model = parse_model(read(path, String))
    if example_dat !== nothing
        # Pass the model-derived schema so `parse_dat` takes the
        # typed branch — the schemaless path mis-parses some `.dat`s
        # (e.g. portfl1.dat: floats in indexed-param values).
        schema = DatSchema(model)
        data = parse_dat(read(example_dat, String), schema)
        fixes = get(data, "fixes", JuMPConverter.FixStatement[])
        for fx in fixes
            push!(model.parametric_fixes, fx)
        end
    end
    return model
end

"""
    fix_kwarg_name(fx::FixStatement) -> Symbol

Stable kwarg name for a parametric fix: `fix_<var>` plus the literal
(non-iter) indices joined with underscores. `fix PL := 1` →
`:fix_PL`; `fix{i in m} H[i,'y1','y2']` → `:fix_H_y1_y2`;
`fix x[1] := 0` → `:fix_x_1`.
"""
function fix_kwarg_name(fx::JuMPConverter.FixStatement)
    parts = ["fix", string(fx.variable)]
    for idx in fx.indices
        idx isa Symbol && continue
        push!(parts, string(idx))
    end
    return Symbol(join(parts, "_"))
end

function clean_expression(expr::AbstractString)
    expr = replace(expr, "complements" => "\u27c2")
    # 2./3 -> 2. / 3 otherwise Julia says it's ambiguous with broadcast
    expr = replace(expr, "./" => ". /")
    # AMPL stepped range `A .. B by S` → Julia `A:S:B` (svanberg's
    # `sum{i in 1..n-1 by 2}`). Must run before the plain `..` → `:`
    # rewrite below.
    expr = replace(expr, r"\.\.\s*(.+?)\s+by\s+([^\s,)\]}]+)" => s":\2:\1")
    # AMPL ranges use `..`; Julia uses `:`.
    expr = replace(expr, ".." => ":")
    # AMPL not-equal is spelled `<>` as well as `!=`.
    expr = replace(expr, r"<\s*>" => "!=")
    # AMPL uses bare `=` for equality constraints; JuMP requires `==`.
    # Don't touch `<=`, `>=`, `:=`, `!=`, or an existing `==`.
    expr = replace(expr, r"(?<![<>:!=])=(?!=)" => "==")
    # AMPL logical keywords: `and`/`or`/`not` → `&&`/`||`/`!`.
    expr = replace(expr, r"\band\b" => "&&")
    expr = replace(expr, r"\bor\b" => "||")
    expr = replace(expr, r"\bnot\b" => "!")
    # AMPL's infix `div`/`mod` and `**` power have no infix spelling in
    # Julia (dtoc1nd's `k div nx`, svanberg's `i mod 2`, arki0009's
    # `x100 ** (-0.24)`).
    expr = replace(expr, r"\bdiv\b" => "÷")
    expr = replace(expr, r"\bmod\b" => "%")
    expr = replace(expr, r"\*\s*\*" => "^")
    # AMPL `floor`/`ceil` return integers whose results index arrays
    # (gasoil's `min(nh, floor(tau[i]/h)+1)`); Julia's return Float64,
    # so pin the `Int` method. The negative lookahead avoids
    # re-wrapping a `floor(Int, …)` already emitted by
    # `_axis_set_to_julia` for a `/`-computed range endpoint.
    expr = replace(expr, r"\bfloor\s*\((?!\s*Int\b)" => "floor(Int, ")
    expr = replace(expr, r"\bceil\s*\((?!\s*Int\b)" => "ceil(Int, ")
    # AMPL RNG builtins → inline Julia `rand`/`randn` (both in Base, so
    # the generated file needs no extra import) — qcqp's `Uniform01()`,
    # `Uniform(-10, 10)`, `Normal01()`. The two-arg forms take simple
    # numeric arguments (no nested parens/commas), so a backreference
    # substitution suffices; `\1` is repeated in `Uniform` because its
    # arguments are literals, so the duplication is free.
    expr = replace(expr, r"\bUniform01\s*\(\s*\)" => "rand()")
    expr = replace(expr, r"\bNormal01\s*\(\s*\)" => "randn()")
    expr = replace(expr, r"\bIrand224\s*\(\s*\)" => "rand(0:(2^24 - 1))")
    expr = replace(
        expr,
        r"\bUniform\s*\(\s*([^(),]+?)\s*,\s*([^(),]+?)\s*\)" =>
            s"(\1 + (\2 - \1) * rand())",
    )
    expr = replace(
        expr,
        r"\bNormal\s*\(\s*([^(),]+?)\s*,\s*([^(),]+?)\s*\)" =>
            s"(\1 + \2 * randn())",
    )
    expr = _ampl_set_ops_to_julia(expr)
    expr = _ampl_conditional_to_ternary(String(expr))
    expr = _convert_complementarity(expr)
    return expr
end

"""
    _ampl_conditional_to_ternary(expr::String) -> String

AMPL conditional `if COND then A [else B]` → Julia ternary
`(COND ? A : B)`, a missing `else` defaulting to 0.

Converts the rightmost `if` first so chained `else if …` collapses
inside-out, and scans operands with bracket-depth awareness so they may
contain arbitrary balanced nesting — including `sum(... for …)`
generators. An `if` with no `then` at its own depth (the filter of a
Julia generator emitted by the sum conversion) is left untouched. A
branch ends at `else`/`for`, a comma at the `if`'s depth, a bracket
closing the group the `if` lives in, or the end of the expression.
"""
function _ampl_conditional_to_ternary(expr::String)
    while (converted = _convert_last_conditional(expr)) !== nothing
        expr = converted
    end
    return expr
end

function _is_word_byte(b::UInt8)
    return UInt8('a') <= b <= UInt8('z') ||
           UInt8('A') <= b <= UInt8('Z') ||
           UInt8('0') <= b <= UInt8('9') ||
           b == UInt8('_')
end

# `word` starts at byte `i` of `expr` with word boundaries on each side.
function _keyword_at(expr::String, i::Int, word::String)
    nb = ncodeunits(expr)
    i + ncodeunits(word) - 1 <= nb || return false
    for (k, c) in enumerate(codeunits(word))
        codeunit(expr, i + k - 1) == c || return false
    end
    i > 1 && _is_word_byte(codeunit(expr, i - 1)) && return false
    j = i + ncodeunits(word)
    j <= nb && _is_word_byte(codeunit(expr, j)) && return false
    return true
end

function _convert_last_conditional(expr::String)
    for m in Iterators.reverse(collect(eachmatch(r"\bif\b", expr)))
        r = _try_convert_conditional(expr, m.offset)
        r === nothing || return r
    end
    return nothing
end

# Scan `expr` from byte `i`, tracking bracket depth, and return
# `(stop_byte, kind)` where `kind` is the keyword (`:then`/`:else`/
# `:for`) or terminator (`:comma`/`:comparison`/`:close`/`:eos`) that
# ended the scan. `stop_at_comparison` is set when scanning a branch —
# lukvle12's `s.t. eq{k}: if C1 then A else B = 0;` constrains the
# whole conditional, so the `= 0` must stay outside the ternary (JuMP
# rejects `:if` as a constraint head) — but not when scanning for the
# `then`, since the condition itself compares (`if k % 3 == 1 then`).
function _scan_branch(expr::String, i::Int; stop_at_comparison::Bool = false)
    nb = ncodeunits(expr)
    depth = 0
    while i <= nb
        b = codeunit(expr, i)
        if b in (UInt8('('), UInt8('['), UInt8('{'))
            depth += 1
        elseif b in (UInt8(')'), UInt8(']'), UInt8('}'))
            depth == 0 && return (i, :close)
            depth -= 1
        elseif depth == 0
            if b == UInt8(',')
                return (i, :comma)
            elseif stop_at_comparison && (
                b in (UInt8('='), UInt8('<'), UInt8('>')) || (
                    b == UInt8('!') &&
                    i < nb &&
                    codeunit(expr, i + 1) == UInt8('=')
                )
            )
                return (i, :comparison)
            elseif _keyword_at(expr, i, "then")
                return (i, :then)
            elseif _keyword_at(expr, i, "else")
                return (i, :else)
            elseif _keyword_at(expr, i, "for")
                return (i, :for)
            end
        end
        i += 1
    end
    return (nb + 1, :eos)
end

function _try_convert_conditional(expr::String, ifpos::Int)
    nb = ncodeunits(expr)
    cond_from = ifpos + 2
    then_at, kind = _scan_branch(expr, cond_from)
    kind === :then || return nothing  # generator filter, not a conditional
    cond = strip(expr[cond_from:prevind(expr, then_at)])
    then_from = then_at + 4
    stop, kind = _scan_branch(expr, then_from; stop_at_comparison = true)
    then_branch = strip(expr[then_from:prevind(expr, stop)])
    if kind === :else
        else_from = stop + 4
        stop, _ = _scan_branch(expr, else_from; stop_at_comparison = true)
        else_branch = strip(expr[else_from:prevind(expr, stop)])
    else
        else_branch = "0"
    end
    (isempty(cond) || isempty(then_branch) || isempty(else_branch)) &&
        return nothing
    head = ifpos == 1 ? "" : expr[1:prevind(expr, ifpos)]
    tail = stop > nb ? "" : expr[stop:end]
    return string(
        head,
        "(",
        cond,
        " ? ",
        then_branch,
        " : ",
        else_branch,
        ")",
        tail,
    )
end

# AMPL writes complementarity as `LB <= LHS \u27c2 RHS >= UB` with explicit
# bounds. JuMP's `@constraint(model, expr \u27c2 var)` takes a single variable
# on the right and infers bounds from its declaration. Strip the redundant
# bounds and put the simple variable side last.
function _convert_complementarity(expr::AbstractString)
    contains(expr, "\u27c2") || return expr
    parts = split(expr, "\u27c2")
    length(parts) == 2 || return expr
    lhs_raw = strip(parts[1])
    rhs_raw = strip(parts[2])
    # `0 == EXPR \u27c2 VAR` (KKT stationarity in AMPL) is degenerate
    # complementarity: the left side is already an equality, so the
    # `\u27c2` part is redundant for JuMP. Emit the plain equality.
    if (m = match(r"^0\s*==\s*(.*)$"s, lhs_raw)) !== nothing
        return strip(m.captures[1]) * " == 0"
    end
    stripped_lhs = _strip_complementarity_lb(lhs_raw)
    if stripped_lhs == lhs_raw
        # No leading numeric bound — this isn't `LB <= VAR <= UB`;
        # it's a relation `EXPR1 OP EXPR2` (e.g. taxmcp's
        # `PK * kbar >= sum(...)`). Convert to a subtraction so JuMP
        # sees one expression on each side of `⟂`.
        lhs = _relation_to_difference(lhs_raw)
    else
        lhs = _strip_complementarity_lhs_ub(stripped_lhs)
    end
    rhs = _strip_complementarity_ub(rhs_raw)
    if !_is_simple_variable_ref(lhs) && _is_simple_variable_ref(rhs)
        return "$lhs \u27c2 $rhs"
    elseif _is_simple_variable_ref(lhs) && !_is_simple_variable_ref(rhs)
        return "$rhs \u27c2 $lhs"
    end
    return "$lhs \u27c2 $rhs"
end

# The lexer emits `-10` as two tokens (`-`, `10`), so the rendered
# expression strings have `- 10` with a space — the `-?\s*` pattern
# tolerates that.
const _NUMBER_RE = raw"-?\s*\d+(?:\.\d+)?"

function _strip_complementarity_lb(s::AbstractString)
    # Strip a leading numeric bound: `0 <=`, `-10 <=`, or the
    # mirror-image `0 >=` / `5 >=` form (some `.mod`s write the bound
    # with the larger side on the left).
    m = match(Regex("^" * _NUMBER_RE * raw"\s*(?:<=|>=)\s*(.*)$", "s"), s)
    return m === nothing ? String(s) : strip(m.captures[1])
end

function _strip_complementarity_lhs_ub(s::AbstractString)
    # When the AMPL form is `LB <= EXPR <= UB ⟂ VAR`, the trailing
    # `<= UB` lives on the LHS. JuMP rejects this mixed comparison
    # chain; strip it. The UB can be a number (`bilevel1m`'s `<= 20`)
    # or an expression (`design-cent-21`'s `<= x[4]^2 * x[3]^2`), so
    # locate the last top-level `<=` / `>=` and drop everything from
    # there onward.
    op_start = _last_top_level_comparator(s)
    op_start === nothing && return String(s)
    return String(strip(s[1:prevind(s, op_start)]))
end

# Convert `A >= B` / `A <= B` / `A == B` at the top level into the
# difference JuMP wants on one side of `⟂`. For taxmcp's `PK * kbar >=
# sum(...)` this becomes `PK * kbar - (sum(...))`; for `0 = LHS` it's
# already handled earlier by the equality short-circuit.
function _relation_to_difference(s::AbstractString)
    op_start = _last_top_level_comparator(s)
    op_start === nothing && return String(s)
    op_end = nextind(s, op_start)
    op_char = s[op_start]
    a = String(strip(s[1:prevind(s, op_start)]))
    b = String(strip(s[nextind(s, op_end):end]))
    return op_char == '<' ? "$b - ($a)" : "$a - ($b)"
end

function _last_top_level_comparator(s::AbstractString)
    depth = 0
    last = nothing
    i = firstindex(s)
    last_idx = lastindex(s)
    while i <= last_idx
        c = s[i]
        if c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif depth == 0 &&
               (c == '<' || c == '>') &&
               i < last_idx &&
               s[nextind(s, i)] == '='
            last = i
        end
        i = nextind(s, i)
    end
    return last
end

function _strip_complementarity_ub(s::AbstractString)
    # Strip a trailing bound from the right side of `⟂`. On the
    # variable side it's a redundant restatement of the variable's
    # declared bound (`m_c11 <= 0`, `y >= 0`); on the expression side
    # it's a bound captured by the complementary variable, possibly
    # involving another expression (`design-cent-21`). Drop everything
    # past the last top-level `<=` / `>=`.
    op_start = _last_top_level_comparator(s)
    inner =
        op_start === nothing ? String(s) :
        String(strip(s[1:prevind(s, op_start)]))
    return _strip_outer_parens(inner)
end

function _is_simple_variable_ref(s::AbstractString)
    return match(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\[\]]*\])?$", strip(s)) !==
           nothing
end
