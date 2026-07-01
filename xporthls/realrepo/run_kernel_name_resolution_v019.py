from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_name_resolver_v019 import build_kernel_name_resolution_report, save_json
from xporthls.realrepo.validate_kernel_name_resolution_v019 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.19 Kernel Name Resolver")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    report_path = out_dir / f"{args.case_id}_kernel_name_resolution_report_v019.json"
    validation_path = out_dir / f"{args.case_id}_kernel_name_resolution_validation_v019.json"

    report = build_kernel_name_resolution_report(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=str(report_path),
    )
    save_json(report_path, report)

    validation = validate(report)
    validation.save(validation_path)

    s = report["summary"]
    print(f"[xporthls] Kernel Name Resolution report: {report_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Resolution state: {report['resolution_state']}")
    print(f"[xporthls] Configured kernels: {s['num_configured_kernels']}")
    print(f"[xporthls] Declared functions: {s['num_declared_functions']}")
    print(f"[xporthls] Matches: {s['num_matches']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Unresolved declared: {s['num_unresolved_declared']}")
    print(f"[xporthls] Match methods: {s['match_methods']}")
    print(f"[xporthls] Proposed gap state: {report['gap_transition_proposal']['proposed_gap_state']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
