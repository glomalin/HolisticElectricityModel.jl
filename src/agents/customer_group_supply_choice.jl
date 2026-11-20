# CustomerGroup supply-choice (green tariff subscription) step.
#
# `solve_supply_choice!` is called by `solve_agent_problem!(::CustomerGroup, ...)` after the
# DER-adoption step (the subscription calculation uses this year's DER builds). It dispatches
# on the supply_choice_use_case type parameter of HEMOptions and returns a vector of
# (before, after) pairs for the convergence check.

solve_supply_choice!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions{<:MarketStructure, <:UseCase, NullUseCase},
    agent_store::AgentStore,
    w_iter,
) = []

function solve_supply_choice!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions{<:MarketStructure, <:UseCase, SupplyChoice},
    agent_store::AgentStore,
    w_iter,
)
    regulator = get_agent(Regulator, agent_store)
    utility_or_ipp = get_bulk_system_agent(agent_store, hem_opts)
    green_developer = get_agent(GreenDeveloper, agent_store)

    # the year consumer is making green tariff subscription decision
    reg_year, reg_year_index = get_reg_year(model_data)

    x_green_sub_before = ParamArray(customers.x_green_sub, "x_green_sub_before")
    fill!(x_green_sub_before, NaN)
    for (z, h) in model_data.index_z_h_map
        x_green_sub_before(h, z, :) .= customers.x_green_sub_my(reg_year_index, h, z)
    end

    GreenSubMWh = get_green_tech_subscription(customers, green_developer, regulator, utility_or_ipp, model_data, hem_opts)

    # customers.x_green_sub_my is an annual number (per the regression), however, this number cannot decrease.
    # this is to make sure the subsribed green techs (in previous years) are always paid for.
    set_green_tech_subscriptions!(customers, GreenSubMWh, model_data)

    return [(x_green_sub_before, GreenSubMWh)]
end

"""
Share of the bulk power system served through a wholesale market, as used by the green
tariff subscription regression: (nearly) none for a vertically integrated utility (0.01
rather than 0 so that the regression's log term is defined) and all of it in a wholesale
market.
"""
get_wholesale_market_perc(::HEMOptions{VIU}) = 0.01
get_wholesale_market_perc(::HEMOptions{WM}) = 1.0

function get_green_tech_subscription(
    customers::CustomerGroup,
    green_developer,
    regulator::Regulator,
    utility_or_ipp,
    model_data::HEMData,
    hem_opts::HEMOptions,
)
    
    green_sub_model = customers.green_sub_model
    delta_t = model_data.delta_t.value

    WholesaleMarketPerc = get_wholesale_market_perc(hem_opts)

    reg_year, reg_year_index = get_reg_year(model_data)

    # calculate green tariff subscription (% MWh)
    GreenSubPerc = KeyedArray(
        [ 
            exp(
            green_sub_model.Constant(h) + 
            green_sub_model.GreenPowerPrice_coefficient(h) * log(green_developer.ppa_my(reg_year_index, h)) + 
            green_sub_model.EnergyRate_coefficient(h) * log(regulator.p_my_regression(reg_year_index, h)) + 
            green_sub_model.WholesaleMarket_coefficient(h) * log(WholesaleMarketPerc) + 
            green_sub_model.RetailCompetition_coefficient(h) * log(customers.RetailCompetition(reg_year_index)) + 
            green_sub_model.RPS_coefficient(h) * log(utility_or_ipp.RPS(reg_year_index)) + 
            green_sub_model.WTP_coefficient(h) * log(customers.WTP_green_power(reg_year_index))
            ) for h in model_data.index_h
        ];
        [get_pair(model_data.index_h)]...,
    )

    sector_to_h_map = get_one_to_many_dict(model_data.index_h_sector_map, :index_sector)

    for h in sector_to_h_map[:Residential]
        # Residential customers are not allowed to subscribe to green tariff
        GreenSubPerc(h,:) .= 0.0
    end

    # is GreenSubPerc a percentage of net load? total load? shall we account for distribution loss or not?

    GreenSubMWh = make_keyed_array(model_data.index_h, model_data.index_z)

    for (z,h) in model_data.index_z_h_map
        GreenSubMWh(h, z, :) .= 
            sum(
                GreenSubPerc(h) * 
                sum(
                    customers.d(h, z, d, t) / (1 + utility_or_ipp.loss_dist) * model_data.omega(d) * delta_t * customers.gamma(z, h) -
                    sum(
                        customers.rho_DG(h, m, z, d, t) * customers.x_DG_E_my(reg_year_index, h, z, m) * model_data.omega(d) * delta_t for
                        m in customers.index_m
                    ) -
                    sum(
                        customers.rho_DG(h, m, z, d, t) * model_data.omega(d) * delta_t * sum(
                            customers.x_DG_new_my(Symbol(Int(y_symbol)), h, z, m) for y_symbol in
                            model_data.year(first(model_data.index_y_fix)):model_data.year(reg_year_index)
                        ) for m in customers.index_m
                    )
                ) for t in model_data.index_t, d in model_data.index_d
            )
    end

    return GreenSubMWh
end

function set_green_tech_subscriptions!(
    customers::CustomerGroup,
    GreenSubMWh::KeyedArray,
    model_data::HEMData,
)

    reg_year, reg_year_index = get_reg_year(model_data)
    for (z, h) in model_data.index_z_h_map
        if reg_year > model_data.year(first(model_data.index_y_fix))
            customers.x_green_sub_my(reg_year_index, h, z, :) .= max(GreenSubMWh(h, z), customers.x_green_sub_my(Symbol(Int(reg_year-1)), h, z))
            customers.x_green_sub_incremental_my(reg_year_index, h, z, :) .= customers.x_green_sub_my(reg_year_index, h, z) - customers.x_green_sub_my(Symbol(Int(reg_year-1)), h, z)
        else
            customers.x_green_sub_my(reg_year_index, h, z, :) .= GreenSubMWh(h, z)
            customers.x_green_sub_incremental_my(reg_year_index, h, z, :) .= GreenSubMWh(h, z)
        end
    end

end

save_supply_choice_results(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    hem_opts::HEMOptions{<:MarketStructure, <:UseCase, NullUseCase},
    export_file_path::AbstractString,
) = nothing

function save_supply_choice_results(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    hem_opts::HEMOptions{<:MarketStructure, <:UseCase, SupplyChoice},
    export_file_path::AbstractString,
)
    save_param(
        customers.x_green_sub_my.values,
        [:Year, :CustomerType],
        :Subscription_MWh,
        joinpath(export_file_path, "x_green_sub.csv"),
    )
end
