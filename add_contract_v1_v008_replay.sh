#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"

echo "[v0.0.8] Python syntax check"

python3 -m py_compile \
  xporthls/contracts/build_contract_v1.py \
  xporthls/contracts/validate_contract_v1.py \
  xporthls/ir/platform_ir.py \
  xporthls/platforms/platform_pack.py \
  xporthls/cli.py

echo "[v0.0.8] Prepare ApplicationIR"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v008.json

echo "[v0.0.8] Build MigrationContract v1 + ExecutionPolicy v1"

python3 -m xporthls.contracts.build_contract_v1 \
  --app-ir experiments/runs/light_ddr_application_ir_v008.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v008.json \
  --policy-out experiments/runs/light_ddr_execution_policy_v008.json

echo "[v0.0.8] Validate MigrationContract v1"

python3 -m xporthls.contracts.validate_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v008.json \
  --policy experiments/runs/light_ddr_execution_policy_v008.json \
  --out experiments/runs/light_ddr_contract_v1_report_v008.json

echo "[v0.0.8] Run existing L0-pre against MigrationContract v1"

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v008.json \
  --contract experiments/runs/light_ddr_migration_contract_v008.json \
  --out experiments/runs/light_ddr_l0_pre_report_v008.json

python3 - <<'PY'
import json

contract = json.load(open("experiments/runs/light_ddr_migration_contract_v008.json"))
policy = json.load(open("experiments/runs/light_ddr_execution_policy_v008.json"))
creport = json.load(open("experiments/runs/light_ddr_contract_v1_report_v008.json"))
l0 = json.load(open("experiments/runs/light_ddr_l0_pre_report_v008.json"))

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["state"])
print("Target platform:", contract["target_platform"])
print("Target ecosystem:", contract["target_ecosystem"])
print("Subcontracts:", sorted(contract["contracts"].keys()))
print("ExecutionPolicy schema:", policy["schema_version"])
print("ExecutionPolicy llm_enabled:", policy["llm_enabled"])
print("Contract validation:", creport["status"])
print("L0-pre status:", l0["status"])
print("L0-pre issues:", len(l0.get("issues", [])))

assert contract["schema_version"] == "migration_contract.v1"
assert contract["state"] == "Proposed"
assert contract["target_platform"] == "v80_aved_2025_1_stub"
assert contract["target_ecosystem"] == "AVED"
assert policy["schema_version"] == "execution_policy.v1"
assert policy["llm_enabled"] is False
assert creport["status"] == "pass"
assert l0["status"] == "pass"
assert len(l0.get("issues", [])) == 0
PY

echo
echo "DONE."
