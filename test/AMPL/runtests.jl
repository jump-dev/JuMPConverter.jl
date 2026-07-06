import JuMPConverter
include(joinpath(dirname(@__DIR__), "utils.jl"))

test_io(JuMPConverter.AMPL.read_model, @__DIR__; ext = ".mod")

include(joinpath(@__DIR__, "mod_tests.jl"))
include(joinpath(@__DIR__, "dat_tests.jl"))
include(joinpath(@__DIR__, "dat", "macmpec.jl"))
include(joinpath(@__DIR__, "plato_nlp.jl"))
