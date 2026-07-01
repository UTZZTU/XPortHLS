#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"

echo "[v0.0.21] Python syntax check"

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
  xporthls/realrepo/run_kernel_alias_resolution_v021.py

echo "[v0.0.21] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.21] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.21] Run Kernel Alias Table + Resolver v2"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run generator guard to prove generation is still blocked"

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

alias_table = json.load(open("experiments/runs/hisparse_u280_profile_kernel_alias_table_v021.json"))
v2 = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json"))
proposal = json.load(open("experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_alias_resolution_validation_v021.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

a = alias_table["summary"]
v = v2["summary"]
p = proposal["summary"]

print()
print("Alias table schema:", alias_table["schema_version"])
print("Aliases:", a["num_aliases"])
print("All v1 unresolved have aliases:", a["all_v1_unresolved_have_alias_candidates"])
print("V2 schema:", v2["schema_version"])
print("V2 resolution state:", v2["resolution_state"])
print("V1 matches:", v["num_v1_matches"])
print("V2 alias matches:", v["num_v2_alias_matches"])
print("Total matches:", v["num_total_matches"])
print("Unresolved configured:", v["num_unresolved_configured"])
print("All configured resolved:", v["all_configured_resolved"])
print("Proposal schema:", proposal["schema_version"])
print("Proposal state:", proposal["proposal_state"])
print("Remove from blocking:", proposal["proposed_contract_delta"]["remove_from_blocking_gap_ids"])
print("Remaining blocking count:", proposal["proposed_contract_delta"]["remaining_blocking_count"])
print("Migration allowed after single gap update:", proposal["proposed_contract_delta"]["migration_allowed_after_this_single_gap_update"])
print("Generator unlock allowed:", p["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert alias_table["schema_version"] == "kernel_alias_table.v1"
assert v2["schema_version"] == "kernel_name_resolution_report_v2.v1"
assert proposal["schema_version"] == "kernel_gap_contract_update_proposal.v1"
assert alias_table["policy"]["llm_used"] is False
assert v2["policy"]["llm_used"] is False
assert proposal["policy"]["llm_used"] is False
assert alias_table["policy"]["generator_unlock_allowed"] is False
assert v2["policy"]["generator_unlock_allowed"] is False
assert proposal["policy"]["generator_unlock_allowed"] is False
assert a["num_aliases"] > 0
assert v["num_total_matches"] == v["num_v1_matches"] + v["num_v2_alias_matches"]
assert v["generator_unlock_allowed"] is False
assert p["generator_unlock_allowed"] is False
assert proposal["proposed_contract_delta"]["migration_allowed_after_this_single_gap_update"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
