#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"
DIAGNOSIS="experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json"
DIAGNOSIS_VALIDATION="experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json"

echo "[v0.0.20] Python syntax check"

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
  xporthls/realrepo/run_kernel_name_resolution_v019.py \
  xporthls/realrepo/kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/validate_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py

echo "[v0.0.20] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.20] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.20] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.20] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.20] Run Kernel Unresolved Diagnosis"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

python3 -m xporthls.realrepo.validate_kernel_unresolved_diagnosis_v020 \
  --diagnosis "$DIAGNOSIS" \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --out "$DIAGNOSIS_VALIDATION"

echo "[v0.0.20] Re-run generator guard to prove generation is still blocked"

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

kernel = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"))
diagnosis = json.load(open("experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

ks = kernel["summary"]
ds = diagnosis["summary"]

print()
print("Kernel resolution state:", kernel["resolution_state"])
print("Kernel unresolved configured:", ks["num_unresolved_configured"])
print("Diagnosis schema:", diagnosis["schema_version"])
print("Diagnosed unresolved:", ds["num_diagnosed"])
print("Classification counts:", ds["classification_counts"])
print("High confidence:", ds["num_high_confidence"])
print("Medium confidence:", ds["num_medium_confidence"])
print("Low confidence:", ds["num_low_confidence"])
print("Safe auto-resolve candidates:", ds["num_safe_to_auto_resolve_candidates"])
print("Must remain blocking:", ds["must_remain_blocking"])
print("Generator unlock allowed:", ds["generator_unlock_allowed"])
print("Proposed v2 tasks:", len(diagnosis["proposed_resolver_v2_tasks"]))
print("Diagnosis validation status:", validation["status"])
print("Guard blocked after diagnosis:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert diagnosis["schema_version"] == "kernel_name_unresolved_diagnosis.v1"
assert diagnosis["source_kernel_resolution_ref"]["schema_version"] == "kernel_name_resolution_report.v1"
assert diagnosis["policy"]["deterministic_only"] is True
assert diagnosis["policy"]["llm_used"] is False
assert diagnosis["policy"]["gap_state_changed"] is False
assert diagnosis["policy"]["contract_state_changed"] is False
assert diagnosis["policy"]["generator_unlock_allowed"] is False
assert ds["num_unresolved_configured"] == ks["num_unresolved_configured"]
assert ds["num_diagnosed"] == ks["num_unresolved_configured"]
assert len(diagnosis["diagnoses"]) == ks["num_unresolved_configured"]
assert diagnosis["gap_transition_proposal"]["proposed_state"] == "remain_blocking"
assert ds["generator_unlock_allowed"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
