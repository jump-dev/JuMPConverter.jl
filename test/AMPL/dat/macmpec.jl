using Test
import MacMPEC
import JuMPConverter

# Instances whose `read_from_file` round-trip currently fails.
# These fall into three categories:
#
#   1. `.dat` files that don't actually populate a required `set`/`param`
#      because the original AMPL script generated the data via a loop
#      we don't evaluate (`nash1a`–`nash1e` lack `InitPoints`).
#   2. Models that lean on AMPL's lazy / defaulted indexing semantics
#      where JuMP requires every accessed key to exist (`siouxfls*`,
#      `tap-09/15`, `monteiro*`, `water-*`, `hs044-i`, `ralphmod`).
#   3. Niche `.mod` constructs the converter doesn't yet emit
#      correctly: recursive defaults (`liswet1-*`'s
#      `param B{i in 0..K} := if i == 0 then 1 else B[i-1] * i`).
#
# Wrapping them in `@test_broken` lets `Pkg.test()` stay green: a real
# regression that newly breaks one of the currently-passing instances
# still errors loudly, and a fix that takes one off this list flips
# the corresponding `@test_broken` to a "@test passed unexpectedly"
# failure so we know to delete it.
const BROKEN_BUILD = Set([
    "hs044-i",
    "liswet1-050",
    "liswet1-100",
    "liswet1-200",
    "monteiro",
    "monteiroB",
    "nash1a",
    "nash1b",
    "nash1c",
    "nash1d",
    "nash1e",
    "ralphmod",
    "siouxfls",
    "siouxfls1",
    "tap-09",
    "tap-15",
    "water-net",
    "water-FL",
])

# Iterate over `collection()` rows rather than `list()` because some
# problem names occur multiple times: `TrafficSignalCycle` shares its
# `.mod` across 13 different `.dat`s, and `gnash10` has two different
# `.mod`s under the same name. `list()` + `problem(name)` would silently
# skip variants since `problem` only returns the first match.
@testset "MacMPEC" begin
    @testset "$(row.name)/$(row["mod file"])" for row in
                                                  eachrow(MacMPEC.collection())
        mod_path = joinpath(MacMPEC.AMPL_DIR, row["mod file"])
        model = JuMPConverter.AMPL.read_model(mod_path)
        @test model isa JuMPConverter.Model
        dat_file = row["dat file"]
        dat_path =
            dat_file == "n/a" ? nothing : joinpath(MacMPEC.AMPL_DIR, dat_file)
        if dat_path !== nothing
            data = JuMPConverter.AMPL.read_dat(dat_path, model)
            @test data isa Dict{Symbol}
        end
        # End-to-end: render to .jl, evaluate in a fresh anonymous module
        # (hygiene — sets/params/build_model from different problems must
        # not collide), then call `build_model`. `read_from_file` already
        # creates a fresh `Module(:JuMPConverterSandbox)` per call.
        if row.name in BROKEN_BUILD
            @test_broken JuMPConverter.read_from_file(mod_path, dat_path) isa
                         JuMPConverter.JuMP.Model
        else
            @test JuMPConverter.read_from_file(mod_path, dat_path) isa
                  JuMPConverter.JuMP.Model
        end
    end
end
