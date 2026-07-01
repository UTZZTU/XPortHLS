from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from xporthls.targetref.target_reference_ir_v024 import build_target_reference_ir, save_json, utc_now
from xporthls.targetref.validate_target_reference_v024 import validate_target_reference


def write_report(path: str | Path, ir: dict[str, Any], validation_status: str | None = None) -> dict[str, Any]:
    summary = ir.get("summary", {})
    report = {
        "schema_version": "target_reference_intake_report.v1",
        "xporthls_version": "v0.0.24",
        "created_at_utc": utc_now(),
        "case_id": ir.get("case_id"),
        "target_reference_name": ir.get("target_reference_name"),
        "migration_direction": ir.get("migration_direction"),
        "target_reference_role": ir.get("target_reference_role"),
        "target_ecosystem": ir.get("target_ecosystem"),
        "target_board": ir.get("target_board"),
        "summary": {
            **summary,
            "validation_status": validation_status,
        },
        "artifact_refs": {
            "facts_digest": ir.get("facts_digest"),
        },
        "trust_boundary": ir.get("trust_boundary", {}),
        "llm_annotations": [],
    }
    save_json(path, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.24 target reference intake")
    parser.add_argument("--target-root", required=True)
    parser.add_argument("--case-id", default="spmv_on_v80")
    parser.add_argument("--target-name", default="SPMV-on-V80")
    parser.add_argument("--out-dir", default="experiments/runs")
    parser.add_argument("--guard-report", default=None)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    ir_path = out_dir / f"{args.case_id}_target_reference_ir_v024.json"
    report_path = out_dir / f"{args.case_id}_target_reference_report_v024.json"
    validation_path = out_dir / f"{args.case_id}_target_reference_validation_v024.json"

    ir = build_target_reference_ir(
        target_root=args.target_root,
        case_id=args.case_id,
        target_name=args.target_name,
    )
    save_json(ir_path, ir)

    guard = None
    if args.guard_report:
        with open(args.guard_report, "r", encoding="utf-8") as f:
            guard = json.load(f)

    validation = validate_target_reference(ir, guard)
    validation.save(validation_path)

    report = write_report(report_path, ir, validation.status)

    s = ir["summary"]
    print(f"[xporthls] TargetReferenceIR: {ir_path}")
    print(f"[xporthls] Target reference report: {report_path}")
    print(f"[xporthls] Target reference validation: {validation_path}")
    print(f"[xporthls] Schema: {ir['schema_version']}")
    print(f"[xporthls] Migration direction: {ir['migration_direction']}")
    print(f"[xporthls] Target ecosystem: {ir['target_ecosystem']}")
    print(f"[xporthls] Target board: {ir['target_board']}")
    print(f"[xporthls] Files: {s['files_total']}")
    print(f"[xporthls] Documents: {s['documentation_files']}")
    print(f"[xporthls] Variants: {s['variant_count']}")
    print(f"[xporthls] QDMA evidence: {s['host_qdma_evidence_count']}")
    print(f"[xporthls] AXI-Lite evidence: {s['host_axi_lite_evidence_count']}")
    print(f"[xporthls] AP_CTRL evidence: {s['host_ap_ctrl_evidence_count']}")
    print(f"[xporthls] HLS m_axi evidence: {s['hls_m_axi_evidence_count']}")
    print(f"[xporthls] HLS axis evidence: {s['hls_axis_evidence_count']}")
    print(f"[xporthls] HLS packaging evidence: {s['hls_packaging_evidence_count']}")
    print(f"[xporthls] create_design.tcl: {s['create_design_tcl_count']}")
    print(f"[xporthls] create_bd_design.tcl: {s['create_bd_design_tcl_count']}")
    print(f"[xporthls] BD connect_bd_intf_net: {s['bd_connect_bd_intf_net_count']}")
    print(f"[xporthls] BD assign_bd_address: {s['bd_assign_bd_address_count']}")
    print(f"[xporthls] F_VERSION_CORRECTNESS: {s['has_f_version_correctness']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
