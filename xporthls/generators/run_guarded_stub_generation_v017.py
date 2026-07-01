from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.generators.generator_guard import enforce_guard


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a contract-gated target generation attempt. In v0.0.17 this is a guard-only wrapper."
    )
    parser.add_argument("--contract", required=True)
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--requested-output-dir", default=None)
    parser.add_argument("--report-out", default=None)
    parser.add_argument("--generator-name", default="stub_generator")
    parser.add_argument("--expect-blocked", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    requested_output_dir = args.requested_output_dir
    if requested_output_dir is None:
        requested_output_dir = f"experiments/runs/{args.case_id}_guarded_generated_v017"

    report_out = args.report_out
    if report_out is None:
        report_out = f"experiments/runs/{args.case_id}_generator_guard_report_v017.json"

    Path(report_out).parent.mkdir(parents=True, exist_ok=True)

    return enforce_guard(
        contract_path=args.contract,
        requested_output_dir=requested_output_dir,
        report_out=report_out,
        generator_name=args.generator_name,
        requested_action="generate_target_project",
        dry_run=args.dry_run,
        expect_blocked=args.expect_blocked,
    )


if __name__ == "__main__":
    raise SystemExit(main())
