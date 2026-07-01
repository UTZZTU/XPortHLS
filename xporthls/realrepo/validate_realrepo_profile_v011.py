from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class RealRepoIssue:
    severity: str
    code: str
    message: str


@dataclass
class RealRepoValidationReport:
    status: str
    issues: list[RealRepoIssue] = field(default_factory=list)
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


def validate(census: dict[str, Any], source: dict[str, Any], compat: dict[str, Any]) -> RealRepoValidationReport:
    issues: list[RealRepoIssue] = []

    if census.get("schema_version") != "repo_census.v1":
        issues.append(RealRepoIssue("error", "CENSUS_SCHEMA", "Expected repo_census.v1."))

    if source.get("schema_version") != "source_platform_profile.v1":
        issues.append(RealRepoIssue("error", "SOURCE_PROFILE_SCHEMA", "Expected source_platform_profile.v1."))

    if compat.get("schema_version") != "compatibility_profile.v1":
        issues.append(RealRepoIssue("error", "COMPAT_PROFILE_SCHEMA", "Expected compatibility_profile.v1."))

    if census.get("summary", {}).get("num_files", 0) <= 0:
        issues.append(RealRepoIssue("error", "NO_FILES", "Repo census found no files."))

    if source.get("source_runtime") == "unknown":
        issues.append(RealRepoIssue("warning", "SOURCE_RUNTIME_UNKNOWN", "Could not infer source runtime."))

    if not source.get("source_boards_detected"):
        issues.append(RealRepoIssue("warning", "SOURCE_BOARD_UNKNOWN", "Could not infer source board."))

    if compat.get("target_platform") != "v80_aved_2025_1_stub":
        issues.append(RealRepoIssue("error", "TARGET_PLATFORM_UNEXPECTED", "v0.0.11 should target v80_aved_2025_1_stub."))

    if compat.get("target_ecosystem") != "AVED":
        issues.append(RealRepoIssue("error", "TARGET_ECOSYSTEM_UNEXPECTED", "v0.0.11 should target AVED."))

    if compat.get("migration_status") != "profile_only":
        issues.append(RealRepoIssue("error", "MIGRATION_STATUS_UNEXPECTED", "v0.0.11 must remain profile_only."))

    required = compat.get("required_next_capabilities", [])
    if not required:
        issues.append(RealRepoIssue("warning", "NO_NEXT_CAPABILITIES", "Compatibility profile did not list next capabilities."))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return RealRepoValidationReport(
        status=status,
        issues=issues,
        summary={
            "repo_path": census.get("repo_path"),
            "num_files": census.get("summary", {}).get("num_files"),
            "roles": census.get("summary", {}).get("roles"),
            "source_runtime": source.get("source_runtime"),
            "source_boards_detected": source.get("source_boards_detected"),
            "source_memory_model": source.get("source_memory_model"),
            "complexity": source.get("complexity", {}).get("level"),
            "migration_status": compat.get("migration_status"),
            "target_platform": compat.get("target_platform"),
            "target_ecosystem": compat.get("target_ecosystem"),
            "required_next_capabilities": compat.get("required_next_capabilities"),
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate v0.0.11 real repo profile outputs")
    parser.add_argument("--census", required=True)
    parser.add_argument("--source-profile", required=True)
    parser.add_argument("--compatibility", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = validate(
        load_json(args.census),
        load_json(args.source_profile),
        load_json(args.compatibility),
    )
    report.save(args.out)

    print(f"[xporthls] Real repo profile validation written to: {args.out}")
    print(f"[xporthls] Real repo profile validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
