from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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


def build_kernel_gap_update_proposal(
    case_id: str,
    gap_contract_path: str,
    v2_report_path: str,
    alias_table_path: str,
    out_path: str | None = None,
) -> dict[str, object]:
    contract = load_json(gap_contract_path)
    v2 = load_json(v2_report_path)
    alias_table = load_json(alias_table_path)

    v2_summary = v2.get("summary", {})
    all_resolved = bool(v2_summary.get("all_configured_resolved"))
    current_blocking = list(contract.get("summary", {}).get("blocking_gap_ids", []))
    gap_id = "GAP-KERNEL-NAME-001"

    proposed_kernel_gap_state = "resolved_pending_contract_update" if all_resolved else "remain_blocking"
    proposed_blocking = [g for g in current_blocking if not (g == gap_id and all_resolved)]

    proposal = {
        "schema_version": "kernel_gap_contract_update_proposal.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "target_gap_id": gap_id,
        "proposal_state": (
            "ready_for_contract_patch_review"
            if all_resolved else
            "not_ready_gap_remains_blocking"
        ),
        "source_refs": {
            "gap_contract": {
                "path": gap_contract_path,
                "sha256": sha256_file(gap_contract_path),
                "schema_version": contract.get("schema_version"),
                "contract_state": contract.get("contract_state"),
                "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
            },
            "kernel_name_resolution_report_v2": {
                "path": v2_report_path,
                "sha256": sha256_file(v2_report_path),
                "schema_version": v2.get("schema_version"),
                "resolution_state": v2.get("resolution_state"),
            },
            "kernel_alias_table": {
                "path": alias_table_path,
                "sha256": sha256_file(alias_table_path),
                "schema_version": alias_table.get("schema_version"),
            },
        },
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "contract_state_changed": False,
            "gap_state_changed": False,
            "generator_unlock_allowed": False,
            "proposal_only": True,
            "validator_required_before_applying": True,
        },
        "current_contract_snapshot": {
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
            "blocking_gap_ids": current_blocking,
            "num_blocking": contract.get("summary", {}).get("num_blocking"),
            "num_gaps": contract.get("summary", {}).get("num_gaps"),
        },
        "proposed_kernel_gap_update": {
            "gap_id": gap_id,
            "from_state": "blocking",
            "to_state": proposed_kernel_gap_state,
            "resolution_artifact_schema": v2.get("schema_version"),
            "resolution_artifact_path": v2_report_path,
            "alias_table_path": alias_table_path,
            "reason": (
                "All configured kernels are matched by exact v1 matches plus deterministic v2 alias matches."
                if all_resolved else
                "Configured kernels remain unresolved in v2 report."
            ),
        },
        "proposed_contract_delta": {
            "remove_from_blocking_gap_ids": [gap_id] if all_resolved else [],
            "remaining_blocking_gap_ids": proposed_blocking,
            "remaining_blocking_count": len(proposed_blocking),
            "migration_allowed_after_this_single_gap_update": False,
            "reason_migration_still_blocked": (
                "Other blocking gaps remain even if kernel-name gap is downgraded."
                if all_resolved and proposed_blocking else
                "Kernel-name gap is not resolved yet."
            ),
        },
        "summary": {
            "all_configured_resolved": all_resolved,
            "num_v1_matches": v2_summary.get("num_v1_matches"),
            "num_v2_alias_matches": v2_summary.get("num_v2_alias_matches"),
            "num_total_matches": v2_summary.get("num_total_matches"),
            "num_unresolved_configured": v2_summary.get("num_unresolved_configured"),
            "num_aliases": alias_table.get("summary", {}).get("num_aliases"),
            "proposal_state": (
                "ready_for_contract_patch_review"
                if all_resolved else
                "not_ready_gap_remains_blocking"
            ),
            "generator_unlock_allowed": False,
            "output_proposal_path": out_path,
        },
        "llm_annotations": [],
    }

    return proposal


def main() -> int:
    parser = argparse.ArgumentParser(description="Build kernel gap contract update proposal v0.0.21")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--alias-table", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    proposal = build_kernel_gap_update_proposal(
        case_id=args.case_id,
        gap_contract_path=args.gap_contract,
        v2_report_path=args.v2_report,
        alias_table_path=args.alias_table,
        out_path=args.out,
    )
    save_json(args.out, proposal)

    s = proposal["summary"]
    d = proposal["proposed_contract_delta"]
    print(f"[xporthls] Kernel Gap Contract Update Proposal: {args.out}")
    print(f"[xporthls] Schema: {proposal['schema_version']}")
    print(f"[xporthls] Proposal state: {proposal['proposal_state']}")
    print(f"[xporthls] All configured resolved: {s['all_configured_resolved']}")
    print(f"[xporthls] Remove from blocking: {d['remove_from_blocking_gap_ids']}")
    print(f"[xporthls] Remaining blocking count: {d['remaining_blocking_count']}")
    print(f"[xporthls] Migration allowed after this gap update: {d['migration_allowed_after_this_single_gap_update']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
