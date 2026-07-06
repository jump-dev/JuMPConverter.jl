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

# Instances whose `read_model` currently fails. These fall into a few
# categories:
#
#   1. `fix` with numeric indices (`fix x[0] := 0.0;`) — the fix parser
#      only accepts identifier / string indices (`clnlbeam`, `corkscrw`,
#      `optmass`).
#   2. Set literals with numeric elements in indexing (`dtoc1nd`, `dtoc2`).
#   3. Un-parenthesized `if … then … else …` inside constraint expressions
#      plus `param p integer in (0,1];` interval checks (`qcqp*`).
#
# Same convention as `dat/macmpec.jl`: a regression on a currently-passing
# instance errors loudly, and a fix flips the corresponding `@test_broken`
# into an "unexpected pass" so we know to delete it from this list.
const PLATO_NLP_BROKEN_PARSE = Set([
    "clnlbeam",
    "corkscrw",
    "dtoc1nd",
    "dtoc2",
    "optmass",
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
])

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
        if first(splitext(mod_file)) in PLATO_NLP_BROKEN_PARSE
            @test_broken JuMPConverter.AMPL.read_model(mod_path) isa
                         JuMPConverter.Model
        else
            model = JuMPConverter.AMPL.read_model(mod_path)
            @test model isa JuMPConverter.Model
            # The rendered .jl must at least be syntactically valid Julia.
            @test Meta.parseall(sprint(print, model)) isa Expr
        end
    end
end
