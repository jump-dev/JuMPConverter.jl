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
function _read_expression!(
    lex::Lexer,
    stops::NTuple{N,TokenKind};
    stop_at_complements::Bool = false,
) where {N}
    parts = String[]
    prev_kind = nothing
    while true
        t = peek(lex)
        if t.kind in stops || t.kind == TOKEN_EOF
            break
        end
        # When called from `_read_summation!`, stop at the `complements`
        # keyword so the sum body doesn't swallow the variable side of
        # an enclosing complementarity constraint.
        if stop_at_complements &&
           t.kind == TOKEN_IDENTIFIER &&
           t.value == "complements"
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
    body = strip(_read_expression!(lex, body_stops; stop_at_complements = true))
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
    default_expr = nothing
    integer = false
    # Parse optional qualifiers until semicolon
    while peek(lex).kind != TOKEN_SEMICOLON && peek(lex).kind != TOKEN_EOF
        t = peek(lex)
        if t.kind == TOKEN_IDENTIFIER && t.value == "default"
            read_token!(lex)
            default = parse(Float64, _read_expression!(lex, (TOKEN_SEMICOLON,)))
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
            # AMPL set ranges use `..`; Julia's UnitRange uses `:`.
            cleaned = replace(String(raw), ".." => ":")
            # AMPL set literal `{ 3, 4 }` → Julia Vector `[3, 4]`
            # (Julia's `{}` vector syntax is discontinued).
            cleaned = replace(cleaned, r"\{\s*([^{}]*?)\s*\}" => s"[\1]")
            default = _ampl_set_ops_to_julia(cleaned)
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
# Supported syntax matches what real `.dat`s exercise (taxmcp's scalar
# `fix PL := 1;` and bar-truss-3's `fix{i in m} H[i,'y1','y2'] := 0;`).
# Forms not yet seen — range iter `{i in 1..n}`, numeric/negative
# indices, negative values — would error and can be added when a real
# `.mod`/`.dat` needs them.
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
    value = parse(Float64, expect!(lex, TOKEN_NUMBER).value)
    return JuMPConverter.FixStatement(; variable, indices, value, iter)
end

function _parse_fix_iter!(lex::Lexer)
    var = Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    in_tok = expect!(lex, TOKEN_IDENTIFIER)
    @assert in_tok.value == "in"
    set = Symbol(expect!(lex, TOKEN_IDENTIFIER).value)
    expect!(lex, TOKEN_RBRACE)
    return JuMPConverter.FixIter(; var, set)
end

# Each fix index is either an iter-bound symbol (`i`) or an AMPL
# string literal (`'y1'`).
function _parse_fix_index!(lex::Lexer)
    t = read_token!(lex)
    if t.kind == TOKEN_STRING
        return t.value
    elseif t.kind == TOKEN_IDENTIFIER
        return Symbol(t.value)
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
    # AMPL logical keywords: `and`/`or`/`not` → `&&`/`||`/`!`.
    expr = replace(expr, r"\band\b" => "&&")
    expr = replace(expr, r"\bor\b" => "||")
    expr = replace(expr, r"\bnot\b" => "!")
    expr = _ampl_set_ops_to_julia(expr)
    # AMPL conditional `if COND then THEN else ELSE` → Julia ternary.
    # Two patterns cover the MacMPEC shapes: a fully paren-bounded
    # form with non-paren operands, and an `else (PAREN_EXPR)` form
    # where the else operand carries its own parens (any surrounding
    # context, e.g. a `sum(... for …)`, is left intact).
    expr = replace(
        expr,
        # `[^()]|\([^()]*\)` lets each operand contain one level of
        # balanced parens (`(i, j) in TOLL`), as in tollmpec.
        # The lexer drops whitespace between `if` and a following `(`
        # (tollmpec emits `if(i, j)`), so allow `\s*` there.
        r"\(\s*if\s*((?:[^()]|\([^()]*\))+?)\s+then\s+((?:[^()]|\([^()]*\))+?)\s+else\s+((?:[^()]|\([^()]*\))+?)\s*\)" =>
            s"(\1 ? \2 : \3)",
    )
    expr = replace(
        expr,
        r"\bif\s*(.+?)\s+then\s+(.+?)\s+else\s*(\([^()]*(?:\([^()]*\)[^()]*)*\))" =>
            s"(\1 ? \2 : \3)",
    )
    # `(if X then Y)` with no `else` — AMPL treats the missing branch
    # as 0 (water-net's `+ (if i in reservoirs then s[i])`).
    expr = replace(
        expr,
        r"\(\s*if\s*((?:[^()]|\([^()]*\))+?)\s+then\s+((?:[^()]|\([^()]*\))+?)\s*\)" =>
            s"(\1 ? \2 : 0)",
    )
    # Bare `if X then Y else Z` running to end of expression, no outer
    # parens — used in b-pn2's `param v2 := if y == 1 then 1.0 else
    # 0.0`. Iterate so nested `else if …` chains collapse.
    while occursin(r"(?<![?])\bif\s*.+?\s+then\s.+?\s+else\s", expr)
        new_expr = replace(
            expr,
            r"(?<![?])\bif\s*(.+?)\s+then\s+(.+?)\s+else\s+(.+)$" =>
                s"(\1 ? \2 : (\3))",
        )
        new_expr == expr && break
        expr = new_expr
    end
    # Final pass for bare `if X then Y` with no `else` — water-net's
    # `hl := height[i] + if i in consumers then (...);`. Allow `\s*`
    # after `then` because the lexer can drop the space before a `(`.
    expr = replace(
        expr,
        r"(?<![?])\bif\s*(.+?)\s+then\s*(.+)$" => s"(\1 ? \2 : 0)",
    )
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
