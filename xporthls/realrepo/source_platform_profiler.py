from __future__ import annotations

import argparse
import json
import re
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


def read_repo_file(repo_path: str, rel: str, max_bytes: int = 2_000_000) -> str:
    path = Path(repo_path) / rel
    try:
        if not path.exists() or path.stat().st_size > max_bytes:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def unique_sorted(items: list[str]) -> list[str]:
    return sorted({x for x in items if x})


def infer_source_profile(census: dict[str, Any]) -> dict[str, Any]:
    repo_path = census["repo_path"]
    marker_totals = census.get("summary", {}).get("marker_totals", {})
    special = census.get("special_files", {})

    readme_texts = []
    for rel in special.get("readme", []):
        readme_texts.append(read_repo_file(repo_path, rel))
    readme = "\n".join(readme_texts)

    all_text_fragments = [readme]
    for rel in special.get("makefiles", [])[:20] + special.get("connectivity_configs", [])[:20]:
        all_text_fragments.append(read_repo_file(repo_path, rel))
    corpus = "\n".join(all_text_fragments)

    boards = []
    for board in ["U280", "U50", "U55C", "U200", "U250", "V80"]:
        if re.search(rf"\b{board}\b", corpus, flags=re.I) or marker_totals.get(board.lower(), 0):
            boards.append(board)

    vitis_versions = unique_sorted(re.findall(r"Vitis\s+([0-9]{4}\.[0-9])", corpus, flags=re.I))
    shell_platforms = unique_sorted(re.findall(r"xilinx_[A-Za-z0-9_]+", corpus))

    xrt_indicators = {
        "xrt_cpp_namespace_hits": marker_totals.get("xrt_cpp_namespace", 0),
        "xrt_c_api_hits": marker_totals.get("xrt_c_api", 0),
        "xclbin_hits": marker_totals.get("xclbin", 0),
        "xrt_file_count": len(special.get("xrt_files", [])),
        "xclbin_file_count": len(special.get("xclbins", [])),
    }

    hls_indicators = {
        "hls_file_count": len(special.get("hls_files", [])),
        "hls_pragma_hits": marker_totals.get("hls_pragmas", 0),
        "hls_stream_hits": marker_totals.get("hls_stream", 0),
        "extern_c_hits": marker_totals.get("extern_c", 0),
        "m_axi_hits": marker_totals.get("m_axi", 0),
        "s_axilite_hits": marker_totals.get("s_axilite", 0),
        "axis_hits": marker_totals.get("axis", 0),
        "dataflow_hits": marker_totals.get("dataflow", 0),
    }

    build_indicators = {
        "makefile_count": len(special.get("makefiles", [])),
        "connectivity_config_count": len(special.get("connectivity_configs", [])),
        "tcl_count": len(special.get("tcl_scripts", [])),
        "vpp_hits": marker_totals.get("vpp", 0),
        "vitis_hits": marker_totals.get("vitis", 0),
        "sp_mapping_hits": marker_totals.get("sp_mapping", 0),
        "nk_mapping_hits": marker_totals.get("nk_mapping", 0),
        "stream_connect_hits": marker_totals.get("stream_connect", 0),
    }

    memory_indicators = {
        "hbm_hits": marker_totals.get("hbm", 0),
        "slr_hits": marker_totals.get("slr", 0),
        "m_axi_hits": marker_totals.get("m_axi", 0),
    }

    source_runtime = "XRT" if (
        xrt_indicators["xrt_cpp_namespace_hits"]
        or xrt_indicators["xrt_c_api_hits"]
        or xrt_indicators["xclbin_hits"]
        or xrt_indicators["xrt_file_count"]
        or xrt_indicators["xclbin_file_count"]
    ) else "unknown"

    source_memory = "HBM" if memory_indicators["hbm_hits"] else "unknown"
    if source_memory == "unknown" and hls_indicators["m_axi_hits"]:
        source_memory = "external_memory_m_axi"

    project_kind = "vitis_xrt_acceleration_project" if (
        source_runtime == "XRT" or build_indicators["vpp_hits"] or build_indicators["vitis_hits"]
    ) else "unknown"

    complexity_reasons = []
    if hls_indicators["extern_c_hits"] > 1:
        complexity_reasons.append("multiple extern C kernel candidates")
    if hls_indicators["axis_hits"] > 0 or hls_indicators["hls_stream_hits"] > 0:
        complexity_reasons.append("AXIS/hls::stream interfaces")
    if memory_indicators["hbm_hits"] > 0:
        complexity_reasons.append("HBM-oriented design")
    if build_indicators["connectivity_config_count"] > 0:
        complexity_reasons.append("connectivity/config files present")
    if xrt_indicators["xclbin_file_count"] > 0:
        complexity_reasons.append("precompiled xclbin artifacts present")
    if build_indicators["makefile_count"] > 1:
        complexity_reasons.append("multiple makefiles/build entry points")

    complexity = "high" if len(complexity_reasons) >= 3 else "medium" if complexity_reasons else "low"

    return {
        "schema_version": "source_platform_profile.v1",
        "repo_path": repo_path,
        "project_kind": project_kind,
        "source_runtime": source_runtime,
        "source_boards_detected": boards,
        "source_toolchains_detected": {
            "vitis_versions": vitis_versions,
            "shell_platforms": shell_platforms,
        },
        "source_memory_model": source_memory,
        "indicators": {
            "xrt": xrt_indicators,
            "hls": hls_indicators,
            "build": build_indicators,
            "memory": memory_indicators,
        },
        "complexity": {
            "level": complexity,
            "reasons": complexity_reasons,
        },
        "representative_files": {
            "readme": special.get("readme", [])[:10],
            "makefiles": special.get("makefiles", [])[:20],
            "connectivity_configs": special.get("connectivity_configs", [])[:20],
            "xclbins": special.get("xclbins", [])[:20],
            "xrt_files": special.get("xrt_files", [])[:20],
            "hls_files": special.get("hls_files", [])[:30],
        }
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Infer source platform profile from repo census")
    parser.add_argument("--census", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    census = load_json(args.census)
    profile = infer_source_profile(census)
    save_json(args.out, profile)

    print(f"[xporthls] Source platform profile written to: {args.out}")
    print(f"[xporthls] Project kind: {profile['project_kind']}")
    print(f"[xporthls] Source runtime: {profile['source_runtime']}")
    print(f"[xporthls] Boards detected: {profile['source_boards_detected']}")
    print(f"[xporthls] Toolchains detected: {profile['source_toolchains_detected']}")
    print(f"[xporthls] Memory model: {profile['source_memory_model']}")
    print(f"[xporthls] Complexity: {profile['complexity']['level']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
