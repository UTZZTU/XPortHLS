#!/usr/bin/env bash
set -e

echo "[1/7] Add realrepo package"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/repo_census.py <<'EOT'
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from collections import Counter
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TEXT_EXTENSIONS = {
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx",
    ".tcl", ".ini", ".cfg", ".json", ".yaml", ".yml", ".mk", ".cmake",
    ".sh", ".py", ".txt", ".md", ".makefile", ""
}

SOURCE_EXTENSIONS = {".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx"}
BUILD_NAMES = {"makefile", "Makefile", "CMakeLists.txt", "makefile_us_alveo.mk"}


@dataclass
class FileRecord:
    path: str
    extension: str
    size_bytes: int
    role: str
    markers: dict[str, int] = field(default_factory=dict)
    sha256: str | None = None


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_read_text(path: Path, max_bytes: int = 2_000_000) -> str:
    try:
        if path.stat().st_size > max_bytes:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def sha256_file(path: Path, max_bytes: int = 100_000_000) -> str | None:
    try:
        if path.stat().st_size > max_bytes:
            return None
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return None


def classify_role(path: Path, rel: str, text: str) -> str:
    name = path.name
    lower_rel = rel.lower()
    ext = path.suffix.lower()

    if ".git/" in lower_rel or lower_rel.startswith(".git/"):
        return "ignored"

    if ext == ".xclbin":
        return "xclbin_binary"

    if name in BUILD_NAMES or lower_rel.endswith("/makefile") or lower_rel.endswith("/makefile_us_alveo.mk"):
        return "build_file"

    if ext in {".ini", ".cfg"}:
        return "connectivity_or_config"

    if ext == ".tcl":
        return "tcl_script"

    if ext in {".sh"}:
        return "shell_script"

    if ext in {".py"}:
        return "python_script"

    if ext in SOURCE_EXTENSIONS:
        if "xrt/" in lower_rel or "xrt::" in text or "xcl" in text or "xrt.h" in text or "experimental/xrt" in text:
            return "xrt_host_or_header"
        if "#pragma hls" in text.lower() or "hls::stream" in text or "extern \"C\"" in text:
            return "hls_kernel_or_header"
        if "sw/" in lower_rel:
            return "host_software"
        return "cpp_source"

    if ext in {".md", ".txt"}:
        return "documentation"

    return "other"


def count_markers(text: str) -> dict[str, int]:
    patterns = {
        "xrt_cpp_namespace": r"\bxrt::",
        "xrt_c_api": r"\bxcl[A-Za-z0-9_]+\b",
        "xclbin": r"\.xclbin\b|xclbin",
        "vitis": r"\bvitis\b",
        "vpp": r"\bv\+\+\b",
        "hls_pragmas": r"#\s*pragma\s+HLS",
        "hls_stream": r"\bhls::stream\b",
        "extern_c": r"extern\s+\"C\"",
        "m_axi": r"interface\s+m_axi|#\s*pragma\s+HLS\s+interface\s+m_axi",
        "s_axilite": r"interface\s+s_axilite|#\s*pragma\s+HLS\s+interface\s+s_axilite",
        "axis": r"interface\s+axis|#\s*pragma\s+HLS\s+interface\s+axis",
        "dataflow": r"#\s*pragma\s+HLS\s+dataflow",
        "stream_connect": r"stream_connect|sc\s*=",
        "sp_mapping": r"\bsp\s*=",
        "nk_mapping": r"\bnk\s*=",
        "hbm": r"\bHBM\b|\bhbm\b",
        "slr": r"\bSLR[0-9]?\b|\bslr[0-9]?\b",
        "u280": r"\bU280\b|\bu280\b",
        "u50": r"\bU50\b|\bu50\b",
        "u55c": r"\bU55C\b|\bu55c\b",
        "u200": r"\bU200\b|\bu200\b",
        "u250": r"\bU250\b|\bu250\b",
        "platform_xilinx": r"xilinx_[A-Za-z0-9_]+",
        "vitis_version": r"Vitis\s+[0-9]{4}\.[0-9]|vitis\s+[0-9]{4}\.[0-9]",
        "cnpy": r"\bcnpy\b",
    }

    out: dict[str, int] = {}
    for key, pattern in patterns.items():
        out[key] = len(re.findall(pattern, text, flags=re.I))
    return out


def discover_repo(repo_path: str) -> dict[str, Any]:
    root = Path(repo_path).resolve()

    if not root.exists():
        raise FileNotFoundError(f"Repository path does not exist: {root}")

    if not root.is_dir():
        raise NotADirectoryError(f"Repository path is not a directory: {root}")

    records: list[FileRecord] = []
    ext_counter: Counter[str] = Counter()
    role_counter: Counter[str] = Counter()
    marker_totals: Counter[str] = Counter()
    top_level_counter: Counter[str] = Counter()
    directories: set[str] = set()
    largest_files: list[dict[str, Any]] = []

    for path in sorted(root.rglob("*")):
        rel = str(path.relative_to(root))

        if rel.startswith(".git/") or "/.git/" in rel:
            continue

        if path.is_dir():
            directories.add(rel)
            continue

        if not path.is_file():
            continue

        ext = path.suffix.lower()
        text = safe_read_text(path) if ext in TEXT_EXTENSIONS or path.name in BUILD_NAMES else ""
        role = classify_role(path, rel, text)
        if role == "ignored":
            continue

        markers = count_markers(text) if text else {}
        for k, v in markers.items():
            marker_totals[k] += v

        size = path.stat().st_size
        ext_key = ext if ext else path.name.lower()
        ext_counter[ext_key] += 1
        role_counter[role] += 1

        top = rel.split(os.sep)[0]
        top_level_counter[top] += 1

        largest_files.append({"path": rel, "size_bytes": size})

        records.append(
            FileRecord(
                path=rel,
                extension=ext_key,
                size_bytes=size,
                role=role,
                markers={k: v for k, v in markers.items() if v},
                sha256=sha256_file(path),
            )
        )

    largest_files = sorted(largest_files, key=lambda x: x["size_bytes"], reverse=True)[:20]

    special_files = {
        "readme": [
            r.path for r in records
            if r.path.lower() in {"readme.md", "readme", "readme.txt"} or r.path.lower().endswith("/readme.md")
        ],
        "makefiles": [r.path for r in records if r.role == "build_file"],
        "connectivity_configs": [r.path for r in records if r.role == "connectivity_or_config"],
        "tcl_scripts": [r.path for r in records if r.role == "tcl_script"],
        "xclbins": [r.path for r in records if r.role == "xclbin_binary"],
        "xrt_files": [r.path for r in records if r.role == "xrt_host_or_header"],
        "hls_files": [r.path for r in records if r.role == "hls_kernel_or_header"],
    }

    return {
        "schema_version": "repo_census.v1",
        "repo_path": str(root),
        "created_at_utc": utc_now(),
        "summary": {
            "num_files": len(records),
            "num_directories": len(directories),
            "extensions": dict(sorted(ext_counter.items())),
            "roles": dict(sorted(role_counter.items())),
            "top_level_entries": dict(sorted(top_level_counter.items())),
            "marker_totals": dict(sorted(marker_totals.items())),
            "largest_files": largest_files,
        },
        "special_files": special_files,
        "directories": sorted(directories),
        "files": [asdict(r) for r in records],
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build a census report for a real XRT/Vitis repository")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = discover_repo(args.repo)
    save_json(args.out, report)

    print(f"[xporthls] Repo census written to: {args.out}")
    print(f"[xporthls] Files: {report['summary']['num_files']}")
    print(f"[xporthls] Directories: {report['summary']['num_directories']}")
    print(f"[xporthls] Roles: {report['summary']['roles']}")
    print(f"[xporthls] XRT files: {len(report['special_files']['xrt_files'])}")
    print(f"[xporthls] HLS files: {len(report['special_files']['hls_files'])}")
    print(f"[xporthls] Connectivity/config files: {len(report['special_files']['connectivity_configs'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add source platform profiler"

cat > xporthls/realrepo/source_platform_profiler.py <<'EOT'
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
EOT

echo "[3/7] Add compatibility profiler"

cat > xporthls/realrepo/compatibility_profiler.py <<'EOT'
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
EOT

echo "[4/7] Add realrepo profile validator"

cat > xporthls/realrepo/validate_realrepo_profile_v011.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class RealRepoIssue:
    severity: str
    code: str
    message: str


@dataclass
class RealRepoValidationReport:
    status: str
    issues: list[RealRepoIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate(census: dict[str, Any], source: dict[str, Any], compat: dict[str, Any]) -> RealRepoValidationReport:
    issues: list[RealRepoIssue] = []

    if census.get("schema_version") != "repo_census.v1":
        issues.append(RealRepoIssue("error", "CENSUS_SCHEMA", "Expected repo_census.v1."))

    if source.get("schema_version") != "source_platform_profile.v1":
        issues.append(RealRepoIssue("error", "SOURCE_PROFILE_SCHEMA", "Expected source_platform_profile.v1."))

    if compat.get("schema_version") != "compatibility_profile.v1":
        issues.append(RealRepoIssue("error", "COMPAT_PROFILE_SCHEMA", "Expected compatibility_profile.v1."))

    if census.get("summary", {}).get("num_files", 0) <= 0:
        issues.append(RealRepoIssue("error", "NO_FILES", "Repo census found no files."))

    if source.get("source_runtime") == "unknown":
        issues.append(RealRepoIssue("warning", "SOURCE_RUNTIME_UNKNOWN", "Could not infer source runtime."))

    if not source.get("source_boards_detected"):
        issues.append(RealRepoIssue("warning", "SOURCE_BOARD_UNKNOWN", "Could not infer source board."))

    if compat.get("target_platform") != "v80_aved_2025_1_stub":
        issues.append(RealRepoIssue("error", "TARGET_PLATFORM_UNEXPECTED", "v0.0.11 should target v80_aved_2025_1_stub."))

    if compat.get("target_ecosystem") != "AVED":
        issues.append(RealRepoIssue("error", "TARGET_ECOSYSTEM_UNEXPECTED", "v0.0.11 should target AVED."))

    if compat.get("migration_status") != "profile_only":
        issues.append(RealRepoIssue("error", "MIGRATION_STATUS_UNEXPECTED", "v0.0.11 must remain profile_only."))

    required = compat.get("required_next_capabilities", [])
    if not required:
        issues.append(RealRepoIssue("warning", "NO_NEXT_CAPABILITIES", "Compatibility profile did not list next capabilities."))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return RealRepoValidationReport(
        status=status,
        issues=issues,
        summary={
            "repo_path": census.get("repo_path"),
            "num_files": census.get("summary", {}).get("num_files"),
            "roles": census.get("summary", {}).get("roles"),
            "source_runtime": source.get("source_runtime"),
            "source_boards_detected": source.get("source_boards_detected"),
            "source_memory_model": source.get("source_memory_model"),
            "complexity": source.get("complexity", {}).get("level"),
            "migration_status": compat.get("migration_status"),
            "target_platform": compat.get("target_platform"),
            "target_ecosystem": compat.get("target_ecosystem"),
            "required_next_capabilities": compat.get("required_next_capabilities"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate v0.0.11 real repo profile outputs")
    parser.add_argument("--census", required=True)
    parser.add_argument("--source-profile", required=True)
    parser.add_argument("--compatibility", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = validate(
        load_json(args.census),
        load_json(args.source_profile),
        load_json(args.compatibility),
    )
    report.save(args.out)

    print(f"[xporthls] Real repo profile validation written to: {args.out}")
    print(f"[xporthls] Real repo profile validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[5/7] Add orchestration runner"

cat > xporthls/realrepo/run_realrepo_profile_v011.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.repo_census import discover_repo, save_json as save_census_json
from xporthls.realrepo.source_platform_profiler import infer_source_profile, save_json as save_source_json
from xporthls.realrepo.compatibility_profiler import build_compatibility_profile, save_json as save_compat_json
from xporthls.realrepo.validate_realrepo_profile_v011 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.11 real repository profiling pipeline")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    census_path = out_dir / f"{args.case_id}_repo_census_v011.json"
    source_path = out_dir / f"{args.case_id}_source_platform_profile_v011.json"
    compat_path = out_dir / f"{args.case_id}_compatibility_profile_v011.json"
    validation_path = out_dir / f"{args.case_id}_realrepo_profile_report_v011.json"

    census = discover_repo(args.repo)
    save_census_json(str(census_path), census)

    source = infer_source_profile(census)
    save_source_json(str(source_path), source)

    compat = build_compatibility_profile(
        census=census,
        source_profile=source,
        target_platform=args.target_platform,
        target_ecosystem=args.target_ecosystem,
    )
    save_compat_json(str(compat_path), compat)

    report = validate(census, source, compat)
    report.save(str(validation_path))

    print(f"[xporthls] Repo census: {census_path}")
    print(f"[xporthls] Source platform profile: {source_path}")
    print(f"[xporthls] Compatibility profile: {compat_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Files: {census['summary']['num_files']}")
    print(f"[xporthls] Source runtime: {source['source_runtime']}")
    print(f"[xporthls] Source boards: {source['source_boards_detected']}")
    print(f"[xporthls] Source memory: {source['source_memory_model']}")
    print(f"[xporthls] Complexity: {source['complexity']['level']}")
    print(f"[xporthls] Migration status: {compat['migration_status']}")
    print(f"[xporthls] Required next capabilities: {compat['required_next_capabilities']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[6/7] Update README with concise real repo profiling usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Real repository profiling

XPortHLS can profile a real XRT/Vitis repository before attempting migration. This is used to identify source platforms, build files, XRT usage, HLS kernels, memory topology hints, connectivity files, and unsupported features.

Example:

```bash
python3 -m xporthls.realrepo.run_realrepo_profile_v011 \\
  --repo /mnt/data/xporthls_benchmarks/HiSparse \\
  --case-id hisparse \\
  --target-platform v80_aved_2025_1_stub \\
  --target-ecosystem AVED
```

The profiler writes:

```text
experiments/runs/hisparse_repo_census_v011.json
experiments/runs/hisparse_source_platform_profile_v011.json
experiments/runs/hisparse_compatibility_profile_v011.json
experiments/runs/hisparse_realrepo_profile_report_v011.json
```

The profiler is analysis-only. It does not generate an AVED project.
"""

if "## Real repository profiling" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[7/7] Create v0.0.11 replay script"

cat > add_realrepo_profiler_v011_replay.sh <<'EOT'
#!/usr/bin/env bash
set -e

HISPARSE_DIR="${HISPARSE_DIR:-/mnt/data/xporthls_benchmarks/HiSparse}"

echo "[v0.0.11] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py

echo "[v0.0.11] Ensure HiSparse checkout exists"

mkdir -p "$(dirname "$HISPARSE_DIR")"

if [ ! -d "$HISPARSE_DIR/.git" ]; then
  git clone --depth 1 https://github.com/cornell-zhang/HiSparse.git "$HISPARSE_DIR"
else
  git -C "$HISPARSE_DIR" checkout master
  git -C "$HISPARSE_DIR" pull --ff-only || true
fi

echo "[v0.0.11] Run real repository profiling"

python3 -m xporthls.realrepo.run_realrepo_profile_v011 \
  --repo "$HISPARSE_DIR" \
  --case-id hisparse \
  --target-platform v80_aved_2025_1_stub \
  --target-ecosystem AVED \
  --out-dir experiments/runs

python3 - <<'PY'
import json

census = json.load(open("experiments/runs/hisparse_repo_census_v011.json"))
source = json.load(open("experiments/runs/hisparse_source_platform_profile_v011.json"))
compat = json.load(open("experiments/runs/hisparse_compatibility_profile_v011.json"))
report = json.load(open("experiments/runs/hisparse_realrepo_profile_report_v011.json"))

print()
print("Census schema:", census["schema_version"])
print("Source profile schema:", source["schema_version"])
print("Compatibility schema:", compat["schema_version"])
print("Validation status:", report["status"])
print("Files:", census["summary"]["num_files"])
print("Roles:", census["summary"]["roles"])
print("Source runtime:", source["source_runtime"])
print("Boards:", source["source_boards_detected"])
print("Toolchains:", source["source_toolchains_detected"])
print("Memory model:", source["source_memory_model"])
print("Complexity:", source["complexity"]["level"])
print("Migration status:", compat["migration_status"])
print("Next capabilities:", compat["required_next_capabilities"])

assert census["schema_version"] == "repo_census.v1"
assert source["schema_version"] == "source_platform_profile.v1"
assert compat["schema_version"] == "compatibility_profile.v1"
assert report["status"] in {"pass", "pass_with_warnings"}
assert census["summary"]["num_files"] > 0
assert compat["target_platform"] == "v80_aved_2025_1_stub"
assert compat["target_ecosystem"] == "AVED"
assert compat["migration_status"] == "profile_only"
assert "U280" in source["source_boards_detected"] or source["source_runtime"] == "XRT"
PY

echo
echo "DONE."
EOT

chmod +x add_realrepo_profiler_v011_replay.sh

echo "[v0.0.11] Run replay"

./add_realrepo_profiler_v011_replay.sh

echo "[v0.0.11] Git status"

git status
