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
