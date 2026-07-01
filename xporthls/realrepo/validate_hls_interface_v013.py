from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class HlsInterfaceIssue:
    severity: str
    code: str
    message: str


@dataclass
class HlsInterfaceValidationReport:
    status: str
    issues: list[HlsInterfaceIssue] = field(default_factory=list)
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


def validate(ir: dict[str, Any]) -> HlsInterfaceValidationReport:
    issues: list[HlsInterfaceIssue] = []

    if ir.get("schema_version") != "hls_interface_ir.v1":
        issues.append(HlsInterfaceIssue("error", "HLS_IR_SCHEMA", "Expected hls_interface_ir.v1."))

    summary = ir.get("summary", {})

    if summary.get("num_hls_files", 0) <= 0:
        issues.append(HlsInterfaceIssue("error", "NO_HLS_FILES", "No HLS source/header files were found."))

    if summary.get("num_kernel_candidates", 0) <= 0:
        issues.append(HlsInterfaceIssue("error", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if summary.get("num_interface_pragmas", 0) <= 0:
        issues.append(HlsInterfaceIssue("error", "NO_INTERFACE_PRAGMAS", "No HLS INTERFACE pragmas were detected."))

    if summary.get("num_m_axi", 0) <= 0:
        issues.append(HlsInterfaceIssue("warning", "NO_M_AXI", "No m_axi interfaces were detected."))

    if summary.get("num_axis", 0) <= 0:
        issues.append(HlsInterfaceIssue("warning", "NO_AXIS", "No axis interfaces were detected."))

    if summary.get("num_s_axilite", 0) <= 0:
        issues.append(HlsInterfaceIssue("warning", "NO_S_AXILITE", "No s_axilite interfaces were detected."))

    if summary.get("num_dataflow", 0) <= 0:
        issues.append(HlsInterfaceIssue("warning", "NO_DATAFLOW", "No DATAFLOW pragmas were detected."))

    if summary.get("num_configured_kernels", 0) > 0 and summary.get("num_matched_configured_kernels", 0) <= 0:
        issues.append(HlsInterfaceIssue("warning", "NO_CONFIGURED_KERNEL_MATCH", "No configured kernels matched declared kernel candidates."))

    missing_declared = summary.get("num_missing_declared_for_config", 0)
    if missing_declared > 0:
        issues.append(HlsInterfaceIssue(
            "warning",
            "CONFIGURED_KERNELS_WITHOUT_DECLARATION",
            f"{missing_declared} configured kernel names did not match a declared kernel candidate."
        ))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return HlsInterfaceValidationReport(
        status=status,
        issues=issues,
        summary={
            "num_hls_files": summary.get("num_hls_files"),
            "num_functions": summary.get("num_functions"),
            "num_kernel_candidates": summary.get("num_kernel_candidates"),
            "num_interface_pragmas": summary.get("num_interface_pragmas"),
            "interface_types": summary.get("interface_types"),
            "num_m_axi": summary.get("num_m_axi"),
            "num_axis": summary.get("num_axis"),
            "num_s_axilite": summary.get("num_s_axilite"),
            "num_dataflow": summary.get("num_dataflow"),
            "num_stream_variables": summary.get("num_stream_variables"),
            "num_include_edges": summary.get("num_include_edges"),
            "num_configured_kernels": summary.get("num_configured_kernels"),
            "num_matched_configured_kernels": summary.get("num_matched_configured_kernels"),
            "num_missing_declared_for_config": summary.get("num_missing_declared_for_config"),
            "num_missing_config_for_declared": summary.get("num_missing_config_for_declared"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate HLS Interface IR")
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    ir = load_json(args.hls_ir)
    report = validate(ir)
    report.save(args.out)

    print(f"[xporthls] HLS Interface validation written to: {args.out}")
    print(f"[xporthls] HLS Interface validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
