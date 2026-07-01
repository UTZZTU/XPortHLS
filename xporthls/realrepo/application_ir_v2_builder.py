from __future__ import annotations

import argparse
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def unique_sorted(items: list[str]) -> list[str]:
    return sorted({x for x in items if x not in {None, ""}})


def normalize_kernel_name(name: str | None) -> str | None:
    if not name:
        return None

    out = str(name).strip()
    out = out.split(".")[0]
    out = re.sub(r"_[0-9]+$", "", out)
    return out or None


def normalize_cu_name(name: str | None) -> str | None:
    if not name:
        return None
    return str(name).strip() or None


def file_ref(path: str | None) -> dict[str, Any] | None:
    if not path:
        return None
    p = Path(path)
    return {
        "path": path,
        "exists": p.exists(),
        "kind": "file" if p.is_file() else "directory" if p.is_dir() else "missing"
    }


def summarize_input_refs(
    census_path: str,
    source_profile_path: str,
    build_ir_path: str,
    connectivity_ir_path: str,
    hls_ir_path: str,
    compatibility_profile_path: str | None,
) -> dict[str, Any]:
    return {
        "repo_census": file_ref(census_path),
        "source_platform_profile": file_ref(source_profile_path),
        "build_ir": file_ref(build_ir_path),
        "connectivity_ir": file_ref(connectivity_ir_path),
        "hls_interface_ir": file_ref(hls_ir_path),
        "compatibility_profile": file_ref(compatibility_profile_path) if compatibility_profile_path else None,
    }


def index_hls_kernels(hls_ir: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}

    for kernel in hls_ir.get("kernels", []):
        name = kernel.get("name")
        norm = normalize_kernel_name(name)
        if not norm:
            continue

        # Prefer the first exact normalized kernel entry. Keep all sources later in aliases.
        out.setdefault(norm, {
            "declared_name": name,
            "normalized_name": norm,
            "files": [],
            "line_ranges": [],
            "args": [],
            "candidate_reasons": [],
            "interfaces": [],
            "has_dataflow": False,
            "hls_stream_markers": 0,
        })

        rec = out[norm]
        if kernel.get("file"):
            rec["files"].append(kernel["file"])
        rec["line_ranges"].append({
            "file": kernel.get("file"),
            "line_start": kernel.get("line_start"),
            "line_end": kernel.get("line_end"),
        })
        rec["args"].extend(kernel.get("args", []))
        rec["candidate_reasons"].extend(kernel.get("candidate_reasons", []))
        rec["has_dataflow"] = bool(rec["has_dataflow"] or kernel.get("has_dataflow"))
        rec["hls_stream_markers"] += int(kernel.get("hls_stream_markers", 0) or 0)

    for rec in out.values():
        rec["files"] = unique_sorted(rec["files"])
        rec["candidate_reasons"] = unique_sorted(rec["candidate_reasons"])

    for interface in hls_ir.get("interfaces", []):
        fn = interface.get("function")
        norm = normalize_kernel_name(fn)
        if norm in out:
            out[norm]["interfaces"].append(interface)

    return out


def collect_configured_kernel_names(connectivity_ir: dict[str, Any]) -> dict[str, dict[str, Any]]:
    configured: dict[str, dict[str, Any]] = {}

    def ensure(name: str | None) -> dict[str, Any] | None:
        norm = normalize_kernel_name(name)
        if not norm:
            return None
        configured.setdefault(norm, {
            "normalized_name": norm,
            "names_seen": [],
            "sources": [],
            "roles": [],
        })
        if name:
            configured[norm]["names_seen"].append(str(name))
        return configured[norm]

    for directive in connectivity_ir.get("compute_units", []):
        parsed = directive.get("parsed", {})
        base = parsed.get("kernel")
        rec = ensure(base)
        if rec:
            rec["sources"].append(directive.get("file", "unknown"))
            rec["roles"].append("compute_unit_base")

        for cu in parsed.get("compute_units", []) or []:
            rec = ensure(cu)
            if rec:
                rec["sources"].append(directive.get("file", "unknown"))
                rec["roles"].append("compute_unit_instance")

    for directive in connectivity_ir.get("memory_mappings", []):
        parsed = directive.get("parsed", {})
        name = parsed.get("kernel_or_cu")
        rec = ensure(name)
        if rec:
            rec["sources"].append(directive.get("file", "unknown"))
            rec["roles"].append("memory_mapping")

    for directive in connectivity_ir.get("stream_edges", []):
        parsed = directive.get("parsed", {})
        for key, role in [("src_kernel_or_cu", "stream_src"), ("dst_kernel_or_cu", "stream_dst")]:
            rec = ensure(parsed.get(key))
            if rec:
                rec["sources"].append(directive.get("file", "unknown"))
                rec["roles"].append(role)

    for directive in connectivity_ir.get("slr_assignments", []):
        parsed = directive.get("parsed", {})
        rec = ensure(parsed.get("kernel_or_cu"))
        if rec:
            rec["sources"].append(directive.get("file", "unknown"))
            rec["roles"].append("slr_assignment")

    for rec in configured.values():
        rec["names_seen"] = unique_sorted(rec["names_seen"])
        rec["sources"] = unique_sorted(rec["sources"])
        rec["roles"] = unique_sorted(rec["roles"])

    return configured


def collect_memory_mappings(connectivity_ir: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    for directive in connectivity_ir.get("memory_mappings", []):
        parsed = directive.get("parsed", {})
        out.append({
            "file": directive.get("file"),
            "line": directive.get("line"),
            "section": directive.get("section"),
            "raw": directive.get("raw"),
            "key": directive.get("key"),
            "value": directive.get("value"),
            "kernel_or_cu": parsed.get("kernel_or_cu"),
            "normalized_kernel": normalize_kernel_name(parsed.get("kernel_or_cu")),
            "port": parsed.get("port"),
            "memory": parsed.get("memory"),
            "memory_kind": parsed.get("memory_kind"),
            "memory_indices": parsed.get("memory_indices", []),
        })

    return out


def collect_compute_units(connectivity_ir: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    for directive in connectivity_ir.get("compute_units", []):
        parsed = directive.get("parsed", {})
        out.append({
            "file": directive.get("file"),
            "line": directive.get("line"),
            "section": directive.get("section"),
            "raw": directive.get("raw"),
            "kernel": parsed.get("kernel"),
            "normalized_kernel": normalize_kernel_name(parsed.get("kernel")),
            "count": parsed.get("count"),
            "compute_units": parsed.get("compute_units", []),
        })

    return out


def collect_stream_edges(connectivity_ir: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    for directive in connectivity_ir.get("stream_edges", []):
        parsed = directive.get("parsed", {})
        out.append({
            "file": directive.get("file"),
            "line": directive.get("line"),
            "section": directive.get("section"),
            "raw": directive.get("raw"),
            "src": parsed.get("src"),
            "dst": parsed.get("dst"),
            "src_kernel_or_cu": parsed.get("src_kernel_or_cu"),
            "src_normalized_kernel": normalize_kernel_name(parsed.get("src_kernel_or_cu")),
            "src_port": parsed.get("src_port"),
            "dst_kernel_or_cu": parsed.get("dst_kernel_or_cu"),
            "dst_normalized_kernel": normalize_kernel_name(parsed.get("dst_kernel_or_cu")),
            "dst_port": parsed.get("dst_port"),
        })

    return out


def collect_slr_assignments(connectivity_ir: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []

    for directive in connectivity_ir.get("slr_assignments", []):
        parsed = directive.get("parsed", {})
        out.append({
            "file": directive.get("file"),
            "line": directive.get("line"),
            "section": directive.get("section"),
            "raw": directive.get("raw"),
            "kernel_or_cu": parsed.get("kernel_or_cu"),
            "normalized_kernel": normalize_kernel_name(parsed.get("kernel_or_cu")),
            "slr": parsed.get("slr"),
        })

    return out


def group_by_kernel(records: list[dict[str, Any]], key: str = "normalized_kernel") -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for rec in records:
        name = rec.get(key)
        if name:
            out[name].append(rec)

    return dict(out)


def build_kernel_graph(
    configured: dict[str, dict[str, Any]],
    declared: dict[str, dict[str, Any]],
    memory_mappings: list[dict[str, Any]],
    compute_units: list[dict[str, Any]],
    stream_edges: list[dict[str, Any]],
    slr_assignments: list[dict[str, Any]],
) -> dict[str, Any]:
    memory_by_kernel = group_by_kernel(memory_mappings)
    cu_by_kernel = group_by_kernel(compute_units)
    slr_by_kernel = group_by_kernel(slr_assignments)

    stream_out: dict[str, list[dict[str, Any]]] = defaultdict(list)
    stream_in: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for edge in stream_edges:
        if edge.get("src_normalized_kernel"):
            stream_out[edge["src_normalized_kernel"]].append(edge)
        if edge.get("dst_normalized_kernel"):
            stream_in[edge["dst_normalized_kernel"]].append(edge)

    all_names = sorted(set(configured.keys()) | set(declared.keys()))
    kernels: list[dict[str, Any]] = []

    configured_without_declared = []
    declared_without_config = []

    for name in all_names:
        configured_rec = configured.get(name)
        declared_rec = declared.get(name)

        if configured_rec and not declared_rec:
            configured_without_declared.append(name)

        if declared_rec and not configured_rec:
            declared_without_config.append(name)

        kernels.append({
            "normalized_name": name,
            "configured": configured_rec is not None,
            "declared": declared_rec is not None,
            "configured_names_seen": configured_rec.get("names_seen", []) if configured_rec else [],
            "configured_sources": configured_rec.get("sources", []) if configured_rec else [],
            "configured_roles": configured_rec.get("roles", []) if configured_rec else [],
            "declared_name": declared_rec.get("declared_name") if declared_rec else None,
            "source_files": declared_rec.get("files", []) if declared_rec else [],
            "args": declared_rec.get("args", []) if declared_rec else [],
            "candidate_reasons": declared_rec.get("candidate_reasons", []) if declared_rec else [],
            "has_dataflow": declared_rec.get("has_dataflow", False) if declared_rec else False,
            "hls_stream_markers": declared_rec.get("hls_stream_markers", 0) if declared_rec else 0,
            "interfaces": declared_rec.get("interfaces", []) if declared_rec else [],
            "compute_units": cu_by_kernel.get(name, []),
            "memory_mappings": memory_by_kernel.get(name, []),
            "stream_inputs": stream_in.get(name, []),
            "stream_outputs": stream_out.get(name, []),
            "slr_assignments": slr_by_kernel.get(name, []),
        })

    return {
        "schema_version": "kernel_graph_ir.v1",
        "kernels": kernels,
        "stream_edges": stream_edges,
        "configured_without_declared": configured_without_declared,
        "declared_without_config": declared_without_config,
        "summary": {
            "num_kernels": len(kernels),
            "num_configured_kernels": len(configured),
            "num_declared_kernels": len(declared),
            "num_configured_without_declared": len(configured_without_declared),
            "num_declared_without_config": len(declared_without_config),
            "num_stream_edges": len(stream_edges),
        }
    }


def build_memory_topology(memory_mappings: list[dict[str, Any]]) -> dict[str, Any]:
    memory_kinds = unique_sorted([m.get("memory_kind") for m in memory_mappings])
    banks_by_kind: dict[str, set[str]] = defaultdict(set)
    ports_by_memory: dict[str, list[dict[str, Any]]] = defaultdict(list)

    for mapping in memory_mappings:
        kind = mapping.get("memory_kind") or "unknown"
        for idx in mapping.get("memory_indices", []) or []:
            banks_by_kind[kind].add(str(idx))

        mem = mapping.get("memory") or "unknown"
        ports_by_memory[mem].append({
            "kernel_or_cu": mapping.get("kernel_or_cu"),
            "normalized_kernel": mapping.get("normalized_kernel"),
            "port": mapping.get("port"),
            "file": mapping.get("file"),
            "line": mapping.get("line"),
        })

    return {
        "schema_version": "memory_topology_ir.v1",
        "memory_kinds": memory_kinds,
        "banks_by_kind": {k: sorted(v) for k, v in sorted(banks_by_kind.items())},
        "ports_by_memory": {k: v for k, v in sorted(ports_by_memory.items())},
        "mappings": memory_mappings,
        "summary": {
            "num_memory_mappings": len(memory_mappings),
            "memory_kinds": memory_kinds,
            "num_memory_objects": len(ports_by_memory),
        }
    }


def build_unsupported_features(
    source_profile: dict[str, Any],
    connectivity_ir: dict[str, Any],
    hls_ir: dict[str, Any],
    kernel_graph: dict[str, Any],
) -> list[dict[str, Any]]:
    unsupported: list[dict[str, Any]] = []
    hls_summary = hls_ir.get("summary", {})
    conn_summary = connectivity_ir.get("summary", {})

    if source_profile.get("source_memory_model") == "HBM" or "HBM" in conn_summary.get("memory_kinds", []):
        unsupported.append({
            "feature": "source_hbm_topology_mapping",
            "severity": "requires_next_ir",
            "reason": "HBM mappings are extracted, but source-to-target memory gap mapping to V80 AVED is not implemented yet.",
            "required_capability": "source_to_target_memory_gap_contract"
        })

    if hls_summary.get("num_axis", 0) > 0 or hls_summary.get("num_stream_variables", 0) > 0:
        unsupported.append({
            "feature": "axis_stream_and_k2k_migration",
            "severity": "requires_next_ir",
            "reason": "AXIS and hls::stream facts are extracted, but target stream/K2K mapping is not implemented yet.",
            "required_capability": "stream_edge_extractor"
        })

    if conn_summary.get("num_slr_assignments", 0) > 0:
        unsupported.append({
            "feature": "source_slr_placement_mapping",
            "severity": "requires_target_mapping",
            "reason": "Source SLR assignments are extracted, but target V80 placement policy is not implemented yet.",
            "required_capability": "source_to_target_gap_contract"
        })

    if kernel_graph.get("summary", {}).get("num_configured_without_declared", 0) > 0:
        unsupported.append({
            "feature": "kernel_name_alignment",
            "severity": "needs_refinement",
            "reason": "Some configured kernels or compute-unit names do not yet align with declared HLS kernel candidates.",
            "required_capability": "kernel_name_resolution"
        })

    return unsupported


def build_application_ir_v2(
    case_id: str,
    target_platform: str,
    target_ecosystem: str,
    census_path: str,
    source_profile_path: str,
    build_ir_path: str,
    connectivity_ir_path: str,
    hls_ir_path: str,
    compatibility_profile_path: str | None = None,
) -> dict[str, Any]:
    census = load_json(census_path)
    source_profile = load_json(source_profile_path)
    build = load_json(build_ir_path)
    connectivity = load_json(connectivity_ir_path)
    hls = load_json(hls_ir_path)
    compatibility = load_json(compatibility_profile_path) if compatibility_profile_path else None

    declared = index_hls_kernels(hls)
    configured = collect_configured_kernel_names(connectivity)

    memory_mappings = collect_memory_mappings(connectivity)
    compute_units = collect_compute_units(connectivity)
    stream_edges = collect_stream_edges(connectivity)
    slr_assignments = collect_slr_assignments(connectivity)

    kernel_graph = build_kernel_graph(
        configured=configured,
        declared=declared,
        memory_mappings=memory_mappings,
        compute_units=compute_units,
        stream_edges=stream_edges,
        slr_assignments=slr_assignments,
    )
    memory_topology = build_memory_topology(memory_mappings)

    unsupported = build_unsupported_features(
        source_profile=source_profile,
        connectivity_ir=connectivity,
        hls_ir=hls,
        kernel_graph=kernel_graph,
    )

    next_capabilities = []
    if compatibility:
        next_capabilities.extend(compatibility.get("required_next_capabilities", []))
    next_capabilities.extend([u.get("required_capability") for u in unsupported])

    unknowns = []
    if kernel_graph["summary"]["num_configured_without_declared"] > 0:
        unknowns.append({
            "kind": "configured_kernel_without_declared_hls_function",
            "count": kernel_graph["summary"]["num_configured_without_declared"],
            "items": kernel_graph["configured_without_declared"],
        })

    if kernel_graph["summary"]["num_declared_without_config"] > 0:
        unknowns.append({
            "kind": "declared_hls_function_without_connectivity_config",
            "count": kernel_graph["summary"]["num_declared_without_config"],
            "items": kernel_graph["declared_without_config"],
        })

    return {
        "schema_version": "application_ir.v2",
        "case_id": case_id,
        "project": case_id,
        "created_at_utc": utc_now(),
        "ir_stage": "real_repo_profile",
        "migration_status": "profile_only",
        "source_runtime": source_profile.get("source_runtime"),
        "source_project_kind": source_profile.get("project_kind"),
        "source": {
            "repo_path": census.get("repo_path"),
            "runtime": source_profile.get("source_runtime"),
            "boards": source_profile.get("source_boards_detected", []),
            "toolchains": source_profile.get("source_toolchains_detected", {}),
            "memory_model": source_profile.get("source_memory_model"),
            "complexity": source_profile.get("complexity", {}),
        },
        "target": {
            "platform": target_platform,
            "ecosystem": target_ecosystem,
            "status": "fixed_target_for_current_development"
        },
        "input_refs": summarize_input_refs(
            census_path=census_path,
            source_profile_path=source_profile_path,
            build_ir_path=build_ir_path,
            connectivity_ir_path=connectivity_ir_path,
            hls_ir_path=hls_ir_path,
            compatibility_profile_path=compatibility_profile_path,
        ),
        "facts": {
            "repo_census": {
                "schema_version": census.get("schema_version"),
                "summary": census.get("summary", {}),
                "special_files": census.get("special_files", {}),
            },
            "source_platform": source_profile,
            "build": {
                "schema_version": build.get("schema_version"),
                "summary": build.get("summary", {}),
                "targets": build.get("targets", []),
                "commands": build.get("commands", []),
                "build_files": build.get("build_files", []),
            },
            "connectivity": {
                "schema_version": connectivity.get("schema_version"),
                "summary": connectivity.get("summary", {}),
                "memory_mappings": memory_mappings,
                "compute_units": compute_units,
                "stream_edges": stream_edges,
                "slr_assignments": slr_assignments,
            },
            "hls": {
                "schema_version": hls.get("schema_version"),
                "summary": hls.get("summary", {}),
                "kernels": hls.get("kernels", []),
                "interfaces": hls.get("interfaces", []),
                "stream_variables": hls.get("stream_variables", []),
                "include_graph": hls.get("include_graph", []),
            }
        },
        "kernel_graph": kernel_graph,
        "memory_topology": memory_topology,
        "interfaces": {
            "hls": hls.get("interfaces", []),
            "interface_type_summary": hls.get("summary", {}).get("interface_types", {}),
        },
        "build_system": {
            "targets": build.get("targets", []),
            "commands": build.get("commands", []),
            "detected_platforms": build.get("summary", {}).get("detected_platforms", []),
            "config_refs": build.get("summary", {}).get("config_refs", []),
            "xclbin_refs": build.get("summary", {}).get("xclbin_refs", []),
            "xo_refs": build.get("summary", {}).get("xo_refs", []),
        },
        "compatibility": {
            "profile_ref": compatibility_profile_path,
            "migration_possible_now": False,
            "migration_reason": "ApplicationIR v2 is a real-repo analysis IR. It does not imply AVED migration is implemented.",
            "required_next_capabilities": unique_sorted([x for x in next_capabilities if x]),
            "unsupported_features": unsupported,
        },
        "unknowns": unknowns,
        "llm_annotations": [],
        "summary": {
            "num_files": census.get("summary", {}).get("num_files"),
            "source_runtime": source_profile.get("source_runtime"),
            "source_boards": source_profile.get("source_boards_detected", []),
            "source_memory_model": source_profile.get("source_memory_model"),
            "num_build_files": build.get("summary", {}).get("num_build_files"),
            "num_build_targets": build.get("summary", {}).get("num_targets"),
            "num_connectivity_directives": connectivity.get("summary", {}).get("num_directives"),
            "num_memory_mappings": connectivity.get("summary", {}).get("num_memory_mappings"),
            "num_stream_edges": connectivity.get("summary", {}).get("num_stream_edges"),
            "num_hls_files": hls.get("summary", {}).get("num_hls_files"),
            "num_hls_kernel_candidates": hls.get("summary", {}).get("num_kernel_candidates"),
            "num_hls_interface_pragmas": hls.get("summary", {}).get("num_interface_pragmas"),
            "num_kernel_graph_nodes": kernel_graph.get("summary", {}).get("num_kernels"),
            "num_unsupported_features": len(unsupported),
            "num_unknowns": len(unknowns),
        }
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build multi-kernel ApplicationIR v2 from real repository IRs")
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--census", required=True)
    parser.add_argument("--source-profile", required=True)
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--compatibility-profile", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    app = build_application_ir_v2(
        case_id=args.case_id,
        target_platform=args.target_platform,
        target_ecosystem=args.target_ecosystem,
        census_path=args.census,
        source_profile_path=args.source_profile,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
        hls_ir_path=args.hls_ir,
        compatibility_profile_path=args.compatibility_profile,
    )

    save_json(args.out, app)

    s = app["summary"]
    kg = app["kernel_graph"]["summary"]
    print(f"[xporthls] ApplicationIR v2 written to: {args.out}")
    print(f"[xporthls] Case: {app['case_id']}")
    print(f"[xporthls] Source runtime: {s['source_runtime']}")
    print(f"[xporthls] Source boards: {s['source_boards']}")
    print(f"[xporthls] Source memory: {s['source_memory_model']}")
    print(f"[xporthls] Build files: {s['num_build_files']}")
    print(f"[xporthls] Connectivity directives: {s['num_connectivity_directives']}")
    print(f"[xporthls] HLS kernel candidates: {s['num_hls_kernel_candidates']}")
    print(f"[xporthls] Kernel graph nodes: {kg['num_kernels']}")
    print(f"[xporthls] Configured without declared: {kg['num_configured_without_declared']}")
    print(f"[xporthls] Declared without config: {kg['num_declared_without_config']}")
    print(f"[xporthls] Unsupported features: {s['num_unsupported_features']}")
    print(f"[xporthls] Unknowns: {s['num_unknowns']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
