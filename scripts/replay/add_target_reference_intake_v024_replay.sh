#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

TARGET_REF_ZIP="${TARGET_REF_ZIP:-/mnt/data/SPMV-on-V80-main.zip}"
TARGET_REF_BASE="${TARGET_REF_BASE:-/mnt/data/xporthls_target_refs}"
TARGET_REF_ROOT="${TARGET_REF_ROOT:-${TARGET_REF_BASE}/SPMV-on-V80-main}"

PATCHED_CONTRACT="experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_targetref_v024.json"
REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v024"

TARGET_IR="experiments/runs/spmv_on_v80_target_reference_ir_v024.json"
TARGET_REPORT="experiments/runs/spmv_on_v80_target_reference_report_v024.json"
TARGET_VALIDATION="experiments/runs/spmv_on_v80_target_reference_validation_v024.json"

echo "[v0.0.24] Python syntax check"

python3 -m py_compile \
  xporthls/targetref/target_reference_ir_v024.py \
  xporthls/targetref/validate_target_reference_v024.py \
  xporthls/targetref/run_target_reference_intake_v024.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.24] Locate or unpack target reference"

if [ ! -d "$TARGET_REF_ROOT" ]; then
  if [ -f "$TARGET_REF_ZIP" ]; then
    mkdir -p "$TARGET_REF_BASE"
    python3 - <<PY
from pathlib import Path
import zipfile

zip_path = Path("$TARGET_REF_ZIP")
base = Path("$TARGET_REF_BASE")
base.mkdir(parents=True, exist_ok=True)

print(f"[xporthls] Extracting {zip_path} -> {base}")
with zipfile.ZipFile(zip_path, "r") as z:
    z.extractall(base)

expected = Path("$TARGET_REF_ROOT")
if not expected.exists():
    dirs = [p for p in base.iterdir() if p.is_dir() and "SPMV" in p.name.upper()]
    if dirs:
        print(f"[xporthls] Found extracted target reference candidate: {dirs[0]}")
    else:
        print("[xporthls] WARNING: expected target reference root not found after extraction.")
PY
  fi
fi

if [ ! -d "$TARGET_REF_ROOT" ]; then
  echo
  echo "[xporthls] ERROR: target reference root not found:"
  echo "  $TARGET_REF_ROOT"
  echo
  echo "Please upload or copy SPMV-on-V80-main.zip to one of these paths:"
  echo "  /mnt/data/SPMV-on-V80-main.zip"
  echo "or set TARGET_REF_ZIP=/path/to/SPMV-on-V80-main.zip"
  echo
  echo "Example:"
  echo "  TARGET_REF_ZIP=/home/wwb/SPMV-on-V80-main.zip ./add_target_reference_intake_v024_replay.sh"
  exit 3
fi

echo "[xporthls] Target reference root: $TARGET_REF_ROOT"

echo "[v0.0.24] Run generator guard against patched contract if available"

if [ -f "$PATCHED_CONTRACT" ]; then
  rm -rf "$REQUESTED_OUT"

  python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
    --contract "$PATCHED_CONTRACT" \
    --case-id hisparse_u280_profile \
    --requested-output-dir "$REQUESTED_OUT" \
    --report-out "$GUARD_REPORT" \
    --generator-name stub_generator \
    --expect-blocked \
    --dry-run
else
  echo "[xporthls] WARNING: patched contract not found; skipping generator guard evidence:"
  echo "  $PATCHED_CONTRACT"
  GUARD_REPORT=""
fi

echo "[v0.0.24] Run target reference intake"

if [ -n "${GUARD_REPORT:-}" ] && [ -f "$GUARD_REPORT" ]; then
  python3 -m xporthls.targetref.run_target_reference_intake_v024 \
    --case-id spmv_on_v80 \
    --target-name SPMV-on-V80 \
    --target-root "$TARGET_REF_ROOT" \
    --guard-report "$GUARD_REPORT" \
    --out-dir experiments/runs
else
  python3 -m xporthls.targetref.run_target_reference_intake_v024 \
    --case-id spmv_on_v80 \
    --target-name SPMV-on-V80 \
    --target-root "$TARGET_REF_ROOT" \
    --out-dir experiments/runs
fi

python3 - <<'PY'
import json
from pathlib import Path

target_ir = json.load(open("experiments/runs/spmv_on_v80_target_reference_ir_v024.json", encoding="utf-8"))
report = json.load(open("experiments/runs/spmv_on_v80_target_reference_report_v024.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/spmv_on_v80_target_reference_validation_v024.json", encoding="utf-8"))

s = target_ir["summary"]

print()
print("TargetReferenceIR schema:", target_ir["schema_version"])
print("Migration direction:", target_ir["migration_direction"])
print("Target ecosystem:", target_ir["target_ecosystem"])
print("Target board:", target_ir["target_board"])
print("Files:", s["files_total"])
print("Documents:", s["documentation_files"])
print("Variants:", s["variant_count"])
print("QDMA evidence:", s["host_qdma_evidence_count"])
print("AXI-Lite evidence:", s["host_axi_lite_evidence_count"])
print("AP_CTRL evidence:", s["host_ap_ctrl_evidence_count"])
print("HLS m_axi evidence:", s["hls_m_axi_evidence_count"])
print("HLS axis evidence:", s["hls_axis_evidence_count"])
print("HLS packaging evidence:", s["hls_packaging_evidence_count"])
print("create_design.tcl:", s["create_design_tcl_count"])
print("create_bd_design.tcl:", s["create_bd_design_tcl_count"])
print("BD connect_bd_intf_net:", s["bd_connect_bd_intf_net_count"])
print("BD assign_bd_address:", s["bd_assign_bd_address_count"])
print("Manual operations:", len(target_ir["manual_operation_trace"]["operations"]))
print("F_VERSION_CORRECTNESS:", s["has_f_version_correctness"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])

if Path("experiments/runs/hisparse_u280_profile_generator_guard_targetref_v024.json").exists():
    guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_targetref_v024.json", encoding="utf-8"))
    print("Guard blocked:", guard["decision"]["blocked"])
    print("Guard allowed:", guard["decision"]["allowed"])
    print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])
    assert guard["decision"]["blocked"] is True
    assert guard["decision"]["allowed"] is False
    assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]

assert target_ir["schema_version"] == "target_reference_ir.v1"
assert target_ir["xporthls_version"] == "v0.0.24"
assert target_ir["migration_direction"] == "XRT->AVED"
assert target_ir["target_ecosystem"] == "AVED"
assert target_ir["target_board"] == "V80"
assert target_ir["llm_annotations"] == []
assert target_ir["trust_boundary"]["llm_used"] is False
assert target_ir["trust_boundary"]["contract_modified"] is False
assert target_ir["trust_boundary"]["generator_unlocked"] is False
assert s["files_total"] > 0
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0

# v0.0.24 should generally find these in SPMV-on-V80. Keep them as strong checks.
assert s["documentation_files"] > 0
assert s["variant_count"] > 0
assert s["host_qdma_evidence_count"] > 0
assert s["host_axi_lite_evidence_count"] > 0
assert s["hls_axis_evidence_count"] > 0
assert s["create_design_tcl_count"] > 0
assert s["create_bd_design_tcl_count"] > 0
assert s["bd_connect_bd_intf_net_count"] > 0
PY

echo
echo "DONE."
