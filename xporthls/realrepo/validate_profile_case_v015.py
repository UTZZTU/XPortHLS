from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class ProfileCaseIssue:
    severity: str
    code: str
    message: str


@dataclass
class ProfileCaseValidationReport:
    status: str
    issues: list[ProfileCaseIssue] = field(default_factory=list)
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


def add_issue(issues: list[ProfileCaseIssue], severity: str, code: str, message: str) -> None:
    issues.append(ProfileCaseIssue(severity, code, message))


def check_equal(issues: list[ProfileCaseIssue], actual: Any, expected: Any, code: str, label: str, severity: str = "error") -> None:
    if actual != expected:
        add_issue(issues, severity, code, f"{label}: expected {expected!r}, got {actual!r}")


def check_include(issues: list[ProfileCaseIssue], actual_values: list[Any], expected_values: list[Any], code: str, label: str, severity: str = "error") -> None:
    missing = [v for v in expected_values if v not in actual_values]
    if missing:
        add_issue(issues, severity, code, f"{label}: missing {missing!r}; actual={actual_values!r}")


def check_minimum(issues: list[ProfileCaseIssue], actual: Any, minimum: int, code: str, label: str, severity: str = "error") -> None:
    try:
        value = int(actual)
    except Exception:
        add_issue(issues, severity, code, f"{label}: value is not an integer: {actual!r}")
        return

    if value < minimum:
        add_issue(issues, severity, code, f"{label}: expected >= {minimum}, got {value}")


def validate_case(case_dir: str, case_run_report: str) -> ProfileCaseValidationReport:
    case_path = Path(case_dir)
    issues: list[ProfileCaseIssue] = []

    source_ref = load_json(str(case_path / "source_repo.json"))
    expected_profile = load_json(str(case_path / "expected_profile.json"))
    expected_gaps = load_json(str(case_path / "expected_gaps.json"))
    run = load_json(case_run_report)

    summary = run.get("summary", {})

    if run.get("schema_version") != "profile_case_run.v1":
        add_issue(issues, "error", "CASE_RUN_SCHEMA", "Expected profile_case_run.v1.")

    check_equal(issues, run.get("case_id"), source_ref.get("case_id"), "CASE_ID_MISMATCH", "case_id")
    check_equal(issues, run.get("status"), "pass", "CASE_RUN_NOT_PASS", "case run status")

    expected_source = expected_profile.get("source", {})
    expected_target = expected_profile.get("target", {})

    check_equal(issues, summary.get("source_runtime"), expected_source.get("runtime"), "SOURCE_RUNTIME_MISMATCH", "source runtime")
    check_include(issues, summary.get("source_boards", []), expected_source.get("boards_include", []), "SOURCE_BOARD_MISSING", "source boards")

    toolchains = summary.get("source_toolchains", {})
    check_include(issues, toolchains.get("vitis_versions", []), expected_source.get("toolchain_versions_include", []), "SOURCE_TOOLCHAIN_MISSING", "source toolchains")
    check_include(issues, toolchains.get("shell_platforms", []), expected_source.get("shell_platforms_include", []), "SOURCE_SHELL_MISSING", "source shell platforms")

    check_equal(issues, summary.get("source_memory_model"), expected_source.get("memory_model"), "SOURCE_MEMORY_MODEL_MISMATCH", "source memory model")
    check_equal(issues, run.get("target_platform"), expected_target.get("platform"), "TARGET_PLATFORM_MISMATCH", "target platform")
    check_equal(issues, run.get("target_ecosystem"), expected_target.get("ecosystem"), "TARGET_ECOSYSTEM_MISMATCH", "target ecosystem")

    for key, minimum in expected_profile.get("minimum_counts", {}).items():
        check_minimum(issues, summary.get(key), minimum, f"MINIMUM_{key.upper()}", key)

    check_include(issues, summary.get("memory_kinds", []), expected_profile.get("required_memory_kinds", []), "MEMORY_KIND_MISSING", "memory kinds")

    required_status = expected_profile.get("required_profile_status", {})
    check_equal(issues, summary.get("migration_status"), required_status.get("migration_status"), "MIGRATION_STATUS_MISMATCH", "migration status")
    check_equal(issues, summary.get("application_ir_schema"), required_status.get("application_ir_schema"), "APP_IR_SCHEMA_MISMATCH", "ApplicationIR schema")

    if summary.get("application_ir_validation_status") not in {"pass", "pass_with_warnings"}:
        add_issue(issues, "error", "APP_IR_VALIDATION_STATUS", f"ApplicationIR validation should pass or pass_with_warnings, got {summary.get('application_ir_validation_status')!r}")

    artifacts = run.get("artifacts", {})
    app_path = artifacts.get("application_ir_v2")
    if not app_path or not Path(app_path).exists():
        add_issue(issues, "error", "APP_IR_ARTIFACT_MISSING", "ApplicationIR v2 artifact is missing.")
        app = {}
    else:
        app = load_json(app_path)

    required_caps = app.get("compatibility", {}).get("required_next_capabilities", [])
    check_include(issues, required_caps, expected_gaps.get("expected_required_capabilities", []), "EXPECTED_CAPABILITY_GAP_MISSING", "required next capabilities", severity="warning")

    unsupported_features = [item.get("feature") for item in app.get("compatibility", {}).get("unsupported_features", []) if item.get("feature")]
    check_include(issues, unsupported_features, expected_gaps.get("expected_unsupported_features", []), "EXPECTED_UNSUPPORTED_FEATURE_MISSING", "unsupported features", severity="warning")

    unknown_kinds = [u.get("kind") for u in app.get("unknowns", []) if u.get("kind")]
    check_include(issues, unknown_kinds, expected_gaps.get("expected_unknown_kinds", []), "EXPECTED_UNKNOWN_KIND_MISSING", "unknown kinds", severity="warning")

    for stage in run.get("stages", []):
        if stage.get("return_code") != 0:
            add_issue(issues, "error", "CASE_STAGE_FAILED", f"Stage {stage.get('name')} failed with rc={stage.get('return_code')}")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ProfileCaseValidationReport(
        status=status,
        issues=issues,
        summary={
            "case_id": run.get("case_id"),
            "case_run_status": run.get("status"),
            "source_runtime": summary.get("source_runtime"),
            "source_boards": summary.get("source_boards"),
            "source_memory_model": summary.get("source_memory_model"),
            "source_toolchains": summary.get("source_toolchains"),
            "target_platform": run.get("target_platform"),
            "target_ecosystem": run.get("target_ecosystem"),
            "repo_files": summary.get("repo_files"),
            "build_files": summary.get("build_files"),
            "connectivity_directives": summary.get("connectivity_directives"),
            "memory_mappings": summary.get("memory_mappings"),
            "stream_edges": summary.get("stream_edges"),
            "hls_kernel_candidates": summary.get("hls_kernel_candidates"),
            "hls_interface_pragmas": summary.get("hls_interface_pragmas"),
            "kernel_graph_nodes": summary.get("kernel_graph_nodes"),
            "unsupported_features": summary.get("unsupported_features"),
            "unknowns": summary.get("unknowns"),
            "application_ir_schema": summary.get("application_ir_schema"),
            "application_ir_validation_status": summary.get("application_ir_validation_status"),
            "expected_required_capabilities_checked": expected_gaps.get("expected_required_capabilities", []),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a profile-only real repository case")
    parser.add_argument("--case-dir", default="cases/hisparse_u280_profile")
    parser.add_argument("--case-run-report", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = validate_case(args.case_dir, args.case_run_report)
    report.save(args.out)

    print(f"[xporthls] Profile case validation written to: {args.out}")
    print(f"[xporthls] Profile case validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
