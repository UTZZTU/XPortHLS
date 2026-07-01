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
