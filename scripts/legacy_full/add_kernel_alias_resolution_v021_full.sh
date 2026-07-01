#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Add Kernel Alias Table builder v1"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/kernel_alias_table_v021.py <<'EOT'
from __future__ import annotations

import argparse
import hashlib
import json
import re
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


def normalize_name(name: str | None) -> str:
    if name is None:
        return ""
    n = str(name).strip()
    n = n.replace("\\", "/")
    n = n.split("/")[-1]
    n = re.sub(r"\.(cpp|cc|cxx|c|hpp|h|hh|ini|cfg|json|tcl)$", "", n, flags=re.I)
    n = n.split("::")[-1]
    n = n.split(":")[0]
    n = n.split(".")[0]
    n = re.sub(r"[^A-Za-z0-9_]+", "_", n)
    n = re.sub(r"_+", "_", n).strip("_")
    return n.lower()


def relaxed_name(name: str | None) -> str:
    return re.sub(r"[^a-z0-9]+", "", normalize_name(name))


def tokenize(name: str | None) -> set[str]:
    return {t for t in re.split(r"[_\W]+", normalize_name(name)) if t and len(t) >= 2}


def alias_rule_for(source: str, target: str) -> dict[str, Any]:
    s_norm = normalize_name(source)
    t_norm = normalize_name(target)
    s_relaxed = relaxed_name(source)
    t_relaxed = relaxed_name(target)
    s_tokens = tokenize(source)
    t_tokens = tokenize(target)

    removed_prefix = None
    removed_suffix = None
    common_tokens = sorted(s_tokens & t_tokens)

    if s_norm.endswith(t_norm) and s_norm != t_norm:
        removed_prefix = s_norm[: -len(t_norm)].strip("_")
    if s_norm.startswith(t_norm) and s_norm != t_norm:
        removed_suffix = s_norm[len(t_norm):].strip("_")

    rule_kind = "manual_review_required"
    if s_relaxed == t_relaxed:
        rule_kind = "relaxed_exact"
    elif t_norm and (s_norm.endswith(t_norm) or s_norm.startswith(t_norm)):
        rule_kind = "prefix_suffix_alias"
    elif common_tokens:
        rule_kind = "token_overlap_alias"

    return {
        "rule_kind": rule_kind,
        "source_normalized": s_norm,
        "target_normalized": t_norm,
        "source_relaxed": s_relaxed,
        "target_relaxed": t_relaxed,
        "removed_prefix": removed_prefix,
        "removed_suffix": removed_suffix,
        "common_tokens": common_tokens,
    }


def build_alias_entries_from_diagnosis(diagnosis: dict[str, Any], min_similarity: float = 0.72) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()

    for diag in diagnosis.get("diagnoses", []):
        classification = diag.get("classification")
        raw_name = diag.get("raw_name")
        norm = diag.get("normalized") or normalize_name(raw_name)
        candidates = diag.get("nearest_declared_candidates", [])

        if classification != "naming_normalization_or_alias_gap":
            continue

        viable = [
            c for c in candidates
            if isinstance(c.get("similarity"), (int, float)) and float(c.get("similarity")) >= min_similarity
        ]

        if not viable:
            continue

        best = sorted(viable, key=lambda x: (-float(x.get("similarity", 0)), x.get("normalized") or ""))[0]
        target_raw = best.get("raw_name") or best.get("normalized")
        target_norm = best.get("normalized") or normalize_name(target_raw)

        key = (norm, target_norm)
        if key in seen:
            continue
        seen.add(key)

        rule = alias_rule_for(raw_name or norm, target_raw or target_norm)

        entries.append({
            "alias_id": f"KERNEL-ALIAS-{len(entries) + 1:03d}",
            "source": {
                "raw_name": raw_name,
                "normalized": norm,
                "relaxed": diag.get("relaxed") or relaxed_name(raw_name),
                "diagnosis_id": diag.get("diagnosis_id"),
                "classification": classification,
                "source": diag.get("source"),
                "pointer": diag.get("pointer"),
            },
            "target": {
                "raw_name": target_raw,
                "normalized": target_norm,
                "relaxed": relaxed_name(target_raw),
                "source": best.get("source"),
                "pointer": best.get("pointer"),
            },
            "evidence": {
                "diagnosis_confidence": diag.get("confidence"),
                "diagnosis_confidence_score": diag.get("confidence_score"),
                "nearest_declared_similarity": best.get("similarity"),
                "diagnosis_evidence": diag.get("evidence", []),
                "diagnosis_recommendations": diag.get("recommendations", []),
                "nearest_declared_candidates": candidates[:5],
            },
            "rule": rule,
            "alias_state": "proposed_validated_candidate",
            "llm_used": False,
            "requires_validator_before_contract_update": True,
            "safe_to_apply_in_resolution_v2": True,
        })

    return entries


def build_kernel_alias_table(
    case_id: str,
    diagnosis_path: str,
    kernel_resolution_path: str,
    out_path: str | None = None,
    min_similarity: float = 0.72,
) -> dict[str, Any]:
    diagnosis = load_json(diagnosis_path)
    kernel_resolution = load_json(kernel_resolution_path)

    entries = build_alias_entries_from_diagnosis(diagnosis, min_similarity=min_similarity)

    unresolved_names = [
        item.get("normalized")
        for item in kernel_resolution.get("unresolved", {}).get("configured_kernels", [])
    ]
    aliased_source_names = {e.get("source", {}).get("normalized") for e in entries}
    missing_aliases = sorted([n for n in unresolved_names if n and n not in aliased_source_names])

    table = {
        "schema_version": "kernel_alias_table.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "source_refs": {
            "kernel_unresolved_diagnosis": {
                "path": diagnosis_path,
                "sha256": sha256_file(diagnosis_path),
                "schema_version": diagnosis.get("schema_version"),
            },
            "kernel_name_resolution_report_v1": {
                "path": kernel_resolution_path,
                "sha256": sha256_file(kernel_resolution_path),
                "schema_version": kernel_resolution.get("schema_version"),
                "resolution_state": kernel_resolution.get("resolution_state"),
            },
        },
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "contract_state_changed": False,
            "gap_state_changed": False,
            "generator_unlock_allowed": False,
            "min_similarity": min_similarity,
            "purpose": "Create deterministic alias candidates for Kernel Name Resolver v2 without updating the gap contract.",
        },
        "aliases": entries,
        "summary": {
            "num_aliases": len(entries),
            "num_unresolved_configured_from_v1": len(unresolved_names),
            "num_unresolved_without_alias_candidate": len(missing_aliases),
            "unresolved_without_alias_candidate": missing_aliases,
            "alias_source_names": sorted(aliased_source_names),
            "alias_target_names": sorted({e.get("target", {}).get("normalized") for e in entries}),
            "all_v1_unresolved_have_alias_candidates": len(missing_aliases) == 0,
            "generator_unlock_allowed": False,
            "output_table_path": out_path,
        },
        "llm_annotations": [],
    }

    return table


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Kernel Alias Table v0.0.21")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--diagnosis", required=True)
    parser.add_argument("--kernel-resolution-report", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--min-similarity", type=float, default=0.72)
    args = parser.parse_args()

    table = build_kernel_alias_table(
        case_id=args.case_id,
        diagnosis_path=args.diagnosis,
        kernel_resolution_path=args.kernel_resolution_report,
        out_path=args.out,
        min_similarity=args.min_similarity,
    )
    save_json(args.out, table)

    s = table["summary"]
    print(f"[xporthls] Kernel Alias Table: {args.out}")
    print(f"[xporthls] Schema: {table['schema_version']}")
    print(f"[xporthls] Aliases: {s['num_aliases']}")
    print(f"[xporthls] V1 unresolved configured: {s['num_unresolved_configured_from_v1']}")
    print(f"[xporthls] Missing alias candidates: {s['num_unresolved_without_alias_candidate']}")
    print(f"[xporthls] All unresolved have aliases: {s['all_v1_unresolved_have_alias_candidates']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add Kernel Name Resolver v2"

cat > xporthls/realrepo/kernel_name_resolver_v021.py <<'EOT'
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

EOT

echo "[3/7] Add kernel gap contract update proposal builder"

cat > xporthls/realrepo/kernel_gap_update_proposal_v021.py <<'EOT'
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
EOT

echo "[4/7] Add v0.0.21 validators"

cat > xporthls/realrepo/validate_kernel_alias_resolution_v021.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class V021Issue:
    severity: str
    code: str
    message: str


@dataclass
class V021ValidationReport:
    status: str
    issues: list[V021Issue] = field(default_factory=list)
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


def issue(issues: list[V021Issue], severity: str, code: str, message: str) -> None:
    issues.append(V021Issue(severity=severity, code=code, message=message))


def validate(alias_table: dict[str, Any], v2: dict[str, Any], proposal: dict[str, Any]) -> V021ValidationReport:
    issues: list[V021Issue] = []

    if alias_table.get("schema_version") != "kernel_alias_table.v1":
        issue(issues, "error", "ALIAS_TABLE_SCHEMA", "Expected kernel_alias_table.v1.")

    if v2.get("schema_version") != "kernel_name_resolution_report_v2.v1":
        issue(issues, "error", "V2_SCHEMA", "Expected kernel_name_resolution_report_v2.v1.")

    if proposal.get("schema_version") != "kernel_gap_contract_update_proposal.v1":
        issue(issues, "error", "PROPOSAL_SCHEMA", "Expected kernel_gap_contract_update_proposal.v1.")

    for obj_name, obj in [
        ("alias_table", alias_table),
        ("v2", v2),
        ("proposal", proposal),
    ]:
        if obj.get("llm_annotations") != []:
            issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", f"{obj_name} must not contain LLM annotations.")
        policy = obj.get("policy", {})
        if policy.get("deterministic_only") is not True:
            issue(issues, "error", "POLICY_NOT_DETERMINISTIC", f"{obj_name} must be deterministic_only.")
        if policy.get("llm_used") is not False:
            issue(issues, "error", "LLM_USED", f"{obj_name} must not use LLM.")
        if policy.get("contract_state_changed") is not False:
            issue(issues, "error", "CONTRACT_STATE_CHANGED", f"{obj_name} must not change contract state.")
        if policy.get("gap_state_changed") is not False:
            issue(issues, "error", "GAP_STATE_CHANGED", f"{obj_name} must not change gap state.")
        if policy.get("generator_unlock_allowed") is not False:
            issue(issues, "error", "GENERATOR_UNLOCK_ALLOWED", f"{obj_name} must not unlock generator.")

    alias_summary = alias_table.get("summary", {})
    aliases = alias_table.get("aliases", [])
    if int(alias_summary.get("num_aliases") or -1) != len(aliases):
        issue(issues, "error", "ALIAS_COUNT_MISMATCH", "Alias summary count mismatch.")

    if int(alias_summary.get("num_aliases") or 0) <= 0:
        issue(issues, "error", "NO_ALIASES", "Expected at least one alias candidate from v0.0.20 diagnosis.")

    seen_alias_ids = set()
    seen_sources = set()
    for entry in aliases:
        aid = entry.get("alias_id")
        if aid in seen_alias_ids:
            issue(issues, "error", "DUPLICATE_ALIAS_ID", f"Duplicate alias id: {aid}")
        seen_alias_ids.add(aid)

        src = entry.get("source", {}).get("normalized")
        tgt = entry.get("target", {}).get("normalized")
        if not src or not tgt:
            issue(issues, "error", "ALIAS_ENDPOINT_MISSING", f"Alias {aid} missing source/target normalized names.")
        if src in seen_sources:
            issue(issues, "error", "DUPLICATE_ALIAS_SOURCE", f"Duplicate alias source: {src}")
        seen_sources.add(src)

        if entry.get("llm_used") is not False:
            issue(issues, "error", "ALIAS_LLM_USED", f"Alias {aid} must not use LLM.")
        if entry.get("requires_validator_before_contract_update") is not True:
            issue(issues, "error", "ALIAS_VALIDATOR_REQUIRED", f"Alias {aid} must require validator before contract update.")
        sim = entry.get("evidence", {}).get("nearest_declared_similarity")
        if not isinstance(sim, (int, float)) or float(sim) < 0.72:
            issue(issues, "error", "ALIAS_SIMILARITY_LOW", f"Alias {aid} similarity too low: {sim!r}")

    v2_summary = v2.get("summary", {})
    if int(v2_summary.get("num_total_matches") or 0) != int(v2_summary.get("num_v1_matches") or 0) + int(v2_summary.get("num_v2_alias_matches") or 0):
        issue(issues, "error", "V2_MATCH_TOTAL_MISMATCH", "V2 total matches must equal v1 + alias matches.")

    if int(v2_summary.get("num_v2_alias_matches") or 0) != int(alias_summary.get("num_aliases") or 0):
        issue(issues, "warning", "ALIAS_MATCH_COUNT_DIFFERS", "Some aliases may not have produced v2 matches.")

    if v2_summary.get("generator_unlock_allowed") is not False:
        issue(issues, "error", "V2_UNLOCK_ALLOWED", "V2 report must not unlock generator.")

    if v2.get("gap_transition_proposal", {}).get("generator_unlock_allowed") is not False:
        issue(issues, "error", "V2_TRANSITION_UNLOCK_ALLOWED", "V2 transition proposal must not unlock generator.")

    all_resolved = bool(v2_summary.get("all_configured_resolved"))
    proposal_summary = proposal.get("summary", {})
    delta = proposal.get("proposed_contract_delta", {})

    if proposal_summary.get("all_configured_resolved") != all_resolved:
        issue(issues, "error", "PROPOSAL_ALL_RESOLVED_MISMATCH", "Proposal all_configured_resolved mismatch.")

    if all_resolved:
        if proposal.get("proposal_state") != "ready_for_contract_patch_review":
            issue(issues, "error", "PROPOSAL_STATE_EXPECT_READY", "Resolved v2 should create ready_for_contract_patch_review proposal.")
        if "GAP-KERNEL-NAME-001" not in delta.get("remove_from_blocking_gap_ids", []):
            issue(issues, "error", "KERNEL_GAP_NOT_REMOVED_IN_DELTA", "Resolved v2 should propose removing GAP-KERNEL-NAME-001 from blocking list.")
    else:
        if proposal.get("proposal_state") != "not_ready_gap_remains_blocking":
            issue(issues, "error", "PROPOSAL_STATE_EXPECT_NOT_READY", "Partial v2 should keep proposal not ready.")
        if delta.get("remove_from_blocking_gap_ids"):
            issue(issues, "error", "PARTIAL_SHOULD_NOT_REMOVE_GAP", "Partial v2 must not remove blocking gap.")

    if delta.get("migration_allowed_after_this_single_gap_update") is not False:
        issue(issues, "error", "MIGRATION_ALLOWED_BY_SINGLE_GAP", "Single kernel-name update must not allow full migration.")

    if proposal_summary.get("generator_unlock_allowed") is not False:
        issue(issues, "error", "PROPOSAL_UNLOCK_ALLOWED", "Proposal must not unlock generator.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return V021ValidationReport(
        status=status,
        issues=issues,
        summary={
            "alias_schema": alias_table.get("schema_version"),
            "v2_schema": v2.get("schema_version"),
            "proposal_schema": proposal.get("schema_version"),
            "num_aliases": alias_summary.get("num_aliases"),
            "num_v1_matches": v2_summary.get("num_v1_matches"),
            "num_v2_alias_matches": v2_summary.get("num_v2_alias_matches"),
            "num_total_matches": v2_summary.get("num_total_matches"),
            "num_unresolved_configured": v2_summary.get("num_unresolved_configured"),
            "all_configured_resolved": v2_summary.get("all_configured_resolved"),
            "proposal_state": proposal.get("proposal_state"),
            "remove_from_blocking_gap_ids": delta.get("remove_from_blocking_gap_ids"),
            "remaining_blocking_count": delta.get("remaining_blocking_count"),
            "generator_unlock_allowed": False,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate kernel alias table and resolver v2 outputs v0.0.21")
    parser.add_argument("--alias-table", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    alias_table = load_json(args.alias_table)
    v2 = load_json(args.v2_report)
    proposal = load_json(args.proposal)

    report = validate(alias_table, v2, proposal)
    report.save(args.out)

    print(f"[xporthls] Kernel Alias/Resolver v2 validation written to: {args.out}")
    print(f"[xporthls] Kernel Alias/Resolver v2 validation status: {report.status}")
    for i in report.issues:
        print(f"  - {i.severity.upper()} {i.code}: {i.message}")
    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[5/7] Add v0.0.21 orchestration runner"

cat > xporthls/realrepo/run_kernel_alias_resolution_v021.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_alias_table_v021 import build_kernel_alias_table, save_json
from xporthls.realrepo.kernel_name_resolver_v021 import build_kernel_name_resolution_v2_report
from xporthls.realrepo.kernel_gap_update_proposal_v021 import build_kernel_gap_update_proposal
from xporthls.realrepo.validate_kernel_alias_resolution_v021 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.21 Kernel Alias Table + Resolver v2")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--diagnosis", required=True)
    parser.add_argument("--v1-report", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    parser.add_argument("--min-similarity", type=float, default=0.72)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    alias_table_path = out_dir / f"{args.case_id}_kernel_alias_table_v021.json"
    v2_report_path = out_dir / f"{args.case_id}_kernel_name_resolution_report_v2_v021.json"
    proposal_path = out_dir / f"{args.case_id}_kernel_gap_update_proposal_v021.json"
    validation_path = out_dir / f"{args.case_id}_kernel_alias_resolution_validation_v021.json"

    alias_table = build_kernel_alias_table(
        case_id=args.case_id,
        diagnosis_path=args.diagnosis,
        kernel_resolution_path=args.v1_report,
        out_path=str(alias_table_path),
        min_similarity=args.min_similarity,
    )
    save_json(alias_table_path, alias_table)

    v2_report = build_kernel_name_resolution_v2_report(
        case_id=args.case_id,
        v1_report_path=args.v1_report,
        alias_table_path=str(alias_table_path),
        diagnosis_path=args.diagnosis,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=str(v2_report_path),
    )
    save_json(v2_report_path, v2_report)

    proposal = build_kernel_gap_update_proposal(
        case_id=args.case_id,
        gap_contract_path=args.gap_contract,
        v2_report_path=str(v2_report_path),
        alias_table_path=str(alias_table_path),
        out_path=str(proposal_path),
    )
    save_json(proposal_path, proposal)

    validation = validate(alias_table, v2_report, proposal)
    validation.save(validation_path)

    print(f"[xporthls] Kernel Alias Table: {alias_table_path}")
    print(f"[xporthls] Kernel Name Resolution v2: {v2_report_path}")
    print(f"[xporthls] Kernel Gap Update Proposal: {proposal_path}")
    print(f"[xporthls] Validation report: {validation_path}")

    a = alias_table["summary"]
    v = v2_report["summary"]
    p = proposal["summary"]
    print(f"[xporthls] Aliases: {a['num_aliases']}")
    print(f"[xporthls] V1 matches: {v['num_v1_matches']}")
    print(f"[xporthls] V2 alias matches: {v['num_v2_alias_matches']}")
    print(f"[xporthls] Total matches: {v['num_total_matches']}")
    print(f"[xporthls] Unresolved configured: {v['num_unresolved_configured']}")
    print(f"[xporthls] All configured resolved: {v['all_configured_resolved']}")
    print(f"[xporthls] Proposal state: {proposal['proposal_state']}")
    print(f"[xporthls] Generator unlock allowed: {p['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[6/7] Update README and create replay script"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Kernel alias table and resolver v2

XPortHLS can turn unresolved kernel-name diagnosis results into a deterministic alias table and apply it in Kernel Name Resolver v2. This creates a report-level resolution and a contract-update proposal for `GAP-KERNEL-NAME-001`.

Example:

```bash
python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \\
  --case-id hisparse_u280_profile \\
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \\
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \\
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \\
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \\
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_kernel_alias_table_v021.json
experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json
experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json
experiments/runs/hisparse_u280_profile_kernel_alias_resolution_validation_v021.json
```

The v0.0.21 flow is deterministic and proposal-only. It does not modify the gap contract and does not unlock generation.
"""

if "## Kernel alias table and resolver v2" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

cat > add_kernel_alias_resolution_v021_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"

echo "[v0.0.21] Python syntax check"

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
  xporthls/realrepo/run_kernel_alias_resolution_v021.py

echo "[v0.0.21] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.21] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.21] Run Kernel Alias Table + Resolver v2"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.21] Re-run generator guard to prove generation is still blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report "$GUARD_REPORT" \
  --out "$GUARD_VALIDATION" \
  --expect-blocked

python3 - <<'PY'
import json
from pathlib import Path

alias_table = json.load(open("experiments/runs/hisparse_u280_profile_kernel_alias_table_v021.json"))
v2 = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json"))
proposal = json.load(open("experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_alias_resolution_validation_v021.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

a = alias_table["summary"]
v = v2["summary"]
p = proposal["summary"]

print()
print("Alias table schema:", alias_table["schema_version"])
print("Aliases:", a["num_aliases"])
print("All v1 unresolved have aliases:", a["all_v1_unresolved_have_alias_candidates"])
print("V2 schema:", v2["schema_version"])
print("V2 resolution state:", v2["resolution_state"])
print("V1 matches:", v["num_v1_matches"])
print("V2 alias matches:", v["num_v2_alias_matches"])
print("Total matches:", v["num_total_matches"])
print("Unresolved configured:", v["num_unresolved_configured"])
print("All configured resolved:", v["all_configured_resolved"])
print("Proposal schema:", proposal["schema_version"])
print("Proposal state:", proposal["proposal_state"])
print("Remove from blocking:", proposal["proposed_contract_delta"]["remove_from_blocking_gap_ids"])
print("Remaining blocking count:", proposal["proposed_contract_delta"]["remaining_blocking_count"])
print("Migration allowed after single gap update:", proposal["proposed_contract_delta"]["migration_allowed_after_this_single_gap_update"])
print("Generator unlock allowed:", p["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert alias_table["schema_version"] == "kernel_alias_table.v1"
assert v2["schema_version"] == "kernel_name_resolution_report_v2.v1"
assert proposal["schema_version"] == "kernel_gap_contract_update_proposal.v1"
assert alias_table["policy"]["llm_used"] is False
assert v2["policy"]["llm_used"] is False
assert proposal["policy"]["llm_used"] is False
assert alias_table["policy"]["generator_unlock_allowed"] is False
assert v2["policy"]["generator_unlock_allowed"] is False
assert proposal["policy"]["generator_unlock_allowed"] is False
assert a["num_aliases"] > 0
assert v["num_total_matches"] == v["num_v1_matches"] + v["num_v2_alias_matches"]
assert v["generator_unlock_allowed"] is False
assert p["generator_unlock_allowed"] is False
assert proposal["proposed_contract_delta"]["migration_allowed_after_this_single_gap_update"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
EOT

chmod +x add_kernel_alias_resolution_v021_replay.sh

echo "[7/7] Run v0.0.21 replay"

./add_kernel_alias_resolution_v021_replay.sh

echo "[v0.0.21] Git status"

git status
