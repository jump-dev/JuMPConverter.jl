using Test
import MacMPEC
import JuMPConverter

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
    dat_path = dat_file == "n/a" ? nothing : joinpath(MacMPEC.AMPL_DIR, dat_file)
    if dat_path !== nothing
        data = JuMPConverter.AMPL.read_dat(dat_path, model)
        @test data isa Dict{Symbol}
    end
    # End-to-end: render to .jl, evaluate in a fresh anonymous module
    # (hygiene — sets/params/build_model from different problems must
    # not collide), then call `build_model`. `read_from_file` already
    # creates a fresh `Module(:JuMPConverterSandbox)` per call.
    @test JuMPConverter.read_from_file(mod_path, dat_path) isa
          JuMPConverter.JuMP.Model
end
end
