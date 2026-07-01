#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"

echo "[v0.0.17] Python syntax check"

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
  xporthls/generators/validate_generator_guard_v017.py

echo "[v0.0.17] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.17] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.17] Ensure blocked generation output path is absent"

rm -rf "$REQUESTED_OUT"

echo "[v0.0.17] Attempt guarded generation; this must be blocked"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.17] Validate generator guard report"

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report "$GUARD_REPORT" \
  --out "$GUARD_VALIDATION" \
  --expect-blocked

python3 - <<'PY'
import json
from pathlib import Path

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"))

requested_out = Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017")

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard schema:", guard["schema_version"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard exit code:", guard["decision"]["exit_code"])
print("Guard reason:", guard["decision"]["reason"])
print("Blocking gaps:", guard["summary"]["blocking_gap_ids"])
print("Output exists after guard:", requested_out.exists())
print("Blocked generation created output:", guard["output_protection"]["blocked_generation_created_output"])
print("Guard validation status:", validation["status"])

required_ids = {
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-KERNEL-NAME-001",
    "GAP-HLS-INTERFACE-001",
}
actual_ids = set(guard["summary"]["blocking_gap_ids"])

assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert guard["schema_version"] == "generator_guard_report.v1"
assert guard["contract_ref"]["schema_version"] == "source_to_target_gap_contract.v1"
assert guard["decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert guard["decision"]["exit_code"] == 2
assert guard["output_protection"]["blocked_generation_created_output"] is False
assert not requested_out.exists()
assert required_ids.issubset(actual_ids)
assert validation["status"] == "pass"
PY

echo
echo "DONE."
