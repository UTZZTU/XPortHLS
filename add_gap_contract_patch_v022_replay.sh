#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v022"
PATCHED_CONTRACT="experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"
PATCH_REPORT="experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"
PATCH_VALIDATION="experiments/runs/hisparse_u280_profile_gap_contract_patch_validation_v022.json"
PATCHED_GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v022.json"

echo "[v0.0.22] Python syntax check"

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
  xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/kernel_alias_table_v021.py \
  xporthls/realrepo/kernel_name_resolver_v021.py \
  xporthls/realrepo/kernel_gap_update_proposal_v021.py \
  xporthls/realrepo/validate_kernel_alias_resolution_v021.py \
  xporthls/realrepo/run_kernel_alias_resolution_v021.py \
  xporthls/realrepo/gap_contract_patch_v022.py \
  xporthls/realrepo/validate_gap_contract_patch_v022.py \
  xporthls/realrepo/run_gap_contract_patch_v022.py

echo "[v0.0.22] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.22] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.18 resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.21 alias resolver baseline"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.22] Apply gap contract patch"

python3 -m xporthls.realrepo.run_gap_contract_patch_v022 \
  --case-id hisparse_u280_profile \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --out-dir experiments/runs

echo "[v0.0.22] Run generator guard against patched contract; it must still be blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$PATCHED_GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.22] Validate patch with patched-contract guard evidence"

python3 -m xporthls.realrepo.validate_gap_contract_patch_v022 \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --patched-contract "$PATCHED_CONTRACT" \
  --patch-report "$PATCH_REPORT" \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --guard-report "$PATCHED_GUARD_REPORT" \
  --out "$PATCH_VALIDATION"

python3 - <<'PY'
import json
from pathlib import Path

original = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
patched = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"))
patch_report = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patch_validation_v022.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v022.json"))

print()
print("Original schema:", original["schema_version"])
print("Original blocking count:", original["summary"]["num_blocking"])
print("Original blocking IDs:", original["summary"]["blocking_gap_ids"])
print("Patched schema:", patched["schema_version"])
print("Patched contract state:", patched["contract_state"])
print("Patched migration allowed:", patched["migration_decision"]["allowed"])
print("Patched blocking count:", patched["summary"]["num_blocking"])
print("Patched blocking IDs:", patched["summary"]["blocking_gap_ids"])
print("Resolved gap IDs:", patched["summary"].get("resolved_gap_ids"))
print("Patch applied:", patch_report["summary"]["applied"])
print("Removed target gap:", patch_report["summary"]["removed_target_gap_from_blocking"])
print("Patch validation status:", validation["status"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v022").exists())

assert original["schema_version"] == "source_to_target_gap_contract.v1"
assert patched["schema_version"] == "source_to_target_gap_contract.v1"
assert "GAP-KERNEL-NAME-001" in original["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" not in patched["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in patched["summary"]["resolved_gap_ids"]
assert patched["summary"]["num_blocking"] == 6
assert patched["contract_state"] == "blocked_profile_only"
assert patched["migration_decision"]["allowed"] is False
assert patch_report["summary"]["applied"] is True
assert patch_report["summary"]["removed_target_gap_from_blocking"] is True
assert validation["status"] == "pass"
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]
assert len(guard["summary"]["blocking_gap_ids"]) == 6
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v022").exists()
PY

echo
echo "DONE."
