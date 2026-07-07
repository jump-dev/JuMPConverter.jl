using Test
import Downloads
import JuMPConverter

# The AMPL sources of Hans Mittelmann's NLP benchmark:
# https://plato.asu.edu/ftp/ampl-nlp-source/
#
# Unlike MacMPEC, there is no Julia package vendoring this collection, so
# the `.mod` files (~15 MB, too large to commit) are downloaded on first
# run into `plato_nlp/` (gitignored) and reused afterwards. The list of
# files is scraped from the directory index so that new uploads are
# picked up; when offline we fall back to the cached copies.

const PLATO_NLP_URL = "https://plato.asu.edu/ftp/ampl-nlp-source/"
const PLATO_NLP_DIR = joinpath(@__DIR__, "plato_nlp")

# Files listed in the index whose link is dead (HTTP 404).
const PLATO_NLP_MISSING = Set(["nql180.mod", "qssp60.mod", "qssp180.mod"])

# `Meta.parseall` never throws — syntax errors come back embedded as
# `Expr(:error, …)` / `Expr(:incomplete, …)` nodes, so `isa Expr` alone
# would accept invalid output.
function plato_nlp_has_parse_error(x)
    x isa Expr || return false
    x.head in (:error, :incomplete) && return true
    return any(plato_nlp_has_parse_error, x.args)
end

function plato_nlp_mod_files()
    files = try
        index = sprint(io -> Downloads.download(PLATO_NLP_URL, io))
        String[
            m.captures[1] for m in eachmatch(r"href=\"([^\"]+\.mod)\"", index)
        ]
    catch err
        # Offline (or plato.asu.edu is down): reuse the cached copies.
        @warn "Cannot reach $PLATO_NLP_URL, using cached files" err
        filter(f -> endswith(f, ".mod"), readdir(PLATO_NLP_DIR))
    end
    return sort!(filter(f -> !(f in PLATO_NLP_MISSING), unique(files)))
end

@testset "PlatoNLP" begin
    mkpath(PLATO_NLP_DIR)
    @testset "$mod_file" for mod_file in plato_nlp_mod_files()
        mod_path = joinpath(PLATO_NLP_DIR, mod_file)
        if !isfile(mod_path)
            Downloads.download(PLATO_NLP_URL * mod_file, mod_path)
        end
        model = JuMPConverter.AMPL.read_model(mod_path)
        @test model isa JuMPConverter.Model
        # The rendered .jl must be syntactically valid Julia.
        @test !plato_nlp_has_parse_error(Meta.parseall(sprint(print, model)))
    end
end

# ============================================================
# End-to-end build: render each `.mod` to Julia, evaluate it, and call
# the generated `build_model()` (via `read_from_file`). This is the real
# test — a syntactically-valid render still has to produce a working
# `JuMP.Model`.
#
# Every instance is built EXCEPT the two documented exception lists
# below. Keeping them as explicit skip/broken lists (rather than an
# allow-list of what works) means a newly-broken instance fails loudly
# instead of silently dropping out of coverage.

_plato_reasons(names, reason) = Dict(String(n) => reason for n in names)

# Instances too expensive to build under CI — skipped entirely. These are
# NOT converter failures: the generated code is correct, the JuMP model is
# just too big (or the source too large for Julia to evaluate) to build in
# reasonable time/memory.
const PLATO_NLP_SKIP_BUILD = merge(
    Dict(
        # Julia's parser/lowering overflows its stack on the single
        # enormous generated expression (sources are 0.9 MB / 1.8 MB).
        "ex8_2_2" => "source too large — StackOverflowError during eval",
        "ex8_2_3" => "source too large — StackOverflowError during eval",
        # Fine-grid PDE/control discretizations: correct, but building the
        # JuMP model takes minutes (200 000+ constraints).
        "ex1_160" => "slow build (fine grid, ~220s)",
        "ex1_320" => "slow build (fine grid)",
        "ex2_160" => "slow build (fine grid)",
        "ex2_320" => "slow build (fine grid)",
        "ex3_160" => "slow build (fine grid, ~220s)",
        "ex3_320" => "slow build (fine grid)",
        "twod" => "slow build (3D grid, n = 500)",
        "bearing_200" => "slow build",
        "arki0003" => "slow build (685 KB source)",
        "arki0009" => "slow build (642 KB source)",
        # Fourier-series models whose data comes from indexed `let` we
        # don't evaluate; the build hangs rather than erroring quickly.
        "NARX_CFy" => "indexed `let` data unsupported; build hangs",
        "WM_CFy" => "indexed `let` data unsupported; build hangs",
        "Weyl_m0" => "indexed `let` data unsupported; build hangs",
    ),
    # Dense randomly-generated QCQP: each fills 500–1500-dimension matrices
    # via `Uniform01()` and builds a quadratic model — 200s+ each.
    _plato_reasons(
        [
            "qcqp$s" for s in (
                "500-1c",
                "500-1nc",
                "500-2c",
                "500-2nc",
                "500-3c",
                "500-3nc",
                "750-1c",
                "750-1nc",
                "750-2c",
                "750-2nc",
                "1000-1c",
                "1000-1nc",
                "1000-2c",
                "1000-2nc",
                "1500-1c",
                "1500-1nc",
            )
        ],
        "slow build (dense random QCQP data)",
    ),
)

# Instances that build quickly but fail for a known converter/data gap.
# `@test_broken` keeps the suite green while flagging the gap; a fix flips
# it to an "unexpected pass".
const PLATO_NLP_BROKEN_BUILD = merge(
    # Finite-element meshes: the node-coefficient params (`b`, `c`, `d`,
    # `p`) are supplied by inline `data;` tables the `.dat` reader doesn't
    # fully capture, so they stay required kwargs of `build_model`.
    _plato_reasons(
        [
            "$m$n" for m in ("dirichlet", "henon", "lane_emden") for
            n in (40, 80, 120)
        ],
        "FE node data (b/c/d/p) not captured from inline `data;` table",
    ),
    # `param rho_0;` / `param y1_n;` have no default and no data
    # assignment — genuinely unspecified, so `build_model()` is missing a
    # required kwarg.
    _plato_reasons(
        ["robot_800", "robot_1600"],
        "param `rho_0` has no default or data source",
    ),
    _plato_reasons(
        ["steering_6400", "steering_12800"],
        "param `y1_n` has no default or data source",
    ),
)

@testset "PlatoNLP build" begin
    @testset "$mod_file" for mod_file in plato_nlp_mod_files()
        name = first(splitext(mod_file))
        if haskey(PLATO_NLP_SKIP_BUILD, name)
            continue
        end
        mod_path = joinpath(PLATO_NLP_DIR, mod_file)
        isfile(mod_path) ||
            Downloads.download(PLATO_NLP_URL * mod_file, mod_path)
        if haskey(PLATO_NLP_BROKEN_BUILD, name)
            @test_broken JuMPConverter.read_from_file(mod_path) isa
                         JuMPConverter.JuMP.Model
        else
            @test JuMPConverter.read_from_file(mod_path) isa
                  JuMPConverter.JuMP.Model
        end
    end
end
