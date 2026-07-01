from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class ResolverPlanIssue:
    severity: str
    code: str
    message: str


@dataclass
class ResolverPlanValidationReport:
    status: str
    issues: list[ResolverPlanIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[ResolverPlanIssue], severity: str, code: str, message: str) -> None:
    issues.append(ResolverPlanIssue(severity=severity, code=code, message=message))


def validate_resolver_shape(resolver: dict[str, Any], issues: list[ResolverPlanIssue]) -> None:
    required = [
        "resolver_id",
        "gap_id",
        "order",
        "resolver_type",
        "category",
        "severity",
        "blocks_migration",
        "must_resolve_before_generation",
        "resolution_state",
        "execution_mode",
        "required_inputs",
        "expected_outputs",
        "steps",
        "preconditions",
        "success_criteria",
        "evidence",
    ]

    for field in required:
        if field not in resolver:
            add_issue(issues, "error", "RESOLVER_FIELD_MISSING", f"Resolver {resolver.get('resolver_id', '<unknown>')} missing field: {field}")

    if resolver.get("resolution_state") != "planned":
        add_issue(issues, "error", "RESOLVER_STATE_NOT_PLANNED", f"Resolver {resolver.get('resolver_id')} must start as planned.")

    if resolver.get("execution_mode") != "deterministic_only":
        add_issue(issues, "error", "RESOLVER_EXECUTION_MODE", f"Resolver {resolver.get('resolver_id')} must be deterministic_only.")

    if not isinstance(resolver.get("steps", []), list) or len(resolver.get("steps", [])) < 3:
        add_issue(issues, "error", "RESOLVER_STEPS_TOO_FEW", f"Resolver {resolver.get('resolver_id')} has too few steps.")

    for step in resolver.get("steps", []):
        if step.get("llm_allowed") is not False:
            add_issue(issues, "error", "STEP_LLM_ALLOWED", f"Step {step.get('step_id')} in {resolver.get('resolver_id')} must not allow LLM execution.")
        if step.get("must_be_deterministic") is not True:
            add_issue(issues, "error", "STEP_NOT_DETERMINISTIC", f"Step {step.get('step_id')} in {resolver.get('resolver_id')} must be deterministic.")

    if not resolver.get("required_inputs"):
        add_issue(issues, "error", "RESOLVER_INPUTS_MISSING", f"Resolver {resolver.get('resolver_id')} has no required_inputs.")

    if not resolver.get("expected_outputs"):
        add_issue(issues, "error", "RESOLVER_OUTPUTS_MISSING", f"Resolver {resolver.get('resolver_id')} has no expected_outputs.")


def validate(plan: dict[str, Any], contract: dict[str, Any] | None = None) -> ResolverPlanValidationReport:
    issues: list[ResolverPlanIssue] = []

    if plan.get("schema_version") != "gap_resolver_plan.v1":
        add_issue(issues, "error", "PLAN_SCHEMA", "Expected gap_resolver_plan.v1.")

    if plan.get("plan_state") != "planned_profile_only":
        add_issue(issues, "error", "PLAN_STATE", "v0.0.18 plan_state must be planned_profile_only.")

    if plan.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.18 resolver plan must remain profile_only.")

    source_ref = plan.get("source_contract_ref", {})
    if source_ref.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA_REF", "Resolver plan must reference source_to_target_gap_contract.v1.")

    if source_ref.get("contract_state") != "blocked_profile_only":
        add_issue(issues, "error", "CONTRACT_STATE_REF", "Resolver plan currently expects blocked_profile_only contract.")

    if source_ref.get("migration_allowed") is not False:
        add_issue(issues, "error", "CONTRACT_MIGRATION_ALLOWED_REF", "Resolver plan expects migration_allowed false.")

    policy = plan.get("planning_policy", {})
    if policy.get("generation_allowed") is not False:
        add_issue(issues, "error", "PLAN_GENERATION_ALLOWED", "v0.0.18 must not allow generation.")

    if policy.get("resolver_execution_allowed") is not False:
        add_issue(issues, "error", "RESOLVER_EXECUTION_ALLOWED", "v0.0.18 must not execute resolvers.")

    llm_policy = policy.get("llm_policy", {})
    if llm_policy.get("llm_may_execute_resolver") is not False:
        add_issue(issues, "error", "LLM_EXECUTE_POLICY", "LLM must not execute resolver.")
    if llm_policy.get("llm_may_change_gap_state") is not False:
        add_issue(issues, "error", "LLM_STATE_CHANGE_POLICY", "LLM must not change gap state.")
    if llm_policy.get("llm_is_correctness_judge") is not False:
        add_issue(issues, "error", "LLM_JUDGE_POLICY", "LLM must not be correctness judge.")

    resolvers = plan.get("resolvers", [])
    if not resolvers:
        add_issue(issues, "error", "NO_RESOLVERS", "Resolver plan has no resolvers.")

    resolver_ids = []
    gap_ids = []
    for resolver in resolvers:
        validate_resolver_shape(resolver, issues)
        resolver_ids.append(resolver.get("resolver_id"))
        gap_ids.append(resolver.get("gap_id"))

    if len(resolver_ids) != len(set(resolver_ids)):
        add_issue(issues, "error", "DUPLICATE_RESOLVER_IDS", "Resolver IDs must be unique.")

    if len(gap_ids) != len(set(gap_ids)):
        add_issue(issues, "error", "DUPLICATE_GAP_IDS", "Each gap should have exactly one resolver entry.")

    summary = plan.get("summary", {})
    if int(summary.get("num_resolvers") or 0) != len(resolvers):
        add_issue(issues, "error", "RESOLVER_COUNT_MISMATCH", "summary.num_resolvers does not match resolver list length.")

    blocking_resolvers = [
        r for r in resolvers
        if r.get("must_resolve_before_generation") is True
    ]

    if int(summary.get("num_blocking_resolvers") or 0) != len(blocking_resolvers):
        add_issue(issues, "error", "BLOCKING_RESOLVER_COUNT_MISMATCH", "summary.num_blocking_resolvers mismatch.")

    expected_blocking_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-PLACEMENT-SLR-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }
    actual_gap_ids = set(gap_ids)

    missing_required = sorted(expected_blocking_gap_ids - actual_gap_ids)
    if missing_required:
        add_issue(issues, "error", "REQUIRED_RESOLVERS_MISSING", f"Missing required resolver gap ids: {missing_required}")

    expected_types = {
        "GAP-XRT-HOST-001": "HostRuntimeRewritePlan",
        "GAP-PLATFORM-001": "SourcePlatformMappingPlan",
        "GAP-MEM-HBM-001": "MemoryMappingPlan",
        "GAP-STREAM-AXIS-001": "StreamGraphMappingPlan",
        "GAP-PLACEMENT-SLR-001": "PlacementPolicyPlan",
        "GAP-KERNEL-NAME-001": "KernelNameResolutionPlan",
        "GAP-HLS-INTERFACE-001": "HlsInterfaceLoweringPlan",
    }

    by_gap = {r.get("gap_id"): r for r in resolvers}
    for gap_id, expected_type in expected_types.items():
        resolver = by_gap.get(gap_id)
        if not resolver:
            continue
        if resolver.get("resolver_type") != expected_type:
            add_issue(
                issues,
                "error",
                "RESOLVER_TYPE_MISMATCH",
                f"{gap_id}: expected {expected_type}, got {resolver.get('resolver_type')!r}",
            )
        if resolver.get("must_resolve_before_generation") is not True:
            add_issue(
                issues,
                "error",
                "BLOCKING_RESOLVER_NOT_REQUIRED",
                f"{gap_id}: must_resolve_before_generation should be true.",
            )

    graph = plan.get("dependency_graph", {})
    graph_nodes = set(graph.get("nodes", []))
    missing_graph_nodes = sorted(set(resolver_ids) - graph_nodes)
    if missing_graph_nodes:
        add_issue(issues, "error", "DEPENDENCY_GRAPH_NODE_MISSING", f"Dependency graph missing nodes: {missing_graph_nodes}")

    for edge in graph.get("edges", []):
        if edge.get("from") not in graph_nodes or edge.get("to") not in graph_nodes:
            add_issue(issues, "error", "DEPENDENCY_GRAPH_EDGE_INVALID", f"Invalid edge: {edge}")

    if plan.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Resolver plan must not contain LLM annotations in v0.0.18.")

    if contract is not None:
        contract_gap_ids = {g.get("id") for g in contract.get("gaps", [])}
        missing_from_plan = sorted(contract_gap_ids - actual_gap_ids)
        if missing_from_plan:
            add_issue(issues, "error", "CONTRACT_GAP_WITHOUT_RESOLVER", f"Contract gaps missing resolver entries: {missing_from_plan}")

        contract_blocking = set(contract.get("summary", {}).get("blocking_gap_ids", []))
        planned_blocking = {r.get("gap_id") for r in blocking_resolvers}
        if contract_blocking != planned_blocking:
            add_issue(
                issues,
                "error",
                "CONTRACT_BLOCKING_MISMATCH",
                f"Contract blocking gaps {sorted(contract_blocking)} != planned blocking gaps {sorted(planned_blocking)}",
            )

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ResolverPlanValidationReport(
        status=status,
        issues=issues,
        summary={
            "plan_id": plan.get("plan_id"),
            "case_id": plan.get("case_id"),
            "schema_version": plan.get("schema_version"),
            "plan_state": plan.get("plan_state"),
            "migration_status": plan.get("migration_status"),
            "source_contract_schema": source_ref.get("schema_version"),
            "source_contract_state": source_ref.get("contract_state"),
            "source_contract_migration_allowed": source_ref.get("migration_allowed"),
            "generation_allowed": policy.get("generation_allowed"),
            "resolver_execution_allowed": policy.get("resolver_execution_allowed"),
            "num_resolvers": summary.get("num_resolvers"),
            "num_blocking_resolvers": summary.get("num_blocking_resolvers"),
            "num_warning_resolvers": summary.get("num_warning_resolvers"),
            "num_info_resolvers": summary.get("num_info_resolvers"),
            "blocking_resolver_ids": summary.get("blocking_resolver_ids"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Gap Resolver Plan v0.0.18")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--contract", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    plan = load_json(args.plan)
    contract = load_json(args.contract) if args.contract else None
    report = validate(plan, contract)
    report.save(args.out)

    print(f"[xporthls] Gap Resolver Plan validation written to: {args.out}")
    print(f"[xporthls] Gap Resolver Plan validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
