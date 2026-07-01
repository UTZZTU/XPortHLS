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
