from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.repo_census import discover_repo, save_json as save_census_json
from xporthls.realrepo.source_platform_profiler import infer_source_profile, save_json as save_source_json
from xporthls.realrepo.compatibility_profiler import build_compatibility_profile, save_json as save_compat_json
from xporthls.realrepo.validate_realrepo_profile_v011 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.11 real repository profiling pipeline")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--case-id", default="hisparse")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    census_path = out_dir / f"{args.case_id}_repo_census_v011.json"
    source_path = out_dir / f"{args.case_id}_source_platform_profile_v011.json"
    compat_path = out_dir / f"{args.case_id}_compatibility_profile_v011.json"
    validation_path = out_dir / f"{args.case_id}_realrepo_profile_report_v011.json"

    census = discover_repo(args.repo)
    save_census_json(str(census_path), census)

    source = infer_source_profile(census)
    save_source_json(str(source_path), source)

    compat = build_compatibility_profile(
        census=census,
        source_profile=source,
        target_platform=args.target_platform,
        target_ecosystem=args.target_ecosystem,
    )
    save_compat_json(str(compat_path), compat)

    report = validate(census, source, compat)
    report.save(str(validation_path))

    print(f"[xporthls] Repo census: {census_path}")
    print(f"[xporthls] Source platform profile: {source_path}")
    print(f"[xporthls] Compatibility profile: {compat_path}")
    print(f"[xporthls] Validation report: {validation_path}")
    print(f"[xporthls] Files: {census['summary']['num_files']}")
    print(f"[xporthls] Source runtime: {source['source_runtime']}")
    print(f"[xporthls] Source boards: {source['source_boards_detected']}")
    print(f"[xporthls] Source memory: {source['source_memory_model']}")
    print(f"[xporthls] Complexity: {source['complexity']['level']}")
    print(f"[xporthls] Migration status: {compat['migration_status']}")
    print(f"[xporthls] Required next capabilities: {compat['required_next_capabilities']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
