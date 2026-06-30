from __future__ import annotations

import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class L0Issue:
    severity: str
    code: str
    message: str


@dataclass
class L0Report:
    status: str
    issues: list[L0Issue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def run_l0_static(app_ir_path: str, contract_path: str | None = None) -> L0Report:
    with open(app_ir_path, "r", encoding="utf-8") as f:
        app = json.load(f)

    contract = None
    if contract_path:
        with open(contract_path, "r", encoding="utf-8") as f:
            contract = json.load(f)

    issues: list[L0Issue] = []

    source_files = app.get("source_files", [])
    host_apis = app.get("host_apis", [])
    kernels = app.get("kernels", [])
    build_targets = app.get("build_targets", [])

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))

    if contract is not None:
        if not contract.get("obligations"):
            issues.append(L0Issue("error", "NO_CONTRACT_OBLIGATIONS", "MigrationContract has no obligations."))
        if not contract.get("target_platform"):
            issues.append(L0Issue("error", "NO_TARGET_PLATFORM", "MigrationContract has no target platform."))

    has_error = any(issue.severity == "error" for issue in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return L0Report(
        status=status,
        issues=issues,
        summary={
            "project": app.get("project", "unknown"),
            "num_source_files": len(source_files),
            "num_xrt_calls": len(host_apis),
            "num_kernel_candidates": len(kernels),
            "num_build_targets": len(build_targets),
            "has_contract": contract is not None,
        },
    )
