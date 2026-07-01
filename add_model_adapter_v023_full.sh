#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add ModelAdapter v1 infrastructure"

mkdir -p xporthls/llm
touch xporthls/llm/__init__.py

cat > xporthls/llm/model_adapter_v023.py <<'EOT'
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def stable_request_id(case_id: str, input_refs: dict[str, Any], task_type: str) -> str:
    material = json.dumps(
        {
            "case_id": case_id,
            "task_type": task_type,
            "input_refs": input_refs,
            "version": "v0.0.23",
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return "llmreq_" + sha256_text(material)[:16]


def artifact_ref(path: str | Path) -> dict[str, Any]:
    p = Path(path)
    data: dict[str, Any] = {
        "path": str(path),
        "sha256": sha256_file(path),
    }
    if p.exists() and p.is_file():
        try:
            obj = load_json(p)
            data["schema_version"] = obj.get("schema_version")
            if "contract_state" in obj:
                data["contract_state"] = obj.get("contract_state")
            if "migration_decision" in obj:
                data["migration_allowed"] = obj.get("migration_decision", {}).get("allowed")
            if "summary" in obj:
                data["summary_digest"] = sha256_text(json.dumps(obj.get("summary", {}), sort_keys=True, ensure_ascii=False))
        except Exception as exc:
            data["read_error"] = repr(exc)
    return data


def build_model_policy(case_id: str, allow_mock_execution: bool = False) -> dict[str, Any]:
    return {
        "schema_version": "model_adapter_policy.v1",
        "case_id": case_id,
        "llm_enabled": False,
        "default_backend": "disabled",
        "real_backend_allowed": False,
        "mock_backend_available": True,
        "mock_backend_execution_allowed": bool(allow_mock_execution),
        "network_access_allowed": False,
        "read_only": True,
        "max_executed_requests_per_run": 0 if not allow_mock_execution else 1,
        "max_estimated_input_tokens": 0 if not allow_mock_execution else 2048,
        "max_estimated_output_tokens": 0 if not allow_mock_execution else 512,
        "max_spend_usd": 0.0,
        "must_trace_every_request": True,
        "must_record_budget": True,
        "allowed_task_types": [
            "read_only_gap_diagnosis",
            "validator_failure_explanation",
            "patch_plan_proposal_for_human_review",
        ],
        "forbidden_actions": [
            "modify_source_files",
            "modify_gap_contract",
            "change_migration_allowed",
            "unlock_generator",
            "execute_shell_commands",
            "write_generated_target_project",
            "treat_llm_output_as_fact",
            "treat_llm_output_as_validation_pass",
        ],
        "notes": [
            "v0.0.23 installs the model adapter safety boundary only.",
            "Real model calls are disabled.",
            "The LLM is not a source of facts, executor, or correctness judge.",
            "Contracts, validators, trace ledger, and guard reports remain authoritative.",
        ],
    }


def build_read_only_prompt_spec(contract: dict[str, Any], resolver_plan: dict[str, Any], patch_report: dict[str, Any]) -> dict[str, Any]:
    blocking_gap_ids = contract.get("summary", {}).get("blocking_gap_ids", [])
    return {
        "schema_version": "llm_prompt_spec.v1",
        "prompt_kind": "read_only_gap_diagnosis",
        "redacted": True,
        "system_boundary": [
            "You may summarize deterministic artifacts only.",
            "You may propose a human-review plan only.",
            "You may not modify files, contracts, or migration state.",
            "You may not decide pass/fail.",
        ],
        "user_task": "Explain remaining source-to-target migration gaps and suggest deterministic next resolver priorities.",
        "facts_supplied_by_tools": {
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
            "blocking_gap_ids": blocking_gap_ids,
            "num_blocking": len(blocking_gap_ids),
            "resolved_gap_ids": contract.get("summary", {}).get("resolved_gap_ids", []),
            "resolver_plan_state": resolver_plan.get("plan_state"),
            "kernel_patch_applied": patch_report.get("summary", {}).get("applied"),
        },
        "expected_response_schema": "llm_response.v1",
    }


def build_llm_request(
    case_id: str,
    application_ir_path: str,
    gap_contract_path: str,
    resolver_plan_path: str,
    patch_report_path: str,
    contract: dict[str, Any],
    resolver_plan: dict[str, Any],
    patch_report: dict[str, Any],
) -> dict[str, Any]:
    input_refs = {
        "application_ir": artifact_ref(application_ir_path),
        "gap_contract": artifact_ref(gap_contract_path),
        "gap_resolver_plan": artifact_ref(resolver_plan_path),
        "gap_contract_patch_report": artifact_ref(patch_report_path),
    }

    prompt_spec = build_read_only_prompt_spec(contract, resolver_plan, patch_report)
    request_id = stable_request_id(case_id, input_refs, "read_only_gap_diagnosis")

    return {
        "schema_version": "llm_request.v1",
        "request_id": request_id,
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "task_type": "read_only_gap_diagnosis",
        "mode": "read_only",
        "input_refs": input_refs,
        "prompt_spec": prompt_spec,
        "prompt_sha256": sha256_text(json.dumps(prompt_spec, sort_keys=True, ensure_ascii=False)),
        "allowed_outputs": [
            "diagnostic_summary",
            "human_review_patch_plan",
            "extractor_improvement_suggestions",
        ],
        "forbidden_actions": [
            "modify_source_files",
            "modify_gap_contract",
            "change_migration_allowed",
            "unlock_generator",
            "execute_shell_commands",
            "write_generated_target_project",
            "return_uncited_external_facts",
        ],
        "authority_boundary": {
            "llm_is_source_of_facts": False,
            "llm_is_executor": False,
            "llm_is_correctness_judge": False,
            "validators_are_authoritative": True,
            "contracts_are_authoritative": True,
            "generator_guard_is_authoritative": True,
        },
        "privacy": {
            "prompt_redacted_in_trace": True,
            "store_full_prompt": True,
            "store_model_raw_output": False,
        },
    }


class DisabledModelBackend:
    name = "disabled"

    def invoke(self, request: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
        return {
            "schema_version": "llm_response.v1",
            "request_id": request.get("request_id"),
            "case_id": request.get("case_id"),
            "created_at_utc": utc_now(),
            "backend": self.name,
            "status": "blocked_by_policy",
            "executed": False,
            "blocked_by_policy": True,
            "reason": "llm_enabled is false in model_adapter_policy.v1.",
            "content": None,
            "usage": {
                "estimated_input_tokens": 0,
                "estimated_output_tokens": 0,
                "actual_input_tokens": 0,
                "actual_output_tokens": 0,
                "cost_usd": 0.0,
            },
            "safety": {
                "real_model_invoked": False,
                "mock_model_invoked": False,
                "network_access_used": False,
                "files_modified": False,
                "contract_modified": False,
                "generator_unlocked": False,
            },
            "llm_annotations": [],
        }


class MockModelBackend:
    name = "mock"

    def invoke(self, request: dict[str, Any], policy: dict[str, Any]) -> dict[str, Any]:
        if policy.get("mock_backend_execution_allowed") is not True:
            return DisabledModelBackend().invoke(request, policy)

        prompt_facts = request.get("prompt_spec", {}).get("facts_supplied_by_tools", {})
        blocking_gap_ids = prompt_facts.get("blocking_gap_ids", [])

        return {
            "schema_version": "llm_response.v1",
            "request_id": request.get("request_id"),
            "case_id": request.get("case_id"),
            "created_at_utc": utc_now(),
            "backend": self.name,
            "status": "completed_mock",
            "executed": True,
            "blocked_by_policy": False,
            "reason": "Mock backend execution allowed for local infrastructure testing only.",
            "content": {
                "diagnostic_summary": "Mock response: remaining gaps should be handled by deterministic resolvers and validators.",
                "remaining_blocking_gap_ids_seen": blocking_gap_ids,
                "suggested_next_resolver": blocking_gap_ids[0] if blocking_gap_ids else None,
                "non_authoritative": True,
            },
            "usage": {
                "estimated_input_tokens": 128,
                "estimated_output_tokens": 64,
                "actual_input_tokens": 0,
                "actual_output_tokens": 0,
                "cost_usd": 0.0,
            },
            "safety": {
                "real_model_invoked": False,
                "mock_model_invoked": True,
                "network_access_used": False,
                "files_modified": False,
                "contract_modified": False,
                "generator_unlocked": False,
            },
            "llm_annotations": [],
        }


def build_trace_ledger(case_id: str, request: dict[str, Any], response: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "llm_trace_ledger.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "entries": [
            {
                "schema_version": "llm_trace_entry.v1",
                "request_id": request.get("request_id"),
                "task_type": request.get("task_type"),
                "mode": request.get("mode"),
                "request_schema": request.get("schema_version"),
                "response_schema": response.get("schema_version"),
                "backend": response.get("backend"),
                "status": response.get("status"),
                "executed": response.get("executed"),
                "blocked_by_policy": response.get("blocked_by_policy"),
                "prompt_sha256": request.get("prompt_sha256"),
                "prompt_redacted_in_trace": request.get("privacy", {}).get("prompt_redacted_in_trace"),
                "input_ref_keys": sorted(request.get("input_refs", {}).keys()),
                "forbidden_actions": request.get("forbidden_actions", []),
                "usage": response.get("usage", {}),
                "safety": response.get("safety", {}),
            }
        ],
        "summary": {
            "num_entries": 1,
            "num_executed": 1 if response.get("executed") else 0,
            "num_blocked_by_policy": 1 if response.get("blocked_by_policy") else 0,
            "real_model_invocations": 1 if response.get("safety", {}).get("real_model_invoked") else 0,
            "mock_model_invocations": 1 if response.get("safety", {}).get("mock_model_invoked") else 0,
            "network_access_used": False,
            "files_modified": False,
            "contract_modified": False,
            "generator_unlocked": False,
        },
        "llm_annotations": [],
    }


def build_budget_ledger(case_id: str, policy: dict[str, Any], request: dict[str, Any], response: dict[str, Any]) -> dict[str, Any]:
    usage = response.get("usage", {})
    return {
        "schema_version": "llm_budget_ledger.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "budget_policy": {
            "max_executed_requests_per_run": policy.get("max_executed_requests_per_run"),
            "max_estimated_input_tokens": policy.get("max_estimated_input_tokens"),
            "max_estimated_output_tokens": policy.get("max_estimated_output_tokens"),
            "max_spend_usd": policy.get("max_spend_usd"),
        },
        "entries": [
            {
                "schema_version": "llm_budget_entry.v1",
                "request_id": request.get("request_id"),
                "backend": response.get("backend"),
                "status": response.get("status"),
                "attempted": True,
                "executed": response.get("executed"),
                "blocked_by_policy": response.get("blocked_by_policy"),
                "estimated_input_tokens": usage.get("estimated_input_tokens", 0),
                "estimated_output_tokens": usage.get("estimated_output_tokens", 0),
                "actual_input_tokens": usage.get("actual_input_tokens", 0),
                "actual_output_tokens": usage.get("actual_output_tokens", 0),
                "cost_usd": usage.get("cost_usd", 0.0),
            }
        ],
        "summary": {
            "attempted_requests": 1,
            "executed_requests": 1 if response.get("executed") else 0,
            "blocked_requests": 1 if response.get("blocked_by_policy") else 0,
            "estimated_input_tokens": usage.get("estimated_input_tokens", 0),
            "estimated_output_tokens": usage.get("estimated_output_tokens", 0),
            "actual_input_tokens": usage.get("actual_input_tokens", 0),
            "actual_output_tokens": usage.get("actual_output_tokens", 0),
            "spent_usd": usage.get("cost_usd", 0.0),
            "budget_exceeded": False,
        },
        "llm_annotations": [],
    }


def run_model_adapter_probe(
    case_id: str,
    application_ir_path: str,
    gap_contract_path: str,
    resolver_plan_path: str,
    patch_report_path: str,
    probe_out: str,
    trace_out: str,
    budget_out: str,
    allow_mock_execution: bool = False,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    app_ir = load_json(application_ir_path)
    contract = load_json(gap_contract_path)
    resolver_plan = load_json(resolver_plan_path)
    patch_report = load_json(patch_report_path)

    policy = build_model_policy(case_id, allow_mock_execution=allow_mock_execution)
    request = build_llm_request(
        case_id=case_id,
        application_ir_path=application_ir_path,
        gap_contract_path=gap_contract_path,
        resolver_plan_path=resolver_plan_path,
        patch_report_path=patch_report_path,
        contract=contract,
        resolver_plan=resolver_plan,
        patch_report=patch_report,
    )

    if policy.get("llm_enabled") is True and allow_mock_execution:
        response = MockModelBackend().invoke(request, policy)
    else:
        response = DisabledModelBackend().invoke(request, policy)

    trace = build_trace_ledger(case_id, request, response)
    budget = build_budget_ledger(case_id, policy, request, response)

    save_json(trace_out, trace)
    save_json(budget_out, budget)

    probe = {
        "schema_version": "model_adapter_probe.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "source_refs": {
            "application_ir": artifact_ref(application_ir_path),
            "gap_contract": artifact_ref(gap_contract_path),
            "gap_resolver_plan": artifact_ref(resolver_plan_path),
            "gap_contract_patch_report": artifact_ref(patch_report_path),
        },
        "policy": policy,
        "request": request,
        "response": response,
        "trace_ledger_ref": {
            "path": trace_out,
            "sha256": sha256_file(trace_out),
            "schema_version": trace.get("schema_version"),
        },
        "budget_ledger_ref": {
            "path": budget_out,
            "sha256": sha256_file(budget_out),
            "schema_version": budget.get("schema_version"),
        },
        "pipeline_state": {
            "application_ir_schema": app_ir.get("schema_version"),
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
            "blocking_gap_ids": contract.get("summary", {}).get("blocking_gap_ids", []),
            "resolved_gap_ids": contract.get("summary", {}).get("resolved_gap_ids", []),
            "resolver_plan_state": resolver_plan.get("plan_state"),
            "kernel_patch_applied": patch_report.get("summary", {}).get("applied"),
        },
        "summary": {
            "llm_enabled": policy.get("llm_enabled"),
            "default_backend": policy.get("default_backend"),
            "real_backend_allowed": policy.get("real_backend_allowed"),
            "mock_backend_available": policy.get("mock_backend_available"),
            "request_status": response.get("status"),
            "request_executed": response.get("executed"),
            "request_blocked_by_policy": response.get("blocked_by_policy"),
            "real_model_invoked": response.get("safety", {}).get("real_model_invoked"),
            "mock_model_invoked": response.get("safety", {}).get("mock_model_invoked"),
            "network_access_used": response.get("safety", {}).get("network_access_used"),
            "files_modified": response.get("safety", {}).get("files_modified"),
            "contract_modified": response.get("safety", {}).get("contract_modified"),
            "generator_unlocked": response.get("safety", {}).get("generator_unlocked"),
            "trace_entries": trace.get("summary", {}).get("num_entries"),
            "budget_attempted_requests": budget.get("summary", {}).get("attempted_requests"),
            "budget_executed_requests": budget.get("summary", {}).get("executed_requests"),
            "budget_blocked_requests": budget.get("summary", {}).get("blocked_requests"),
            "spent_usd": budget.get("summary", {}).get("spent_usd"),
            "generator_unlock_allowed": False,
        },
        "llm_annotations": [],
    }

    save_json(probe_out, probe)
    return probe, trace, budget


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.23 ModelAdapter probe")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--patch-report", required=True)
    parser.add_argument("--probe-out", required=True)
    parser.add_argument("--trace-out", required=True)
    parser.add_argument("--budget-out", required=True)
    parser.add_argument("--allow-mock-execution", action="store_true")
    args = parser.parse_args()

    probe, trace, budget = run_model_adapter_probe(
        case_id=args.case_id,
        application_ir_path=args.application_ir,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        patch_report_path=args.patch_report,
        probe_out=args.probe_out,
        trace_out=args.trace_out,
        budget_out=args.budget_out,
        allow_mock_execution=args.allow_mock_execution,
    )

    s = probe["summary"]
    print(f"[xporthls] ModelAdapter probe: {args.probe_out}")
    print(f"[xporthls] Trace ledger: {args.trace_out}")
    print(f"[xporthls] Budget ledger: {args.budget_out}")
    print(f"[xporthls] Probe schema: {probe['schema_version']}")
    print(f"[xporthls] LLM enabled: {s['llm_enabled']}")
    print(f"[xporthls] Default backend: {s['default_backend']}")
    print(f"[xporthls] Request status: {s['request_status']}")
    print(f"[xporthls] Request executed: {s['request_executed']}")
    print(f"[xporthls] Blocked by policy: {s['request_blocked_by_policy']}")
    print(f"[xporthls] Real model invoked: {s['real_model_invoked']}")
    print(f"[xporthls] Mock model invoked: {s['mock_model_invoked']}")
    print(f"[xporthls] Trace entries: {s['trace_entries']}")
    print(f"[xporthls] Budget executed requests: {s['budget_executed_requests']}")
    print(f"[xporthls] Spent USD: {s['spent_usd']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/6] Add ModelAdapter validator"

cat > xporthls/llm/validate_model_adapter_v023.py <<'EOT'
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
EOT

echo "[3/6] Add ModelAdapter orchestration runner"

cat > xporthls/llm/run_model_adapter_probe_v023.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.llm.model_adapter_v023 import run_model_adapter_probe
from xporthls.llm.validate_model_adapter_v023 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.23 ModelAdapter probe")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--patch-report", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    probe_path = out_dir / f"{args.case_id}_model_adapter_probe_v023.json"
    trace_path = out_dir / f"{args.case_id}_llm_trace_ledger_v023.json"
    budget_path = out_dir / f"{args.case_id}_llm_budget_ledger_v023.json"
    validation_path = out_dir / f"{args.case_id}_model_adapter_validation_v023.json"

    probe, trace, budget = run_model_adapter_probe(
        case_id=args.case_id,
        application_ir_path=args.application_ir,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        patch_report_path=args.patch_report,
        probe_out=str(probe_path),
        trace_out=str(trace_path),
        budget_out=str(budget_path),
        allow_mock_execution=False,
    )

    validation = validate(probe, trace, budget, None)
    validation.save(validation_path)

    s = probe["summary"]
    print(f"[xporthls] ModelAdapter probe: {probe_path}")
    print(f"[xporthls] Trace ledger: {trace_path}")
    print(f"[xporthls] Budget ledger: {budget_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Probe schema: {probe['schema_version']}")
    print(f"[xporthls] Trace schema: {trace['schema_version']}")
    print(f"[xporthls] Budget schema: {budget['schema_version']}")
    print(f"[xporthls] LLM enabled: {s['llm_enabled']}")
    print(f"[xporthls] Default backend: {s['default_backend']}")
    print(f"[xporthls] Request status: {s['request_status']}")
    print(f"[xporthls] Request executed: {s['request_executed']}")
    print(f"[xporthls] Blocked by policy: {s['request_blocked_by_policy']}")
    print(f"[xporthls] Real model invoked: {s['real_model_invoked']}")
    print(f"[xporthls] Mock model invoked: {s['mock_model_invoked']}")
    print(f"[xporthls] Budget executed requests: {s['budget_executed_requests']}")
    print(f"[xporthls] Spent USD: {s['spent_usd']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## ModelAdapter and LLM trace infrastructure

XPortHLS includes a ModelAdapter safety boundary for future LLM-assisted diagnosis and repair planning. In v0.0.23, real model calls are disabled by default. The adapter creates an `llm_request.v1`, blocks execution by policy, records a `llm_trace_ledger.v1`, records a `llm_budget_ledger.v1`, and validates that no model, network, source modification, contract mutation, or generator unlock occurred.

Example:

```bash
python3 -m xporthls.llm.run_model_adapter_probe_v023 \\
  --case-id hisparse_u280_profile \\
  --application-ir experiments/runs/hisparse_application_ir_v2_v014.json \\
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json \\
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \\
  --patch-report experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json \\
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_model_adapter_probe_v023.json
experiments/runs/hisparse_u280_profile_llm_trace_ledger_v023.json
experiments/runs/hisparse_u280_profile_llm_budget_ledger_v023.json
experiments/runs/hisparse_u280_profile_model_adapter_validation_v023.json
```

The v0.0.23 adapter is read-only and disabled by default. It does not call a real model, does not execute shell commands, does not modify contracts, and does not unlock generation.
"""

if "## ModelAdapter and LLM trace infrastructure" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.23 replay script"

cat > add_model_adapter_v023_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v023"
PATCHED_CONTRACT="experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"
PATCH_REPORT="experiments/runs/hisparse_u280_profile_gap_contract_patch_report_v022.json"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v023.json"
PROBE="experiments/runs/hisparse_u280_profile_model_adapter_probe_v023.json"
TRACE="experiments/runs/hisparse_u280_profile_llm_trace_ledger_v023.json"
BUDGET="experiments/runs/hisparse_u280_profile_llm_budget_ledger_v023.json"
VALIDATION="experiments/runs/hisparse_u280_profile_model_adapter_validation_v023.json"

echo "[v0.0.23] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/hls_interface_extractor.py \
  xporthls/realrepo/validate_hls_interface_v013.py \
  xporthls/realrepo/run_hls_interface_v013.py \
  xporthls/realrepo/application_ir_v2_builder.py \
  xporthls/realrepo/validate_application_ir_v2_v014.py \
  xporthls/realrepo/run_application_ir_v2_v014.py \
  xporthls/realrepo/run_profile_case_v015.py \
  xporthls/realrepo/validate_profile_case_v015.py \
  xporthls/realrepo/run_hisparse_profile_case_v015.py \
  xporthls/realrepo/gap_contract_v016.py \
  xporthls/realrepo/validate_gap_contract_v016.py \
  xporthls/realrepo/run_gap_contract_v016.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py \
  xporthls/generators/validate_generator_guard_v017.py \
  xporthls/realrepo/gap_resolver_plan_v018.py \
  xporthls/realrepo/validate_gap_resolver_plan_v018.py \
  xporthls/realrepo/run_gap_resolver_plan_v018.py \
  xporthls/realrepo/kernel_name_resolver_v019.py \
  xporthls/realrepo/validate_kernel_name_resolution_v019.py \
  xporthls/realrepo/run_kernel_name_resolution_v019.py \
  xporthls/realrepo/kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/validate_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/run_kernel_unresolved_diagnosis_v020.py \
  xporthls/realrepo/kernel_alias_table_v021.py \
  xporthls/realrepo/kernel_name_resolver_v021.py \
  xporthls/realrepo/kernel_gap_update_proposal_v021.py \
  xporthls/realrepo/validate_kernel_alias_resolution_v021.py \
  xporthls/realrepo/run_kernel_alias_resolution_v021.py \
  xporthls/realrepo/gap_contract_patch_v022.py \
  xporthls/realrepo/validate_gap_contract_patch_v022.py \
  xporthls/realrepo/run_gap_contract_patch_v022.py \
  xporthls/llm/model_adapter_v023.py \
  xporthls/llm/validate_model_adapter_v023.py \
  xporthls/llm/run_model_adapter_probe_v023.py

echo "[v0.0.23] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.23] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.18 resolver plan baseline"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.19 kernel name resolver baseline"

python3 -m xporthls.realrepo.run_kernel_name_resolution_v019 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.20 unresolved diagnosis baseline"

python3 -m xporthls.realrepo.run_kernel_unresolved_diagnosis_v020 \
  --case-id hisparse_u280_profile \
  --kernel-resolution-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --build-ir experiments/runs/hisparse_build_ir_v012.json \
  --connectivity-ir experiments/runs/hisparse_connectivity_ir_v012.json \
  --hls-ir experiments/runs/hisparse_hls_interface_ir_v013.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.21 alias resolver baseline"

python3 -m xporthls.realrepo.run_kernel_alias_resolution_v021 \
  --case-id hisparse_u280_profile \
  --diagnosis experiments/runs/hisparse_u280_profile_kernel_unresolved_diagnosis_v020.json \
  --v1-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v019.json \
  --gap-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --out-dir experiments/runs

echo "[v0.0.23] Re-run v0.0.22 gap contract patch baseline"

python3 -m xporthls.realrepo.run_gap_contract_patch_v022 \
  --case-id hisparse_u280_profile \
  --original-contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --proposal experiments/runs/hisparse_u280_profile_kernel_gap_update_proposal_v021.json \
  --v2-report experiments/runs/hisparse_u280_profile_kernel_name_resolution_report_v2_v021.json \
  --out-dir experiments/runs

echo "[v0.0.23] Run ModelAdapter probe; real and mock model execution must remain disabled"

python3 -m xporthls.llm.run_model_adapter_probe_v023 \
  --case-id hisparse_u280_profile \
  --application-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --gap-contract "$PATCHED_CONTRACT" \
  --resolver-plan experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json \
  --patch-report "$PATCH_REPORT" \
  --out-dir experiments/runs

echo "[v0.0.23] Run generator guard against patched contract; it must still be blocked"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.23] Validate ModelAdapter with guard evidence"

python3 -m xporthls.llm.validate_model_adapter_v023 \
  --probe "$PROBE" \
  --trace-ledger "$TRACE" \
  --budget-ledger "$BUDGET" \
  --guard-report "$GUARD_REPORT" \
  --out "$VALIDATION"

python3 - <<'PY'
import json
from pathlib import Path

probe = json.load(open("experiments/runs/hisparse_u280_profile_model_adapter_probe_v023.json"))
trace = json.load(open("experiments/runs/hisparse_u280_profile_llm_trace_ledger_v023.json"))
budget = json.load(open("experiments/runs/hisparse_u280_profile_llm_budget_ledger_v023.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_model_adapter_validation_v023.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_patched_contract_report_v023.json"))
contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json"))

s = probe["summary"]

print()
print("Probe schema:", probe["schema_version"])
print("Policy schema:", probe["policy"]["schema_version"])
print("Request schema:", probe["request"]["schema_version"])
print("Response schema:", probe["response"]["schema_version"])
print("Trace schema:", trace["schema_version"])
print("Budget schema:", budget["schema_version"])
print("LLM enabled:", s["llm_enabled"])
print("Default backend:", s["default_backend"])
print("Request status:", s["request_status"])
print("Request executed:", s["request_executed"])
print("Blocked by policy:", s["request_blocked_by_policy"])
print("Real model invoked:", s["real_model_invoked"])
print("Mock model invoked:", s["mock_model_invoked"])
print("Trace entries:", trace["summary"]["num_entries"])
print("Budget attempted requests:", budget["summary"]["attempted_requests"])
print("Budget executed requests:", budget["summary"]["executed_requests"])
print("Budget blocked requests:", budget["summary"]["blocked_requests"])
print("Spent USD:", budget["summary"]["spent_usd"])
print("Patched contract blocking count:", contract["summary"]["num_blocking"])
print("Patched contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])
print("Validation status:", validation["status"])
print("Guard output exists:", Path("experiments/runs/hisparse_u280_profile_guarded_generated_v023").exists())

assert probe["schema_version"] == "model_adapter_probe.v1"
assert probe["policy"]["schema_version"] == "model_adapter_policy.v1"
assert probe["request"]["schema_version"] == "llm_request.v1"
assert probe["response"]["schema_version"] == "llm_response.v1"
assert trace["schema_version"] == "llm_trace_ledger.v1"
assert budget["schema_version"] == "llm_budget_ledger.v1"
assert probe["policy"]["llm_enabled"] is False
assert probe["policy"]["default_backend"] == "disabled"
assert probe["policy"]["real_backend_allowed"] is False
assert probe["policy"]["network_access_allowed"] is False
assert probe["response"]["status"] == "blocked_by_policy"
assert probe["response"]["executed"] is False
assert probe["response"]["blocked_by_policy"] is True
assert s["real_model_invoked"] is False
assert s["mock_model_invoked"] is False
assert s["network_access_used"] is False
assert s["files_modified"] is False
assert s["contract_modified"] is False
assert s["generator_unlocked"] is False
assert trace["summary"]["num_entries"] == 1
assert trace["summary"]["num_executed"] == 0
assert trace["summary"]["num_blocked_by_policy"] == 1
assert trace["summary"]["real_model_invocations"] == 0
assert trace["summary"]["mock_model_invocations"] == 0
assert budget["summary"]["attempted_requests"] == 1
assert budget["summary"]["executed_requests"] == 0
assert budget["summary"]["blocked_requests"] == 1
assert budget["summary"]["spent_usd"] == 0.0
assert contract["summary"]["num_blocking"] == 6
assert "GAP-KERNEL-NAME-001" not in contract["summary"]["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in contract["summary"]["resolved_gap_ids"]
assert contract["migration_decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert len(guard["summary"]["blocking_gap_ids"]) == 6
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]
assert validation["status"] == "pass"
assert not Path("experiments/runs/hisparse_u280_profile_guarded_generated_v023").exists()
PY

echo
echo "DONE."
EOT

chmod +x add_model_adapter_v023_replay.sh

echo "[6/6] Run v0.0.23 replay"

./add_model_adapter_v023_replay.sh

echo "[v0.0.23] Git status"

git status
