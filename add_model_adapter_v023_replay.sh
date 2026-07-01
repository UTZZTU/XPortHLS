#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v023"
PATCHED_CONTRACT="experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"
PATCH_REPORT="experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v023.json"
PROBE="experiments/runs/hisparse_u280_profile_model_adapter_probe_v023.json"
TRACE="experiments/runs/hisparse_u280_profile_llm_trace_ledger_v023.json"
BUDGET="experiments/runs/hisparse_u280_profile_llm_budget_ledger_v023.json"
VALIDATION="experiments/runs/hisparse_u280_profile_model_adapter_validation_v023.json"

echo "[v0.0.23] Python syntax check"

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
  xporthls/realrepo/run_gap_contract_patch_v022.py \
  xporthls/llm/model_adapter_v023.py \
  xporthls/llm/validate_model_adapter_v023.py \
  xporthls/llm/run_model_adapter_probe_v023.py

echo "[v0.0.23] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.23] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.18 resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.21 alias resolver baseline"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.22 gap contract patch baseline"

python3 -m xporthls.realrepo.run_gap_contract_patch_v022 \
  --case-id hisparse_u280_profile \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --out-dir experiments/runs

echo "[v0.0.23] Run ModelAdapter probe; real and mock model execution must remain disabled"

python3 -m xporthls.llm.run_model_adapter_probe_v023 \
  --case-id hisparse_u280_profile \
  --application-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract "$PATCHED_CONTRACT" \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --patch-report "$PATCH_REPORT" \
  --out-dir experiments/runs

echo "[v0.0.23] Run generator guard against patched contract; it must still be blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.23] Validate ModelAdapter with guard evidence"

python3 -m xporthls.llm.validate_model_adapter_v023 \
  --probe "$PROBE" \
  --trace-ledger "$TRACE" \
  --budget-ledger "$BUDGET" \
  --guard-report "$GUARD_REPORT" \
  --out "$VALIDATION"

python3 - <<'PY'
import json
from pathlib import Path

probe = json.load(open("experiments/runs/hisparse_u280_profile_model_adapter_probe_v023.json"))
trace = json.load(open("experiments/runs/hisparse_u280_profile_llm_trace_ledger_v023.json"))
budget = json.load(open("experiments/runs/hisparse_u280_profile_llm_budget_ledger_v023.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_model_adapter_validation_v023.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v023.json"))
contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"))

s = probe["summary"]

print()
print("Probe schema:", probe["schema_version"])
print("Policy schema:", probe["policy"]["schema_version"])
print("Request schema:", probe["request"]["schema_version"])
print("Response schema:", probe["response"]["schema_version"])
print("Trace schema:", trace["schema_version"])
print("Budget schema:", budget["schema_version"])
print("LLM enabled:", s["llm_enabled"])
print("Default backend:", s["default_backend"])
print("Request status:", s["request_status"])
print("Request executed:", s["request_executed"])
print("Blocked by policy:", s["request_blocked_by_policy"])
print("Real model invoked:", s["real_model_invoked"])
print("Mock model invoked:", s["mock_model_invoked"])
print("Trace entries:", trace["summary"]["num_entries"])
print("Budget attempted requests:", budget["summary"]["attempted_requests"])
print("Budget executed requests:", budget["summary"]["executed_requests"])
print("Budget blocked requests:", budget["summary"]["blocked_requests"])
print("Spent USD:", budget["summary"]["spent_usd"])
print("Patched contract blocking count:", contract["summary"]["num_blocking"])
print("Patched contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])
print("Validation status:", validation["status"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v023").exists())

assert probe["schema_version"] == "model_adapter_probe.v1"
assert probe["policy"]["schema_version"] == "model_adapter_policy.v1"
assert probe["request"]["schema_version"] == "llm_request.v1"
assert probe["response"]["schema_version"] == "llm_response.v1"
assert trace["schema_version"] == "llm_trace_ledger.v1"
assert budget["schema_version"] == "llm_budget_ledger.v1"
assert probe["policy"]["llm_enabled"] is False
assert probe["policy"]["default_backend"] == "disabled"
assert probe["policy"]["real_backend_allowed"] is False
assert probe["policy"]["network_access_allowed"] is False
assert probe["response"]["status"] == "blocked_by_policy"
assert probe["response"]["executed"] is False
assert probe["response"]["blocked_by_policy"] is True
assert s["real_model_invoked"] is False
assert s["mock_model_invoked"] is False
assert s["network_access_used"] is False
assert s["files_modified"] is False
assert s["contract_modified"] is False
assert s["generator_unlocked"] is False
assert trace["summary"]["num_entries"] == 1
assert trace["summary"]["num_executed"] == 0
assert trace["summary"]["num_blocked_by_policy"] == 1
assert trace["summary"]["real_model_invocations"] == 0
assert trace["summary"]["mock_model_invocations"] == 0
assert budget["summary"]["attempted_requests"] == 1
assert budget["summary"]["executed_requests"] == 0
assert budget["summary"]["blocked_requests"] == 1
assert budget["summary"]["spent_usd"] == 0.0
assert contract["summary"]["num_blocking"] == 6
assert "GAP-KERNEL-NAME-001" not in contract["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in contract["summary"]["resolved_gap_ids"]
assert contract["migration_decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert len(guard["summary"]["blocking_gap_ids"]) == 6
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]
assert validation["status"] == "pass"
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v023").exists()
PY

echo
echo "DONE."
