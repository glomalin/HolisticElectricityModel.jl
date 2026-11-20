abstract type HEMSolver end

function make_jump_model(attributes::MOI.OptimizerWithAttributes)
    model = Model()
    JuMP.set_optimizer(model, attributes)
    return model
end

struct AnySolver <: HEMSolver
    attributes::MOI.OptimizerWithAttributes
end

get_new_jump_model(hem_solver::AnySolver) = make_jump_model(hem_solver.attributes)

"""
Construct an Ipopt optimizer. Use default settings or pass an MOI.OptimizerWithAttributes
instance.

If using the default settings, call `import_ipopt()` first. Ipopt must be installed.

# Examples
```
julia> import_ipopt()
julia> hem_solver = IpoptSolver()

julia> import Ipopt
julia> import JuMP
julia> ipopt = JuMP.optimizer_with_attributes(Ipopt.Optimizer, "tol" => 1e-6, "print_level" => 0)
julia> solver = IpoptSolver(ipopt)
```
"""
struct IpoptSolver <: HEMSolver
    attributes::Union{Nothing,MOI.OptimizerWithAttributes}

    IpoptSolver(attributes=nothing) = new(attributes)
end


function get_new_jump_model(hem_solver::IpoptSolver)
    isnothing(hem_solver.attributes) && return Model(_get_ipopt())
    make_jump_model(hem_solver.attributes)
end

function import_ipopt()
    try
        @eval Main begin
            import Ipopt
        end
    catch
        error("The Ipopt optimizer must be installed.")
    end
end

function _get_ipopt()
    @eval Main begin
        import Ipopt
        return Ipopt.Optimizer
    end
end

function _initialize_optimizer_ipopt()
    @eval Main begin
        import Ipopt
        return Ipopt.Optimizer()
    end
end

function addsolvers_ipp!(ipp_solvers::Dict,solver_name::Val{:Ipopt})
    ipp_solvers["Lagrange_Sub_Investment_Retirement_Cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "print_level" => 0,
        # "tol" => 1e-6,
        # "max_iter" => 500,
    )
end


"""
Construct an Xpress optimizer. Use default settings or pass an MOI.OptimizerWithAttributes
instance.

If using the default settings, call `import_xpress()` first. Xpress must be installed.

# Examples
```
julia> import_xpress()
julia> hem_solver = XpressSolver()

julia> import Xpress
julia> import JuMP
julia> xpress = JuMP.optimizer_with_attributes(
    Xpress.Optimizer,
    "MIPRELSTOP" => 0.01,
    "OUTPUTLOG" => 1,
)
julia> solver = XpressSolver(xpress)
```
"""
struct XpressSolver <: HEMSolver
    attributes::Union{Nothing,MOI.OptimizerWithAttributes}

    XpressSolver(attributes=nothing) = new(attributes)
end

function get_new_jump_model(hem_solver::XpressSolver)
    isnothing(hem_solver.attributes) && return Model(_get_xpress())
    make_jump_model(hem_solver.attributes)
end

function import_xpress()
    try
        @eval Main begin
            import Xpress
        end
    catch
        error("The Xpress optimizer must be installed.")
    end
end

function _get_xpress()
    @eval Main begin
        import Xpress
        return Xpress.Optimizer
    end
end

function _initialize_optimizer_xpress()
    @eval Main begin
        import Xpress
        return Xpress.Optimizer()
    end
end

function addsolvers_ipp!(ipp_solvers::Dict,solver_name::Val{:Xpress})
    ipp_solvers["Lagrange_Sub_Dispatch_Cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["Lagrange_Feasible_Cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name)
    )
    ipp_solvers["solve_agent_problem_ipp_cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "Presolve" => 1,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "Aggregate" => 0,
        # "Presolve" => 0,
        # "BarHomogeneous" => 1,
        # "FeasibilityTol" => 1e-3,
        # "Method" => 1
        # "NumericFocus" => 3,
        # "ScaleFlag" => 2,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc_mccormic_lower"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "Presolve" => 1,
        # "BarHomogeneous" => 1,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc_mccormic_lower_presolve"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "Presolve" => 1,
        # "BarHomogeneous" => 1,
        # "OUTPUTLOG" => 0,
    )
end


"""
Construct an Gurobi optimizer. Use default settings or pass an MOI.OptimizerWithAttributes
instance.

If using the default settings, call `import_gurobi()` first. Gurobi must be installed.

# Examples
```
julia> import_gurobi()
julia> hem_solver = GurobiSolver()

julia> import Gurobi
julia> import JuMP
julia> gurobi = JuMP.optimizer_with_attributes(
    () -> Gurobi.Optimizer(Gurobi.Env()),
    "MIPFocus" => 3,
)
julia> solver = GurobiSolver(gurobi)
```
"""
struct GurobiSolver <: HEMSolver
    env::Any
    attributes::Union{Nothing,MOI.OptimizerWithAttributes}

    GurobiSolver(env, attributes=nothing) = new(GurobiSolver(env, attributes))
end

function get_new_jump_model(hem_solver::GurobiSolver)
    isnothing(hem_solver.attributes) && return Model(() -> _get_gurobi()(hem_solver.env))
    model = Model()
    make_jump_model(hem_solver.attributes)
end

function import_gurobi()
    try
        @eval Main begin
            import Gurobi
            return Gurobi.Env()
        end
    catch
        error("The Gurobi optimizer must be installed.")
    end
end

function _get_gurobi()
    @eval Main begin
        import Gurobi
        return Gurobi.Optimizer
    end
end

"""
Gurobi parameters applied to every Gurobi optimizer HEM creates. Parameters set explicitly
for a particular model (e.g. via `JuMP.optimizer_with_attributes` in `addsolvers_ipp!`) are
applied afterwards and take precedence.

- `Method = 4` (deterministic concurrent): Gurobi's default for LPs is non-deterministic
  concurrent (`Method = 3`), a race between simplex and barrier whose winner, and hence the
  optimal basis returned for degenerate problems, can change from run to run. That made
  identical HEM runs give different prices and downstream results.
- `Threads`: set with `set_solver_threads!` (e.g. from `SimulationParameters.solver_threads`)
  so runs use the same thread count regardless of how many cores the node has.

See https://docs.gurobi.com/projects/optimizer/en/11.0/features/concurrent.html#determinism
"""
const GUROBI_PARAMS = Dict{String, Any}("Method" => 4)

"""
Fix the number of solver threads for all subsequently created optimizers (currently applied
to Gurobi only). Pass `nothing` to use the solver's default.
"""
function set_solver_threads!(threads::Union{Integer, Nothing})
    if isnothing(threads)
        delete!(GUROBI_PARAMS, "Threads")
    else
        threads >= 1 || error("threads must be >= 1, got $threads")
        GUROBI_PARAMS["Threads"] = Int(threads)
    end
    return
end

function _initialize_optimizer_gurobi()
    optimizer = @eval Main begin
        import Gurobi
        if !(@isdefined GUROBI_ENV)
            const global GUROBI_ENV = Gurobi.Env()
        end
        Gurobi.Optimizer(GUROBI_ENV)
    end
    for (name, value) in GUROBI_PARAMS
        MOI.set(optimizer, MOI.RawOptimizerAttribute(name), value)
    end
    return optimizer
end

function addsolvers_ipp!(ipp_solvers::Dict,solver_name::Val{:Gurobi})
    ipp_solvers["Lagrange_Sub_Dispatch_Cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["Lagrange_Feasible_Cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "Presolve" => 0,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_cap"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "Presolve" => 1,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "Aggregate" => 0,
        # "Presolve" => 0,
        "BarHomogeneous" => 1,
        # "FeasibilityTol" => 1e-3,
        # "Method" => 1
        "NumericFocus" => 3,
        "ScaleFlag" => 2,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc_mccormic_lower"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "Presolve" => 0,
        "BarHomogeneous" => 1,
        # "OUTPUTLOG" => 0,
    )
    ipp_solvers["solve_agent_problem_ipp_mppdc_mccormic_lower_presolve"] = JuMP.optimizer_with_attributes(
        () -> get_optimizer_for_solver(solver_name),
        "Presolve" => 1,
        "BarHomogeneous" => 1,
        # "OUTPUTLOG" => 0,
    )
end


import_solver_package(solver_name::Symbol) = import_solver_package(Val{solver_name}())

import_solver_package(solver_name::Val{:Ipopt}) = import_ipopt()
import_solver_package(solver_name::Val{:Xpress}) = import_xpress()
import_solver_package(solver_name::Val{:Gurobi}) = import_gurobi()

get_optimizer_for_solver(solver_name::Symbol) = get_optimizer_for_solver(Val{solver_name}())

get_optimizer_for_solver(solver_name::Val{:Ipopt}) = _initialize_optimizer_ipopt()
get_optimizer_for_solver(solver_name::Val{:Xpress}) = _initialize_optimizer_xpress()
get_optimizer_for_solver(solver_name::Val{:Gurobi}) = _initialize_optimizer_gurobi()

addsolvers_ipp!(ipp_solvers::Dict, solver_name::Symbol) = addsolvers_ipp!(ipp_solvers, Val{solver_name}())
