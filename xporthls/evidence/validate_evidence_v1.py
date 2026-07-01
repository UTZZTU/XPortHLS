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
