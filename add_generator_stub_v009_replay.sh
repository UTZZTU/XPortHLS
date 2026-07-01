#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"
GEN_DIR="experiments/runs/light_ddr_generated_v009"

echo "[v0.0.9] Python syntax check"

python3 -m py_compile \
  xporthls/contracts/build_contract_v1.py \
  xporthls/contracts/validate_contract_v1.py \
  xporthls/contracts/promote_contract_v1.py \
  xporthls/generators/stub_generator.py \
  xporthls/validators/l0_post_checker.py \
  xporthls/validators/run_l0.py

echo "[v0.0.9] Build ApplicationIR + Contract v1 + ExecutionPolicy"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v009.json

python3 -m xporthls.contracts.build_contract_v1 \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --policy-out experiments/runs/light_ddr_execution_policy_v009.json

python3 -m xporthls.contracts.validate_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --policy experiments/runs/light_ddr_execution_policy_v009.json \
  --out experiments/runs/light_ddr_contract_v1_report_v009.json

echo "[v0.0.9] Run L0-pre and promote contract"

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --out experiments/runs/light_ddr_l0_pre_report_v009.json

python3 -m xporthls.contracts.promote_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --l0-report experiments/runs/light_ddr_l0_pre_report_v009.json \
  --out experiments/runs/light_ddr_migration_contract_v009_static.json

echo "[v0.0.9] Generate stub target project"

python3 -m xporthls.generators.stub_generator \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --contract experiments/runs/light_ddr_migration_contract_v009_static.json \
  --policy experiments/runs/light_ddr_execution_policy_v009.json \
  --platform "$PACK_DIR" \
  --out-dir "$GEN_DIR" \
  --clean

echo "[v0.0.9] Run L0-post on generated project"

python3 -m xporthls.validators.run_l0 \
  --stage post \
  --project "$GEN_DIR" \
  --contract experiments/runs/light_ddr_migration_contract_v009_static.json \
  --out experiments/runs/light_ddr_l0_post_report_v009.json

python3 - <<'PY'
import json
from pathlib import Path

manifest = json.load(open("experiments/runs/light_ddr_generated_v009/xporthls_generated_manifest.json"))
static_contract = json.load(open("experiments/runs/light_ddr_migration_contract_v009_static.json"))
post = json.load(open("experiments/runs/light_ddr_l0_post_report_v009.json"))

print()
print("Generated manifest schema:", manifest["schema_version"])
print("Generated target_platform:", manifest["target_platform"])
print("Generated artifacts:", sorted(manifest["artifacts"].keys()))
print("Contract state:", static_contract["state"])
print("L0-post status:", post["status"])
print("L0-post issues:", len(post.get("issues", [])))
print("Forbidden source-runtime hits:", post.get("summary", {}).get("num_forbidden_xrt_hits"))

assert manifest["schema_version"] == "xporthls_generated_manifest.v1"
assert manifest["target_platform"] == "v80_aved_2025_1_stub"
assert static_contract["state"] == "StaticallyChecked"
assert post["status"] == "pass"
assert len(post.get("issues", [])) == 0
assert post.get("summary", {}).get("num_forbidden_xrt_hits") == 0

for rel in manifest["artifacts"].values():
    assert (Path("experiments/runs/light_ddr_generated_v009") / rel).exists(), rel
PY

echo
echo "DONE."
