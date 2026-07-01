from __future__ import annotations

import argparse

from xporthls.validators.l0_pre_checker import run_l0_pre
from xporthls.validators.l0_post_checker import run_l0_post


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XPortHLS L0 validation")
    parser.add_argument("--stage", choices=["pre", "post"], default="pre")
    parser.add_argument("--app-ir", default=None, help="ApplicationIR JSON path for L0-pre")
    parser.add_argument("--contract", default=None, help="MigrationContract JSON path")
    parser.add_argument("--project", default=None, help="Generated project path for L0-post")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.stage == "pre":
        if not args.app_ir:
            parser.error("--app-ir is required for --stage pre")
        report = run_l0_pre(args.app_ir, args.contract)
    else:
        if not args.project:
            parser.error("--project is required for --stage post")
        report = run_l0_post(args.project, args.contract)

    report.save(args.out)

    print(f"[xporthls] {report.stage} report written to: {args.out}")
    print(f"[xporthls] {report.stage} status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
