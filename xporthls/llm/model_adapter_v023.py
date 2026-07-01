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
