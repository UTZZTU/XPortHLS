from __future__ import annotations

import hashlib
import json
import os
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


TEXT_SUFFIXES = {
    ".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hh", ".tcl", ".cfg", ".ini",
    ".mk", ".make", ".cmake", ".txt", ".md", ".yaml", ".yml", ".json", ".sh",
    ".py", ".csv", ".xdc", ".xml", ".log", ".rst"
}

DOC_SUFFIXES = {".md", ".txt", ".rst", ".pdf"}
CODE_SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp", ".hh"}
TCL_SUFFIXES = {".tcl"}
YAML_SUFFIXES = {".yaml", ".yml"}

IGNORE_DIR_NAMES = {
    ".git", "__pycache__", ".cache", ".vscode", ".idea",
    "node_modules", ".pytest_cache"
}

LARGE_TEXT_LIMIT_BYTES = 2_000_000
MAX_SNIPPETS_PER_KIND = 40
MAX_FILES_PER_INDEX = 200


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: str | Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def safe_rel(path: str | Path, root: str | Path) -> str:
    try:
        return str(Path(path).resolve().relative_to(Path(root).resolve()))
    except Exception:
        return str(path)


def is_text_candidate(path: Path) -> bool:
    return path.suffix.lower() in TEXT_SUFFIXES


def read_text_limited(path: Path) -> str:
    try:
        if path.stat().st_size > LARGE_TEXT_LIMIT_BYTES:
            return ""
        return path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return ""


def normalize_ws(s: str) -> str:
    return re.sub(r"\s+", " ", s).strip()


def collect_files(root: str | Path) -> list[Path]:
    root = Path(root)
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in IGNORE_DIR_NAMES]
        for name in filenames:
            p = Path(dirpath) / name
            if p.is_file():
                out.append(p)
    return sorted(out)


def line_snippets(text: str, patterns: list[str], max_count: int = 5) -> list[str]:
    snippets: list[str] = []
    lines = text.splitlines()
    lowered_patterns = [p.lower() for p in patterns]
    for idx, line in enumerate(lines):
        low = line.lower()
        if any(p in low for p in lowered_patterns):
            start = max(0, idx - 1)
            end = min(len(lines), idx + 2)
            snippet = " | ".join(normalize_ws(x) for x in lines[start:end] if normalize_ws(x))
            if snippet:
                snippets.append(snippet[:600])
            if len(snippets) >= max_count:
                break
    return snippets


def extract_function_candidates(text: str) -> list[str]:
    # intentionally conservative: enough for target reference census, not a full C++ parser
    names: set[str] = set()
    for m in re.finditer(
        r"(?:extern\s+\"C\"\s+)?(?:void|int|float|double|bool|ap_uint\s*<[^>]+>|[A-Za-z_]\w*(?:::\w+)?)\s+([A-Za-z_]\w*)\s*\(",
        text,
    ):
        name = m.group(1)
        if name not in {"if", "for", "while", "switch", "return", "sizeof"}:
            names.add(name)
    return sorted(names)[:80]


def parse_simple_yaml_key_values(text: str) -> dict[str, Any]:
    data: dict[str, Any] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or ":" not in stripped:
            continue
        if stripped.startswith("-"):
            continue
        k, v = stripped.split(":", 1)
        k = k.strip()
        v = v.strip().strip("'\"")
        if k and len(k) <= 80:
            data[k] = v
    return data


def file_record(path: Path, root: Path, include_sha: bool = False) -> dict[str, Any]:
    rec: dict[str, Any] = {
        "path": safe_rel(path, root),
        "suffix": path.suffix.lower(),
        "size_bytes": path.stat().st_size,
    }
    if include_sha:
        rec["sha256"] = sha256_file(path)
    return rec


def build_repository_summary(root: Path, files: list[Path]) -> dict[str, Any]:
    ext_counts = Counter(p.suffix.lower() or "<no_ext>" for p in files)
    dir_counts: Counter[str] = Counter()
    for p in files:
        rel = Path(safe_rel(p, root))
        first = rel.parts[0] if rel.parts else "."
        dir_counts[first] += 1

    return {
        "root": str(root),
        "root_name": root.name,
        "files_total": len(files),
        "directories_top_level": dict(sorted(dir_counts.items())),
        "extension_counts": dict(sorted(ext_counts.items())),
        "text_candidate_files": sum(1 for p in files if is_text_candidate(p)),
        "code_files": sum(1 for p in files if p.suffix.lower() in CODE_SUFFIXES),
        "tcl_files": sum(1 for p in files if p.suffix.lower() in TCL_SUFFIXES),
        "yaml_files": sum(1 for p in files if p.suffix.lower() in YAML_SUFFIXES),
        "documentation_files": sum(1 for p in files if p.suffix.lower() in DOC_SUFFIXES),
        "largest_files": [
            file_record(p, root)
            for p in sorted(files, key=lambda x: x.stat().st_size, reverse=True)[:20]
        ],
    }


def build_documentation_index(root: Path, files: list[Path]) -> dict[str, Any]:
    docs = [p for p in files if p.suffix.lower() in DOC_SUFFIXES]
    records: list[dict[str, Any]] = []

    important_terms = [
        "aved", "v80", "qdma", "hbm", "pc", "pseudo", "axi", "axilite", "axi-lite",
        "vivado", "bd", "pdi", "ami", "shuffler", "cdc", "wns", "performance",
        "correctness", "bug", "fix", "version"
    ]

    for p in docs[:MAX_FILES_PER_INDEX]:
        text = read_text_limited(p)
        lower = text.lower()
        records.append({
            **file_record(p, root, include_sha=True),
            "title_guess": p.stem,
            "matched_terms": sorted({t for t in important_terms if t in lower or t in str(p).lower()}),
            "snippet": normalize_ws(text[:800]) if text else "",
        })

    return {
        "num_documents": len(docs),
        "documents": records,
    }


def build_variant_index(root: Path, files: list[Path]) -> dict[str, Any]:
    variant_files = [
        p for p in files
        if p.name.lower() == "variant.yaml" or p.name.lower() == "variant.yml"
    ]
    variants: list[dict[str, Any]] = []

    for p in variant_files:
        text = read_text_limited(p)
        kv = parse_simple_yaml_key_values(text)
        rel = safe_rel(p, root)
        variant_root = str(Path(rel).parent)
        lower = text.lower()
        hbm_mentions = sorted(set(re.findall(r"hbm\d+", lower)))
        pc_mentions = sorted(set(re.findall(r"pc\d+", lower)))
        sk_mentions = sorted(set(re.findall(r"sk\d+", lower)))
        variants.append({
            "variant_root": variant_root,
            "variant_file": rel,
            "key_values_preview": dict(list(kv.items())[:50]),
            "hbm_mentions": hbm_mentions,
            "pc_mentions": pc_mentions,
            "sk_mentions": sk_mentions,
            "contains_shared_sk": "shared" in lower and "sk" in lower,
            "raw_sha256": sha256_file(p),
        })

    return {
        "num_variants": len(variants),
        "variants": variants[:MAX_FILES_PER_INDEX],
    }


def build_host_runtime_pattern(root: Path, files: list[Path]) -> dict[str, Any]:
    host_files = [
        p for p in files
        if p.suffix.lower() in CODE_SUFFIXES and (
            "host" in safe_rel(p, root).lower()
            or "controller" in p.name.lower()
            or "benchmark" in p.name.lower()
        )
    ]

    patterns = {
        "qdma": ["qdma", "QdmaDevice", "/dev/qdma"],
        "axi_lite": ["axilite", "axi-lite", "AxiLite", "AxiLiteBus"],
        "ap_ctrl": ["ap_ctrl", "AP_CTRL", "start", "done", "idle"],
        "hbm_pc_addr": ["HBM_PC_ADDR", "hbm_pc", "pc_addr", "pseudo", "0x4000000000"],
        "device_node": ["/dev/qdma", "/dev/"],
        "verification": ["verify", "golden", "compare", "mismatch", "PASS", "FAIL"],
    }

    evidence: dict[str, list[dict[str, Any]]] = {k: [] for k in patterns}
    function_index: list[dict[str, Any]] = []

    for p in host_files:
        text = read_text_limited(p)
        if not text:
            continue
        lower = text.lower()

        funcs = extract_function_candidates(text)
        if funcs:
            function_index.append({
                "file": safe_rel(p, root),
                "functions": funcs,
            })

        for kind, pats in patterns.items():
            if any(x.lower() in lower for x in pats):
                evidence[kind].append({
                    "file": safe_rel(p, root),
                    "snippets": line_snippets(text, pats, max_count=4),
                })

    return {
        "num_host_files": len(host_files),
        "host_files": [file_record(p, root) for p in host_files[:MAX_FILES_PER_INDEX]],
        "function_index": function_index[:MAX_FILES_PER_INDEX],
        "evidence": {k: v[:MAX_SNIPPETS_PER_KIND] for k, v in evidence.items()},
        "summary": {
            "qdma_evidence_count": len(evidence["qdma"]),
            "axi_lite_evidence_count": len(evidence["axi_lite"]),
            "ap_ctrl_evidence_count": len(evidence["ap_ctrl"]),
            "hbm_pc_addr_evidence_count": len(evidence["hbm_pc_addr"]),
            "device_node_evidence_count": len(evidence["device_node"]),
            "verification_evidence_count": len(evidence["verification"]),
        },
    }


def build_hls_ip_packaging_pattern(root: Path, files: list[Path]) -> dict[str, Any]:
    hls_files = [
        p for p in files
        if p.suffix.lower() in CODE_SUFFIXES and (
            "hls" in safe_rel(p, root).lower()
            or "spmv" in p.name.lower()
            or "kernel" in p.name.lower()
        )
    ]
    cfg_files = [
        p for p in files
        if p.suffix.lower() in {".cfg", ".ini", ".tcl", ".sh", ".mk", ".make"}
        and ("hls" in safe_rel(p, root).lower() or "vitis" in read_text_limited(p).lower()[:4000] or "v++" in read_text_limited(p).lower()[:4000])
    ]

    interface_patterns = {
        "m_axi": ["#pragma HLS INTERFACE m_axi", "interface m_axi"],
        "axis": ["#pragma HLS INTERFACE axis", "hls::stream", "axis"],
        "s_axilite": ["#pragma HLS INTERFACE s_axilite", "s_axilite"],
        "ap_ctrl": ["ap_ctrl_hs", "ap_ctrl_none", "ap_ctrl_chain"],
        "dataflow": ["#pragma HLS DATAFLOW", "dataflow"],
        "ap_uint_packed_word": ["ap_uint<256>", "ap_uint<512>", "ap_uint <256>", "ap_uint <512>"],
    }

    evidence: dict[str, list[dict[str, Any]]] = {k: [] for k in interface_patterns}
    function_index: list[dict[str, Any]] = []

    for p in hls_files:
        text = read_text_limited(p)
        if not text:
            continue
        lower = text.lower()
        funcs = extract_function_candidates(text)
        if funcs:
            function_index.append({
                "file": safe_rel(p, root),
                "functions": funcs,
            })
        for kind, pats in interface_patterns.items():
            if any(x.lower() in lower for x in pats):
                evidence[kind].append({
                    "file": safe_rel(p, root),
                    "snippets": line_snippets(text, pats, max_count=4),
                })

    packaging_evidence: list[dict[str, Any]] = []
    for p in cfg_files[:MAX_FILES_PER_INDEX]:
        text = read_text_limited(p)
        lower = text.lower()
        matched = []
        for term in ["flow_target=vivado", "ip_catalog", "v++", "vitis-run", "package.output", "csim", "csynth"]:
            if term in lower:
                matched.append(term)
        if matched:
            packaging_evidence.append({
                "file": safe_rel(p, root),
                "matched_terms": matched,
                "snippets": line_snippets(text, matched, max_count=5),
            })

    return {
        "num_hls_candidate_files": len(hls_files),
        "hls_candidate_files": [file_record(p, root) for p in hls_files[:MAX_FILES_PER_INDEX]],
        "num_hls_config_or_script_files": len(cfg_files),
        "function_index": function_index[:MAX_FILES_PER_INDEX],
        "interface_evidence": {k: v[:MAX_SNIPPETS_PER_KIND] for k, v in evidence.items()},
        "packaging_evidence": packaging_evidence[:MAX_SNIPPETS_PER_KIND],
        "summary": {
            "m_axi_evidence_count": len(evidence["m_axi"]),
            "axis_evidence_count": len(evidence["axis"]),
            "s_axilite_evidence_count": len(evidence["s_axilite"]),
            "ap_ctrl_evidence_count": len(evidence["ap_ctrl"]),
            "dataflow_evidence_count": len(evidence["dataflow"]),
            "packed_word_evidence_count": len(evidence["ap_uint_packed_word"]),
            "packaging_evidence_count": len(packaging_evidence),
        },
    }


def build_vivado_aved_project_pattern(root: Path, files: list[Path]) -> dict[str, Any]:
    tcl_files = [p for p in files if p.suffix.lower() == ".tcl"]
    create_design = [p for p in tcl_files if p.name == "create_design.tcl"]
    create_bd = [p for p in tcl_files if p.name == "create_bd_design.tcl"]
    aved_files = [p for p in files if "aved" in safe_rel(p, root).lower()]

    evidence_terms = [
        "create_project", "create_bd_design", "source", "ip_repo_paths", "update_ip_catalog",
        "write_device_image", "pdi", "ami_tool", "validate_bd_design", "make_wrapper",
        "xcv80", "amd_v80", "v80"
    ]

    records: list[dict[str, Any]] = []
    for p in tcl_files[:MAX_FILES_PER_INDEX]:
        text = read_text_limited(p)
        lower = text.lower()
        matched = [t for t in evidence_terms if t in lower]
        if matched or "aved" in safe_rel(p, root).lower():
            records.append({
                "file": safe_rel(p, root),
                "matched_terms": matched,
                "snippets": line_snippets(text, matched or ["create", "bd"], max_count=5),
            })

    return {
        "num_tcl_files": len(tcl_files),
        "num_aved_path_files": len(aved_files),
        "create_design_tcl_count": len(create_design),
        "create_bd_design_tcl_count": len(create_bd),
        "create_design_files": [file_record(p, root, include_sha=True) for p in create_design[:MAX_FILES_PER_INDEX]],
        "create_bd_design_files": [file_record(p, root, include_sha=True) for p in create_bd[:MAX_FILES_PER_INDEX]],
        "tcl_evidence": records[:MAX_SNIPPETS_PER_KIND],
    }


def build_bd_tcl_pattern(root: Path, files: list[Path]) -> dict[str, Any]:
    bd_tcls = [p for p in files if p.name == "create_bd_design.tcl"]
    cell_counter: Counter[str] = Counter()
    command_counter: Counter[str] = Counter()
    connection_records: list[dict[str, Any]] = []
    cell_records: list[dict[str, Any]] = []

    command_terms = [
        "create_bd_cell", "connect_bd_intf_net", "connect_bd_net", "assign_bd_address",
        "set_property", "get_bd_intf_pins", "get_bd_pins", "create_bd_design"
    ]

    for p in bd_tcls:
        text = read_text_limited(p)
        for term in command_terms:
            count = len(re.findall(re.escape(term), text))
            if count:
                command_counter[term] += count

        for m in re.finditer(r"create_bd_cell\s+(?:-[^\n]+?\s+)*([A-Za-z0-9_:\.\-/]+)\s+([A-Za-z0-9_./-]+)", text):
            cell_type = m.group(1)
            cell_name = m.group(2)
            cell_counter[cell_type] += 1
            if len(cell_records) < MAX_FILES_PER_INDEX:
                cell_records.append({
                    "file": safe_rel(p, root),
                    "cell_type": cell_type,
                    "cell_name": cell_name,
                })

        for line in text.splitlines():
            if "connect_bd_intf_net" in line or "assign_bd_address" in line:
                if len(connection_records) < MAX_FILES_PER_INDEX:
                    connection_records.append({
                        "file": safe_rel(p, root),
                        "line": normalize_ws(line)[:800],
                    })

    return {
        "create_bd_design_tcl_count": len(bd_tcls),
        "command_counts": dict(sorted(command_counter.items())),
        "cell_type_counts": dict(cell_counter.most_common(50)),
        "cell_records": cell_records,
        "connection_and_address_records": connection_records,
    }


def build_hbm_pc_address_map(root: Path, files: list[Path]) -> dict[str, Any]:
    patterns = {
        "hbm_base_0x4000000000": ["0x4000000000", "4000000000"],
        "hbm_stride_0x80000000": ["0x80000000", "80000000"],
        "pc_stride_0x40000000": ["0x40000000", "40000000"],
        "hbm_pc_addr_symbol": ["HBM_PC_ADDR", "hbm_pc_addr", "pc_addr"],
        "hbm_index": ["hbm_index", "hbm_idx", "HBM"],
        "pc_index": ["pc_index", "pc_idx", "PC"],
        "slot_bytes": ["slot_bytes", "SLOT_BYTES", "byte_offset", "offset"],
    }

    candidate_files = [
        p for p in files
        if is_text_candidate(p)
        and (
            "hbm" in safe_rel(p, root).lower()
            or "variant" in safe_rel(p, root).lower()
            or "host" in safe_rel(p, root).lower()
            or "controller" in p.name.lower()
            or p.suffix.lower() in YAML_SUFFIXES
        )
    ]

    evidence: dict[str, list[dict[str, Any]]] = {k: [] for k in patterns}
    numeric_constants: Counter[str] = Counter()

    for p in candidate_files:
        text = read_text_limited(p)
        if not text:
            continue
        lower = text.lower()

        for const in re.findall(r"0x[0-9a-fA-F]{6,16}", text):
            if any(x in const.lower() for x in ["40000000", "80000000", "4000000000"]):
                numeric_constants[const] += 1

        for kind, pats in patterns.items():
            if any(x.lower() in lower for x in pats):
                evidence[kind].append({
                    "file": safe_rel(p, root),
                    "snippets": line_snippets(text, pats, max_count=4),
                })

    hbm_mentions = Counter()
    pc_mentions = Counter()
    for p in candidate_files:
        rel = safe_rel(p, root).lower()
        text = read_text_limited(p).lower()
        material = rel + "\n" + text[:20000]
        for m in re.findall(r"hbm\d+", material):
            hbm_mentions[m] += 1
        for m in re.findall(r"pc\d+", material):
            pc_mentions[m] += 1

    return {
        "candidate_files": [file_record(p, root) for p in candidate_files[:MAX_FILES_PER_INDEX]],
        "numeric_constants": dict(numeric_constants.most_common(40)),
        "hbm_mentions": dict(hbm_mentions.most_common(64)),
        "pc_mentions": dict(pc_mentions.most_common(16)),
        "evidence": {k: v[:MAX_SNIPPETS_PER_KIND] for k, v in evidence.items()},
        "summary": {
            "candidate_file_count": len(candidate_files),
            "hbm_pc_addr_evidence_count": len(evidence["hbm_pc_addr_symbol"]),
            "hbm_base_evidence_count": len(evidence["hbm_base_0x4000000000"]),
            "hbm_stride_evidence_count": len(evidence["hbm_stride_0x80000000"]),
            "pc_stride_evidence_count": len(evidence["pc_stride_0x40000000"]),
            "slot_bytes_evidence_count": len(evidence["slot_bytes"]),
        },
    }


def build_stream_connection_pattern(root: Path, files: list[Path]) -> dict[str, Any]:
    candidate_files = [
        p for p in files
        if is_text_candidate(p)
        and (
            p.suffix.lower() in {".tcl", ".cpp", ".h", ".hpp", ".cfg", ".yaml", ".yml"}
            and (
                "stream" in safe_rel(p, root).lower()
                or "axis" in safe_rel(p, root).lower()
                or "bd" in safe_rel(p, root).lower()
                or "hls" in safe_rel(p, root).lower()
                or p.name == "create_bd_design.tcl"
            )
        )
    ]

    terms = [
        "connect_bd_intf_net", "M_AXIS", "S_AXIS", "axis", "hls::stream",
        "axis_duplicate", "axis_merge", "stream"
    ]

    evidence: list[dict[str, Any]] = []
    counts = Counter()
    for p in candidate_files:
        text = read_text_limited(p)
        lower = text.lower()
        matched = []
        for term in terms:
            count = lower.count(term.lower())
            if count:
                counts[term] += count
                matched.append(term)
        if matched and len(evidence) < MAX_SNIPPETS_PER_KIND:
            evidence.append({
                "file": safe_rel(p, root),
                "matched_terms": matched,
                "snippets": line_snippets(text, matched, max_count=5),
            })

    return {
        "candidate_file_count": len(candidate_files),
        "term_counts": dict(sorted(counts.items())),
        "evidence": evidence,
        "summary": {
            "connect_bd_intf_net_count": counts.get("connect_bd_intf_net", 0),
            "axis_term_count": counts.get("axis", 0) + counts.get("M_AXIS", 0) + counts.get("S_AXIS", 0),
            "hls_stream_count": counts.get("hls::stream", 0),
            "axis_duplicate_count": counts.get("axis_duplicate", 0),
            "axis_merge_count": counts.get("axis_merge", 0),
        },
    }


def build_manual_operation_trace(root: Path, files: list[Path], vivado: dict[str, Any], bd: dict[str, Any]) -> dict[str, Any]:
    # These are inferred from repeatable target-side Tcl/script evidence, not from LLM.
    operations = []

    command_counts = bd.get("command_counts", {})
    if vivado.get("create_design_tcl_count", 0) > 0:
        operations.append({
            "operation": "create_or_reuse_aved_vivado_project_template",
            "evidence_type": "tcl",
            "evidence_count": vivado.get("create_design_tcl_count", 0),
            "migration_relevance": "GAP-PLATFORM-001",
        })

    if command_counts.get("create_bd_cell", 0) > 0:
        operations.append({
            "operation": "instantiate_hls_ip_in_block_design",
            "evidence_type": "create_bd_cell",
            "evidence_count": command_counts.get("create_bd_cell", 0),
            "migration_relevance": "GAP-HLS-INTERFACE-001",
        })

    if command_counts.get("connect_bd_intf_net", 0) > 0:
        operations.append({
            "operation": "connect_axis_and_memory_interfaces_in_bd",
            "evidence_type": "connect_bd_intf_net",
            "evidence_count": command_counts.get("connect_bd_intf_net", 0),
            "migration_relevance": "GAP-STREAM-AXIS-001",
        })

    if command_counts.get("assign_bd_address", 0) > 0:
        operations.append({
            "operation": "assign_vivado_bd_address_space",
            "evidence_type": "assign_bd_address",
            "evidence_count": command_counts.get("assign_bd_address", 0),
            "migration_relevance": "GAP-MEM-HBM-001",
        })

    hls_cfg_or_scripts = [
        p for p in files
        if is_text_candidate(p)
        and any(term in read_text_limited(p).lower()[:4000] for term in ["ip_catalog", "flow_target=vivado", "vitis-run", "v++"])
    ]
    if hls_cfg_or_scripts:
        operations.append({
            "operation": "package_hls_cxx_as_vivado_ip",
            "evidence_type": "hls_config_or_script",
            "evidence_count": len(hls_cfg_or_scripts),
            "migration_relevance": "GAP-HLS-INTERFACE-001",
        })

    return {
        "schema_version": "manual_operation_trace.v1",
        "description": "Deterministically inferred manual/target-side operations from Tcl/scripts and target reference repository structure.",
        "operations": operations,
        "notes": [
            "These operations are target reference evidence, not direct contract mutations.",
            "They should become source-target pattern candidates in v0.0.26.",
        ],
    }


def build_known_correctness_fixes(root: Path, files: list[Path]) -> dict[str, Any]:
    candidate_files = [
        p for p in files
        if is_text_candidate(p)
        and (
            p.suffix.lower() in {".md", ".txt", ".cpp", ".h", ".hpp", ".tcl", ".log"}
            or "change" in p.name.lower()
            or "report" in p.name.lower()
            or "fix" in p.name.lower()
        )
    ]

    correctness_terms = [
        "shuffler", "arbiter", "arbitration", "dependency", "dependence",
        "version", "bug", "fix", "correctness", "error", "fail", "resend",
        "payload", "raw dependency", "latency"
    ]

    entries: list[dict[str, Any]] = []
    shuffler_entries = []
    for p in candidate_files:
        text = read_text_limited(p)
        lower = text.lower()
        if any(t in lower for t in correctness_terms):
            rec = {
                "file": safe_rel(p, root),
                "matched_terms": sorted({t for t in correctness_terms if t in lower}),
                "snippets": line_snippets(text, correctness_terms, max_count=6),
            }
            entries.append(rec)
            if "shuffler" in lower or "arbiter" in lower or "resend" in lower or "payload" in lower:
                shuffler_entries.append(rec)

    classified: list[dict[str, Any]] = []
    if shuffler_entries:
        classified.append({
            "failure_type": "F_VERSION_CORRECTNESS",
            "title": "Shuffler / arbitration / dependency related correctness fix",
            "classification": "version_or_toolchain_induced_correctness_fix",
            "is_optimization": False,
            "migration_relevance": [
                "GAP-STREAM-AXIS-001",
                "GAP-HLS-INTERFACE-001",
            ],
            "evidence": shuffler_entries[:MAX_SNIPPETS_PER_KIND],
            "notes": [
                "Classified as correctness, not PPA optimization.",
                "Must be validated by build/simulation/run evidence before becoming an automatic resolver rule.",
            ],
        })

    return {
        "schema_version": "known_correctness_fixes.v1",
        "candidate_evidence_count": len(entries),
        "classified_fixes": classified,
        "unclassified_evidence": entries[:MAX_SNIPPETS_PER_KIND],
        "summary": {
            "has_f_version_correctness": any(x.get("failure_type") == "F_VERSION_CORRECTNESS" for x in classified),
            "shuffler_related_evidence_count": len(shuffler_entries),
        },
    }


def build_optimization_notes(root: Path, files: list[Path]) -> dict[str, Any]:
    terms = ["cdc", "wns", "qor", "timing", "throughput", "gb/s", "gops", "performance", "utilization", "latency"]
    candidate_files = [p for p in files if is_text_candidate(p) and p.suffix.lower() in {".md", ".txt", ".csv", ".log", ".rpt"}]
    evidence = []
    counts = Counter()

    for p in candidate_files:
        text = read_text_limited(p)
        lower = text.lower()
        matched = []
        for t in terms:
            if t in lower:
                counts[t] += lower.count(t)
                matched.append(t)
        if matched and len(evidence) < MAX_SNIPPETS_PER_KIND:
            evidence.append({
                "file": safe_rel(p, root),
                "matched_terms": sorted(set(matched)),
                "snippets": line_snippets(text, matched, max_count=4),
            })

    return {
        "schema_version": "optimization_notes.v1",
        "description": "Performance/timing/CDC/QoR notes are recorded but not treated as correctness requirements unless separately classified.",
        "term_counts": dict(sorted(counts.items())),
        "evidence": evidence,
    }


def build_target_reference_ir(
    target_root: str | Path,
    case_id: str = "spmv_on_v80",
    target_name: str = "SPMV-on-V80",
) -> dict[str, Any]:
    root = Path(target_root).resolve()
    files = collect_files(root)

    repo_summary = build_repository_summary(root, files)
    documentation_index = build_documentation_index(root, files)
    variant_index = build_variant_index(root, files)
    host_runtime_pattern = build_host_runtime_pattern(root, files)
    hls_ip_packaging_pattern = build_hls_ip_packaging_pattern(root, files)
    vivado_aved_project_pattern = build_vivado_aved_project_pattern(root, files)
    bd_tcl_pattern = build_bd_tcl_pattern(root, files)
    hbm_pc_address_map = build_hbm_pc_address_map(root, files)
    stream_connection_pattern = build_stream_connection_pattern(root, files)
    manual_operation_trace = build_manual_operation_trace(root, files, vivado_aved_project_pattern, bd_tcl_pattern)
    known_correctness_fixes = build_known_correctness_fixes(root, files)
    optimization_notes = build_optimization_notes(root, files)

    facts_digest_material = {
        "repository_summary": repo_summary,
        "variant_count": variant_index.get("num_variants"),
        "host_summary": host_runtime_pattern.get("summary"),
        "hls_summary": hls_ip_packaging_pattern.get("summary"),
        "vivado_summary": {
            "create_design_tcl_count": vivado_aved_project_pattern.get("create_design_tcl_count"),
            "create_bd_design_tcl_count": vivado_aved_project_pattern.get("create_bd_design_tcl_count"),
        },
        "bd_command_counts": bd_tcl_pattern.get("command_counts"),
        "memory_summary": hbm_pc_address_map.get("summary"),
        "stream_summary": stream_connection_pattern.get("summary"),
        "correctness_summary": known_correctness_fixes.get("summary"),
    }

    ir = {
        "schema_version": "target_reference_ir.v1",
        "xporthls_version": "v0.0.24",
        "case_id": case_id,
        "target_reference_name": target_name,
        "created_at_utc": utc_now(),
        "target_reference_role": "Target Reference / Golden Reference",
        "migration_direction": "XRT->AVED",
        "target_ecosystem": "AVED",
        "target_board": "V80",
        "source_case_relationship": {
            "source_case_id": "hisparse_u280_profile",
            "source_runtime": "XRT",
            "source_board": "U280",
            "purpose": "Use target reference evidence to learn general XRT->AVED migration patterns, not to hardcode one case.",
        },
        "repository_summary": repo_summary,
        "documentation_index": documentation_index,
        "variant_index": variant_index,
        "host_runtime_pattern": host_runtime_pattern,
        "vivado_aved_project_pattern": vivado_aved_project_pattern,
        "bd_tcl_pattern": bd_tcl_pattern,
        "hls_ip_packaging_pattern": hls_ip_packaging_pattern,
        "axi_lite_register_pattern": {
            "schema_version": "axi_lite_register_pattern.v1",
            "derived_from": "host_runtime_pattern + HLS s_axilite evidence",
            "evidence": {
                "host_axi_lite": host_runtime_pattern.get("evidence", {}).get("axi_lite", []),
                "host_ap_ctrl": host_runtime_pattern.get("evidence", {}).get("ap_ctrl", []),
                "hls_s_axilite": hls_ip_packaging_pattern.get("interface_evidence", {}).get("s_axilite", []),
                "hls_ap_ctrl": hls_ip_packaging_pattern.get("interface_evidence", {}).get("ap_ctrl", []),
            },
        },
        "qdma_transfer_pattern": {
            "schema_version": "qdma_transfer_pattern.v1",
            "derived_from": "host_runtime_pattern",
            "evidence": host_runtime_pattern.get("evidence", {}).get("qdma", []),
            "device_node_evidence": host_runtime_pattern.get("evidence", {}).get("device_node", []),
        },
        "hbm_pc_address_map": hbm_pc_address_map,
        "stream_connection_pattern": stream_connection_pattern,
        "manual_operation_trace": manual_operation_trace,
        "known_correctness_fixes": known_correctness_fixes,
        "optimization_notes": optimization_notes,
        "trust_boundary": {
            "facts_extracted_by": "deterministic target reference intake",
            "llm_used": False,
            "llm_annotations_allowed": False,
            "contract_modified": False,
            "migration_allowed_modified": False,
            "generator_unlocked": False,
            "target_reference_is_authoritative_for_generalization": False,
            "target_reference_requires_validation_before_resolver_rule": True,
        },
        "summary": {
            "files_total": repo_summary.get("files_total"),
            "documentation_files": repo_summary.get("documentation_files"),
            "variant_count": variant_index.get("num_variants"),
            "host_qdma_evidence_count": host_runtime_pattern.get("summary", {}).get("qdma_evidence_count"),
            "host_axi_lite_evidence_count": host_runtime_pattern.get("summary", {}).get("axi_lite_evidence_count"),
            "host_ap_ctrl_evidence_count": host_runtime_pattern.get("summary", {}).get("ap_ctrl_evidence_count"),
            "hls_m_axi_evidence_count": hls_ip_packaging_pattern.get("summary", {}).get("m_axi_evidence_count"),
            "hls_axis_evidence_count": hls_ip_packaging_pattern.get("summary", {}).get("axis_evidence_count"),
            "hls_s_axilite_evidence_count": hls_ip_packaging_pattern.get("summary", {}).get("s_axilite_evidence_count"),
            "hls_packaging_evidence_count": hls_ip_packaging_pattern.get("summary", {}).get("packaging_evidence_count"),
            "create_design_tcl_count": vivado_aved_project_pattern.get("create_design_tcl_count"),
            "create_bd_design_tcl_count": vivado_aved_project_pattern.get("create_bd_design_tcl_count"),
            "bd_connect_bd_intf_net_count": bd_tcl_pattern.get("command_counts", {}).get("connect_bd_intf_net", 0),
            "bd_assign_bd_address_count": bd_tcl_pattern.get("command_counts", {}).get("assign_bd_address", 0),
            "hbm_pc_addr_evidence_count": hbm_pc_address_map.get("summary", {}).get("hbm_pc_addr_evidence_count"),
            "stream_axis_term_count": stream_connection_pattern.get("summary", {}).get("axis_term_count"),
            "has_f_version_correctness": known_correctness_fixes.get("summary", {}).get("has_f_version_correctness"),
            "llm_used": False,
            "contract_modified": False,
            "generator_unlock_allowed": False,
        },
        "facts_digest": sha256_text(json.dumps(facts_digest_material, sort_keys=True, ensure_ascii=False)),
        "llm_annotations": [],
    }

    return ir


def save_json(path: str | Path, obj: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
