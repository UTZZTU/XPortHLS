from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.application_ir_v2_builder import build_application_ir_v2, save_json
from xporthls.realrepo.validate_application_ir_v2_v014 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.14 ApplicationIR v2 build pipeline")
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--census", required=True)
    parser.add_argument("--source-profile", required=True)
    parser.add_argument("--build-ir", required=True)
    parser.add_argument("--connectivity-ir", required=True)
    parser.add_argument("--hls-ir", required=True)
    parser.add_argument("--compatibility-profile", default=None)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    app_path = out_dir / f"{args.case_id}_application_ir_v2_v014.json"
    report_path = out_dir / f"{args.case_id}_application_ir_v2_report_v014.json"

    app = build_application_ir_v2(
        case_id=args.case_id,
        target_platform=args.target_platform,
        target_ecosystem=args.target_ecosystem,
        census_path=args.census,
        source_profile_path=args.source_profile,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
        hls_ir_path=args.hls_ir,
        compatibility_profile_path=args.compatibility_profile,
    )

    save_json(str(app_path), app)

    report = validate(app)
    report.save(str(report_path))

    s = app["summary"]
    kg = app["kernel_graph"]["summary"]

    print(f"[xporthls] ApplicationIR v2: {app_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Source runtime: {s['source_runtime']}")
    print(f"[xporthls] Source boards: {s['source_boards']}")
    print(f"[xporthls] Source memory: {s['source_memory_model']}")
    print(f"[xporthls] Build files: {s['num_build_files']}")
    print(f"[xporthls] Build targets: {s['num_build_targets']}")
    print(f"[xporthls] Connectivity directives: {s['num_connectivity_directives']}")
    print(f"[xporthls] Memory mappings: {s['num_memory_mappings']}")
    print(f"[xporthls] Stream edges: {s['num_stream_edges']}")
    print(f"[xporthls] HLS files: {s['num_hls_files']}")
    print(f"[xporthls] HLS kernel candidates: {s['num_hls_kernel_candidates']}")
    print(f"[xporthls] HLS interface pragmas: {s['num_hls_interface_pragmas']}")
    print(f"[xporthls] Kernel graph nodes: {kg['num_kernels']}")
    print(f"[xporthls] Configured without declared: {kg['num_configured_without_declared']}")
    print(f"[xporthls] Declared without config: {kg['num_declared_without_config']}")
    print(f"[xporthls] Unsupported features: {s['num_unsupported_features']}")
    print(f"[xporthls] Unknowns: {s['num_unknowns']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
