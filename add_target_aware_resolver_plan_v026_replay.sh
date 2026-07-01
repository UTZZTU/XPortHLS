#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATTERN_PAIRING="${PATTERN_PAIRING:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
OLD_RESOLVER_PLAN="${OLD_RESOLVER_PLAN:-experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_target_aware_plan_v026.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v026}"

PLAN="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json"
PLAN_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json"
PLAN_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json"

echo "[v0.0.26] Python syntax check"

python3 -m py_compile \
  xporthls/targetref/target_aware_resolver_plan_v026.py \
  xporthls/targetref/validate_target_aware_resolver_plan_v026.py \
  xporthls/targetref/run_target_aware_resolver_plan_v026.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.26] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATTERN_PAIRING" "$PATCHED_CONTRACT"; do
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
  echo "  - v0.0.25 for PatternPairing"
  exit 3
fi

if [ -f "$OLD_RESOLVER_PLAN" ]; then
  OLD_RESOLVER_PLAN_ARG=(--old-resolver-plan "$OLD_RESOLVER_PLAN")
  echo "[xporthls] Found old resolver plan: $OLD_RESOLVER_PLAN"
else
  OLD_RESOLVER_PLAN_ARG=()
  echo "[xporthls] WARNING: old resolver plan not found, continuing without it: $OLD_RESOLVER_PLAN"
fi

echo "[v0.0.26] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.26] Run target-aware resolver plan"

python3 -m xporthls.targetref.run_target_aware_resolver_plan_v026 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --pattern-pairing "$PATTERN_PAIRING" \
  --patched-contract "$PATCHED_CONTRACT" \
  "${OLD_RESOLVER_PLAN_ARG[@]}" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json

plan = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_target_aware_plan_v026.json", encoding="utf-8"))

s = plan["summary"]
ctx = plan["contract_context"]
rec = plan["v027_recommendation"]

print()
print("TargetAwarePlan schema:", plan["schema_version"])
print("Migration direction:", plan["migration_direction"])
print("Source case:", plan["source_case_id"])
print("Target case:", plan["target_case_id"])
print("Resolvers:", s["num_resolvers"])
print("Ready for next resolver design:", s["ready_for_next_resolver_design_count"])
print("Normalize-only:", s["normalize_only_count"])
print("Missing evidence:", s["missing_evidence_count"])
print("Contract blockers:", ctx["blocking_gap_ids"])
print("Resolved prior gaps:", ctx["resolved_prior_gaps"])
print("Gaps marked resolved by v0.0.26:", s["gaps_marked_resolved_by_v026"])
print("Contract blocking gap count:", s["contract_blocking_gap_count"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Recommended v0.0.27 resolver:", rec["recommended_next_resolver"])
print("Recommended v0.0.27 gap:", rec["recommended_gap_id"])
print("Alternative next resolver:", rec["alternative_next_resolver"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for item in plan["recommended_execution_order"]:
    print(f"{item['order']}. {item['gap_id']} -> {item['resolver_name']} [{item['execution_readiness']}]")

expected = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert plan["schema_version"] == "target_aware_gap_resolution_plan.v1"
assert plan["xporthls_version"] == "v0.0.26"
assert plan["migration_direction"] == "XRT->AVED"
assert plan["target_reference_schema"] == "target_reference_ir.v1"
assert plan["pattern_pairing_schema"] == "source_target_pattern_pairing.v1"
assert plan["llm_annotations"] == []
assert plan["trust_boundary"]["llm_used"] is False
assert plan["trust_boundary"]["contract_modified"] is False
assert plan["trust_boundary"]["generator_unlocked"] is False
assert plan["trust_boundary"]["can_resolve_gap"] is False
assert plan["trust_boundary"]["can_execute_resolver"] is False
assert s["num_resolvers"] == 6
assert s["ready_for_next_resolver_design_count"] >= 5
assert s["normalize_only_count"] == 1
assert s["missing_evidence_count"] == 0
assert s["gaps_marked_resolved_by_v026"] == 0
assert s["contract_blocking_gap_count"] == 6
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(ctx["blocking_gap_ids"]) == sorted(expected)
assert "GAP-KERNEL-NAME-001" not in ctx["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in ctx["resolved_prior_gaps"]
assert rec["recommended_next_resolver"] == "AVEDHostRuntimePatternResolver"
assert rec["recommended_gap_id"] == "GAP-XRT-HOST-001"
assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected)

resolver_by_gap = {r["gap_id"]: r for r in plan["resolvers"]}
assert resolver_by_gap["GAP-PLACEMENT-SLR-001"]["execution_readiness"] == "normalize_evidence_only"
assert resolver_by_gap["GAP-PLACEMENT-SLR-001"]["ready_for_contract_resolution"] is False
for gid, r in resolver_by_gap.items():
    assert r["ready_for_contract_resolution"] is False
    assert r["contract_state_after_v026"] == "unchanged_blocking"
    assert r["trust_boundary"]["can_execute"] is False
    assert r["trust_boundary"]["can_mark_gap_resolved"] is False
PY

echo
echo "DONE."
