module TestReadFromFile

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
# AMPL — with companion .dat file
# ============================================================

function test_read_ampl_mod_with_dat()
    mod = joinpath(@__DIR__, "AMPL", "input", "elec_pricing.mod")
    dat = joinpath(@__DIR__, "AMPL", "examples", "example1.dat")
    jm = JuMPConverter.read_from_file(mod, dat)
    @test jm isa JuMP.Model
    # Same shape as the manual codegen-and-include path used elsewhere
    # in the test suite (46 vars, 34 constraints).
    @test JuMP.num_variables(jm) == 46
    return
end

function test_read_from_file_dummy_elec_pricing_dat()
    # Smoke test on the dummy `.dat` shipped alongside the `.mod` —
    # exercises the full read_from_file path on a model with sets,
    # scalars, 1D, 2D and 3D parameters.
    mod = joinpath(@__DIR__, "AMPL", "input", "elec_pricing.mod")
    dat = joinpath(@__DIR__, "AMPL", "input", "elec_pricing.dat")
    jm = JuMPConverter.read_from_file(mod, dat)
    @test jm isa JuMP.Model
    return
end

# ============================================================
# AMPL — kwargs forwarded to the kwarg `build_model`
# ============================================================

function test_read_ampl_mod_with_dat_fixes()
    # The `.dat` doubles as the example for discovering data-section
    # `fix` statements: each unique fix becomes a `fix_<…> = nothing`
    # kwarg, and the runtime path-loader fills it from the same `.dat`.
    mktempdir() do dir
        mod = """
        set I;
        var x {I};
        minimize obj: sum {i in I} x[i];
        """
        dat = """
        set I := a b c;
        fix x['a'] := 5;
        fix{i in I} x[i] := 7;
        """
        mod_path = joinpath(dir, "m.mod")
        dat_path = joinpath(dir, "m.dat")
        write(mod_path, mod)
        write(dat_path, dat)
        jm = JuMPConverter.read_from_file(mod_path, dat_path)
        x = jm[:x]
        # Both fixes applied in declaration order: the iter fix runs
        # after the scalar one, so x["a"] ends up at 7.
        @test JuMP.fix_value(x["a"]) == 7.0
        @test JuMP.fix_value(x["b"]) == 7.0
        @test JuMP.fix_value(x["c"]) == 7.0
    end
    return
end

function test_read_ampl_mod_with_kwargs()
    # An MWE that has a default-less scalar plus a 1D param with a
    # default — passing `n` as a kwarg satisfies the required arg, and
    # `ALPHA` falls back to its `default 1.0`.
    mktempdir() do dir
        mod = """
        param n integer;
        param ALPHA {i in 1..n} default 1.0;
        var x {i in 1..n} >= 0;
        minimize obj: sum {i in 1..n} ALPHA[i] * x[i];
        s.t. c {i in 1..n}: x[i] >= 0;
        """
        path = joinpath(dir, "m.mod")
        write(path, mod)
        jm = JuMPConverter.read_from_file(path; n = 3)
        @test jm isa JuMP.Model
        @test JuMP.num_variables(jm) == 3
    end
    return
end

# ============================================================
# GAMS — no .dat concept
# ============================================================

function test_read_gams_first_example()
    gms = joinpath(@__DIR__, "GAMS", "input", "first_example.gms")
    jm = JuMPConverter.read_from_file(gms)
    @test jm isa JuMP.Model
    # Xcorn, Xwheat, Xcotton, Z = 4 vars; obj/land/labor = 3 constraints.
    @test JuMP.num_variables(jm) == 4
    return
end

# ============================================================
# Error cases
# ============================================================

function test_unsupported_extension_throws()
    @test_throws ErrorException JuMPConverter.read_from_file("foo.txt")
    return
end

function test_dat_and_kwargs_mutually_exclusive()
    mod = joinpath(@__DIR__, "AMPL", "input", "elec_pricing.mod")
    dat = joinpath(@__DIR__, "AMPL", "examples", "example1.dat")
    @test_throws ErrorException JuMPConverter.read_from_file(mod, dat; S = 5)
    return
end

end  # module

TestReadFromFile.runtests()
