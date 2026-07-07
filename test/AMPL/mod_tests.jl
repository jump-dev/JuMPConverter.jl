module TestModParsing

using Test
import JuMPConverter

const MOI = JuMPConverter.MOI

function runtests()
    for name in names(@__MODULE__; all = true)
        if startswith("$(name)", "test_")
            @testset "$(name)" begin
                getfield(@__MODULE__, name)()
            end
        end
    end
    return
end

# ============================================================
# Expression cleaning (works independently of the parser)
# ============================================================

function test_clean_complements()
    expr = JuMPConverter.AMPL.clean_expression("0 <= x complements y >= 0")
    @test contains(expr, "\u27c2")
    @test !contains(expr, "complements")
    return
end

function test_clean_dot_slash()
    expr = JuMPConverter.AMPL.clean_expression("2./beta")
    @test contains(expr, ". /")
    return
end

# ============================================================
# Full model: elec_pricing (the one existing test that works)
# ============================================================

function test_full_elec_pricing()
    path = joinpath(@__DIR__, "input", "elec_pricing.mod")
    model = JuMPConverter.AMPL.read_model(path)
    # Parameters (S, W, H, X, rho, beta, alpha, E, C, R, polyX)
    @test length(model.parameters) == 11
    for name in
        ["S", "W", "H", "X", "rho", "beta", "alpha", "E", "C", "R", "polyX"]
        @test haskey(model.parameters, name)
    end
    @test model.parameters["S"].integer
    @test model.parameters["rho"].default == 0.0
    @test model.parameters["E"].axes !== nothing
    @test length(model.parameters["E"].axes.axes) == 3
    # Variables
    @test length(model.variables) == 4
    for name in ["xx", "y", "mu", "eta"]
        @test haskey(model.variables, name)
    end
    @test model.variables["xx"].lower_bound == "0"
    @test model.variables["xx"].upper_bound == "1"
    # Objective
    @test model.objective !== nothing
    @test model.objective.sense == MOI.MAX_SENSE
    @test model.objective.name == "profit"
    @test contains(model.objective.expression, "sum")
    # Constraints
    @test length(model.constraints) >= 5
    # Check specific constraints
    simplex = model.constraints[1]
    @test simplex.name == "simplex"
    @test simplex.axes !== nothing
    # Check condition on testgeq
    testgeq = model.constraints[2]
    @test testgeq.name == "testgeq"
    @test testgeq.axes.condition !== nothing
    return
end

# ============================================================
# Tests for desired parser behavior (currently broken)
#
# These document what the new parser should handle.
# They use @test_broken or try/catch to avoid erroring.
# ============================================================

# --- Comments ---

function test_comment_line()
    # The current parser should handle # comments (it does strip them)
    mod = """
    # This is a comment
    param S integer;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {i in 1..S}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test haskey(model.parameters, "S")
    return
end

function test_comment_after_statement()
    mod = """
    param n integer; # integer count
    param m integer;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {i in 1..n}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test haskey(model.parameters, "n")
    @test haskey(model.parameters, "m")
    return
end

# --- Whitespace handling ---
# The current parser splits on ';' which is correct.
# But `parse_parameter` can't handle bare `param n;` (no type/default).
# These tests document what the new parser should handle.

function test_scalar_param_bare()
    # `param T;` with no integer/default qualifier
    # Current parser crashes on split(rest, limit=2) when rest is just " T"
    mod = """
    param T;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {i in 1..T}: x >= 0;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test haskey(model.parameters, "T")
    catch
        @test_broken false
    end
    return
end

function test_multiline_param()
    # Newlines within a statement (before semicolon) should be treated as spaces
    mod = """
    param
        n
        integer;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {i in 1..n}: x >= 0;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test haskey(model.parameters, "n")
        @test model.parameters["n"].integer
    catch
        @test_broken false
    end
    return
end

function test_multiline_variable_bounds()
    # Variable bounds split across lines
    mod = """
    param n integer;
    var x {i in 1..n}
        >= 0,
        <= 1;
    maximize obj: sum {i in 1..n} x[i];
    subject to
    c1 {i in 1..n}: x[i] >= 0;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test haskey(model.variables, "x")
        @test model.variables["x"].lower_bound == "0"
        @test model.variables["x"].upper_bound == "1"
    catch
        @test_broken false
    end
    return
end

function test_multiline_objective()
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    minimize cost:
        sum {i in 1..n}
            (x[i]);
    subject to
    c1 {i in 1..n}: x[i] <= 10;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test model.objective !== nothing
        @test model.objective.sense == MOI.MIN_SENSE
    catch
        @test_broken false
    end
    return
end

function test_multiline_constraint()
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    minimize obj: sum {i in 1..n} x[i];
    subject to
    bound {i in 1..n}:
        x[i]
        >= 0;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test length(model.constraints) == 1
        @test model.constraints[1].name == "bound"
    catch
        @test_broken false
    end
    return
end

# --- Multiple params and variables ---

function test_multiple_params()
    mod = """
    param S integer;
    param W integer;
    param H integer;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {i in 1..S}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.parameters) == 3
    for name in ["S", "W", "H"]
        @test haskey(model.parameters, name)
        @test model.parameters[name].integer
    end
    return
end

function test_param_default()
    mod = """
    param S integer;
    param rho {s in 1..S} default 0;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {s in 1..S}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["rho"].default == 0.0
    @test model.parameters["rho"].axes !== nothing
    @test length(model.parameters["rho"].axes.axes) == 1
    return
end

function test_param_multi_indexed()
    mod = """
    param S integer;
    param W integer;
    param H integer;
    param E {s in 1..S, w in 1..W, h in 1..H} default 0;
    var x >= 0;
    maximize obj: x;
    subject to
    c1 {s in 1..S}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test haskey(model.parameters, "E")
    @test length(model.parameters["E"].axes.axes) == 3
    return
end

function test_param_expression_in_range()
    mod = """
    param X integer;
    param H integer;
    param polyX {x in 1..X, k in 1..3+H} default 0;
    var xx >= 0;
    maximize obj: xx;
    subject to
    c1 {x in 1..X}: xx >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    axes = model.parameters["polyX"].axes.axes
    @test length(axes) == 2
    @test axes[2].set == "1..3+H"
    return
end

# --- Variable declarations ---

function test_variable_both_bounds()
    mod = """
    param W integer;
    param H integer;
    var xx {w in 1..W, h in 1..H} >=0, <=1;
    maximize obj: sum {w in 1..W, h in 1..H} xx[w,h];
    subject to
    c1 {w in 1..W}: sum {h in 1..H} xx[w,h] <= 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.variables["xx"].lower_bound == "0"
    @test model.variables["xx"].upper_bound == "1"
    return
end

function test_conditional_expr_translates_to_ternary()
    # monteiro-style: AMPL `(if COND then A else B)` inside an
    # expression needs to render as Julia `(COND ? A : B)`, not
    # `if COND then A else B` (a Julia parse error in expression
    # position).
    mod = """
    set N;
    set D;
    param QD {N};
    var x {N};
    minimize obj: sum {n in N} ((if n in D then QD[n] else 0) - x[n]);
    subject to
    c {n in N}: x[n] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "(n in D ? QD[n] : 0)")
    @test !contains(rendered, "if n in D")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_sum_body_stops_at_complements()
    # taxmcp-style: `LHS >= sum{...} EXPR complements VAR`. The sum
    # body must stop at `complements`, otherwise the variable side
    # gets swallowed into the generator (`sum(... ⟂ PK for i in I)`).
    mod = """
    set I;
    var PK >= 0;
    var Y {I};
    param kbar;
    minimize obj: PK;
    s.t. MARKETK: PK * kbar >= sum {i in I} Y[i] complements PK >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    # The sum's body is just `Y[i]`; `PK` belongs on the variable side
    # of `⟂`, not inside the generator.
    @test contains(expr, "sum(Y[i] for i in I)")
    @test endswith(expr, "⟂ PK")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_ampl_logical_keywords_translated()
    # tollmpec-style: AMPL `and` / `or` / `not` need to render as
    # Julia `&&` / `||` / `!` — `and` left alone fails to parse in a
    # `for j in N if (...) and (...)` generator filter.
    mod = """
    set ARCS within {1..3, 1..3};
    var x {ARCS};
    minimize obj: sum {(i, j) in ARCS if (i, j) in ARCS and i != 1} x[i, j];
    subject to
    c {(i, j) in ARCS}: x[i, j] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.objective.expression
    @test contains(expr, "&&")
    @test !occursin(r"\band\b", expr)
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_conditional_expr_without_else_defaults_to_zero()
    # water-net-style: `(if COND then EXPR)` with no `else` — AMPL
    # treats the missing branch as 0.
    mod = """
    set reservoirs;
    set nodes;
    var s {reservoirs};
    minimize obj: sum {i in nodes} (if i in reservoirs then s[i]);
    subject to
    c {i in nodes}: 1 >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.objective.expression
    @test contains(expr, "(i in reservoirs ? s[i] : 0)")
    @test !occursin(r"\bif\b", expr)
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_conditional_expr_with_tuple_condition()
    # tollmpec-style: `(if (i, j) in TOLL then EXPR else 0.0)` — the
    # condition itself carries a `(i, j)` tuple. Need to allow one
    # level of balanced parens in each ternary operand.
    mod = """
    set ARCS within {1..3, 1..3};
    set TOLL within ARCS;
    param trffcost {ARCS};
    var x {ARCS};
    minimize obj: sum {(i, j) in ARCS} ((if (i, j) in TOLL then 100 * trffcost[i, j] else 0.0) - x[i, j]);
    subject to
    c {(i, j) in ARCS}: x[i, j] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.objective.expression
    @test contains(expr, "((i, j) in TOLL ? 100 * trffcost[i, j] : 0.0)")
    @test !occursin(r"\bif\b", expr)
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_conditional_expr_with_paren_else_operand()
    # monteiro-style: `sum(if l in Sf then 0 else (EXPR) for l in P)`
    # — the if/then/else isn't paren-bounded as a whole, but the else
    # operand carries its own parens. Need to translate to ternary
    # without swallowing the surrounding `for … P)`.
    mod = """
    set Sf;
    set P;
    param a {P};
    var QS {P};
    minimize obj: sum {l in P} (if l in Sf then 0 else (a[l] * QS[l] + a[l] * QS[l]^2));
    subject to
    c {l in P}: QS[l] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.objective.expression
    @test contains(expr, "(l in Sf ? 0 :")
    @test !occursin(r"\bif\b", expr)
    # The `for l in P` must NOT have been swallowed into the ternary.
    @test contains(expr, "for l in P")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_set_within_defaults_to_empty()
    # pack-comp1-style: `set fix_nodes within nodes;` — `fix_nodes`
    # has no `:=`, so it would normally be a required kwarg, but the
    # MacMPEC `.dat`s populate it via `let fix_nodes := { };` (we
    # skip `let`). Default to empty so the call works (and `setdiff`
    # downstream produces the full superset).
    mod = """
    set nodes;
    set fix_nodes within nodes;
    var x {nodes};
    minimize obj: sum {i in nodes} x[i];
    subject to
    c {i in nodes}: x[i] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["fix_nodes"].default == "Int[]"
    rendered = sprint(print, model)
    @test contains(rendered, "fix_nodes = Int[]")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_set_default_brace_literal_to_vector()
    # tap-09-style: `set DEST := { 3 , 4 };` — Julia's `{}` is the
    # discontinued vector syntax; emit `[3, 4]` so the kwarg default
    # parses.
    mod = """
    set DEST := { 3, 4 };
    var x {DEST};
    minimize obj: sum {i in DEST} x[i];
    subject to
    c {i in DEST}: x[i] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["DEST"].default == "[3, 4]"
    rendered = sprint(print, model)
    @test contains(rendered, "DEST = [3, 4]")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_set_default_translates_diff_to_setdiff()
    # incid-set1-style: `set int_nodes = nodes diff bnd_nodes;` should
    # render as `setdiff(nodes, bnd_nodes)` so the generated
    # `build_model` kwarg default is valid Julia.
    mod = """
    set nodes;
    set bnd_nodes;
    set int_nodes = nodes diff bnd_nodes;
    var x {int_nodes} >= 0;
    minimize obj: sum {i in int_nodes} x[i];
    subject to
    c {i in int_nodes}: x[i] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["int_nodes"].default == "setdiff(nodes, bnd_nodes)"
    rendered = sprint(print, model)
    @test contains(rendered, "int_nodes = setdiff(nodes, bnd_nodes)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_integral_default_renders_as_int()
    # portfl-i-style: `param NS := 12;` — Float64 default whose value
    # is integral must render as `12`, not `12.0`, so a downstream
    # `1..NS` becomes `1:12` (`UnitRange{Int}`) rather than a
    # `StepRangeLen{Float64, …}` JuMP can't accept.
    mod = """
    param NS := 12;
    param NR := 62;
    var x;
    minimize obj: x;
    subject to
    c {i in 1..NS}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "NS = 12,")
    @test contains(rendered, "NR = 62)")  # last kwarg
    @test !contains(rendered, "12.0")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_indexed_tuple_assign_becomes_sparse_axis_array()
    # water-net-style: `param dist{(i, j) in arcs} := f(i, j);` — the
    # iter is a tuple over a 2-set; emit as a `SparseAxisArray`
    # keyed by the tuple so the kwarg default is a valid value
    # rather than `i, j` undefined.
    mod = """
    set arcs within {1..3, 1..3};
    param x {1..3};
    param dist {(i, j) in arcs} := x[i] + x[j];
    var z {arcs};
    minimize obj: sum {(i, j) in arcs} dist[i, j] * z[i, j];
    subject to
    c {(i, j) in arcs}: z[i, j] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "dist = JuMP.Containers.SparseAxisArray(Dict((i, j) => x[i] + x[j] for (i, j) in arcs))",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_indexed_assign_becomes_comprehension()
    # water-net-style: `param hl{i in nodes} := height[i] + …;` — the
    # default references the iter `i`. Emit as a `DenseAxisArray`
    # comprehension so the kwarg default actually carries a value
    # rather than `i`-as-an-undefined-name.
    mod = """
    set nodes;
    param height {nodes};
    param hl {i in nodes} := height[i] + 1;
    var x {nodes};
    minimize obj: sum {i in nodes} hl[i] * x[i];
    subject to
    c {i in nodes}: x[i] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["hl"].default_expr == "height[i] + 1"
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "hl = JuMP.Containers.DenseAxisArray([height[i] + 1 for i in nodes], nodes)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_inline_assign_expression_becomes_default_expr()
    # incid-set1-style: `param h := 1/n;` — RHS is an expression, not
    # a literal. Emit the expression as the Julia kwarg default so
    # `h` is computed from `n` at call time rather than becoming a
    # required kwarg the .dat doesn't carry.
    mod = """
    param n integer;
    param h := 1/n;
    param Nnd := (n+1)*(n+1);
    var x {1..Nnd};
    minimize obj: sum {i in 1..Nnd} h * x[i];
    subject to
    c {i in 1..Nnd}: x[i] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["h"].default === nothing
    @test model.parameters["h"].default_expr == "1 / n"
    @test model.parameters["Nnd"].default_expr == "(n + 1) * (n + 1)"
    rendered = sprint(print, model)
    @test contains(rendered, "h = 1 / n")
    @test contains(rendered, "Nnd = (n + 1) * (n + 1)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_default_expression_becomes_default_expr()
    # cont5_1-style: `param m default n;` and ex6_160-style
    # `param pi default 4*atan(1);` — a `default` whose value is an
    # expression rather than a numeric literal must become the Julia
    # kwarg default expression, exactly like `:=`.
    mod = """
    param n default 200;
    param m default n;
    param pi default 4*atan(1);
    var x;
    minimize obj: pi * x;
    subject to
    c {i in 1..m}: x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["n"].default == 200.0
    @test model.parameters["m"].default === nothing
    @test model.parameters["m"].default_expr == "n"
    @test model.parameters["pi"].default_expr == "4 * atan(1)"
    rendered = sprint(print, model)
    @test contains(rendered, "m = n")
    @test contains(rendered, "pi = 4 * atan(1)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_interval_check_skipped()
    # qcqp-style: `param ml integer in [0,n);` and `param sq in (0,1];`
    # — interval membership checks whose half-open delimiters are
    # deliberately unbalanced (`[…)`, `(…]`). Like `> 0` checks they
    # are skipped, and a qualifier after the interval must survive.
    mod = """
    param n integer > 0;
    param ml integer in [0,n);
    param sq in (0,1];
    param pf in (0,1] default .2;
    var x {1..n};
    minimize obj: sum {i in 1..n} x[i];
    subject to
    c {i in 1..ml}: x[i] >= sq;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["ml"].integer
    @test haskey(model.parameters, "sq")
    @test model.parameters["pf"].default == 0.2
    return
end

function test_param_inline_assign_becomes_default()
    # design-cent-1-style: `param pi := 3.14;` and b-pn2-style
    # `param v1{Y} := 1;` initialize the parameter inline; treat the
    # `:= VALUE` as the parameter's default so `build_model` doesn't
    # demand a kwarg for it.
    mod = """
    set Y;
    param pi := 3.141592654;
    param v1 {Y} := 1;
    var x;
    minimize obj: pi * x;
    subject to
    c {y in Y}: v1[y] * x >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["pi"].default == 3.141592654
    @test model.parameters["v1"].default == 1.0
    rendered = sprint(print, model)
    @test contains(rendered, "pi = 3.141592654")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_variable_bound_then_init_value()
    # design-cent-1-style: `var l{k in K} >= 0 := l0[k];`. The `:=` is
    # an initial value, not part of the bound; the parser must stop the
    # `>=` expression at it so `lower_bound` ends up as just `"0"` and
    # the emitted `@variable` doesn't contain `>= 0 := l0[k]`.
    mod = """
    set K;
    param l0 {K};
    var l {k in K} >= 0 := l0[k];
    minimize obj: sum {k in K} l[k];
    subject to
    c {k in K}: l[k] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.variables["l"].lower_bound == "0"
    @test model.variables["l"].upper_bound === nothing
    rendered = sprint(print, model)
    @test !contains(rendered, ":= l0")
    @test contains(rendered, "@variable(model, l[k in K] >= 0)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_variable_both_bounds_no_comma()
    # AMPL accepts the two bounds back-to-back with no comma:
    # `var x{…} >= LB <= UB;`. The parser used to swallow `LB <= UB`
    # whole into `lower_bound`, and the printer then emitted
    # `x[…] >= LB <= UB` — which `@variable` rejects as an unsupported
    # mix of comparison operators.
    mod = """
    set N;
    param u_x {N, N};
    var x {i in N, j in N} >= 0 <= u_x[i,j];
    minimize obj: sum {i in N, j in N} x[i, j];
    subject to
    c {i in N, j in N}: x[i, j] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.variables["x"].lower_bound == "0"
    @test model.variables["x"].upper_bound == "u_x[i, j]"
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "@variable(model, 0 <= x[i in N, j in N] <= u_x[i, j])",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_variable_zero_start_index()
    mod = """
    param S integer;
    param W integer;
    var y {s in 1..S, w in 0..W} >=0, <=1;
    maximize obj: sum {s in 1..S, w in 0..W} y[s,w];
    subject to
    c1 {s in 1..S}: sum {w in 0..W} y[s,w] == 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    axes = model.variables["y"].axes.axes
    @test length(axes) == 2
    @test axes[2].set == "0..W"
    return
end

# --- Objectives ---

function test_maximize_objective()
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    maximize profit: sum {i in 1..n} x[i];
    subject to
    c1 {i in 1..n}: x[i] <= 10;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.objective.sense == MOI.MAX_SENSE
    @test model.objective.name == "profit"
    return
end

function test_minimize_objective()
    # The current parser only supports `maximize`, not `minimize`.
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    minimize cost: sum {i in 1..n} x[i];
    subject to
    c1 {i in 1..n}: x[i] <= 10;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test model.objective.sense == MOI.MIN_SENSE
        @test model.objective.name == "cost"
    catch
        @test_broken false
    end
    return
end

# --- Constraints ---

function test_indexed_constraint()
    mod = """
    param S integer;
    param W integer;
    var y {s in 1..S, w in 0..W} >= 0;
    maximize obj: sum {s in 1..S, w in 0..W} y[s,w];
    subject to
    simplex {s in 1..S}: sum{w in 0..W}(y[s,w]) == 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.constraints) == 1
    c = model.constraints[1]
    @test c.name == "simplex"
    @test c.axes !== nothing
    return
end

function test_constraint_with_condition()
    mod = """
    param X integer;
    param H integer;
    param polyX {x in 1..X, k in 1..3+H} default 0;
    var xx {w in 1..4, h in 1..H} >= 0;
    maximize obj: sum {w in 1..4, h in 1..H} xx[w,h];
    subject to
    testgeq {x in 1..X: polyX[x,2] == 1}: sum{h in 1..H}(polyX[x,3+h]*xx[round(polyX[x,1]),h]) >= polyX[x,3];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    c = model.constraints[1]
    @test c.axes.condition !== nothing
    @test contains(c.axes.condition, "polyX[x, 2] == 1")
    return
end

function test_multiple_constraints()
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    var y {j in 1..n} >= 0;
    maximize obj: sum {i in 1..n} (x[i] + y[i]);
    subject to
    c1 {i in 1..n}: x[i] >= 1;
    c2 {j in 1..n}: y[j] >= 2;
    c3 {k in 1..n}: x[k] + y[k] >= 3;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.constraints) == 3
    return
end

function test_complementarity_constraint()
    mod = """
    param S integer;
    param W integer;
    param H integer;
    param E {s in 1..S, w in 1..W, h in 1..H} default 0;
    var xx {w in 1..W, h in 1..H} >= 0;
    var y {s in 1..S, w in 0..W} >= 0;
    var mu {s in 1..S} >= 0;
    maximize obj: sum {s in 1..S} mu[s];
    subject to
    KKT {s in 1..S, w in 1..W}: 0 <= sum{h in 1..H}(E[s,w,h]*xx[w,h]) + mu[s] complements y[s,w] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.constraints) == 1
    @test contains(model.constraints[1].expression, "\u27c2")
    return
end

# ============================================================
# Tests for features the new parser should support
# (these document desired behavior that isn't tested yet
#  because the current parser structure can't handle them)
# ============================================================

function test_no_subject_to_keyword()
    # In AMPL, `subject to` is optional - any unrecognized declaration
    # is a constraint. The current parser requires `subject to`.
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    minimize cost: sum {i in 1..n} x[i];
    bound {i in 1..n}: x[i] <= 10;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test length(model.constraints) == 1
    catch
        @test_broken false
    end
    return
end

function test_double_inequality()
    # subject to Bounds {j in 1..n}: lb[j] <= x[j] <= ub[j];
    mod = """
    param n integer;
    param lb {i in 1..n} default 0;
    param ub {i in 1..n} default 1;
    var x {i in 1..n};
    minimize cost: sum {i in 1..n} x[i];
    subject to
    bounds {i in 1..n}: lb[i] <= x[i] <= ub[i];
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test length(model.constraints) == 1
    catch
        @test_broken false
    end
    return
end

function test_binary_variable()
    mod = """
    param n integer;
    var x {i in 1..n} binary;
    maximize obj: sum {i in 1..n} x[i];
    subject to
    c1 {i in 1..n}: x[i] <= 1;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test model.variables["x"].binary
    catch
        @test_broken false
    end
    return
end

function test_integer_variable()
    mod = """
    param n integer;
    var x {i in 1..n} integer, >= 0;
    maximize obj: sum {i in 1..n} x[i];
    subject to
    c1 {i in 1..n}: x[i] <= 10;
    """
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test model.variables["x"].integer
    catch
        @test_broken false
    end
    return
end

function test_set_declaration()
    mod = """
    set PRODUCTS;
    set MACHINES := 1..5;
    param cost {PRODUCTS} default 0;
    var Buy {PRODUCTS} >= 0;
    minimize total: sum {p in PRODUCTS} cost[p] * Buy[p];
    subject to
    budget: sum {p in PRODUCTS} cost[p] * Buy[p] <= 100;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test haskey(model.variables, "Buy")
    @test haskey(model.sets, "PRODUCTS")
    @test haskey(model.sets, "MACHINES")
    # Sets must appear in the build_model keyword args so that splatting
    # `read_dat` output works.
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "build_model(; PRODUCTS, MACHINES = 1:5, cost = JuMP.Containers.DenseAxisArray(fill(0, length(PRODUCTS)), PRODUCTS))",
    )
    return
end

function test_set_with_default_is_optional_kwarg()
    # `set N := 1..2;` defines N in the .mod, so it should not be a
    # required keyword argument of `build_model` — and AMPL's `..` must
    # be translated to Julia's `:` so the default is a valid expression.
    mod = """
    set T;
    set N := 1..2;
    var x {t in T, n in N};
    minimize obj: sum {t in T, n in N} x[t,n];
    subject to
    c {t in T}: sum {n in N} x[t,n] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["N"].default == "1:2"
    @test model.sets["T"].default === nothing
    rendered = sprint(print, model)
    @test contains(rendered, "build_model(; T, N = 1:2)")
    return
end

function test_indexed_param_default_is_indexable_container()
    # `param ALPHA{K} default 1.0;` — when ALPHA isn't passed, the
    # default must still be indexable by `k`, otherwise `ALPHA[k]`
    # crashes with a scalar.
    mod = """
    set K;
    param ALPHA {k in K} default 1.0;
    var x {k in K} >= 0;
    minimize obj: sum {k in K} ALPHA[k] * x[k];
    subject to
    c {k in K}: x[k] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "ALPHA = JuMP.Containers.DenseAxisArray(fill(1, length(K)), K)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_param_default_survives_check_constraint()
    # `param x > 0 default 1.5;` — the `> 0` check must not swallow the
    # `default` qualifier.
    mod = """
    param eps > 0 default 1e-6;
    param lo >= 0 default 0.05;
    var y >= 0;
    minimize obj: y;
    subject to
    c1: y >= eps;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["eps"].default == 1e-6
    @test model.parameters["lo"].default == 0.05
    rendered = sprint(print, model)
    @test contains(rendered, "eps = 1.0e-6")
    @test contains(rendered, "lo = 0.05")
    return
end

function test_indexed_constraint_emits_jump_brackets()
    # AMPL `s.t. name {t in T, k in K}: expr;` must render as
    # `@constraint(model, name[t in T, k in K], expr)` so the index
    # variables are bound. Same for indexed variables. Set ranges
    # written with `..` must use Julia's `:` so they parse and run.
    mod = """
    set T;
    set K;
    param REF {t in T, k in K} default 0;
    var x {t in T, k in K} >= 0;
    var y {i in 1..3} >= 0;
    minimize obj: sum {t in T, k in K} x[t,k];
    s.t. c1 {t in T, k in K}: x[t,k] >= REF[t,k];
    s.t. c2 {i in 1..3}: y[i] <= 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "@variable(model, x[t in T, k in K] >= 0)")
    @test contains(rendered, "@variable(model, y[i in 1:3] >= 0)")
    @test contains(rendered, "@constraint(model, c1[t in T, k in K], ")
    @test contains(rendered, "@constraint(model, c2[i in 1:3], ")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_constraint_axes_with_condition()
    mod = """
    set T;
    param a {t in T} default 0;
    var x {t in T} >= 0;
    minimize obj: sum {t in T} x[t];
    s.t. c {t in T : a[t] > 0}: x[t] >= 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "@constraint(model, c[t in T; a[t] > 0],")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_generated_file_has_data_loader()
    # When the model has parameters/sets, `Base.show` emits the kwarg
    # method plus a single `build_model(path::String)` that builds a
    # `DatSchema` and dispatches between `read_dat` and `read_csv`
    # based on `isdir(path)`. The whole file must parse as Julia.
    mod = """
    set K;
    param ALPHA {k in K} default 1.0;
    var x {k in K} >= 0;
    minimize obj: sum {k in K} ALPHA[k] * x[k];
    s.t. c {k in K}: x[k] >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "function build_model(;")
    @test contains(rendered, "function build_model(path::String)")
    @test contains(rendered, "isdir(path)")
    @test contains(rendered, "JuMPConverter.AMPL.DatSchema(")
    @test contains(rendered, "Dict{Symbol,Int}(")
    @test contains(rendered, ":ALPHA => 1")
    @test contains(rendered, "[:K]")
    @test contains(rendered, "JuMPConverter.AMPL.read_dat(path, schema)")
    @test contains(rendered, "JuMPConverter.AMPL.read_csv(path, schema)")
    @test contains(rendered, "build_model(; data...)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_no_data_loader_when_no_params_or_sets()
    # GAMS-derived models (and any AMPL model with no `param`/`set`
    # declarations) must not get the data loader — there's nothing
    # to load.
    mod = """
    var x >= 0;
    minimize obj: x;
    s.t. c: x >= 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "function build_model(")
    @test !contains(rendered, "build_model(path::String)")
    @test !contains(rendered, "DatSchema")
    return
end

function test_st_constraint_prefix()
    # AMPL accepts `s.t.` as shorthand for `subject to`.
    mod = """
    param n integer;
    var x {i in 1..n} >= 0;
    maximize obj: sum {i in 1..n} x[i];
    s.t. c1 {i in 1..n}: x[i] <= 10;
    s.t. c2: sum {i in 1..n} x[i] <= 100;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.constraints) == 2
    @test model.constraints[1].name == "c1"
    @test model.constraints[2].name == "c2"
    return
end

function test_sum_with_parens_body()
    # AMPL `sum{IDX}(BODY)` → Julia `sum(BODY for IDX)`.
    mod = """
    set T;
    var x {t in T};
    maximize obj: sum{t in T}(x[t]);
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.objective.expression == "sum(x[t] for t in T)"
    @test Meta.parseall("(" * model.objective.expression * ")") isa Expr
    return
end

function test_sum_without_parens_body()
    # AMPL `sum{IDX} a*b` binds at multiplicative precedence — body is the
    # multiplication chain, then `-` ends the sum.
    mod = """
    set T;
    param c {t in T} default 1;
    var x {t in T};
    var y;
    maximize obj: sum{t in T} c[t] * x[t] - y;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.objective.expression == "sum(c[t] * x[t] for t in T) - y"
    @test Meta.parseall("(" * model.objective.expression * ")") isa Expr
    return
end

function test_sum_multi_index()
    mod = """
    set T;
    set K;
    var x {t in T, k in K};
    maximize obj: sum{t in T, k in K} x[t,k];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.objective.expression == "sum(x[t, k] for t in T, k in K)"
    @test Meta.parseall("(" * model.objective.expression * ")") isa Expr
    return
end

function test_complementarity_strips_bounds_and_orders_var_last()
    # AMPL `0 <= VAR ⟂ EXPR >= 0` becomes JuMP `EXPR ⟂ VAR`: bounds are
    # implicit from the variable's declaration and the variable comes
    # second (JuMP requires a single VariableRef on the right of ⟂).
    mod = """
    set T;
    set K;
    param FLEX {k in K} default 0.1;
    param REF {t in T, k in K} default 0;
    var x {t in T, k in K};
    var mu {t in T, k in K} >= 0;
    minimize obj: 0;
    s.t. comp {t in T, k in K}: 0 <= mu[t,k] complements (x[t,k] - (1 - FLEX[k]) * REF[t,k]) >= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "0 <=")
    @test !contains(expr, ">= 0")
    # variable side comes last
    @test endswith(expr, "⟂ mu[t, k]")
    # parses as Julia
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_equality_kkt_renders_as_eq_constraint()
    # bard2m-style KKT stationarity: `0 = LHS complements VAR`. The
    # left side is already an equality, so the resulting JuMP
    # constraint is just `LHS == 0` — emitting `0 == LHS ⟂ VAR` (the
    # naive split) would be a JuMP-rejected mix of comparison
    # operators.
    mod = """
    var y11 >= 0, <= 20;
    var m_c11 <= 0;
    var m_c12 <= 0;
    minimize obj: 0;
    s.t. d_y11: 0 = 2*(y11-4) - m_c11*0.4 - m_c12*0.6 complements y11;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "⟂")
    @test endswith(expr, "== 0")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_strips_two_sided_bounds_on_expr_side()
    # bilevel1m-style: `LB <= EXPR <= UB complements VAR`. Both LHS
    # bounds must be stripped so the emitted constraint is `EXPR ⟂ VAR`
    # — keeping either bound produces a `mix of comparison operators`
    # that JuMP can't parse.
    mod = """
    param n integer;
    var y {1..n};
    var l {1..n} >= 0;
    minimize obj: 0;
    s.t. m1: -10 <= y[1] <= 20 complements l[1];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "<= 20")
    @test !contains(expr, "-10 <=")
    @test endswith(expr, "y[1] ⟂ l[1]")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_strips_nonzero_upper_bound_on_expr_side()
    # design-cent-2-style: `0 <= VAR complements EXPR <= 1` — the
    # variable side gets the variable, the expression side has a
    # non-zero upper bound. JuMP needs `EXPR ⟂ VAR`, so the `<= 1`
    # must be stripped.
    mod = """
    set K;
    param u;
    var x;
    var l {k in K} >= 0;
    minimize obj: 0;
    s.t. compl {k in K}: 0 <= l[k] complements x^2 <= 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "<= 1")
    @test endswith(expr, "⟂ l[k]")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_strips_expr_upper_bound_on_expr_side()
    # design-cent-21-style: `0 <= VAR complements EXPR <= EXPR2` —
    # the UB on the expression side isn't a number but another
    # expression. Strip whatever follows the last top-level `<=`.
    mod = """
    set K;
    var x {1..4};
    var y {1..2, K};
    var l {k in K} >= 0;
    minimize obj: 0;
    s.t. compl {k in K}: 0 <= l[k] complements (y[1,k] - x[1])^2 <= x[3]^2 * x[4]^2;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "<= x[3]")
    @test endswith(expr, "⟂ l[k]")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_strips_ge_lower_bound_on_expr_side()
    # dempe-style: `0 >= EXPR complements VAR` (some `.mod`s write the
    # bound with the larger side on the left). The `0 >=` is just the
    # mirror image of `EXPR <= 0`; strip it the same way.
    mod = """
    var x;
    var z;
    var w >= 0;
    minimize obj: 0;
    s.t. con2: 0 >= z^2 - x complements w;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "0 >=")
    @test endswith(expr, "⟂ w")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_complementarity_strips_le_zero_bound_on_var_side()
    # bard2m-style: variables with an upper bound of 0 appear as
    # `EXPR ⟂ VAR <= 0`. JuMP infers the bound from `var VAR <= 0;` so
    # the trailing `<= 0` must be stripped just like `>= 0` is for the
    # positive-bound case.
    mod = """
    var x11 >= 0;
    var y11 >= 0;
    var m_c11 <= 0;
    minimize obj: 0;
    s.t. c11: 0 <= -(0.4*y11 - x11) complements m_c11 <= 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test !contains(expr, "<= 0")
    @test endswith(expr, "⟂ m_c11")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_utf8_in_comment()
    # Multi-byte UTF-8 characters in comments must not crash the lexer.
    mod = """
    param price >= 0;  # Cost in € per unit
    var x >= 0;
    maximize obj: price * x;  # objective in €
    subject to
    c1: x <= 10;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test haskey(model.parameters, "price")
    @test length(model.constraints) == 1
    return
end

function test_conditional_expression_if_then_else()
    mod = """
    param n integer;
    param flag {i in 1..n} default 0;
    var x {i in 1..n} >= 0;
    minimize cost: sum {i in 1..n} (if flag[i] == 1 then x[i] else 0);
    subject to
    c1 {i in 1..n}: x[i] <= 10;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.objective !== nothing
    # AMPL `(if … then … else …)` → Julia ternary; the rendered
    # expression must not still contain `if` (which would be a
    # statement-form Julia parse error in this position).
    @test contains(model.objective.expression, "?")
    @test !occursin(r"\bif\b", model.objective.expression)
    return
end

# --- Inline data sections ---
# Some AMPL `.mod` files embed parameter / set values inline via
# `data; ...` rather than keeping them in a separate `.dat`. The parser
# must capture that text and the generated kwargs must use the inline
# values as defaults — otherwise the params show up as required kwargs
# even though their values are literally in the source file.

function test_inline_data_param_table()
    # `param: <names> := <values>` after `data;` — the tabular form.
    mod = """
    set I := 1..3;
    param zl{I};
    param zu{I};
    var z{i in I} >= zl[i], <= zu[i];
    minimize f: z[1];
    subject to
    c: z[1] >= 0;
    data;
    param: 		zl,	zu :=
    \t1\t10\t1E10
    \t2\t0.01\t10
    \t3\t0\t1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    # The model side parsed normally.
    @test haskey(model.parameters, "zl")
    @test haskey(model.parameters, "zu")
    @test haskey(model.variables, "z")
    @test length(model.constraints) == 1
    # The data section was captured and the names recorded.
    @test model.inline_data_text !== nothing
    @test "zl" in model.inline_data_names
    @test "zu" in model.inline_data_names
    # The rendered .jl wires the inline data into the kwarg defaults so
    # `build_model()` works with no arguments.
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "const _INLINE_DATA = JuMPConverter.AMPL.parse_dat(",
    )
    @test contains(rendered, "zl = _INLINE_DATA[\"zl\"]")
    @test contains(rendered, "zu = _INLINE_DATA[\"zu\"]")
    @test Meta.parseall(rendered) isa Expr
    return
end

# --- AMPL `fix VAR := VAL;` ---

function test_model_level_fix_scalar()
    # Scalar fix on a model variable (taxmcp-style).
    mod = """
    var PL >= 0;
    minimize obj: PL;
    fix PL := 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.fixes) == 1
    fx = model.fixes[1]
    @test fx.iter === nothing
    @test fx.variable === :PL
    @test isempty(fx.indices)
    @test fx.value == 1.0
    rendered = sprint(print, model)
    @test contains(rendered, "JuMP.fix(model[:PL], 1.0; force = true)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_model_level_fix_indexed_with_iter_and_string()
    # Indexed fix with iteration and string-literal indices (bar-truss
    # style, lifted into the model section so parse_model sees it).
    # Verifies that the lexer now distinguishes `'y1'` from a bare
    # identifier so it round-trips as a Julia string.
    mod = """
    set m;
    set y;
    var H{m, y, y};
    minimize obj: sum {i in m} H[i, 'y1', 'y1'];
    fix{i in m} H[i, 'y1', 'y2'] := 0.0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.fixes) == 1
    fx = model.fixes[1]
    @test fx.iter !== nothing
    @test fx.iter.var === :i
    @test fx.iter.set === :m
    @test fx.variable === :H
    @test fx.indices == Any[:i, "y1", "y2"]
    @test fx.value == 0.0
    rendered = sprint(print, model)
    @test contains(rendered, "for i in m")
    @test contains(
        rendered,
        "JuMP.fix(model[:H][i, \"y1\", \"y2\"], 0.0; force = true)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_model_level_fix_numeric_index()
    # clnlbeam-style: `fix x[0] := 0.0;` — numeric indices must parse
    # and emit as integer literals.
    mod = """
    param ni integer;
    var x {0..ni};
    minimize obj: x[0];
    fix x[0] := 0.0;
    fix x[ni] := 0.0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.fixes) == 2
    @test model.fixes[1].indices == Any[0]
    @test model.fixes[1].value == 0.0
    # `ni` is a param reference, resolved from `build_model`'s kwargs.
    @test model.fixes[2].indices == Any[:ni]
    rendered = sprint(print, model)
    @test contains(rendered, "JuMP.fix(model[:x][0], 0.0; force = true)")
    @test contains(rendered, "JuMP.fix(model[:x][ni], 0.0; force = true)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_model_level_fix_expression_value()
    # optmass-style: `fix v[1,0] := speed;` — the fix value is a param
    # reference, not a literal; it must emit verbatim so it resolves
    # against `build_model`'s kwargs.
    mod = """
    param speed;
    var v {1..2, 0..3};
    minimize obj: v[1, 0];
    fix v[1,0] := speed;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.fixes) == 1
    @test model.fixes[1].indices == Any[1, 0]
    @test model.fixes[1].value == "speed"
    rendered = sprint(print, model)
    @test contains(rendered, "JuMP.fix(model[:v][1, 0], speed; force = true)")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_model_level_fix_range_iter()
    # dtoc2-style: `fix{i in 1..ny} y[1,i] := i/(2*ny);` — the iter set
    # is an inline range (not a set name) and the fix value is an
    # expression referencing the iter variable.
    mod = """
    param ny integer;
    var y {1..3, 1..ny};
    minimize obj: y[1, 1];
    fix{i in 1..ny} y[1,i] := i/(2*ny);
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test length(model.fixes) == 1
    fx = model.fixes[1]
    @test fx.iter.var === :i
    @test fx.iter.set == "1:ny"
    @test fx.indices == Any[1, :i]
    @test fx.value == "i / (2 * ny)"
    rendered = sprint(print, model)
    @test contains(rendered, "for i in 1:ny")
    @test contains(
        rendered,
        "JuMP.fix(model[:y][1, i], i / (2 * ny); force = true)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

# ============================================================
# Emitter conversions exercised by the Plato AMPL-NLP collection
# ============================================================

function test_infix_div_mod_power()
    # dtoc1nd's `k div nx`, svanberg's `i mod 2`, arki0009's `x ** y`
    # have no infix spelling in Julia.
    expr = JuMPConverter.AMPL.clean_expression("(k div nx) + (i mod 2) ** 3")
    @test expr == "(k ÷ nx) + (i % 2) ^ 3"
    @test Meta.parseall(expr) isa Expr
    return
end

function test_not_equal_spelled_with_angle_brackets()
    expr = JuMPConverter.AMPL.clean_expression("i mod n <> 0")
    @test expr == "i % n != 0"
    return
end

function test_stepped_range_by()
    # svanberg's `sum{i in 1..n-1 by 2}` — AMPL `A..B by S` is Julia's
    # `A:S:B`.
    mod = """
    param n integer;
    var x {1..n};
    minimize obj: sum {i in 1..n-1 by 2} x[i];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test contains(model.objective.expression, "for i in 1:2:n - 1")
    @test Meta.parseall("(" * model.objective.expression * ")") isa Expr
    return
end

function test_number_literal_normalization()
    # cont_p's `.5`, lukvle9's Fortran-style `1.d-4`, and trailing-dot
    # `2.` are not valid Julia literals.
    mod = """
    param a := .5;
    param b := 1.d-4;
    param c := 2.;
    var x;
    minimize obj: a * x + b * x + c * x;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["a"].default == 0.5
    @test model.parameters["b"].default == 1.0e-4
    @test model.parameters["c"].default == 2.0
    return
end

function test_number_d_exponent_only_before_digit_or_sign()
    # `2*d` must still lex `d` as an identifier, not an exponent.
    mod = """
    param d;
    var x;
    minimize obj: 2*d + x;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test contains(model.objective.expression, "2 * d")
    return
end

function test_julia_keyword_declaration_names_escaped()
    # dirichlet-style `s.t. end {n in N}: …` / lukvle5's `s.t. begin:` —
    # Julia reserved words as names must render with `var"…"`.
    mod = """
    set N;
    var u {N} >= 0;
    minimize obj: sum {n in N} u[n];
    s.t. begin: sum {n in N} u[n] >= 1;
    s.t. end {n in N}: u[n] <= 2;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "@constraint(model, var\"begin\", ")
    @test contains(rendered, "@constraint(model, var\"end\"[n in N], ")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_min_max_reducers_become_minimum_maximum()
    # qcqp's `max{k in 1..n} abs(A0[i,k])`.
    mod = """
    param n integer;
    param A {1..n};
    var x;
    minimize obj: x + max {k in 1..n} abs(A[k]) - min {k in 1..n} A[k];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.objective.expression
    @test contains(expr, "maximum(abs(A[k]) for k in 1:n)")
    @test contains(expr, "minimum(A[k] for k in 1:n)")
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_conditional_chain_without_final_else()
    # qcqp's `param z{…} := if C1 then A else if C2 then B;` — chained
    # `else if` whose last branch has no `else` (missing → 0). The old
    # regex conversion emitted `(C2 ? B)) : 0` here.
    expr = JuMPConverter.AMPL.clean_expression(
        "if i <= pl && u < plf then Uniform(0, 10) else if i > pl && u < pqf then Uniform(0, 10)",
    )
    # `Uniform(a, b)` is an AMPL RNG builtin inlined as Julia `rand`.
    U = "(0 + (10 - 0) * rand())"
    @test expr == "(i <= pl && u < plf ? $U : (i > pl && u < pqf ? $U : 0))"
    @test Meta.parseall(expr) isa Expr
    return
end

function test_random_builtins_inlined()
    # AMPL's RNG builtins render to Base `rand`/`randn` inline, so the
    # generated file needs no runtime helper (qcqp's `Uniform01()`,
    # `Uniform(-10, 10)`, `Normal01()`).
    c = JuMPConverter.AMPL.clean_expression
    @test c("Uniform01()") == "rand()"
    @test c("Normal01()") == "randn()"
    @test c("Uniform(-10, 10)") == "(-10 + (10 - -10) * rand())"
    @test c("Normal(mu, sd)") == "(mu + sd * randn())"
    @test Meta.parseall(c("Uniform(-10, 10)")) isa Expr
    @test Meta.parseall(c("Normal(mu, sd)")) isa Expr
    return
end

function test_conditional_with_sums_in_branches()
    # NARX_CFy-style: `x[i,j] = if j==1 then sum{u in 1..Nu}(…) else
    # sum{u in 1..Nu}(…);` — the sum body must stop at `else`, and the
    # conditional must convert with the generators intact.
    mod = """
    param Nu integer;
    param a1 {1..Nu};
    param a2 {1..Nu};
    var x {1..2};
    minimize obj: x[1];
    s.t. c {j in 1..2}: x[j] = if j == 1 then sum{u in 1..Nu}(a1[u]) else sum{u in 1..Nu}(a2[u]);
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    expr = model.constraints[1].expression
    @test contains(
        expr,
        "(j == 1 ? sum(a1[u] for u in 1:Nu) : sum(a2[u] for u in 1:Nu))",
    )
    @test Meta.parseall("(" * expr * ")") isa Expr
    return
end

function test_conditional_else_without_space_before_paren()
    # svanberg-style: the lexer drops the space in `else (5 - i)`,
    # emitting `else(5 - i)`; conversion must still find the `else`.
    expr = JuMPConverter.AMPL.clean_expression(
        "if((i mod 2) == 1) then (i * 2 / n + 1) else(5 - i * 3 / n)",
    )
    @test expr == "(((i % 2) == 1) ? (i * 2 / n + 1) : (5 - i * 3 / n))"
    @test Meta.parseall(expr) isa Expr
    return
end

function test_generator_filter_if_left_untouched()
    # A Julia generator filter emitted by the sum conversion has no
    # `then` and must not be mistaken for an AMPL conditional.
    expr =
        JuMPConverter.AMPL.clean_expression("sum(x[t] for t in T if a[t] > 0)")
    @test expr == "sum(x[t] for t in T if a[t] > 0)"
    return
end

function test_set_default_with_iterators_becomes_comprehension()
    # ex1_160-style: `set P := {i in 1..n2, j in 1..n2: COND};` — the
    # brace form with iterators and a condition must render as a
    # comprehension with the condition cleaned (`=` → `==`, `mod` → `%`,
    # `<>` → `!=`), not as a mangled vector literal.
    mod = """
    param n integer;
    param n2 := n^2;
    set P := {i in 1..n2, j in 1..n2: i == j || j = i+n || i = j-1 && i mod n <> 0};
    var x {P};
    minimize obj: sum {(i, j) in P} x[i, j];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["P"].default ==
          "[(i, j) for i in 1:n2, j in 1:n2 if i == j||j == i+n||i == j-1&&i % n != 0]"
    @test Meta.parseall(model.sets["P"].default) isa Expr
    return
end

function test_set_default_single_iterator_comprehension()
    # Weyl_m0-style with `not(… and …)` in the condition.
    mod = """
    set S;
    set W := {i in S: not(i == 0)};
    var x {W};
    minimize obj: sum {i in W} x[i];
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.sets["W"].default == "[i for i in S if !(i == 0)]"
    @test Meta.parseall(model.sets["W"].default) isa Expr
    return
end

function test_boolify_condition()
    # AMPL treats a bare arithmetic filter as true when nonzero
    # (dirichlet's `{n in N : BNDRY[n]}` with `BNDRY` a 0/1 param); a
    # condition already carrying a relational/logical/membership operator
    # is left alone.
    b = JuMPConverter.AMPL._boolify_condition
    @test b("BNDRY[n]") == "(BNDRY[n]) != 0"
    @test b("a[i] > 0") == "a[i] > 0"
    @test b("i == j") == "i == j"
    @test b("i <= n && j >= 1") == "i <= n && j >= 1"
    @test b("(i, j) in ARCS") == "(i, j) in ARCS"
    @test b("") == ""
    return
end

function test_constraint_filter_on_param_boolified()
    # A constraint indexed with a bare-param filter must render the JuMP
    # `[…; cond]` filter as a `Bool` so `@constraint` accepts it.
    mod = """
    set N;
    param BNDRY {N} default 0;
    var x {N};
    minimize obj: sum {n in N} x[n];
    s.t. c {n in N : BNDRY[n]}: x[n] == 0;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    rendered = sprint(print, model)
    @test contains(rendered, "@constraint(model, c[n in N; (BNDRY[n]) != 0],")
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_data_indexed_let_constant_default()
    # dirichlet-style `let {n in N} b[n] := 1;` in the data section sets a
    # constant at every node — captured as a scalar param default the
    # emitter fills over the axes.
    mod = """
    set N;
    param b {N} >= 0;
    var x {N};
    minimize obj: sum {n in N} b[n] * x[n];
    s.t. c {n in N}: x[n] >= 0;
    data;
    let {n in N} b[n] := 1;
    """
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["b"].default == 1.0
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "b = JuMP.Containers.DenseAxisArray(fill(1, length(N)), N)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

function test_data_indexed_let_expression_becomes_comprehension()
    # henon-style `let {n in N} c[n] := sqrt(COORDS[n,1]^2+COORDS[n,2]^2);`
    # references the index, so it becomes a comprehension default over
    # `n in N`, with the anonymous `{N}` axis rebound to `n`.
    mod = """
    set N;
    param COORDS {N, 1..2};
    param c {N} >= 0;
    var x {N};
    minimize obj: sum {n in N} c[n] * x[n];
    s.t. cc {n in N}: x[n] >= 0;
    data;
    let {n in N} c[n] := sqrt(COORDS[n,1]^2 + COORDS[n,2]^2);
    """
    # The RHS is captured from the raw `data;` text, so it keeps the
    # source spacing (`COORDS[n,1]^2`) rather than lexer spacing — still
    # valid Julia.
    model = JuMPConverter.AMPL.parse_model(mod)
    @test model.parameters["c"].default_expr ==
          "sqrt(COORDS[n,1]^2 + COORDS[n,2]^2)"
    rendered = sprint(print, model)
    @test contains(
        rendered,
        "c = JuMP.Containers.DenseAxisArray([sqrt(COORDS[n,1]^2 + COORDS[n,2]^2) for n in N], N)",
    )
    @test Meta.parseall(rendered) isa Expr
    return
end

end  # module

TestModParsing.runtests()
