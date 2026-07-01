from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.targetref.target_aware_resolver_plan_v026 import (
    build_target_aware_resolver_plan,
    build_target_aware_resolver_report,
    load_json,
    save_json,
)
from xporthls.targetref.validate_target_aware_resolver_plan_v026 import validate_target_aware_plan


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.26 target-aware resolver plan")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--pattern-pairing", required=True)
    parser.add_argument("--patched-contract", required=True)
    parser.add_argument("--old-resolver-plan", default=None)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--source-case-id", default="hisparse_u280_profile")
    parser.add_argument("--target-case-id", default="spmv_on_v80")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    app_ir = load_json(args.application_ir)
    target_ir = load_json(args.target_reference_ir)
    pairing = load_json(args.pattern_pairing)
    patched_contract = load_json(args.patched_contract)
    old_plan = load_json(args.old_resolver_plan) if args.old_resolver_plan else None
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    plan_path = out_dir / f"{prefix}_target_aware_resolver_plan_v026.json"
    report_path = out_dir / f"{prefix}_target_aware_resolver_plan_report_v026.json"
    validation_path = out_dir / f"{prefix}_target_aware_resolver_plan_validation_v026.json"

    plan = build_target_aware_resolver_plan(
        application_ir=app_ir,
        target_reference_ir=target_ir,
        pattern_pairing=pairing,
        patched_contract=patched_contract,
        old_resolver_plan=old_plan,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(plan_path, plan)

    report = build_target_aware_resolver_report(plan)
    save_json(report_path, report)

    validation = validate_target_aware_plan(plan, guard)
    validation.save(validation_path)

    s = plan["summary"]
    rec = plan["v027_recommendation"]

    print(f"[xporthls] Target-aware resolver plan: {plan_path}")
    print(f"[xporthls] Target-aware resolver report: {report_path}")
    print(f"[xporthls] Target-aware resolver validation: {validation_path}")
    print(f"[xporthls] Schema: {plan['schema_version']}")
    print(f"[xporthls] Migration direction: {plan['migration_direction']}")
    print(f"[xporthls] Source case: {plan['source_case_id']}")
    print(f"[xporthls] Target case: {plan['target_case_id']}")
    print(f"[xporthls] Resolvers: {s['num_resolvers']}")
    print(f"[xporthls] Ready for next resolver design: {s['ready_for_next_resolver_design_count']}")
    print(f"[xporthls] Normalize-only: {s['normalize_only_count']}")
    print(f"[xporthls] Missing evidence: {s['missing_evidence_count']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.26: {s['gaps_marked_resolved_by_v026']}")
    print(f"[xporthls] Contract blocking gap count: {s['contract_blocking_gap_count']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] v0.0.27 recommended resolver: {rec['recommended_next_resolver']}")
    print(f"[xporthls] v0.0.27 recommended gap: {rec['recommended_gap_id']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
