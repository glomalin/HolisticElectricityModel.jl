# Tests for the `end_year` run-truncation option. These need no solver and no real input data:
# they use the minimal HEMData fixture in test/data/hem_data_minimal (simulation years
# 2021-2023) and a dummy agent that only records which years it was asked to solve.

using Test
using Logging
using HolisticElectricityModel
const HEM = HolisticElectricityModel

const END_YEAR_DATA_DIR = joinpath(@__DIR__, "data", "hem_data_minimal")

"Dummy agent that records the simulation year of every solve_agent_problem! call."
struct YearRecorder <: HEM.AbstractAgent
    years::Vector{Int}
end
YearRecorder() = YearRecorder(Int[])

HEM.get_id(::YearRecorder) = "year_recorder"

function HEM.solve_agent_problem!(
    agent::YearRecorder,
    agent_opts::HEM.AgentOptions,
    model_data::HEMData,
    hem_opts::HEMOptions,
    agent_store::HEM.AgentStore,
    w_iter,
    window_length,
    jump_model,
    export_file_path,
    update_results::Bool,
    output_intermediate_results::Bool,
)
    reg_year, _ = HEM.get_reg_year(model_data)
    push!(agent.years, Int(reg_year))
    return 0.0  # converged immediately
end

"Run the equilibrium loop with a YearRecorder and return the years it solved."
function solved_years(end_year)
    model_data = HEMData(END_YEAR_DATA_DIR)  # fresh each time: the loop mutates index_y
    agent = YearRecorder()
    agents_and_opts = HEM.AgentAndOptions[HEM.AgentAndOptions(agent, HEM.NullAgentOptions())]
    hem_opts = HEMOptions(VIU(), DERAdoption(), NullUseCase(), NullUseCase())
    mktempdir() do export_dir
        solve_equilibrium_problem!(
            hem_opts, model_data, agents_and_opts, export_dir,
            1,   # max_iter
            1,   # window_length
            [],  # jump_model
            end_year,
        )
    end
    return agent.years
end

@testset "end_year" begin
    # the loop stops after end_year
    @test solved_years(nothing) == [2021, 2022, 2023]
    @test solved_years(2022) == [2021, 2022]

    # end_year at or after the last simulation year is ignored; before the first is an error
    sim_years = [2021, 2022, 2023]
    @test (@test_logs (:info,) HEM.resolve_end_year(2023, sim_years)) === nothing
    @test (@test_logs (:warn,) HEM.resolve_end_year(2030, sim_years)) === nothing
    @test_throws ErrorException HEM.resolve_end_year(2020, sim_years)

    # output dir suffix, without creating a subdirectory from a trailing separator
    @test HEM.end_year_output_dir("Results/", 2022) == "Results_thru2022"
end
