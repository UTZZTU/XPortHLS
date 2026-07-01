#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.11] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py

echo "[v0.0.11] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.11] Run real repository profiling"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

python3 - <<'PY'
import json

census = json.load(open("experiments/runs/hisparse_repo_census_v011.json"))
source = json.load(open("experiments/runs/hisparse_source_platform_profile_v011.json"))
compat = json.load(open("experiments/runs/hisparse_compatibility_profile_v011.json"))
report = json.load(open("experiments/runs/hisparse_realrepo_profile_report_v011.json"))

print()
print("Census schema:", census["schema_version"])
print("Source profile schema:", source["schema_version"])
print("Compatibility schema:", compat["schema_version"])
print("Validation status:", report["status"])
print("Files:", census["summary"]["num_files"])
print("Roles:", census["summary"]["roles"])
print("Source runtime:", source["source_runtime"])
print("Boards:", source["source_boards_detected"])
print("Toolchains:", source["source_toolchains_detected"])
print("Memory model:", source["source_memory_model"])
print("Complexity:", source["complexity"]["level"])
print("Migration status:", compat["migration_status"])
print("Next capabilities:", compat["required_next_capabilities"])

assert census["schema_version"] == "repo_census.v1"
assert source["schema_version"] == "source_platform_profile.v1"
assert compat["schema_version"] == "compatibility_profile.v1"
assert report["status"] in {"pass", "pass_with_warnings"}
assert census["summary"]["num_files"] > 0
assert compat["target_platform"] == "v80_aved_2025_1_stub"
assert compat["target_ecosystem"] == "AVED"
assert compat["migration_status"] == "profile_only"
assert "U280" in source["source_boards_detected"] or source["source_runtime"] == "XRT"
PY

echo
echo "DONE."
