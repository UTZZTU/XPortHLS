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
