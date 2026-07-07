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

# Every instance currently parses (`read_model` succeeds), but for the
# instances below the rendered `.jl` still contains Julia syntax errors
# — un-parenthesized `if … then … else` emitted verbatim, negative
# ranges rendered without spacing (`i in-mo:-1`), AMPL generator forms
# like `max{i in S} expr`, and similar constructs the emitter doesn't
# translate yet.
#
# Same convention as `dat/macmpec.jl`: a regression on a currently-passing
# instance errors loudly, and a fix flips the corresponding `@test_broken`
# into an "unexpected pass" so we know to delete it from this list.
const PLATO_NLP_BROKEN_RENDER = Set([
    "NARX_CFy",
    "WM_CFy",
    "Weyl_m0",
    "arki0009",
    "cont_p",
    "dirichlet120",
    "dirichlet40",
    "dirichlet80",
    "dtoc1nd",
    "ex1_160",
    "ex1_320",
    "ex2_160",
    "ex2_320",
    "ex3_160",
    "ex3_320",
    "henon120",
    "henon40",
    "henon80",
    "lane_emden120",
    "lane_emden40",
    "lane_emden80",
    "lukvle11",
    "lukvle12",
    "lukvle13",
    "lukvle14",
    "lukvle15",
    "lukvle16",
    "lukvle17",
    "lukvle18",
    "lukvle5",
    "lukvle9",
    "lukvli11",
    "lukvli12",
    "lukvli13",
    "lukvli14",
    "lukvli15",
    "lukvli16",
    "lukvli17",
    "lukvli18",
    "lukvli5",
    "lukvli9",
    "qcqp1000-1c",
    "qcqp1000-1nc",
    "qcqp1000-2c",
    "qcqp1000-2nc",
    "qcqp1500-1c",
    "qcqp1500-1nc",
    "qcqp500-1c",
    "qcqp500-1nc",
    "qcqp500-2c",
    "qcqp500-2nc",
    "qcqp500-3c",
    "qcqp500-3nc",
    "qcqp750-1c",
    "qcqp750-1nc",
    "qcqp750-2c",
    "qcqp750-2nc",
    "svanberg",
])

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
        valid = !plato_nlp_has_parse_error(Meta.parseall(sprint(print, model)))
        if first(splitext(mod_file)) in PLATO_NLP_BROKEN_RENDER
            @test_broken valid
        else
            @test valid
        end
    end
end
