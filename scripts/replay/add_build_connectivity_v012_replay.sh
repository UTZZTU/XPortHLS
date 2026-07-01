#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.12] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py

echo "[v0.0.12] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.12] Re-run v0.0.11 profile for fresh baseline"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

echo "[v0.0.12] Run BuildIR + ConnectivityIR extraction"

python3 -m xporthls.realrepo.run_build_connectivity_v012 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --out-dir experiments/runs

python3 - <<'PY'
import json

census = json.load(open("experiments/runs/hisparse_repo_census_v011.json"))
source = json.load(open("experiments/runs/hisparse_source_platform_profile_v011.json"))
build = json.load(open("experiments/runs/hisparse_build_ir_v012.json"))
conn = json.load(open("experiments/runs/hisparse_connectivity_ir_v012.json"))
report = json.load(open("experiments/runs/hisparse_build_connectivity_report_v012.json"))

print()
print("Census schema:", census["schema_version"])
print("Source runtime:", source["source_runtime"])
print("Source boards:", source["source_boards_detected"])
print("BuildIR schema:", build["schema_version"])
print("ConnectivityIR schema:", conn["schema_version"])
print("Validation status:", report["status"])
print("Build files:", build["summary"]["num_build_files"])
print("Targets:", build["summary"]["num_targets"])
print("Commands:", build["summary"]["num_commands"])
print("Command kinds:", build["summary"]["command_kinds"])
print("Detected platforms:", build["summary"]["detected_platforms"])
print("Config refs:", build["summary"]["config_refs"])
print("Config files:", conn["summary"]["num_config_files"])
print("Directives:", conn["summary"]["num_directives"])
print("Memory mappings:", conn["summary"]["num_memory_mappings"])
print("Compute-unit directives:", conn["summary"]["num_compute_unit_directives"])
print("Stream edges:", conn["summary"]["num_stream_edges"])
print("SLR assignments:", conn["summary"]["num_slr_assignments"])
print("Memory kinds:", conn["summary"]["memory_kinds"])

assert census["schema_version"] == "repo_census.v1"
assert source["source_runtime"] == "XRT"
assert build["schema_version"] == "build_ir.v1"
assert conn["schema_version"] == "connectivity_ir.v1"
assert report["status"] in {"pass", "pass_with_warnings"}
assert build["summary"]["num_build_files"] > 0
assert conn["summary"]["num_config_files"] > 0
assert conn["summary"]["num_directives"] > 0
assert conn["summary"]["num_memory_mappings"] > 0
assert "U280" in source["source_boards_detected"] or build["summary"]["detected_platforms"]
PY

echo
echo "DONE."
