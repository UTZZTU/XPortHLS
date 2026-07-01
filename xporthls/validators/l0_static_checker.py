from __future__ import annotations

import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any

from xporthls.ir.schema_checks import check_application_ir_schema


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

    for issue in check_application_ir_schema(app):
        issues.append(L0Issue(
            severity=issue["severity"],
            code=issue["code"],
            message=issue["message"]
        ))

    source_files = app.get("source_files", [])
    host_apis = app.get("host_apis", [])
    kernels = app.get("kernels", [])
    build_targets = app.get("build_targets", [])
    buffers = app.get("buffers", [])
    kernel_invocations = app.get("kernel_invocations", [])
    sync_operations = app.get("sync_operations", [])
    host_transfers = app.get("host_transfers", [])
    unknowns = app.get("unknowns", [])
    facts = app.get("facts", {})
    case_metadata = app.get("case_metadata", {})

    if not case_metadata:
        issues.append(L0Issue("warning", "NO_CASE_METADATA", "ApplicationIR has no case_metadata. Add case.yaml for this case."))
    else:
        if not case_metadata.get("case_id"):
            issues.append(L0Issue("error", "CASE_METADATA_NO_ID", "case_metadata must include case_id."))
        if not case_metadata.get("validation_targets"):
            issues.append(L0Issue("warning", "CASE_METADATA_NO_VALIDATION_TARGETS", "case_metadata should include validation_targets."))

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

    if facts:
        xrt_facts = facts.get("xrt", {})
        if len(xrt_facts.get("buffers", [])) != len(buffers):
            issues.append(L0Issue(
                "error",
                "FACTS_BUFFER_MISMATCH",
                "facts.xrt.buffers length does not match top-level buffers length."
            ))

        if len(xrt_facts.get("kernel_invocations", [])) != len(kernel_invocations):
            issues.append(L0Issue(
                "error",
                "FACTS_KERNEL_INVOCATION_MISMATCH",
                "facts.xrt.kernel_invocations length does not match top-level kernel_invocations length."
            ))

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
            "schema_version": facts.get("schema_version", "unknown") if isinstance(facts, dict) else "missing",
            "case_id": case_metadata.get("case_id", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_role": case_metadata.get("role", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_memory_type": case_metadata.get("memory_type", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_validation_targets": case_metadata.get("validation_targets", []) if isinstance(case_metadata, dict) else [],
            "num_source_files": len(source_files),
            "num_xrt_calls": len(host_apis),
            "num_kernel_candidates": len(kernels),
            "num_build_targets": len(build_targets),
            "num_buffers": len(buffers),
            "num_kernel_invocations": len(kernel_invocations),
            "num_sync_operations": len(sync_operations),
            "num_host_transfers": len(host_transfers),
            "num_unknowns": len(unknowns),
            "has_facts": isinstance(facts, dict) and bool(facts),
            "has_contract": contract is not None,
        },
    )
