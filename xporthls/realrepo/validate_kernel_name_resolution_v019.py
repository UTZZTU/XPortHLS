from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class KernelNameResolutionIssue:
    severity: str
    code: str
    message: str


@dataclass
class KernelNameResolutionValidationReport:
    status: str
    issues: list[KernelNameResolutionIssue] = field(default_factory=list)
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


def add_issue(issues: list[KernelNameResolutionIssue], severity: str, code: str, message: str) -> None:
    issues.append(KernelNameResolutionIssue(severity=severity, code=code, message=message))


def validate_match_shape(match: dict[str, Any], issues: list[KernelNameResolutionIssue]) -> None:
    for key in ["configured", "declared", "score", "method", "reasons"]:
        if key not in match:
            add_issue(issues, "error", "MATCH_FIELD_MISSING", f"Match record missing field: {key}")

    score = match.get("score")
    if not isinstance(score, (int, float)) or score < 0 or score > 1:
        add_issue(issues, "error", "MATCH_SCORE_INVALID", f"Match score must be between 0 and 1, got {score!r}")

    for side in ["configured", "declared"]:
        item = match.get(side, {})
        for key in ["raw_name", "normalized", "relaxed", "source", "pointer"]:
            if key not in item:
                add_issue(issues, "error", "MATCH_SIDE_FIELD_MISSING", f"Match {side} record missing field: {key}")


def validate(report: dict[str, Any]) -> KernelNameResolutionValidationReport:
    issues: list[KernelNameResolutionIssue] = []

    if report.get("schema_version") != "kernel_name_resolution_report.v1":
        add_issue(issues, "error", "REPORT_SCHEMA", "Expected kernel_name_resolution_report.v1.")

    if report.get("gap_id") != "GAP-KERNEL-NAME-001":
        add_issue(issues, "error", "GAP_ID", "Kernel resolver must target GAP-KERNEL-NAME-001.")

    if report.get("resolver_id") != "RESOLVE-GAP-KERNEL-NAME-001":
        add_issue(issues, "error", "RESOLVER_ID", "Kernel resolver must use RESOLVE-GAP-KERNEL-NAME-001.")

    if report.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.19 must remain profile_only.")

    if report.get("resolution_state") not in {"resolved_pending_validation", "partial", "unresolved", "insufficient_evidence"}:
        add_issue(issues, "error", "RESOLUTION_STATE", f"Unexpected resolution_state: {report.get('resolution_state')!r}")

    refs = report.get("source_refs", {})
    if refs.get("application_ir", {}).get("schema_version") != "application_ir.v2":
        add_issue(issues, "error", "APP_IR_SCHEMA_REF", "Kernel resolver must reference application_ir.v2.")

    if refs.get("gap_contract", {}).get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "GAP_CONTRACT_SCHEMA_REF", "Kernel resolver must reference source_to_target_gap_contract.v1.")

    if refs.get("gap_resolver_plan", {}).get("schema_version") != "gap_resolver_plan.v1":
        add_issue(issues, "error", "RESOLVER_PLAN_SCHEMA_REF", "Kernel resolver must reference gap_resolver_plan.v1.")

    policy = report.get("policy", {})
    if policy.get("deterministic_only") is not True:
        add_issue(issues, "error", "POLICY_NOT_DETERMINISTIC", "Kernel resolver must be deterministic_only.")
    if policy.get("llm_used") is not False:
        add_issue(issues, "error", "LLM_USED", "v0.0.19 resolver must not use LLM.")
    if policy.get("gap_state_changed") is not False:
        add_issue(issues, "error", "GAP_STATE_CHANGED", "v0.0.19 must not change gap state.")
    if policy.get("contract_state_changed") is not False:
        add_issue(issues, "error", "CONTRACT_STATE_CHANGED", "v0.0.19 must not change contract state.")
    if policy.get("generation_allowed") is not False:
        add_issue(issues, "error", "GENERATION_ALLOWED", "v0.0.19 must not allow generation.")

    summary = report.get("summary", {})
    inputs = report.get("inputs", {})
    configured = inputs.get("configured_kernels", [])
    declared = inputs.get("declared_functions", [])
    matches = report.get("matches", [])
    unresolved = report.get("unresolved", {})
    unresolved_configured = unresolved.get("configured_kernels", [])
    unresolved_declared = unresolved.get("declared_functions", [])

    if int(summary.get("num_configured_kernels") or -1) != len(configured):
        add_issue(issues, "error", "CONFIGURED_COUNT_MISMATCH", "summary.num_configured_kernels mismatch.")

    if int(summary.get("num_declared_functions") or -1) != len(declared):
        add_issue(issues, "error", "DECLARED_COUNT_MISMATCH", "summary.num_declared_functions mismatch.")

    if int(summary.get("num_matches") or -1) != len(matches):
        add_issue(issues, "error", "MATCH_COUNT_MISMATCH", "summary.num_matches mismatch.")

    if int(summary.get("num_unresolved_configured") or -1) != len(unresolved_configured):
        add_issue(issues, "error", "UNRESOLVED_CONFIGURED_COUNT_MISMATCH", "summary.num_unresolved_configured mismatch.")

    if int(summary.get("num_unresolved_declared") or -1) != len(unresolved_declared):
        add_issue(issues, "error", "UNRESOLVED_DECLARED_COUNT_MISMATCH", "summary.num_unresolved_declared mismatch.")

    if len(matches) + len(unresolved_configured) != len(configured):
        add_issue(issues, "error", "CONFIGURED_PARTITION_MISMATCH", "matches + unresolved configured must partition configured kernels.")

    if len(matches) + len(unresolved_declared) > len(declared):
        add_issue(issues, "error", "DECLARED_PARTITION_OVERFLOW", "matches + unresolved declared cannot exceed declared functions.")

    for match in matches:
        validate_match_shape(match, issues)

    if not configured:
        add_issue(issues, "error", "NO_CONFIGURED_KERNELS", "Kernel resolver found no configured kernels.")

    if not declared:
        add_issue(issues, "error", "NO_DECLARED_FUNCTIONS", "Kernel resolver found no declared functions.")

    extraction = inputs.get("extraction_summary", {})
    if int(extraction.get("configured_synthetic_count") or 0) > 0:
        add_issue(
            issues,
            "warning",
            "CONFIGURED_SYNTHETIC_FALLBACK_USED",
            "Some configured kernels were synthesized from summary counts because names were not fully recoverable.",
        )

    if int(extraction.get("declared_synthetic_count") or 0) > 0:
        add_issue(
            issues,
            "warning",
            "DECLARED_SYNTHETIC_FALLBACK_USED",
            "Some declared functions were synthesized from summary counts because names were not fully recoverable.",
        )

    transition = report.get("gap_transition_proposal", {})
    if transition.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK_PROPOSED", "v0.0.19 must not unlock generator.")

    if transition.get("proposed_gap_state") not in {"remain_blocking", "resolved_pending_contract_update"}:
        add_issue(issues, "error", "PROPOSED_GAP_STATE_INVALID", f"Unexpected proposed gap state: {transition.get('proposed_gap_state')!r}")

    if report.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Kernel resolver report must not contain LLM annotations.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return KernelNameResolutionValidationReport(
        status=status,
        issues=issues,
        summary={
            "case_id": report.get("case_id"),
            "schema_version": report.get("schema_version"),
            "resolver_id": report.get("resolver_id"),
            "gap_id": report.get("gap_id"),
            "resolution_state": report.get("resolution_state"),
            "migration_status": report.get("migration_status"),
            "num_configured_kernels": summary.get("num_configured_kernels"),
            "num_declared_functions": summary.get("num_declared_functions"),
            "num_matches": summary.get("num_matches"),
            "num_unresolved_configured": summary.get("num_unresolved_configured"),
            "num_unresolved_declared": summary.get("num_unresolved_declared"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "proposed_gap_state": transition.get("proposed_gap_state"),
            "match_methods": summary.get("match_methods"),
            "configured_synthetic_count": extraction.get("configured_synthetic_count"),
            "declared_synthetic_count": extraction.get("declared_synthetic_count"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Kernel Name Resolution report v0.0.19")
    parser.add_argument("--report", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = load_json(args.report)
    validation = validate(report)
    validation.save(args.out)

    print(f"[xporthls] Kernel Name Resolution validation written to: {args.out}")
    print(f"[xporthls] Kernel Name Resolution validation status: {validation.status}")

    for issue in validation.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
