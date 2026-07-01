from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


ALLOWED_CLASSIFICATIONS = {
    "summary_count_fallback",
    "compute_unit_instance_name",
    "naming_normalization_or_alias_gap",
    "helper_or_wrapper_name_mismatch",
    "connectivity_name_without_hls_top_function",
    "name_extraction_pointer_gap",
    "possible_false_positive_from_connectivity_parsing",
    "insufficient_evidence",
}


@dataclass
class DiagnosisIssue:
    severity: str
    code: str
    message: str


@dataclass
class DiagnosisValidationReport:
    status: str
    issues: list[DiagnosisIssue] = field(default_factory=list)
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


def add_issue(issues: list[DiagnosisIssue], severity: str, code: str, message: str) -> None:
    issues.append(DiagnosisIssue(severity=severity, code=code, message=message))


def validate_diagnosis_entry(entry: dict[str, Any], issues: list[DiagnosisIssue]) -> None:
    required = [
        "diagnosis_id",
        "raw_name",
        "normalized",
        "classification",
        "confidence",
        "confidence_score",
        "source",
        "pointer",
        "nearest_declared_candidates",
        "mentions",
        "evidence",
        "recommendations",
        "proposed_next_action",
    ]

    for field in required:
        if field not in entry:
            add_issue(issues, "error", "DIAGNOSIS_FIELD_MISSING", f"Diagnosis {entry.get('diagnosis_id', '<unknown>')} missing field: {field}")

    if entry.get("classification") not in ALLOWED_CLASSIFICATIONS:
        add_issue(issues, "error", "CLASSIFICATION_INVALID", f"Invalid classification: {entry.get('classification')!r}")

    if entry.get("confidence") not in {"high", "medium", "low"}:
        add_issue(issues, "error", "CONFIDENCE_INVALID", f"Invalid confidence: {entry.get('confidence')!r}")

    score = entry.get("confidence_score")
    if not isinstance(score, (int, float)) or score < 0 or score > 1:
        add_issue(issues, "error", "CONFIDENCE_SCORE_INVALID", f"confidence_score must be 0..1, got {score!r}")

    if not isinstance(entry.get("evidence", []), list) or not entry.get("evidence"):
        add_issue(issues, "error", "EVIDENCE_MISSING", f"Diagnosis {entry.get('diagnosis_id')} has no evidence.")

    if not isinstance(entry.get("recommendations", []), list) or not entry.get("recommendations"):
        add_issue(issues, "error", "RECOMMENDATIONS_MISSING", f"Diagnosis {entry.get('diagnosis_id')} has no recommendations.")

    next_action = entry.get("proposed_next_action", {})
    if next_action.get("requires_validator_before_gap_update") is not True:
        add_issue(issues, "error", "VALIDATOR_REQUIRED_MISSING", f"Diagnosis {entry.get('diagnosis_id')} must require validator before gap update.")


def validate(report: dict[str, Any], kernel_resolution: dict[str, Any] | None = None) -> DiagnosisValidationReport:
    issues: list[DiagnosisIssue] = []

    if report.get("schema_version") != "kernel_name_unresolved_diagnosis.v1":
        add_issue(issues, "error", "REPORT_SCHEMA", "Expected kernel_name_unresolved_diagnosis.v1.")

    source_ref = report.get("source_kernel_resolution_ref", {})
    if source_ref.get("schema_version") != "kernel_name_resolution_report.v1":
        add_issue(issues, "error", "KERNEL_RESOLUTION_SCHEMA_REF", "Report must reference kernel_name_resolution_report.v1.")

    refs = report.get("input_refs", {})
    if refs.get("application_ir", {}).get("schema_version") != "application_ir.v2":
        add_issue(issues, "error", "APP_IR_SCHEMA_REF", "Report must reference application_ir.v2.")

    policy = report.get("policy", {})
    if policy.get("deterministic_only") is not True:
        add_issue(issues, "error", "POLICY_NOT_DETERMINISTIC", "Diagnosis must be deterministic_only.")
    if policy.get("llm_used") is not False:
        add_issue(issues, "error", "LLM_USED", "v0.0.20 diagnosis must not use LLM.")
    if policy.get("gap_state_changed") is not False:
        add_issue(issues, "error", "GAP_STATE_CHANGED", "v0.0.20 must not change gap state.")
    if policy.get("contract_state_changed") is not False:
        add_issue(issues, "error", "CONTRACT_STATE_CHANGED", "v0.0.20 must not change contract state.")
    if policy.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK_ALLOWED", "v0.0.20 must not unlock generation.")

    diagnoses = report.get("diagnoses", [])
    summary = report.get("summary", {})

    if int(summary.get("num_diagnosed") or -1) != len(diagnoses):
        add_issue(issues, "error", "DIAGNOSIS_COUNT_MISMATCH", "summary.num_diagnosed mismatch.")

    if int(summary.get("num_unresolved_configured") or -1) != len(diagnoses):
        add_issue(issues, "error", "UNRESOLVED_COUNT_MISMATCH", "Every unresolved configured kernel must have one diagnosis.")

    seen_ids = set()
    for entry in diagnoses:
        validate_diagnosis_entry(entry, issues)
        did = entry.get("diagnosis_id")
        if did in seen_ids:
            add_issue(issues, "error", "DUPLICATE_DIAGNOSIS_ID", f"Duplicate diagnosis_id: {did}")
        seen_ids.add(did)

    counts = {}
    for entry in diagnoses:
        c = entry.get("classification")
        counts[c] = counts.get(c, 0) + 1

    if counts != summary.get("classification_counts", {}):
        add_issue(issues, "error", "CLASSIFICATION_COUNTS_MISMATCH", "classification_counts does not match diagnoses.")

    tasks = report.get("proposed_resolver_v2_tasks", [])
    task_classes = {task.get("classification") for task in tasks}
    diagnosis_classes = set(counts)
    missing_task_classes = sorted(diagnosis_classes - task_classes)
    if missing_task_classes:
        add_issue(issues, "error", "RESOLVER_V2_TASK_MISSING", f"Missing resolver v2 tasks for classes: {missing_task_classes}")

    for task in tasks:
        if task.get("must_be_deterministic") is not True:
            add_issue(issues, "error", "TASK_NOT_DETERMINISTIC", f"Task {task.get('task_id')} must be deterministic.")
        if task.get("llm_allowed") is not False:
            add_issue(issues, "error", "TASK_LLM_ALLOWED", f"Task {task.get('task_id')} must not allow LLM execution in v0.0.20.")
        if not task.get("affected_diagnosis_ids"):
            add_issue(issues, "error", "TASK_NO_AFFECTED_DIAGNOSES", f"Task {task.get('task_id')} has no affected diagnoses.")

    transition = report.get("gap_transition_proposal", {})
    if transition.get("gap_id") != "GAP-KERNEL-NAME-001":
        add_issue(issues, "error", "GAP_TRANSITION_ID", "Diagnosis must target GAP-KERNEL-NAME-001.")
    if transition.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "TRANSITION_UNLOCK_ALLOWED", "Diagnosis must not unlock generator.")
    if transition.get("proposed_state") != "remain_blocking":
        add_issue(issues, "error", "PROPOSED_STATE_NOT_BLOCKING", "v0.0.20 must keep GAP-KERNEL-NAME-001 blocking.")

    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "SUMMARY_UNLOCK_ALLOWED", "Summary must keep generator_unlock_allowed false.")

    if report.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Diagnosis report must not contain LLM annotations.")

    if kernel_resolution is not None:
        expected_unresolved = int(kernel_resolution.get("summary", {}).get("num_unresolved_configured") or 0)
        if expected_unresolved != int(summary.get("num_unresolved_configured") or -1):
            add_issue(
                issues,
                "error",
                "SOURCE_UNRESOLVED_COUNT_MISMATCH",
                f"Kernel resolution unresolved configured count={expected_unresolved}, diagnosis count={summary.get('num_unresolved_configured')}",
            )

    if int(summary.get("num_low_confidence") or 0) > 0:
        add_issue(
            issues,
            "warning",
            "LOW_CONFIDENCE_DIAGNOSES_PRESENT",
            "Some unresolved kernels have low-confidence diagnosis and need more deterministic evidence.",
        )

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return DiagnosisValidationReport(
        status=status,
        issues=issues,
        summary={
            "case_id": report.get("case_id"),
            "schema_version": report.get("schema_version"),
            "source_kernel_resolution_schema": source_ref.get("schema_version"),
            "num_unresolved_configured": summary.get("num_unresolved_configured"),
            "num_diagnosed": summary.get("num_diagnosed"),
            "classification_counts": summary.get("classification_counts"),
            "num_high_confidence": summary.get("num_high_confidence"),
            "num_medium_confidence": summary.get("num_medium_confidence"),
            "num_low_confidence": summary.get("num_low_confidence"),
            "num_safe_to_auto_resolve_candidates": summary.get("num_safe_to_auto_resolve_candidates"),
            "must_remain_blocking": summary.get("must_remain_blocking"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "num_resolver_v2_tasks": len(tasks),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Kernel Unresolved Diagnosis v0.0.20")
    parser.add_argument("--diagnosis", required=True)
    parser.add_argument("--kernel-resolution-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    diagnosis = load_json(args.diagnosis)
    kernel_resolution = load_json(args.kernel_resolution_report) if args.kernel_resolution_report else None

    report = validate(diagnosis, kernel_resolution)
    report.save(args.out)

    print(f"[xporthls] Kernel Unresolved Diagnosis validation written to: {args.out}")
    print(f"[xporthls] Kernel Unresolved Diagnosis validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
