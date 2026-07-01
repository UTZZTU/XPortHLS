from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class GuardIssue:
    severity: str
    code: str
    message: str


@dataclass
class GeneratorGuardDecision:
    allowed: bool
    blocked: bool
    reason: str
    exit_code: int
    issue_codes: list[str] = field(default_factory=list)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def sha256_file(path: str | Path) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None

    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def simplify_gap(gap: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": gap.get("id"),
        "title": gap.get("title"),
        "category": gap.get("category"),
        "severity": gap.get("severity"),
        "blocks_migration": gap.get("blocks_migration"),
        "status": gap.get("status"),
        "decision": gap.get("decision"),
        "required_action": gap.get("required_action"),
    }


def evaluate_contract(contract: dict[str, Any]) -> tuple[GeneratorGuardDecision, list[GuardIssue]]:
    issues: list[GuardIssue] = []

    schema = contract.get("schema_version")
    if schema != "source_to_target_gap_contract.v1":
        issues.append(GuardIssue(
            severity="error",
            code="CONTRACT_SCHEMA_INVALID",
            message=f"Expected source_to_target_gap_contract.v1, got {schema!r}.",
        ))

    if contract.get("migration_status") != "profile_only":
        issues.append(GuardIssue(
            severity="warning",
            code="MIGRATION_STATUS_NOT_PROFILE_ONLY",
            message=f"Unexpected migration_status: {contract.get('migration_status')!r}.",
        ))

    migration_decision = contract.get("migration_decision", {})
    summary = contract.get("summary", {})

    migration_allowed = bool(migration_decision.get("allowed"))
    contract_state = contract.get("contract_state")
    num_blocking = int(summary.get("num_blocking") or 0)

    blocking_gaps = [
        gap
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "blocking" and gap.get("blocks_migration")
    ]

    if num_blocking != len(blocking_gaps):
        issues.append(GuardIssue(
            severity="error",
            code="BLOCKING_COUNT_MISMATCH",
            message=f"summary.num_blocking={num_blocking}, actual blocking gaps={len(blocking_gaps)}.",
        ))

    if migration_allowed and blocking_gaps:
        issues.append(GuardIssue(
            severity="error",
            code="MIGRATION_ALLOWED_WITH_BLOCKING_GAPS",
            message="Contract allows migration while blocking gaps still exist.",
        ))

    if migration_allowed and contract_state != "ready_for_planning":
        issues.append(GuardIssue(
            severity="error",
            code="ALLOWED_CONTRACT_STATE_INVALID",
            message=f"migration allowed requires contract_state ready_for_planning, got {contract_state!r}.",
        ))

    if not migration_allowed:
        issues.append(GuardIssue(
            severity="blocking",
            code="CONTRACT_BLOCKS_GENERATION",
            message="Gap contract does not allow target generation.",
        ))

    if contract_state == "blocked_profile_only":
        issues.append(GuardIssue(
            severity="blocking",
            code="CONTRACT_STATE_BLOCKED_PROFILE_ONLY",
            message="Contract state is blocked_profile_only.",
        ))

    error_codes = [i.code for i in issues if i.severity == "error"]
    blocking_codes = [i.code for i in issues if i.severity == "blocking"]

    if error_codes:
        return (
            GeneratorGuardDecision(
                allowed=False,
                blocked=True,
                reason="Contract is invalid or internally inconsistent.",
                exit_code=3,
                issue_codes=error_codes + blocking_codes,
            ),
            issues,
        )

    if blocking_codes or not migration_allowed or num_blocking > 0:
        return (
            GeneratorGuardDecision(
                allowed=False,
                blocked=True,
                reason="Target generation blocked by source-to-target gap contract.",
                exit_code=2,
                issue_codes=blocking_codes,
            ),
            issues,
        )

    return (
        GeneratorGuardDecision(
            allowed=True,
            blocked=False,
            reason="Gap contract allows target generation.",
            exit_code=0,
            issue_codes=[],
        ),
        issues,
    )


def build_guard_report(
    contract_path: str,
    requested_output_dir: str,
    generator_name: str,
    requested_action: str,
    dry_run: bool = True,
) -> dict[str, Any]:
    contract = load_json(contract_path)
    decision, issues = evaluate_contract(contract)

    output_path = Path(requested_output_dir)
    output_exists_before = output_path.exists()

    if decision.allowed and not dry_run:
        output_path.mkdir(parents=True, exist_ok=True)
        marker = output_path / "GENERATION_ALLOWED_BY_CONTRACT.txt"
        marker.write_text(
            "Generation was allowed by source-to-target gap contract.\n",
            encoding="utf-8",
        )

    output_exists_after = output_path.exists()

    blocking_gaps = [
        simplify_gap(gap)
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "blocking" and gap.get("blocks_migration")
    ]

    warning_gaps = [
        simplify_gap(gap)
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "warning"
    ]

    return {
        "schema_version": "generator_guard_report.v1",
        "created_at_utc": utc_now(),
        "generator_name": generator_name,
        "requested_action": requested_action,
        "requested_output_dir": requested_output_dir,
        "dry_run": dry_run,
        "contract_ref": {
            "path": contract_path,
            "sha256": sha256_file(contract_path),
            "schema_version": contract.get("schema_version"),
            "contract_id": contract.get("contract_id"),
            "case_id": contract.get("case_id"),
            "contract_state": contract.get("contract_state"),
            "migration_status": contract.get("migration_status"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
        },
        "decision": asdict(decision),
        "issues": [asdict(i) for i in issues],
        "blocking_gaps": blocking_gaps,
        "warning_gaps": warning_gaps,
        "output_protection": {
            "output_exists_before": output_exists_before,
            "output_exists_after": output_exists_after,
            "output_created_by_guard": (not output_exists_before) and output_exists_after,
            "blocked_generation_created_output": decision.blocked and ((not output_exists_before) and output_exists_after),
        },
        "summary": {
            "allowed": decision.allowed,
            "blocked": decision.blocked,
            "exit_code": decision.exit_code,
            "num_issues": len(issues),
            "num_blocking_gaps": len(blocking_gaps),
            "num_warning_gaps": len(warning_gaps),
            "blocking_gap_ids": [g.get("id") for g in blocking_gaps],
            "warning_gap_ids": [g.get("id") for g in warning_gaps],
        },
    }


def enforce_guard(
    contract_path: str,
    requested_output_dir: str,
    report_out: str,
    generator_name: str = "stub_generator",
    requested_action: str = "generate_target_project",
    dry_run: bool = True,
    expect_blocked: bool = False,
) -> int:
    report = build_guard_report(
        contract_path=contract_path,
        requested_output_dir=requested_output_dir,
        generator_name=generator_name,
        requested_action=requested_action,
        dry_run=dry_run,
    )
    save_json(report_out, report)

    decision = report["decision"]

    print(f"[xporthls] Generator guard report: {report_out}")
    print(f"[xporthls] Generator: {generator_name}")
    print(f"[xporthls] Requested action: {requested_action}")
    print(f"[xporthls] Contract: {contract_path}")
    print(f"[xporthls] Allowed: {decision['allowed']}")
    print(f"[xporthls] Blocked: {decision['blocked']}")
    print(f"[xporthls] Reason: {decision['reason']}")
    print(f"[xporthls] Blocking gaps: {report['summary']['blocking_gap_ids']}")
    print(f"[xporthls] Output created by guard: {report['output_protection']['output_created_by_guard']}")

    if expect_blocked:
        if decision["blocked"]:
            print("[xporthls] Expected block observed.")
            return 0
        print("[xporthls] ERROR: expected generation to be blocked, but it was allowed.")
        return 1

    return int(decision["exit_code"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Contract-gated generator guard")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--requested-output-dir", required=True)
    parser.add_argument("--report-out", required=True)
    parser.add_argument("--generator-name", default="stub_generator")
    parser.add_argument("--requested-action", default="generate_target_project")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--expect-blocked", action="store_true")
    args = parser.parse_args()

    return enforce_guard(
        contract_path=args.contract,
        requested_output_dir=args.requested_output_dir,
        report_out=args.report_out,
        generator_name=args.generator_name,
        requested_action=args.requested_action,
        dry_run=args.dry_run,
        expect_blocked=args.expect_blocked,
    )


if __name__ == "__main__":
    raise SystemExit(main())
