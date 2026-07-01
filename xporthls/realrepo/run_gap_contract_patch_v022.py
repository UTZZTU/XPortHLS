from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_contract_patch_v022 import apply_kernel_gap_patch
from xporthls.realrepo.validate_gap_contract_patch_v022 import load_json, validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.22 Gap Contract Patch Apply")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--original-contract", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    patched_contract_path = out_dir / f"{args.case_id}_gap_contract_patched_v022.json"
    patch_report_path = out_dir / f"{args.case_id}_gap_contract_patch_report_v022.json"
    validation_path = out_dir / f"{args.case_id}_gap_contract_patch_validation_v022.json"

    patched, patch_report = apply_kernel_gap_patch(
        case_id=args.case_id,
        original_contract_path=args.original_contract,
        proposal_path=args.proposal,
        v2_report_path=args.v2_report,
        patched_contract_path=str(patched_contract_path),
        patch_report_path=str(patch_report_path),
    )

    original = load_json(args.original_contract)
    proposal = load_json(args.proposal)
    v2_report = load_json(args.v2_report)
    validation = validate(original, patched, patch_report, proposal, v2_report, None)
    validation.save(validation_path)

    s = patch_report["summary"]
    print(f"[xporthls] Patched Gap Contract: {patched_contract_path}")
    print(f"[xporthls] Patch report: {patch_report_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Applied: {s['applied']}")
    print(f"[xporthls] Removed target gap from blocking: {s['removed_target_gap_from_blocking']}")
    print(f"[xporthls] Contract state: {patched.get('contract_state')}")
    print(f"[xporthls] Migration allowed: {patched.get('migration_decision', {}).get('allowed')}")
    print(f"[xporthls] Remaining blocking count: {s['remaining_blocking_count']}")
    print(f"[xporthls] Remaining blocking IDs: {s['remaining_blocking_gap_ids']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
