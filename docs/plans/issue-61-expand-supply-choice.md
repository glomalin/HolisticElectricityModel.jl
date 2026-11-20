# Issue #61: expand SupplyChoice applicability (branch `eh/expand-supply-choice-applicability`)

Working plan for https://github.com/glomalin/HolisticElectricityModel.jl/issues/61. Update the status list as commits land so work can resume across sessions.

## Status
- [x] Step 0: rename branch (from `eh/capture-supply-choice-in-run-name`) and commit this plan
- [x] Step 1: `end_year` truncation option (tested in `test/test_end_year.jl`)
- [x] Reproducible solves (Gurobi `Method = 4`, `solver_threads`)
- [x] Step 2: baselines (worktree `/scratch/ehale/HEM-baseline` at cbedeaf, `scenarios/run-baseline.sh`, configs in `scenarios/configs-bench/`). B1 = full VIU scenario-5 run, B2 = WM scenario-1 `_thru2027` run, B3–B5 = `Results_bench_B*_baseline_thru2023`
- [x] Step 3: refactor of CustomerGroup into dispatch-based DER-adoption / supply-choice steps. Gate: B1, B3, B5 all files match; B4 matches except intended output-format changes (extra DER files; x_DG.csv now has Zone, and its old DERTech column actually held zone names). #61 combos (scenario-7, SolarPlusStorageOnly+SupplyChoice, VIU) now run. WM gate (R-B2) and WM #61 (scenario-3) pending. A no-decision CustomerGroup (NullUseCase/NullUseCase) now only updates annual load data and returns 0.0.
- [x] Step 4.1: fix stale payback (CompeteDERConfigs). No change in VIU scenarios 5 and 6 through 2023 (the one-config-attractive branches were not reached)
- [x] Step 4.2: fix WholesaleMarketPerc dispatch. VIU + DERAdoption + SupplyChoice previously got the WM value (1.0); now 0.01 like VIU + SupplyChoice. Green subscriptions and green-tech buildout drop ~47% in VIU scenario-7 and B4 (2021-2023), with knock-on changes in prices/dispatch/capacity; VIU SupplyChoice-only (B5) unchanged
- [x] Step 4.3: fix x_green_sub save dims (x_DG fixed by the Step 3 refactor). Output-only: x_green_sub.csv gains Zone; values unchanged
- [ ] Step 4.4: StandalonePVOnly path never updates total_der_capacity_my / total_pv_only_capacity_my, which the VIU utility reads (so the utility never sees new standalone-PV builds)
- [ ] Step 5: fail-fast validation of agent/option method coverage
- [ ] Full-horizon reruns of MARKET-2.5 scenarios 3, 4, 7, 8 (confirm cluster time first)

Reproducibility (found and fixed between Steps 1 and 2): identical runs used to differ because
Gurobi's default LP method is a non-deterministic concurrent race (simplex vs barrier), which
returned different optimal bases for the degenerate utility LP; prices and everything downstream
followed. Fixed by `Method = 4` (deterministic concurrent) for all Gurobi optimizers plus
`SimulationParameters.solver_threads` (use 10, matching `sbatch -n 10`). Verified: two identical
`end_year: 2022` scenario-5 runs on different nodes matched in all 402 Gurobi fingerprints/objectives
and all output files. Pre-fix full-horizon baselines must be rerun.
Comparison tool: `/scratch/ehale/MARKET-2.5/scenarios/compare_results.jl` (env `compare_env`).

Decisions already made: fix the latent bugs in separate commits after a refactor that leaves results unchanged; put the split-out logic in new sibling files rather than reorganizing customer_group.jl in place.


## Context
Issue #61: `CompeteDERConfigs` (or `SolarPlusStorageOnly`) + `DERAdoption` + `SupplyChoice` hits a `MethodError` in `solve_agent_problem!(::CustomerGroup, ...)`. It happens after the year-1 IPP/Regulator solves. MARKET-2.5 scenarios 3, 4, 7 and 8 (`/scratch/ehale/MARKET-2.5/scenarios/configs/`) all crashed this way. `src/agents/customer_group.jl` has four monolithic `solve_agent_problem!` methods, one per hard-coded combination:

| line | CustomerOptions | der_use_case | supply_choice |
|---|---|---|---|
| 696 | StandalonePVOnly | DERAdoption | NullUseCase (old 6-arg signature, dead) |
| 831 | SolarPlusStorageOnly ∪ CompeteDERConfigs | DERAdoption | NullUseCase (about 570 lines) |
| 1492 | any | NullUseCase | SupplyChoice |
| 1541 | StandalonePVOnly | DERAdoption | SupplyChoice (copy of the DER and green-sub code) |

The goal is to build `solve_agent_problem!`/`save_results` from two independent steps, each picked by multiple dispatch, so every combination works. Validating that requires before/after benchmark runs. Full runs go to 2036 (16 years) and take a long time, so the first code change is an option to stop a run early.

## Step 1: `end_year` truncation option (commit 1; must come before the refactor so baselines can use it)
Truncate the **window loop only**. Do not truncate `index_y`/`index_y_fix`. `index_y_fix` is used about 140 times across agents, e.g. `update_total_capacity!` fills forward to `last(index_y_fix)`, so trimming it would change year-1 numbers. Trimming only the loop means years ≤ end_year are identical to the same years of a full run. Later years keep their initialized values, the same in both runs being compared.
- `src/run_hem.jl` `run_hem`: new kwarg `end_year::Union{Int,Nothing}=nothing`, passed to `solve_equilibrium_problem!`. If set, append `_thru$(end_year)` to the default output-dir name so truncated runs don't overwrite full-run `Results_*` dirs.
- `src/agents/common.jl` `solve_equilibrium_problem!` (line 492): new `end_year` arg. Before each window, `break` when `model_data.year(first(model_data.index_y)) > end_year`. Log that the run was truncated. `save_results` still runs.
- Validate `end_year` in `run_hem`: it must fall inside `model_data.year` over `index_y_fix`, otherwise raise an error.
- `script/config_data.jl`: add `FieldValidatorHasDefault("end_year", check_integer, nothing)` under `"RunOptions"`. `script/hem.jl`: parse it and pass it to `run_hem`. `script/config.jl` `save_config`: write `end_year` into the `RunOptions` section of the saved config.yaml.

## Step 2: Baselines (no code changes; run from commit 1)
- **Existing full-horizon baselines:** SLURM jobs 20010816/17/25/26 are running scenarios 1, 2, 5 and 6 (CompeteDERConfigs; WM/VIU × ExcessRetailRate/ExcessMarginalCost; no SupplyChoice) from this checkout at 775b62f. The Julia code was already loaded when they started, so changing branch or files does not affect them. Keep their `Results_*` dirs as baselines for full runs.
- **Pin baseline code:** `git worktree add --detach ../HEM-baseline <commit-1>`, then copy `runner/Gurobi/Manifest.toml` (untracked; it points to the package as `path = "../.."`) into it. All later baseline runs use this tree. Development continues in the main checkout.
- **Truncated benchmark configs:** put them in `/scratch/ehale/MARKET-2.5/scenarios/configs-bench/`, each copied from scenario-5 or 6 (VIU is fastest) or 1 (WM), with `RunOptions: end_year: 2023`. That gives 3 years, so the `w_iter >= 2` paths run.
  - B1: scenario-5 as is (VIU, CompeteDERConfigs, NullUseCase)
  - B2: scenario-1 as is (WM, CompeteDERConfigs, NullUseCase)
  - B3: scenario-5 with `pv_adoption_type: SolarPlusStorageOnly`
  - B4: scenario-7 with `pv_adoption_type: StandalonePVOnly` (VIU + DERAdoption + SupplyChoice, already supported)
  - B5: scenario-5 with `der_use_case: NullUseCase`, `supply_choice_use_case: SupplyChoice`

  Run B1–B5 from `../HEM-baseline` with a copy of `scenarios/run.sh` that `cd`s there, submitted via sbatch.
- Comparison script, in a durable location (e.g. `/scratch/ehale/MARKET-2.5/scenarios/compare_results.jl`): walk the CSVs in two result dirs with the `isapprox(rtol=1e-5, atol=1e-8, nans=true)` logic from `test/test_hem.jl` and report differences per file and column.

## Step 3: Pure refactor, no change in results (commit 2)
New files, included in `src/HolisticElectricityModel.jl` right after `agents/customer_group.jl`: `src/agents/customer_group_der_adoption.jl` and `src/agents/customer_group_supply_choice.jl`.

`customer_group.jl` keeps the types, constructor, PV adoption helpers (`get_max_market_share`, `get_incremental_build_frac`, `update_total_capacity*!`) and one orchestrating method:
```julia
function solve_agent_problem!(customers::CustomerGroup, customer_opts::CustomerOptions,
        model_data::HEMData, hem_opts::HEMOptions, agent_store::AgentStore, w_iter,
        window_length, jump_model, export_file_path, update_results::Bool, output_intermediate_results::Bool)
    _, reg_year_index = get_reg_year(model_data)
    _, reg_year_index_pre = get_prev_reg_year(model_data, w_iter)
    diffs = []
    append!(diffs, solve_der_adoption!(customers, customer_opts, model_data, hem_opts, agent_store, w_iter))   # first: green sub reads x_DG_new_my
    append!(diffs, solve_supply_choice!(customers, customer_opts, model_data, hem_opts, agent_store, w_iter))
    isempty(diffs) && error("CustomerGroup has no decision to make under $(hem_opts)")
    customers.current_year = reg_year_index
    customers.previous_year = reg_year_index_pre
    return compute_difference_percentage_maximum_one_norm(diffs)   # src/utils.jl:290, takes (before, after) pairs
end
```
`save_results(::CustomerGroup, ::CustomerOptions, ::HEMOptions, path)` calls `save_der_adoption_results` and then `save_supply_choice_results`.

**customer_group_der_adoption.jl** (`solve_*` functions return `[(before, after), ...]`):
- `solve_der_adoption!(..., ::HEMOptions{<:MarketStructure, NullUseCase}, ...) = []`
- `solve_der_adoption!(..., ::HEMOptions{<:MarketStructure, DERAdoption}, ...)`: `snapshot_x_DG`, then `load_annual_der_params!` (the PeakLoad/d/Opti_DG/FOM/CapEx/ITC/x_DG_E block, currently duplicated 3×), then `choose_der_builds!(customers, customer_opts, ...)`, then write `x_DG_new_my`, `MaxDG_my`, `total_der_capacity_my`.
- `choose_der_builds!(::CustomerOptions{StandalonePVOnly})`: per-m payback logic from line 1541, plus the `update_total_capacity_pv_only_builds!` call that the dead line-696 method had. Delete 696.
- `choose_der_builds!(::Union{CustomerOptions{SolarPlusStorageOnly},CustomerOptions{CompeteDERConfigs}})` calls:
  - `solve_btm_storage_dispatch!(customers, solvers, regulator, utility_or_ipp, model_data, z, h, reg_year_index)`: the JuMP model at lines 909–1111. Returns Payment_after_PVStor(z,h).
  - `compute_pv_stor_net_profit` and `compute_pv_only_economics` (lines 896–906, 1115–1156)
  - `record_der_financials!` (lines 1159–1178)
  - `select_der_config!(::CustomerOptions{SolarPlusStorageOnly})` and `select_der_config!(::CustomerOptions{CompeteDERConfigs})`, replacing the `isa` branch at line 1181
  - `update_btm_storage_rho!` (lines 1379–1391)
- Dedupe the four near-identical adoption blocks into `adopt_pv_stor!` / `adopt_pv_only!`, built on `get_max_market_share` / `get_incremental_build_frac`. These replace the inline Gamma/Bass formulas at lines 1279–1310 and 1323–1354, which are mathematically identical; the comparison against B1/B2 confirms this. Branch selection stays exactly as it is, stale payback read included, until Step 4.
- `save_der_adoption_results`: the NullUseCase method does nothing. The DERAdoption method writes the file set from lines 1686–1800.

**customer_group_supply_choice.jl:**
- `solve_supply_choice!(..., ::HEMOptions{<:MarketStructure, <:UseCase, NullUseCase}) = []`
- The `SupplyChoice` method snapshots x_green_sub, loads the year's `customers.d` (idempotent after the DER step), then calls `get_green_tech_subscription` and `set_green_tech_subscriptions!`, moved here unchanged.
- `save_supply_choice_results`: Null and SupplyChoice methods.

The #61 combination now resolves without further work. `GreenDeveloper` already has `HEMOptions{WM|VIU, <:UseCase, SupplyChoice}`, `DERAggregator` covers every combination in WM and VIU, and a grep finds no other `isa HEMOptions` checks.

**Gate:** rerun B1–B5 from the dev checkout and compare against the baselines. Expect zero differences. Known exception: B4's `x_DG.csv`/`x_green_sub.csv` gain a `:Zone` column, because the DERAdoption+SupplyChoice saver now shares the DERAdoption file set. Fix 3 in Step 4 keeps those columns.

## Step 4: Bug fixes, one commit each, then compare against the Step 3 outputs
1. **Stale payback (CompeteDERConfigs):** compute `Payback_pv_stor`/`Payback_pv_only` whenever the matching NetProfit > 0, before branching. Today the "only PV" and "only PV+stor" branches read values left over from earlier. Expected to change B1/B2 only.
2. **WholesaleMarketPerc** (line 1415): replace the `isa HEMOptions{VIU, NullUseCase, SupplyChoice}` check with `wholesale_market_perc(::HEMOptions{VIU}) = 0.01` and `wholesale_market_perc(::HEMOptions{WM}) = 1.0`. Expected to change B4 only.
3. **Save dims:** `x_DG.csv` uses `[:Year, :CustomerType, :Zone, :DERTech]`, `x_green_sub.csv` uses `[:Year, :CustomerType, :Zone]` (`x_green_sub_my` is (y,h,z)). Output columns only.

## Step 5: Fail fast on unsupported combinations (commit; the issue's second suggestion)
Add `validate_agent_methods(hem_opts, agents_and_opts)` in `src/agents/common.jl` and call it in `run_hem` before `solve_equilibrium_problem!`. It runs `hasmethod(solve_agent_problem!, Tuple{typeof(agent), typeof(opts), HEMData, typeof(hem_opts), AgentStore, Int, Int, Any, String, Bool, Bool})` for each agent in `iter_agents_and_options` and raises one error that lists every missing combination. Gaps then show up in seconds, not after the IPP solve.

## Verification summary
- After Step 1: run B1 with `end_year: 2021` and with `end_year: 2023`. Check that the output dir carries `_thru…`, the log stops at the right year, and `config.yaml` records end_year. When scenarios 5/1 finish, check that B1/B2 years 2021–2023 match the full-run baselines (proves truncation doesn't change results).
- After Step 3: B1–B5 match the baselines. New: truncated runs of scenarios 7 and 3 (VIU and WM CompeteDERConfigs + SupplyChoice, i.e. #61), plus SolarPlusStorageOnly + SupplyChoice, complete and write x_DG, x_green_sub, BTM storage and green_tech_buildout outputs.
- After each Step 4 commit: differences appear only in the expected runs and files.
- After Step 5: a fake `PVAdoptionType` defined in the REPL makes `run_hem` fail before any solve.
- Finally, rerun scenarios 3, 4, 7 and 8 at full horizon via `scenarios/run.sh` from the dev checkout. Do this only after the user confirms, since it uses cluster time.

## Critical files
`src/agents/customer_group.jl`, new `src/agents/customer_group_{der_adoption,supply_choice}.jl`, `src/HolisticElectricityModel.jl`, `src/agents/common.jl`, `src/run_hem.jl`, `script/{hem,config,config_data}.jl`.
