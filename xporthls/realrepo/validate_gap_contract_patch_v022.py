from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


TARGET_GAP_ID = "GAP-KERNEL-NAME-001"


@dataclass
class PatchIssue:
    severity: str
    code: str
    message: str


@dataclass
class PatchValidationReport:
    status: str
    issues: list[PatchIssue] = field(default_factory=list)
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


def add_issue(issues: list[PatchIssue], severity: str, code: str, message: str) -> None:
    issues.append(PatchIssue(severity=severity, code=code, message=message))


def find_gap(contract: dict[str, Any], gap_id: str) -> dict[str, Any] | None:
    for gap in contract.get("gaps", []):
        if gap.get("id") == gap_id:
            return gap
    return None


def actual_blocking_gap_ids(contract: dict[str, Any]) -> list[str]:
    return [
        g.get("id")
        for g in contract.get("gaps", [])
        if g.get("severity") == "blocking" and bool(g.get("blocks_migration")) is True
    ]


def validate(
    original: dict[str, Any],
    patched: dict[str, Any],
    patch_report: dict[str, Any],
    proposal: dict[str, Any],
    v2_report: dict[str, Any],
    guard_report: dict[str, Any] | None = None,
) -> PatchValidationReport:
    issues: list[PatchIssue] = []

    if original.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "ORIGINAL_SCHEMA", "Original contract must use source_to_target_gap_contract.v1.")

    if patched.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "PATCHED_SCHEMA", "Patched contract must preserve source_to_target_gap_contract.v1.")

    if patch_report.get("schema_version") != "gap_contract_patch_report.v1":
        add_issue(issues, "error", "PATCH_REPORT_SCHEMA", "Patch report must use gap_contract_patch_report.v1.")

    if proposal.get("schema_version") != "kernel_gap_contract_update_proposal.v1":
        add_issue(issues, "error", "PROPOSAL_SCHEMA", "Proposal must use kernel_gap_contract_update_proposal.v1.")

    if v2_report.get("schema_version") != "kernel_name_resolution_report_v2.v1":
        add_issue(issues, "error", "V2_SCHEMA", "V2 report must use kernel_name_resolution_report_v2.v1.")

    if proposal.get("proposal_state") != "ready_for_contract_patch_review":
        add_issue(issues, "error", "PROPOSAL_NOT_READY", "Proposal must be ready_for_contract_patch_review.")

    if v2_report.get("summary", {}).get("all_configured_resolved") is not True:
        add_issue(issues, "error", "V2_NOT_RESOLVED", "Kernel Name Resolution v2 must resolve all configured kernels.")

    original_gap = find_gap(original, TARGET_GAP_ID)
    patched_gap = find_gap(patched, TARGET_GAP_ID)

    if not original_gap:
        add_issue(issues, "error", "ORIGINAL_TARGET_GAP_MISSING", f"{TARGET_GAP_ID} missing from original contract.")
    else:
        if original_gap.get("severity") != "blocking" or original_gap.get("blocks_migration") is not True:
            add_issue(issues, "error", "ORIGINAL_TARGET_NOT_BLOCKING", f"{TARGET_GAP_ID} should be blocking in original contract.")

    if not patched_gap:
        add_issue(issues, "error", "PATCHED_TARGET_GAP_MISSING", f"{TARGET_GAP_ID} missing from patched contract.")
    else:
        if patched_gap.get("severity") == "blocking" or patched_gap.get("blocks_migration") is True:
            add_issue(issues, "error", "PATCHED_TARGET_STILL_BLOCKING", f"{TARGET_GAP_ID} should no longer be blocking.")
        if patched_gap.get("resolution_state") != "resolved_by_kernel_name_resolution_v2":
            add_issue(issues, "error", "PATCHED_TARGET_RESOLUTION_STATE", f"{TARGET_GAP_ID} must be resolved_by_kernel_name_resolution_v2.")

    original_blocking = original.get("summary", {}).get("blocking_gap_ids", [])
    patched_blocking = patched.get("summary", {}).get("blocking_gap_ids", [])

    if TARGET_GAP_ID not in original_blocking:
        add_issue(issues, "error", "ORIGINAL_BLOCKING_LIST_MISSING_TARGET", f"{TARGET_GAP_ID} must be in original blocking_gap_ids.")

    if TARGET_GAP_ID in patched_blocking:
        add_issue(issues, "error", "PATCHED_BLOCKING_LIST_HAS_TARGET", f"{TARGET_GAP_ID} must not be in patched blocking_gap_ids.")

    expected_patched_blocking = sorted([g for g in original_blocking if g != TARGET_GAP_ID])
    if sorted(patched_blocking) != expected_patched_blocking:
        add_issue(
            issues,
            "error",
            "PATCHED_BLOCKING_LIST_UNEXPECTED",
            f"Expected patched blocking ids {expected_patched_blocking}, got {sorted(patched_blocking)}.",
        )

    actual_patched_blocking = actual_blocking_gap_ids(patched)
    if sorted(actual_patched_blocking) != sorted(patched_blocking):
        add_issue(
            issues,
            "error",
            "PATCHED_SUMMARY_BLOCKING_MISMATCH",
            f"Patched summary blocking ids {patched_blocking} != actual {actual_patched_blocking}.",
        )

    if patched.get("summary", {}).get("num_blocking") != len(patched_blocking):
        add_issue(issues, "error", "PATCHED_NUM_BLOCKING_MISMATCH", "summary.num_blocking mismatch.")

    if patched.get("summary", {}).get("num_blocking") != 6:
        add_issue(issues, "error", "PATCHED_EXPECT_SIX_BLOCKERS", "HiSparse v0.0.22 should have exactly 6 remaining blocking gaps.")

    if patched.get("contract_state") != "blocked_profile_only":
        add_issue(issues, "error", "PATCHED_CONTRACT_STATE", "Patched contract must remain blocked_profile_only.")

    if patched.get("migration_decision", {}).get("allowed") is not False:
        add_issue(issues, "error", "PATCHED_MIGRATION_ALLOWED", "Patched contract must still disallow migration.")

    if patch_report.get("summary", {}).get("applied") is not True:
        add_issue(issues, "error", "PATCH_REPORT_NOT_APPLIED", "Patch report should say applied=true.")

    if patch_report.get("summary", {}).get("removed_target_gap_from_blocking") is not True:
        add_issue(issues, "error", "PATCH_REPORT_TARGET_NOT_REMOVED", "Patch report should record target gap removal.")

    if patch_report.get("summary", {}).get("remaining_blocking_count") != 6:
        add_issue(issues, "error", "PATCH_REPORT_REMAINING_COUNT", "Patch report should show 6 remaining blockers.")

    for obj_name, obj in [
        ("patch_report", patch_report),
        ("proposal", proposal),
        ("v2_report", v2_report),
    ]:
        if obj.get("llm_annotations") != []:
            add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", f"{obj_name} must not contain LLM annotations.")
        policy = obj.get("policy", {})
        if policy.get("llm_used") is not False:
            add_issue(issues, "error", "LLM_USED", f"{obj_name} must not use LLM.")
        if policy.get("generator_unlock_allowed") is not False:
            add_issue(issues, "error", "GENERATOR_UNLOCK_ALLOWED", f"{obj_name} must not unlock generator.")

    if guard_report is not None:
        if guard_report.get("schema_version") != "generator_guard_report.v1":
            add_issue(issues, "error", "GUARD_SCHEMA", "Guard report must use generator_guard_report.v1.")
        if guard_report.get("contract_ref", {}).get("path") is None:
            add_issue(issues, "error", "GUARD_CONTRACT_REF_MISSING", "Guard report missing contract ref path.")
        if guard_report.get("decision", {}).get("blocked") is not True:
            add_issue(issues, "error", "GUARD_NOT_BLOCKED", "Generator guard must still block patched contract.")
        if guard_report.get("decision", {}).get("allowed") is not False:
            add_issue(issues, "error", "GUARD_ALLOWED", "Generator guard must not allow patched contract.")
        guard_ids = guard_report.get("summary", {}).get("blocking_gap_ids", [])
        if TARGET_GAP_ID in guard_ids:
            add_issue(issues, "error", "GUARD_STILL_HAS_KERNEL_BLOCKER", f"Guard should not list {TARGET_GAP_ID} as blocking after patch.")
        if len(guard_ids) != 6:
            add_issue(issues, "error", "GUARD_EXPECT_SIX_BLOCKERS", f"Guard should see 6 remaining blockers, got {len(guard_ids)}.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return PatchValidationReport(
        status=status,
        issues=issues,
        summary={
            "original_schema": original.get("schema_version"),
            "patched_schema": patched.get("schema_version"),
            "patch_report_schema": patch_report.get("schema_version"),
            "proposal_schema": proposal.get("schema_version"),
            "v2_schema": v2_report.get("schema_version"),
            "target_gap_id": TARGET_GAP_ID,
            "original_blocking_count": len(original_blocking),
            "patched_blocking_count": len(patched_blocking),
            "removed_from_blocking": sorted(set(original_blocking) - set(patched_blocking)),
            "remaining_blocking_gap_ids": patched_blocking,
            "patched_contract_state": patched.get("contract_state"),
            "patched_migration_allowed": patched.get("migration_decision", {}).get("allowed"),
            "guard_blocked": guard_report.get("decision", {}).get("blocked") if guard_report else None,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Gap Contract Patch v0.0.22")
    parser.add_argument("--original-contract", required=True)
    parser.add_argument("--patched-contract", required=True)
    parser.add_argument("--patch-report", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    original = load_json(args.original_contract)
    patched = load_json(args.patched_contract)
    patch_report = load_json(args.patch_report)
    proposal = load_json(args.proposal)
    v2_report = load_json(args.v2_report)
    guard_report = load_json(args.guard_report) if args.guard_report else None

    report = validate(original, patched, patch_report, proposal, v2_report, guard_report)
    report.save(args.out)

    print(f"[xporthls] Gap Contract Patch validation written to: {args.out}")
    print(f"[xporthls] Gap Contract Patch validation status: {report.status}")
    for i in report.issues:
        print(f"  - {i.severity.upper()} {i.code}: {i.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
