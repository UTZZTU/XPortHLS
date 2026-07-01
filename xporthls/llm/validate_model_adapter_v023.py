from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


TARGET_RESOLVED_GAP_ID = "GAP-KERNEL-NAME-001"


@dataclass
class ModelAdapterIssue:
    severity: str
    code: str
    message: str


@dataclass
class ModelAdapterValidationReport:
    status: str
    issues: list[ModelAdapterIssue] = field(default_factory=list)
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


def add_issue(issues: list[ModelAdapterIssue], severity: str, code: str, message: str) -> None:
    issues.append(ModelAdapterIssue(severity=severity, code=code, message=message))


def validate(probe: dict[str, Any], trace: dict[str, Any], budget: dict[str, Any], guard: dict[str, Any] | None = None) -> ModelAdapterValidationReport:
    issues: list[ModelAdapterIssue] = []

    if probe.get("schema_version") != "model_adapter_probe.v1":
        add_issue(issues, "error", "PROBE_SCHEMA", "Expected model_adapter_probe.v1.")

    if trace.get("schema_version") != "llm_trace_ledger.v1":
        add_issue(issues, "error", "TRACE_SCHEMA", "Expected llm_trace_ledger.v1.")

    if budget.get("schema_version") != "llm_budget_ledger.v1":
        add_issue(issues, "error", "BUDGET_SCHEMA", "Expected llm_budget_ledger.v1.")

    if probe.get("llm_annotations") != [] or trace.get("llm_annotations") != [] or budget.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Infrastructure artifacts must not contain LLM annotations.")

    policy = probe.get("policy", {})
    if policy.get("schema_version") != "model_adapter_policy.v1":
        add_issue(issues, "error", "POLICY_SCHEMA", "Expected model_adapter_policy.v1.")

    if policy.get("llm_enabled") is not False:
        add_issue(issues, "error", "LLM_ENABLED", "v0.0.23 must keep llm_enabled=false by default.")

    if policy.get("default_backend") != "disabled":
        add_issue(issues, "error", "DEFAULT_BACKEND", "v0.0.23 default backend must be disabled.")

    if policy.get("real_backend_allowed") is not False:
        add_issue(issues, "error", "REAL_BACKEND_ALLOWED", "Real backend must not be allowed in v0.0.23.")

    if policy.get("network_access_allowed") is not False:
        add_issue(issues, "error", "NETWORK_ALLOWED", "Network access must not be allowed in v0.0.23.")

    if policy.get("read_only") is not True:
        add_issue(issues, "error", "NOT_READ_ONLY", "ModelAdapter must be read-only in v0.0.23.")

    for action in [
        "modify_source_files",
        "modify_gap_contract",
        "change_migration_allowed",
        "unlock_generator",
        "execute_shell_commands",
        "write_generated_target_project",
    ]:
        if action not in policy.get("forbidden_actions", []):
            add_issue(issues, "error", "FORBIDDEN_ACTION_MISSING", f"Missing forbidden action: {action}")

    request = probe.get("request", {})
    response = probe.get("response", {})

    if request.get("schema_version") != "llm_request.v1":
        add_issue(issues, "error", "REQUEST_SCHEMA", "Expected llm_request.v1.")

    if response.get("schema_version") != "llm_response.v1":
        add_issue(issues, "error", "RESPONSE_SCHEMA", "Expected llm_response.v1.")

    if request.get("mode") != "read_only":
        add_issue(issues, "error", "REQUEST_MODE", "Request must be read_only.")

    if request.get("task_type") != "read_only_gap_diagnosis":
        add_issue(issues, "error", "REQUEST_TASK", "Request must be read_only_gap_diagnosis.")

    if request.get("authority_boundary", {}).get("llm_is_source_of_facts") is not False:
        add_issue(issues, "error", "LLM_FACT_AUTHORITY", "Request must say LLM is not a source of facts.")

    if request.get("authority_boundary", {}).get("validators_are_authoritative") is not True:
        add_issue(issues, "error", "VALIDATOR_AUTHORITY", "Request must say validators are authoritative.")

    if response.get("backend") != "disabled":
        add_issue(issues, "error", "RESPONSE_BACKEND", "Default v0.0.23 response backend must be disabled.")

    if response.get("status") != "blocked_by_policy":
        add_issue(issues, "error", "RESPONSE_STATUS", "Default v0.0.23 request must be blocked_by_policy.")

    if response.get("executed") is not False:
        add_issue(issues, "error", "RESPONSE_EXECUTED", "Default v0.0.23 request must not execute.")

    if response.get("blocked_by_policy") is not True:
        add_issue(issues, "error", "RESPONSE_NOT_BLOCKED", "Default v0.0.23 request must be blocked by policy.")

    safety = response.get("safety", {})
    for key in [
        "real_model_invoked",
        "mock_model_invoked",
        "network_access_used",
        "files_modified",
        "contract_modified",
        "generator_unlocked",
    ]:
        if safety.get(key) is not False:
            add_issue(issues, "error", "SAFETY_FLAG", f"Response safety flag must be false: {key}")

    pipeline = probe.get("pipeline_state", {})
    if pipeline.get("migration_allowed") is not False:
        add_issue(issues, "error", "PIPELINE_MIGRATION_ALLOWED", "Patched contract should still disallow migration.")

    if len(pipeline.get("blocking_gap_ids", [])) != 6:
        add_issue(issues, "error", "PIPELINE_EXPECT_SIX_BLOCKERS", "v0.0.23 should run on patched contract with 6 blockers.")

    if TARGET_RESOLVED_GAP_ID not in pipeline.get("resolved_gap_ids", []):
        add_issue(issues, "error", "KERNEL_GAP_NOT_RESOLVED", "Patched contract should include GAP-KERNEL-NAME-001 in resolved_gap_ids.")

    if TARGET_RESOLVED_GAP_ID in pipeline.get("blocking_gap_ids", []):
        add_issue(issues, "error", "KERNEL_GAP_STILL_BLOCKING", "Patched contract should not block on GAP-KERNEL-NAME-001.")

    entries = trace.get("entries", [])
    if len(entries) != 1:
        add_issue(issues, "error", "TRACE_ENTRY_COUNT", "Trace ledger must have exactly one entry.")
    else:
        entry = entries[0]
        if entry.get("request_id") != request.get("request_id"):
            add_issue(issues, "error", "TRACE_REQUEST_ID", "Trace request_id mismatch.")
        if entry.get("status") != response.get("status"):
            add_issue(issues, "error", "TRACE_STATUS", "Trace status mismatch.")
        if entry.get("backend") != response.get("backend"):
            add_issue(issues, "error", "TRACE_BACKEND", "Trace backend mismatch.")
        if entry.get("blocked_by_policy") is not True:
            add_issue(issues, "error", "TRACE_NOT_BLOCKED", "Trace must record blocked_by_policy=true.")

    trace_summary = trace.get("summary", {})
    if trace_summary.get("num_entries") != 1:
        add_issue(issues, "error", "TRACE_SUMMARY_ENTRIES", "Trace summary num_entries must be 1.")
    if trace_summary.get("num_executed") != 0:
        add_issue(issues, "error", "TRACE_EXECUTED", "Trace summary num_executed must be 0.")
    if trace_summary.get("num_blocked_by_policy") != 1:
        add_issue(issues, "error", "TRACE_BLOCKED", "Trace summary num_blocked_by_policy must be 1.")
    if trace_summary.get("real_model_invocations") != 0:
        add_issue(issues, "error", "TRACE_REAL_MODEL", "Trace must record zero real model invocations.")
    if trace_summary.get("mock_model_invocations") != 0:
        add_issue(issues, "error", "TRACE_MOCK_MODEL", "Trace must record zero mock model invocations by default.")

    budget_summary = budget.get("summary", {})
    if budget_summary.get("attempted_requests") != 1:
        add_issue(issues, "error", "BUDGET_ATTEMPTED", "Budget attempted_requests must be 1.")
    if budget_summary.get("executed_requests") != 0:
        add_issue(issues, "error", "BUDGET_EXECUTED", "Budget executed_requests must be 0.")
    if budget_summary.get("blocked_requests") != 1:
        add_issue(issues, "error", "BUDGET_BLOCKED", "Budget blocked_requests must be 1.")
    if budget_summary.get("spent_usd") != 0.0:
        add_issue(issues, "error", "BUDGET_SPENT", "Budget spent_usd must be 0.0.")

    probe_summary = probe.get("summary", {})
    for key in [
        "llm_enabled",
        "real_backend_allowed",
        "request_executed",
        "real_model_invoked",
        "mock_model_invoked",
        "network_access_used",
        "files_modified",
        "contract_modified",
        "generator_unlocked",
        "generator_unlock_allowed",
    ]:
        if probe_summary.get(key) is not False:
            add_issue(issues, "error", "PROBE_SUMMARY_FLAG", f"Probe summary flag must be false: {key}")

    if probe_summary.get("request_blocked_by_policy") is not True:
        add_issue(issues, "error", "PROBE_REQUEST_NOT_BLOCKED", "Probe summary must record request_blocked_by_policy=true.")

    if guard is not None:
        if guard.get("schema_version") != "generator_guard_report.v1":
            add_issue(issues, "error", "GUARD_SCHEMA", "Guard report must use generator_guard_report.v1.")
        if guard.get("decision", {}).get("blocked") is not True:
            add_issue(issues, "error", "GUARD_NOT_BLOCKED", "Generator guard must remain blocked.")
        if guard.get("decision", {}).get("allowed") is not False:
            add_issue(issues, "error", "GUARD_ALLOWED", "Generator guard must not allow generation.")
        guard_ids = guard.get("summary", {}).get("blocking_gap_ids", [])
        if len(guard_ids) != 6:
            add_issue(issues, "error", "GUARD_EXPECT_SIX_BLOCKERS", f"Guard should see 6 blockers, got {len(guard_ids)}.")
        if TARGET_RESOLVED_GAP_ID in guard_ids:
            add_issue(issues, "error", "GUARD_KERNEL_GAP_BLOCKING", "Guard should not list resolved kernel-name gap.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ModelAdapterValidationReport(
        status=status,
        issues=issues,
        summary={
            "probe_schema": probe.get("schema_version"),
            "trace_schema": trace.get("schema_version"),
            "budget_schema": budget.get("schema_version"),
            "policy_schema": policy.get("schema_version"),
            "request_schema": request.get("schema_version"),
            "response_schema": response.get("schema_version"),
            "llm_enabled": policy.get("llm_enabled"),
            "default_backend": policy.get("default_backend"),
            "request_status": response.get("status"),
            "request_executed": response.get("executed"),
            "request_blocked_by_policy": response.get("blocked_by_policy"),
            "real_model_invoked": safety.get("real_model_invoked"),
            "mock_model_invoked": safety.get("mock_model_invoked"),
            "trace_entries": trace_summary.get("num_entries"),
            "budget_attempted_requests": budget_summary.get("attempted_requests"),
            "budget_executed_requests": budget_summary.get("executed_requests"),
            "budget_blocked_requests": budget_summary.get("blocked_requests"),
            "spent_usd": budget_summary.get("spent_usd"),
            "pipeline_blocking_count": len(pipeline.get("blocking_gap_ids", [])),
            "pipeline_migration_allowed": pipeline.get("migration_allowed"),
            "guard_blocked": guard.get("decision", {}).get("blocked") if guard else None,
            "generator_unlock_allowed": False,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate ModelAdapter infrastructure v0.0.23")
    parser.add_argument("--probe", required=True)
    parser.add_argument("--trace-ledger", required=True)
    parser.add_argument("--budget-ledger", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    probe = load_json(args.probe)
    trace = load_json(args.trace_ledger)
    budget = load_json(args.budget_ledger)
    guard = load_json(args.guard_report) if args.guard_report else None

    report = validate(probe, trace, budget, guard)
    report.save(args.out)

    print(f"[xporthls] ModelAdapter validation written to: {args.out}")
    print(f"[xporthls] ModelAdapter validation status: {report.status}")
    for i in report.issues:
        print(f"  - {i.severity.upper()} {i.code}: {i.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
