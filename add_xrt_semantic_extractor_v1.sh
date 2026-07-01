#!/usr/bin/env bash
set -e

echo "[1/6] Add XRT semantic extractor v1"

cat > xporthls/scanner/xrt_semantic_extractor.py <<'EOT'
from __future__ import annotations

import re
from dataclasses import dataclass, asdict, field
from typing import Any


@dataclass
class XrtSemanticResult:
    kernel_objects: list[dict[str, Any]] = field(default_factory=list)
    buffers: list[dict[str, Any]] = field(default_factory=list)
    host_transfers: list[dict[str, Any]] = field(default_factory=list)
    sync_operations: list[dict[str, Any]] = field(default_factory=list)
    kernel_invocations: list[dict[str, Any]] = field(default_factory=list)
    run_waits: list[dict[str, Any]] = field(default_factory=list)
    unknowns: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


KERNEL_OBJECT_RE = re.compile(
    r"(?:auto|xrt::kernel)\s+([A-Za-z_]\w*)\s*=\s*xrt::kernel\s*\((.*)\)\s*;"
)

# Example:
# auto bo_in1 = xrt::bo(device, n * sizeof(int), kernel.group_id(0));
BO_RE = re.compile(
    r"(?:auto|xrt::bo)\s+([A-Za-z_]\w*)\s*=\s*xrt::bo\s*\((.*)\)\s*;"
)

GROUP_ID_RE = re.compile(
    r"([A-Za-z_]\w*)\.group_id\s*\(\s*([0-9]+)\s*\)"
)

WRITE_RE = re.compile(
    r"([A-Za-z_]\w*)\.write\s*\((.*)\)\s*;"
)

READ_RE = re.compile(
    r"([A-Za-z_]\w*)\.read\s*\((.*)\)\s*;"
)

SYNC_RE = re.compile(
    r"([A-Za-z_]\w*)\.sync\s*\(\s*(XCL_BO_SYNC_BO_TO_DEVICE|XCL_BO_SYNC_BO_FROM_DEVICE)\s*\)\s*;"
)

# Example:
# auto run = kernel(bo_in1, bo_in2, bo_out, n);
KERNEL_CALL_RE = re.compile(
    r"(?:auto\s+)?([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*\((.*)\)\s*;"
)

RUN_WAIT_RE = re.compile(
    r"([A-Za-z_]\w*)\.wait\s*\(\s*\)\s*;"
)


def _split_top_level_args(arg_text: str) -> list[str]:
    args: list[str] = []
    cur: list[str] = []
    depth = 0

    for ch in arg_text:
        if ch in "([{":
            depth += 1
            cur.append(ch)
        elif ch in ")]}":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            item = "".join(cur).strip()
            if item:
                args.append(item)
            cur = []
        else:
            cur.append(ch)

    item = "".join(cur).strip()
    if item:
        args.append(item)

    return args


def _strip_quotes(text: str) -> str:
    t = text.strip()
    if len(t) >= 2 and ((t[0] == '"' and t[-1] == '"') or (t[0] == "'" and t[-1] == "'")):
        return t[1:-1]
    return t


def extract_xrt_semantics(text: str, file_path: str) -> XrtSemanticResult:
    result = XrtSemanticResult()

    known_kernel_vars: dict[str, str] = {}
    known_buffer_vars: set[str] = set()
    known_run_vars: set[str] = set()

    lines = text.splitlines()

    for lineno, raw_line in enumerate(lines, start=1):
        line = raw_line.strip()
        if not line or line.startswith("//"):
            continue

        kernel_match = KERNEL_OBJECT_RE.search(line)
        if kernel_match:
            var_name = kernel_match.group(1)
            args = _split_top_level_args(kernel_match.group(2))
            kernel_name = None
            if args:
                last_arg = args[-1]
                if last_arg.startswith('"') or last_arg.startswith("'"):
                    kernel_name = _strip_quotes(last_arg)

            known_kernel_vars[var_name] = kernel_name or var_name
            result.kernel_objects.append({
                "file": file_path,
                "line": lineno,
                "var": var_name,
                "kernel_name": kernel_name,
                "args": args,
                "evidence": line
            })
            continue

        bo_match = BO_RE.search(line)
        if bo_match:
            bo_name = bo_match.group(1)
            args = _split_top_level_args(bo_match.group(2))
            size_expr = args[1] if len(args) >= 2 else None
            group_id = None
            group_kernel_var = None

            for arg in args:
                gid_match = GROUP_ID_RE.search(arg)
                if gid_match:
                    group_kernel_var = gid_match.group(1)
                    group_id = int(gid_match.group(2))

            known_buffer_vars.add(bo_name)
            result.buffers.append({
                "file": file_path,
                "line": lineno,
                "name": bo_name,
                "size_expr": size_expr,
                "group_id": group_id,
                "group_kernel_var": group_kernel_var,
                "allocation_args": args,
                "evidence": line
            })
            continue

        write_match = WRITE_RE.search(line)
        if write_match:
            bo_name = write_match.group(1)
            args = _split_top_level_args(write_match.group(2))
            result.host_transfers.append({
                "file": file_path,
                "line": lineno,
                "buffer": bo_name,
                "operation": "write",
                "host_expr": args[0] if args else None,
                "args": args,
                "evidence": line
            })
            continue

        read_match = READ_RE.search(line)
        if read_match:
            bo_name = read_match.group(1)
            args = _split_top_level_args(read_match.group(2))
            result.host_transfers.append({
                "file": file_path,
                "line": lineno,
                "buffer": bo_name,
                "operation": "read",
                "host_expr": args[0] if args else None,
                "args": args,
                "evidence": line
            })
            continue

        sync_match = SYNC_RE.search(line)
        if sync_match:
            bo_name = sync_match.group(1)
            sync_flag = sync_match.group(2)
            direction = "host_to_device" if sync_flag == "XCL_BO_SYNC_BO_TO_DEVICE" else "device_to_host"
            result.sync_operations.append({
                "file": file_path,
                "line": lineno,
                "buffer": bo_name,
                "sync_flag": sync_flag,
                "direction": direction,
                "evidence": line
            })
            continue

        call_match = KERNEL_CALL_RE.search(line)
        if call_match:
            run_var = call_match.group(1)
            kernel_var = call_match.group(2)
            call_args = _split_top_level_args(call_match.group(3))

            if kernel_var in known_kernel_vars:
                known_run_vars.add(run_var)
                result.kernel_invocations.append({
                    "file": file_path,
                    "line": lineno,
                    "run_var": run_var,
                    "kernel_var": kernel_var,
                    "kernel_name": known_kernel_vars.get(kernel_var),
                    "args": call_args,
                    "buffer_args": [a for a in call_args if a in known_buffer_vars],
                    "scalar_args": [a for a in call_args if a not in known_buffer_vars],
                    "evidence": line
                })
            continue

        wait_match = RUN_WAIT_RE.search(line)
        if wait_match:
            run_var = wait_match.group(1)
            result.run_waits.append({
                "file": file_path,
                "line": lineno,
                "run_var": run_var,
                "known_run": run_var in known_run_vars,
                "evidence": line
            })
            continue

    # Add lightweight unknowns for incomplete facts.
    for buf in result.buffers:
        if buf.get("size_expr") is None:
            result.unknowns.append({
                "kind": "buffer_size",
                "file": buf["file"],
                "line": buf["line"],
                "name": buf["name"],
                "reason": "Could not extract xrt::bo size expression."
            })
        if buf.get("group_id") is None:
            result.unknowns.append({
                "kind": "buffer_group_id",
                "file": buf["file"],
                "line": buf["line"],
                "name": buf["name"],
                "reason": "Could not extract kernel.group_id(N)."
            })

    return result
EOT

echo "[2/6] Update ApplicationIR dataclass"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/ir/application_ir.py")
text = path.read_text(encoding="utf-8")

old = '''    buffers: list[dict[str, Any]] = field(default_factory=list)
    memory_groups: list[dict[str, Any]] = field(default_factory=list)
    build_targets: list[dict[str, Any]] = field(default_factory=list)
    test_entries: list[dict[str, Any]] = field(default_factory=list)
    connectivity: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
'''

new = '''    buffers: list[dict[str, Any]] = field(default_factory=list)
    memory_groups: list[dict[str, Any]] = field(default_factory=list)
    host_transfers: list[dict[str, Any]] = field(default_factory=list)
    sync_operations: list[dict[str, Any]] = field(default_factory=list)
    kernel_objects: list[dict[str, Any]] = field(default_factory=list)
    kernel_invocations: list[dict[str, Any]] = field(default_factory=list)
    run_waits: list[dict[str, Any]] = field(default_factory=list)
    build_targets: list[dict[str, Any]] = field(default_factory=list)
    test_entries: list[dict[str, Any]] = field(default_factory=list)
    connectivity: list[dict[str, Any]] = field(default_factory=list)
    unknowns: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
'''

if old not in text:
    raise SystemExit("Expected ApplicationIR field block not found.")

path.write_text(text.replace(old, new), encoding="utf-8")
PY

echo "[3/6] Update repo_scanner to call semantic extractor"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/scanner/repo_scanner.py")
text = path.read_text(encoding="utf-8")

text = text.replace(
    "from xporthls.ir.application_ir import ApplicationIR, SourceFile, XrtCall\n",
    "from xporthls.ir.application_ir import ApplicationIR, SourceFile, XrtCall\n"
    "from xporthls.scanner.xrt_semantic_extractor import extract_xrt_semantics\n"
)

old = '''        for lineno, line in enumerate(text.splitlines(), start=1):
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
'''

new = '''        if kind in {"source", "header"}:
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
'''

if old not in text:
    raise SystemExit("Expected scanner loop block not found.")

path.write_text(text.replace(old, new), encoding="utf-8")
PY

echo "[4/6] Update CLI scan summary"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/cli.py")
text = path.read_text(encoding="utf-8")

old_meta = '''            "num_kernel_candidates": len(ir.kernels),
            "warnings": ir.warnings
'''

new_meta = '''            "num_kernel_candidates": len(ir.kernels),
            "num_buffers": len(ir.buffers),
            "num_kernel_invocations": len(ir.kernel_invocations),
            "num_sync_operations": len(ir.sync_operations),
            "num_host_transfers": len(ir.host_transfers),
            "num_unknowns": len(ir.unknowns),
            "warnings": ir.warnings
'''

text = text.replace(old_meta, new_meta)

old_print = '''    print(f"[xporthls] Kernel candidates: {len(ir.kernels)}")
    if ir.warnings:
'''

new_print = '''    print(f"[xporthls] Kernel candidates: {len(ir.kernels)}")
    print(f"[xporthls] Buffers: {len(ir.buffers)}")
    print(f"[xporthls] Kernel invocations: {len(ir.kernel_invocations)}")
    print(f"[xporthls] Sync operations: {len(ir.sync_operations)}")
    print(f"[xporthls] Host transfers: {len(ir.host_transfers)}")
    print(f"[xporthls] Unknowns: {len(ir.unknowns)}")
    if ir.warnings:
'''

if old_print not in text:
    raise SystemExit("Expected CLI print block not found.")

path.write_text(text.replace(old_print, new_print), encoding="utf-8")
PY

echo "[5/6] Update L0 checker with XRT semantic checks"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/validators/l0_static_checker.py")
text = path.read_text(encoding="utf-8")

old = '''    build_targets = app.get("build_targets", [])

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))
'''

new = '''    build_targets = app.get("build_targets", [])
    buffers = app.get("buffers", [])
    kernel_invocations = app.get("kernel_invocations", [])
    sync_operations = app.get("sync_operations", [])
    host_transfers = app.get("host_transfers", [])
    unknowns = app.get("unknowns", [])

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if host_apis and not buffers:
        issues.append(L0Issue("warning", "NO_XRT_BUFFERS", "XRT API calls were detected, but no xrt::bo buffers were extracted."))

    if buffers and not kernel_invocations:
        issues.append(L0Issue("warning", "NO_KERNEL_INVOCATION", "Buffers were detected, but no kernel invocation was extracted."))

    if buffers and not sync_operations:
        issues.append(L0Issue("warning", "NO_SYNC_OPERATIONS", "Buffers were detected, but no bo.sync operations were extracted."))

    if buffers and not host_transfers:
        issues.append(L0Issue("warning", "NO_HOST_TRANSFERS", "Buffers were detected, but no bo.write/bo.read operations were extracted."))

    if unknowns:
        issues.append(L0Issue("warning", "IR_UNKNOWNS_PRESENT", f"ApplicationIR contains {len(unknowns)} unknown semantic fields."))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))
'''

if old not in text:
    raise SystemExit("Expected L0 checker block not found.")

text = text.replace(old, new)

old_summary = '''            "num_build_targets": len(build_targets),
            "has_contract": contract is not None,
'''

new_summary = '''            "num_build_targets": len(build_targets),
            "num_buffers": len(buffers),
            "num_kernel_invocations": len(kernel_invocations),
            "num_sync_operations": len(sync_operations),
            "num_host_transfers": len(host_transfers),
            "num_unknowns": len(unknowns),
            "has_contract": contract is not None,
'''

text = text.replace(old_summary, new_summary)

path.write_text(text, encoding="utf-8")
PY

echo "[6/6] Run scan + contract + L0"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v003.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v003.json \
  --platform config/platforms/v80_aved_2025_1_stub.json \
  --out experiments/runs/light_ddr_migration_contract_v003.json

python3 -m xporthls.validators.run_l0 \
  --app-ir experiments/runs/light_ddr_application_ir_v003.json \
  --contract experiments/runs/light_ddr_migration_contract_v003.json \
  --out experiments/runs/light_ddr_l0_report_v003.json

echo
echo "DONE."
echo "Check:"
echo "  cat experiments/runs/light_ddr_l0_report_v003.json"
echo "  python3 - <<'PY'"
echo "import json"
echo "p='experiments/runs/light_ddr_application_ir_v003.json'"
echo "d=json.load(open(p))"
echo "print(json.dumps({k:d[k] for k in ['buffers','host_transfers','sync_operations','kernel_invocations','run_waits','unknowns']}, indent=2))"
echo "PY"
