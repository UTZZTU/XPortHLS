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
