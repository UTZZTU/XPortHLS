#!/usr/bin/env bash
set -e

echo "[1/6] Add evidence package"

mkdir -p xporthls/evidence
touch xporthls/evidence/__init__.py

cat > xporthls/evidence/artifact_registry.py <<'EOT'
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def directory_digest(path: Path) -> tuple[str, int]:
    entries: list[dict[str, Any]] = []

    for file_path in sorted(path.rglob("*")):
        if not file_path.is_file():
            continue

        entries.append({
            "relative_path": str(file_path.relative_to(path)),
            "size_bytes": file_path.stat().st_size,
            "sha256": sha256_file(file_path)
        })

    payload = json.dumps(entries, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest(), len(entries)


def make_file_artifact(role: str, path: str, artifact_type: str, stage: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists() and p.is_file()

    record: dict[str, Any] = {
        "role": role,
        "type": artifact_type,
        "stage": stage,
        "path": str(p),
        "exists": exists,
        "kind": "file"
    }

    if exists:
        record.update({
            "size_bytes": p.stat().st_size,
            "sha256": sha256_file(p)
        })

    return record


def make_directory_artifact(role: str, path: str, artifact_type: str, stage: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists() and p.is_dir()

    record: dict[str, Any] = {
        "role": role,
        "type": artifact_type,
        "stage": stage,
        "path": str(p),
        "exists": exists,
        "kind": "directory"
    }

    if exists:
        digest, num_files = directory_digest(p)
        record.update({
            "num_files": num_files,
            "sha256": digest
        })

    return record


def build_artifact_registry(
    run_id: str,
    case_id: str,
    target_platform: str,
    target_ecosystem: str,
    artifacts: list[dict[str, Any]],
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": "artifact_registry.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "created_at_utc": utc_now(),
        "artifacts": artifacts,
        "summary": {
            "num_artifacts": len(artifacts),
            "num_missing": sum(1 for a in artifacts if not a.get("exists")),
            "roles": sorted(a.get("role") for a in artifacts)
        },
        "metadata": metadata or {}
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)
EOT

echo "[2/6] Add budget ledger"

cat > xporthls/evidence/budget_ledger.py <<'EOT'
from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_budget_ledger(run_id: str, case_id: str, target_platform: str) -> dict[str, Any]:
    return {
        "schema_version": "budget_ledger.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "created_at_utc": utc_now(),
        "mode": "deterministic_pipeline_only",
        "llm_enabled": False,
        "tool_calls": [],
        "llm_calls": [],
        "summary": {
            "num_tool_calls": 0,
            "num_failed_tool_calls": 0,
            "num_llm_calls": 0,
            "total_wall_time_sec": 0.0,
            "total_prompt_tokens": 0,
            "total_completion_tokens": 0,
            "total_tokens": 0
        }
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _tail(text: str, max_lines: int = 40) -> str:
    lines = text.splitlines()
    return "\n".join(lines[-max_lines:])


def refresh_summary(ledger: dict[str, Any]) -> None:
    calls = ledger.get("tool_calls", [])
    ledger["summary"] = {
        "num_tool_calls": len(calls),
        "num_failed_tool_calls": sum(1 for c in calls if c.get("return_code") != 0),
        "num_llm_calls": len(ledger.get("llm_calls", [])),
        "total_wall_time_sec": round(sum(float(c.get("duration_sec", 0.0)) for c in calls), 6),
        "total_prompt_tokens": 0,
        "total_completion_tokens": 0,
        "total_tokens": 0
    }


def run_logged(
    ledger: dict[str, Any],
    stage: str,
    name: str,
    command: list[str],
    cwd: str | None = None,
    partial_ledger_path: str | None = None,
) -> subprocess.CompletedProcess[str]:
    start_wall = utc_now()
    start = time.perf_counter()

    print(f"[xporthls-budget] START {stage}/{name}")
    print("[xporthls-budget] CMD:", " ".join(command))

    proc = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        capture_output=True,
    )

    duration = time.perf_counter() - start
    end_wall = utc_now()

    if proc.stdout:
        print(proc.stdout, end="")
    if proc.stderr:
        print(proc.stderr, file=sys.stderr, end="")

    record = {
        "stage": stage,
        "name": name,
        "command": command,
        "started_at_utc": start_wall,
        "ended_at_utc": end_wall,
        "duration_sec": round(duration, 6),
        "return_code": proc.returncode,
        "stdout_tail": _tail(proc.stdout),
        "stderr_tail": _tail(proc.stderr),
        "budget": {
            "credit_cost": 1,
            "llm_prompt_tokens": 0,
            "llm_completion_tokens": 0,
            "llm_total_tokens": 0
        }
    }

    ledger.setdefault("tool_calls", []).append(record)
    refresh_summary(ledger)

    if partial_ledger_path:
        save_json(partial_ledger_path, ledger)

    print(f"[xporthls-budget] END {stage}/{name} rc={proc.returncode} duration={duration:.3f}s")

    if proc.returncode != 0:
        raise RuntimeError(f"Command failed at {stage}/{name}: {' '.join(command)}")

    return proc
EOT

echo "[3/6] Add evidenced pipeline runner"

cat > xporthls/evidence/run_evidenced_pipeline_v010.py <<'EOT'
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from xporthls.evidence.artifact_registry import (
    build_artifact_registry,
    load_json,
    make_directory_artifact,
    make_file_artifact,
    save_json,
)
from xporthls.evidence.budget_ledger import new_budget_ledger, run_logged, save_json as save_budget_json


def default_run_id(case_id: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{case_id}_v010_{stamp}"


def build_replay_manifest(
    run_id: str,
    case_id: str,
    target_platform: str,
    target_ecosystem: str,
    budget_ledger: dict[str, Any],
    paths: dict[str, str],
) -> dict[str, Any]:
    return {
        "schema_version": "replay_manifest.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "working_directory": str(Path.cwd()),
        "commands": [
            {
                "stage": c.get("stage"),
                "name": c.get("name"),
                "command": c.get("command"),
                "return_code": c.get("return_code")
            }
            for c in budget_ledger.get("tool_calls", [])
        ],
        "paths": paths,
        "replay_note": "Run these commands from repository root. Runtime outputs are intentionally stored under experiments/runs."
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.10 evidenced XPortHLS pipeline")
    parser.add_argument("--case", default="cases/light_ddr")
    parser.add_argument("--case-id", default="light_ddr")
    parser.add_argument("--platform", default="platform_packs/v80_aved_2025_1_stub")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--run-id", default=None)
    args = parser.parse_args()

    case_id = args.case_id
    run_id = args.run_id or default_run_id(case_id)

    paths = {
        "application_ir": "experiments/runs/light_ddr_application_ir_v010.json",
        "contract_proposed": "experiments/runs/light_ddr_migration_contract_v010_proposed.json",
        "execution_policy": "experiments/runs/light_ddr_execution_policy_v010.json",
        "contract_validation_report": "experiments/runs/light_ddr_contract_v1_report_v010.json",
        "l0_pre_report": "experiments/runs/light_ddr_l0_pre_report_v010.json",
        "contract_static": "experiments/runs/light_ddr_migration_contract_v010_static.json",
        "generated_project": "experiments/runs/light_ddr_generated_v010",
        "l0_post_report": "experiments/runs/light_ddr_l0_post_report_v010.json",
        "artifact_registry": "experiments/runs/light_ddr_artifact_registry_v010.json",
        "budget_ledger": "experiments/runs/light_ddr_budget_ledger_v010.json",
        "replay_manifest": "experiments/runs/light_ddr_replay_manifest_v010.json",
    }

    ledger = new_budget_ledger(run_id, case_id, args.target_platform)
    partial_budget = paths["budget_ledger"]

    py = sys.executable

    run_logged(
        ledger,
        "scan",
        "application_ir",
        [py, "-m", "xporthls.cli", "scan", "--case", args.case, "--out", paths["application_ir"]],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "build_contract_v1",
        [
            py, "-m", "xporthls.contracts.build_contract_v1",
            "--app-ir", paths["application_ir"],
            "--platform", args.platform,
            "--out", paths["contract_proposed"],
            "--policy-out", paths["execution_policy"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "validate_contract_v1",
        [
            py, "-m", "xporthls.contracts.validate_contract_v1",
            "--contract", paths["contract_proposed"],
            "--policy", paths["execution_policy"],
            "--out", paths["contract_validation_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "validation",
        "l0_pre",
        [
            py, "-m", "xporthls.validators.run_l0",
            "--stage", "pre",
            "--app-ir", paths["application_ir"],
            "--contract", paths["contract_proposed"],
            "--out", paths["l0_pre_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "promote_contract_v1",
        [
            py, "-m", "xporthls.contracts.promote_contract_v1",
            "--contract", paths["contract_proposed"],
            "--l0-report", paths["l0_pre_report"],
            "--out", paths["contract_static"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "generation",
        "stub_generator",
        [
            py, "-m", "xporthls.generators.stub_generator",
            "--app-ir", paths["application_ir"],
            "--contract", paths["contract_static"],
            "--policy", paths["execution_policy"],
            "--platform", args.platform,
            "--out-dir", paths["generated_project"],
            "--clean",
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "validation",
        "l0_post",
        [
            py, "-m", "xporthls.validators.run_l0",
            "--stage", "post",
            "--project", paths["generated_project"],
            "--contract", paths["contract_static"],
            "--out", paths["l0_post_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    static_contract = load_json(paths["contract_static"])
    manifest_path = str(Path(paths["generated_project"]) / "xporthls_generated_manifest.json")

    artifacts = [
        make_file_artifact("application_ir", paths["application_ir"], "json", "scan"),
        make_file_artifact("migration_contract_proposed", paths["contract_proposed"], "json", "contract"),
        make_file_artifact("execution_policy", paths["execution_policy"], "json", "contract"),
        make_file_artifact("contract_v1_validation_report", paths["contract_validation_report"], "json", "contract"),
        make_file_artifact("l0_pre_report", paths["l0_pre_report"], "json", "validation"),
        make_file_artifact("migration_contract_static", paths["contract_static"], "json", "contract"),
        make_directory_artifact("generated_project", paths["generated_project"], "directory", "generation"),
        make_file_artifact("generated_manifest", manifest_path, "json", "generation"),
        make_file_artifact("l0_post_report", paths["l0_post_report"], "json", "validation"),
    ]

    registry = build_artifact_registry(
        run_id=run_id,
        case_id=case_id,
        target_platform=static_contract.get("target_platform", args.target_platform),
        target_ecosystem=static_contract.get("target_ecosystem", args.target_ecosystem),
        artifacts=artifacts,
        metadata={
            "xporthls_version": "v0.0.10",
            "pipeline": "ApplicationIR -> Contract v1 -> L0-pre -> StaticallyChecked -> Generator stub -> L0-post",
            "platform_pack": args.platform
        }
    )

    replay = build_replay_manifest(
        run_id=run_id,
        case_id=case_id,
        target_platform=static_contract.get("target_platform", args.target_platform),
        target_ecosystem=static_contract.get("target_ecosystem", args.target_ecosystem),
        budget_ledger=ledger,
        paths=paths,
    )

    save_json(paths["artifact_registry"], registry)
    save_budget_json(paths["budget_ledger"], ledger)
    save_json(paths["replay_manifest"], replay)

    print(f"[xporthls] ArtifactRegistry written to: {paths['artifact_registry']}")
    print(f"[xporthls] BudgetLedger written to: {paths['budget_ledger']}")
    print(f"[xporthls] ReplayManifest written to: {paths['replay_manifest']}")
    print(f"[xporthls] Run ID: {run_id}")
    print(f"[xporthls] Tool calls: {ledger['summary']['num_tool_calls']}")
    print(f"[xporthls] LLM calls: {ledger['summary']['num_llm_calls']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Add evidence validator"

cat > xporthls/evidence/validate_evidence_v1.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any

from xporthls.evidence.artifact_registry import directory_digest, sha256_file


@dataclass
class EvidenceIssue:
    severity: str
    code: str
    message: str


@dataclass
class EvidenceValidationReport:
    status: str
    issues: list[EvidenceIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_artifact_hash(artifact: dict[str, Any]) -> EvidenceIssue | None:
    p = Path(artifact.get("path", ""))

    if not p.exists():
        return EvidenceIssue("error", "ARTIFACT_MISSING", f"Missing artifact: {artifact.get('role')} at {p}")

    if artifact.get("kind") == "file":
        if not p.is_file():
            return EvidenceIssue("error", "ARTIFACT_KIND_MISMATCH", f"Expected file: {p}")
        actual = sha256_file(p)
    elif artifact.get("kind") == "directory":
        if not p.is_dir():
            return EvidenceIssue("error", "ARTIFACT_KIND_MISMATCH", f"Expected directory: {p}")
        actual, _ = directory_digest(p)
    else:
        return EvidenceIssue("error", "ARTIFACT_KIND_UNKNOWN", f"Unknown artifact kind: {artifact.get('kind')}")

    if actual != artifact.get("sha256"):
        return EvidenceIssue("error", "ARTIFACT_HASH_MISMATCH", f"SHA256 mismatch for {artifact.get('role')}")

    return None


def validate_evidence(registry: dict[str, Any], budget: dict[str, Any], replay: dict[str, Any]) -> EvidenceValidationReport:
    issues: list[EvidenceIssue] = []

    if registry.get("schema_version") != "artifact_registry.v1":
        issues.append(EvidenceIssue("error", "REGISTRY_SCHEMA_VERSION", "Expected artifact_registry.v1."))

    if budget.get("schema_version") != "budget_ledger.v1":
        issues.append(EvidenceIssue("error", "BUDGET_SCHEMA_VERSION", "Expected budget_ledger.v1."))

    if replay.get("schema_version") != "replay_manifest.v1":
        issues.append(EvidenceIssue("error", "REPLAY_SCHEMA_VERSION", "Expected replay_manifest.v1."))

    if registry.get("run_id") != budget.get("run_id") or registry.get("run_id") != replay.get("run_id"):
        issues.append(EvidenceIssue("error", "RUN_ID_MISMATCH", "Registry, budget and replay manifest run_id must match."))

    required_roles = {
        "application_ir",
        "migration_contract_proposed",
        "execution_policy",
        "contract_v1_validation_report",
        "l0_pre_report",
        "migration_contract_static",
        "generated_project",
        "generated_manifest",
        "l0_post_report",
    }

    artifacts = registry.get("artifacts", [])
    roles = {a.get("role") for a in artifacts}

    for role in sorted(required_roles - roles):
        issues.append(EvidenceIssue("error", "ARTIFACT_ROLE_MISSING", f"Missing artifact role: {role}"))

    for artifact in artifacts:
        issue = validate_artifact_hash(artifact)
        if issue:
            issues.append(issue)

    calls = budget.get("tool_calls", [])
    required_call_names = {
        "application_ir",
        "build_contract_v1",
        "validate_contract_v1",
        "l0_pre",
        "promote_contract_v1",
        "stub_generator",
        "l0_post",
    }

    call_names = {c.get("name") for c in calls}

    for name in sorted(required_call_names - call_names):
        issues.append(EvidenceIssue("error", "TOOL_CALL_MISSING", f"Missing tool call: {name}"))

    for call in calls:
        if call.get("return_code") != 0:
            issues.append(EvidenceIssue("error", "TOOL_CALL_FAILED", f"Tool call failed: {call.get('name')}"))

    if budget.get("llm_enabled") is not False:
        issues.append(EvidenceIssue("error", "LLM_SHOULD_BE_DISABLED", "LLM must remain disabled in v0.0.10."))

    if budget.get("summary", {}).get("num_llm_calls") != 0:
        issues.append(EvidenceIssue("error", "LLM_CALLS_NOT_ZERO", "v0.0.10 should have zero LLM calls."))

    replay_commands = replay.get("commands", [])
    if len(replay_commands) != len(calls):
        issues.append(EvidenceIssue("error", "REPLAY_COMMAND_COUNT_MISMATCH", "Replay manifest command count differs from budget ledger."))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return EvidenceValidationReport(
        status=status,
        issues=issues,
        summary={
            "run_id": registry.get("run_id"),
            "case_id": registry.get("case_id"),
            "target_platform": registry.get("target_platform"),
            "num_artifacts": len(artifacts),
            "num_tool_calls": len(calls),
            "num_llm_calls": budget.get("summary", {}).get("num_llm_calls"),
            "total_wall_time_sec": budget.get("summary", {}).get("total_wall_time_sec"),
            "replay_commands": len(replay_commands)
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate XPortHLS evidence artifacts")
    parser.add_argument("--registry", required=True)
    parser.add_argument("--budget", required=True)
    parser.add_argument("--replay", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    registry = load_json(args.registry)
    budget = load_json(args.budget)
    replay = load_json(args.replay)

    report = validate_evidence(registry, budget, replay)
    report.save(args.out)

    print(f"[xporthls] Evidence validation report written to: {args.out}")
    print(f"[xporthls] Evidence validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[5/6] Update README checklist"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

replacements = {
    "### Phase 9 — Evidence System\n\nStatus: planned.": "### Phase 9 — Evidence System\n\nStatus: in progress.",
    "- [ ] Add Artifact Registry": "- [x] Add Artifact Registry",
    "- [ ] Add Evidence Ledger": "- [x] Add Evidence Ledger",
    "- [ ] Add Budget Ledger": "- [x] Add Budget Ledger",
    "- [ ] Add Replay Manifest": "- [x] Add Replay Manifest",
    "- [ ] Record every generated file": "- [x] Record every generated file",
    "- [ ] Record every validation report": "- [x] Record every validation report",
    "- [ ] Record every patch attempt": "- [ ] Record every patch attempt",
    "- [ ] Record every LLM call": "- [ ] Record every LLM call",
}

for old, new in replacements.items():
    text = text.replace(old, new)

if "### Phase 9 — Evidence System" not in text:
    text += """

### Phase 9 — Evidence System

Status: in progress.

- [x] Add Artifact Registry
- [x] Add Evidence Ledger
- [x] Add Budget Ledger
- [x] Add Replay Manifest
- [x] Record every generated file
- [x] Record every validation report
- [ ] Record every patch attempt
- [ ] Record every LLM call
"""

p.write_text(text, encoding="utf-8")
PY

echo "[6/6] Create v0.0.10 replay script"

cat > add_evidence_system_v010_replay.sh <<'EOT'
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
EOT

chmod +x add_evidence_system_v010_replay.sh

echo "[v0.0.10] Run replay"

./add_evidence_system_v010_replay.sh

echo "[v0.0.10] Git status"

git status
