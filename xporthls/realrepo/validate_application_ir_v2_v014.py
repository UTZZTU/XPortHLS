from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class ApplicationIRv2Issue:
    severity: str
    code: str
    message: str


@dataclass
class ApplicationIRv2ValidationReport:
    status: str
    issues: list[ApplicationIRv2Issue] = field(default_factory=list)
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


def require(condition: bool, issues: list[ApplicationIRv2Issue], severity: str, code: str, message: str) -> None:
    if not condition:
        issues.append(ApplicationIRv2Issue(severity, code, message))


def validate(app: dict[str, Any]) -> ApplicationIRv2ValidationReport:
    issues: list[ApplicationIRv2Issue] = []

    require(
        app.get("schema_version") == "application_ir.v2",
        issues,
        "error",
        "APP_IR_SCHEMA",
        "Expected application_ir.v2.",
    )

    require(
        app.get("migration_status") == "profile_only",
        issues,
        "error",
        "MIGRATION_STATUS",
        "ApplicationIR v2 in v0.0.14 must remain profile_only.",
    )

    require(
        app.get("source_runtime") == "XRT",
        issues,
        "error",
        "SOURCE_RUNTIME",
        "Expected source_runtime XRT for the HiSparse profile.",
    )

    target = app.get("target", {})
    require(
        target.get("platform") == "v80_aved_2025_1_stub",
        issues,
        "error",
        "TARGET_PLATFORM",
        "Expected target platform v80_aved_2025_1_stub.",
    )
    require(
        target.get("ecosystem") == "AVED",
        issues,
        "error",
        "TARGET_ECOSYSTEM",
        "Expected target ecosystem AVED.",
    )

    facts = app.get("facts", {})
    for required in ["repo_census", "source_platform", "build", "connectivity", "hls"]:
        require(
            required in facts,
            issues,
            "error",
            "FACTS_SECTION_MISSING",
            f"Missing facts section: {required}.",
        )

    summary = app.get("summary", {})

    require(
        int(summary.get("num_files") or 0) > 0,
        issues,
        "error",
        "NO_FILES",
        "ApplicationIR v2 has no source files.",
    )

    require(
        int(summary.get("num_build_files") or 0) > 0,
        issues,
        "error",
        "NO_BUILD_FILES",
        "ApplicationIR v2 has no build files.",
    )

    require(
        int(summary.get("num_connectivity_directives") or 0) > 0,
        issues,
        "error",
        "NO_CONNECTIVITY_DIRECTIVES",
        "ApplicationIR v2 has no connectivity directives.",
    )

    require(
        int(summary.get("num_hls_kernel_candidates") or 0) > 0,
        issues,
        "error",
        "NO_HLS_KERNEL_CANDIDATES",
        "ApplicationIR v2 has no HLS kernel candidates.",
    )

    kernel_graph = app.get("kernel_graph", {})
    kg_summary = kernel_graph.get("summary", {})

    require(
        kernel_graph.get("schema_version") == "kernel_graph_ir.v1",
        issues,
        "error",
        "KERNEL_GRAPH_SCHEMA",
        "Expected kernel_graph_ir.v1.",
    )

    require(
        int(kg_summary.get("num_kernels") or 0) > 0,
        issues,
        "error",
        "NO_KERNEL_GRAPH_NODES",
        "Kernel graph has no nodes.",
    )

    memory_topology = app.get("memory_topology", {})
    require(
        memory_topology.get("schema_version") == "memory_topology_ir.v1",
        issues,
        "error",
        "MEMORY_TOPOLOGY_SCHEMA",
        "Expected memory_topology_ir.v1.",
    )

    if int(kg_summary.get("num_configured_without_declared") or 0) > 0:
        issues.append(ApplicationIRv2Issue(
            "warning",
            "CONFIGURED_KERNELS_WITHOUT_DECLARED_FUNCTION",
            f"{kg_summary.get('num_configured_without_declared')} configured kernels do not have a matched declared HLS kernel function.",
        ))

    if int(kg_summary.get("num_declared_without_config") or 0) > 0:
        issues.append(ApplicationIRv2Issue(
            "warning",
            "DECLARED_KERNELS_WITHOUT_CONNECTIVITY",
            f"{kg_summary.get('num_declared_without_config')} declared kernel candidates are not referenced by connectivity.",
        ))

    if int(summary.get("num_unsupported_features") or 0) > 0:
        issues.append(ApplicationIRv2Issue(
            "warning",
            "UNSUPPORTED_FEATURES_REMAIN",
            f"{summary.get('num_unsupported_features')} unsupported or not-yet-mapped features remain.",
        ))

    if int(summary.get("num_unknowns") or 0) > 0:
        issues.append(ApplicationIRv2Issue(
            "warning",
            "APP_IR_HAS_UNKNOWNS",
            f"{summary.get('num_unknowns')} unknown groups remain in ApplicationIR v2.",
        ))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ApplicationIRv2ValidationReport(
        status=status,
        issues=issues,
        summary={
            "schema_version": app.get("schema_version"),
            "case_id": app.get("case_id"),
            "migration_status": app.get("migration_status"),
            "source_runtime": app.get("source_runtime"),
            "target_platform": target.get("platform"),
            "target_ecosystem": target.get("ecosystem"),
            "num_files": summary.get("num_files"),
            "num_build_files": summary.get("num_build_files"),
            "num_connectivity_directives": summary.get("num_connectivity_directives"),
            "num_memory_mappings": summary.get("num_memory_mappings"),
            "num_stream_edges": summary.get("num_stream_edges"),
            "num_hls_kernel_candidates": summary.get("num_hls_kernel_candidates"),
            "num_hls_interface_pragmas": summary.get("num_hls_interface_pragmas"),
            "num_kernel_graph_nodes": summary.get("num_kernel_graph_nodes"),
            "num_configured_without_declared": kg_summary.get("num_configured_without_declared"),
            "num_declared_without_config": kg_summary.get("num_declared_without_config"),
            "num_unsupported_features": summary.get("num_unsupported_features"),
            "num_unknowns": summary.get("num_unknowns"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate ApplicationIR v2")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    app = load_json(args.app_ir)
    report = validate(app)
    report.save(args.out)

    print(f"[xporthls] ApplicationIR v2 validation written to: {args.out}")
    print(f"[xporthls] ApplicationIR v2 validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
