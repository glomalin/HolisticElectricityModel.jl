# solve_equilibrium_problem! should fail before any agent is solved, naming the agent, when
# an agent has no solve_agent_problem! method for the given options. Uses the minimal HEMData
# fixture.

using Test
using HolisticElectricityModel
const HEM = HolisticElectricityModel

"Well-formed dummy agent that counts its solve_agent_problem! calls."
struct CountingAgent <: HEM.AbstractAgent
    calls::Base.RefValue{Int}
end
HEM.get_id(::CountingAgent) = "counting_agent"
function HEM.solve_agent_problem!(agent::CountingAgent, opts::HEM.AgentOptions, model_data::HEMData,
        hem_opts::HEMOptions, store::HEM.AgentStore, w_iter, window_length, jump_model,
        export_file_path, update_results::Bool, output_intermediate_results::Bool)
    agent.calls[] += 1
    return 0.0
end

"Dummy agent with no solve_agent_problem! method."
struct AgentWithoutMethod <: HEM.AbstractAgent end
HEM.get_id(::AgentWithoutMethod) = "agent_without_method"

@testset "check_agent_methods" begin
    model_data = HEMData(joinpath(@__DIR__, "data", "hem_data_minimal"))
    good = CountingAgent(Ref(0))
    # the well-formed agent comes first, so without an up-front check it would be solved
    # before the run reached the agent without a method
    agents_and_opts = HEM.AgentAndOptions[
        HEM.AgentAndOptions(good, HEM.NullAgentOptions()),
        HEM.AgentAndOptions(AgentWithoutMethod(), HEM.NullAgentOptions()),
    ]
    hem_opts = HEMOptions(VIU(), DERAdoption(), SupplyChoice(), NullUseCase())
    err = mktempdir() do export_dir
        try
            solve_equilibrium_problem!(hem_opts, model_data, agents_and_opts, export_dir, 1, 1, [])
            nothing
        catch e
            e
        end
    end
    @test err isa ErrorException
    @test occursin("AgentWithoutMethod", sprint(showerror, err))
    @test good.calls[] == 0  # failed before any agent was solved
end
