#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add Gap Contract Patch Apply v1"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/gap_contract_patch_v022.py <<'EOT'
from __future__ import annotations

import argparse
import copy
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TARGET_GAP_ID = "GAP-KERNEL-NAME-001"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def sha256_file(path: str | Path) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None

    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def find_gap(contract: dict[str, Any], gap_id: str) -> dict[str, Any] | None:
    for gap in contract.get("gaps", []):
        if gap.get("id") == gap_id:
            return gap
    return None


def recompute_summary(contract: dict[str, Any]) -> dict[str, Any]:
    gaps = contract.get("gaps", [])

    blocking = [
        g for g in gaps
        if g.get("severity") == "blocking" and bool(g.get("blocks_migration")) is True
    ]
    warnings = [g for g in gaps if g.get("severity") == "warning"]
    info = [g for g in gaps if g.get("severity") == "info"]
    resolved = [
        g for g in gaps
        if g.get("severity") == "resolved" or g.get("resolution_state") in {
            "resolved_pending_contract_update_applied",
            "resolved_by_kernel_name_resolution_v2",
        }
    ]

    old_summary = dict(contract.get("summary", {}))
    old_summary.update({
        "num_gaps": len(gaps),
        "num_blocking": len(blocking),
        "num_warnings": len(warnings),
        "num_info": len(info),
        "num_resolved": len(resolved),
        "blocking_gap_ids": [g.get("id") for g in blocking],
        "warning_gap_ids": [g.get("id") for g in warnings],
        "info_gap_ids": [g.get("id") for g in info],
        "resolved_gap_ids": [g.get("id") for g in resolved],
    })
    return old_summary


def update_migration_decision(contract: dict[str, Any]) -> dict[str, Any]:
    summary = contract.get("summary", {})
    blocking_gap_ids = summary.get("blocking_gap_ids", [])
    allowed = len(blocking_gap_ids) == 0

    old = dict(contract.get("migration_decision", {}))
    old.update({
        "allowed": allowed,
        "reason": (
            "No blocking gaps remain after patch application."
            if allowed else
            "Migration remains blocked because source-to-target gaps still require deterministic resolver outputs."
        ),
        "remaining_blocking_gap_ids": blocking_gap_ids,
        "num_remaining_blocking_gaps": len(blocking_gap_ids),
        "last_updated_by": "gap_contract_patch_v022",
    })
    return old


def build_patch_report(
    case_id: str,
    original_contract_path: str,
    proposal_path: str,
    v2_report_path: str,
    patched_contract_path: str,
    original: dict[str, Any],
    proposal: dict[str, Any],
    v2_report: dict[str, Any],
    patched: dict[str, Any],
    applied: bool,
    reason: str,
) -> dict[str, Any]:
    original_blocking = original.get("summary", {}).get("blocking_gap_ids", [])
    patched_blocking = patched.get("summary", {}).get("blocking_gap_ids", [])

    removed = sorted(set(original_blocking) - set(patched_blocking))
    added = sorted(set(patched_blocking) - set(original_blocking))

    return {
        "schema_version": "gap_contract_patch_report.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "patch_id": f"{case_id}.gap_contract_patch.v022",
        "target_gap_id": TARGET_GAP_ID,
        "applied": applied,
        "reason": reason,
        "source_refs": {
            "original_gap_contract": {
                "path": original_contract_path,
                "sha256": sha256_file(original_contract_path),
                "schema_version": original.get("schema_version"),
                "contract_state": original.get("contract_state"),
                "migration_allowed": original.get("migration_decision", {}).get("allowed"),
            },
            "kernel_gap_update_proposal": {
                "path": proposal_path,
                "sha256": sha256_file(proposal_path),
                "schema_version": proposal.get("schema_version"),
                "proposal_state": proposal.get("proposal_state"),
            },
            "kernel_name_resolution_report_v2": {
                "path": v2_report_path,
                "sha256": sha256_file(v2_report_path),
                "schema_version": v2_report.get("schema_version"),
                "resolution_state": v2_report.get("resolution_state"),
            },
            "patched_gap_contract": {
                "path": patched_contract_path,
                "sha256": sha256_file(patched_contract_path),
                "schema_version": patched.get("schema_version"),
                "contract_state": patched.get("contract_state"),
                "migration_allowed": patched.get("migration_decision", {}).get("allowed"),
            },
        },
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "patch_applies_only_target_gap": True,
            "generator_unlock_allowed": False,
            "migration_may_remain_blocked": True,
            "validator_required": True,
        },
        "delta": {
            "original_blocking_gap_ids": original_blocking,
            "patched_blocking_gap_ids": patched_blocking,
            "removed_from_blocking_gap_ids": removed,
            "added_to_blocking_gap_ids": added,
            "original_blocking_count": len(original_blocking),
            "patched_blocking_count": len(patched_blocking),
            "migration_allowed_before": original.get("migration_decision", {}).get("allowed"),
            "migration_allowed_after": patched.get("migration_decision", {}).get("allowed"),
        },
        "patched_gap_snapshot": find_gap(patched, TARGET_GAP_ID),
        "summary": {
            "applied": applied,
            "target_gap_id": TARGET_GAP_ID,
            "removed_target_gap_from_blocking": TARGET_GAP_ID in removed,
            "remaining_blocking_count": len(patched_blocking),
            "remaining_blocking_gap_ids": patched_blocking,
            "migration_allowed_after_patch": patched.get("migration_decision", {}).get("allowed"),
            "generator_unlock_allowed": False,
            "patched_contract_path": patched_contract_path,
        },
        "llm_annotations": [],
    }


def apply_kernel_gap_patch(
    case_id: str,
    original_contract_path: str,
    proposal_path: str,
    v2_report_path: str,
    patched_contract_path: str,
    patch_report_path: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    original = load_json(original_contract_path)
    proposal = load_json(proposal_path)
    v2_report = load_json(v2_report_path)

    patched = copy.deepcopy(original)
    applied = False
    reason = ""

    proposal_ready = proposal.get("proposal_state") == "ready_for_contract_patch_review"
    v2_resolved = (
        v2_report.get("schema_version") == "kernel_name_resolution_report_v2.v1"
        and v2_report.get("summary", {}).get("all_configured_resolved") is True
        and v2_report.get("summary", {}).get("num_unresolved_configured") == 0
    )
    proposal_targets_gap = proposal.get("target_gap_id") == TARGET_GAP_ID
    proposal_removes_gap = TARGET_GAP_ID in proposal.get("proposed_contract_delta", {}).get("remove_from_blocking_gap_ids", [])

    gap = find_gap(patched, TARGET_GAP_ID)

    if not gap:
        reason = f"Target gap {TARGET_GAP_ID} not found in original contract."
    elif not proposal_ready:
        reason = f"Proposal is not ready: {proposal.get('proposal_state')!r}."
    elif not v2_resolved:
        reason = "Kernel Name Resolution v2 report does not prove all configured kernels resolved."
    elif not proposal_targets_gap or not proposal_removes_gap:
        reason = "Proposal does not target and remove GAP-KERNEL-NAME-001."
    else:
        previous = {
            "severity": gap.get("severity"),
            "blocks_migration": gap.get("blocks_migration"),
            "status": gap.get("status"),
            "decision": gap.get("decision"),
        }

        gap["severity"] = "resolved"
        gap["blocks_migration"] = False
        gap["status"] = "resolved_pending_contract_update_applied"
        gap["decision"] = "resolved_by_kernel_name_resolution_v2"
        gap["resolution_state"] = "resolved_by_kernel_name_resolution_v2"
        gap["resolution_refs"] = {
            "kernel_name_resolution_report_v2": {
                "path": v2_report_path,
                "sha256": sha256_file(v2_report_path),
                "schema_version": v2_report.get("schema_version"),
            },
            "kernel_gap_update_proposal": {
                "path": proposal_path,
                "sha256": sha256_file(proposal_path),
                "schema_version": proposal.get("schema_version"),
            },
        }
        gap["previous_blocking_state"] = previous
        gap["resolved_at_utc"] = utc_now()
        gap["resolved_by"] = "gap_contract_patch_v022"

        applied = True
        reason = "Applied kernel-name gap contract patch."

    patched["contract_state"] = "blocked_profile_only"
    patched["migration_status"] = "profile_only"
    patched["summary"] = recompute_summary(patched)
    patched["migration_decision"] = update_migration_decision(patched)

    if patched["migration_decision"]["allowed"]:
        patched["contract_state"] = "ready_for_planning"
    else:
        patched["contract_state"] = "blocked_profile_only"

    patch_history = list(patched.get("patch_history", []))
    patch_history.append({
        "patch_schema_version": "gap_contract_patch_application.v1",
        "patch_version": "v0.0.22",
        "created_at_utc": utc_now(),
        "target_gap_id": TARGET_GAP_ID,
        "applied": applied,
        "reason": reason,
        "original_contract_ref": {
            "path": original_contract_path,
            "sha256": sha256_file(original_contract_path),
        },
        "proposal_ref": {
            "path": proposal_path,
            "sha256": sha256_file(proposal_path),
        },
        "v2_resolution_ref": {
            "path": v2_report_path,
            "sha256": sha256_file(v2_report_path),
        },
    })
    patched["patch_history"] = patch_history

    patched["derived_from_contract"] = {
        "path": original_contract_path,
        "sha256": sha256_file(original_contract_path),
        "schema_version": original.get("schema_version"),
    }
    patched["last_updated_by"] = "gap_contract_patch_v022"
    patched["last_updated_at_utc"] = utc_now()

    save_json(patched_contract_path, patched)

    patch_report = build_patch_report(
        case_id=case_id,
        original_contract_path=original_contract_path,
        proposal_path=proposal_path,
        v2_report_path=v2_report_path,
        patched_contract_path=patched_contract_path,
        original=original,
        proposal=proposal,
        v2_report=v2_report,
        patched=patched,
        applied=applied,
        reason=reason,
    )
    save_json(patch_report_path, patch_report)

    return patched, patch_report


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply kernel-name gap contract patch v0.0.22")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--original-contract", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--patched-contract-out", required=True)
    parser.add_argument("--patch-report-out", required=True)
    args = parser.parse_args()

    patched, report = apply_kernel_gap_patch(
        case_id=args.case_id,
        original_contract_path=args.original_contract,
        proposal_path=args.proposal,
        v2_report_path=args.v2_report,
        patched_contract_path=args.patched_contract_out,
        patch_report_path=args.patch_report_out,
    )

    s = report["summary"]
    print(f"[xporthls] Patched Gap Contract: {args.patched_contract_out}")
    print(f"[xporthls] Patch report: {args.patch_report_out}")
    print(f"[xporthls] Applied: {s['applied']}")
    print(f"[xporthls] Removed target gap from blocking: {s['removed_target_gap_from_blocking']}")
    print(f"[xporthls] Contract state: {patched.get('contract_state')}")
    print(f"[xporthls] Migration allowed after patch: {s['migration_allowed_after_patch']}")
    print(f"[xporthls] Remaining blocking count: {s['remaining_blocking_count']}")
    print(f"[xporthls] Remaining blocking IDs: {s['remaining_blocking_gap_ids']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")

    return 0 if s["applied"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/6] Add Gap Contract Patch validator"

cat > xporthls/realrepo/validate_gap_contract_patch_v022.py <<'EOT'
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
EOT

echo "[3/6] Add Gap Contract Patch orchestration runner"

cat > xporthls/realrepo/run_gap_contract_patch_v022.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_contract_patch_v022 import apply_kernel_gap_patch
from xporthls.realrepo.validate_gap_contract_patch_v022 import load_json, validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.22 Gap Contract Patch Apply")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--original-contract", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    patched_contract_path = out_dir / f"{args.case_id}_gap_contract_patched_v022.json"
    patch_report_path = out_dir / f"{args.case_id}_gap_contract_patch_report_v022.json"
    validation_path = out_dir / f"{args.case_id}_gap_contract_patch_validation_v022.json"

    patched, patch_report = apply_kernel_gap_patch(
        case_id=args.case_id,
        original_contract_path=args.original_contract,
        proposal_path=args.proposal,
        v2_report_path=args.v2_report,
        patched_contract_path=str(patched_contract_path),
        patch_report_path=str(patch_report_path),
    )

    original = load_json(args.original_contract)
    proposal = load_json(args.proposal)
    v2_report = load_json(args.v2_report)
    validation = validate(original, patched, patch_report, proposal, v2_report, None)
    validation.save(validation_path)

    s = patch_report["summary"]
    print(f"[xporthls] Patched Gap Contract: {patched_contract_path}")
    print(f"[xporthls] Patch report: {patch_report_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Applied: {s['applied']}")
    print(f"[xporthls] Removed target gap from blocking: {s['removed_target_gap_from_blocking']}")
    print(f"[xporthls] Contract state: {patched.get('contract_state')}")
    print(f"[xporthls] Migration allowed: {patched.get('migration_decision', {}).get('allowed')}")
    print(f"[xporthls] Remaining blocking count: {s['remaining_blocking_count']}")
    print(f"[xporthls] Remaining blocking IDs: {s['remaining_blocking_gap_ids']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Gap contract patch apply

XPortHLS can apply a validated resolver-specific contract update proposal to produce a patched source-to-target gap contract. The v0.0.22 patch applies the Kernel Name Resolver v2 proposal for `GAP-KERNEL-NAME-001`.

Example:

```bash
python3 -m xporthls.realrepo.run_gap_contract_patch_v022 \\
  --case-id hisparse_u280_profile \\
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \\
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \\
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \\
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json
experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json
experiments/runs/hisparse_u280_profile_gap_contract_patch_validation_v022.json
```

The patched contract removes `GAP-KERNEL-NAME-001` from the blocking list but remains `blocked_profile_only` because other blocking gaps remain. Generation remains blocked by the generator guard.
"""

if "## Gap contract patch apply" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.22 replay script"

cat > add_gap_contract_patch_v022_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v022"
PATCHED_CONTRACT="experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"
PATCH_REPORT="experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"
PATCH_VALIDATION="experiments/runs/hisparse_u280_profile_gap_contract_patch_validation_v022.json"
PATCHED_GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v022.json"

echo "[v0.0.22] Python syntax check"

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
  xporthls/realrepo/run_hisparse_profile_case_v015.py \
  xporthls/realrepo/gap_contract_v016.py \
  xporthls/realrepo/validate_gap_contract_v016.py \
  xporthls/realrepo/run_gap_contract_v016.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py \
  xporthls/generators/validate_generator_guard_v017.py \
  xporthls/realrepo/gap_resolver_plan_v018.py \
  xporthls/realrepo/validate_gap_resolver_plan_v018.py \
  xporthls/realrepo/run_gap_resolver_plan_v018.py \
  xporthls/realrepo/kernel_name_resolver_v019.py \
  xporthls/realrepo/validate_kernel_name_resolution_v019.py \
  xporthls/realrepo/run_kernel_name_resolution_v019.py \
  xporthls/realrepo/kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/validate_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/kernel_alias_table_v021.py \
  xporthls/realrepo/kernel_name_resolver_v021.py \
  xporthls/realrepo/kernel_gap_update_proposal_v021.py \
  xporthls/realrepo/validate_kernel_alias_resolution_v021.py \
  xporthls/realrepo/run_kernel_alias_resolution_v021.py \
  xporthls/realrepo/gap_contract_patch_v022.py \
  xporthls/realrepo/validate_gap_contract_patch_v022.py \
  xporthls/realrepo/run_gap_contract_patch_v022.py

echo "[v0.0.22] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.22] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.18 resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.22] Re-run v0.0.21 alias resolver baseline"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.22] Apply gap contract patch"

python3 -m xporthls.realrepo.run_gap_contract_patch_v022 \
  --case-id hisparse_u280_profile \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --out-dir experiments/runs

echo "[v0.0.22] Run generator guard against patched contract; it must still be blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$PATCHED_GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.22] Validate patch with patched-contract guard evidence"

python3 -m xporthls.realrepo.validate_gap_contract_patch_v022 \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --patched-contract "$PATCHED_CONTRACT" \
  --patch-report "$PATCH_REPORT" \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --guard-report "$PATCHED_GUARD_REPORT" \
  --out "$PATCH_VALIDATION"

python3 - <<'PY'
import json
from pathlib import Path

original = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
patched = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"))
patch_report = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patch_validation_v022.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v022.json"))

print()
print("Original schema:", original["schema_version"])
print("Original blocking count:", original["summary"]["num_blocking"])
print("Original blocking IDs:", original["summary"]["blocking_gap_ids"])
print("Patched schema:", patched["schema_version"])
print("Patched contract state:", patched["contract_state"])
print("Patched migration allowed:", patched["migration_decision"]["allowed"])
print("Patched blocking count:", patched["summary"]["num_blocking"])
print("Patched blocking IDs:", patched["summary"]["blocking_gap_ids"])
print("Resolved gap IDs:", patched["summary"].get("resolved_gap_ids"))
print("Patch applied:", patch_report["summary"]["applied"])
print("Removed target gap:", patch_report["summary"]["removed_target_gap_from_blocking"])
print("Patch validation status:", validation["status"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v022").exists())

assert original["schema_version"] == "source_to_target_gap_contract.v1"
assert patched["schema_version"] == "source_to_target_gap_contract.v1"
assert "GAP-KERNEL-NAME-001" in original["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" not in patched["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in patched["summary"]["resolved_gap_ids"]
assert patched["summary"]["num_blocking"] == 6
assert patched["contract_state"] == "blocked_profile_only"
assert patched["migration_decision"]["allowed"] is False
assert patch_report["summary"]["applied"] is True
assert patch_report["summary"]["removed_target_gap_from_blocking"] is True
assert validation["status"] == "pass"
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]
assert len(guard["summary"]["blocking_gap_ids"]) == 6
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v022").exists()
PY

echo
echo "DONE."
EOT

chmod +x add_gap_contract_patch_v022_replay.sh

echo "[6/6] Run v0.0.22 replay"

./add_gap_contract_patch_v022_replay.sh

echo "[v0.0.22] Git status"

git status
