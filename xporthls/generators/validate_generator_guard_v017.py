from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class GeneratorGuardIssue:
    severity: str
    code: str
    message: str


@dataclass
class GeneratorGuardValidationReport:
    status: str
    issues: list[GeneratorGuardIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[GeneratorGuardIssue], severity: str, code: str, message: str) -> None:
    issues.append(GeneratorGuardIssue(severity=severity, code=code, message=message))


def validate(report: dict[str, Any], expect_blocked: bool = True) -> GeneratorGuardValidationReport:
    issues: list[GeneratorGuardIssue] = []

    if report.get("schema_version") != "generator_guard_report.v1":
        add_issue(issues, "error", "REPORT_SCHEMA", "Expected generator_guard_report.v1.")

    contract = report.get("contract_ref", {})
    decision = report.get("decision", {})
    output = report.get("output_protection", {})
    summary = report.get("summary", {})

    if contract.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA", "Guard report must reference source_to_target_gap_contract.v1.")

    if expect_blocked:
        if decision.get("allowed") is not False:
            add_issue(issues, "error", "EXPECTED_ALLOWED_FALSE", "Guard should not allow generation for blocked HiSparse contract.")
        if decision.get("blocked") is not True:
            add_issue(issues, "error", "EXPECTED_BLOCKED_TRUE", "Guard should block generation for blocked HiSparse contract.")
        if int(decision.get("exit_code") or 0) not in {2, 3}:
            add_issue(issues, "error", "EXPECTED_BLOCK_EXIT_CODE", f"Expected guard block exit code 2 or 3, got {decision.get('exit_code')!r}.")
        if contract.get("contract_state") != "blocked_profile_only":
            add_issue(issues, "error", "CONTRACT_STATE_NOT_BLOCKED", "Expected contract_state blocked_profile_only.")
        if contract.get("migration_allowed") is not False:
            add_issue(issues, "error", "CONTRACT_MIGRATION_ALLOWED_NOT_FALSE", "Expected migration_allowed false.")
        if int(summary.get("num_blocking_gaps") or 0) <= 0:
            add_issue(issues, "error", "NO_BLOCKING_GAPS", "Expected at least one blocking gap.")
        if output.get("blocked_generation_created_output"):
            add_issue(issues, "error", "BLOCKED_GENERATION_CREATED_OUTPUT", "Blocked generation must not create requested output directory.")

    required_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }
    actual_gap_ids = set(summary.get("blocking_gap_ids", []))
    missing = sorted(required_gap_ids - actual_gap_ids)
    if missing:
        add_issue(issues, "error", "REQUIRED_BLOCKING_GAPS_MISSING", f"Missing required blocking gap ids: {missing}")

    if report.get("llm_annotations"):
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_ALLOWED", "Generator guard report must not include LLM annotations.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return GeneratorGuardValidationReport(
        status=status,
        issues=issues,
        summary={
            "schema_version": report.get("schema_version"),
            "generator_name": report.get("generator_name"),
            "requested_action": report.get("requested_action"),
            "contract_schema": contract.get("schema_version"),
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_allowed"),
            "guard_allowed": decision.get("allowed"),
            "guard_blocked": decision.get("blocked"),
            "guard_exit_code": decision.get("exit_code"),
            "num_blocking_gaps": summary.get("num_blocking_gaps"),
            "blocking_gap_ids": summary.get("blocking_gap_ids"),
            "output_created_by_guard": output.get("output_created_by_guard"),
            "blocked_generation_created_output": output.get("blocked_generation_created_output"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate generator guard report v0.0.17")
    parser.add_argument("--guard-report", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--expect-blocked", action="store_true")
    args = parser.parse_args()

    report = load_json(args.guard_report)
    validation = validate(report, expect_blocked=args.expect_blocked)
    validation.save(args.out)

    print(f"[xporthls] Generator guard validation written to: {args.out}")
    print(f"[xporthls] Generator guard validation status: {validation.status}")

    for issue in validation.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
