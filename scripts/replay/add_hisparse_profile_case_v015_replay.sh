#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

echo "[v0.0.15 clean] Python syntax check"

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
  xporthls/realrepo/run_hisparse_profile_case_v015.py

echo "[v0.0.15 clean] Run HiSparse profile-only case with live output"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

echo "[v0.0.15 clean] Validate HiSparse profile-only case"

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

python3 - <<'PY'
import json

run = json.load(open("experiments/runs/hisparse_u280_profile_case_run_report_v015.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_case_validation_v015.json"))
app = json.load(open("experiments/runs/hisparse_application_ir_v2_v014.json"))

summary = run["summary"]
kg = app["kernel_graph"]["summary"]

print()
print("Case run schema:", run["schema_version"])
print("Case run status:", run["status"])
print("Case validation status:", validation["status"])
print("Case ID:", run["case_id"])
print("Source runtime:", summary["source_runtime"])
print("Source boards:", summary["source_boards"])
print("Source toolchains:", summary["source_toolchains"])
print("Source memory:", summary["source_memory_model"])
print("Target platform:", run["target_platform"])
print("Target ecosystem:", run["target_ecosystem"])
print("Repo files:", summary["repo_files"])
print("Build files:", summary["build_files"])
print("Build targets:", summary["build_targets"])
print("Connectivity directives:", summary["connectivity_directives"])
print("Memory mappings:", summary["memory_mappings"])
print("Stream edges:", summary["stream_edges"])
print("SLR assignments:", summary["slr_assignments"])
print("HLS kernel candidates:", summary["hls_kernel_candidates"])
print("HLS interface pragmas:", summary["hls_interface_pragmas"])
print("Kernel graph nodes:", summary["kernel_graph_nodes"])
print("Configured without declared:", kg["num_configured_without_declared"])
print("Declared without config:", kg["num_declared_without_config"])
print("Unsupported features:", summary["unsupported_features"])
print("Unknowns:", summary["unknowns"])
print("ApplicationIR schema:", summary["application_ir_schema"])
print("ApplicationIR validation:", summary["application_ir_validation_status"])

assert run["schema_version"] == "profile_case_run.v1"
assert run["status"] == "pass"
assert validation["status"] in {"pass", "pass_with_warnings"}
assert run["case_id"] == "hisparse_u280_profile"
assert summary["source_runtime"] == "XRT"
assert "U280" in summary["source_boards"]
assert "2020.2" in summary["source_toolchains"]["vitis_versions"]
assert "xilinx_u280_xdma_201920_3" in summary["source_toolchains"]["shell_platforms"]
assert summary["source_memory_model"] == "HBM"
assert run["target_platform"] == "v80_aved_2025_1_stub"
assert run["target_ecosystem"] == "AVED"
assert summary["repo_files"] >= 100
assert summary["build_files"] >= 8
assert summary["connectivity_directives"] >= 80
assert summary["memory_mappings"] >= 40
assert summary["stream_edges"] >= 10
assert summary["hls_kernel_candidates"] >= 20
assert summary["hls_interface_pragmas"] >= 100
assert summary["application_ir_schema"] == "application_ir.v2"
assert summary["application_ir_validation_status"] in {"pass", "pass_with_warnings"}
PY

echo
echo "DONE."
