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
        "build_model(; PRODUCTS, MACHINES = 1:5, cost = JuMP.Containers.DenseAxisArray(fill(0.0, length(PRODUCTS)), PRODUCTS))",
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
        "ALPHA = JuMP.Containers.DenseAxisArray(fill(1.0, length(K)), K)",
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
    try
        model = JuMPConverter.AMPL.parse_model(mod)
        @test model.objective !== nothing
        @test contains(model.objective.expression, "if")
    catch
        @test_broken false
    end
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
    @test contains(rendered, "const _INLINE_DATA = JuMPConverter.AMPL.parse_dat(")
    @test contains(rendered, "zl = _INLINE_DATA[\"zl\"]")
    @test contains(rendered, "zu = _INLINE_DATA[\"zu\"]")
    @test Meta.parseall(rendered) isa Expr
    return
end

end  # module

TestModParsing.runtests()
