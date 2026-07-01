from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from xporthls.targetref.target_aware_resolver_plan_v026 import (
    REMAINING_BLOCKING_GAPS_V022,
    RESOLVED_PRIOR_GAPS,
)


@dataclass
class TargetAwarePlanIssue:
    severity: str
    code: str
    message: str


@dataclass
class TargetAwarePlanValidationReport:
    schema_version: str = "target_aware_gap_resolution_plan_validation_report.v1"
    xporthls_version: str = "v0.0.26"
    status: str = "fail"
    issues: list[TargetAwarePlanIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)
    llm_annotations: list[Any] = field(default_factory=list)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[TargetAwarePlanIssue], severity: str, code: str, message: str) -> None:
    issues.append(TargetAwarePlanIssue(severity=severity, code=code, message=message))


def validate_target_aware_plan(plan: dict[str, Any], guard_report: dict[str, Any] | None = None) -> TargetAwarePlanValidationReport:
    issues: list[TargetAwarePlanIssue] = []

    if plan.get("schema_version") != "target_aware_gap_resolution_plan.v1":
        add_issue(issues, "error", "SCHEMA", "Expected target_aware_gap_resolution_plan.v1.")

    if plan.get("xporthls_version") != "v0.0.26":
        add_issue(issues, "error", "VERSION", "Expected xporthls_version v0.0.26.")

    if plan.get("migration_direction") != "XRT->AVED":
        add_issue(issues, "error", "MIGRATION_DIRECTION", "Expected migration_direction XRT->AVED.")

    if plan.get("target_reference_schema") != "target_reference_ir.v1":
        add_issue(issues, "error", "TARGET_REFERENCE_SCHEMA", "Expected target_reference_ir.v1.")

    if plan.get("pattern_pairing_schema") != "source_target_pattern_pairing.v1":
        add_issue(issues, "error", "PATTERN_PAIRING_SCHEMA", "Expected source_target_pattern_pairing.v1.")

    if plan.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS", "v0.0.26 must not contain LLM annotations.")

    tb = plan.get("trust_boundary", {})
    required_false = [
        "llm_used",
        "contract_modified",
        "migration_allowed_modified",
        "generator_unlocked",
        "can_resolve_gap",
        "can_execute_resolver",
    ]
    for key in required_false:
        if tb.get(key) is not False:
            add_issue(issues, "error", "TRUST_BOUNDARY", f"Trust boundary flag must be false: {key}")

    if tb.get("plan_only") is not True:
        add_issue(issues, "error", "PLAN_ONLY", "v0.0.26 must be a plan-only stage.")

    if tb.get("requires_future_resolver_and_validation") is not True:
        add_issue(issues, "error", "FUTURE_VALIDATION", "Plan must require future resolver and validation.")

    contract_context = plan.get("contract_context", {})
    if sorted(contract_context.get("expected_remaining_blocking_gap_ids", [])) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "EXPECTED_BLOCKERS", "Expected remaining blocking gaps mismatch.")

    blockers = contract_context.get("blocking_gap_ids", [])
    if sorted(blockers) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "CONTRACT_BLOCKERS", "Contract blockers must remain the six post-v0.0.22 blockers.")

    for gid in RESOLVED_PRIOR_GAPS:
        if gid in blockers:
            add_issue(issues, "error", "RESOLVED_GAP_BLOCKING", f"Resolved prior gap must not be blocking: {gid}")

    if contract_context.get("contract_mutation_allowed") is not False:
        add_issue(issues, "error", "CONTRACT_MUTATION_ALLOWED", "Contract mutation must not be allowed in v0.0.26.")

    resolvers = plan.get("resolvers", [])
    if len(resolvers) != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "RESOLVER_COUNT", "Expected one target-aware resolver plan per remaining blocker.")

    resolver_gap_ids = [r.get("gap_id") for r in resolvers]
    if sorted(resolver_gap_ids) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "RESOLVER_GAP_SET", "Resolver gap set mismatch.")

    seen_priorities: set[int] = set()
    for r in resolvers:
        gid = r.get("gap_id")
        priority = r.get("priority")
        if not isinstance(priority, int):
            add_issue(issues, "error", "BAD_PRIORITY", f"Resolver priority must be int: {gid}")
        elif priority in seen_priorities:
            add_issue(issues, "error", "DUPLICATE_PRIORITY", f"Duplicate priority: {priority}")
        else:
            seen_priorities.add(priority)

        if r.get("ready_for_contract_resolution") is not False:
            add_issue(issues, "error", "READY_FOR_CONTRACT_RESOLUTION", f"v0.0.26 must not make gaps ready for contract resolution: {gid}")

        if r.get("contract_state_after_v026") != "unchanged_blocking":
            add_issue(issues, "error", "CONTRACT_STATE_CHANGE", f"Resolver must keep contract state unchanged/blocking: {gid}")

        rtb = r.get("trust_boundary", {})
        for key in ["llm_used", "authoritative", "can_execute", "can_modify_contract", "can_mark_gap_resolved", "can_unlock_generator"]:
            if rtb.get(key) is not False:
                add_issue(issues, "error", "RESOLVER_TRUST_BOUNDARY", f"{gid} trust flag must be false: {key}")
        if rtb.get("plan_only") is not True:
            add_issue(issues, "error", "RESOLVER_PLAN_ONLY", f"{gid} must be plan-only.")

        if not r.get("must_extract"):
            add_issue(issues, "error", "MISSING_MUST_EXTRACT", f"Resolver must list must_extract: {gid}")
        if not r.get("must_not_do"):
            add_issue(issues, "error", "MISSING_MUST_NOT_DO", f"Resolver must list must_not_do: {gid}")
        if not r.get("validation_requirements"):
            add_issue(issues, "error", "MISSING_VALIDATION_REQUIREMENTS", f"Resolver must list validation requirements: {gid}")

        if gid == "GAP-PLACEMENT-SLR-001":
            if r.get("execution_readiness") != "normalize_evidence_only":
                add_issue(issues, "error", "PLACEMENT_NOT_NORMALIZE_ONLY", "Placement must be normalize-only in v0.0.26.")
            if r.get("resolver_name") != "PlacementEvidenceNormalizer":
                add_issue(issues, "error", "PLACEMENT_RESOLVER_NAME", "Placement resolver must be PlacementEvidenceNormalizer.")

    summary = plan.get("summary", {})
    if summary.get("gaps_marked_resolved_by_v026") != 0:
        add_issue(issues, "error", "RESOLVED_BY_V026", "v0.0.26 must mark zero gaps resolved.")
    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK", "v0.0.26 must not unlock generator.")
    if summary.get("llm_used") is not False:
        add_issue(issues, "error", "SUMMARY_LLM_USED", "summary.llm_used must be false.")
    if summary.get("contract_modified") is not False:
        add_issue(issues, "error", "SUMMARY_CONTRACT_MODIFIED", "summary.contract_modified must be false.")
    if summary.get("contract_blocking_gap_count") != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "BLOCKING_COUNT", "Contract blocking count must remain six.")

    target_evidence = plan.get("target_evidence_context", {})
    required_positive_evidence = [
        "target_reference_files",
        "target_reference_variants",
        "qdma_evidence_count",
        "axi_lite_evidence_count",
        "hls_axis_evidence_count",
        "create_design_tcl_count",
        "create_bd_design_tcl_count",
        "bd_connect_bd_intf_net_count",
        "bd_assign_bd_address_count",
    ]
    for key in required_positive_evidence:
        val = target_evidence.get(key)
        if not isinstance(val, int) or val <= 0:
            add_issue(issues, "error", "TARGET_EVIDENCE", f"Expected positive target evidence count: {key}")

    if target_evidence.get("has_f_version_correctness") is not True:
        add_issue(issues, "error", "F_VERSION_CORRECTNESS", "Expected F_VERSION_CORRECTNESS evidence from target reference.")

    pair_ctx = plan.get("pattern_pairing_context", {})
    if pair_ctx.get("num_pairings") != 6:
        add_issue(issues, "error", "PAIRING_COUNT", "Expected six pairings from v0.0.25.")
    if pair_ctx.get("unpaired_gap_count") != 0:
        add_issue(issues, "error", "UNPAIRED_GAPS", "Expected zero unpaired gaps from v0.0.25.")
    if pair_ctx.get("gaps_marked_resolved_by_v025") != 0:
        add_issue(issues, "error", "V025_RESOLVED_GAPS", "v0.0.25 should have resolved zero gaps.")

    rec = plan.get("v027_recommendation", {})
    if rec.get("recommended_next_resolver") != "AVEDHostRuntimePatternResolver":
        add_issue(issues, "warning", "V027_RECOMMENDATION", "Expected AVEDHostRuntimePatternResolver as recommended next resolver.")
    if rec.get("recommended_gap_id") != "GAP-XRT-HOST-001":
        add_issue(issues, "warning", "V027_GAP", "Expected GAP-XRT-HOST-001 as recommended next gap.")

    if guard_report is not None:
        if guard_report.get("schema_version") != "generator_guard_report.v1":
            add_issue(issues, "error", "GUARD_SCHEMA", "Expected generator_guard_report.v1.")
        if guard_report.get("decision", {}).get("blocked") is not True:
            add_issue(issues, "error", "GUARD_NOT_BLOCKED", "Generator guard must remain blocked.")
        if guard_report.get("decision", {}).get("allowed") is not False:
            add_issue(issues, "error", "GUARD_ALLOWED", "Generator guard must not allow generation.")
        guard_blockers = guard_report.get("summary", {}).get("blocking_gap_ids", [])
        if sorted(guard_blockers) != sorted(REMAINING_BLOCKING_GAPS_V022):
            add_issue(issues, "error", "GUARD_BLOCKERS", "Guard blocking IDs must remain the six post-v0.0.22 blockers.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return TargetAwarePlanValidationReport(
        status=status,
        issues=issues,
        summary={
            "plan_schema": plan.get("schema_version"),
            "migration_direction": plan.get("migration_direction"),
            "source_case_id": plan.get("source_case_id"),
            "target_case_id": plan.get("target_case_id"),
            "num_resolvers": len(resolvers),
            "ready_for_next_resolver_design_count": summary.get("ready_for_next_resolver_design_count"),
            "normalize_only_count": summary.get("normalize_only_count"),
            "missing_evidence_count": summary.get("missing_evidence_count"),
            "gaps_marked_resolved_by_v026": summary.get("gaps_marked_resolved_by_v026"),
            "contract_blocking_gap_count": summary.get("contract_blocking_gap_count"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "llm_used": summary.get("llm_used"),
            "contract_modified": summary.get("contract_modified"),
            "recommended_next_resolver": rec.get("recommended_next_resolver"),
            "recommended_gap_id": rec.get("recommended_gap_id"),
            "guard_blocked": guard_report.get("decision", {}).get("blocked") if guard_report else None,
            "guard_allowed": guard_report.get("decision", {}).get("allowed") if guard_report else None,
            "num_errors": sum(1 for i in issues if i.severity == "error"),
            "num_warnings": sum(1 for i in issues if i.severity == "warning"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate target-aware resolver plan v0.0.26")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    plan = load_json(args.plan)
    guard = load_json(args.guard_report) if args.guard_report else None

    report = validate_target_aware_plan(plan, guard)
    report.save(args.out)

    print(f"[xporthls] Target-aware plan validation: {args.out}")
    print(f"[xporthls] Validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
