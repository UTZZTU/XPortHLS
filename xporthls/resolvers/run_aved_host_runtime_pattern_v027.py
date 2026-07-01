from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.resolvers.aved_host_runtime_pattern_v027 import (
    build_aved_host_runtime_pattern,
    build_aved_host_runtime_report,
    load_json,
    save_json,
)
from xporthls.resolvers.validate_aved_host_runtime_pattern_v027 import validate_aved_host_runtime_pattern


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.27 AVED host runtime pattern resolver")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--pattern-pairing", required=True)
    parser.add_argument("--target-aware-plan", required=True)
    parser.add_argument("--patched-contract", required=True)
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
    target_aware_plan = load_json(args.target_aware_plan)
    patched_contract = load_json(args.patched_contract)
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    pattern_path = out_dir / f"{prefix}_aved_host_runtime_pattern_v027.json"
    report_path = out_dir / f"{prefix}_aved_host_runtime_pattern_report_v027.json"
    validation_path = out_dir / f"{prefix}_aved_host_runtime_pattern_validation_v027.json"

    pattern = build_aved_host_runtime_pattern(
        application_ir=app_ir,
        target_reference_ir=target_ir,
        pattern_pairing=pairing,
        target_aware_plan=target_aware_plan,
        patched_contract=patched_contract,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(pattern_path, pattern)

    report = build_aved_host_runtime_report(pattern)
    save_json(report_path, report)

    validation = validate_aved_host_runtime_pattern(pattern, guard)
    validation.save(validation_path)

    s = pattern["summary"]

    print(f"[xporthls] AVED host runtime pattern: {pattern_path}")
    print(f"[xporthls] AVED host runtime report: {report_path}")
    print(f"[xporthls] AVED host runtime validation: {validation_path}")
    print(f"[xporthls] Schema: {pattern['schema_version']}")
    print(f"[xporthls] Migration direction: {pattern['migration_direction']}")
    print(f"[xporthls] Gap ID: {pattern['gap_id']}")
    print(f"[xporthls] Resolver: {pattern['resolver_name']}")
    print(f"[xporthls] Pattern state: {pattern['pattern_state']}")
    print(f"[xporthls] Ready for contract resolution: {pattern['ready_for_contract_resolution']}")
    print(f"[xporthls] Host action mappings: {s['host_action_mapping_count']}")
    print(f"[xporthls] Mapped with source+target evidence: {s['mapped_with_source_and_target_evidence_count']}")
    print(f"[xporthls] Mapped with target evidence / source sparse: {s['mapped_with_target_evidence_source_sparse_count']}")
    print(f"[xporthls] Needs more target evidence: {s['mapped_but_needs_more_target_evidence_count']}")
    print(f"[xporthls] Target QDMA evidence: {s['target_qdma_evidence_count']}")
    print(f"[xporthls] Target AXI-Lite evidence: {s['target_axi_lite_evidence_count']}")
    print(f"[xporthls] Target AP_CTRL evidence: {s['target_ap_ctrl_evidence_count']}")
    print(f"[xporthls] Unresolved dependency count: {s['unresolved_dependency_count']}")
    print(f"[xporthls] Host gap still blocking: {s['host_gap_still_blocking']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.27: {s['gaps_marked_resolved_by_v027']}")
    print(f"[xporthls] Contract blocking gap count: {s['contract_blocking_gap_count']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
