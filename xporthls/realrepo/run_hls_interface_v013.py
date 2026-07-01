from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.hls_interface_extractor import build_hls_interface_ir, save_json
from xporthls.realrepo.validate_hls_interface_v013 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.13 HLS Interface extraction pipeline")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--build-ir", default=None)
    parser.add_argument("--connectivity-ir", default=None)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    hls_path = out_dir / f"{args.case_id}_hls_interface_ir_v013.json"
    report_path = out_dir / f"{args.case_id}_hls_interface_report_v013.json"

    ir = build_hls_interface_ir(
        repo_path=args.repo,
        build_ir_path=args.build_ir,
        connectivity_ir_path=args.connectivity_ir,
    )
    save_json(str(hls_path), ir)

    report = validate(ir)
    report.save(str(report_path))

    s = ir["summary"]
    print(f"[xporthls] HLS Interface IR: {hls_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] HLS files: {s['num_hls_files']}")
    print(f"[xporthls] Functions: {s['num_functions']}")
    print(f"[xporthls] Kernel candidates: {s['num_kernel_candidates']}")
    print(f"[xporthls] Interface pragmas: {s['num_interface_pragmas']}")
    print(f"[xporthls] Interface types: {s['interface_types']}")
    print(f"[xporthls] Dataflow pragmas: {s['num_dataflow']}")
    print(f"[xporthls] Stream variables: {s['num_stream_variables']}")
    print(f"[xporthls] Include edges: {s['num_include_edges']}")
    print(f"[xporthls] Configured kernels: {s['num_configured_kernels']}")
    print(f"[xporthls] Matched configured kernels: {s['num_matched_configured_kernels']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
