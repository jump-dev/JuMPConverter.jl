module AMPL

import MathOptInterface as MOI
import JuMPConverter

include("lexer.jl")
include("model.jl")
include("parser.jl")
include("csv.jl")

# AMPL's built-in RNG functions, referenced by generated model code
# (qcqp's `param LQ{…} := if i == j then Uniform01() …`). Matching the
# distribution is enough to build instances; these do not reproduce
# AMPL's random streams.
Uniform01() = rand()
Uniform(a, b) = a + (b - a) * rand()
Normal01() = randn()
Normal(m, s) = m + s * randn()
Irand224() = rand(0:(2^24-1))

end # module AMPL
