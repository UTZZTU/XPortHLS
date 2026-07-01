from __future__ import annotations

import argparse
import json
from pathlib import Path

from xporthls.targetref.pattern_pairing_v025 import (
    build_pairing_report,
    build_source_target_pattern_pairing,
    load_json,
    save_json,
)
from xporthls.targetref.validate_pattern_pairing_v025 import validate_pattern_pairing


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.25 source-target pattern pairing")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--patched-contract", default=None)
    parser.add_argument("--resolver-plan", default=None)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--source-case-id", default="hisparse_u280_profile")
    parser.add_argument("--target-case-id", default="spmv_on_v80")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    application_ir = load_json(args.application_ir)
    target_reference_ir = load_json(args.target_reference_ir)
    patched_contract = load_json(args.patched_contract) if args.patched_contract else None
    resolver_plan = load_json(args.resolver_plan) if args.resolver_plan else None
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    pairing_path = out_dir / f"{prefix}_pattern_pairing_v025.json"
    report_path = out_dir / f"{prefix}_pattern_pairing_report_v025.json"
    validation_path = out_dir / f"{prefix}_pattern_pairing_validation_v025.json"

    pairing = build_source_target_pattern_pairing(
        application_ir=application_ir,
        target_reference_ir=target_reference_ir,
        patched_contract=patched_contract,
        resolver_plan=resolver_plan,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(pairing_path, pairing)

    report = build_pairing_report(pairing)
    save_json(report_path, report)

    validation = validate_pattern_pairing(pairing, guard)
    validation.save(validation_path)

    s = pairing["summary"]
    cov = pairing["coverage"]

    print(f"[xporthls] Pattern pairing: {pairing_path}")
    print(f"[xporthls] Pattern pairing report: {report_path}")
    print(f"[xporthls] Pattern pairing validation: {validation_path}")
    print(f"[xporthls] Schema: {pairing['schema_version']}")
    print(f"[xporthls] Migration direction: {pairing['migration_direction']}")
    print(f"[xporthls] Source case: {pairing['source_case_id']}")
    print(f"[xporthls] Target case: {pairing['target_case_id']}")
    print(f"[xporthls] Pairings: {s['num_pairings']}")
    print(f"[xporthls] Paired gaps: {s['paired_gap_count']}")
    print(f"[xporthls] Partial gaps: {s['partial_gap_count']}")
    print(f"[xporthls] Unpaired gaps: {s['unpaired_gap_count']}")
    print(f"[xporthls] Expected blockers: {cov['expected_remaining_blocking_gaps']}")
    print(f"[xporthls] Paired gap IDs: {cov['paired_gap_ids']}")
    print(f"[xporthls] Paired with target evidence: {cov['paired_with_target_reference_evidence']}")
    print(f"[xporthls] Partial target evidence: {cov['partial_target_reference_evidence']}")
    print(f"[xporthls] Unpaired needing evidence: {cov['unpaired_needs_more_evidence']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.25: {s['gaps_marked_resolved_by_v025']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
