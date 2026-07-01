from __future__ import annotations

import os
import re
from pathlib import Path
from xporthls.ir.application_ir import ApplicationIR, SourceFile, XrtCall
from xporthls.scanner.xrt_semantic_extractor import extract_xrt_semantics
from xporthls.cases.case_config import load_case_config, validate_case_config


XRT_PATTERNS = {
    "xrt::device": re.compile(r"\bxrt::device\b"),
    "xrt::kernel": re.compile(r"\bxrt::kernel\b"),
    "xrt::bo": re.compile(r"\bxrt::bo\b"),
    "xrt::run": re.compile(r"\bxrt::run\b"),
    "bo.sync": re.compile(r"\.sync\s*\("),
    "kernel.group_id": re.compile(r"\.group_id\s*\("),
}

HLS_PRAGMA_PATTERN = re.compile(r"#\s*pragma\s+HLS")
FUNCTION_PATTERN = re.compile(
    r"^\s*(?:extern\s+\"C\"\s+)?(?:void|int|float|double|[\w:<>]+)\s+([A-Za-z_]\w*)\s*\("
)


def classify_file(path: Path) -> str:
    name = path.name.lower()
    suffix = path.suffix.lower()
    if name in {"makefile"} or suffix in {".mk"}:
        return "build_make"
    if suffix in {".cmake"} or name == "cmakelists.txt":
        return "build_cmake"
    if suffix in {".cpp", ".cc", ".cxx", ".c"}:
        return "source"
    if suffix in {".hpp", ".hh", ".h"}:
        return "header"
    if suffix in {".tcl"}:
        return "tcl"
    if suffix in {".cfg", ".ini"}:
        return "config"
    if suffix in {".json", ".yaml", ".yml"}:
        return "metadata"
    return "other"


def scan_repository(case_path: str) -> ApplicationIR:
    root = Path(case_path).resolve()
    if not root.exists():
        raise FileNotFoundError(f"Case path does not exist: {root}")

    case_cfg = load_case_config(str(root))
    ir = ApplicationIR(
        project=case_cfg.case_id,
        source_runtime=case_cfg.source_runtime,
        case_metadata=case_cfg.to_dict(),
    )

    for case_issue in validate_case_config(case_cfg, str(root)):
        if case_issue["severity"] == "error":
            ir.unknowns.append({
                "kind": "case_config",
                "code": case_issue["code"],
                "message": case_issue["message"]
            })
        else:
            ir.warnings.append(f'{case_issue["code"]}: {case_issue["message"]}')

    if case_cfg.golden:
        ir.test_entries.append({
            "kind": "golden",
            "source": "case.yaml",
            **case_cfg.golden,
        })

    if case_cfg.host_entry:
        ir.test_entries.append({
            "kind": "host_entry",
            "source": "case.yaml",
            "path": case_cfg.host_entry,
        })

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue

        rel = str(path.relative_to(root))
        kind = classify_file(path)
        ir.source_files.append(SourceFile(path=rel, kind=kind))

        if kind in {"build_make", "build_cmake"}:
            ir.build_targets.append({"file": rel, "kind": kind})

        if kind not in {"source", "header", "tcl", "config", "build_make", "build_cmake"}:
            continue

        try:
            text = path.read_text(encoding="utf-8", errors="ignore")
        except Exception as exc:
            ir.warnings.append(f"Could not read {rel}: {exc}")
            continue

        if kind in {"source", "header"}:
            semantic = extract_xrt_semantics(text, rel)
            ir.kernel_objects.extend(semantic.kernel_objects)
            ir.buffers.extend(semantic.buffers)
            ir.host_transfers.extend(semantic.host_transfers)
            ir.sync_operations.extend(semantic.sync_operations)
            ir.kernel_invocations.extend(semantic.kernel_invocations)
            ir.run_waits.extend(semantic.run_waits)
            ir.unknowns.extend(semantic.unknowns)

        for lineno, line in enumerate(text.splitlines(), start=1):
            for api, pattern in XRT_PATTERNS.items():
                if pattern.search(line):
                    ir.host_apis.append(XrtCall(file=rel, line=lineno, expression=line.strip(), api=api))

            if HLS_PRAGMA_PATTERN.search(line):
                ir.kernels.append({
                    "file": rel,
                    "line": lineno,
                    "evidence": line.strip(),
                    "kind": "hls_pragma_context"
                })

            match = FUNCTION_PATTERN.match(line)
            if match and kind in {"source", "header"}:
                name = match.group(1)
                if name not in {"main", "printf", "fprintf"}:
                    if "kernel" in rel.lower() or "hls" in rel.lower() or HLS_PRAGMA_PATTERN.search(text):
                        ir.kernels.append({
                            "file": rel,
                            "line": lineno,
                            "name": name,
                            "kind": "function_candidate"
                        })

    if not ir.host_apis:
        ir.warnings.append("No obvious XRT API calls found.")
    if not ir.kernels:
        ir.warnings.append("No obvious HLS kernel candidates found.")

    return ir
