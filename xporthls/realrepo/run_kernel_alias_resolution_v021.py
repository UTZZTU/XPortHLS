from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_alias_table_v021 import build_kernel_alias_table, save_json
from xporthls.realrepo.kernel_name_resolver_v021 import build_kernel_name_resolution_v2_report
from xporthls.realrepo.kernel_gap_update_proposal_v021 import build_kernel_gap_update_proposal
from xporthls.realrepo.validate_kernel_alias_resolution_v021 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.21 Kernel Alias Table + Resolver v2")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--diagnosis", required=True)
    parser.add_argument("--v1-report", required=True)
    parser.add_argument("--gap-contract", required=True)
    parser.add_argument("--resolver-plan", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    parser.add_argument("--min-similarity", type=float, default=0.72)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    alias_table_path = out_dir / f"{args.case_id}_kernel_alias_table_v021.json"
    v2_report_path = out_dir / f"{args.case_id}_kernel_name_resolution_report_v2_v021.json"
    proposal_path = out_dir / f"{args.case_id}_kernel_gap_update_proposal_v021.json"
    validation_path = out_dir / f"{args.case_id}_kernel_alias_resolution_validation_v021.json"

    alias_table = build_kernel_alias_table(
        case_id=args.case_id,
        diagnosis_path=args.diagnosis,
        kernel_resolution_path=args.v1_report,
        out_path=str(alias_table_path),
        min_similarity=args.min_similarity,
    )
    save_json(alias_table_path, alias_table)

    v2_report = build_kernel_name_resolution_v2_report(
        case_id=args.case_id,
        v1_report_path=args.v1_report,
        alias_table_path=str(alias_table_path),
        diagnosis_path=args.diagnosis,
        gap_contract_path=args.gap_contract,
        resolver_plan_path=args.resolver_plan,
        out_path=str(v2_report_path),
    )
    save_json(v2_report_path, v2_report)

    proposal = build_kernel_gap_update_proposal(
        case_id=args.case_id,
        gap_contract_path=args.gap_contract,
        v2_report_path=str(v2_report_path),
        alias_table_path=str(alias_table_path),
        out_path=str(proposal_path),
    )
    save_json(proposal_path, proposal)

    validation = validate(alias_table, v2_report, proposal)
    validation.save(validation_path)

    print(f"[xporthls] Kernel Alias Table: {alias_table_path}")
    print(f"[xporthls] Kernel Name Resolution v2: {v2_report_path}")
    print(f"[xporthls] Kernel Gap Update Proposal: {proposal_path}")
    print(f"[xporthls] Validation report: {validation_path}")

    a = alias_table["summary"]
    v = v2_report["summary"]
    p = proposal["summary"]
    print(f"[xporthls] Aliases: {a['num_aliases']}")
    print(f"[xporthls] V1 matches: {v['num_v1_matches']}")
    print(f"[xporthls] V2 alias matches: {v['num_v2_alias_matches']}")
    print(f"[xporthls] Total matches: {v['num_total_matches']}")
    print(f"[xporthls] Unresolved configured: {v['num_unresolved_configured']}")
    print(f"[xporthls] All configured resolved: {v['all_configured_resolved']}")
    print(f"[xporthls] Proposal state: {proposal['proposal_state']}")
    print(f"[xporthls] Generator unlock allowed: {p['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
