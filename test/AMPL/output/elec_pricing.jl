using JuMP
function build_model(;
    S,
    W,
    H,
    X,
    rho = JuMP.Containers.DenseAxisArray(fill(0.0, length(1:S)), 1:S),
    beta = JuMP.Containers.DenseAxisArray(fill(0.0, length(1:S)), 1:S),
    alpha = JuMP.Containers.DenseAxisArray(fill(0.0, length(1:W)), 1:W),
    E = JuMP.Containers.DenseAxisArray(
        fill(0.0, length(1:S), length(1:W), length(1:H)),
        1:S,
        1:W,
        1:H,
    ),
    C = JuMP.Containers.DenseAxisArray(
        fill(0.0, length(1:S), length(1:W)),
        1:S,
        1:W,
    ),
    R = JuMP.Containers.DenseAxisArray(
        fill(0.0, length(1:S), length(1:W)),
        1:S,
        1:W,
    ),
    polyX = JuMP.Containers.DenseAxisArray(
        fill(0.0, length(1:X), length(1:(3+H))),
        1:X,
        1:(3+H),
    ),
)
    model = Model()
    @variable(model, 0 <= xx[w in 1:W, h in 1:H] <= 1)
    @variable(model, 0 <= y[s in 1:S, w in 0:W] <= 1)
    @variable(model, mu[s in 1:S] >= 0)
    @variable(model, eta[w in 1:W] >= 0)
    @constraint(model, simplex[s in 1:S], sum(y[s, w] for w in 0:W) == 1)
    @constraint(
        model,
        testgeq[x in 1:X; polyX[x, 2] == 1],
        sum(polyX[x, 3+h] * xx[round(polyX[x, 1]), h] for h in 1:H) >=
        polyX[x, 3]
    )
    @constraint(
        model,
        testeq[x in 1:X; polyX[x, 2] == 0],
        sum(polyX[x, 3+h] * xx[round(polyX[x, 1]), h] for h in 1:H) ==
        polyX[x, 3]
    )
    @constraint(
        model,
        KKT1[s in 1:S, w in 1:W],
        sum(E[s, w, h] * xx[w, h] for h in 1:H) + mu[s] - R[s, w] +
        2.0 / beta[s] * (y[s, w] - y[s, 0]) ⟂ y[s, w]
    )
    @constraint(model, KKT2[s in 1:S], mu[s] ⟂ y[s, 0])
    @constraint(
        model,
        coupl[w in 1:W],
        eta[w] + sum(y[s, w] for s in 1:S) >= S * alpha[w]
    )
    @objective(
        model,
        Max,
        sum(rho[s] * (R[s, w] - C[s, w]) * y[s, w] for s in 1:S, w in 1:W) -
        sum(rho[s] * 2.0 / beta[s] * y[s, w] ^ 2 for s in 1:S, w in 1:W) +
        sum(rho[s] * (2.0 / beta[s] * y[s, 0] - mu[s]) for s in 1:S) -
        10 * sum(eta[w] for w in 1:W)
    )
    return model
end

function build_model(path::String)
    schema = JuMPConverter.AMPL.DatSchema(
        Dict{Symbol,Int}(
            :S => 0,
            :W => 0,
            :H => 0,
            :X => 0,
            :rho => 1,
            :beta => 1,
            :alpha => 1,
            :E => 3,
            :C => 2,
            :R => 2,
            :polyX => 2,
        ),
    )
    data = if isdir(path)
        JuMPConverter.AMPL.read_csv(path, schema)
    else
        JuMPConverter.AMPL.read_dat(path, schema)
    end
    return build_model(; data...)
end
