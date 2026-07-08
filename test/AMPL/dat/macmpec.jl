using Test
import MacMPEC
import JuMPConverter

# Instances whose `read_from_file` round-trip currently fails: models
# indexed over a set of tuples (arcs) where a param/variable is accessed
# at a tuple outside its domain — `siouxfls*`, `tap-09/15`, `monteiro*`,
# `water-*` key by `(i, j)` arcs, and `ralphmod` accesses a `{state}`
# variable off its index set. AMPL's lazy indexing tolerates this; JuMP
# requires the key to exist. (The simpler defaulted-scalar-index case,
# hs044-i, is handled by `JuMPConverter.AMPL.with_default`; declared-
# but-unused required params, `nash1a`–`nash1e`'s `InitPoints`, by the
# `JuMPConverter.AMPL.Unset` kwarg sentinel.)
#
# Wrapping them in `@test_broken` lets `Pkg.test()` stay green: a real
# regression that newly breaks one of the currently-passing instances
# still errors loudly, and a fix that takes one off this list flips
# the corresponding `@test_broken` to a "@test passed unexpectedly"
# failure so we know to delete it.
const BROKEN_BUILD = Set([
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
