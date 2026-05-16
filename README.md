# JuMPConverter.jl

[![Build Status](https://github.com/jump-dev/JuMPConverter.jl/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/jump-dev/JuMPConverter.jl/actions?query=workflow%3ACI)
[![codecov](https://codecov.io/gh/jump-dev/JuMPConverter.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/jump-dev/JuMPConverter.jl)

[JuMPConverter.jl](https://github.com/jump-dev/JuMPConverter.jl) is a converter
for AMPL™ models in `.mod` or GAMS™ models in `.gmx` to [JuMP](https://github.com/jump-dev/JuMP.jl/)
models in `.jl`.

## License

`JuMPConverter.jl` is licensed under the [MIT License](https://github.com/jump-dev/JuMPConverter.jl/blob/main/LICENSE.md).

## Installation

Install JuMPConverter as follows:
```julia
import Pkg
Pkg.add("https://github.com/jump-dev/JuMPConverter.jl")
```

## Use with JuMP

### AMPL™ converter

To read an AMPL™ model `file.mod` with (optional) data in `file.dat` into a JuMP model, use the following:
```julia
using JuMPConverter
model = JuMPConverter.read_from_file("file.mod", "file.dat")
```

#### Convert the `.mod` into `.jl`

Internally, `read_from_file` convert the `.mod` as a `.jl` file using JuMP to model the problem.
To get this `.jl` file, use the following:
```julia
using JuMPConverter
model = JuMPConverter.AMPL.read_model("file.mod")
open("file.jl", "w") do io
    println(io, model)
end
```

#### Loading data from a `.dat` file

AMPL keeps the model structure (`.mod`) and the data (`.dat`) in
separate files. The emitted Julia file is self-contained: it defines
the keyword-argument `build_model(; S, W, ...)` plus a
`build_model(path::String)` dispatcher that picks between a `.dat`
file and a directory of CSVs based on `isdir(path)`. Once the `.jl`
file is generated, the `.mod` is no longer needed at runtime:

```julia
include("file.jl")

# Load straight from the .dat
jump_model = build_model("file.dat")
```

Internally, this loads the `.dat` file into a data dictionary.
`JuMPConverter.AMPL.read_dat`
returns a `Dict{Symbol,Any}` mapping each parameter or set name to a
scalar, `Vector`, `Array`, `JuMP.Containers.DenseAxisArray`, or
`JuMP.Containers.SparseAxisArray`. Doing this in two steps
can be useful if you want to inspect the dictionary.
One caveat is that you still need to keep the `model` (output of
`JuMPConverter.AMPL.read_model`) around (or you need to use a `DatSchema` as
done in the `file.jl`):
```julia
data = JuMPConverter.AMPL.read_dat("file.dat", model)
jump_model = build_model(; data...)
```

#### Loading data from CSV files

You can also export a `.dat` to a directory of CSVs (one file per
parameter or set) and pass that directory back to `build_model`:

```julia
JuMPConverter.AMPL.dat_to_csv("file.dat", model, "data/")
jump_model = build_model("data/")
```

The CSV directory loader reads each kwarg's CSV when present, so any
file you delete falls back to the kwarg's `.mod` default. CSV shape:
scalars and sets are single-column; 1D parameters are `index, value`;
2D parameters are labeled matrices (column headers from the second
axis); 3+D parameters use long form (`i1, i2, ..., value`).

### GAMS™ converter

To read a GAMS™ model `file.gms`, do:
```julia
using JuMPConverter
model = JuMPConverter.GAMS.read_model("file.gms")
```

To print the JuMP model to the terminal, simply do
```julia
println(io, model)
```

To save the JuMP model in a file `file.jl`, do
```julia
open("file.jl", "w") do io
    println(io, model)
end
```
