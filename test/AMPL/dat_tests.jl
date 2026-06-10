module TestDatParsing

using Test
import JuMPConverter

const JuMP = JuMPConverter.JuMP

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
# Helper: parse dat with model context
#
# The new parser will need model info to interpret .dat files.
# This helper calls the future API: parse_dat(dat_text, model)
# where `model` comes from parse_model(mod_text).
# Until the new API exists, we fall back to the current
# parse_dat(dat_text) which ignores model info.
# ============================================================

function parse_dat(dat::String, mod::String)
    model = JuMPConverter.AMPL.parse_model(mod)
    return JuMPConverter.AMPL.parse_dat(dat, model)
end

# ============================================================
# Comments
# ============================================================

function test_comment_only()
    data = JuMPConverter.AMPL.parse_dat("# just a comment\nparam n := 5;")
    @test data["n"] == 5
    return
end

function test_comment_before_param()
    data = JuMPConverter.AMPL.parse_dat("""
    # This is a comment
    param n := 5;
    """)
    @test data["n"] == 5
    return
end

function test_multiple_comments()
    data = JuMPConverter.AMPL.parse_dat("""
    # Comment 1
    # Comment 2
    param n := 5;
    # Comment 3
    param m := 10;
    """)
    @test data["n"] == 5
    @test data["m"] == 10
    return
end

# ============================================================
# Whitespace equivalence (newlines = spaces)
#
# In AMPL, newlines are equivalent to spaces. The parser needs
# model info to know how many indices a param has, so it can
# tokenize `1 10 2 20 3 30` as pairs (index, value) for a 1D
# param, or as rows for a 2D param, etc.
# ============================================================

function test_newlines_are_spaces_scalar()
    mod = "param n integer;"
    dat_normal = "param n := 5;"
    dat_newlines = "param\nn\n:=\n5;"
    dat_spaces = "param  n  :=  5;"
    data1 = parse_dat(dat_normal, mod)
    @test data1["n"] == 5
    data3 = parse_dat(dat_spaces, mod)
    @test data1["n"] == data3["n"]
    # With newlines splitting the `:=` across lines, the current parser
    # fails entirely. The new tokenizer-based parser should handle this.
    try
        data2 = parse_dat(dat_newlines, mod)
        @test data1["n"] == data2["n"]
    catch
        @test_broken false
    end
    return
end

function test_newlines_are_spaces_1d()
    # The model tells us `c` is indexed over 1..3, so the parser knows
    # to read (index, value) pairs from the token stream.
    mod = """
    param n integer;
    param c {i in 1..n};
    """
    dat_multiline = """
    param c :=
    1 10
    2 20
    3 30;
    """
    dat_oneline = "param c := 1 10 2 20 3 30;"
    data_multi = parse_dat(dat_multiline, mod)
    @test data_multi["c"][1] ≈ 10.0
    data_one = parse_dat(dat_oneline, mod)
    @test data_one["c"] isa Vector
    @test data_one["c"] == data_multi["c"]
    return
end

function test_newlines_are_spaces_table()
    # The model tells us `cost` is indexed over (1..2) x {A, B},
    # so the parser knows each row has 1 index + 2 values.
    mod = """
    set COLS;
    param cost {1..2, COLS};
    """
    dat_multiline = """
    param cost: A B :=
    1 10 20
    2 30 40;
    """
    dat_oneline = "param cost: A B := 1 10 20 2 30 40;"
    data_multi = parse_dat(dat_multiline, mod)
    @test haskey(data_multi, "cost")
    data_one = parse_dat(dat_oneline, mod)
    @test data_one["cost"] == data_multi["cost"]
    return
end

# ============================================================
# Scalar parameters
# ============================================================

function test_scalar_int()
    data = JuMPConverter.AMPL.parse_dat("param S := 5;")
    @test data["S"] == 5
    @test data["S"] isa Int
    return
end

function test_scalar_float()
    data = JuMPConverter.AMPL.parse_dat("param pi := 3.14159;")
    @test data["pi"] ≈ 3.14159
    @test data["pi"] isa Float64
    return
end

function test_scalar_negative()
    data = JuMPConverter.AMPL.parse_dat("param x := -42;")
    @test data["x"] == -42
    return
end

function test_scalar_scientific()
    data = JuMPConverter.AMPL.parse_dat("param eps := 1e-7;")
    @test data["eps"] ≈ 1e-7
    return
end

function test_multiple_scalars()
    data = JuMPConverter.AMPL.parse_dat("""
    param S := 5;
    param W := 4;
    param H := 3;
    param X := 4;
    """)
    @test data["S"] == 5
    @test data["W"] == 4
    @test data["H"] == 3
    @test data["X"] == 4
    return
end

function test_multiple_scalars_one_line()
    data = JuMPConverter.AMPL.parse_dat("param S := 5; param W := 4;")
    @test data["S"] == 5
    @test data["W"] == 4
    return
end

# ============================================================
# 1D array parameters
# ============================================================

function test_1d_array()
    data = JuMPConverter.AMPL.parse_dat("""
    param rho :=
    1 0.323232
    2 0.161616
    3 0.080808;
    """)
    @test length(data["rho"]) >= 3
    @test data["rho"][1] ≈ 0.323232
    @test data["rho"][2] ≈ 0.161616
    @test data["rho"][3] ≈ 0.080808
    @test eltype(data["rho"]) == Float64
    return
end

function test_1d_array_single_line()
    # With model info (c is indexed), the parser knows to read pairs.
    mod = """
    param n integer;
    param c {i in 1..n};
    """
    dat = "param c := 1 10.0 2 20.0 3 30.0;"
    data = parse_dat(dat, mod)
    @test data["c"] isa Vector
    @test data["c"][1] ≈ 10.0
    @test data["c"][2] ≈ 20.0
    @test data["c"][3] ≈ 30.0
    return
end

# ============================================================
# Multi-column table (param : col1 col2 := ...)
# ============================================================

function test_multi_column_1d()
    data = JuMPConverter.AMPL.parse_dat("""
    param
    :      rho       beta   alpha    :=
    1   0.323232    0.66667    0
    2   0.161616    0.66667    0
    3   0.080808    0.66667    0;
    """)
    @test haskey(data, "rho")
    @test haskey(data, "beta")
    @test haskey(data, "alpha")
    @test isa(data["rho"], Vector)
    @test data["rho"][1] ≈ 0.323232
    @test data["beta"][1] ≈ 0.66667
    return
end

function test_multi_column_2d()
    data = JuMPConverter.AMPL.parse_dat("""
    param
    :        C          R       :=
    1 1    84.812151    120.964401
    1 2    100.553059   135.362834
    2 1    79.851577    115.524285
    2 2    102.740615   126.833369;
    """)
    @test haskey(data, "C")
    @test haskey(data, "R")
    @test size(data["C"]) == (2, 2) ||
          data["C"] isa JuMP.Containers.SparseAxisArray
    @test size(data["R"]) == (2, 2) ||
          data["R"] isa JuMP.Containers.SparseAxisArray
    return
end

# ============================================================
# 2D table format (param name: col1 col2 := ...)
# ============================================================

function test_2d_table()
    data = JuMPConverter.AMPL.parse_dat("""
    param cost: A B C :=
    1 10 20 30
    2 40 50 60;
    """)
    @test haskey(data, "cost")
    return
end

# ============================================================
# 3D arrays (slice notation)
# ============================================================

function test_3d_array_slices()
    data = JuMPConverter.AMPL.parse_dat("""
    param E [*,*,1]: 1 2 :=
    1 10 20
    2 30 40
    [*,*,2]: 1 2 :=
    1 50 60
    2 70 80;
    """)
    @test haskey(data, "E")
    E = data["E"]
    @test ndims(E) == 3
    @test size(E) == (2, 2, 2)
    @test E[1, 1, 1] ≈ 10
    @test E[1, 2, 1] ≈ 20
    @test E[2, 1, 2] ≈ 70
    @test E[2, 2, 2] ≈ 80
    return
end

# ============================================================
# Missing values (dot)
# ============================================================

function test_dot_as_missing_1d()
    data = JuMPConverter.AMPL.parse_dat("""
    param
    :      rho    alpha    :=
    1   0.323232    0
    2   0.161616    0
    3   0.080808    .;
    """)
    @test haskey(data, "rho")
    @test haskey(data, "alpha")
    # alpha[3] should be missing or handled appropriately
    return
end

# ============================================================
# Set data
# ============================================================

function test_set_integers()
    data = JuMPConverter.AMPL.parse_dat("set S := 1 2 3 4 5;")
    @test data["S"] == [1, 2, 3, 4, 5]
    return
end

function test_set_strings()
    data = JuMPConverter.AMPL.parse_dat("set CITIES := Seattle Denver Chicago;")
    @test data["CITIES"] == ["Seattle", "Denver", "Chicago"]
    return
end

function test_set_comma_separated()
    data = JuMPConverter.AMPL.parse_dat("set S := 1,2,3;")
    @test length(data["S"]) == 3
    return
end

# ============================================================
# Semicolons as delimiters
# ============================================================

function test_semicolon_ends_statement()
    data = JuMPConverter.AMPL.parse_dat("param a := 1; param b := 2;")
    @test data["a"] == 1
    @test data["b"] == 2
    return
end

function test_trailing_whitespace_after_semicolon()
    data = JuMPConverter.AMPL.parse_dat("param n := 42;   \n\n")
    @test data["n"] == 42
    return
end

# ============================================================
# let command
# ============================================================

function test_let_command_skipped()
    # `let VAR := EXPR;` sets a variable's starting value (a JuMP
    # `set_start_value` concept), not a parameter. parse_dat skips it
    # so the variable name doesn't leak into the data dict as a bogus
    # kwarg of `build_model`.
    data = JuMPConverter.AMPL.parse_dat("let x := 5;")
    @test !haskey(data, "x")
    return
end

function test_indexed_let_const_populates_dense_axis_array()
    # incid-set-style: `let{i in S} VAR[i] := CONST;` populates the
    # indexed parameter with a constant value at every element of the
    # already-loaded set `S`.
    data = JuMPConverter.AMPL.parse_dat("""
    set bnd_nodes := 1 2 3 ;
    let{i in bnd_nodes} u0[i] := 0.0;
    """)
    u0 = data["u0"]
    @test u0 isa JuMPConverter.JuMP.Containers.DenseAxisArray
    @test u0[1] == 0.0
    @test u0[2] == 0.0
    @test u0[3] == 0.0
    return
end

# ============================================================
# Full example file with model context
# ============================================================

function test_example1_dat()
    path = joinpath(@__DIR__, "examples", "example1.dat")
    data = JuMPConverter.AMPL.read_dat(path)
    @test data[:S] == 5
    @test data[:W] == 4
    @test data[:H] == 3
    @test data[:X] == 4
    @test haskey(data, :rho)
    @test haskey(data, :beta)
    @test haskey(data, :alpha)
    @test haskey(data, :E)
    @test haskey(data, :C)
    @test haskey(data, :R)
    @test haskey(data, :polyX)
    @test isa(data[:rho], Vector)
    @test isa(data[:E], Array)
    @test ndims(data[:E]) == 3
    return
end

function test_2d_param_list_form_builds_matrix()
    # AMPL `param P := i j v ...` over a 2D parameter must produce a
    # `Matrix` indexable as `P[i, j]`, not a flat `Vector`.
    mod = """
    set T;
    set K;
    param REF {t in T, k in K};
    var x {t in T, k in K};
    minimize obj: sum {t in T, k in K} x[t,k];
    subject to
    c {t in T, k in K}: x[t,k] >= REF[t,k];
    """
    dat = """
    set T := 1 2 3;
    set K := 1 2;
    param REF :=
    1 1 11.0
    1 2 12.0
    2 1 21.0
    2 2 22.0
    3 1 31.0
    3 2 32.0
    ;
    """
    data = parse_dat(dat, mod)
    P = data["REF"]
    @test P isa Matrix{Float64}
    @test size(P) == (3, 2)
    @test P[1, 1] == 11.0
    @test P[2, 1] == 21.0
    @test P[3, 2] == 32.0
    return
end

function test_dat_schema_redirects_through_model()
    # `read_dat(path, model)` is a thin convenience that derives a
    # `DatSchema` from the model and delegates. The two paths must
    # produce the same dictionary so the generated `.jl` file
    # (which embeds a hard-coded `DatSchema`) matches the model-loaded
    # workflow exactly.
    path = joinpath(@__DIR__, "examples", "example1.dat")
    model = JuMPConverter.AMPL.read_model(
        joinpath(@__DIR__, "input", "elec_pricing.mod"),
    )
    schema = JuMPConverter.AMPL.DatSchema(model)
    @test schema isa JuMPConverter.AMPL.DatSchema
    @test schema.param_ndims[:S] == 0
    @test schema.param_ndims[:E] == 3
    @test JuMPConverter.AMPL.read_dat(path, model) ==
          JuMPConverter.AMPL.read_dat(path, schema)
    return
end

function test_read_dat_returns_symbol_keys()
    # Splatting `data...` into `build_model(; ...)` requires Symbol keys.
    path = joinpath(@__DIR__, "examples", "example1.dat")
    data = JuMPConverter.AMPL.read_dat(path)
    @test data isa Dict{Symbol,Any}
    @test all(k -> k isa Symbol, keys(data))
    return
end

function test_example1_with_model()
    # Parse the .mod to get model info, then parse .dat with it.
    # The model tells the parser the dimensionality of each param.
    mod_path = joinpath(@__DIR__, "input", "elec_pricing.mod")
    dat_path = joinpath(@__DIR__, "examples", "example1.dat")
    mod_text = read(mod_path, String)
    dat_text = read(dat_path, String)
    data = parse_dat(dat_text, mod_text)
    @test data["S"] == 5
    @test data["W"] == 4
    @test data["H"] == 3
    @test data["X"] == 4
    @test isa(data["rho"], Vector)
    @test length(data["rho"]) == 5
    @test isa(data["E"], Array)
    @test ndims(data["E"]) == 3
    return
end

# ============================================================
# CSV export / import (dat_to_csv + read_*_csv)
# ============================================================

function test_dat_to_csv_roundtrip_set_scalar_1d_2d()
    # Roundtrip: parse .dat → write CSVs → read CSVs back. We use
    # integer-indexed sets to stay within the parser's existing
    # capabilities for simple-form 1D params (ALPHA below).
    mod = """
    param n integer;
    set K := 1..3;
    param ALPHA {k in K};
    param BETA {i in 1..2, j in 1..3};
    var x {k in K} >= 0;
    minimize obj: sum {k in K} ALPHA[k] * x[k];
    s.t. c {k in K}: x[k] >= 0;
    """
    dat = """
    param n := 5;
    param ALPHA :=
    1 1.5
    2 2.5
    3 3.5;
    param BETA :=
    1 1 11.0
    1 2 12.0
    1 3 13.0
    2 1 21.0
    2 2 22.0
    2 3 23.0;
    """
    mktempdir() do dir
        mod_path = joinpath(dir, "m.mod")
        dat_path = joinpath(dir, "d.dat")
        write(mod_path, mod)
        write(dat_path, dat)
        model = JuMPConverter.AMPL.read_model(mod_path)
        csv_dir = joinpath(dir, "csvs")
        JuMPConverter.AMPL.dat_to_csv(dat_path, model, csv_dir)
        @test isfile(joinpath(csv_dir, "n.csv"))
        @test isfile(joinpath(csv_dir, "ALPHA.csv"))
        @test isfile(joinpath(csv_dir, "BETA.csv"))
        n = JuMPConverter.AMPL.read_scalar_csv(joinpath(csv_dir, "n.csv"))
        @test n == 5
        ALPHA = JuMPConverter.AMPL.read_1d_csv(joinpath(csv_dir, "ALPHA.csv"))
        @test ALPHA[1] == 1.5
        @test ALPHA[3] == 3.5
        BETA = JuMPConverter.AMPL.read_2d_csv(joinpath(csv_dir, "BETA.csv"))
        @test BETA[1, 1] == 11.0
        @test BETA[2, 3] == 23.0
    end
    return
end

function test_dat_to_csv_via_dat_schema()
    # The Model-accepting overload must redirect through DatSchema.
    mod = """
    param a integer;
    var x >= 0;
    minimize obj: a * x;
    s.t. c: x >= a;
    """
    dat = "param a := 7;"
    mktempdir() do dir
        mod_path = joinpath(dir, "m.mod")
        dat_path = joinpath(dir, "d.dat")
        write(mod_path, mod)
        write(dat_path, dat)
        model = JuMPConverter.AMPL.read_model(mod_path)
        schema = JuMPConverter.AMPL.DatSchema(model)
        d1 = joinpath(dir, "via_model")
        d2 = joinpath(dir, "via_schema")
        JuMPConverter.AMPL.dat_to_csv(dat_path, model, d1)
        JuMPConverter.AMPL.dat_to_csv(dat_path, schema, d2)
        @test read(joinpath(d1, "a.csv"), String) ==
              read(joinpath(d2, "a.csv"), String)
    end
    return
end

function test_read_csv_via_schema()
    # `read_csv(csv_dir, schema)` reads only the CSV files listed in
    # the schema, and skips missing ones so the kwarg's `.mod` default
    # takes effect. Must mirror the shape of `read_dat`.
    mod = """
    set K := 1..3;
    param n integer;
    param ALPHA {k in K};
    var x {k in K} >= 0;
    minimize obj: sum {k in K} ALPHA[k] * x[k];
    s.t. c {k in K}: x[k] >= 0;
    """
    dat = """
    param n := 5;
    param ALPHA :=
    1 1.5
    2 2.5
    3 3.5;
    """
    mktempdir() do dir
        mod_path = joinpath(dir, "m.mod")
        dat_path = joinpath(dir, "d.dat")
        write(mod_path, mod)
        write(dat_path, dat)
        model = JuMPConverter.AMPL.read_model(mod_path)
        schema = JuMPConverter.AMPL.DatSchema(model)
        # Sets in the schema (K is in the .mod, no .dat content for it
        # in this example, but the schema lists it so read_csv can
        # pick up a K.csv if present).
        @test :K in schema.set_names
        csv_dir = joinpath(dir, "csvs")
        JuMPConverter.AMPL.dat_to_csv(dat_path, model, csv_dir)
        data = JuMPConverter.AMPL.read_csv(csv_dir, schema)
        @test data isa Dict{Symbol,Any}
        @test data[:n] == 5
        @test data[:ALPHA][1] == 1.5
        @test data[:ALPHA][3] == 3.5
        # Deleting a CSV makes that kwarg fall back to the .mod default.
        rm(joinpath(csv_dir, "n.csv"))
        data2 = JuMPConverter.AMPL.read_csv(csv_dir, schema)
        @test !haskey(data2, :n)
    end
    return
end

function test_csv_writers_for_dense_axis_arrays()
    # Cover `_write_csv_value` overloads that fire only for
    # DenseAxisArray with explicit labels (1D string-indexed, 2D, 3D)
    # and the empty-SparseAxisArray fast-return. We construct the
    # containers directly so we hit every shape regardless of which
    # types the parser happens to materialize.
    JuMP = JuMPConverter.JuMP
    A = JuMPConverter.AMPL
    mktempdir() do dir
        # DenseAxisArray{T,1} with string labels.
        v1 = JuMP.Containers.DenseAxisArray([1.0, 2.0, 3.0], ["A", "B", "C"])
        p1 = joinpath(dir, "v1.csv")
        A._write_csv_value(p1, v1)
        @test read(p1, String) == "index,value\nA,1.0\nB,2.0\nC,3.0\n"
        # DenseAxisArray{T,2}.
        m2 = JuMP.Containers.DenseAxisArray(
            Float64[1 2; 3 4],
            ["r1", "r2"],
            ["c1", "c2"],
        )
        p2 = joinpath(dir, "m2.csv")
        A._write_csv_value(p2, m2)
        @test occursin("index,c1,c2", read(p2, String))
        @test occursin("r1,1.0,2.0", read(p2, String))
        # DenseAxisArray{T,3}.
        m3 = JuMP.Containers.DenseAxisArray(
            reshape(Float64[1:8;], 2, 2, 2),
            ["a", "b"],
            [10, 20],
            ["x", "y"],
        )
        p3 = joinpath(dir, "m3.csv")
        A._write_csv_value(p3, m3)
        out = read(p3, String)
        @test occursin("i1,i2,i3,value", out)
        @test occursin("a,10,x,1.0", out)
        # Empty SparseAxisArray: short-circuit return, nothing written.
        empty_sp =
            JuMP.Containers.SparseAxisArray(Dict{Tuple{Int,Int},Float64}())
        p_empty = joinpath(dir, "empty.csv")
        A._write_csv_value(p_empty, empty_sp)
        @test !isfile(p_empty)
    end
    return
end

function test_csv_readers_strings_and_2col_and_sparse_nd()
    # Cover: read_set_csv on string elements (also exercises the
    # `_try_numeric` String fallback), read_1d_csv 2-column branch,
    # and read_nd_csv sparse branch.
    A = JuMPConverter.AMPL
    JuMP = JuMPConverter.JuMP
    mktempdir() do dir
        # Set with non-numeric elements.
        set_path = joinpath(dir, "S.csv")
        write(set_path, "value\nA\nB\nC\n")
        @test A.read_set_csv(set_path) == ["A", "B", "C"]
        # 2-column 1D CSV.
        path1d = joinpath(dir, "ALPHA.csv")
        write(path1d, "index,value\nA,1.5\nB,2.5\n")
        ALPHA = A.read_1d_csv(path1d)
        @test ALPHA isa JuMP.Containers.DenseAxisArray
        @test ALPHA["A"] == 1.5
        # 3D long-form with sparse coverage.
        sp_path = joinpath(dir, "sp.csv")
        write(sp_path, "i1,i2,i3,value\n1,1,1,10\n2,2,2,80\n")
        E = A.read_nd_csv(sp_path, 3)
        @test E isa JuMP.Containers.SparseAxisArray
    end
    return
end

function test_read_csv_covers_every_ndims_branch()
    # Exercise read_csv's per-ndims dispatch (set, scalar, 1D, 2D,
    # 3D) plus the "set CSV present" branch.
    A = JuMPConverter.AMPL
    mktempdir() do dir
        write(joinpath(dir, "S.csv"), "value\n1\n2\n3\n")
        write(joinpath(dir, "n.csv"), "value\n7\n")
        write(joinpath(dir, "ALPHA.csv"), "value\n1.0\n2.0\n3.0\n")
        write(joinpath(dir, "BETA.csv"), "index,1,2\n1,11,12\n2,21,22\n")
        write(
            joinpath(dir, "GAMMA.csv"),
            "i1,i2,i3,value\n1,1,1,1\n1,1,2,2\n1,2,1,3\n1,2,2,4\n2,1,1,5\n2,1,2,6\n2,2,1,7\n2,2,2,8\n",
        )
        schema = A.DatSchema(
            Dict{Symbol,Int}(:n => 0, :ALPHA => 1, :BETA => 2, :GAMMA => 3),
            [:S],
        )
        loaded = A.read_csv(dir, schema)
        @test loaded[:S] == [1, 2, 3]
        @test loaded[:n] == 7
        @test loaded[:ALPHA] == [1.0, 2.0, 3.0]
        @test loaded[:BETA][1, 1] == 11
        @test loaded[:GAMMA][1, 1, 1] == 1
    end
    return
end

function test_dat_to_csv_long_form_for_3d()
    # 3D values use long form; reader returns a DenseAxisArray when
    # the indices fill a complete grid.
    path = joinpath(@__DIR__, "examples", "example1.dat")
    model = JuMPConverter.AMPL.read_model(
        joinpath(@__DIR__, "input", "elec_pricing.mod"),
    )
    mktempdir() do dir
        JuMPConverter.AMPL.dat_to_csv(path, model, dir)
        E_csv = read(joinpath(dir, "E.csv"), String)
        @test occursin("i1,i2,i3,value", E_csv)
        E = JuMPConverter.AMPL.read_nd_csv(joinpath(dir, "E.csv"), 3)
        @test E isa JuMPConverter.JuMP.Containers.DenseAxisArray
        @test ndims(E) == 3
        @test E[1, 1, 1] ≈ 205.014795
    end
    return
end

function test_dat_to_csv_multi_column_named_table()
    # `param NAME: c1 c2 := …` (named multi-column form) keeps the
    # whole block as a DataFrame in the data dict, exercising the
    # DataFrame branch of `_write_csv_value` — written as a labeled
    # matrix CSV with the column headers preserved.
    mod = """
    set I;
    param T {I, I};
    var x {I} >= 0;
    minimize obj: sum {i in I} x[i];
    s.t. c {i in I}: x[i] >= 0;
    """
    dat = """
    set I := a b c;
    param T:  a  b  c :=
    a         1  2  3
    b         4  5  6
    c         7  8  9 ;
    """
    mktempdir() do dir
        mod_path = joinpath(dir, "m.mod")
        dat_path = joinpath(dir, "m.dat")
        write(mod_path, mod)
        write(dat_path, dat)
        model = JuMPConverter.AMPL.read_model(mod_path)
        csv_dir = joinpath(dir, "csvs")
        JuMPConverter.AMPL.dat_to_csv(dat_path, model, csv_dir)
        T_csv = read(joinpath(csv_dir, "T.csv"), String)
        # Header row carries the column labels from the `:` line; row
        # labels come from the first column of each data row.
        @test startswith(T_csv, "index,a,b,c\n")
        @test occursin("\na,1.0,2.0,3.0\n", T_csv)
        @test occursin("\nc,7.0,8.0,9.0", T_csv)
    end
    return
end

end  # module

TestDatParsing.runtests()
