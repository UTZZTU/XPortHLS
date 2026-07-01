from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class GapContractIssue:
    severity: str
    code: str
    message: str


@dataclass
class GapContractValidationReport:
    status: str
    issues: list[GapContractIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[GapContractIssue], severity: str, code: str, message: str) -> None:
    issues.append(GapContractIssue(severity=severity, code=code, message=message))


def validate_gap_shape(gap: dict[str, Any], issues: list[GapContractIssue]) -> None:
    required_fields = [
        "id",
        "title",
        "category",
        "severity",
        "status",
        "blocks_migration",
        "source_feature",
        "target_requirement",
        "decision",
        "required_action",
        "evidence",
    ]

    for field_name in required_fields:
        if field_name not in gap:
            add_issue(issues, "error", "GAP_FIELD_MISSING", f"Gap {gap.get('id', '<unknown>')} missing field: {field_name}")

    if gap.get("severity") not in {"blocking", "warning", "info"}:
        add_issue(issues, "error", "GAP_SEVERITY_INVALID", f"Gap {gap.get('id')} has invalid severity: {gap.get('severity')!r}")

    if not isinstance(gap.get("evidence", []), list) or not gap.get("evidence"):
        add_issue(issues, "error", "GAP_EVIDENCE_MISSING", f"Gap {gap.get('id')} has no evidence list.")


def validate(contract: dict[str, Any]) -> GapContractValidationReport:
    issues: list[GapContractIssue] = []

    if contract.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA", "Expected source_to_target_gap_contract.v1.")

    if contract.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.16 gap contract must remain profile_only.")

    if contract.get("contract_state") not in {"blocked_profile_only", "ready_for_planning"}:
        add_issue(issues, "error", "CONTRACT_STATE", f"Unexpected contract_state: {contract.get('contract_state')!r}")

    source_ref = contract.get("source_application_ir_ref", {})
    if source_ref.get("schema_version") != "application_ir.v2":
        add_issue(issues, "error", "APP_IR_SCHEMA_REF", "Gap contract must reference application_ir.v2.")

    target = contract.get("target", {})
    if target.get("platform") != "v80_aved_2025_1_stub":
        add_issue(issues, "error", "TARGET_PLATFORM", "Expected target platform v80_aved_2025_1_stub.")
    if target.get("ecosystem") != "AVED":
        add_issue(issues, "error", "TARGET_ECOSYSTEM", "Expected target ecosystem AVED.")

    if contract.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Deterministic gap contract must not contain LLM annotations in v0.0.16.")

    gaps = contract.get("gaps", [])
    if not gaps:
        add_issue(issues, "error", "NO_GAPS", "Gap contract has no gaps.")

    for gap in gaps:
        validate_gap_shape(gap, issues)

    summary = contract.get("summary", {})
    if int(summary.get("num_gaps") or 0) != len(gaps):
        add_issue(issues, "error", "GAP_COUNT_MISMATCH", "summary.num_gaps does not match actual gaps length.")

    blocking = [g for g in gaps if g.get("severity") == "blocking" and g.get("blocks_migration")]
    warnings = [g for g in gaps if g.get("severity") == "warning"]
    infos = [g for g in gaps if g.get("severity") == "info"]

    if int(summary.get("num_blocking") or 0) != len(blocking):
        add_issue(issues, "error", "BLOCKING_COUNT_MISMATCH", "summary.num_blocking does not match actual blocking gaps length.")

    if int(summary.get("num_warnings") or 0) != len(warnings):
        add_issue(issues, "error", "WARNING_COUNT_MISMATCH", "summary.num_warnings does not match actual warning gaps length.")

    if int(summary.get("num_info") or 0) != len(infos):
        add_issue(issues, "error", "INFO_COUNT_MISMATCH", "summary.num_info does not match actual info gaps length.")

    migration = contract.get("migration_decision", {})
    if blocking:
        if migration.get("allowed") is not False:
            add_issue(issues, "error", "MIGRATION_ALLOWED_WITH_BLOCKERS", "migration_decision.allowed must be false when blocking gaps exist.")
        if contract.get("contract_state") != "blocked_profile_only":
            add_issue(issues, "error", "CONTRACT_STATE_WITH_BLOCKERS", "contract_state must be blocked_profile_only when blocking gaps exist.")

    required_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }

    actual_gap_ids = {g.get("id") for g in gaps}
    missing_required = sorted(required_gap_ids - actual_gap_ids)
    if missing_required:
        add_issue(issues, "error", "REQUIRED_GAP_MISSING", f"Missing required gap ids: {missing_required}")

    expected_alignment = contract.get("expected_gaps_alignment", {})
    missing_expected_caps = expected_alignment.get("missing_expected_capabilities", [])
    if missing_expected_caps:
        add_issue(
            issues,
            "warning",
            "EXPECTED_CAPABILITY_ALIGNMENT_INCOMPLETE",
            f"Some expected case-pack capabilities did not align by substring: {missing_expected_caps}",
        )

    app_summary = contract.get("traceability", {}).get("application_ir_summary", {})
    if int(app_summary.get("num_hls_kernel_candidates") or 0) <= 0:
        add_issue(issues, "error", "TRACE_APP_SUMMARY_NO_HLS_KERNELS", "Trace ApplicationIR summary has no HLS kernel candidates.")

    if int(app_summary.get("num_memory_mappings") or 0) <= 0:
        add_issue(issues, "error", "TRACE_APP_SUMMARY_NO_MEMORY_MAPPINGS", "Trace ApplicationIR summary has no memory mappings.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return GapContractValidationReport(
        status=status,
        issues=issues,
        summary={
            "contract_id": contract.get("contract_id"),
            "case_id": contract.get("case_id"),
            "schema_version": contract.get("schema_version"),
            "contract_state": contract.get("contract_state"),
            "migration_status": contract.get("migration_status"),
            "migration_allowed": migration.get("allowed"),
            "target_platform": target.get("platform"),
            "target_ecosystem": target.get("ecosystem"),
            "num_gaps": summary.get("num_gaps"),
            "num_blocking": summary.get("num_blocking"),
            "num_warnings": summary.get("num_warnings"),
            "num_info": summary.get("num_info"),
            "blocking_gap_ids": summary.get("blocking_gap_ids"),
            "missing_expected_capabilities": missing_expected_caps,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Source-to-Target Gap Contract v0.0.16")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contract = load_json(args.contract)
    report = validate(contract)
    report.save(args.out)

    print(f"[xporthls] Gap Contract validation written to: {args.out}")
    print(f"[xporthls] Gap Contract validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
