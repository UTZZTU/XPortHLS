from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.kernel_unresolved_diagnosis_v020 import build_kernel_unresolved_diagnosis, save_json
from xporthls.realrepo.validate_kernel_unresolved_diagnosis_v020 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.20 Kernel Unresolved Diagnosis")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--kernel-resolution-report", required=True)
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    diagnosis_path = out_dir / f"{args.case_id}_kernel_unresolved_diagnosis_v020.json"
    validation_path = out_dir / f"{args.case_id}_kernel_unresolved_diagnosis_validation_v020.json"

    diagnosis = build_kernel_unresolved_diagnosis(
        case_id=args.case_id,
        kernel_resolution_report_path=args.kernel_resolution_report,
        app_ir_path=args.app_ir,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
        hls_ir_path=args.hls_ir,
        out_path=str(diagnosis_path),
    )
    save_json(diagnosis_path, diagnosis)

    validation = validate(diagnosis)
    validation.save(validation_path)

    s = diagnosis["summary"]
    print(f"[xporthls] Kernel Unresolved Diagnosis: {diagnosis_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Report schema: {diagnosis['schema_version']}")
    print(f"[xporthls] Unresolved configured: {s['num_unresolved_configured']}")
    print(f"[xporthls] Diagnosed: {s['num_diagnosed']}")
    print(f"[xporthls] Classification counts: {s['classification_counts']}")
    print(f"[xporthls] High confidence: {s['num_high_confidence']}")
    print(f"[xporthls] Medium confidence: {s['num_medium_confidence']}")
    print(f"[xporthls] Low confidence: {s['num_low_confidence']}")
    print(f"[xporthls] Safe auto-resolve candidates: {s['num_safe_to_auto_resolve_candidates']}")
    print(f"[xporthls] Must remain blocking: {s['must_remain_blocking']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Proposed v2 tasks: {len(diagnosis['proposed_resolver_v2_tasks'])}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
