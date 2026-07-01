#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add Kernel Name Resolver v1"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/kernel_name_resolver_v019.py <<'EOT'
from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


NAME_KEYS = {
    "name",
    "kernel",
    "kernel_name",
    "function",
    "function_name",
    "hls_function",
    "compute_unit",
    "cu",
    "instance",
    "instance_name",
    "symbol",
}

BAD_NAME_TOKENS = {
    "",
    "read",
    "write",
    "true",
    "false",
    "none",
    "null",
    "ddr",
    "hbm",
    "axis",
    "m_axi",
    "s_axilite",
    "ap_ctrl_none",
    "ap_ctrl_hs",
}


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


def pointer_join(path: str, key: str | int) -> str:
    if isinstance(key, int):
        return f"{path}/{key}"
    safe = str(key).replace("~", "~0").replace("/", "~1")
    return f"{path}/{safe}"


def flatten_path(path: str) -> str:
    return path.lower().replace("/", " ").replace("_", " ").replace("-", " ")


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
    n = n.lower()

    # Connectivity often uses instance suffixes. Keep a base form for matching.
    n = re.sub(r"_(?:cu|inst|kernel)?\d+$", "", n)
    n = re.sub(r"\d+$", "", n) if len(n) > 4 else n

    return n


def relaxed_name(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", normalize_name(name))


def valid_candidate_name(name: str) -> bool:
    if name is None:
        return False

    raw = str(name).strip()
    if not raw:
        return False
    if len(raw) > 160:
        return False
    if "\n" in raw:
        return False

    n = normalize_name(raw)
    if not n or n in BAD_NAME_TOKENS:
        return False
    if len(n) < 2:
        return False
    if re.fullmatch(r"\d+", n):
        return False
    if re.fullmatch(r"hbm\d+|ddr\d+|bank\d+|s\d+|m\d+", n):
        return False

    return True


def candidate_record(kind: str, name: str, source: str, pointer: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "kind": kind,
        "raw_name": str(name),
        "normalized": normalize_name(str(name)),
        "relaxed": relaxed_name(str(name)),
        "source": source,
        "pointer": pointer,
        "metadata": metadata or {},
    }


def add_unique(items: list[dict[str, Any]], seen: set[tuple[str, str, str]], item: dict[str, Any]) -> None:
    key = (item["kind"], item["normalized"], item.get("pointer", ""))
    if key in seen:
        return
    seen.add(key)
    items.append(item)


def parse_connectivity_directive(text: str) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    s = str(text)

    # nk=kernel:count[:cu_1.cu_2]
    for m in re.finditer(r"\bnk\s*=\s*([A-Za-z_][A-Za-z0-9_]*)", s):
        out.append(("nk_kernel", m.group(1)))

    # sp=kernel.port:HBM[0] or sp=cu.port:DDR[0]
    for m in re.finditer(r"\bsp\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\.", s):
        out.append(("sp_kernel_or_cu", m.group(1)))

    # stream_connect=kernel1.port:kernel2.port
    for m in re.finditer(r"\bstream_connect\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\.", s):
        out.append(("stream_source_kernel_or_cu", m.group(1)))
        out.append(("stream_target_kernel_or_cu", m.group(3)))

    # kernel instances may appear as foo_1.bar or foo_2.bar in connectivity.
    for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*_\d+)\.", s):
        out.append(("instance_prefix", m.group(1)))

    return out


def recursive_collect(obj: Any, path: str = "", source: str = "application_ir") -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    configured: list[dict[str, Any]] = []
    declared: list[dict[str, Any]] = []
    seen_configured: set[tuple[str, str, str]] = set()
    seen_declared: set[tuple[str, str, str]] = set()

    def walk(node: Any, p: str) -> None:
        pflat = flatten_path(p)

        if isinstance(node, dict):
            # Prefer explicit dict names.
            for k, v in node.items():
                k_lower = str(k).lower()
                child_path = pointer_join(p, k)

                if isinstance(v, str):
                    if k_lower in NAME_KEYS and valid_candidate_name(v):
                        item_kind = "generic_name"
                        metadata = {"key": k}

                        if any(tok in pflat for tok in ["configured", "connectivity", "compute unit", "compute_unit", "nk", "sp", "stream"]):
                            add_unique(configured, seen_configured, candidate_record("configured_kernel", v, source, child_path, metadata))
                        if any(tok in pflat for tok in ["declared", "hls", "function", "candidate", "kernel graph"]):
                            add_unique(declared, seen_declared, candidate_record("declared_function", v, source, child_path, metadata))

                    # Parse raw connectivity directives.
                    if any(tok in pflat or tok in k_lower for tok in ["directive", "connectivity", "raw", "line", "command", "config"]):
                        for kind, name in parse_connectivity_directive(v):
                            if valid_candidate_name(name):
                                add_unique(
                                    configured,
                                    seen_configured,
                                    candidate_record(
                                        "configured_kernel",
                                        name,
                                        source,
                                        child_path,
                                        {"parsed_from": kind, "raw": v[:240]},
                                    ),
                                )

                    # Parse Vitis commands with kernel names, when present.
                    if "v++" in v or "vpp" in pflat or "command" in k_lower:
                        for m in re.finditer(r"(?:--kernel|--hls\.kernel|kernel=)\s+([A-Za-z_][A-Za-z0-9_]*)", v):
                            name = m.group(1)
                            if valid_candidate_name(name):
                                add_unique(
                                    declared,
                                    seen_declared,
                                    candidate_record(
                                        "declared_function",
                                        name,
                                        source,
                                        child_path,
                                        {"parsed_from": "vitis_command", "raw": v[:240]},
                                    ),
                                )

                walk(v, child_path)

        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(value, pointer_join(p, i))

        elif isinstance(node, str):
            if any(tok in pflat for tok in ["directive", "connectivity", "nk", "sp", "stream", "config"]):
                for kind, name in parse_connectivity_directive(node):
                    if valid_candidate_name(name):
                        add_unique(
                            configured,
                            seen_configured,
                            candidate_record(
                                "configured_kernel",
                                name,
                                source,
                                p,
                                {"parsed_from": kind, "raw": node[:240]},
                            ),
                        )

    walk(obj, path or "")
    return configured, declared


def collect_from_explicit_kernel_graph(app: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    kg = app.get("kernel_graph", {})
    configured: list[dict[str, Any]] = []
    declared: list[dict[str, Any]] = []
    seen_c: set[tuple[str, str, str]] = set()
    seen_d: set[tuple[str, str, str]] = set()

    configured_paths = [
        ("configured_kernels", "/kernel_graph/configured_kernels"),
        ("configured_kernel_names", "/kernel_graph/configured_kernel_names"),
        ("configured_compute_units", "/kernel_graph/configured_compute_units"),
        ("configured_without_declared", "/kernel_graph/configured_without_declared"),
        ("unmatched_configured", "/kernel_graph/unmatched_configured"),
    ]

    declared_paths = [
        ("declared_kernels", "/kernel_graph/declared_kernels"),
        ("declared_functions", "/kernel_graph/declared_functions"),
        ("hls_kernel_candidates", "/kernel_graph/hls_kernel_candidates"),
        ("declared_without_config", "/kernel_graph/declared_without_config"),
        ("unmatched_declared", "/kernel_graph/unmatched_declared"),
    ]

    def pull_name(item: Any) -> str | None:
        if isinstance(item, str):
            return item
        if isinstance(item, dict):
            for key in ["name", "kernel", "kernel_name", "function", "function_name", "hls_function", "compute_unit", "instance", "symbol"]:
                value = item.get(key)
                if isinstance(value, str) and valid_candidate_name(value):
                    return value
            # Some records may store nested endpoint names.
            for value in item.values():
                if isinstance(value, str) and valid_candidate_name(value):
                    return value
        return None

    for key, base in configured_paths:
        value = kg.get(key)
        if isinstance(value, list):
            for i, item in enumerate(value):
                name = pull_name(item)
                if name and valid_candidate_name(name):
                    add_unique(
                        configured,
                        seen_c,
                        candidate_record(
                            "configured_kernel",
                            name,
                            "kernel_graph",
                            f"{base}/{i}",
                            {"explicit_field": key, "record": item if isinstance(item, dict) else None},
                        ),
                    )

    for key, base in declared_paths:
        value = kg.get(key)
        if isinstance(value, list):
            for i, item in enumerate(value):
                name = pull_name(item)
                if name and valid_candidate_name(name):
                    add_unique(
                        declared,
                        seen_d,
                        candidate_record(
                            "declared_function",
                            name,
                            "kernel_graph",
                            f"{base}/{i}",
                            {"explicit_field": key, "record": item if isinstance(item, dict) else None},
                        ),
                    )

    # Some kernel graph builders use "nodes".
    nodes = kg.get("nodes")
    if isinstance(nodes, list):
        for i, node in enumerate(nodes):
            if not isinstance(node, dict):
                continue
            name = pull_name(node)
            if not name:
                continue
            role = " ".join(str(node.get(k, "")).lower() for k in ["role", "kind", "node_kind", "source", "origin"])
            if "config" in role or "connect" in role or "compute" in role:
                add_unique(configured, seen_c, candidate_record("configured_kernel", name, "kernel_graph", f"/kernel_graph/nodes/{i}", {"node": node}))
            if "declared" in role or "hls" in role or "function" in role or "candidate" in role:
                add_unique(declared, seen_d, candidate_record("declared_function", name, "kernel_graph", f"/kernel_graph/nodes/{i}", {"node": node}))

    return configured, declared


def first_int(obj: Any, wanted_keys: list[str]) -> int | None:
    wanted = {k.lower() for k in wanted_keys}

    def walk(node: Any) -> int | None:
        if isinstance(node, dict):
            for k, v in node.items():
                if str(k).lower() in wanted and isinstance(v, int):
                    return v
            for v in node.values():
                found = walk(v)
                if found is not None:
                    return found
        elif isinstance(node, list):
            for v in node:
                found = walk(v)
                if found is not None:
                    return found
        return None

    return walk(obj)


def unique_by_normalized(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    best: dict[str, dict[str, Any]] = {}
    for item in items:
        norm = item.get("normalized")
        if not norm:
            continue
        # Prefer non-synthetic, explicit kernel graph entries.
        if norm not in best:
            best[norm] = item
            continue
        old = best[norm]
        old_score = (old.get("metadata", {}).get("synthetic") is not True, old.get("source") == "kernel_graph")
        new_score = (item.get("metadata", {}).get("synthetic") is not True, item.get("source") == "kernel_graph")
        if new_score > old_score:
            best[norm] = item
    return sorted(best.values(), key=lambda x: x["normalized"])


def synthesize_missing(items: list[dict[str, Any]], expected_count: int | None, kind: str, label: str) -> list[dict[str, Any]]:
    unique = unique_by_normalized(items)
    if expected_count is None or expected_count <= len(unique):
        return unique

    out = list(unique)
    for i in range(expected_count - len(unique)):
        name = f"__{label}_unextracted_{i + 1}"
        out.append({
            "kind": kind,
            "raw_name": name,
            "normalized": normalize_name(name),
            "relaxed": relaxed_name(name),
            "source": "summary_count_fallback",
            "pointer": f"/summary/{label}_fallback/{i}",
            "metadata": {
                "synthetic": True,
                "reason": "ApplicationIR summary reported more kernels than the conservative name extractor could recover.",
            },
        })
    return out


def score_match(configured: dict[str, Any], declared: dict[str, Any]) -> tuple[float, str, list[str]]:
    c = configured["normalized"]
    d = declared["normalized"]
    cr = configured["relaxed"]
    dr = declared["relaxed"]

    reasons: list[str] = []

    if c == d and not configured.get("metadata", {}).get("synthetic") and not declared.get("metadata", {}).get("synthetic"):
        return 1.0, "exact_normalized", ["normalized names are identical"]

    if cr == dr and cr:
        return 0.95, "exact_relaxed", ["relaxed names are identical"]

    # Connectivity often has instance names while HLS has the base kernel/function name.
    if c.startswith(d) or d.startswith(c):
        shorter = min(len(c), len(d))
        longer = max(len(c), len(d))
        if shorter >= 3:
            score = max(0.70, min(0.90, shorter / max(longer, 1)))
            reasons.append("one normalized name is a prefix of the other")
            return score, "prefix_normalized", reasons

    # Token overlap for names such as spmv_cluster_1 vs spmv_cluster.
    c_tokens = {t for t in c.split("_") if t}
    d_tokens = {t for t in d.split("_") if t}
    if c_tokens and d_tokens:
        inter = c_tokens & d_tokens
        union = c_tokens | d_tokens
        j = len(inter) / max(len(union), 1)
        if j >= 0.5:
            return max(0.55, min(0.85, j)), "token_overlap", [f"token overlap={j:.2f}"]

    return 0.0, "no_match", []


def greedy_match(configured: list[dict[str, Any]], declared: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    configured_unique = unique_by_normalized(configured)
    declared_unique = unique_by_normalized(declared)

    candidates: list[dict[str, Any]] = []
    for c in configured_unique:
        for d in declared_unique:
            score, method, reasons = score_match(c, d)
            if score >= 0.55:
                candidates.append({
                    "configured": c,
                    "declared": d,
                    "score": round(score, 4),
                    "method": method,
                    "reasons": reasons,
                })

    candidates.sort(key=lambda x: (-x["score"], x["configured"]["normalized"], x["declared"]["normalized"]))

    used_c: set[str] = set()
    used_d: set[str] = set()
    matches: list[dict[str, Any]] = []

    for candidate in candidates:
        c_norm = candidate["configured"]["normalized"]
        d_norm = candidate["declared"]["normalized"]
        if c_norm in used_c or d_norm in used_d:
            continue
        used_c.add(c_norm)
        used_d.add(d_norm)
        matches.append(candidate)

    unresolved_configured = [c for c in configured_unique if c["normalized"] not in used_c]
    unresolved_declared = [d for d in declared_unique if d["normalized"] not in used_d]

    return matches, unresolved_configured, unresolved_declared


def extract_inputs(app: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    kg = app.get("kernel_graph", {})
    kg_summary = kg.get("summary", {})
    app_summary = app.get("summary", {})

    explicit_c, explicit_d = collect_from_explicit_kernel_graph(app)
    recursive_c, recursive_d = recursive_collect(app, "", "application_ir")

    configured = explicit_c + recursive_c
    declared = explicit_d + recursive_d

    configured_expected = (
        first_int(kg_summary, ["num_configured_kernels", "configured_kernels", "num_configured"])
        or first_int(app_summary, ["num_configured_kernels", "configured_kernels", "num_configured"])
    )

    declared_expected = (
        first_int(kg_summary, ["num_declared_kernels", "declared_kernels", "num_declared"])
        or first_int(app_summary, ["num_declared_kernels", "declared_kernels", "num_declared"])
        or first_int(app_summary, ["num_hls_kernel_candidates"])
    )

    configured = synthesize_missing(configured, configured_expected, "configured_kernel", "configured_kernel")
    declared = synthesize_missing(declared, declared_expected, "declared_function", "declared_function")

    extraction_summary = {
        "configured_expected_count": configured_expected,
        "declared_expected_count": declared_expected,
        "configured_extracted_unique": len(unique_by_normalized(configured)),
        "declared_extracted_unique": len(unique_by_normalized(declared)),
        "configured_synthetic_count": len([x for x in configured if x.get("metadata", {}).get("synthetic")]),
        "declared_synthetic_count": len([x for x in declared if x.get("metadata", {}).get("synthetic")]),
    }

    return configured, declared, extraction_summary


def find_resolver_entry(plan: dict[str, Any], gap_id: str) -> dict[str, Any] | None:
    for resolver in plan.get("resolvers", []):
        if resolver.get("gap_id") == gap_id:
            return resolver
    return None


def build_kernel_name_resolution_report(
    case_id: str,
    app_ir_path: str,
    gap_contract_path: str,
    resolver_plan_path: str,
    out_path: str | None = None,
) -> dict[str, Any]:
    app = load_json(app_ir_path)
    contract = load_json(gap_contract_path)
    plan = load_json(resolver_plan_path)

    gap_id = "GAP-KERNEL-NAME-001"
    resolver = find_resolver_entry(plan, gap_id)

    configured, declared, extraction_summary = extract_inputs(app)
    matches, unresolved_configured, unresolved_declared = greedy_match(configured, declared)

    configured_unique = unique_by_normalized(configured)
    declared_unique = unique_by_normalized(declared)

    total_configured = len(configured_unique)
    total_declared = len(declared_unique)
    num_matches = len(matches)
    num_unresolved_configured = len(unresolved_configured)
    num_unresolved_declared = len(unresolved_declared)

    if total_configured == 0 or total_declared == 0:
        resolution_state = "insufficient_evidence"
    elif num_unresolved_configured == 0:
        resolution_state = "resolved_pending_validation"
    elif num_matches > 0:
        resolution_state = "partial"
    else:
        resolution_state = "unresolved"

    gap_transition_proposal = {
        "gap_id": gap_id,
        "current_gap_contract_state": contract.get("contract_state"),
        "proposed_gap_state": (
            "resolved_pending_contract_update"
            if resolution_state == "resolved_pending_validation"
            else "remain_blocking"
        ),
        "generator_unlock_allowed": False,
        "reason": (
            "All configured kernels have deterministic declared-function matches, but v0.0.19 still requires explicit validator/contract update before changing generation state."
            if resolution_state == "resolved_pending_validation"
            else "Some configured kernels remain unresolved or only partially resolved; GAP-KERNEL-NAME-001 must remain blocking."
        ),
    }

    report = {
        "schema_version": "kernel_name_resolution_report.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "resolver_id": "RESOLVE-GAP-KERNEL-NAME-001",
        "gap_id": gap_id,
        "resolution_state": resolution_state,
        "migration_status": "profile_only",
        "source_refs": {
            "application_ir": {
                "path": app_ir_path,
                "sha256": sha256_file(app_ir_path),
                "schema_version": app.get("schema_version"),
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
        "resolver_plan_entry": resolver,
        "policy": {
            "deterministic_only": True,
            "llm_used": False,
            "gap_state_changed": False,
            "contract_state_changed": False,
            "generation_allowed": False,
            "notes": [
                "v0.0.19 executes a deterministic name-resolution analysis only.",
                "It does not modify the gap contract.",
                "It does not allow target project generation.",
            ],
        },
        "inputs": {
            "configured_kernels": configured_unique,
            "declared_functions": declared_unique,
            "extraction_summary": extraction_summary,
        },
        "matches": matches,
        "unresolved": {
            "configured_kernels": unresolved_configured,
            "declared_functions": unresolved_declared,
        },
        "gap_transition_proposal": gap_transition_proposal,
        "summary": {
            "num_configured_kernels": total_configured,
            "num_declared_functions": total_declared,
            "num_matches": num_matches,
            "num_unresolved_configured": num_unresolved_configured,
            "num_unresolved_declared": num_unresolved_declared,
            "resolution_state": resolution_state,
            "match_methods": dict(sorted(defaultdict(int, {m["method"]: 0 for m in matches}).items())),
            "matched_configured_names": [m["configured"]["raw_name"] for m in matches],
            "unresolved_configured_names": [c["raw_name"] for c in unresolved_configured],
            "generator_unlock_allowed": False,
            "output_report_path": out_path,
        },
        "traceability": {
            "application_ir_kernel_graph_summary": app.get("kernel_graph", {}).get("summary", {}),
            "application_ir_summary": app.get("summary", {}),
            "contract_gap_summary": contract.get("summary", {}),
            "resolver_plan_summary": plan.get("summary", {}),
        },
        "llm_annotations": [],
    }

    # Fill match method counts after report construction.
    method_counts: dict[str, int] = {}
    for m in matches:
        method_counts[m["method"]] = method_counts.get(m["method"], 0) + 1
    report["summary"]["match_methods"] = dict(sorted(method_counts.items()))

    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Kernel Name Resolver v1")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = build_kernel_name_resolution_report(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=args.out,
    )

    save_json(args.out, report)

    s = report["summary"]
    print(f"[xporthls] Kernel Name Resolution report: {args.out}")
    print(f"[xporthls] Report schema: {report['schema_version']}")
    print(f"[xporthls] Resolution state: {report['resolution_state']}")
    print(f"[xporthls] Configured kernels: {s['num_configured_kernels']}")
    print(f"[xporthls] Declared functions: {s['num_declared_functions']}")
    print(f"[xporthls] Matches: {s['num_matches']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Unresolved declared: {s['num_unresolved_declared']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Proposed gap state: {report['gap_transition_proposal']['proposed_gap_state']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/6] Add Kernel Name Resolver validator"

cat > xporthls/realrepo/validate_kernel_name_resolution_v019.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class KernelNameResolutionIssue:
    severity: str
    code: str
    message: str


@dataclass
class KernelNameResolutionValidationReport:
    status: str
    issues: list[KernelNameResolutionIssue] = field(default_factory=list)
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


def add_issue(issues: list[KernelNameResolutionIssue], severity: str, code: str, message: str) -> None:
    issues.append(KernelNameResolutionIssue(severity=severity, code=code, message=message))


def validate_match_shape(match: dict[str, Any], issues: list[KernelNameResolutionIssue]) -> None:
    for key in ["configured", "declared", "score", "method", "reasons"]:
        if key not in match:
            add_issue(issues, "error", "MATCH_FIELD_MISSING", f"Match record missing field: {key}")

    score = match.get("score")
    if not isinstance(score, (int, float)) or score < 0 or score > 1:
        add_issue(issues, "error", "MATCH_SCORE_INVALID", f"Match score must be between 0 and 1, got {score!r}")

    for side in ["configured", "declared"]:
        item = match.get(side, {})
        for key in ["raw_name", "normalized", "relaxed", "source", "pointer"]:
            if key not in item:
                add_issue(issues, "error", "MATCH_SIDE_FIELD_MISSING", f"Match {side} record missing field: {key}")


def validate(report: dict[str, Any]) -> KernelNameResolutionValidationReport:
    issues: list[KernelNameResolutionIssue] = []

    if report.get("schema_version") != "kernel_name_resolution_report.v1":
        add_issue(issues, "error", "REPORT_SCHEMA", "Expected kernel_name_resolution_report.v1.")

    if report.get("gap_id") != "GAP-KERNEL-NAME-001":
        add_issue(issues, "error", "GAP_ID", "Kernel resolver must target GAP-KERNEL-NAME-001.")

    if report.get("resolver_id") != "RESOLVE-GAP-KERNEL-NAME-001":
        add_issue(issues, "error", "RESOLVER_ID", "Kernel resolver must use RESOLVE-GAP-KERNEL-NAME-001.")

    if report.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.19 must remain profile_only.")

    if report.get("resolution_state") not in {"resolved_pending_validation", "partial", "unresolved", "insufficient_evidence"}:
        add_issue(issues, "error", "RESOLUTION_STATE", f"Unexpected resolution_state: {report.get('resolution_state')!r}")

    refs = report.get("source_refs", {})
    if refs.get("application_ir", {}).get("schema_version") != "application_ir.v2":
        add_issue(issues, "error", "APP_IR_SCHEMA_REF", "Kernel resolver must reference application_ir.v2.")

    if refs.get("gap_contract", {}).get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "GAP_CONTRACT_SCHEMA_REF", "Kernel resolver must reference source_to_target_gap_contract.v1.")

    if refs.get("gap_resolver_plan", {}).get("schema_version") != "gap_resolver_plan.v1":
        add_issue(issues, "error", "RESOLVER_PLAN_SCHEMA_REF", "Kernel resolver must reference gap_resolver_plan.v1.")

    policy = report.get("policy", {})
    if policy.get("deterministic_only") is not True:
        add_issue(issues, "error", "POLICY_NOT_DETERMINISTIC", "Kernel resolver must be deterministic_only.")
    if policy.get("llm_used") is not False:
        add_issue(issues, "error", "LLM_USED", "v0.0.19 resolver must not use LLM.")
    if policy.get("gap_state_changed") is not False:
        add_issue(issues, "error", "GAP_STATE_CHANGED", "v0.0.19 must not change gap state.")
    if policy.get("contract_state_changed") is not False:
        add_issue(issues, "error", "CONTRACT_STATE_CHANGED", "v0.0.19 must not change contract state.")
    if policy.get("generation_allowed") is not False:
        add_issue(issues, "error", "GENERATION_ALLOWED", "v0.0.19 must not allow generation.")

    summary = report.get("summary", {})
    inputs = report.get("inputs", {})
    configured = inputs.get("configured_kernels", [])
    declared = inputs.get("declared_functions", [])
    matches = report.get("matches", [])
    unresolved = report.get("unresolved", {})
    unresolved_configured = unresolved.get("configured_kernels", [])
    unresolved_declared = unresolved.get("declared_functions", [])

    if int(summary.get("num_configured_kernels") or -1) != len(configured):
        add_issue(issues, "error", "CONFIGURED_COUNT_MISMATCH", "summary.num_configured_kernels mismatch.")

    if int(summary.get("num_declared_functions") or -1) != len(declared):
        add_issue(issues, "error", "DECLARED_COUNT_MISMATCH", "summary.num_declared_functions mismatch.")

    if int(summary.get("num_matches") or -1) != len(matches):
        add_issue(issues, "error", "MATCH_COUNT_MISMATCH", "summary.num_matches mismatch.")

    if int(summary.get("num_unresolved_configured") or -1) != len(unresolved_configured):
        add_issue(issues, "error", "UNRESOLVED_CONFIGURED_COUNT_MISMATCH", "summary.num_unresolved_configured mismatch.")

    if int(summary.get("num_unresolved_declared") or -1) != len(unresolved_declared):
        add_issue(issues, "error", "UNRESOLVED_DECLARED_COUNT_MISMATCH", "summary.num_unresolved_declared mismatch.")

    if len(matches) + len(unresolved_configured) != len(configured):
        add_issue(issues, "error", "CONFIGURED_PARTITION_MISMATCH", "matches + unresolved configured must partition configured kernels.")

    if len(matches) + len(unresolved_declared) > len(declared):
        add_issue(issues, "error", "DECLARED_PARTITION_OVERFLOW", "matches + unresolved declared cannot exceed declared functions.")

    for match in matches:
        validate_match_shape(match, issues)

    if not configured:
        add_issue(issues, "error", "NO_CONFIGURED_KERNELS", "Kernel resolver found no configured kernels.")

    if not declared:
        add_issue(issues, "error", "NO_DECLARED_FUNCTIONS", "Kernel resolver found no declared functions.")

    extraction = inputs.get("extraction_summary", {})
    if int(extraction.get("configured_synthetic_count") or 0) > 0:
        add_issue(
            issues,
            "warning",
            "CONFIGURED_SYNTHETIC_FALLBACK_USED",
            "Some configured kernels were synthesized from summary counts because names were not fully recoverable.",
        )

    if int(extraction.get("declared_synthetic_count") or 0) > 0:
        add_issue(
            issues,
            "warning",
            "DECLARED_SYNTHETIC_FALLBACK_USED",
            "Some declared functions were synthesized from summary counts because names were not fully recoverable.",
        )

    transition = report.get("gap_transition_proposal", {})
    if transition.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK_PROPOSED", "v0.0.19 must not unlock generator.")

    if transition.get("proposed_gap_state") not in {"remain_blocking", "resolved_pending_contract_update"}:
        add_issue(issues, "error", "PROPOSED_GAP_STATE_INVALID", f"Unexpected proposed gap state: {transition.get('proposed_gap_state')!r}")

    if report.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Kernel resolver report must not contain LLM annotations.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return KernelNameResolutionValidationReport(
        status=status,
        issues=issues,
        summary={
            "case_id": report.get("case_id"),
            "schema_version": report.get("schema_version"),
            "resolver_id": report.get("resolver_id"),
            "gap_id": report.get("gap_id"),
            "resolution_state": report.get("resolution_state"),
            "migration_status": report.get("migration_status"),
            "num_configured_kernels": summary.get("num_configured_kernels"),
            "num_declared_functions": summary.get("num_declared_functions"),
            "num_matches": summary.get("num_matches"),
            "num_unresolved_configured": summary.get("num_unresolved_configured"),
            "num_unresolved_declared": summary.get("num_unresolved_declared"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "proposed_gap_state": transition.get("proposed_gap_state"),
            "match_methods": summary.get("match_methods"),
            "configured_synthetic_count": extraction.get("configured_synthetic_count"),
            "declared_synthetic_count": extraction.get("declared_synthetic_count"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Kernel Name Resolution report v0.0.19")
    parser.add_argument("--report", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = load_json(args.report)
    validation = validate(report)
    validation.save(args.out)

    print(f"[xporthls] Kernel Name Resolution validation written to: {args.out}")
    print(f"[xporthls] Kernel Name Resolution validation status: {validation.status}")

    for issue in validation.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/6] Add Kernel Name Resolver orchestration runner"

cat > xporthls/realrepo/run_kernel_name_resolution_v019.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_name_resolver_v019 import build_kernel_name_resolution_report, save_json
from xporthls.realrepo.validate_kernel_name_resolution_v019 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.19 Kernel Name Resolver")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    report_path = out_dir / f"{args.case_id}_kernel_name_resolution_report_v019.json"
    validation_path = out_dir / f"{args.case_id}_kernel_name_resolution_validation_v019.json"

    report = build_kernel_name_resolution_report(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=str(report_path),
    )
    save_json(report_path, report)

    validation = validate(report)
    validation.save(validation_path)

    s = report["summary"]
    print(f"[xporthls] Kernel Name Resolution report: {report_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Resolution state: {report['resolution_state']}")
    print(f"[xporthls] Configured kernels: {s['num_configured_kernels']}")
    print(f"[xporthls] Declared functions: {s['num_declared_functions']}")
    print(f"[xporthls] Matches: {s['num_matches']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Unresolved declared: {s['num_unresolved_declared']}")
    print(f"[xporthls] Match methods: {s['match_methods']}")
    print(f"[xporthls] Proposed gap state: {report['gap_transition_proposal']['proposed_gap_state']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README with Kernel Name Resolver usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Kernel name resolver

XPortHLS includes a deterministic Kernel Name Resolver for the first blocking resolver in the HiSparse gap resolver plan. It maps configured kernels and compute units from connectivity/build facts to declared HLS functions from ApplicationIR v2.

Example:

```bash
python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \\
  --case-id hisparse_u280_profile \\
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \\
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \\
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \\
  --out-dir experiments/runs
```

The resolver writes:

```text
experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json
experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json
```

The v0.0.19 resolver is deterministic and profile-only. It does not modify the gap contract and does not unlock generation.
"""

if "## Kernel name resolver" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.19 replay script"

cat > add_kernel_name_resolver_v019_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

KERNEL_REPORT="experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"
KERNEL_VALIDATION="experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"
REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"

echo "[v0.0.19] Python syntax check"

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
  xporthls/realrepo/run_kernel_name_resolution_v019.py

echo "[v0.0.19] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.19] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.19] Re-run v0.0.18 gap resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.19] Run Kernel Name Resolver"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.19] Re-run generator guard to prove generation is still blocked"

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

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
plan = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"))
kernel = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_kernel_name_resolution_validation_v019.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))

summary = kernel["summary"]

print()
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Resolver plan state:", plan["plan_state"])
print("Kernel report schema:", kernel["schema_version"])
print("Kernel resolver ID:", kernel["resolver_id"])
print("Kernel resolution state:", kernel["resolution_state"])
print("Configured kernels:", summary["num_configured_kernels"])
print("Declared functions:", summary["num_declared_functions"])
print("Matches:", summary["num_matches"])
print("Unresolved configured:", summary["num_unresolved_configured"])
print("Unresolved declared:", summary["num_unresolved_declared"])
print("Match methods:", summary["match_methods"])
print("Proposed gap state:", kernel["gap_transition_proposal"]["proposed_gap_state"])
print("Generator unlock allowed:", summary["generator_unlock_allowed"])
print("Kernel validation status:", validation["status"])
print("Guard blocked after resolver:", guard["decision"]["blocked"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists())

assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert plan["schema_version"] == "gap_resolver_plan.v1"
assert kernel["schema_version"] == "kernel_name_resolution_report.v1"
assert kernel["gap_id"] == "GAP-KERNEL-NAME-001"
assert kernel["resolver_id"] == "RESOLVE-GAP-KERNEL-NAME-001"
assert kernel["migration_status"] == "profile_only"
assert kernel["policy"]["deterministic_only"] is True
assert kernel["policy"]["llm_used"] is False
assert kernel["policy"]["gap_state_changed"] is False
assert kernel["policy"]["contract_state_changed"] is False
assert summary["num_configured_kernels"] > 0
assert summary["num_declared_functions"] > 0
assert summary["num_matches"] + summary["num_unresolved_configured"] == summary["num_configured_kernels"]
assert summary["generator_unlock_allowed"] is False
assert validation["status"] in {"pass", "pass_with_warnings"}
assert guard["decision"]["blocked"] is True
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017").exists()
PY

echo
echo "DONE."
EOT

chmod +x add_kernel_name_resolver_v019_replay.sh

echo "[6/6] Run v0.0.19 replay"

./add_kernel_name_resolver_v019_replay.sh

echo "[v0.0.19] Git status"

git status
