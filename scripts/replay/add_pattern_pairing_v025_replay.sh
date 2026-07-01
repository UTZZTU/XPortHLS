#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
RESOLVER_PLAN="${RESOLVER_PLAN:-experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_pattern_pairing_v025.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v025}"

PAIRING="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json"
PAIRING_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json"
PAIRING_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json"

echo "[v0.0.25] Python syntax check"

python3 -m py_compile \
  xporthls/targetref/pattern_pairing_v025.py \
  xporthls/targetref/validate_pattern_pairing_v025.py \
  xporthls/targetref/run_pattern_pairing_v025.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.25] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATCHED_CONTRACT"; do
  if [ ! -f "$f" ]; then
    echo "[xporthls] MISSING: $f"
    missing=1
  else
    echo "[xporthls] Found: $f"
  fi
done

if [ "$missing" -ne 0 ]; then
  echo
  echo "[xporthls] ERROR: Required artifacts are missing."
  echo "Re-run prior versions first:"
  echo "  - v0.0.14/v0.0.15 for ApplicationIR v2"
  echo "  - v0.0.22 for patched gap contract"
  echo "  - v0.0.24 for TargetReferenceIR"
  exit 3
fi

if [ -f "$RESOLVER_PLAN" ]; then
  RESOLVER_PLAN_ARG=(--resolver-plan "$RESOLVER_PLAN")
  echo "[xporthls] Found resolver plan: $RESOLVER_PLAN"
else
  RESOLVER_PLAN_ARG=()
  echo "[xporthls] WARNING: resolver plan not found, continuing without it: $RESOLVER_PLAN"
fi

echo "[v0.0.25] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.25] Run source-target pattern pairing"

python3 -m xporthls.targetref.run_pattern_pairing_v025 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --patched-contract "$PATCHED_CONTRACT" \
  "${RESOLVER_PLAN_ARG[@]}" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json
from pathlib import Path

pairing = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_pattern_pairing_v025.json", encoding="utf-8"))

s = pairing["summary"]
cov = pairing["coverage"]

print()
print("PatternPairing schema:", pairing["schema_version"])
print("Migration direction:", pairing["migration_direction"])
print("Source case:", pairing["source_case_id"])
print("Target case:", pairing["target_case_id"])
print("Pairings:", s["num_pairings"])
print("Paired gaps:", s["paired_gap_count"])
print("Partial gaps:", s["partial_gap_count"])
print("Unpaired gaps:", s["unpaired_gap_count"])
print("Expected remaining blockers:", cov["expected_remaining_blocking_gaps"])
print("Contract blocking IDs:", cov["contract_blocking_gap_ids"])
print("Paired gap IDs:", cov["paired_gap_ids"])
print("Paired with target evidence:", cov["paired_with_target_reference_evidence"])
print("Partial target evidence:", cov["partial_target_reference_evidence"])
print("Unpaired needing evidence:", cov["unpaired_needs_more_evidence"])
print("Resolved by prior work:", cov["resolved_by_prior_work"])
print("Gaps marked resolved by v0.0.25:", s["gaps_marked_resolved_by_v025"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for p in pairing["pairings"]:
    print(f"- {p['gap_id']}: {p['pairing_state']} score={p['scoring']['score']} next={p['proposed_source_to_target_mapping']['next_resolver']}")

expected = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert pairing["schema_version"] == "source_target_pattern_pairing.v1"
assert pairing["xporthls_version"] == "v0.0.25"
assert pairing["migration_direction"] == "XRT->AVED"
assert pairing["target_reference_schema"] == "target_reference_ir.v1"
assert pairing["llm_annotations"] == []
assert pairing["trust_boundary"]["llm_used"] is False
assert pairing["trust_boundary"]["contract_modified"] is False
assert pairing["trust_boundary"]["generator_unlocked"] is False
assert pairing["trust_boundary"]["can_resolve_gap"] is False
assert pairing["trust_boundary"]["can_unlock_generator"] is False
assert s["num_pairings"] == 6
assert s["gaps_marked_resolved_by_v025"] == 0
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(cov["paired_gap_ids"]) == sorted(expected)
assert cov["gaps_marked_resolved_by_v025"] == []
assert "GAP-KERNEL-NAME-001" not in cov["paired_gap_ids"]
assert "GAP-KERNEL-NAME-001" in cov["resolved_by_prior_work"]
assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected)
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]

# Strong expected coverage: all six should at least have target reference pairing evidence,
# but placement must remain partial.
states = {p["gap_id"]: p["pairing_state"] for p in pairing["pairings"]}
assert states["GAP-PLACEMENT-SLR-001"] == "partial_target_reference_evidence"
assert s["unpaired_gap_count"] == 0
PY

echo
echo "DONE."
