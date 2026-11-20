# This file defines data and functions associated with the customer.

const DER_factor = 1.0    # A scaling factor applied to existing DER penetration level

abstract type PVAdoptionType end
struct StandalonePVOnly <: PVAdoptionType end
struct SolarPlusStorageOnly <: PVAdoptionType end
struct CompeteDERConfigs <: PVAdoptionType end

abstract type AbstractCustomerOptions <: AgentOptions end

struct CustomerOptions{T <: PVAdoptionType} <: AbstractCustomerOptions
    pv_adoption_type::T

    solvers::HEMSolver
end

function get_file_prefix(options::CustomerOptions)
    return join(["$(typeof(options.pv_adoption_type))"],"_")
end

function CustomerOptions(pv_adoption_type::PVAdoptionType, attributes::MOI.OptimizerWithAttributes)
    return CustomerOptions(pv_adoption_type, AnySolver(attributes))
end


mutable struct PVAdoptionModel
    Shape::ParamArray
    MeanPayback::ParamArray
    Bass_p::ParamArray
    Bass_q::ParamArray
    Rate::ParamArray
end

"""
Constructs a PVAdoptionModel by computing Rate from the other parameters.
"""
function PVAdoptionModel(Shape, MeanPayback, Bass_p, Bass_q)
    @assert_op length(Shape) == length(MeanPayback)
    vals = deepcopy(Shape.values)
    for i in 1:length(vals)
        vals[i] = Shape[i] / MeanPayback[i]
    end

    return PVAdoptionModel(
        Shape,
        MeanPayback,
        Bass_p,
        Bass_q,
        ParamArray("Rate", Shape.dims, vals), # Rate
    )
end

function get_max_market_share(
    adopt_model::PVAdoptionModel,
    payback::ParamArray,
    z::Symbol,
    h::Symbol,
    m::Symbol;
    payback_by_m::Bool=false
)
    payback_value = (payback_by_m ? payback(z, h, m) : payback(z, h))

    return 1.0 - Distributions.cdf(
        Distributions.Gamma(
            adopt_model.Shape(z, h, m),
            1 / adopt_model.Rate(z, h, m),
        ),
        payback_value,
    )
end

function get_incremental_build_frac(
    adopt_model::PVAdoptionModel,
    exist_pv_frac::ParamArray, # relative to maximum market share
    z::Symbol,
    h::Symbol,
    m::Symbol;
    exist_pv_frac_by_m::Bool=false
)
    exist_pv_val = (exist_pv_frac_by_m ? exist_pv_frac(z, h, m) : exist_pv_frac(z, h))

    # Back out the reference year of DER based on the percentage of existing DER
    year_pv = -log(
        (1 - exist_pv_val) /
        (exist_pv_val * adopt_model.Bass_q(z, h, m) / adopt_model.Bass_p(z, h, m) + 1),
    ) / (adopt_model.Bass_p(z, h, m) + adopt_model.Bass_q(z, h, m))

    # Calculate the incremental build as a fraction of maximum market share
    return (
        1.0 - exp(
            -(adopt_model.Bass_p(z, h, m) + adopt_model.Bass_q(z, h, m)) *
            (year_pv + 1),
        )
    ) / (
        1.0 +
        (adopt_model.Bass_q(z, h, m) / adopt_model.Bass_p(z, h, m)) * exp(
            -(adopt_model.Bass_p(z, h, m) + adopt_model.Bass_q(z, h, m)) *
            (year_pv + 1),
        )
    )
end

mutable struct GreenSubModel
    Constant::ParamArray
    EnergyRate_coefficient::ParamArray
    WTP_coefficient::ParamArray
    WholesaleMarket_coefficient::ParamArray
    GreenPowerPrice_coefficient::ParamArray
    RetailCompetition_coefficient::ParamArray
    RPS_coefficient::ParamArray
    
end

abstract type AbstractCustomerGroup <: AgentGroup end

mutable struct CustomerGroup <: AbstractCustomerGroup
    id::String
    current_year::Symbol
    previous_year::Symbol
    # Sets
    index_m::Dimension # behind-the-meter technologies

    # Parameters
    "number of customers of type h"
    gamma::ParamArray
    "demand (MWh per representative agent per hour)"
    d::ParamArray
    "multi-year demand (MWh per representative agent per hour)"
    d_my::ParamArray
    x_DG_E::ParamArray
    "Existing DER at year y. This is a cumulative number but without x_DG_new_my built by this module"
    x_DG_E_my::ParamArray
    "Portion of existing DER at year y (x_DG_E_my) assigned to be Solar plus Storage"
    existing_pv_stor_capacity_my::ParamArray
    "Portion of existing DER at year y (x_DG_E_my) assigned to be Standalone PV"
    existing_pv_only_capacity_my::ParamArray
    Opti_DG::ParamArray
    #TODO: make sure optimal DG sizes are the same for existing and new
    #TODO; change this assumption later
    Opti_DG_E::ParamArray
    Opti_DG_my::ParamArray
    CapEx_DG::ParamArray
    CapEx_DG_my::ParamArray
    ITC_DER::ParamArray
    ITC_DER_my::ParamArray
    FOM_DG::ParamArray
    FOM_DG_my::ParamArray
    rho_DG::ParamArray
    rho_DG_my::ParamArray
    "Annualization factor for net consumer surplus of PV installation"
    delta::ParamScalar
    PeakLoad::ParamArray
    PeakLoad_my::ParamArray

    # Primal Variables
    x_DG_new::ParamArray
    x_DG_new_my::ParamArray    # Annual new DER build (not cumulative)
    x_green_sub::ParamArray
    x_green_sub_my::ParamArray
    x_green_sub_incremental_my::ParamArray

    # Auxiliary Variables
    Payback::ParamArray
    MarketShare::ParamArray
    MaxDG::ParamArray
    F::ParamArray
    year::ParamArray
    A::ParamArray
    ConPVNetSurplus::ParamArray
    ConPVNetSurplus_my::ParamArray

    pv_adoption_model::PVAdoptionModel
    green_sub_model::GreenSubModel

    pvf::Any
    # rooftop::Any
    MaxDG_my::ParamArray

    RetailCompetition::ParamArray
    WTP_green_power::ParamArray

    ConGreenPowerNetSurplus_pre_proportion_my::ParamArray
    ConGreenPowerNetSurplus_post_proportion_my::ParamArray
    ConGreenPowerNetSurplus_cumu_my::ParamArray

    rte_dist_stor::ParamArray
    initial_energy_dist_stor::ParamArray
    duration_dist_stor::ParamArray

    # Optimal DER Subproblem
    Payback_pv_stor::ParamArray
    Payback_pv_only::ParamArray
    MarketShare_pv_stor::ParamArray
    MarketShare_pv_only::ParamArray
    MaxDG_pv::ParamArray
    F_pv::ParamArray
    year_pv::ParamArray
    A_pv::ParamArray
    net_load::ParamArray
    net_load_plus::ParamArray
    net_load_minus::ParamArray
    stor_charge::ParamArray
    stor_discharge::ParamArray
    stor_energy::ParamArray

    # Outputs

    # Within a run, these variables are populated for all years, projecting that 
    # existing and new capacity will persist. E.g., for the next year, these variables 
    # are already populated with all existing capacity and all new capacity built 
    # through this year.

    "Cumulative DER capacity, total PV and storage regardless of how they are grouped"
    total_der_capacity_my::ParamArray
    "Cumulative PV only capacity"
    total_pv_only_capacity_my::ParamArray
    "Cumulative PV plus Storage capacity"
    total_pv_stor_capacity_my::ParamArray

    "Per customer annual utility bill prior to DER"
    Payment_before_PVStor_my::ParamArray
    "Per customer annual utility bill after adding solar plus storage"
    Payment_after_PVStor_my::ParamArray
    "Per customer annual VPP aggregation incentive"
    PVStor_DERA_incentive_my::ParamArray
    "Per customer annual FOM cost if have solar plus storage"
    PVStor_FOM_my::ParamArray
    "Per customer annual net profit from owning solar plus storage. Does not account for capital costs."
    NetProfit_PVStor_my::ParamArray

    "Per customer annual utility bill after adding standalone PV"
    Payment_after_PVOnly_my::ParamArray
    "Per customer annual FOM cost if have solar"
    PVOnly_FOM_my::ParamArray
    "Per customer annual net profit from owning standalone PV. Does not account for capital costs."
    NetProfit_PVOnly_my::ParamArray

    "Per customer capital costs for solar plus storage. Includes ITC."
    FinalCapEx_PVStor_my::ParamArray
    "Per customer capital costs for standalone PV. Includes ITC."
    FinalCapEx_PVOnly_my::ParamArray

    "Cumulative DER capacity, total PV and storage regardless of how they are grouped"
    total_der_capacity_my_delay_update::ParamArray
    "Cumulative PV only capacity"
    total_pv_only_capacity_my_delay_update::ParamArray
    "Cumulative PV plus Storage capacity"
    total_pv_stor_capacity_my_delay_update::ParamArray
    "Big M Parameter"
    BIGM::ParamScalar{<:Integer}
end


function CustomerGroup(input_dir::AbstractString, model_data::HEMData; id = DEFAULT_ID)
    index_m = read_set(
        input_dir,
        "index_m",
        "index_m",
        prose_name = "behind-the-meter technologies m",
    )

    gamma = read_param(
        "gamma",
        input_dir,
        "Gamma",
        model_data.index_h,
        [model_data.index_z],
        description = "number of customers of type h at zone z",
    )
    demand =
        read_param("d", input_dir, "Demand", model_data.index_t, [model_data.index_h, model_data.index_z, model_data.index_d])
    demand_my = read_param(
        "d_my",
        input_dir,
        "Demandmy",
        model_data.index_t,
        [model_data.index_y, model_data.index_h, model_data.index_z, model_data.index_d],
    )
    x_DG_E = read_param(
        "x_DG_E",
        input_dir,
        "ExistingDER",
        index_m,
        [model_data.index_h, model_data.index_z],
        description = "existing DG capacity",
    )
    for h in model_data.index_h, z in model_data.index_z, m in index_m
        x_DG_E(h, z, m, :) .= x_DG_E(h, z, m) * DER_factor
    end
    x_DG_E_my = read_param(
        "x_DG_E_my",
        input_dir,
        "ExistingDERmy",
        index_m,
        [model_data.index_y, model_data.index_h, model_data.index_z],
    )
    Opti_DG = read_param(
        "Opti_DG",
        input_dir,
        "OptimalDER",
        index_m,
        [model_data.index_z, model_data.index_h])
    Opti_DG_my = read_param(
        "Opti_DG_my",
        input_dir,
        "OptimalDERmy",
        index_m,
        [model_data.index_y, model_data.index_z, model_data.index_h],
    )
    rho_DG = read_param(
        "rho_DG",
        input_dir,
        "AvailabilityDER",
        model_data.index_t,
        [model_data.index_h, index_m, model_data.index_z, model_data.index_d],
    )
    # Calculate maximum demand for each customer type
    MaxLoad = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        MaxLoad(z, h, :) .=
            gamma(z, h) * findmax(Dict((z, d, t) => demand(h, z, d, t) for d in model_data.index_d, t in model_data.index_t))[1]
    end
    MaxLoad_my = make_keyed_array(model_data.index_y, model_data.index_z, model_data.index_h)
    for y in model_data.index_y, (z, h) in model_data.index_z_h_map
        MaxLoad_my(y, z, h, :) .=
            gamma(z, h) * findmax(Dict((d, t) => demand_my(y, h, z, d, t) for d in model_data.index_d, t in model_data.index_t))[1]
    end
    
    existing_pv_stor_capacity_my = initialize_param(
        "existing_pv_stor_capacity_my",
        model_data.index_y, model_data.index_h, model_data.index_z, index_m,
        description="Portion of existing DER at year y (x_DG_E_my) assigned to be Solar plus Storage"
    )
    
    for y in model_data.index_y, (z, h) in model_data.index_z_h_map
        x_DG_E_storage = x_DG_E_my(y, h, z, :BTMStorage)
        Opti_DG_PV = Opti_DG_my(y, z, h, :BTMPV)
        Opti_DG_Storage = Opti_DG_my(y, z, h, :BTMStorage)
        
        existing_pv_stor_capacity_my(y, h, z, :BTMStorage, :) .= x_DG_E_storage
    
        if Opti_DG_Storage != 0.0
            ratio = Opti_DG_PV / Opti_DG_Storage
            if isfinite(ratio)
                existing_pv_stor_capacity_my(y, h, z, :BTMPV, :) .= x_DG_E_storage * ratio
            else
                println("Warning: Non-finite ratio at (y, h, z) = ", (y, h, z))
                existing_pv_stor_capacity_my(y, h, z, :BTMPV, :) .= 0.0
            end
        else
            existing_pv_stor_capacity_my(y, h, z, :BTMPV, :) .= 0.0
        end
    end

    existing_pv_only_capacity_my = initialize_param(
        "existing_pv_only_capacity_my",
        model_data.index_y, model_data.index_h, model_data.index_z, index_m,
        description="Portion of existing DER at year y (x_DG_E_my) assigned to be Standalone PV"
    )
    for y in model_data.index_y, (z, h) in model_data.index_z_h_map
        existing_pv_only_capacity_my(y, h, z, :BTMPV, :) .= x_DG_E_my(y, h, z, :BTMPV) - existing_pv_stor_capacity_my(y, h, z, :BTMPV)
    end

    pv_adoption_model = PVAdoptionModel(
        initialize_param("Shape", model_data.index_z, model_data.index_h, index_m, value = 1.7), # Shape
        initialize_param("MeanPayback", model_data.index_z, model_data.index_h, index_m, value = 8.8), # MeanPayback
        read_param(
            "Bass_p",
            input_dir,
            "Bass_P",
            index_m,
            [model_data.index_z, model_data.index_h],
        ),
        read_param(
            "Bass_q",
            input_dir,
            "Bass_Q",
            index_m,
            [model_data.index_z, model_data.index_h],
        ),
    )

    function generate_coefficients(index_h, index_h_to_sector_map, coefficients)
        map_dict = Dict(index_h_to_sector_map)
        return [
            get(coefficients, String(map_dict[h]), 0.0) for h in index_h
        ]
    end
    
    param_coefficients = Dict(
        "WholesaleMarket_coefficient" => Dict(
            "Residential" => 0.0,
            "Commercial" => 0.14,
            "Industrial" => 0.14
        ),
        "GreenPowerPrice_coefficient" => Dict(
            "Residential" => 0.0,
            "Commercial" => -0.55,
            "Industrial" => -0.55
        ),
        "RetailCompetition_coefficient" => Dict(
            "Residential" => 0.0,
            "Commercial" => 0.16,
            "Industrial" => 0.16
        ),
        "RPS_coefficient" => Dict(
            "Residential" => 0.0,
            "Commercial" => 0.42,
            "Industrial" => 0.42
        )
    )
    
    green_sub_model = GreenSubModel(
        # Constant ParamArray
        ParamArray(
            "Constant",
            (model_data.index_h,),  
            fill(0.0, length(model_data.index_h));
            description = "Constant in green power uptake function (regression parameter)"
        ),
        
        # Energy Rate Coefficient
        ParamArray(
            "EnergyRate_coefficient",
            (model_data.index_h,),
            fill(0.0, length(model_data.index_h));
            description = "Weighted mean C&I volumetric (\$/MWh) rate (regression parameter)"
        ),
    
        # WTP Coefficient
        ParamArray(
            "WTP_coefficient",
            (model_data.index_h,),
            fill(0.0, length(model_data.index_h));
            description = "% of customers willing to pay for renewable energy at the state level (regression parameter)"
        ),
    
        # Sector-based ParamArrays
        [
            ParamArray(
                param_name,
                (model_data.index_h,),
                generate_coefficients(model_data.index_h, model_data.index_h_sector_map, param_coefficients[param_name]);
                description = description
            ) for (param_name, description) in [
                ("WholesaleMarket_coefficient", "% of load served by an ISO (regression parameter)"),
                ("GreenPowerPrice_coefficient", "Sum of PPA and REC prices (regression parameter)"),
                ("RetailCompetition_coefficient", "% of C&I customers that are eligible for retail choice (regression parameter)"),
                ("RPS_coefficient", "RPS percentage requirement in 2019 (regression parameter)")
            ]
        ]...
    )
    
        
    # Customer financing
    debt_ratio =
        read_param("debt_ratio", input_dir, "CustomerDebtRatio", model_data.index_h, [model_data.index_z])
    cost_of_debt =
        read_param("cost_of_debt", input_dir, "CustomerCOD", model_data.index_h, [model_data.index_z])
    cost_of_equity =
        read_param("cost_of_equity", input_dir, "CustomerCOE", model_data.index_h, [model_data.index_z])
    tax_rate = read_param("tax_rate", input_dir, "CustomerTax", model_data.index_h, [model_data.index_z])

    atwacc = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        atwacc(z, h, :) .= debt_ratio(z, h) * cost_of_debt(z, h) * (1 - tax_rate(z, h)) +
        (1 - debt_ratio(z, h)) * cost_of_equity(z, h)
    end

    CRF = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        CRF(z, h, :) .= atwacc(z, h) * (1 + atwacc(z, h))^20 / ((1 + atwacc(z, h))^20 - 1)
    end

    pvf = make_keyed_array(model_data.index_z, model_data.index_h)
    for (z, h) in model_data.index_z_h_map
        pvf(z, h, :) .= 1 / CRF(z, h)
    end

    rte_dist_stor = read_param(
        "rte_dist_stor",
        input_dir,
        "rte_dist_stor",
        model_data.index_h,
        [model_data.index_z],
        description = "distributed storage round trip efficiency of customers of type h at zone z",
    )

    duration_dist_stor = read_param(
        "duration_dist_stor",
        input_dir,
        "duration_dist_stor",
        model_data.index_h,
        [model_data.index_z],
        description = "distributed storage duration of customers of type h at zone z",
    )

    initial_energy_dist_stor = read_param(
        "initial_energy_dist_stor",
        input_dir,
        "initial_energy_dist_stor",
        model_data.index_d,
        [model_data.index_z, model_data.index_h],
    )

    result = CustomerGroup(
        id,
        first(model_data.index_y),
        first(model_data.index_y),
        index_m,
        gamma,
        demand,
        demand_my,
        x_DG_E,
        x_DG_E_my,
        existing_pv_stor_capacity_my,
        existing_pv_only_capacity_my,
        Opti_DG,
        Opti_DG,
        Opti_DG_my,
        # DERGen,
        read_param("CapEx_DG", input_dir, "CapExDER", index_m, [model_data.index_z, model_data.index_h]),
        read_param(
            "CapEx_DG_my",
            input_dir,
            "CapExDERmy",
            index_m,
            [model_data.index_y, model_data.index_z, model_data.index_h],
        ),
        read_param("ITC_DER", input_dir, "DER_ITCNew", index_m),
        read_param(
            "ITC_DER_my",
            input_dir,
            "DER_ITCNewmy",
            index_m,
            [model_data.index_y],
        ),
        read_param("FOM_DG", input_dir, "FOMDER", index_m, [model_data.index_z, model_data.index_h]),
        read_param(
            "FOM_DG_my",
            input_dir,
            "FOMDERmy",
            index_m,
            [model_data.index_y, model_data.index_z, model_data.index_h],
        ),
        rho_DG,
        initialize_param("rho_DG_my", model_data.index_y, model_data.index_h, index_m, model_data.index_z, model_data.index_d, model_data.index_t,
                         description = "Store each year's DER dispatch. Only populated for actively dispatched DER (e.g., :BTMStorage)."),
        ParamScalar("delta", 0.05),
               
        # Call ParamArray with the PeakLoad parameter
        ParamArray("PeakLoad", Tuple(push!(copy([model_data.index_z]), model_data.index_h)), MaxLoad),
        
        # Call ParamArray with the PeakLoad_my parameter
        ParamArray(
            "PeakLoad_my",
            Tuple(push!(copy([model_data.index_y, model_data.index_z]), model_data.index_h)),
            MaxLoad_my,
        ),
        
        initialize_param("x_DG_new", model_data.index_h, model_data.index_z, index_m, value = 0.0),
        initialize_param("x_DG_new_my", model_data.index_y, model_data.index_h, model_data.index_z, index_m, value = 0.0),
        initialize_param("x_green_sub", model_data.index_h, model_data.index_z, value = 10.0),
        initialize_param("x_green_sub_my", model_data.index_y, model_data.index_h, model_data.index_z, value = 100.0),
        initialize_param("x_green_sub_incremental_my", model_data.index_y, model_data.index_h, model_data.index_z, value = 0.0),
        initialize_param("Payback", model_data.index_z, model_data.index_h, index_m),
        initialize_param("MarketShare", model_data.index_z, model_data.index_h, index_m),
        initialize_param("MaxDG", model_data.index_z, model_data.index_h, index_m),
        initialize_param("F", model_data.index_z, model_data.index_h, index_m),
        initialize_param("year", model_data.index_z, model_data.index_h, index_m),
        initialize_param("A", model_data.index_z, model_data.index_h, index_m),
        initialize_param("ConPVNetSurplus", model_data.index_z, model_data.index_h, index_m),
        
        initialize_param(
            "ConPVNetSurplus_my",
            model_data.index_y,
            model_data.index_z, 
            model_data.index_h,
            index_m,
        ),
        pv_adoption_model,
        green_sub_model,
        pvf,
        # read_param("rooftop", input_filename, "RooftopDER", index_m, [model_data.index_z, model_data.index_h]),
        initialize_param("MaxDG_my", model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        read_param("RetailCompetition", input_dir, "RetailCompetition", model_data.index_y),
        read_param("WTP_green_power", input_dir, "WTP", model_data.index_y),
        initialize_param(
            "ConGreenPowerNetSurplus_pre_proportion_my",
            model_data.index_y,
            model_data.index_h,
        ),
        initialize_param(
            "ConGreenPowerNetSurplus_post_proportion_my",
            model_data.index_y,
            model_data.index_h,
        ),
        initialize_param(
            "ConGreenPowerNetSurplus_cumu_my",
            model_data.index_y,
            model_data.index_h,
        ),
        rte_dist_stor,
        initial_energy_dist_stor,
        duration_dist_stor,
        initialize_param("Payback_pv_stor", model_data.index_z, model_data.index_h),
        initialize_param("Payback_pv_only", model_data.index_z, model_data.index_h),
        initialize_param("MarketShare_pv_stor", model_data.index_z, model_data.index_h),
        initialize_param("MarketShare_pv_only", model_data.index_z, model_data.index_h),
        initialize_param("MaxDG_pv", model_data.index_z, model_data.index_h),
        initialize_param("F_pv", model_data.index_z, model_data.index_h),
        initialize_param("year_pv", model_data.index_z, model_data.index_h),
        initialize_param("A_pv", model_data.index_z, model_data.index_h),
        initialize_param("net_load", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("net_load_plus", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("net_load_minus", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("stor_charge", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("stor_discharge", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("stor_energy", model_data.index_y, model_data.index_z, model_data.index_h, model_data.index_d, model_data.index_t),
        initialize_param("total_der_capacity_my",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        initialize_param("total_pv_only_capacity_my",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        initialize_param("total_pv_stor_capacity_my",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        initialize_param("Payment_before_PVStor_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("Payment_after_PVStor_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("PVStor_DERA_incentive_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("PVStor_FOM_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("NetProfit_PVStor_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("Payment_after_PVOnly_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("PVOnly_FOM_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("NetProfit_PVOnly_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("FinalCapEx_PVStor_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("FinalCapEx_PVOnly_my", model_data.index_y, model_data.index_z, model_data.index_h),
        initialize_param("total_der_capacity_my_delay_update",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        initialize_param("total_pv_only_capacity_my_delay_update",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        initialize_param("total_pv_stor_capacity_my_delay_update",model_data.index_y, model_data.index_z, model_data.index_h, index_m),
        ParamScalar("BIGM", 100),
    )

    # populate total_*_capacity_my variables for DER with all existing/prescribed capacity for all years
    for y in model_data.index_y
        for (z, h) in model_data.index_z_h_map
            for m in index_m
                result.total_der_capacity_my(y, z, h, m, :) .= x_DG_E_my(y, h, z, m)
                result.total_pv_stor_capacity_my(y, z, h, m, :) .= existing_pv_stor_capacity_my(y, h, z, m)
                result.total_der_capacity_my_delay_update(y, z, h, m, :) .= x_DG_E_my(y, h, z, m)
                result.total_pv_stor_capacity_my_delay_update(y, z, h, m, :) .= existing_pv_stor_capacity_my(y, h, z, m)
            end
            result.total_pv_only_capacity_my(y, z, h, :BTMPV, :) .= existing_pv_only_capacity_my(y, h, z, :BTMPV)
            result.total_pv_only_capacity_my_delay_update(y, z, h, :BTMPV, :) .= existing_pv_only_capacity_my(y, h, z, :BTMPV)
        end
    end

    return result
end

"""
Calculates cumulative capacity for this year and future years if this technology was a build option.
"""
function update_total_capacity!(
    total_capacity_my::ParamArray,
    x_DG_new::ParamArray,
    model_data::HEMData,
    reg_year::Integer,
    z::Symbol, h::Symbol, m::Symbol)

    for y in reg_year:model_data.year(last(model_data.index_y_fix))
        total_capacity_my(Symbol(y), z, h, m, :) .+= x_DG_new(h, z, m)
    end
end


function update_total_capacity_pv_stor_builds!(
    customers::CustomerGroup,
    model_data::HEMData,
    reg_year::Integer,
    z::Symbol, h::Symbol,
)
    for m in (:BTMStorage, :BTMPV)
        update_total_capacity!(customers.total_pv_stor_capacity_my, customers.x_DG_new, model_data, reg_year, z, h, m)
    end
end

function update_total_capacity_pv_only_builds!(
    customers::CustomerGroup,
    model_data::HEMData,
    reg_year::Integer,
    z::Symbol, h::Symbol,
)
    update_total_capacity!(customers.total_pv_only_capacity_my, customers.x_DG_new, model_data, reg_year, z, h, :BTMPV)
end

get_id(x::CustomerGroup) = x.id

"""
Solve the customer group's annual decisions. Each decision is a separate step that dispatches
on its own HEMOptions type parameter (and the DER step also on the CustomerOptions PV adoption
type), so any combination of options is supported:

0. Annual update of load data to the solve year (`load_annual_customer_params!`), done
   whatever the options because other agents read `customers.d`.
1. DER adoption (`solve_der_adoption!`, customer_group_der_adoption.jl); runs first because
   the supply-choice calculation uses this year's DER builds.
2. Supply choice / green tariff subscription (`solve_supply_choice!`,
   customer_group_supply_choice.jl).

If the options call for no customer decisions, only the annual update is done and the
customer group reports itself converged (0.0).
"""
function solve_agent_problem!(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    model_data::HEMData,
    hem_opts::HEMOptions,
    agent_store::AgentStore,
    w_iter,
    window_length,
    jump_model,
    export_file_path,
    update_results::Bool,
    output_intermediate_results::Bool,
)
    _, reg_year_index = get_reg_year(model_data)
    _, reg_year_index_pre = get_prev_reg_year(model_data, w_iter)

    load_annual_customer_params!(customers, model_data)

    diffs = []
    append!(diffs, solve_der_adoption!(customers, customer_opts, model_data, hem_opts, agent_store, w_iter))
    append!(diffs, solve_supply_choice!(customers, customer_opts, model_data, hem_opts, agent_store, w_iter))

    customers.current_year = reg_year_index
    customers.previous_year = reg_year_index_pre

    if isempty(diffs)
        @info "CustomerGroup makes no decisions under $(hem_opts); only annual load data are updated." maxlog = 1
        return 0.0
    end
    return compute_difference_percentage_maximum_one_norm(diffs)
end

"""
Update annual load data (peak load and hourly demand) to the solve year.
"""
function load_annual_customer_params!(customers::CustomerGroup, model_data::HEMData)
    _, reg_year_index = get_reg_year(model_data)
    for (z, h) in model_data.index_z_h_map
        customers.PeakLoad(z, h, :) .= customers.PeakLoad_my(reg_year_index, z, h)
    end
    for (z, h) in model_data.index_z_h_map, d in model_data.index_d, t in model_data.index_t
        customers.d(h, z, d, t, :) .= customers.d_my(reg_year_index, h, z, d, t)
        # customers.DERGen(h, t, :) .= customers.DERGen_my(reg_year_index, h, t)
    end
end

function save_results(
    customers::CustomerGroup,
    customer_opts::CustomerOptions,
    hem_opts::HEMOptions,
    export_file_path::AbstractString,
)
    save_der_adoption_results(customers, customer_opts, hem_opts, export_file_path)
    save_supply_choice_results(customers, customer_opts, hem_opts, export_file_path)
end
