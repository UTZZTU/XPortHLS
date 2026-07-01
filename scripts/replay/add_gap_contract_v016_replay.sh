#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

echo "[v0.0.16] Python syntax check"

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
  xporthls/realrepo/run_gap_contract_v016.py

echo "[v0.0.16] Re-run HiSparse profile-only case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.16] Build Source-to-Target Gap Contract"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

python3 - <<'PY'
import json

case_validation = json.load(open("experiments/runs/hisparse_u280_profile_case_validation_v015.json"))
contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
report = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_report_v016.json"))

summary = contract["summary"]

print()
print("Case validation status:", case_validation["status"])
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Migration status:", contract["migration_status"])
print("Migration allowed:", contract["migration_decision"]["allowed"])
print("Target:", contract["target"])
print("Gaps:", summary["num_gaps"])
print("Blocking:", summary["num_blocking"])
print("Warnings:", summary["num_warnings"])
print("Info:", summary["num_info"])
print("Blocking IDs:", summary["blocking_gap_ids"])
print("Missing expected capabilities:", summary["missing_expected_capabilities"])
print("Validation status:", report["status"])

required_ids = {
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-KERNEL-NAME-001",
    "GAP-HLS-INTERFACE-001",
}
actual_ids = {gap["id"] for gap in contract["gaps"]}

assert case_validation["status"] in {"pass", "pass_with_warnings"}
assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["source_application_ir_ref"]["schema_version"] == "application_ir.v2"
assert contract["migration_status"] == "profile_only"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert contract["target"]["platform"] == "v80_aved_2025_1_stub"
assert contract["target"]["ecosystem"] == "AVED"
assert summary["num_gaps"] >= 6
assert summary["num_blocking"] >= 5
assert required_ids.issubset(actual_ids)
assert report["status"] in {"pass", "pass_with_warnings"}
PY

echo
echo "DONE."
