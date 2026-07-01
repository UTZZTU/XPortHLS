from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def status_entry(status: str, reason: str, next_step: str) -> dict[str, str]:
    return {
        "status": status,
        "reason": reason,
        "next_step": next_step,
    }


def build_compatibility_profile(
    census: dict[str, Any],
    source_profile: dict[str, Any],
    target_platform: str,
    target_ecosystem: str,
) -> dict[str, Any]:
    indicators = source_profile.get("indicators", {})
    xrt = indicators.get("xrt", {})
    hls = indicators.get("hls", {})
    build = indicators.get("build", {})
    memory = indicators.get("memory", {})

    supported = {}
    gaps = []

    supported["repo_census"] = status_entry(
        "supported",
        "v0.0.11 can enumerate files, roles, markers and special project files.",
        "Use census report as input to future BuildIR and HlsInterfaceIR extractors."
    )

    supported["source_platform_profile"] = status_entry(
        "supported",
        "v0.0.11 can infer source runtime, boards, Vitis versions, shell strings and memory hints from text markers.",
        "Refine with explicit SourcePlatformProfile schema in a later version."
    )

    if source_profile.get("source_runtime") == "XRT":
        supported["xrt_runtime_detection"] = status_entry(
            "partially_supported",
            "XRT/XCL markers and xclbin artifacts can be detected, but full host semantic extraction is still limited to simple patterns.",
            "Extend XRT extractor for real host code, xcl C APIs, events, command queues and xclbin handling."
        )
        gaps.append("real_xrt_host_semantic_extraction")
    else:
        supported["xrt_runtime_detection"] = status_entry(
            "unknown_or_not_detected",
            "No strong XRT indicators detected.",
            "Inspect repository manually or add project-specific detection rules."
        )

    if build.get("makefile_count", 0) or build.get("vpp_hits", 0) or build.get("vitis_hits", 0):
        supported["vitis_build_flow"] = status_entry(
            "not_supported_yet",
            "Build files and Vitis markers are detected, but BuildIR parsing is not implemented yet.",
            "Implement v0.0.12 BuildIR extractor for Makefile, v++ commands, targets and platform strings."
        )
        gaps.append("build_ir_extractor")
    else:
        supported["vitis_build_flow"] = status_entry(
            "not_detected",
            "No Makefile/Vitis build markers detected.",
            "No immediate action."
        )

    if build.get("connectivity_config_count", 0) or build.get("sp_mapping_hits", 0) or build.get("stream_connect_hits", 0) or build.get("nk_mapping_hits", 0):
        supported["connectivity"] = status_entry(
            "not_supported_yet",
            "Connectivity/config files or mapping directives are detected, but ConnectivityIR is not implemented yet.",
            "Implement v0.0.12 ConnectivityIR for sp/nk/stream_connect/SLR/HBM mapping."
        )
        gaps.append("connectivity_ir_extractor")
    else:
        supported["connectivity"] = status_entry(
            "not_detected",
            "No connectivity markers detected in the current profile.",
            "No immediate action."
        )

    if hls.get("hls_pragma_hits", 0) or hls.get("extern_c_hits", 0):
        supported["hls_kernel_interfaces"] = status_entry(
            "not_supported_yet",
            "HLS kernels and pragmas are detected, but HlsInterfaceIR extraction is not implemented yet.",
            "Implement v0.0.13 HLS interface extractor for extern C kernels, m_axi, s_axilite, axis and dataflow."
        )
        gaps.append("hls_interface_ir_extractor")
    else:
        supported["hls_kernel_interfaces"] = status_entry(
            "not_detected",
            "No HLS pragma/kernel markers detected.",
            "No immediate action."
        )

    if memory.get("hbm_hits", 0) or hls.get("m_axi_hits", 0):
        supported["memory_topology"] = status_entry(
            "not_supported_yet",
            "HBM/m_axi hints are detected, but MemoryTopologyIR and source-to-target memory gap mapping are not implemented yet.",
            "Implement MemoryTopologyIR and SourceToTargetGapContract."
        )
        gaps.append("memory_topology_ir")
        gaps.append("source_to_target_memory_gap_contract")
    else:
        supported["memory_topology"] = status_entry(
            "simple_or_unknown",
            "No strong HBM marker detected.",
            "Use existing light DDR path if project is actually simple DDR."
        )

    if hls.get("axis_hits", 0) or hls.get("hls_stream_hits", 0):
        supported["streaming_k2k"] = status_entry(
            "not_supported_yet",
            "AXIS/hls::stream interfaces are detected, but KernelGraphIR and K2K edge extraction are not implemented yet.",
            "Implement KernelGraphIR with stream edges."
        )
        gaps.append("kernel_graph_ir")
        gaps.append("stream_edge_extractor")
    else:
        supported["streaming_k2k"] = status_entry(
            "not_detected",
            "No stream markers detected.",
            "No immediate action."
        )

    real_migration_possible_now = False
    if (
        source_profile.get("source_runtime") == "XRT"
        and hls.get("extern_c_hits", 0) <= 1
        and not memory.get("hbm_hits", 0)
        and not hls.get("axis_hits", 0)
        and not hls.get("hls_stream_hits", 0)
        and not build.get("connectivity_config_count", 0)
    ):
        real_migration_possible_now = False

    migration_status = "profile_only"
    migration_reason = (
        "v0.0.11 intentionally performs real-repo profiling only. "
        "HiSparse-like projects require BuildIR, ConnectivityIR, HlsInterfaceIR, KernelGraphIR and MemoryTopologyIR before migration."
    )

    return {
        "schema_version": "compatibility_profile.v1",
        "repo_path": census.get("repo_path"),
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "migration_status": migration_status,
        "migration_possible_now": real_migration_possible_now,
        "migration_reason": migration_reason,
        "source_summary": {
            "project_kind": source_profile.get("project_kind"),
            "source_runtime": source_profile.get("source_runtime"),
            "boards": source_profile.get("source_boards_detected"),
            "toolchains": source_profile.get("source_toolchains_detected"),
            "memory_model": source_profile.get("source_memory_model"),
            "complexity": source_profile.get("complexity"),
        },
        "capability_matrix": supported,
        "required_next_capabilities": sorted(set(gaps)),
        "recommended_next_version": {
            "version": "v0.0.12",
            "name": "Vitis Build + Connectivity Extractor",
            "why": "The profile shows real projects need Makefile/v++/connectivity parsing before ApplicationIR can represent them."
        }
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build source-to-target compatibility profile")
    parser.add_argument("--census", required=True)
    parser.add_argument("--source-profile", required=True)
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    census = load_json(args.census)
    source_profile = load_json(args.source_profile)

    profile = build_compatibility_profile(
        census=census,
        source_profile=source_profile,
        target_platform=args.target_platform,
        target_ecosystem=args.target_ecosystem,
    )
    save_json(args.out, profile)

    print(f"[xporthls] Compatibility profile written to: {args.out}")
    print(f"[xporthls] Migration status: {profile['migration_status']}")
    print(f"[xporthls] Target: {profile['target_platform']} / {profile['target_ecosystem']}")
    print(f"[xporthls] Required next capabilities: {profile['required_next_capabilities']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
