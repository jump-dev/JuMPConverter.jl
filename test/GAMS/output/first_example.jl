using JuMP
function build_model()
    model = Model()
    @variable(model, Xcorn >= 0)
    @variable(model, Xwheat >= 0)
    @variable(model, Xcotton >= 0)
    @variable(model, Z)
    @constraint(model, obj, Z == 109 * Xcorn + 90 * Xwheat + 115 * Xcotton)
    @constraint(model, land, Xcorn +      Xwheat +       Xcotton <= 100)
    @constraint(model, labor, 6 * Xcorn +  4 * Xwheat +   8 * Xcotton <= 500)
    @objective(model, Max, Z)
    return model
end
