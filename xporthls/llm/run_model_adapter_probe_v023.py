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
