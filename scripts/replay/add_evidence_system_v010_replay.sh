#!/usr/bin/env bash
set -e

echo "[v0.0.10] Python syntax check"

python3 -m py_compile \
  xporthls/evidence/artifact_registry.py \
  xporthls/evidence/budget_ledger.py \
  xporthls/evidence/run_evidenced_pipeline_v010.py \
  xporthls/evidence/validate_evidence_v1.py \
  xporthls/contracts/build_contract_v1.py \
  xporthls/contracts/validate_contract_v1.py \
  xporthls/contracts/promote_contract_v1.py \
  xporthls/generators/stub_generator.py

echo "[v0.0.10] Run evidenced pipeline"

python3 -m xporthls.evidence.run_evidenced_pipeline_v010 \
  --case cases/light_ddr \
  --case-id light_ddr \
  --platform platform_packs/v80_aved_2025_1_stub \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --run-id light_ddr_v010

echo "[v0.0.10] Validate evidence"

python3 -m xporthls.evidence.validate_evidence_v1 \
  --registry experiments/runs/light_ddr_artifact_registry_v010.json \
  --budget experiments/runs/light_ddr_budget_ledger_v010.json \
  --replay experiments/runs/light_ddr_replay_manifest_v010.json \
  --out experiments/runs/light_ddr_evidence_report_v010.json

python3 - <<'PY'
import json

registry = json.load(open("experiments/runs/light_ddr_artifact_registry_v010.json"))
budget = json.load(open("experiments/runs/light_ddr_budget_ledger_v010.json"))
replay = json.load(open("experiments/runs/light_ddr_replay_manifest_v010.json"))
report = json.load(open("experiments/runs/light_ddr_evidence_report_v010.json"))
l0post = json.load(open("experiments/runs/light_ddr_l0_post_report_v010.json"))

print()
print("ArtifactRegistry schema:", registry["schema_version"])
print("BudgetLedger schema:", budget["schema_version"])
print("ReplayManifest schema:", replay["schema_version"])
print("Evidence validation:", report["status"])
print("Artifacts:", registry["summary"]["num_artifacts"])
print("Missing artifacts:", registry["summary"]["num_missing"])
print("Tool calls:", budget["summary"]["num_tool_calls"])
print("Failed tool calls:", budget["summary"]["num_failed_tool_calls"])
print("LLM calls:", budget["summary"]["num_llm_calls"])
print("Total wall time sec:", budget["summary"]["total_wall_time_sec"])
print("L0-post status:", l0post["status"])
print("L0-post issues:", len(l0post.get("issues", [])))

assert registry["schema_version"] == "artifact_registry.v1"
assert budget["schema_version"] == "budget_ledger.v1"
assert replay["schema_version"] == "replay_manifest.v1"
assert report["status"] == "pass"
assert registry["summary"]["num_missing"] == 0
assert budget["summary"]["num_tool_calls"] == 7
assert budget["summary"]["num_failed_tool_calls"] == 0
assert budget["summary"]["num_llm_calls"] == 0
assert l0post["status"] == "pass"
assert len(l0post.get("issues", [])) == 0
PY

echo
echo "DONE."
