function create_agents_and_opts(input_dir::AbstractString, model_data::HEMData, agent_options::AgentOptionsStore, ::HEMOptions{VIU})

    regulator_options = get_agent_option(Regulator, agent_options)
    utility_options = get_agent_option(Utility, agent_options)
    customer_options = get_agent_option(CustomerGroup, agent_options)
    green_developer_options = get_agent_option(GreenDeveloper, agent_options)
    dera_options = get_agent_option(DERAggregator, agent_options)

    regulator = Regulator(input_dir, model_data, regulator_options)
    utility = Utility(input_dir, model_data)
    customers = CustomerGroup(input_dir, model_data)
    green_developer = GreenDeveloper(input_dir, model_data)
    dera = DERAggregator(input_dir, model_data, dera_options)

    # the sequence of simulation matters a lot! (e.g., the year DER aggregation is picked is dependent on this)
    agents_and_opts = [
        AgentAndOptions(utility, utility_options),
        AgentAndOptions(regulator, regulator_options),
        AgentAndOptions(customers, customer_options),
        AgentAndOptions(green_developer, green_developer_options),
        AgentAndOptions(dera, dera_options),
    ]

    return agents_and_opts
end

function create_agents_and_opts(input_dir::AbstractString, model_data::HEMData, agent_options::AgentOptionsStore, ::HEMOptions{WM})

    regulator_options = get_agent_option(Regulator, agent_options)
    ipp_options = get_agent_option(IPPGroup, agent_options)
    customer_options = get_agent_option(CustomerGroup, agent_options)
    green_developer_options = get_agent_option(GreenDeveloper, agent_options)
    dera_options = get_agent_option(DERAggregator, agent_options)

    regulator = Regulator(input_dir, model_data, regulator_options)
    ipp = IPPGroup(input_dir, model_data)
    customers = CustomerGroup(input_dir, model_data)
    green_developer = GreenDeveloper(input_dir, model_data)
    dera = DERAggregator(input_dir, model_data, dera_options)

    # the sequence of simulation matters a lot! (e.g., the year DER aggregation is picked is dependent on this)
    agents_and_opts = [
        AgentAndOptions(ipp, ipp_options),
        AgentAndOptions(regulator, regulator_options),
        AgentAndOptions(customers, customer_options),
        AgentAndOptions(green_developer, green_developer_options),
        AgentAndOptions(dera, dera_options),
    ]

    return agents_and_opts
end

function create_agents_and_opts(input_dir::AbstractString, model_data::HEMData, agent_options::AgentOptionsStore, ::HEMOptions{LocalDistributionAndDER})

    # Need to ensure the order of agents is correct
    rate_maker_options = get_agent_option(LocalDistributionRateMaker, agent_options)
    distribution_utility_options = get_agent_option(DistributionUtility, agent_options)
    customer_options = get_agent_option(LocalDistributionCustomer, agent_options)

    rate_maker = LocalDistributionRateMaker(input_dir, model_data, rate_maker_options)
    distribution_utility = DistributionUtility(input_dir, model_data, distribution_utility_options)
    customers = LocalDistributionCustomer(input_dir, model_data, customer_options)

    agents_and_opts = [
        AgentAndOptions(rate_maker, rate_maker_options),
        AgentAndOptions(customers, customer_options),
        AgentAndOptions(distribution_utility, distribution_utility_options),
    ]
    return agents_and_opts
end

"""
Return the simulation years (as `Int`s) over the full horizon `model_data.index_y_fix`.
"""
get_simulation_years(model_data::HEMData) =
    [Int(model_data.year(y)) for y in model_data.index_y_fix.elements]

"""
Check a requested `end_year` against the simulation years and return the value to use.

- `nothing` -> `nothing` (solve all years)
- `end_year` at or after the last simulation year -> `nothing`, with a log message
  (`@info` if equal, `@warn` if after)
- `end_year` one of the other simulation years -> `end_year`
- otherwise (before the first year, or not a simulation year) -> error
"""
resolve_end_year(end_year::Nothing, sim_years::AbstractVector{<:Integer}) = nothing

function resolve_end_year(end_year::Integer, sim_years::AbstractVector{<:Integer})
    last_year = last(sim_years)
    if end_year == last_year
        @info "end_year = $end_year is the last simulation year; running all years without truncation."
        return nothing
    elseif end_year > last_year
        @warn "end_year = $end_year is after the last simulation year ($last_year); running all years without truncation."
        return nothing
    elseif !(end_year in sim_years)
        error("end_year = $end_year is not one of the simulation years $(sim_years)")
    end
    return Int(end_year)
end

resolve_end_year(end_year, model_data::HEMData) =
    resolve_end_year(end_year, get_simulation_years(model_data))

"""
Return the results directory for a run truncated at `end_year`: `output_dir` with a
`_thru<end_year>` suffix, or `output_dir` unchanged if `end_year` is `nothing`. Trailing
path separators are stripped first, so `"Results/"` becomes `"Results_thru2023"` rather
than a subdirectory.
"""
end_year_output_dir(output_dir::AbstractString, ::Nothing) = output_dir
end_year_output_dir(output_dir::AbstractString, end_year::Integer) =
    rstrip(output_dir, ['/', '\\']) * "_thru$(end_year)"

"""
Solve the problem with the given inputs.

# Arguments
- `input_dir::AbstractString`: Directory containing input data. Outputs will be recorded in
  a subdirectory.
- `options::HEMOptions`:
- `ipp_options::IPPOptions`: Independent Power Producer options. Defaults to NullAgentOptions.
- `regulator_options::RegulatorOptions`: Regulator options. Defaults to NullAgentOptions.
- `utility_options::RegulatorOptions`: Regulator options. Defaults to NullAgentOptions.
- `max_iterations::Int`: Max number of iterations to attempt a solution. Defaults to 100.
- `window_length::Int`:
- `force::Bool`: If true, overwrite results if a directory already exists.
- `jump_model::Any`: Jump model to use for the simulation.
- `output_dir::Union{<:AbstractString, Nothing}`: Directory to save results. If `nothing`, it will be set to
  `input_dir` with a prefix based on the options and agents.
- `delta_t::Int`: Number of hours per representative hour. Defaults to 4.
- `year_start::Int`: The base year for the simulation. Defaults to 2020.
- `end_year::Union{Int, Nothing}`: Last simulation year to solve. If set, the run stops after
  the window starting in `end_year` (results for later years are initial values only) and
  the output directory name (default or user-specified) gets a `_thru<end_year>` suffix. If
  `end_year` is at or after the last simulation year, it is ignored (with a log message) and all
  years are solved. Otherwise it must be one of the simulation years. Defaults to `nothing`
  (solve all years).
"""
function run_hem(
    input_dir::AbstractString,
    options::HEMOptions;
    agent_options::AgentOptionsStore,
    max_iterations=1,
    window_length=1,
    force=false,
    jump_model::Any,
    output_dir::Union{<:AbstractString, Nothing} = nothing,
    delta_t::Int = 4,
    year_start::Int = 2020,
    end_year::Union{Int, Nothing} = nothing,
)
    model_data = HEMData(input_dir;
        year_start=year_start,
        delta_t=delta_t,
        )

    end_year = resolve_end_year(end_year, model_data)

    agents_and_opts = create_agents_and_opts(input_dir, model_data, agent_options, options)

    if isnothing(output_dir)
        output_dir = joinpath(input_dir, get_file_prefix(options, agents_and_opts))
    end
    output_dir = end_year_output_dir(output_dir, end_year)
    
    if isdir(output_dir)
        if force
            rm(output_dir, recursive=true)
        else
            error("$output_dir already exists. Move the existing directory or set force=true to overwrite.")
        end
    end
    mkdir(output_dir)
    logger = configure_logging(
        console_level=Logging.Info,
        file_level=Logging.Info,
        filename=joinpath(output_dir, "run_hem.log"),
    )

    try
        @info "Output directory: $(output_dir)"
        solve_equilibrium_problem!(
            options,
            model_data,
            agents_and_opts,
            output_dir,
            max_iterations,
            window_length,
            jump_model,
            end_year,
        )
    finally
        close(logger)
    end

    return output_dir
end
