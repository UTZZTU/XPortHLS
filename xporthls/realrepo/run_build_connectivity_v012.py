from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.build_connectivity_extractor import build_ir, connectivity_ir, save_json
from xporthls.realrepo.validate_build_connectivity_v012 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.12 BuildIR + ConnectivityIR extraction pipeline")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    build_path = out_dir / f"{args.case_id}_build_ir_v012.json"
    conn_path = out_dir / f"{args.case_id}_connectivity_ir_v012.json"
    report_path = out_dir / f"{args.case_id}_build_connectivity_report_v012.json"

    build = build_ir(args.repo)
    conn = connectivity_ir(args.repo, build)

    save_json(str(build_path), build)
    save_json(str(conn_path), conn)

    report = validate(build, conn)
    report.save(str(report_path))

    print(f"[xporthls] BuildIR: {build_path}")
    print(f"[xporthls] ConnectivityIR: {conn_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Build files: {build['summary']['num_build_files']}")
    print(f"[xporthls] Targets: {build['summary']['num_targets']}")
    print(f"[xporthls] Commands: {build['summary']['num_commands']}")
    print(f"[xporthls] Platforms: {build['summary']['detected_platforms']}")
    print(f"[xporthls] Config files: {conn['summary']['num_config_files']}")
    print(f"[xporthls] Directives: {conn['summary']['num_directives']}")
    print(f"[xporthls] Memory mappings: {conn['summary']['num_memory_mappings']}")
    print(f"[xporthls] Compute-unit directives: {conn['summary']['num_compute_unit_directives']}")
    print(f"[xporthls] Stream edges: {conn['summary']['num_stream_edges']}")
    print(f"[xporthls] SLR assignments: {conn['summary']['num_slr_assignments']}")
    print(f"[xporthls] Memory kinds: {conn['summary']['memory_kinds']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
