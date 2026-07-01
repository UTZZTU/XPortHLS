#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.14] Python syntax check"

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
  xporthls/realrepo/run_application_ir_v2_v014.py

echo "[v0.0.14] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.14] Re-run v0.0.11 realrepo profile"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

echo "[v0.0.14] Re-run v0.0.12 BuildIR + ConnectivityIR"

python3 -m xporthls.realrepo.run_build_connectivity_v012 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --out-dir experiments/runs

echo "[v0.0.14] Re-run v0.0.13 HLS Interface IR"

python3 -m xporthls.realrepo.run_hls_interface_v013 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --out-dir experiments/runs

echo "[v0.0.14] Build ApplicationIR v2"

python3 -m xporthls.realrepo.run_application_ir_v2_v014 \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --census experiments/runs/hisparse_repo_census_v011.json \
  --source-profile experiments/runs/hisparse_source_platform_profile_v011.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --compatibility-profile experiments/runs/hisparse_compatibility_profile_v011.json \
  --out-dir experiments/runs

python3 - <<'PY'
import json

app = json.load(open("experiments/runs/hisparse_application_ir_v2_v014.json"))
report = json.load(open("experiments/runs/hisparse_application_ir_v2_report_v014.json"))

summary = app["summary"]
kg = app["kernel_graph"]["summary"]
mem = app["memory_topology"]["summary"]

print()
print("ApplicationIR schema:", app["schema_version"])
print("Validation status:", report["status"])
print("Migration status:", app["migration_status"])
print("Source runtime:", app["source_runtime"])
print("Source boards:", app["source"]["boards"])
print("Source memory:", app["source"]["memory_model"])
print("Target:", app["target"])
print("Files:", summary["num_files"])
print("Build files:", summary["num_build_files"])
print("Build targets:", summary["num_build_targets"])
print("Connectivity directives:", summary["num_connectivity_directives"])
print("Memory mappings:", summary["num_memory_mappings"])
print("Stream edges:", summary["num_stream_edges"])
print("HLS files:", summary["num_hls_files"])
print("HLS kernel candidates:", summary["num_hls_kernel_candidates"])
print("HLS interface pragmas:", summary["num_hls_interface_pragmas"])
print("Kernel graph nodes:", kg["num_kernels"])
print("Configured kernels:", kg["num_configured_kernels"])
print("Declared kernels:", kg["num_declared_kernels"])
print("Configured without declared:", kg["num_configured_without_declared"])
print("Declared without config:", kg["num_declared_without_config"])
print("Memory kinds:", mem["memory_kinds"])
print("Unsupported features:", summary["num_unsupported_features"])
print("Unknowns:", summary["num_unknowns"])
print("Next capabilities:", app["compatibility"]["required_next_capabilities"])

assert app["schema_version"] == "application_ir.v2"
assert app["migration_status"] == "profile_only"
assert app["source_runtime"] == "XRT"
assert app["target"]["platform"] == "v80_aved_2025_1_stub"
assert app["target"]["ecosystem"] == "AVED"
assert report["status"] in {"pass", "pass_with_warnings"}
assert summary["num_files"] > 0
assert summary["num_build_files"] > 0
assert summary["num_connectivity_directives"] > 0
assert summary["num_hls_kernel_candidates"] > 0
assert summary["num_hls_interface_pragmas"] > 0
assert kg["num_kernels"] > 0
assert mem["num_memory_mappings"] > 0
PY

echo
echo "DONE."
