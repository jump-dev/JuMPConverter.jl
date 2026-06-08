import CSV
import DataFrames

# ============================================================
# CSV writers: dispatched on the value type returned by `read_dat`.
#
# - Number          → 1 row + `value` header
# - AbstractVector  → single column + `value` header
#                     (sets and dense 1D params with implicit 1:N indexing)
# - DenseAxisArray{T,1} → 2 columns: `index, value`
# - AbstractMatrix  → labeled matrix with implicit 1:N row/col labels
# - DenseAxisArray{T,2} → labeled matrix with explicit labels
# - DenseAxisArray (N≥3) → long form with explicit labels
# - AbstractArray   (N≥3) → long form with implicit 1:N indices
# - SparseAxisArray → long form
# ============================================================

function _write_csv_value(path::String, v::Number)
    open(path, "w") do io
        println(io, "value")
        return println(io, v)
    end
    return
end

function _write_csv_value(path::String, v::AbstractVector)
    open(path, "w") do io
        println(io, "value")
        for x in v
            println(io, x)
        end
    end
    return
end

function _write_csv_value(
    path::String,
    v::JuMP.Containers.DenseAxisArray{T,1},
) where {T}
    labels = collect(only(v.axes))
    open(path, "w") do io
        println(io, "index,value")
        for (l, x) in zip(labels, v.data)
            println(io, l, ",", x)
        end
    end
    return
end

function _write_labeled_matrix(path::String, rows, cols, cell::Function)
    open(path, "w") do io
        print(io, "index")
        for c in cols
            print(io, ",", c)
        end
        println(io)
        for (i, r) in enumerate(rows)
            print(io, r)
            for (j, _) in enumerate(cols)
                print(io, ",", cell(i, j))
            end
            println(io)
        end
    end
    return
end

function _write_csv_value(
    path::String,
    v::JuMP.Containers.DenseAxisArray{T,2},
) where {T}
    rows = collect(v.axes[1])
    cols = collect(v.axes[2])
    return _write_labeled_matrix(path, rows, cols, (i, j) -> v.data[i, j])
end

function _write_csv_value(path::String, v::AbstractMatrix)
    nrows, ncols = size(v)
    return _write_labeled_matrix(path, 1:nrows, 1:ncols, (i, j) -> v[i, j])
end

function _write_csv_value(
    path::String,
    v::JuMP.Containers.DenseAxisArray{T,N},
) where {T,N}
    open(path, "w") do io
        for d in 1:N
            print(io, "i", d, ",")
        end
        println(io, "value")
        for I in CartesianIndices(v.data)
            for d in 1:N
                print(io, v.axes[d][I[d]], ",")
            end
            println(io, v.data[I])
        end
    end
    return
end

function _write_csv_value(path::String, v::AbstractArray)
    N = ndims(v)
    open(path, "w") do io
        for d in 1:N
            print(io, "i", d, ",")
        end
        println(io, "value")
        for I in CartesianIndices(v)
            for d in 1:N
                print(io, I[d], ",")
            end
            println(io, v[I])
        end
    end
    return
end

# `read_dat` returns multi-column `param: c1 c2 := …` blocks as a
# DataFrame whose first column is the row index and remaining columns
# are the data columns — exactly the labeled-matrix layout. Missing
# cells (AMPL `.`) become empty CSV cells so the reader sees them as
# absent rather than the literal string "missing".
function _write_csv_value(path::String, v::DataFrames.DataFrame)
    rows = v[:, 1]
    cols = DataFrames.names(v)[2:end]
    cell = (i, j) -> let x = v[i, j+1]
        x === missing ? "" : x
    end
    return _write_labeled_matrix(path, rows, cols, cell)
end

function _write_csv_value(path::String, v::JuMP.Containers.SparseAxisArray)
    isempty(v.data) && return
    N = length(first(keys(v.data)))
    if N == 2
        rows = sort(unique(k[1] for k in keys(v.data)))
        cols = sort(unique(k[2] for k in keys(v.data)))
        return _write_labeled_matrix(
            path,
            rows,
            cols,
            (i, j) -> get(v.data, (rows[i], cols[j]), NaN),
        )
    end
    open(path, "w") do io
        for d in 1:N
            print(io, "i", d, ",")
        end
        println(io, "value")
        for (k, val) in v.data
            for d in 1:N
                print(io, k[d], ",")
            end
            println(io, val)
        end
    end
    return
end

"""
    dat_to_csv(dat_path::String, schema::DatSchema, out_dir::String)
    dat_to_csv(dat_path::String, model::JuMPConverter.Model, out_dir::String)

Read an AMPL `.dat` file and emit one CSV per parameter/set into
`out_dir`. The CSV format is type-dependent and pairs with
`read_set_csv`, `read_scalar_csv`, `read_1d_csv`, `read_2d_csv`,
`read_nd_csv` for roundtripping. The `Model`-accepting overload is a
thin wrapper that derives a `DatSchema` from the model.
"""
function dat_to_csv(dat_path::String, schema::DatSchema, out_dir::String)
    isdir(out_dir) || mkpath(out_dir)
    data = read_dat(dat_path, schema)
    for (name, value) in data
        # `:fixes` is a meta-entry (Vector{FixStatement}) carried
        # alongside data values; no CSV representation makes sense.
        name === :fixes && continue
        _write_csv_value(joinpath(out_dir, string(name) * ".csv"), value)
    end
    return out_dir
end

function dat_to_csv(
    dat_path::String,
    model::JuMPConverter.Model,
    out_dir::String,
)
    return dat_to_csv(dat_path, DatSchema(model), out_dir)
end

# ============================================================
# CSV readers: every cell is read as a String and run through
# `_try_numeric`, so column headers (which are always strings on
# disk) and values are parsed back to Int/Float64 when possible.
# ============================================================

# Recover an Int or Float64 from a CSV cell or header; fall back
# to the raw string. Needed because CSV column headers are always
# strings on disk, but we want `1, 2, 3` axis labels back as Ints.
function _try_numeric(s::AbstractString)
    v = tryparse(Int, s)
    isnothing(v) || return v
    v = tryparse(Float64, s)
    isnothing(v) || return v
    return String(s)
end

"""
    read_set_csv(path::String) -> Vector

Read a single-column CSV (header `value`) and return the values,
parsed as `Int`/`Float64` when possible.
"""
function read_set_csv(path::String)
    f = CSV.File(path; types = String)
    return [_try_numeric(r[1]) for r in f]
end

"""
    read_scalar_csv(path::String) -> Number or String

Read a 1-row CSV (header `value`) and return the single cell.
"""
function read_scalar_csv(path::String)
    f = CSV.File(path; types = String)
    return _try_numeric(first(f)[1])
end

"""
    read_1d_csv(path::String) -> Vector or DenseAxisArray

Read a 1- or 2-column CSV. With one column, returns a `Vector`. With
two columns (`index, value`), returns a `DenseAxisArray` indexed by
the first-column labels.
"""
function read_1d_csv(path::String)
    f = CSV.File(path; types = String)
    cols = propertynames(f)
    if length(cols) == 1
        return _convert_to_concrete_eltype([_try_numeric(r[1]) for r in f])
    end
    labels = _convert_to_concrete_eltype([_try_numeric(r[1]) for r in f])
    values = _convert_to_concrete_eltype([_try_numeric(r[2]) for r in f])
    return JuMP.Containers.DenseAxisArray(values, labels)
end

"""
    read_2d_csv(path::String) -> DenseAxisArray

Read a labeled 2D CSV (first column = row labels, header = column
labels) into a `DenseAxisArray` indexed by row × col.
"""
function read_2d_csv(path::String)
    f = CSV.File(path; types = String)
    cols = propertynames(f)
    col_labels = _convert_to_concrete_eltype(
        Any[_try_numeric(String(c)) for c in cols[2:end]],
    )
    rows = collect(f)
    row_labels =
        _convert_to_concrete_eltype(Any[_try_numeric(r[1]) for r in rows])
    raw = Any[
        _try_numeric(rows[i][cols[j+1]]) for
        i in eachindex(rows), j in eachindex(col_labels)
    ]
    T = _concrete_eltype(raw)
    M = convert(Matrix{T}, raw)
    return JuMP.Containers.DenseAxisArray(M, row_labels, col_labels)
end

"""
    read_csv(csv_dir::String, schema::DatSchema) -> Dict{Symbol, Any}

Read a directory of CSVs (one file per parameter or set named in
`schema`) and return a dictionary suitable for splatting into a
generated `build_model(; ...)` kwarg method. Files that are missing
are simply skipped, so the corresponding kwarg's `.mod` default takes
effect.
"""
function read_csv(csv_dir::String, schema::DatSchema)
    data = Dict{Symbol,Any}()
    for name in schema.set_names
        path = joinpath(csv_dir, string(name) * ".csv")
        isfile(path) || continue
        data[name] = read_set_csv(path)
    end
    for (name, nd) in schema.param_ndims
        path = joinpath(csv_dir, string(name) * ".csv")
        isfile(path) || continue
        data[name] = if nd == 0
            read_scalar_csv(path)
        elseif nd == 1
            read_1d_csv(path)
        elseif nd == 2
            read_2d_csv(path)
        else
            read_nd_csv(path, nd)
        end
    end
    return data
end

"""
    read_nd_csv(path::String, ndims::Int) -> DenseAxisArray or SparseAxisArray

Read a long-form CSV with `ndims` index columns followed by a value
column. Returns a `DenseAxisArray` if the indices form a complete
1:n_d grid in each dimension, else a `SparseAxisArray`.
"""
function read_nd_csv(path::String, nd::Int)
    f = CSV.File(path; types = String)
    cols = propertynames(f)
    @assert length(cols) == nd + 1 "expected $(nd + 1) columns, got $(length(cols))"
    indices = NTuple{nd,Any}[]
    values = Any[]
    for r in f
        push!(indices, ntuple(d -> _try_numeric(r[d]), nd))
        push!(values, _try_numeric(r[nd+1]))
    end
    T = _concrete_eltype(values)
    values = convert(Vector{T}, values)
    axes_per_dim = ntuple(d -> sort(unique([idx[d] for idx in indices])), nd)
    grid_size = prod(length, axes_per_dim)
    if length(indices) == grid_size
        sz = length.(axes_per_dim)
        arr = Array{T,nd}(undef, sz...)
        idx_to_pos = ntuple(
            d -> Dict(v => i for (i, v) in enumerate(axes_per_dim[d])),
            nd,
        )
        for (idx, val) in zip(indices, values)
            pos = ntuple(d -> idx_to_pos[d][idx[d]], nd)
            arr[pos...] = val
        end
        return JuMP.Containers.DenseAxisArray(arr, axes_per_dim...)
    end
    d = OrderedCollections.OrderedDict{NTuple{nd,Any},T}()
    for (idx, val) in zip(indices, values)
        d[idx] = val
    end
    return JuMP.Containers.SparseAxisArray(d)
end
