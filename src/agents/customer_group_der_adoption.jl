# CustomerGroup DER-adoption step.
#
# `solve_der_adoption!` is called by `solve_agent_problem!(::CustomerGroup, ...)` before the
# supply-choice step. It dispatches on the der_use_case type parameter of HEMOptions, and
# `choose_der_builds!` dispatches on the CustomerOptions PV adoption type. Returns a vector of
# (before, after) pairs for the convergence check.

solve_der_adoption!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions{<:MarketStructure, NullUseCase},
    agent_store::AgentStore,
    w_iter,
) = []

function solve_der_adoption!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions{<:MarketStructure, DERAdoption},
    agent_store::AgentStore,
    w_iter,
)
    # the year consumer is making DER investment decision
    reg_year, reg_year_index = get_reg_year(model_data)

    x_DG_before = ParamArray(customers.x_DG_new, "x_DG_before")
    fill!(x_DG_before, NaN)
    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        x_DG_before(h, z, m, :) .= customers.x_DG_new_my(reg_year_index, h, z, m)
    end

    load_annual_der_params!(customers, model_data, w_iter)
    choose_der_builds!(customers, customer_opts, model_data, hem_opts, agent_store, w_iter)

    return [(x_DG_before, customers.x_DG_new)]
end

"""
Update the annual DER parameters to the solve year (so we don't have to change the majority
of the functions), including existing DER capacity x_DG_E. Annual load data are updated by
`load_annual_customer_params!`.
"""
function load_annual_der_params!(customers::CustomerGroup, model_data::HEMData, w_iter)
    reg_year, reg_year_index = get_reg_year(model_data)
    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        customers.Opti_DG(z, h, m, :) .= customers.Opti_DG_my(reg_year_index, z, h, m)
        customers.FOM_DG(z, h, m, :) .= customers.FOM_DG_my(reg_year_index, z, h, m)
        customers.CapEx_DG(z, h, m, :) .= customers.CapEx_DG_my(reg_year_index, z, h, m)
        customers.ITC_DER(m, :) .= customers.ITC_DER_my(reg_year_index, m)
        if w_iter >= 2
            customers.x_DG_E(h, z, m, :) .=
                customers.x_DG_E_my(reg_year_index, h, z, m) + sum(
                    customers.x_DG_new_my(Symbol(Int(y)), h, z, m) for
                    y in model_data.year(first(model_data.index_y_fix)):(reg_year - 1)
                )
        else
            customers.x_DG_E(h, z, m, :) .= customers.x_DG_E_my(reg_year_index, h, z, m)
        end
    end
end

"""
Value of standalone DER technology `m` (energy savings/credit per representative agent at
the optimal DER size, net of fixed O&M), valuing self-consumption at the retail rate `p` and
excess generation at `p_ex`.
"""
function standalone_der_savings(customers::CustomerGroup, regulator::Regulator, utility_or_ipp,
        model_data::HEMData, z::Symbol, h::Symbol, m::Symbol)
    delta_t = model_data.delta_t.value
    return (
        # value of distributed generation (offset load)
        sum(
            model_data.omega(d) * delta_t *
            regulator.p(z, h, d, t) *
            min(
                customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist),
                customers.rho_DG(h, m, z, d, t) * customers.Opti_DG(z, h, m),
            ) for d in model_data.index_d, t in model_data.index_t
        ) +
        # value of distributed generation (excess generation)
        sum(
            model_data.omega(d) * delta_t *
            regulator.p_ex(z, h, d, t) *
            max(
                0,
                customers.rho_DG(h, m, z, d, t) * customers.Opti_DG(z, h, m) -
                customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist),
            ) for d in model_data.index_d, t in model_data.index_t
        )
    )
end

############ Standalone PV adoption ############

function choose_der_builds!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions{StandalonePVOnly},
    model_data::HEMData,
    hem_opts::HEMOptions,
    agent_store::AgentStore,
    w_iter,
)
    regulator = get_agent(Regulator, agent_store)
    utility_or_ipp = get_bulk_system_agent(agent_store, hem_opts)
    reg_year, reg_year_index = get_reg_year(model_data)
    adopt_model = customers.pv_adoption_model

    # Calculate payback period of DER
    # The NetProfit represents the energy saving/credit per representative agent per DER technology, assuming the optimal DER technology size
    NetProfit = make_keyed_array(model_data.index_z, model_data.index_h, customers.index_m)
    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        NetProfit(z, h, m, :) .=
            standalone_der_savings(customers, regulator, utility_or_ipp, model_data, z, h, m) -
            # cost of distributed generation
            customers.FOM_DG(z, h, m) * customers.Opti_DG(z, h, m)
    end

    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        if NetProfit(z, h, m) >= 0.0
            customers.Payback(z, h, m, :) .= (
                (1.0 - customers.ITC_DER(m)) * customers.CapEx_DG(z, h, m) *
                customers.Opti_DG(z, h, m)) / NetProfit(z, h, m)
            # Calculate maximum market share and maximum DG potential (based on WTP curve)
            customers.MarketShare(z, h, m, :) .= get_max_market_share(
                adopt_model,
                customers.Payback,
                z, h, m;
                payback_by_m = true,
            )
            customers.MaxDG(z, h, m, :) .=
                customers.MarketShare(z, h, m) * customers.gamma(z, h) * customers.Opti_DG(z, h, m)
            # Calculate the percentage of existing DER (per agent type per DER technology) as a fraction of maximum DG potential
            customers.F(z, h, m, :) .= min(customers.x_DG_E(h, z, m) / customers.MaxDG(z, h, m), 1.0)
            # Calculate incremental DG build
            customers.A(z, h, m, :) .= get_incremental_build_frac(
                adopt_model,
                customers.F,
                z, h, m;
                exist_pv_frac_by_m = true,
            )
            customers.x_DG_new(h, z, m, :) .=
                max(0.0, customers.A(z, h, m) * customers.MaxDG(z, h, m) - customers.x_DG_E(h, z, m))
        else
            customers.x_DG_new(h, z, m, :) .= 0.0
        end
    end

    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        customers.x_DG_new_my(reg_year_index, h, z, m, :) .= customers.x_DG_new(h, z, m)
        customers.MaxDG_my(reg_year_index, z, h, m, :) .= customers.MaxDG(z, h, m)
    end
end

############ BTM PV+Storage adoption ############

const PVStorCustomerOptions = Union{CustomerOptions{SolarPlusStorageOnly}, CustomerOptions{CompeteDERConfigs}}

function choose_der_builds!(
    customers::CustomerGroup,
    customer_opts::PVStorCustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions,
    agent_store::AgentStore,
    w_iter,
)
    regulator = get_agent(Regulator, agent_store)
    utility_or_ipp = get_bulk_system_agent(agent_store, hem_opts)
    der_aggregator = get_agent(DERAggregator, agent_store)

    reg_year, reg_year_index = get_reg_year(model_data)
    delta_t = model_data.delta_t.value
    # the year the aggregator decided on incentive levels
    reg_year_dera, reg_year_index_dera = get_prev_reg_year(model_data, w_iter)

    # Calculate payback period of DER
    # The NetProfit represents the energy saving/credit per representative agent for optimally operated PV+storage, assuming the optimal DER technology size
    Payment_before_PVStor = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        Payment_before_PVStor(z, h, :) .=
            sum(
                model_data.omega(d) * delta_t *
                regulator.p(z, h, d, t) *
                customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist) for d in model_data.index_d, t in model_data.index_t
            )
    end

    Payment_after_PVStor = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        Payment_after_PVStor(z, h, :) .= solve_btm_storage_dispatch!(
            customers, customer_opts, regulator, utility_or_ipp, model_data, z, h, reg_year_index)
    end

    NetProfit_pv_stor = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        NetProfit_pv_stor(z, h, :) .= 
            # revenue of pv+storage, accounting for revenues from der aggregator (probablity weighted)
            # assume der_aggregator.aggregation_level = 10%, then 10% of revenues will come from DER aggregation incentive and 90% of revenues will come from electricity bill cost savings
            (Payment_before_PVStor(z, h) - Payment_after_PVStor(z, h)) * (1 - der_aggregator.aggregation_level(reg_year_index_dera, z)) + 
            der_aggregator.incentive_level(reg_year_index_dera, z) * customers.Opti_DG(z, h, :BTMStorage) * der_aggregator.aggregation_level(reg_year_index_dera, z) -
            # cost of distributed generation 
            sum(customers.FOM_DG(z, h, m) * customers.Opti_DG(z, h, m) for m in customers.index_m)
    end    

    # Calculate payback period of DPV-only
    # The NetProfit represents the energy saving/credit per representative agent per DER technology, 
    # assuming the optimal DER technology size
    Payment_after_PVOnly = make_keyed_array(model_data.index_z, model_data.index_h)
    NetProfit_PV_only = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        pvonly_savings = standalone_der_savings(customers, regulator, utility_or_ipp, model_data, z, h, :BTMPV)
        Payment_after_PVOnly(z, h, :) .= Payment_before_PVStor(z, h) - pvonly_savings
        NetProfit_PV_only(z, h, :) .= pvonly_savings -
            # cost of distributed generation 
            customers.FOM_DG(z, h, :BTMPV) * customers.Opti_DG(z, h, :BTMPV)
    end

    # Save financial results
    for (z, h) in model_data.index_z_h_map
        customers.Payment_before_PVStor_my(reg_year_index, z, h, :) .= Payment_before_PVStor(z, h)
        customers.Payment_after_PVStor_my(reg_year_index, z, h, :) .= Payment_after_PVStor(z, h)
        customers.PVStor_DERA_incentive_my(reg_year_index, z, h, :) .= der_aggregator.incentive_level(reg_year_index_dera, z) * customers.Opti_DG(z, h, :BTMStorage)
        customers.PVStor_FOM_my(reg_year_index, z, h, :) .=  sum(customers.FOM_DG(z, h, m) * customers.Opti_DG(z, h, m) for m in customers.index_m)
        customers.NetProfit_PVStor_my(reg_year_index, z, h, :) .= NetProfit_pv_stor(z, h)
    
        customers.Payment_after_PVOnly_my(reg_year_index, z, h, :) .= Payment_after_PVOnly(z, h)
        customers.PVOnly_FOM_my(reg_year_index, z, h, :) .= customers.FOM_DG(z, h, :BTMPV) * customers.Opti_DG(z, h, :BTMPV)
        customers.NetProfit_PVOnly_my(reg_year_index, z, h, :) .= NetProfit_PV_only(z, h)

        customers.FinalCapEx_PVStor_my(reg_year_index, z, h, :) .= sum(
            (1.0 - customers.ITC_DER(m)) * customers.CapEx_DG(z, h, m) * customers.Opti_DG(z, h, m) 
            for m in customers.index_m
        )
        customers.FinalCapEx_PVOnly_my(reg_year_index, z, h, :) .= (
            (1.0 - customers.ITC_DER(:BTMPV)) * customers.CapEx_DG(z, h, :BTMPV) * 
            customers.Opti_DG(z, h, :BTMPV)
        )
    end

    for (z, h) in model_data.index_z_h_map
        select_der_config!(customers, customer_opts, NetProfit_pv_stor, NetProfit_PV_only, model_data, reg_year, z, h)
    end

    for (z, h) in model_data.index_z_h_map, m in customers.index_m
        customers.x_DG_new_my(reg_year_index, h, z, m, :) .= customers.x_DG_new(h, z, m)
        update_total_capacity!(customers.total_der_capacity_my, customers.x_DG_new, model_data, reg_year, z, h, m)
    end

    update_btm_storage_rho!(customers, model_data, reg_year_index)
end

"""
Solve the representative customer's optimal BTM PV+storage dispatch for zone `z` and customer
group `h`, store the dispatch results for `reg_year_index`, and return the resulting
electricity payment.
"""
function solve_btm_storage_dispatch!(
    customers::CustomerGroup,
    customer_opts::PVStorCustomerOptions,
    regulator::Regulator,
    utility_or_ipp,
    model_data::HEMData,
    z::Symbol,
    h::Symbol,
    reg_year_index::Symbol,
)
    delta_t = model_data.delta_t.value

    Customer_PV_Storage_Opti = get_new_jump_model(customer_opts.solvers)

    # units in MWh
    @variable(Customer_PV_Storage_Opti, net_load[model_data.index_d, model_data.index_t])
    @variable(Customer_PV_Storage_Opti, net_load_plus[model_data.index_d, model_data.index_t] >= 0)
    @variable(Customer_PV_Storage_Opti, net_load_minus[model_data.index_d, model_data.index_t] <= 0)
    @variable(Customer_PV_Storage_Opti, stor_charge[model_data.index_d, model_data.index_t] >= 0)
    @variable(Customer_PV_Storage_Opti, stor_discharge[model_data.index_d, model_data.index_t] >= 0)
    @variable(Customer_PV_Storage_Opti, stor_energy[model_data.index_d, model_data.index_t] >= 0)
    @variable(Customer_PV_Storage_Opti, net_load_sign[model_data.index_d, model_data.index_t], Bin)

    objective_function_dist = begin
        sum(
            model_data.omega(d) * delta_t *
            regulator.p(z, h, d, t) *
            net_load_plus[d, t] + 
            model_data.omega(d) * delta_t *
            regulator.p_ex(z, h, d, t) *
            net_load_minus[d, t] for d in model_data.index_d, t in model_data.index_t
        )
    end
    @objective(Customer_PV_Storage_Opti, Min, objective_function_dist)

    # for net load balance constraints, need to convert things to kWh, otherwise customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist) and 
    net_load_balance = 
        (d, t) -> begin
            (net_load[d, t] - customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist) 
                        + customers.rho_DG(h, :BTMPV, z, d, t) * customers.Opti_DG(z, h, :BTMPV) 
                        - stor_charge[d, t] + stor_discharge[d, t])
        end

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_balance[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load_balance(d, t) == 0.0
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_plus[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load_plus[d, t] >= net_load[d, t]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_balance_plus_minus[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load[d, t] == net_load_plus[d, t] + net_load_minus[d, t]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_minus[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load_minus[d, t] <= net_load[d, t]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_plus_bigm[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load_plus[d, t] <= customers.BIGM * net_load_sign[d, t]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_net_load_minus_bigm[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        net_load_minus[d, t] >= -customers.BIGM * (1 - net_load_sign[d, t])
    )

    discharged_energy = (d, t) -> customers.rte_dist_stor(z, h) > 0.0 ? stor_discharge[d, t] / customers.rte_dist_stor(z, h) * delta_t : 0.0

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_energy_balance[
            d in model_data.index_d,
            t in model_data.index_t.elements[2:end],
        ],
        stor_energy[d, t] == stor_energy[d, model_data.index_t.elements[findall(x -> x == (model_data.time(t)-delta_t), model_data.time.values)][1]]
            - discharged_energy(d, t) +
            + stor_charge[d, t] * delta_t
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_energy_balance_0[
            d in model_data.index_d,
            t in [model_data.index_t.elements[1]],
        ],
        stor_energy[d, t] == customers.initial_energy_dist_stor(z, h, d) - discharged_energy(d, t) + stor_charge[d, t] * delta_t
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_energy_upper_bound[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        stor_energy[d, t] <= customers.duration_dist_stor(z, h) * customers.Opti_DG(z, h, :BTMStorage) 
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_discharge_upper_bound[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        stor_discharge[d, t] <= customers.rte_dist_stor(z, h) * customers.Opti_DG(z, h, :BTMStorage)
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_charge_upper_bound[
            d in model_data.index_d,
            t in model_data.index_t,
        ],
        stor_charge[d, t] <= customers.Opti_DG(z, h, :BTMStorage)
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_discharge_energy_upper_bound[
            d in model_data.index_d,
            t in model_data.index_t.elements[2:end],
        ],
        stor_discharge[d, t] * delta_t <= 
        stor_energy[d, model_data.index_t.elements[findall(x -> x == (model_data.time(t)-delta_t), model_data.time.values)][1]]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_discharge_energy_upper_bound_0[
            d in model_data.index_d,
            t in [model_data.index_t.elements[1]],
        ],
        stor_discharge[d, t] * delta_t <= customers.initial_energy_dist_stor(z, h, d)
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_charge_energy_upper_bound[
            d in model_data.index_d,
            t in model_data.index_t.elements[2:end],
        ],
        stor_charge[d, t] * delta_t <= customers.duration_dist_stor(z, h) * customers.Opti_DG(z, h, :BTMStorage) -
        stor_energy[d, model_data.index_t.elements[findall(x -> x == (model_data.time(t)-delta_t), model_data.time.values)][1]]
    )

    @constraint(
        Customer_PV_Storage_Opti,
        Eq_stor_charge_energy_upper_bound_0[
            d in model_data.index_d,
            t in [model_data.index_t.elements[1]],
        ],
        stor_charge[d, t] * delta_t <= customers.duration_dist_stor(z, h) * customers.Opti_DG(z, h, :BTMStorage) -
        customers.initial_energy_dist_stor(z, h, d)
    )

    # @constraint(
    #     Customer_PV_Storage_Opti,
    #     Eq_stor_charge_discharge_upper_bound[
    #         d in model_data.index_d,
    #         t in model_data.index_t.elements,
    #     ],
    #     stor_charge[d, t] + stor_discharge[d, t] / customers.rte_dist_stor(z, h) <= 
    #     customers.Opti_DG(z, h, :BTMStorage)
    # )

    TimerOutputs.@timeit HEM_TIMER "optimize! Customer BTM storage dispatch" begin
        optimize!(Customer_PV_Storage_Opti)
    end

    # push!(jump_model, Customer_PV_Storage_Opti)

    if (termination_status(Customer_PV_Storage_Opti) != OPTIMAL)
        error("customer problem is not solved")
    end

    payment_after = objective_value(Customer_PV_Storage_Opti)

    for d in model_data.index_d, t in model_data.index_t
        customers.net_load(reg_year_index, z, h, d, t, :) .= value.(net_load[d, t])
        customers.net_load_plus(reg_year_index, z, h, d, t, :) .= value.(net_load_plus[d, t])
        customers.net_load_minus(reg_year_index, z, h, d, t, :) .= value.(net_load_minus[d, t])
        customers.stor_charge(reg_year_index, z, h, d, t, :) .= value.(stor_charge[d, t])
        customers.stor_discharge(reg_year_index, z, h, d, t, :) .= value.(stor_discharge[d, t])
        customers.stor_energy(reg_year_index, z, h, d, t, :) .= value.(stor_energy[d, t])
    end

    return payment_after
end

"""
Fraction of storage capacity discharged (net of charging) in each hour, used as the storage
"generation profile" by other agents.
"""
function update_btm_storage_rho!(customers::CustomerGroup, model_data::HEMData, reg_year_index::Symbol)
    for (z, h) in model_data.index_z_h_map, d in model_data.index_d, t in model_data.index_t
        if customers.Opti_DG(z, h, :BTMStorage) == 0.0
            customers.rho_DG(h, :BTMStorage, z, d, t, :) .= 0.0
        else
            customers.rho_DG(h, :BTMStorage, z, d, t, :) .= (customers.stor_discharge(reg_year_index, z, h, d, t) - customers.stor_charge(reg_year_index, z, h, d, t)) / customers.Opti_DG(z, h, :BTMStorage)
            customers.rho_DG_my(reg_year_index, h, :BTMStorage, z, d, t, :) .= customers.rho_DG(h, :BTMStorage, z, d, t, :)
        end
    end
end

"""
Adopt solar plus storage for (z, h) based on `payback` (indexed by (z, h)): PV adoption from
the Bass diffusion model, with storage built in proportion to the optimal storage:PV ratio.
"""
function adopt_pv_stor!(customers::CustomerGroup, payback::ParamArray, model_data::HEMData, reg_year, z::Symbol, h::Symbol)
    adopt_model = customers.pv_adoption_model
    # Calculate maximum market share and maximum DG potential (based on WTP curve)
    customers.MarketShare_pv_stor(z, h, :) .= get_max_market_share(adopt_model, payback, z, h, :BTMPV)
    customers.MaxDG_pv(z, h, :) .=
        customers.MarketShare_pv_stor(z, h) * customers.gamma(z, h) * customers.Opti_DG(z, h, :BTMPV)
    # Calculate the percentage of existing DER (per agent type per DER technology) as a fraction of maximum DG potential
    customers.F_pv(z, h, :) .= min(customers.x_DG_E(h, z, :BTMPV) / customers.MaxDG_pv(z, h), 1.0)
    # Calculate incremental DG build
    customers.A_pv(z, h, :) .= get_incremental_build_frac(adopt_model, customers.F_pv, z, h, :BTMPV)
    # calculate dpv adoption, then get storage adoption by 
    # multiplying the ratio of distributed storage to dpv to dpv adoption
    customers.x_DG_new(h, z, :BTMPV, :) .=
        max(0.0, customers.A_pv(z, h) * customers.MaxDG_pv(z, h) - customers.x_DG_E(h, z, :BTMPV))
    customers.x_DG_new(h, z, :BTMStorage, :) .=
        customers.x_DG_new(h, z, :BTMPV) * customers.Opti_DG(z, h, :BTMStorage) / customers.Opti_DG(z, h, :BTMPV)

    update_total_capacity_pv_stor_builds!(customers, model_data, reg_year, z, h)
end

"""
Adopt standalone PV for (z, h) based on `payback` (indexed by (z, h)), using the Bass
diffusion model. No storage is built.
"""
function adopt_pv_only!(customers::CustomerGroup, payback::ParamArray, model_data::HEMData, reg_year, z::Symbol, h::Symbol)
    adopt_model = customers.pv_adoption_model
    # Calculate maximum market share and maximum DG potential (based on WTP curve)
    customers.MarketShare_pv_only(z, h, :) .= get_max_market_share(adopt_model, payback, z, h, :BTMPV)
    customers.MaxDG_pv(z, h, :) .=
        customers.MarketShare_pv_only(z, h) * customers.gamma(z, h) * customers.Opti_DG(z, h, :BTMPV)
    # Calculate the percentage of existing DER (per agent type per DER technology) as a fraction of maximum DG potential
    customers.F_pv(z, h, :) .= min(customers.x_DG_E(h, z, :BTMPV) / customers.MaxDG_pv(z, h), 1.0)
    # Calculate incremental DG build
    customers.A_pv(z, h, :) .= get_incremental_build_frac(adopt_model, customers.F_pv, z, h, :BTMPV)
    customers.x_DG_new(h, z, :BTMPV, :) .=
        max(0.0, customers.A_pv(z, h) * customers.MaxDG_pv(z, h) - customers.x_DG_E(h, z, :BTMPV))
    customers.x_DG_new(h, z, :BTMStorage, :) .= 0.0

    update_total_capacity_pv_only_builds!(customers, model_data, reg_year, z, h)
end

"No DER built for (z, h)."
function adopt_nothing!(customers::CustomerGroup, model_data::HEMData, reg_year, z::Symbol, h::Symbol)
    customers.x_DG_new(h, z, :BTMPV, :) .= 0.0
    customers.x_DG_new(h, z, :BTMStorage, :) .= 0.0
    # which function we call doesn't matter since x_DG_new is 0.0
    update_total_capacity_pv_stor_builds!(customers, model_data, reg_year, z, h)
end

"Total installed cost of the DER configuration (after ITC) divided by its annual net profit."
function payback_pv_stor(customers::CustomerGroup, net_profit, z::Symbol, h::Symbol)
    return sum(
        (1.0 - customers.ITC_DER(m)) * customers.CapEx_DG(z, h, m) * customers.Opti_DG(z, h, m)
        for m in customers.index_m) / net_profit
end

function payback_pv_only(customers::CustomerGroup, net_profit, z::Symbol, h::Symbol)
    return (
        (1.0 - customers.ITC_DER(:BTMPV)) * customers.CapEx_DG(z, h, :BTMPV) *
        customers.Opti_DG(z, h, :BTMPV)) / net_profit
end

function select_der_config!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions{SolarPlusStorageOnly},
    NetProfit_pv_stor, NetProfit_PV_only,
    model_data::HEMData, reg_year, z::Symbol, h::Symbol,
)
    if NetProfit_pv_stor(z, h) > 0.0
        customers.Payback_pv_stor(z, h, :) .= payback_pv_stor(customers, NetProfit_pv_stor(z, h), z, h)
        adopt_pv_stor!(customers, customers.Payback_pv_stor, model_data, reg_year, z, h)
    else
        adopt_nothing!(customers, model_data, reg_year, z, h)
    end
end

function select_der_config!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions{CompeteDERConfigs},
    NetProfit_pv_stor, NetProfit_PV_only,
    model_data::HEMData, reg_year, z::Symbol, h::Symbol,
)
    # A configuration is attractive if it has positive net profit; only then is its payback
    # period defined. Compute paybacks before choosing so the chosen branch never uses a
    # payback left over from an earlier iteration or year.
    pv_stor_attractive = NetProfit_pv_stor(z, h) > 0.0
    pv_only_attractive = NetProfit_PV_only(z, h) > 0.0
    if pv_stor_attractive
        customers.Payback_pv_stor(z, h, :) .= payback_pv_stor(customers, NetProfit_pv_stor(z, h), z, h)
    end
    if pv_only_attractive
        customers.Payback_pv_only(z, h, :) .= payback_pv_only(customers, NetProfit_PV_only(z, h), z, h)
    end

    if pv_stor_attractive && pv_only_attractive
        if customers.Payback_pv_stor(z, h) <= customers.Payback_pv_only(z, h)
            # Solar plus storage is most attractive
            adopt_pv_stor!(customers, customers.Payback_pv_stor, model_data, reg_year, z, h)
        else
            # Standalone PV is most attractive
            adopt_pv_only!(customers, customers.Payback_pv_only, model_data, reg_year, z, h)
        end
    elseif pv_only_attractive
        # Only Standalone PV is attractive
        adopt_pv_only!(customers, customers.Payback_pv_only, model_data, reg_year, z, h)
    elseif pv_stor_attractive
        # Only Solar plus Storage is attractive
        adopt_pv_stor!(customers, customers.Payback_pv_stor, model_data, reg_year, z, h)
    else
        adopt_nothing!(customers, model_data, reg_year, z, h)
    end
end

save_der_adoption_results(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    hem_opts::HEMOptions{<:MarketStructure, NullUseCase},
    export_file_path::AbstractString,
) = nothing

function save_der_adoption_results(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    hem_opts::HEMOptions{<:MarketStructure, DERAdoption},
    export_file_path::AbstractString,
)

    # Primal Variables
    save_param(
        customers.x_DG_new_my.values,
        [:Year, :CustomerType, :Zone, :DERTech],
        :Capacity_MW,
        joinpath(export_file_path, "x_DG.csv"),
    )
    save_param(
        customers.stor_charge.values,
        [:Year, :Zone, :CustomerType, :Day, :Hour],
        :MW,
        joinpath(export_file_path, "BTM_stor_charge.csv"),
    )
    save_param(
        customers.stor_discharge.values,
        [:Year, :Zone, :CustomerType, :Day, :Hour],
        :MW,
        joinpath(export_file_path, "BTM_stor_discharge.csv"),
    )
    save_param(
        customers.rho_DG_my.values,
        [:Year, :CustomerType, :DERTech, :Zone, :Day, :Hour],
        :MW,
        joinpath(export_file_path, "rho_DG_my.csv"),
    )

    # Cumulative DER by Configuration
    save_param(
        customers.total_der_capacity_my.values,
        [:Year, :Zone, :CustomerType, :DERTech],
        :MW,
        joinpath(export_file_path, "total_der_capacity_my.csv"),
    )
    save_param(
        customers.total_pv_only_capacity_my.values,
        [:Year, :Zone, :CustomerType, :DERTech],
        :MW,
        joinpath(export_file_path, "total_pv_only_capacity_my.csv"),
    )
    save_param(
        customers.total_pv_stor_capacity_my.values,
        [:Year, :Zone, :CustomerType, :DERTech],
        :MW,
        joinpath(export_file_path, "total_pv_stor_capacity_my.csv"),
    )

    # Financial Metrics
    save_param(
        customers.Payment_before_PVStor_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "Payment_before_PVStor_my.csv"),
    )
    save_param(
        customers.Payment_after_PVStor_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "Payment_after_PVStor_my.csv"),
    )
    save_param(
        customers.PVStor_DERA_incentive_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "PVStor_DERA_incentive_my.csv"),
    )
    save_param(
        customers.PVStor_FOM_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "PVStor_FOM_my.csv"),
    )
    save_param(
        customers.NetProfit_PVStor_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "NetProfit_PVStor_my.csv"),
    )
    save_param(
        customers.Payment_after_PVOnly_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "Payment_after_PVOnly_my.csv"),
    )
    save_param(
        customers.PVOnly_FOM_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "PVOnly_FOM_my.csv"),
    )
    save_param(
        customers.NetProfit_PVOnly_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "NetProfit_PVOnly_my.csv"),
    )
    save_param(
        customers.FinalCapEx_PVStor_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "FinalCapEx_PVStor_my.csv"),
    )
    save_param(
        customers.FinalCapEx_PVOnly_my.values,
        [:Year, :Zone, :CustomerType],
        :dollars_per_yr,
        joinpath(export_file_path, "FinalCapEx_PVOnly_my.csv"),
    )
end
