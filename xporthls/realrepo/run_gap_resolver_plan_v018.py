from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_resolver_plan_v018 import build_gap_resolver_plan, save_json
from xporthls.realrepo.validate_gap_resolver_plan_v018 import load_json, validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.18 Gap Resolver Plan pipeline")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    plan_path = out_dir / f"{args.case_id}_gap_resolver_plan_v018.json"
    report_path = out_dir / f"{args.case_id}_gap_resolver_plan_report_v018.json"

    plan = build_gap_resolver_plan(
        case_id=args.case_id,
        contract_path=args.contract,
        out_path=str(plan_path),
    )
    save_json(plan_path, plan)

    contract = load_json(args.contract)
    report = validate(plan, contract)
    report.save(report_path)

    s = plan["summary"]
    print(f"[xporthls] Gap Resolver Plan: {plan_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Plan state: {plan['plan_state']}")
    print(f"[xporthls] Generation allowed: {s['generation_allowed']}")
    print(f"[xporthls] Resolver execution allowed: {s['resolver_execution_allowed']}")
    print(f"[xporthls] Resolvers: {s['num_resolvers']}")
    print(f"[xporthls] Blocking resolvers: {s['num_blocking_resolvers']}")
    print(f"[xporthls] Warnings resolvers: {s['num_warning_resolvers']}")
    print(f"[xporthls] Info resolvers: {s['num_info_resolvers']}")
    print(f"[xporthls] Blocking resolver IDs: {s['blocking_resolver_ids']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
