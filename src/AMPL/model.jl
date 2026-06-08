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
    # Find " in " at depth 0, handling tuple indices like "(i, j) in S"
    depth = 0
    n = length(s)
    for i in 1:n
        c = s[i]
        if c in ('(', '{', '[')
            depth += 1
        elseif c in (')', '}', ']')
            depth -= 1
        elseif c == ' ' && depth == 0 && i + 3 <= n && s[i:(i+3)] == " in "
            name = strip(s[1:(i-1)])
            set = strip(s[(i+4):end])
            return JuMPConverter.Axe(name, isempty(set) ? name : set)
        end
    end
    # No "in" found at depth 0 — bare set or range reference
    return JuMPConverter.Axe(s, s)
end

"""
    _read_expression!(lex::Lexer, stops)

Read tokens until a stop token kind is reached, returning the expression
text. Handles balanced braces/brackets/parens within.
"""
function _read_expression!(lex::Lexer, stops::NTuple{N,TokenKind}) where {N}
    parts = String[]
    prev_kind = nothing
    while true
        t = peek(lex)
        if t.kind in stops || t.kind == TOKEN_EOF
            break
        end
        # AMPL `sum {idx} body` / `prod {idx} body` → Julia generator syntax.
        if t.kind == TOKEN_IDENTIFIER &&
           (t.value == "sum" || t.value == "prod") &&
           peek(lex, 2).kind == TOKEN_LBRACE
            read_token!(lex)  # consume sum/prod
            if !isempty(parts) && _needs_space(prev_kind, t.kind)
                push!(parts, " ")
            end
            push!(parts, _read_summation!(lex, t.value, stops))
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
    body = strip(_read_expression!(lex, body_stops))
    body = _strip_outer_parens(body)
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

# Translate AMPL index syntax to Julia generator syntax: a `:` that
# separates the index from a condition becomes ` if `.
function _ampl_index_to_julia(idx::AbstractString)
    depth = 0
    for (i, c) in enumerate(idx)
        if c in ('(', '[', '{')
            depth += 1
        elseif c in (')', ']', '}')
            depth -= 1
        elseif c == ':' && depth == 0
            return string(strip(idx[1:(i-1)]), " if ", strip(idx[(i+1):end]))
        end
    end
    return String(idx)
end

"""
    _parse_param!(lex::Lexer, model::JuMPConverter.Model)

Parse: `param name [{axes}] [integer] [binary] [default expr] [check...] ;`
"""
function _parse_param!(lex::Lexer, model::JuMPConverter.Model)
    name = expect!(lex, TOKEN_IDENTIFIER).value
    axes = _read_axes!(lex)
    default = nothing
    integer = false
    # Parse optional qualifiers until semicolon
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_IDENTIFIER && t.value == "default"
            read_token!(lex)
            default = parse(Float64, _read_expression!(lex, (TOKEN_SEMICOLON,)))
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
                if nx.kind in (TOKEN_SEMICOLON, TOKEN_COMMA, TOKEN_EOF)
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
            # `param name symbolic in SET;` — skip
            read_token!(lex)
            _read_expression!(lex, (TOKEN_SEMICOLON,))
        elseif t.kind == TOKEN_COMMA
            read_token!(lex)
        else
            # Unknown qualifier — skip token
            read_token!(lex)
        end
    end
    push!(model, JuMPConverter.Parameter(; name, axes, integer, default))
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
            lower_bound = _read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA))
        elseif t.kind == TOKEN_LEQ
            read_token!(lex)
            upper_bound = _read_expression!(lex, (TOKEN_SEMICOLON, TOKEN_COMMA))
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
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_ASSIGN
            read_token!(lex)
            raw = strip(_read_expression!(lex, (TOKEN_SEMICOLON,)))
            # AMPL set ranges use `..`; Julia's UnitRange uses `:`.
            default = replace(String(raw), ".." => ":")
        else
            read_token!(lex)
        end
    end
    push!(model, JuMPConverter.Set(; name, default))
    return
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

# Parse `fix [{ITER}] VAR[idx, …] := VALUE;` into a structured
# `FixStatement`. Used by both `parse_model` (model-section fix in the
# .mod) and `parse_dat` (fix in a data section / .dat file).
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
    if peek(lex).kind != TOKEN_ASSIGN
        # `fix VAR;` without `:= VALUE` would pin to the current value;
        # nothing to pin at build time.
        @warn "skipping `fix` without `:=` (no value to pin)" variable
        # Skip to the terminating semicolon.
        while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
            read_token!(lex)
        end
        return nothing
    end
    read_token!(lex)  # consume `:=`
    value = _parse_fix_number!(lex)
    return JuMPConverter.FixStatement(; variable, indices, value, iter)
end

function _parse_fix_iter!(lex::Lexer)
    var = Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    in_tok = expect!(lex, TOKEN_IDENTIFIER)
    in_tok.value == "in" ||
        error("expected `in` after fix iter variable, got `$(in_tok.value)`")
    t = peek(lex)
    set = if t.kind == TOKEN_NUMBER
        lo = parse(Int, read_token!(lex).value)
        expect!(lex, TOKEN_DOTDOT)
        hi = parse(Int, expect!(lex, TOKEN_NUMBER).value)
        lo:hi
    else
        Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    end
    expect!(lex, TOKEN_RBRACE)
    return JuMPConverter.FixIter(; var, set)
end

function _parse_fix_index!(lex::Lexer)
    t = read_token!(lex)
    if t.kind == TOKEN_NUMBER
        n = tryparse(Int, t.value)
        return n === nothing ? parse(Float64, t.value) : n
    elseif t.kind == TOKEN_STRING
        return t.value
    elseif t.kind == TOKEN_IDENTIFIER
        return Symbol(t.value)
    elseif t.kind == TOKEN_MINUS
        n_tok = expect!(lex, TOKEN_NUMBER)
        return -parse(Float64, n_tok.value)
    end
    return error("unexpected token in fix index: $(t.kind) `$(t.value)`")
end

function _parse_fix_number!(lex::Lexer)
    sign = 1
    if peek(lex).kind == TOKEN_MINUS
        read_token!(lex)
        sign = -1
    end
    return sign * parse(Float64, expect!(lex, TOKEN_NUMBER).value)
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
    # AMPL ranges use `..`; Julia uses `:`.
    expr = replace(expr, ".." => ":")
    # AMPL uses bare `=` for equality constraints; JuMP requires `==`.
    # Don't touch `<=`, `>=`, `:=`, `!=`, or an existing `==`.
    expr = replace(expr, r"(?<![<>:!=])=(?!=)" => "==")
    expr = _convert_complementarity(expr)
    return expr
end

# AMPL writes complementarity as `LB <= LHS \u27c2 RHS >= UB` with explicit
# bounds. JuMP's `@constraint(model, expr \u27c2 var)` takes a single variable
# on the right and infers bounds from its declaration. Strip the redundant
# bounds and put the simple variable side last.
function _convert_complementarity(expr::AbstractString)
    contains(expr, "\u27c2") || return expr
    parts = split(expr, "\u27c2")
    length(parts) == 2 || return expr
    lhs = _strip_complementarity_lb(strip(parts[1]))
    rhs = _strip_complementarity_ub(strip(parts[2]))
    if !_is_simple_variable_ref(lhs) && _is_simple_variable_ref(rhs)
        return "$lhs \u27c2 $rhs"
    elseif _is_simple_variable_ref(lhs) && !_is_simple_variable_ref(rhs)
        return "$rhs \u27c2 $lhs"
    end
    return "$lhs \u27c2 $rhs"
end

function _strip_complementarity_lb(s::AbstractString)
    m = match(r"^0\s*<=\s*(.*)$"s, s)
    return m === nothing ? String(s) : strip(m.captures[1])
end

function _strip_complementarity_ub(s::AbstractString)
    m = match(r"^(.*?)\s*>=\s*0\s*$"s, s)
    inner = m === nothing ? String(s) : strip(m.captures[1])
    return _strip_outer_parens(inner)
end

function _is_simple_variable_ref(s::AbstractString)
    return match(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\[\]]*\])?$", strip(s)) !==
           nothing
end
