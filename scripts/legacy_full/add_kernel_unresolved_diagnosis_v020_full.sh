#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add Kernel Unresolved Diagnosis v1"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/kernel_unresolved_diagnosis_v020.py <<'EOT'
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


def normalize_name(name: str) -> str:
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


def relaxed_name(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", normalize_name(name))


def tokens(name: str) -> set[str]:
    n = normalize_name(name)
    return {t for t in re.split(r"[_\W]+", n) if t and len(t) >= 2}


def token_similarity(a: str, b: str) -> float:
    ta = tokens(a)
    tb = tokens(b)
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / max(len(ta | tb), 1)


def string_similarity(a: str, b: str) -> float:
    an = relaxed_name(a)
    bn = relaxed_name(b)
    if not an or not bn:
        return 0.0
    if an == bn:
        return 1.0
    if an in bn or bn in an:
        return min(len(an), len(bn)) / max(len(an), len(bn))
    return token_similarity(a, b)


def iter_strings(obj: Any, pointer: str = "") -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            safe = str(k).replace("~", "~0").replace("/", "~1")
            out.extend(iter_strings(v, f"{pointer}/{safe}"))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out.extend(iter_strings(v, f"{pointer}/{i}"))
    elif isinstance(obj, str):
        out.append((pointer, obj))
    return out


def find_mentions(name: str, objects: dict[str, dict[str, Any]], max_hits: int = 10) -> list[dict[str, Any]]:
    norm = normalize_name(name)
    relaxed = relaxed_name(name)
    raw = str(name).strip()

    if not norm and not relaxed and not raw:
        return []

    hits: list[dict[str, Any]] = []
    for source_name, obj in objects.items():
        for pointer, text in iter_strings(obj):
            hay = text.lower()
            hay_relaxed = re.sub(r"[^a-z0-9]+", "", hay)
            if (
                (raw and raw.lower() in hay)
                or (norm and norm in hay)
                or (relaxed and relaxed in hay_relaxed)
            ):
                hits.append({
                    "source": source_name,
                    "pointer": pointer,
                    "snippet": text[:300],
                })
                if len(hits) >= max_hits:
                    return hits
    return hits


def collect_declared_names(kernel_report: dict[str, Any], hls_ir: dict[str, Any], app_ir: dict[str, Any]) -> list[dict[str, Any]]:
    declared: list[dict[str, Any]] = []

    for item in kernel_report.get("inputs", {}).get("declared_functions", []):
        declared.append({
            "raw_name": item.get("raw_name"),
            "normalized": item.get("normalized") or normalize_name(item.get("raw_name", "")),
            "source": item.get("source"),
            "pointer": item.get("pointer"),
        })

    # Conservative recursive extraction of function-like names from HLS IR.
    for pointer, text in iter_strings(hls_ir):
        pl = pointer.lower()
        if any(tok in pl for tok in ["function", "kernel", "candidate", "name"]):
            if isinstance(text, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_:]*", text.strip()):
                declared.append({
                    "raw_name": text.strip(),
                    "normalized": normalize_name(text.strip()),
                    "source": "hls_ir_recursive",
                    "pointer": pointer,
                })

    # Kernel graph may include names.
    kg = app_ir.get("kernel_graph", {})
    for pointer, text in iter_strings(kg):
        pl = pointer.lower()
        if any(tok in pl for tok in ["declared", "hls", "function", "candidate", "kernel", "name"]):
            if isinstance(text, str) and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_:]*", text.strip()):
                declared.append({
                    "raw_name": text.strip(),
                    "normalized": normalize_name(text.strip()),
                    "source": "application_ir_kernel_graph",
                    "pointer": f"/kernel_graph{pointer}",
                })

    seen = set()
    unique = []
    for item in declared:
        norm = item.get("normalized")
        if not norm or norm in seen:
            continue
        seen.add(norm)
        unique.append(item)

    return sorted(unique, key=lambda x: x["normalized"])


def nearest_declared(name: str, declared: list[dict[str, Any]], limit: int = 5) -> list[dict[str, Any]]:
    scored = []
    for d in declared:
        dname = d.get("raw_name") or d.get("normalized") or ""
        score = string_similarity(name, dname)
        if score > 0:
            scored.append({
                "raw_name": d.get("raw_name"),
                "normalized": d.get("normalized"),
                "source": d.get("source"),
                "pointer": d.get("pointer"),
                "similarity": round(score, 4),
            })
    scored.sort(key=lambda x: (-x["similarity"], x["normalized"] or ""))
    return scored[:limit]


def classify_unresolved(
    unresolved: dict[str, Any],
    declared: list[dict[str, Any]],
    mentions: list[dict[str, Any]],
) -> tuple[str, str, float, list[str], list[str]]:
    raw = unresolved.get("raw_name", "")
    norm = unresolved.get("normalized") or normalize_name(raw)
    meta = unresolved.get("metadata", {}) or {}
    source = unresolved.get("source", "")
    pointer = unresolved.get("pointer", "")
    parsed_from = str(meta.get("parsed_from", ""))

    evidence: list[str] = []
    recommendations: list[str] = []

    if meta.get("synthetic") is True or source == "summary_count_fallback" or norm.startswith("__configured_kernel_unextracted"):
        evidence.append("Kernel name was synthesized from summary count fallback.")
        recommendations.append("Improve ApplicationIR v2 kernel_graph export so real configured kernel names are preserved.")
        recommendations.append("Avoid changing contract state until synthetic configured names disappear.")
        return "summary_count_fallback", "high", 0.95, evidence, recommendations

    if re.search(r"(_|\b)(cu|inst)?\d+$", str(raw)) or "instance" in parsed_from:
        evidence.append("Raw name looks like a compute-unit instance or connectivity instance prefix.")
        recommendations.append("Strip instance suffix and map compute-unit instance to base HLS function via nk/sp directives.")
        return "compute_unit_instance_name", "medium", 0.8, evidence, recommendations

    nearest = nearest_declared(raw, declared, limit=3)
    if nearest and nearest[0]["similarity"] >= 0.72:
        evidence.append(f"Nearest declared function is similar: {nearest[0]['raw_name']} score={nearest[0]['similarity']}.")
        recommendations.append("Add alias-aware normalization for this name pattern before treating it as missing source.")
        return "naming_normalization_or_alias_gap", "medium", float(nearest[0]["similarity"]), evidence, recommendations

    if nearest and nearest[0]["similarity"] >= 0.45:
        evidence.append(f"Some declared functions share tokens with this name: {nearest[0]['raw_name']} score={nearest[0]['similarity']}.")
        recommendations.append("Inspect whether this is a wrapper/helper mismatch or abbreviated connectivity alias.")
        return "helper_or_wrapper_name_mismatch", "medium", float(nearest[0]["similarity"]), evidence, recommendations

    mention_sources = {m.get("source") for m in mentions}
    if "connectivity_ir" in mention_sources and "hls_ir" not in mention_sources:
        evidence.append("Name is mentioned in ConnectivityIR but not found in HLSIR string mentions.")
        recommendations.append("Check whether connectivity references a generated kernel alias, stale kernel, or source file missing from BuildIR.")
        return "connectivity_name_without_hls_top_function", "high", 0.85, evidence, recommendations

    if "connectivity_ir" in mention_sources and "hls_ir" in mention_sources:
        evidence.append("Name appears in both ConnectivityIR and HLSIR but the resolver did not match it.")
        recommendations.append("Enhance resolver extraction pointers and exact name preservation from HLS InterfaceIR.")
        return "name_extraction_pointer_gap", "medium", 0.7, evidence, recommendations

    if "build_ir" not in mention_sources and "hls_ir" not in mention_sources:
        evidence.append("Name is not found in BuildIR or HLSIR string mentions.")
        recommendations.append("Treat this as possible false positive from connectivity parsing until source evidence is found.")
        return "possible_false_positive_from_connectivity_parsing", "medium", 0.65, evidence, recommendations

    evidence.append("Name has insufficient evidence for a precise diagnosis.")
    recommendations.append("Inspect source files and connectivity directives manually or improve deterministic extraction.")
    return "insufficient_evidence", "low", 0.5, evidence, recommendations


def make_diagnosis_entry(
    unresolved: dict[str, Any],
    declared: list[dict[str, Any]],
    objects: dict[str, dict[str, Any]],
    index: int,
) -> dict[str, Any]:
    raw = unresolved.get("raw_name")
    norm = unresolved.get("normalized") or normalize_name(raw)
    mentions = find_mentions(raw or norm, objects)
    nearest = nearest_declared(raw or norm, declared)

    classification, confidence, confidence_score, evidence, recommendations = classify_unresolved(
        unresolved,
        declared,
        mentions,
    )

    return {
        "diagnosis_id": f"UNRESOLVED-KERNEL-{index:03d}",
        "raw_name": raw,
        "normalized": norm,
        "relaxed": unresolved.get("relaxed") or relaxed_name(raw or norm),
        "classification": classification,
        "confidence": confidence,
        "confidence_score": round(float(confidence_score), 4),
        "source": unresolved.get("source"),
        "pointer": unresolved.get("pointer"),
        "metadata": unresolved.get("metadata", {}),
        "nearest_declared_candidates": nearest,
        "mentions": mentions,
        "evidence": evidence,
        "recommendations": recommendations,
        "proposed_next_action": {
            "action": next_action_for_classification(classification),
            "safe_to_auto_resolve": classification in {"compute_unit_instance_name", "naming_normalization_or_alias_gap"} and confidence == "high",
            "requires_validator_before_gap_update": True,
        },
    }


def next_action_for_classification(classification: str) -> str:
    mapping = {
        "summary_count_fallback": "Improve KernelGraphIR/ApplicationIR v2 name preservation before adding new matching rules.",
        "compute_unit_instance_name": "Add compute-unit-instance-to-base-kernel resolver using nk/sp/stream directives.",
        "naming_normalization_or_alias_gap": "Add deterministic alias table or stronger normalization rule with validator coverage.",
        "helper_or_wrapper_name_mismatch": "Classify HLS function role as top kernel/helper/wrapper before matching.",
        "connectivity_name_without_hls_top_function": "Trace connectivity name to build source reference and verify whether source file is missing or stale.",
        "name_extraction_pointer_gap": "Improve extraction of exact names from HLS InterfaceIR and ApplicationIR kernel graph.",
        "possible_false_positive_from_connectivity_parsing": "Tighten connectivity directive parser and require stronger evidence.",
        "insufficient_evidence": "Collect more source evidence before attempting resolution.",
    }
    return mapping.get(classification, "Review unresolved kernel evidence.")


def build_kernel_unresolved_diagnosis(
    case_id: str,
    kernel_resolution_report_path: str,
    app_ir_path: str,
    build_ir_path: str,
    connectivity_ir_path: str,
    hls_ir_path: str,
    out_path: str | None = None,
) -> dict[str, Any]:
    kernel_report = load_json(kernel_resolution_report_path)
    app_ir = load_json(app_ir_path)
    build_ir = load_json(build_ir_path)
    connectivity_ir = load_json(connectivity_ir_path)
    hls_ir = load_json(hls_ir_path)

    unresolved_configured = kernel_report.get("unresolved", {}).get("configured_kernels", [])
    declared = collect_declared_names(kernel_report, hls_ir, app_ir)

    objects = {
        "application_ir": app_ir,
        "build_ir": build_ir,
        "connectivity_ir": connectivity_ir,
        "hls_ir": hls_ir,
        "kernel_resolution_report": kernel_report,
    }

    diagnoses = [
        make_diagnosis_entry(item, declared, objects, i + 1)
        for i, item in enumerate(unresolved_configured)
    ]

    classification_counts: dict[str, int] = {}
    for d in diagnoses:
        c = d["classification"]
        classification_counts[c] = classification_counts.get(c, 0) + 1

    high_conf = [d for d in diagnoses if d["confidence"] == "high"]
    medium_conf = [d for d in diagnoses if d["confidence"] == "medium"]
    low_conf = [d for d in diagnoses if d["confidence"] == "low"]

    safe_auto = [d for d in diagnoses if d["proposed_next_action"]["safe_to_auto_resolve"]]
    must_remain_blocking = len(diagnoses) > len(safe_auto)

    report = {
        "schema_version": "kernel_name_unresolved_diagnosis.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "source_kernel_resolution_ref": {
            "path": kernel_resolution_report_path,
            "sha256": sha256_file(kernel_resolution_report_path),
            "schema_version": kernel_report.get("schema_version"),
            "resolution_state": kernel_report.get("resolution_state"),
        },
        "input_refs": {
            "application_ir": {
                "path": app_ir_path,
                "sha256": sha256_file(app_ir_path),
                "schema_version": app_ir.get("schema_version"),
            },
            "build_ir": {
                "path": build_ir_path,
                "sha256": sha256_file(build_ir_path),
                "schema_version": build_ir.get("schema_version"),
            },
            "connectivity_ir": {
                "path": connectivity_ir_path,
                "sha256": sha256_file(connectivity_ir_path),
                "schema_version": connectivity_ir.get("schema_version"),
            },
            "hls_ir": {
                "path": hls_ir_path,
                "sha256": sha256_file(hls_ir_path),
                "schema_version": hls_ir.get("schema_version"),
            },
        },
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "gap_state_changed": False,
            "contract_state_changed": False,
            "generator_unlock_allowed": False,
            "purpose": "Diagnose unresolved configured kernels from v0.0.19 without changing contracts or generation state.",
        },
        "diagnoses": diagnoses,
        "proposed_resolver_v2_tasks": build_resolver_v2_tasks(diagnoses),
        "gap_transition_proposal": {
            "gap_id": "GAP-KERNEL-NAME-001",
            "current_state": "remain_blocking",
            "proposed_state": "remain_blocking",
            "reason": (
                "Unresolved configured kernels remain and require resolver v2 improvements."
                if diagnoses else
                "No unresolved configured kernels remain, but contract update is still not performed in v0.0.20."
            ),
            "generator_unlock_allowed": False,
        },
        "summary": {
            "num_unresolved_configured": len(unresolved_configured),
            "num_diagnosed": len(diagnoses),
            "classification_counts": dict(sorted(classification_counts.items())),
            "num_high_confidence": len(high_conf),
            "num_medium_confidence": len(medium_conf),
            "num_low_confidence": len(low_conf),
            "num_safe_to_auto_resolve_candidates": len(safe_auto),
            "must_remain_blocking": must_remain_blocking,
            "generator_unlock_allowed": False,
            "output_report_path": out_path,
        },
        "traceability": {
            "kernel_resolution_summary": kernel_report.get("summary", {}),
            "application_ir_kernel_graph_summary": app_ir.get("kernel_graph", {}).get("summary", {}),
            "build_ir_summary": build_ir.get("summary", {}),
            "connectivity_ir_summary": connectivity_ir.get("summary", {}),
            "hls_ir_summary": hls_ir.get("summary", {}),
        },
        "llm_annotations": [],
    }

    return report


def build_resolver_v2_tasks(diagnoses: list[dict[str, Any]]) -> list[dict[str, Any]]:
    tasks_by_class: dict[str, dict[str, Any]] = {}

    for d in diagnoses:
        c = d["classification"]
        if c not in tasks_by_class:
            tasks_by_class[c] = {
                "task_id": f"KERNEL-RESOLVER-V2-{len(tasks_by_class) + 1:03d}",
                "classification": c,
                "title": title_for_classification(c),
                "description": next_action_for_classification(c),
                "affected_diagnosis_ids": [],
                "priority": priority_for_classification(c),
                "expected_output": expected_output_for_classification(c),
                "must_be_deterministic": True,
                "llm_allowed": False,
            }
        tasks_by_class[c]["affected_diagnosis_ids"].append(d["diagnosis_id"])

    return sorted(tasks_by_class.values(), key=lambda x: (x["priority"], x["task_id"]))


def title_for_classification(classification: str) -> str:
    mapping = {
        "summary_count_fallback": "Improve configured kernel name preservation",
        "compute_unit_instance_name": "Resolve compute-unit instance aliases",
        "naming_normalization_or_alias_gap": "Add deterministic alias-aware name normalization",
        "helper_or_wrapper_name_mismatch": "Classify helper/wrapper functions",
        "connectivity_name_without_hls_top_function": "Trace connectivity names to HLS top functions",
        "name_extraction_pointer_gap": "Improve exact HLS/ApplicationIR name extraction",
        "possible_false_positive_from_connectivity_parsing": "Tighten connectivity parser false positives",
        "insufficient_evidence": "Collect additional deterministic evidence",
    }
    return mapping.get(classification, "Resolve unidentified kernel-name issue")


def priority_for_classification(classification: str) -> int:
    mapping = {
        "summary_count_fallback": 10,
        "compute_unit_instance_name": 20,
        "naming_normalization_or_alias_gap": 30,
        "name_extraction_pointer_gap": 40,
        "helper_or_wrapper_name_mismatch": 50,
        "connectivity_name_without_hls_top_function": 60,
        "possible_false_positive_from_connectivity_parsing": 70,
        "insufficient_evidence": 80,
    }
    return mapping.get(classification, 100)


def expected_output_for_classification(classification: str) -> dict[str, str]:
    mapping = {
        "summary_count_fallback": {
            "schema": "kernel_graph_name_preservation_report.v1",
            "artifact": "ApplicationIR v2 kernel graph with explicit configured kernel names",
        },
        "compute_unit_instance_name": {
            "schema": "compute_unit_alias_resolution_report.v1",
            "artifact": "CU instance to base kernel alias table",
        },
        "naming_normalization_or_alias_gap": {
            "schema": "kernel_alias_table.v1",
            "artifact": "validated deterministic alias table",
        },
        "helper_or_wrapper_name_mismatch": {
            "schema": "hls_function_role_classification.v1",
            "artifact": "top/helper/wrapper classification report",
        },
        "connectivity_name_without_hls_top_function": {
            "schema": "connectivity_to_source_trace_report.v1",
            "artifact": "connectivity name to source file/function trace",
        },
        "name_extraction_pointer_gap": {
            "schema": "hls_name_extraction_improvement_report.v1",
            "artifact": "exact HLS/ApplicationIR name extraction report",
        },
        "possible_false_positive_from_connectivity_parsing": {
            "schema": "connectivity_false_positive_report.v1",
            "artifact": "tightened parser false-positive report",
        },
    }
    return mapping.get(classification, {
        "schema": "kernel_unresolved_followup_report.v1",
        "artifact": "follow-up diagnosis report",
    })


def main() -> int:
    parser = argparse.ArgumentParser(description="Diagnose unresolved configured kernels from v0.0.19")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--kernel-resolution-report", required=True)
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = build_kernel_unresolved_diagnosis(
        case_id=args.case_id,
        kernel_resolution_report_path=args.kernel_resolution_report,
        app_ir_path=args.app_ir,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
        hls_ir_path=args.hls_ir,
        out_path=args.out,
    )
    save_json(args.out, report)

    s = report["summary"]
    print(f"[xporthls] Kernel Unresolved Diagnosis report: {args.out}")
    print(f"[xporthls] Report schema: {report['schema_version']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Diagnosed: {s['num_diagnosed']}")
    print(f"[xporthls] Classification counts: {s['classification_counts']}")
    print(f"[xporthls] High confidence: {s['num_high_confidence']}")
    print(f"[xporthls] Medium confidence: {s['num_medium_confidence']}")
    print(f"[xporthls] Low confidence: {s['num_low_confidence']}")
    print(f"[xporthls] Safe auto-resolve candidates: {s['num_safe_to_auto_resolve_candidates']}")
    print(f"[xporthls] Must remain blocking: {s['must_remain_blocking']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Proposed v2 tasks: {len(report['proposed_resolver_v2_tasks'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/6] Add Kernel Unresolved Diagnosis validator"

cat > xporthls/realrepo/validate_kernel_unresolved_diagnosis_v020.py <<'EOT'
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
EOT

echo "[3/6] Add Kernel Unresolved Diagnosis orchestration runner"

cat > xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_unresolved_diagnosis_v020 import build_kernel_unresolved_diagnosis, save_json
from xporthls.realrepo.validate_kernel_unresolved_diagnosis_v020 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.20 Kernel Unresolved Diagnosis")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--kernel-resolution-report", required=True)
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    diagnosis_path = out_dir / f"{args.case_id}_kernel_unresolved_diagnosis_v020.json"
    validation_path = out_dir / f"{args.case_id}_kernel_unresolved_diagnosis_validation_v020.json"

    diagnosis = build_kernel_unresolved_diagnosis(
        case_id=args.case_id,
        kernel_resolution_report_path=args.kernel_resolution_report,
        app_ir_path=args.app_ir,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
        hls_ir_path=args.hls_ir,
        out_path=str(diagnosis_path),
    )
    save_json(diagnosis_path, diagnosis)

    validation = validate(diagnosis)
    validation.save(validation_path)

    s = diagnosis["summary"]
    print(f"[xporthls] Kernel Unresolved Diagnosis: {diagnosis_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Report schema: {diagnosis['schema_version']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Diagnosed: {s['num_diagnosed']}")
    print(f"[xporthls] Classification counts: {s['classification_counts']}")
    print(f"[xporthls] High confidence: {s['num_high_confidence']}")
    print(f"[xporthls] Medium confidence: {s['num_medium_confidence']}")
    print(f"[xporthls] Low confidence: {s['num_low_confidence']}")
    print(f"[xporthls] Safe auto-resolve candidates: {s['num_safe_to_auto_resolve_candidates']}")
    print(f"[xporthls] Must remain blocking: {s['must_remain_blocking']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Proposed v2 tasks: {len(diagnosis['proposed_resolver_v2_tasks'])}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README with Kernel Unresolved Diagnosis usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Kernel unresolved diagnosis

XPortHLS can diagnose unresolved configured kernels left by the deterministic Kernel Name Resolver. The diagnosis classifies each unresolved configured kernel into causes such as compute-unit instance names, alias/normalization gaps, helper/wrapper mismatches, missing HLS top functions, extraction pointer gaps, parser false positives, or insufficient evidence.

Example:

```bash
python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \\
  --case-id hisparse_u280_profile \\
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \\
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \\
  --build-ir experiments/runs/hisparse_build_ir_v012.json \\
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \\
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \\
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json
experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json
```

The v0.0.20 diagnosis is deterministic and profile-only. It does not update the gap contract and does not unlock generation.
"""

if "## Kernel unresolved diagnosis" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.20 replay script"

cat > add_kernel_unresolved_diagnosis_v020_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"
DIAGNOSIS="experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json"
DIAGNOSIS_VALIDATION="experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json"

echo "[v0.0.20] Python syntax check"

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
  xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py

echo "[v0.0.20] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.20] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.20] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.20] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.20] Run Kernel Unresolved Diagnosis"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

python3 -m xporthls.realrepo.validate_kernel_unresolved_diagnosis_v020 \
  --diagnosis "$DIAGNOSIS" \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --out "$DIAGNOSIS_VALIDATION"

echo "[v0.0.20] Re-run generator guard to prove generation is still blocked"

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

kernel = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"))
diagnosis = json.load(open("experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_validation_v020.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

ks = kernel["summary"]
ds = diagnosis["summary"]

print()
print("Kernel resolution state:", kernel["resolution_state"])
print("Kernel unresolved configured:", ks["num_unresolved_configured"])
print("Diagnosis schema:", diagnosis["schema_version"])
print("Diagnosed unresolved:", ds["num_diagnosed"])
print("Classification counts:", ds["classification_counts"])
print("High confidence:", ds["num_high_confidence"])
print("Medium confidence:", ds["num_medium_confidence"])
print("Low confidence:", ds["num_low_confidence"])
print("Safe auto-resolve candidates:", ds["num_safe_to_auto_resolve_candidates"])
print("Must remain blocking:", ds["must_remain_blocking"])
print("Generator unlock allowed:", ds["generator_unlock_allowed"])
print("Proposed v2 tasks:", len(diagnosis["proposed_resolver_v2_tasks"]))
print("Diagnosis validation status:", validation["status"])
print("Guard blocked after diagnosis:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert diagnosis["schema_version"] == "kernel_name_unresolved_diagnosis.v1"
assert diagnosis["source_kernel_resolution_ref"]["schema_version"] == "kernel_name_resolution_report.v1"
assert diagnosis["policy"]["deterministic_only"] is True
assert diagnosis["policy"]["llm_used"] is False
assert diagnosis["policy"]["gap_state_changed"] is False
assert diagnosis["policy"]["contract_state_changed"] is False
assert diagnosis["policy"]["generator_unlock_allowed"] is False
assert ds["num_unresolved_configured"] == ks["num_unresolved_configured"]
assert ds["num_diagnosed"] == ks["num_unresolved_configured"]
assert len(diagnosis["diagnoses"]) == ks["num_unresolved_configured"]
assert diagnosis["gap_transition_proposal"]["proposed_state"] == "remain_blocking"
assert ds["generator_unlock_allowed"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
EOT

chmod +x add_kernel_unresolved_diagnosis_v020_replay.sh

echo "[6/6] Run v0.0.20 replay"

./add_kernel_unresolved_diagnosis_v020_replay.sh

echo "[v0.0.20] Git status"

git status
