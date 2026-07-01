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


def normalized_set(items: list[dict[str, object]]) -> set[str]:
    return {str(i.get("normalized")) for i in items if i.get("normalized")}


def build_alias_map(alias_table: dict[str, object]) -> dict[str, dict[str, object]]:
    out: dict[str, dict[str, object]] = {}
    for entry in alias_table.get("aliases", []):
        if not isinstance(entry, dict):
            continue
        source_norm = entry.get("source", {}).get("normalized") if isinstance(entry.get("source"), dict) else None
        if not source_norm:
            continue
        out[str(source_norm)] = entry
    return out


def declared_record_from_alias_target(alias: dict[str, object]) -> dict[str, object] | None:
    # Create a declared-function record from a validated alias target.
    #
    # v0.0.19's declared list can be conservative. v0.0.20 diagnosis may find
    # nearest declared candidates from HLSIR/ApplicationIR evidence that are not
    # present in the v1 declared-function list. v0.0.21 should allow those alias
    # targets to participate in report-level resolution, while preserving evidence
    # that they came from the alias table and not from v1 exact extraction.
    target = alias.get("target", {})
    if not isinstance(target, dict):
        return None

    normalized = target.get("normalized")
    raw_name = target.get("raw_name") or normalized
    if not normalized or not raw_name:
        return None

    return {
        "kind": "declared_function",
        "raw_name": raw_name,
        "normalized": normalized,
        "relaxed": target.get("relaxed"),
        "source": target.get("source") or "kernel_alias_table_target",
        "pointer": target.get("pointer") or f"/aliases/{alias.get('alias_id')}/target",
        "metadata": {
            "introduced_by": "kernel_alias_table.v1",
            "alias_id": alias.get("alias_id"),
            "report_level_only": True,
            "requires_validator_before_contract_update": True,
        },
    }


def build_kernel_name_resolution_v2_report(
    case_id: str,
    v1_report_path: str,
    alias_table_path: str,
    diagnosis_path: str,
    gap_contract_path: str,
    resolver_plan_path: str,
    out_path: str | None = None,
) -> dict[str, object]:
    v1 = load_json(v1_report_path)
    alias_table = load_json(alias_table_path)
    diagnosis = load_json(diagnosis_path)
    contract = load_json(gap_contract_path)
    plan = load_json(resolver_plan_path)

    alias_map = build_alias_map(alias_table)

    configured = list(v1.get("inputs", {}).get("configured_kernels", []))
    declared = list(v1.get("inputs", {}).get("declared_functions", []))
    v1_matches = list(v1.get("matches", []))
    v1_unresolved_configured = list(v1.get("unresolved", {}).get("configured_kernels", []))
    v1_unresolved_declared = list(v1.get("unresolved", {}).get("declared_functions", []))

    declared_by_norm = {
        str(d.get("normalized")): d
        for d in declared
        if d.get("normalized")
    }

    used_declared = {
        str(m.get("declared", {}).get("normalized"))
        for m in v1_matches
        if isinstance(m.get("declared"), dict) and m.get("declared", {}).get("normalized")
    }

    alias_matches = []
    still_unresolved_configured = []

    for item in v1_unresolved_configured:
        source_norm = str(item.get("normalized"))
        alias = alias_map.get(source_norm)
        if not alias:
            still_unresolved_configured.append(item)
            continue

        target_norm = str(alias.get("target", {}).get("normalized"))
        target_declared = declared_by_norm.get(target_norm)

        if not target_declared:
            target_declared = declared_record_from_alias_target(alias)
            if target_declared:
                declared.append(target_declared)
                declared_by_norm[target_norm] = target_declared

        if not target_declared:
            still_unresolved_configured.append(item)
            continue

        alias_matches.append({
            "configured": item,
            "declared": target_declared,
            "score": 0.88,
            "method": "validated_alias_table",
            "alias_id": alias.get("alias_id"),
            "alias_rule": alias.get("rule"),
            "reasons": [
                "v0.0.20 classified this unresolved kernel as naming_normalization_or_alias_gap.",
                "v0.0.21 alias table selected a deterministic nearest declared candidate above threshold.",
                "Alias is used for resolution report only and does not update the gap contract.",
            ],
            "evidence": alias.get("evidence", {}),
        })
        used_declared.add(target_norm)

    all_matches = v1_matches + alias_matches
    unresolved_declared = [
        d for d in declared
        if str(d.get("normalized")) not in used_declared
    ]

    resolution_state = "resolved_pending_contract_update" if not still_unresolved_configured else "partial"

    update_proposal_state = (
        "kernel_name_gap_resolved_pending_contract_update"
        if resolution_state == "resolved_pending_contract_update"
        else "kernel_name_gap_remains_partial"
    )

    report = {
        "schema_version": "kernel_name_resolution_report_v2.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "resolver_id": "RESOLVE-GAP-KERNEL-NAME-001",
        "gap_id": "GAP-KERNEL-NAME-001",
        "resolution_state": resolution_state,
        "migration_status": "profile_only",
        "source_refs": {
            "kernel_name_resolution_report_v1": {
                "path": v1_report_path,
                "sha256": sha256_file(v1_report_path),
                "schema_version": v1.get("schema_version"),
                "resolution_state": v1.get("resolution_state"),
            },
            "kernel_alias_table": {
                "path": alias_table_path,
                "sha256": sha256_file(alias_table_path),
                "schema_version": alias_table.get("schema_version"),
            },
            "kernel_unresolved_diagnosis": {
                "path": diagnosis_path,
                "sha256": sha256_file(diagnosis_path),
                "schema_version": diagnosis.get("schema_version"),
            },
            "gap_contract": {
                "path": gap_contract_path,
                "sha256": sha256_file(gap_contract_path),
                "schema_version": contract.get("schema_version"),
                "contract_state": contract.get("contract_state"),
                "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
            },
            "gap_resolver_plan": {
                "path": resolver_plan_path,
                "sha256": sha256_file(resolver_plan_path),
                "schema_version": plan.get("schema_version"),
                "plan_state": plan.get("plan_state"),
            },
        },
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "gap_state_changed": False,
            "contract_state_changed": False,
            "generator_unlock_allowed": False,
            "alias_table_applied_to_report_only": True,
            "notes": [
                "v0.0.21 resolves kernel names in a v2 report using a deterministic alias table.",
                "It does not directly modify source-to-target gap contract.",
                "It does not unlock target generation.",
            ],
        },
        "inputs": {
            "configured_kernels": configured,
            "declared_functions": declared,
            "aliases": alias_table.get("aliases", []),
        },
        "matches": all_matches,
        "match_breakdown": {
            "v1_exact_matches": v1_matches,
            "v2_alias_matches": alias_matches,
        },
        "unresolved": {
            "configured_kernels": still_unresolved_configured,
            "declared_functions": unresolved_declared,
        },
        "gap_transition_proposal": {
            "gap_id": "GAP-KERNEL-NAME-001",
            "current_contract_state": contract.get("contract_state"),
            "proposed_gap_state": (
                "resolved_pending_contract_update"
                if resolution_state == "resolved_pending_contract_update"
                else "remain_blocking"
            ),
            "proposal_state": update_proposal_state,
            "contract_update_required": resolution_state == "resolved_pending_contract_update",
            "generator_unlock_allowed": False,
            "reason": (
                "All configured kernels are matched after applying deterministic alias table. Contract update proposal may downgrade this specific gap, but generator remains blocked by other gaps."
                if resolution_state == "resolved_pending_contract_update"
                else "Some configured kernels remain unresolved after alias table application."
            ),
        },
        "summary": {
            "num_configured_kernels": len(configured),
            "num_declared_functions": len(declared),
            "num_v1_matches": len(v1_matches),
            "num_v2_alias_matches": len(alias_matches),
            "num_total_matches": len(all_matches),
            "num_unresolved_configured": len(still_unresolved_configured),
            "num_unresolved_declared": len(unresolved_declared),
            "num_aliases": len(alias_table.get("aliases", [])),
            "resolution_state": resolution_state,
            "all_configured_resolved": len(still_unresolved_configured) == 0,
            "generator_unlock_allowed": False,
            "output_report_path": out_path,
        },
        "traceability": {
            "v1_summary": v1.get("summary", {}),
            "alias_table_summary": alias_table.get("summary", {}),
            "diagnosis_summary": diagnosis.get("summary", {}),
            "contract_summary": contract.get("summary", {}),
            "resolver_plan_summary": plan.get("summary", {}),
        },
        "llm_annotations": [],
    }

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Kernel Name Resolver v2 using alias table")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--v1-report", required=True)
    parser.add_argument("--alias-table", required=True)
    parser.add_argument("--diagnosis", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = build_kernel_name_resolution_v2_report(
        case_id=args.case_id,
        v1_report_path=args.v1_report,
        alias_table_path=args.alias_table,
        diagnosis_path=args.diagnosis,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=args.out,
    )
    save_json(args.out, report)

    s = report["summary"]
    print(f"[xporthls] Kernel Name Resolution v2 report: {args.out}")
    print(f"[xporthls] Schema: {report['schema_version']}")
    print(f"[xporthls] Resolution state: {report['resolution_state']}")
    print(f"[xporthls] Configured kernels: {s['num_configured_kernels']}")
    print(f"[xporthls] V1 matches: {s['num_v1_matches']}")
    print(f"[xporthls] V2 alias matches: {s['num_v2_alias_matches']}")
    print(f"[xporthls] Total matches: {s['num_total_matches']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] All configured resolved: {s['all_configured_resolved']}")
    print(f"[xporthls] Proposed gap state: {report['gap_transition_proposal']['proposed_gap_state']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
