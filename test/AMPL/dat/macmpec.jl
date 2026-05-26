using Test
import MacMPEC
import JuMPConverter

# Iterate over `collection()` rows rather than `list()` because some
# problem names occur multiple times: `TrafficSignalCycle` shares its
# `.mod` across 13 different `.dat`s, and `gnash10` has two different
# `.mod`s under the same name. `list()` + `problem(name)` would silently
# skip variants since `problem` only returns the first match.
@testset "$(row.name)/$(row["mod file"])" for row in
                                              eachrow(MacMPEC.collection())
    model = JuMPConverter.AMPL.read_model(
        joinpath(MacMPEC.AMPL_DIR, row["mod file"]),
    )
    @test model isa JuMPConverter.Model
    dat_file = row["dat file"]
    if dat_file != "n/a"
        data = JuMPConverter.AMPL.read_dat(
            joinpath(MacMPEC.AMPL_DIR, dat_file),
            model,
        )
        @test data isa Dict{Symbol}
    end
end
