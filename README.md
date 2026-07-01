# XPortHLS

XPortHLS is an engineering migration framework for moving XRT/Vitis HLS accelerator projects toward an AVED-native project structure.

The current target is AMD Alveo V80 with AVED and Vivado/Vitis 2025.1. Source projects are expected to come from XRT-based Alveo platforms such as U280, U50, U55C, U200-class designs, and similar Vitis acceleration projects.

The project is intentionally built as a compiler-like pipeline: facts are extracted deterministically, normalized into IR, checked against contracts, generated into a target scaffold, and recorded with reproducible evidence. Model-assisted repair can be added later through a bounded adapter layer, but correctness is always decided by contracts, validators, tool reports, and tests.

## Current status

XPortHLS is currently an early-stage migration framework. It can run a complete deterministic pipeline on the included `light_ddr` fixture:

```text
case.yaml
  -> ApplicationIR
  -> Platform Pack
  -> MigrationContract v1
  -> ExecutionPolicy v1
  -> L0-pre
  -> StaticallyChecked contract
  -> generated target scaffold
  -> L0-post
  -> Artifact Registry / Budget Ledger / Replay Manifest
```

The current implementation does **not** claim to fully migrate large real-world projects such as multi-kernel HBM designs yet. Repositories with HiSparse-like structure require repository census, build/connectivity extraction, HLS interface extraction, and source-platform profiling before full migration can be attempted.

## What works today

- Scan a small XRT/Vitis HLS project fixture.
- Extract basic XRT host facts:
  - `xrt::device`
  - `xrt::kernel`
  - `xrt::bo`
  - `kernel.group_id`
  - buffer allocation
  - `bo.write`
  - `bo.read`
  - `bo.sync`
  - kernel invocation
  - `run.wait`
- Build `ApplicationIR`.
- Load a versioned target Platform Pack.
- Build `MigrationContract v1`.
- Build `ExecutionPolicy v1`.
- Run L0-pre validation before generation.
- Promote a contract from `Proposed` to `StaticallyChecked`.
- Generate a deterministic target scaffold.
- Run L0-post validation on the generated project.
- Record artifacts, file hashes, tool calls, wall time, and replay commands.

## What is not implemented yet

- Full migration of real XRT Alveo applications.
- Real AVED/QDMA host generation.
- Real register map and address map generation.
- Full Vivado block design generation.
- Vitis build/connectivity parsing for complex projects.
- Multi-kernel and kernel-to-kernel stream migration.
- HBM bank mapping migration.
- C simulation, co-simulation, synthesis, implementation, or hardware validation.
- Model-driven diagnosis or repair.

## Target platform

Current target:

```text
Board:      AMD Alveo V80
Flow:       AVED-native target scaffold
Tools:      Vivado/Vitis 2025.1
Pack:       platform_packs/v80_aved_2025_1_stub
Status:     stub pack; rule files exist but hardware-specific rules still require verification
```

Target-platform information is kept in a Platform Pack rather than hard-coded into the pipeline.

## Source projects

Current source assumption:

```text
Runtime:    XRT
Flow:       Vitis acceleration projects
Boards:     U280 / U50 / U55C / U200-class Alveo projects and similar XRT-based designs
```

The current fixture is intentionally small. Real repositories should first be profiled before they are treated as migration candidates.

## Repository layout

```text
cases/
  light_ddr/
    case.yaml
    src/
    tests/

platform_packs/
  v80_aved_2025_1_stub/
    platform.json
    capabilities.json
    memory_rules.json
    qdma_rules.json
    register_rules.json
    templates/

xporthls/
  cases/
  contracts/
  evidence/
  generators/
  ir/
  platforms/
  scanner/
  validators/

experiments/
  runs -> /mnt/data/xporthls_runs
```

## Requirements

Minimum development environment:

- Linux
- Python 3.10+
- Git
- AMD/Xilinx tools installed separately if running hardware-tool stages later

The current L0 pipeline does not require running Vivado or Vitis. Later stages will require the installed AMD/Xilinx toolchain.

On the current development server the expected tools are:

```text
Vivado: /opt/Xilinx/2025.1/Vivado/bin/vivado
Vitis:  /opt/Xilinx/2025.1/Vitis/bin/vitis
HLS:    /opt/Xilinx/2025.1/Vitis/bin/vitis_hls
```

## Quick start

Clone the repository and enter it:

```bash
git clone git@github.com:UTZZTU/XPortHLS.git
cd XPortHLS
```

Run the current evidenced pipeline:

```bash
./add_evidence_system_v010_replay.sh
```

Expected result:

```text
Evidence validation: pass
Missing artifacts: 0
Tool calls: 7
Failed tool calls: 0
LLM calls: 0
L0-post status: pass
L0-post issues: 0
```

## Manual pipeline commands

### 1. Scan the fixture

```bash
python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir.json
```

### 2. Validate the target Platform Pack

```bash
python3 -m xporthls.platforms.platform_pack \
  --pack platform_packs/v80_aved_2025_1_stub \
  --out experiments/runs/v80_aved_2025_1_platform_pack_report.json
```

### 3. Build MigrationContract v1 and ExecutionPolicy v1

```bash
python3 -m xporthls.contracts.build_contract_v1 \
  --app-ir experiments/runs/light_ddr_application_ir.json \
  --platform platform_packs/v80_aved_2025_1_stub \
  --out experiments/runs/light_ddr_migration_contract_proposed.json \
  --policy-out experiments/runs/light_ddr_execution_policy.json
```

### 4. Validate the contract

```bash
python3 -m xporthls.contracts.validate_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_proposed.json \
  --policy experiments/runs/light_ddr_execution_policy.json \
  --out experiments/runs/light_ddr_contract_v1_report.json
```

### 5. Run L0-pre

```bash
python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir.json \
  --contract experiments/runs/light_ddr_migration_contract_proposed.json \
  --out experiments/runs/light_ddr_l0_pre_report.json
```

### 6. Promote the contract

```bash
python3 -m xporthls.contracts.promote_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_proposed.json \
  --l0-report experiments/runs/light_ddr_l0_pre_report.json \
  --out experiments/runs/light_ddr_migration_contract_static.json
```

### 7. Generate a target scaffold

```bash
python3 -m xporthls.generators.stub_generator \
  --app-ir experiments/runs/light_ddr_application_ir.json \
  --contract experiments/runs/light_ddr_migration_contract_static.json \
  --policy experiments/runs/light_ddr_execution_policy.json \
  --platform platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs/light_ddr_generated \
  --clean
```

### 8. Run L0-post

```bash
python3 -m xporthls.validators.run_l0 \
  --stage post \
  --project experiments/runs/light_ddr_generated \
  --contract experiments/runs/light_ddr_migration_contract_static.json \
  --out experiments/runs/light_ddr_l0_post_report.json
```

## Generated scaffold

The current generator creates a deterministic scaffold:

```text
experiments/runs/light_ddr_generated/
  README.md
  xporthls_generated_manifest.json
  hls/
  host/
  bd_tcl/
  build/
```

The generated host scaffold is checked to avoid source-runtime residue such as XRT object use or `.xclbin` loading.

## Evidence files

The evidenced pipeline records:

```text
experiments/runs/light_ddr_artifact_registry_v010.json
experiments/runs/light_ddr_budget_ledger_v010.json
experiments/runs/light_ddr_replay_manifest_v010.json
experiments/runs/light_ddr_evidence_report_v010.json
```

These files are runtime outputs and should not normally be committed.

## Design principles

- Facts are extracted by deterministic code.
- Platform information comes from versioned Platform Packs.
- Migration obligations are represented as contracts.
- Generation is allowed only after L0-pre validation.
- Generated output must pass L0-post validation.
- Evidence is recorded for every run.
- Model calls are disabled in the current pipeline.
- A model may assist diagnosis or repair later, but it must not be the source of truth.

## Version checkpoints

```text
v0.0.1   Project scaffold
v0.0.2   light_ddr fixture and initial L0
v0.0.3   XRT semantic extractor v1
v0.0.4   ApplicationIR v1
v0.0.5   case.yaml and case metadata
v0.0.6   L0-pre / L0-post split
v0.0.7   Platform Pack v1
v0.0.8   MigrationContract v1 and ExecutionPolicy v1
v0.0.9   Generator stub and L0-post generation loop
v0.0.10  Artifact Registry, Budget Ledger, Replay Manifest
```

## External references

- AVED documentation: https://xilinx.github.io/AVED/
- AVED historical repository: https://github.com/Xilinx/AVED
- HiSparse reference repository: https://github.com/cornell-zhang/HiSparse

## Development notes

The current repository is best treated as a migration framework prototype, not a production AVED generator. The next useful engineering step is to add real-repository profiling so that complex XRT/Vitis projects can be analyzed before migration logic is expanded.

## Real repository profiling

XPortHLS can profile a real XRT/Vitis repository before attempting migration. This is used to identify source platforms, build files, XRT usage, HLS kernels, memory topology hints, connectivity files, and unsupported features.

Example:

```bash
python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo /mnt/data/xporthls_benchmarks/HiSparse \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED
```

The profiler writes:

```text
experiments/runs/hisparse_repo_census_v011.json
experiments/runs/hisparse_source_platform_profile_v011.json
experiments/runs/hisparse_compatibility_profile_v011.json
experiments/runs/hisparse_realrepo_profile_report_v011.json
```

The profiler is analysis-only. It does not generate an AVED project.

## Build and connectivity extraction

XPortHLS can extract build and connectivity facts from a real Vitis/XRT repository. This produces a BuildIR and ConnectivityIR used by later migration stages.

Example:

```bash
python3 -m xporthls.realrepo.run_build_connectivity_v012 \
  --repo /mnt/data/xporthls_benchmarks/HiSparse \
  --case-id hisparse
```

The extractor writes:

```text
experiments/runs/hisparse_build_ir_v012.json
experiments/runs/hisparse_connectivity_ir_v012.json
experiments/runs/hisparse_build_connectivity_report_v012.json
```

The extractor is analysis-only. It does not generate an AVED project.

## HLS interface extraction

XPortHLS can extract HLS kernel interface facts from a real Vitis/XRT repository. This produces an HLS Interface IR with kernel candidates, function arguments, HLS pragmas, interface ports, stream usage, and include dependencies.

Example:

```bash
python3 -m xporthls.realrepo.run_hls_interface_v013 \
  --repo /mnt/data/xporthls_benchmarks/HiSparse \
  --case-id hisparse \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json
```

The extractor writes:

```text
experiments/runs/hisparse_hls_interface_ir_v013.json
experiments/runs/hisparse_hls_interface_report_v013.json
```

The extractor is analysis-only. It does not generate an AVED project.

## Multi-kernel ApplicationIR v2

XPortHLS can merge real-repository facts into a multi-kernel ApplicationIR v2. This IR combines repository census data, source platform profile, build facts, connectivity facts, HLS interfaces, memory topology, stream edges, and kernel graph alignment.

Example:

```bash
python3 -m xporthls.realrepo.run_application_ir_v2_v014 \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --census experiments/runs/hisparse_repo_census_v011.json \
  --source-profile experiments/runs/hisparse_source_platform_profile_v011.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --compatibility-profile experiments/runs/hisparse_compatibility_profile_v011.json
```

The builder writes:

```text
experiments/runs/hisparse_application_ir_v2_v014.json
experiments/runs/hisparse_application_ir_v2_report_v014.json
```

ApplicationIR v2 is analysis-only at this stage. It does not generate an AVED project.

## HiSparse profile-only case

XPortHLS includes a profile-only case for the HiSparse U280 repository. This case runs the real-repository profiling pipeline and validates that the expected source profile, build facts, connectivity facts, HLS interface facts, ApplicationIR v2, and known gaps remain stable.

Example:

```bash
python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json
```

By default, the case runner reuses the local HiSparse checkout and skips `git pull` to avoid unnecessary network delays. Set `XPORT_HISPARSE_SKIP_PULL=0` to refresh the checkout.

The case is analysis-only. It does not generate an AVED project.

## Source-to-target gap contract

XPortHLS can convert ApplicationIR v2 gaps into a deterministic source-to-target gap contract. The contract decides whether target generation is allowed and records blocking gaps, warnings, evidence, and required next capabilities.

Example:

```bash
python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs
```

The builder writes:

```text
experiments/runs/hisparse_u280_profile_gap_contract_v016.json
experiments/runs/hisparse_u280_profile_gap_contract_report_v016.json
```

The contract is deterministic and profile-only at this stage. It does not generate an AVED project.

## Contract-gated generator guard

XPortHLS prevents target generation when the source-to-target gap contract blocks migration. A generator wrapper must read the gap contract before creating target output.

Example:

```bash
python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --expect-blocked \
  --dry-run
```

For the HiSparse profile-only case, generation is expected to be blocked because the contract contains blocking gaps such as XRT host rewrite, U280-to-V80 platform mapping, HBM memory topology mapping, AXIS/K2K stream mapping, SLR placement, kernel-name resolution, and HLS interface lowering.

## Gap resolver plan

XPortHLS can turn a blocked source-to-target gap contract into a deterministic resolver plan. The plan does not execute resolvers and does not mark any gap as resolved. It records the required inputs, output schemas, ordered steps, dependency graph, success criteria, and state-transition policy for each gap.

Example:

```bash
python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json
experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json
```

For the HiSparse profile-only case, the resolver plan is expected to remain profile-only and generation-blocked.

## Kernel name resolver

XPortHLS includes a deterministic Kernel Name Resolver for the first blocking resolver in the HiSparse gap resolver plan. It maps configured kernels and compute units from connectivity/build facts to declared HLS functions from ApplicationIR v2.

Example:

```bash
python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs
```

The resolver writes:

```text
experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json
experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json
```

The v0.0.19 resolver is deterministic and profile-only. It does not modify the gap contract and does not unlock generation.

## Kernel unresolved diagnosis

XPortHLS can diagnose unresolved configured kernels left by the deterministic Kernel Name Resolver. The diagnosis classifies each unresolved configured kernel into causes such as compute-unit instance names, alias/normalization gaps, helper/wrapper mismatches, missing HLS top functions, extraction pointer gaps, parser false positives, or insufficient evidence.

Example:

```bash
python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json
experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json
```

The v0.0.20 diagnosis is deterministic and profile-only. It does not update the gap contract and does not unlock generation.
