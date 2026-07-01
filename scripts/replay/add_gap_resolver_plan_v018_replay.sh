#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

PLAN_PATH="experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"
PLAN_REPORT="experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json"

echo "[v0.0.18] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/hls_interface_extractor.py \
  xporthls/realrepo/validate_hls_interface_v013.py \
  xporthls/realrepo/run_hls_interface_v013.py \
  xporthls/realrepo/application_ir_v2_builder.py \
  xporthls/realrepo/validate_application_ir_v2_v014.py \
  xporthls/realrepo/run_application_ir_v2_v014.py \
  xporthls/realrepo/run_profile_case_v015.py \
  xporthls/realrepo/validate_profile_case_v015.py \
  xporthls/realrepo/run_hisparse_profile_case_v015.py \
  xporthls/realrepo/gap_contract_v016.py \
  xporthls/realrepo/validate_gap_contract_v016.py \
  xporthls/realrepo/run_gap_contract_v016.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py \
  xporthls/generators/validate_generator_guard_v017.py \
  xporthls/realrepo/gap_resolver_plan_v018.py \
  xporthls/realrepo/validate_gap_resolver_plan_v018.py \
  xporthls/realrepo/run_gap_resolver_plan_v018.py

echo "[v0.0.18] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.18] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.18] Re-run v0.0.17 generator guard baseline"

rm -rf experiments/runs/hisparse_u280_profile_guarded_generated_v017

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir experiments/runs/hisparse_u280_profile_guarded_generated_v017 \
  --report-out experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json \
  --out experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json \
  --expect-blocked

echo "[v0.0.18] Build Gap Resolver Plan"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

python3 - <<'PY'
import json
from pathlib import Path

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))
plan = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"))
report = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json"))

summary = plan["summary"]
resolver_types = {r["gap_id"]: r["resolver_type"] for r in plan["resolvers"]}

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Plan schema:", plan["schema_version"])
print("Plan state:", plan["plan_state"])
print("Migration status:", plan["migration_status"])
print("Generation allowed:", summary["generation_allowed"])
print("Resolver execution allowed:", summary["resolver_execution_allowed"])
print("Resolvers:", summary["num_resolvers"])
print("Blocking resolvers:", summary["num_blocking_resolvers"])
print("Warning resolvers:", summary["num_warning_resolvers"])
print("Info resolvers:", summary["num_info_resolvers"])
print("Blocking resolver IDs:", summary["blocking_resolver_ids"])
print("Resolver types:", resolver_types)
print("Validation status:", report["status"])

required_types = {
    "GAP-XRT-HOST-001": "HostRuntimeRewritePlan",
    "GAP-PLATFORM-001": "SourcePlatformMappingPlan",
    "GAP-MEM-HBM-001": "MemoryMappingPlan",
    "GAP-STREAM-AXIS-001": "StreamGraphMappingPlan",
    "GAP-PLACEMENT-SLR-001": "PlacementPolicyPlan",
    "GAP-KERNEL-NAME-001": "KernelNameResolutionPlan",
    "GAP-HLS-INTERFACE-001": "HlsInterfaceLoweringPlan",
}

assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert plan["schema_version"] == "gap_resolver_plan.v1"
assert plan["plan_state"] == "planned_profile_only"
assert plan["migration_status"] == "profile_only"
assert summary["generation_allowed"] is False
assert summary["resolver_execution_allowed"] is False
assert summary["num_blocking_resolvers"] == len(contract["summary"]["blocking_gap_ids"])
assert summary["num_resolvers"] == contract["summary"]["num_gaps"]
assert report["status"] == "pass"

for gap_id, resolver_type in required_types.items():
    assert resolver_types[gap_id] == resolver_type, (gap_id, resolver_types.get(gap_id))
PY

echo
echo "DONE."
