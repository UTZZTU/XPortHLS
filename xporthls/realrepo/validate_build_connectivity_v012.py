from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class BuildConnectivityIssue:
    severity: str
    code: str
    message: str


@dataclass
class BuildConnectivityValidationReport:
    status: str
    issues: list[BuildConnectivityIssue] = field(default_factory=list)
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


def validate(build: dict[str, Any], conn: dict[str, Any]) -> BuildConnectivityValidationReport:
    issues: list[BuildConnectivityIssue] = []

    if build.get("schema_version") != "build_ir.v1":
        issues.append(BuildConnectivityIssue("error", "BUILD_IR_SCHEMA", "Expected build_ir.v1."))

    if conn.get("schema_version") != "connectivity_ir.v1":
        issues.append(BuildConnectivityIssue("error", "CONNECTIVITY_IR_SCHEMA", "Expected connectivity_ir.v1."))

    bsum = build.get("summary", {})
    csum = conn.get("summary", {})

    if bsum.get("num_build_files", 0) <= 0:
        issues.append(BuildConnectivityIssue("error", "NO_BUILD_FILES", "No build files were found."))

    if bsum.get("num_targets", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_BUILD_TARGETS", "No Makefile/CMake targets were detected."))

    if not bsum.get("detected_platforms"):
        issues.append(BuildConnectivityIssue("warning", "NO_PLATFORM_STRING", "No xilinx_* platform string was detected in build files."))

    if csum.get("num_config_files", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_CONNECTIVITY_CONFIGS", "No .ini/.cfg connectivity files were found."))

    if csum.get("num_directives", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_CONNECTIVITY_DIRECTIVES", "No connectivity directives were parsed."))

    if csum.get("num_memory_mappings", 0) <= 0:
        issues.append(BuildConnectivityIssue("warning", "NO_MEMORY_MAPPINGS", "No sp= memory mappings were parsed."))

    # For HiSparse-like projects, HBM is expected. This is warning only because the extractor must remain generic.
    if bsum.get("detected_platforms") and csum.get("num_memory_mappings", 0) > 0:
        memory_kinds = csum.get("memory_kinds", [])
        if memory_kinds and not any(str(k).upper().startswith("HBM") for k in memory_kinds):
            issues.append(BuildConnectivityIssue("warning", "NO_HBM_MEMORY_KIND", "Connectivity mappings exist but no HBM memory kind was detected."))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return BuildConnectivityValidationReport(
        status=status,
        issues=issues,
        summary={
            "num_build_files": bsum.get("num_build_files"),
            "num_targets": bsum.get("num_targets"),
            "num_commands": bsum.get("num_commands"),
            "command_kinds": bsum.get("command_kinds"),
            "detected_platforms": bsum.get("detected_platforms"),
            "config_refs": bsum.get("config_refs"),
            "num_config_files": csum.get("num_config_files"),
            "num_directives": csum.get("num_directives"),
            "num_memory_mappings": csum.get("num_memory_mappings"),
            "num_compute_unit_directives": csum.get("num_compute_unit_directives"),
            "num_stream_edges": csum.get("num_stream_edges"),
            "num_slr_assignments": csum.get("num_slr_assignments"),
            "memory_kinds": csum.get("memory_kinds"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate BuildIR and ConnectivityIR")
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    build = load_json(args.build_ir)
    conn = load_json(args.connectivity_ir)

    report = validate(build, conn)
    report.save(args.out)

    print(f"[xporthls] Build/Connectivity validation written to: {args.out}")
    print(f"[xporthls] Build/Connectivity validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
