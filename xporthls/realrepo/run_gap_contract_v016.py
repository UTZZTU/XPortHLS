from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_contract_v016 import build_gap_contract, save_json
from xporthls.realrepo.validate_gap_contract_v016 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.16 Source-to-Target Gap Contract pipeline")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--expected-gaps", default="cases/hisparse_u280_profile/expected_gaps.json")
    parser.add_argument("--platform-pack", default="platform_packs/v80_aved_2025_1_stub")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    contract_path = out_dir / f"{args.case_id}_gap_contract_v016.json"
    report_path = out_dir / f"{args.case_id}_gap_contract_report_v016.json"

    contract = build_gap_contract(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        expected_gaps_path=args.expected_gaps,
        platform_pack_dir=args.platform_pack,
        out_contract_path=str(contract_path),
    )
    save_json(contract_path, contract)

    report = validate(contract)
    report.save(str(report_path))

    s = contract["summary"]
    print(f"[xporthls] Gap Contract: {contract_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Contract state: {contract['contract_state']}")
    print(f"[xporthls] Migration allowed: {s['migration_allowed']}")
    print(f"[xporthls] Gaps: {s['num_gaps']}")
    print(f"[xporthls] Blocking: {s['num_blocking']}")
    print(f"[xporthls] Warnings: {s['num_warnings']}")
    print(f"[xporthls] Info: {s['num_info']}")
    print(f"[xporthls] Blocking IDs: {s['blocking_gap_ids']}")
    print(f"[xporthls] Missing expected capabilities: {s['missing_expected_capabilities']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
