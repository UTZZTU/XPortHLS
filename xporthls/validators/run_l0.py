from __future__ import annotations

import argparse
from xporthls.validators.l0_static_checker import run_l0_static


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XPortHLS L0 static validation")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--contract", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = run_l0_static(args.app_ir, args.contract)
    report.save(args.out)

    print(f"[xporthls] L0 report written to: {args.out}")
    print(f"[xporthls] L0 status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
