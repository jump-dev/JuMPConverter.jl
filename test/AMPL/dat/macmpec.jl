using Test
import MacMPEC
import JuMPConverter

# Instances whose `read_from_file` round-trip currently fails: models
# that lean on AMPL's lazy / defaulted indexing semantics where JuMP
# requires every accessed key to exist (`siouxfls*`, `tap-09/15`,
# `monteiro*`, `water-*`, `hs044-i`, `ralphmod`).
#
# Wrapping them in `@test_broken` lets `Pkg.test()` stay green: a real
# regression that newly breaks one of the currently-passing instances
# still errors loudly, and a fix that takes one off this list flips
# the corresponding `@test_broken` to a "@test passed unexpectedly"
# failure so we know to delete it.
const BROKEN_BUILD = Set([
    "hs044-i",
    "monteiro",
    "monteiroB",
    "ralphmod",
    "siouxfls",
    "siouxfls1",
    "tap-09",
    "tap-15",
    "water-net",
    "water-FL",
])

# Iterate over `problems()` rather than `list()` because some problem
# names occur multiple times: `TrafficSignalCycle` shares its `.mod`
# across 13 different `.dat`s, and `gnash10` has two different `.mod`s
# under the same name. `list()` + `problem(name)` would silently skip
# variants since `problem` only returns the first match.
@testset "MacMPEC" begin
    @testset "$(p.name)/$(p.mod_file)" for p in MacMPEC.problems()
        mod_path = MacMPEC.mod_path(p)
        model = JuMPConverter.AMPL.read_model(mod_path)
        @test model isa JuMPConverter.Model
        # A problem may need several `.dat`s: `nash1a`–`nash1e` are
        # `nash1.dat` (which populates `InitPoints`/`iptx1`/`iptx2`)
        # followed by their own, which only sets the starting point.
        dat_paths = MacMPEC.dat_paths(p)
        if !isempty(dat_paths)
            data = JuMPConverter.AMPL.read_dat(dat_paths, model)
            @test data isa Dict{Symbol}
        end
        # End-to-end: render to .jl, evaluate in a fresh anonymous module
        # (hygiene — sets/params/build_model from different problems must
        # not collide), then call `build_model`. `read_from_file` already
        # creates a fresh `Module(:JuMPConverterSandbox)` per call.
        if p.name in BROKEN_BUILD
            @test_broken JuMPConverter.read_from_file(mod_path, dat_paths) isa
                         JuMPConverter.JuMP.Model
        else
            @test JuMPConverter.read_from_file(mod_path, dat_paths) isa
                  JuMPConverter.JuMP.Model
        end
    end
end
