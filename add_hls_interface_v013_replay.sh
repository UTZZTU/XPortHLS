#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.13] Python syntax check"

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
  xporthls/realrepo/run_hls_interface_v013.py

echo "[v0.0.13] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.13] Re-run v0.0.11 realrepo profile"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

echo "[v0.0.13] Re-run v0.0.12 BuildIR + ConnectivityIR"

python3 -m xporthls.realrepo.run_build_connectivity_v012 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --out-dir experiments/runs

echo "[v0.0.13] Run HLS Interface extraction"

python3 -m xporthls.realrepo.run_hls_interface_v013 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --out-dir experiments/runs

python3 - <<'PY'
import json

source = json.load(open("experiments/runs/hisparse_source_platform_profile_v011.json"))
build = json.load(open("experiments/runs/hisparse_build_ir_v012.json"))
conn = json.load(open("experiments/runs/hisparse_connectivity_ir_v012.json"))
hls = json.load(open("experiments/runs/hisparse_hls_interface_ir_v013.json"))
report = json.load(open("experiments/runs/hisparse_hls_interface_report_v013.json"))

summary = hls["summary"]

print()
print("Source runtime:", source["source_runtime"])
print("Source boards:", source["source_boards_detected"])
print("BuildIR schema:", build["schema_version"])
print("ConnectivityIR schema:", conn["schema_version"])
print("HLS Interface schema:", hls["schema_version"])
print("Validation status:", report["status"])
print("HLS files:", summary["num_hls_files"])
print("Functions:", summary["num_functions"])
print("Kernel candidates:", summary["num_kernel_candidates"])
print("Interface pragmas:", summary["num_interface_pragmas"])
print("Interface types:", summary["interface_types"])
print("m_axi:", summary["num_m_axi"])
print("axis:", summary["num_axis"])
print("s_axilite:", summary["num_s_axilite"])
print("dataflow:", summary["num_dataflow"])
print("stream variables:", summary["num_stream_variables"])
print("include edges:", summary["num_include_edges"])
print("configured kernels:", summary["num_configured_kernels"])
print("matched configured kernels:", summary["num_matched_configured_kernels"])
print("missing declared for config:", summary["num_missing_declared_for_config"])

assert source["source_runtime"] == "XRT"
assert build["schema_version"] == "build_ir.v1"
assert conn["schema_version"] == "connectivity_ir.v1"
assert hls["schema_version"] == "hls_interface_ir.v1"
assert report["status"] in {"pass", "pass_with_warnings"}
assert summary["num_hls_files"] > 0
assert summary["num_kernel_candidates"] > 0
assert summary["num_interface_pragmas"] > 0
assert summary["num_m_axi"] > 0
assert summary["num_axis"] > 0
assert summary["num_dataflow"] > 0
PY

echo
echo "DONE."
