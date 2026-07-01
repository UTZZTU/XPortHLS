#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

KERNEL_REPORT="experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"
KERNEL_VALIDATION="experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"
REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"

echo "[v0.0.19] Python syntax check"

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
  xporthls/realrepo/run_gap_resolver_plan_v018.py \
  xporthls/realrepo/kernel_name_resolver_v019.py \
  xporthls/realrepo/validate_kernel_name_resolution_v019.py \
  xporthls/realrepo/run_kernel_name_resolution_v019.py

echo "[v0.0.19] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.19] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.19] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.19] Run Kernel Name Resolver"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.19] Re-run generator guard to prove generation is still blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report "$GUARD_REPORT" \
  --out "$GUARD_VALIDATION" \
  --expect-blocked

python3 - <<'PY'
import json
from pathlib import Path

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
plan = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"))
kernel = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

summary = kernel["summary"]

print()
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Resolver plan state:", plan["plan_state"])
print("Kernel report schema:", kernel["schema_version"])
print("Kernel resolver ID:", kernel["resolver_id"])
print("Kernel resolution state:", kernel["resolution_state"])
print("Configured kernels:", summary["num_configured_kernels"])
print("Declared functions:", summary["num_declared_functions"])
print("Matches:", summary["num_matches"])
print("Unresolved configured:", summary["num_unresolved_configured"])
print("Unresolved declared:", summary["num_unresolved_declared"])
print("Match methods:", summary["match_methods"])
print("Proposed gap state:", kernel["gap_transition_proposal"]["proposed_gap_state"])
print("Generator unlock allowed:", summary["generator_unlock_allowed"])
print("Kernel validation status:", validation["status"])
print("Guard blocked after resolver:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert plan["schema_version"] == "gap_resolver_plan.v1"
assert kernel["schema_version"] == "kernel_name_resolution_report.v1"
assert kernel["gap_id"] == "GAP-KERNEL-NAME-001"
assert kernel["resolver_id"] == "RESOLVE-GAP-KERNEL-NAME-001"
assert kernel["migration_status"] == "profile_only"
assert kernel["policy"]["deterministic_only"] is True
assert kernel["policy"]["llm_used"] is False
assert kernel["policy"]["gap_state_changed"] is False
assert kernel["policy"]["contract_state_changed"] is False
assert summary["num_configured_kernels"] > 0
assert summary["num_declared_functions"] > 0
assert summary["num_matches"] + summary["num_unresolved_configured"] == summary["num_configured_kernels"]
assert summary["generator_unlock_allowed"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
