# XPortHLS

**Version-aware XRT->AVED engineering migration agent**

XPortHLS is an engineering migration framework for converting **XRT-based Alveo HLS applications** into **native AVED projects**, with the current target deployment board being **AMD Alveo V80**.

The project is not a free-form code generator. It is designed as a **compiler-like migration pipeline** controlled by structured IR, contracts, validators, guards, evidence logs, and budget ledgers.

## Correct terminology

XPortHLS uses the following terminology.

| Term | Meaning in this project |
|---|---|
| XRT | Source-side runtime / host API ecosystem used by existing Alveo applications. |
| AVED | Target-side engineering / runtime ecosystem for the generated native project. |
| V80 | Current target deployment board. V80 is hardware, not the runtime ecosystem. |
| Vivado | Target-side implementation and integration tool for BD, synthesis, implementation, address assignment, PDI generation, and board deployment flow. |
| Vivado HLS / Vitis HLS | HLS toolchain components used to generate RTL/IP from C/C++ HLS code. They are toolchain facts, not the migration endpoint. |
| QDMA | Target-side host-to-card data movement path used in the current AVED/V80 reference flow. |
| AXI-Lite | Target-side control/register interface for HLS IP control. |
| HBM/PC | Target-side high-bandwidth memory and pseudo-channel address model. |
| TargetReferenceIR | A future structured representation of a known-good AVED/V80 target reference project. |
| VectorKB | External plug-in vector knowledge base. It provides retrievable knowledge, not authoritative correctness decisions. |

The migration direction is:

```text
XRT-based Alveo HLS application
        ->
Native AVED project
Current deployment board: V80
```

Do **not** describe the project as "Vitis HLS -> AVED" or "V80 -> AVED". These are different layers.

## Core research principle

XPortHLS follows this principle:

```text
Extract general migration rules from HiSparse,
then validate whether those rules generalize on a second and third XRT->AVED case.
```

HiSparse is the first complex main case, not the whole project. Case-specific evidence belongs in case configuration, target reference data, and experiment artifacts. Core extractors, resolvers, validators, and guards should remain general whenever possible.

## Project scope

### In scope

XPortHLS targets application-level migration from source XRT projects to a native AVED/V80 flow:

- Source repository census.
- Source runtime profiling.
- Source build and connectivity extraction.
- HLS interface extraction.
- Multi-kernel ApplicationIR construction.
- Source-to-target gap contract generation.
- Contract-gated generation blocking.
- Resolver planning.
- Deterministic gap resolution.
- Contract patch proposal and patch application.
- Evidence, trace, budget, and artifact ledgers.
- ModelAdapter / LLM boundary infrastructure.
- Target reference intake for known-good AVED/V80 projects.
- Future external VectorKB integration.

### Out of scope for the current stage

The current stage does **not** claim:

- Arbitrary XRT project one-click migration.
- Real AVED project generation.
- Real model-driven patching.
- Real LLM correctness judgment.
- Real board-level auto deployment.
- General DDR<->HBM conversion.
- Zynq/Versal-to-Alveo migration.
- Cross-vendor FPGA migration.
- PPA-optimal generation.

Correct migration comes first. Performance tuning comes after correctness.

## Why V80/AVED target reference matters

V80/AVED target-side projects do not use the old XRT flow directly. The source-side abstractions such as:

```text
xclbin
xrt::device
xrt::kernel
xrt::bo
group_id
run.start()
run.wait()
```

must be expanded into target-side engineering artifacts such as:

```text
Vivado/AVED project templates
BD/Tcl connections
AXI-Lite register maps
QDMA host transfers
HBM/PC address spaces
HLS IP packaging
PDI build and deployment flow
```

Manual migration steps such as copying AVED templates, changing Tcl, connecting BD ports, and assigning address spaces are not "miscellaneous manual work". They are first-class migration knowledge that XPortHLS must eventually learn, encode, validate, and replay.

## HiSparse and SPMV-on-V80

The source-side main case is HiSparse:

```text
HiSparse source:
  Alveo U280
  XRT runtime
  HBM-heavy multi-kernel SpMV application
```

The target-side reference is the uploaded / external SPMV-on-V80 project:

```text
SPMV-on-V80 target reference:
  Native AVED/V80 engineering flow
  Vivado/AVED BD/Tcl project structure
  HLS IP packaging
  QDMA host runtime
  AXI-Lite control
  HBM/PC address mapping
  known-correct target-side execution evidence
```

SPMV-on-V80 should be treated as a **Target Reference / Golden Reference**, not merely as a manually modified copy. It is expected to become the first input to `TargetReferenceIR`.

## TargetReferenceIR roadmap

The next major project step is not direct AVED generation. The next step is to ingest the known-good AVED/V80 target reference project.

Planned `TargetReferenceIR v1` fields include:

```text
repository_summary
documentation_index
host_runtime_pattern
vivado_aved_project_pattern
bd_tcl_pattern
hls_ip_packaging_pattern
axi_lite_register_pattern
qdma_transfer_pattern
hbm_pc_address_map
stream_connection_pattern
manual_operation_trace
known_correctness_fixes
optimization_notes
```

The purpose is to convert target-side engineering knowledge into machine-readable migration evidence.

## Shuffler changes are correctness fixes

Some changes in the V80/AVED target reference are not performance optimizations. In particular, shuffler-related changes caused by toolchain/platform version behavior should be classified as:

```text
F_VERSION_CORRECTNESS
```

Meaning:

```text
A version-induced correctness fix required because the same algorithm or structure fails to build, synthesize, or run correctly under the new toolchain/platform semantics, HLS dependency behavior, stream arbitration behavior, or interface constraints.
```

This is different from later optimization categories such as CDC cleanup, timing closure, QoR tuning, aggressive HBM scaling, or PPA search.

## Architecture

XPortHLS is organized as:

```text
Case
  -> Source extractors
  -> ApplicationIR
  -> Platform Pack
  -> Gap Contract
  -> Resolver Plan
  -> Deterministic Resolvers
  -> Contract Patch Proposal
  -> Patched Contract
  -> Generator Guard
  -> Future Target Generator
  -> Validation and Evidence
```

The LLM path is separate and controlled:

```text
ModelAdapter
  -> LLMRequest
  -> LLMResponse
  -> LLM Trace Ledger
  -> LLM Budget Ledger
  -> Validator
```

The LLM is not allowed to become the source of truth.

## Trust boundary

The following components are authoritative:

```text
ApplicationIR facts
Platform Pack
MigrationContract / Gap Contract
Validators
Generator Guard
Build logs
Run logs
Board PASS results
Artifact Registry
Patch Ledger
Budget Ledger
```

The following components are non-authoritative:

```text
LLM output
Mock LLM output
VectorKB retrieval result
Unverified documentation summary
Unvalidated patch plan
```

LLM and VectorKB may help propose explanations or plans, but they do not decide whether a migration is correct.

## External Vector Knowledge Base

XPortHLS will support an external plug-in Vector Knowledge Base.

The VectorKB should store and retrieve:

```text
AVED documentation
V80 manuals
Vivado/AVED project templates
QDMA notes
AXI-Lite register patterns
HBM/PC mapping rules
HLS IP packaging examples
manual migration traces
known failure signatures
known correctness fixes
build and run logs
negative cases
```

Every retrieval must be traced.

Every knowledge block should include metadata:

```text
source
version
toolchain
board
runtime/ecosystem
file_type
applicability
verified_by
negative_cases
license_or_distribution_note
```

The VectorKB must not directly modify:

```text
facts
contracts
migration_allowed
generator decisions
validation results
```

Final correctness must still be decided by validators, contracts, guards, build logs, run logs, and board PASS evidence.

## Current implemented status

Latest implemented milestone:

```text
v0.0.23
Add model adapter and LLM trace infrastructure
```

Current state:

```text
Real source case:
  HiSparse U280/XRT/HBM profile-only case

ApplicationIR:
  application_ir.v2

Initial gap contract:
  14 gaps
  7 initial blocking gaps

Resolved:
  GAP-KERNEL-NAME-001

Remaining blocking gaps:
  GAP-XRT-HOST-001
  GAP-PLATFORM-001
  GAP-MEM-HBM-001
  GAP-STREAM-AXIS-001
  GAP-PLACEMENT-SLR-001
  GAP-HLS-INTERFACE-001

Migration allowed:
  false

Generator:
  blocked by guard

LLM:
  ModelAdapter installed
  default backend disabled
  real model not invoked
  mock model not invoked
```

## Implemented milestones

| Version | Milestone | Status |
|---|---|---|
| v0.0.1 | Initial scaffold | Complete |
| v0.0.2 | Light DDR fixture and L0 checker | Complete |
| v0.0.3 | XRT semantic extractor v1 | Complete |
| v0.0.4 | ApplicationIR v1 trust-boundary schema | Complete |
| v0.0.5 | case.yaml loader and case metadata | Complete |
| v0.0.6 | L0-pre / L0-post split | Complete |
| v0.0.7 | Versioned Platform Pack v1 | Complete |
| v0.0.8 | MigrationContract v1 and ExecutionPolicy v1 | Complete |
| v0.0.9 | Generator stub and L0-post generated project loop | Complete |
| v0.0.10 | Evidence registry and budget ledger | Complete |
| v0.0.11 | Real repo census and source platform profiler | Complete |
| v0.0.12 | Source-side build/connectivity extractor | Complete |
| v0.0.13 | HLS interface extractor v1 | Complete |
| v0.0.14 | Multi-kernel ApplicationIR v2 | Complete |
| v0.0.15 | HiSparse profile-only case pack | Complete |
| v0.0.16 | Source-to-target gap contract | Complete |
| v0.0.17 | Contract-gated generator guard | Complete |
| v0.0.18 | Gap contract resolver plan | Complete |
| v0.0.19 | Kernel name resolver v1 | Complete |
| v0.0.20 | Kernel unresolved diagnosis | Complete |
| v0.0.21 | Kernel alias table and resolver v2 | Complete |
| v0.0.22 | Gap contract patch apply | Complete |
| v0.0.23 | ModelAdapter and LLM trace infrastructure | Complete |

Note on v0.0.12: the name "Vitis Build" refers to **source-side build/connectivity parsing** of the original XRT/Vitis-style project metadata. It does not imply that the target AVED/V80 board deployment uses a Vitis上板 flow.

## Important implemented result

XPortHLS has already completed the first full deterministic gap-resolution chain:

```text
Detect GAP-KERNEL-NAME-001
  -> diagnose unresolved configured kernels
  -> build alias table
  -> resolve all configured kernels
  -> generate contract update proposal
  -> apply patched gap contract
  -> remove GAP-KERNEL-NAME-001 from blocking list
  -> keep migration_allowed=false
  -> prove generator guard still blocks generation
```

Result:

```text
Original blocking gaps: 7
Patched blocking gaps: 6
Resolved: GAP-KERNEL-NAME-001
Generator remains blocked: true
```

This proves the contract/resolver/patch/guard path works for at least one real blocking gap.

## Repository layout

Typical repository layout:

```text
cases/
  hisparse_u280_profile/

platform_packs/
  v80_aved_2025_1_stub/

xporthls/
  applications/
  contracts/
  generators/
  ir/
  llm/
  realrepo/
  targetref/        # planned for v0.0.24+
  validation/

experiments/runs -> /mnt/data/xporthls_runs
```

`experiments/runs` is expected to point to external run artifacts and should not be committed as experiment output.

## Current main case

```text
cases/hisparse_u280_profile
```

Current external source repository path:

```text
/mnt/data/xporthls_benchmarks/HiSparse
```

Current target reference path should be external, for example:

```text
/mnt/data/xporthls_target_refs/SPMV-on-V80-main
```

Do not commit large external benchmark or target reference repositories unless explicitly intended and license-approved.

## Common replay scripts

Previously generated replay scripts include:

```text
add_kernel_alias_resolution_v021_replay.sh
add_gap_contract_patch_v022_replay.sh
add_model_adapter_v023_replay.sh
```

Example:

```bash
cd /home/wwb/XPortHLS
./add_model_adapter_v023_replay.sh
```

Expected v0.0.23 safety result:

```text
LLM enabled: False
Default backend: disabled
Request status: blocked_by_policy
Request executed: False
Real model invoked: False
Mock model invoked: False
Budget executed requests: 0
Spent USD: 0.0
Guard blocked: True
Validation status: pass
```

## Do not commit run artifacts

Do not commit files like:

```text
experiments/runs/*.json
experiments/runs/hisparse_*_v011.json
experiments/runs/hisparse_*_v012.json
experiments/runs/hisparse_*_v013.json
experiments/runs/hisparse_*_v014.json
experiments/runs/hisparse_u280_profile_*_v015.json
experiments/runs/hisparse_u280_profile_*_v016.json
experiments/runs/hisparse_u280_profile_*_v017.json
experiments/runs/hisparse_u280_profile_*_v018.json
experiments/runs/hisparse_u280_profile_*_v019.json
experiments/runs/hisparse_u280_profile_*_v020.json
experiments/runs/hisparse_u280_profile_*_v021.json
experiments/runs/hisparse_u280_profile_*_v022.json
experiments/runs/hisparse_u280_profile_*_v023.json
/mnt/data/xporthls_benchmarks/HiSparse
/mnt/data/xporthls_target_refs/SPMV-on-V80-main
```

Commit source code, validators, runners, replay scripts, README updates, schema files, and small case metadata only.

## Suggested next milestone

The next milestone should be:

```text
v0.0.24
XRT->AVED Terminology Normalization + Target Reference Intake
```

Scope:

```text
1. Normalize README, comments, schemas, and report language to XRT->AVED.
2. Add xporthls/targetref/.
3. Add TargetReferenceIR v1 schema.
4. Add SPMV-on-V80 target reference census.
5. Extract documentation, host runtime, Vivado/AVED BD/Tcl, HLS IP packaging, QDMA, AXI-Lite, HBM/PC, stream patterns, and manual operation traces.
6. Classify shuffler changes as F_VERSION_CORRECTNESS, not optimization.
7. Produce validation report.
8. Do not modify gap contract.
9. Do not unlock generator.
10. Do not call real LLM.
```

Proposed v0.0.24 outputs:

```text
experiments/runs/spmv_on_v80_target_reference_ir_v024.json
experiments/runs/spmv_on_v80_target_reference_report_v024.json
experiments/runs/spmv_on_v80_target_reference_validation_v024.json
```

## Revised near-term roadmap

```text
v0.0.24  XRT->AVED Terminology Normalization + Target Reference Intake
v0.0.25  TargetReferenceIR Extractor for SPMV-on-V80
v0.0.26  Source-Target Pattern Pairing v1
v0.0.27  AVED Host Runtime Pattern Resolver v1
v0.0.28  HBM/PC Memory Mapping Resolver v1
v0.0.29  AVED Stream Graph Resolver v1
v0.0.30  VectorKB Adapter v1
v0.0.31  Mock LLM Read-only Diagnosis using TargetReference + VectorKB
```

The exact order of host, memory, and stream resolvers may change after TargetReferenceIR evidence is extracted.

## Correctness-first validation ladder

XPortHLS should keep the validation ladder:

```text
L0-pre   input/schema/contract checks
L0-post  generated project static checks
L1       software reference / CPU golden
L2       HLS C simulation
L3       HLS synthesis
L4       Vivado/AVED BD/interface/build validation
L5       V80 board run
```

A later version may add more target-reference-specific checks before L4/L5.

## Failure taxonomy additions

Current and planned failure categories should include:

```text
F_XRT_HOST_RUNTIME
F_PLATFORM_TARGET
F_MEMORY_HBM_PC
F_STREAM_AXIS
F_PLACEMENT_SLR
F_HLS_INTERFACE
F_KERNEL_NAME
F_VERSION_CORRECTNESS
F_UNKNOWN
```

`F_VERSION_CORRECTNESS` is important for target-side changes caused by toolchain/platform version behavior, including shuffler-related correctness fixes.

## LLM policy

The LLM must remain bounded:

```text
LLM is not a source of facts.
LLM is not an executor.
LLM is not a correctness judge.
LLM cannot modify contracts directly.
LLM cannot unlock generator.
LLM cannot replace validators.
LLM cannot bypass build/run evidence.
```

In v0.0.23:

```text
llm_enabled: false
default_backend: disabled
real_backend_allowed: false
network_access_allowed: false
request_status: blocked_by_policy
```

Future mock LLM stages must still be read-only unless explicitly validated.

## Development rule of thumb

For every new capability:

```text
extract facts
write IR
write report
write validator
write replay
prove generator remains blocked unless contract allows
commit only source and replay, not run artifacts
```

For every resolved gap:

```text
detect
diagnose
resolve
propose patch
apply patch
validate
prove guard behavior
```

For every target-reference feature:

```text
extract target evidence
record source path and digest
classify as correctness / migration pattern / optimization note
validate schema
do not mutate migration contract directly
```

## Current project sentence

A safe one-sentence description:

```text
XPortHLS is a version-aware XRT->AVED engineering migration framework that extracts source application facts, builds machine-checkable migration contracts, applies deterministic resolvers, and uses validators, guards, and evidence ledgers to safely migrate XRT-based Alveo HLS applications toward native AVED projects on V80.
```

## Target Reference Intake v0.0.24

v0.0.24 adds the first target-side intake path for the known-good SPMV-on-V80 AVED/V80 reference project. It creates `TargetReferenceIR v1` from deterministic repository evidence and records host/QDMA, AXI-Lite/AP_CTRL, HBM/PC address, Vivado/AVED Tcl/BD, HLS IP packaging, stream connection, manual operation trace, known correctness fixes, and optimization notes.

This version does not modify the gap contract, does not unlock the generator, and does not call an LLM.

Typical command:

```bash
python3 -m xporthls.targetref.run_target_reference_intake_v024 \
  --case-id spmv_on_v80 \
  --target-name SPMV-on-V80 \
  --target-root /mnt/data/xporthls_target_refs/SPMV-on-V80-main \
  --out-dir experiments/runs
```

Expected artifacts:

```text
experiments/runs/spmv_on_v80_target_reference_ir_v024.json
experiments/runs/spmv_on_v80_target_reference_report_v024.json
experiments/runs/spmv_on_v80_target_reference_validation_v024.json
```
