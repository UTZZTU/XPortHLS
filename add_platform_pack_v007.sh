#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"

echo "[v0.0.7] Python syntax check"
python3 -m py_compile \
  xporthls/ir/platform_ir.py \
  xporthls/platforms/platform_pack.py \
  xporthls/cli.py

echo "[v0.0.7] Validate Platform Pack"
python3 -m xporthls.platforms.platform_pack \
  --pack "$PACK_DIR" \
  --out experiments/runs/v80_aved_2025_1_platform_pack_report_v007.json

echo "[v0.0.7] Check PlatformIR compatibility"
python3 - <<'PY'
from xporthls.ir.platform_ir import PlatformIR

p = PlatformIR.load_json("platform_packs/v80_aved_2025_1_stub")
print("PlatformIR id:", p.id)
print("PlatformIR status:", p.status)
print("PlatformIR target:", p.target)

assert p.id == "v80_aved_2025_1_stub"
assert p.target.get("ecosystem") == "AVED"
assert p.status
PY

echo "[v0.0.7] Run scan + contract + L0-pre using Platform Pack"
python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v007.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v007.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v007.json

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v007.json \
  --contract experiments/runs/light_ddr_migration_contract_v007.json \
  --out experiments/runs/light_ddr_l0_pre_report_v007.json

python3 - <<'PY'
import json

pack_report = json.load(open("experiments/runs/v80_aved_2025_1_platform_pack_report_v007.json"))
contract = json.load(open("experiments/runs/light_ddr_migration_contract_v007.json"))
l0 = json.load(open("experiments/runs/light_ddr_l0_pre_report_v007.json"))

print()
print("Platform Pack status:", pack_report["status"])
print("Platform ID:", pack_report["platform_id"])
print("Contract target_platform:", contract.get("target_platform"))
print("L0-pre status:", l0["status"])
print("L0-pre issues:", len(l0.get("issues", [])))

assert pack_report["status"] == "pass"
assert contract.get("target_platform") == "v80_aved_2025_1_stub"
assert l0["status"] == "pass"
assert len(l0.get("issues", [])) == 0
PY

echo
echo "DONE."
