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
