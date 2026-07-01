#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATTERN_PAIRING="${PATTERN_PAIRING:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json}"
TARGET_AWARE_PLAN="${TARGET_AWARE_PLAN:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_aved_host_runtime_v027.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v027}"

PATTERN="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json"
PATTERN_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json"
PATTERN_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json"

echo "[v0.0.27] Python syntax check"

python3 -m py_compile \
  xporthls/resolvers/aved_host_runtime_pattern_v027.py \
  xporthls/resolvers/validate_aved_host_runtime_pattern_v027.py \
  xporthls/resolvers/run_aved_host_runtime_pattern_v027.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.27] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATTERN_PAIRING" "$TARGET_AWARE_PLAN" "$PATCHED_CONTRACT"; do
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
  echo "  - v0.0.26 for TargetAwareResolverPlan"
  exit 3
fi

echo "[v0.0.27] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.27] Run AVED host runtime pattern resolver"

python3 -m xporthls.resolvers.run_aved_host_runtime_pattern_v027 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --pattern-pairing "$PATTERN_PAIRING" \
  --target-aware-plan "$TARGET_AWARE_PLAN" \
  --patched-contract "$PATCHED_CONTRACT" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json

pattern = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_aved_host_runtime_v027.json", encoding="utf-8"))

s = pattern["summary"]

print()
print("AVEDHostRuntimePattern schema:", pattern["schema_version"])
print("Migration direction:", pattern["migration_direction"])
print("Gap ID:", pattern["gap_id"])
print("Resolver:", pattern["resolver_name"])
print("Pattern state:", pattern["pattern_state"])
print("Ready for contract resolution:", pattern["ready_for_contract_resolution"])
print("Host action mappings:", s["host_action_mapping_count"])
print("Mapped with source+target evidence:", s["mapped_with_source_and_target_evidence_count"])
print("Mapped with target evidence / source sparse:", s["mapped_with_target_evidence_source_sparse_count"])
print("Needs more target evidence:", s["mapped_but_needs_more_target_evidence_count"])
print("Source XRT host hits:", s["source_xrt_host_total_hits"])
print("Target host hits:", s["target_host_total_hits"])
print("Target QDMA evidence:", s["target_qdma_evidence_count"])
print("Target AXI-Lite evidence:", s["target_axi_lite_evidence_count"])
print("Target AP_CTRL evidence:", s["target_ap_ctrl_evidence_count"])
print("Unresolved dependencies:", pattern["unresolved_dependencies"])
print("Host gap still blocking:", s["host_gap_still_blocking"])
print("Gaps marked resolved by v0.0.27:", s["gaps_marked_resolved_by_v027"])
print("Contract blocking gap count:", s["contract_blocking_gap_count"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for m in pattern["host_action_mappings"]:
    print(f"- {m['source_action_id']} -> {m['target_action_id']} [{m['mapping_state']}] dep={m['dependency']}")

expected_blockers = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert pattern["schema_version"] == "aved_host_runtime_pattern.v1"
assert pattern["xporthls_version"] == "v0.0.27"
assert pattern["migration_direction"] == "XRT->AVED"
assert pattern["gap_id"] == "GAP-XRT-HOST-001"
assert pattern["resolver_name"] == "AVEDHostRuntimePatternResolver"
assert pattern["pattern_state"] == "host_runtime_pattern_extracted_not_resolved"
assert pattern["ready_for_contract_resolution"] is False
assert pattern["llm_annotations"] == []
assert pattern["trust_boundary"]["llm_used"] is False
assert pattern["trust_boundary"]["contract_modified"] is False
assert pattern["trust_boundary"]["generator_unlocked"] is False
assert pattern["trust_boundary"]["can_resolve_gap"] is False
assert pattern["trust_boundary"]["can_generate_host_code"] is False
assert s["host_action_mapping_count"] >= 8
assert s["target_qdma_evidence_count"] > 0
assert s["target_axi_lite_evidence_count"] > 0
assert s["target_ap_ctrl_evidence_count"] > 0
assert s["host_gap_still_blocking"] is True
assert s["gaps_marked_resolved_by_v027"] == 0
assert s["contract_blocking_gap_count"] == 6
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(pattern["contract_context"]["blocking_gap_ids"]) == sorted(expected_blockers)
assert "GAP-KERNEL-NAME-001" not in pattern["contract_context"]["blocking_gap_ids"]

dep_ids = {d["gap_id"] for d in pattern["unresolved_dependencies"]}
assert "GAP-MEM-HBM-001" in dep_ids
assert "GAP-HLS-INTERFACE-001" in dep_ids
assert "GAP-PLATFORM-001" in dep_ids

assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected_blockers)
PY

echo
echo "DONE."
