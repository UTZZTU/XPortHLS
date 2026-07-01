from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from xporthls.scanner.repo_scanner import scan_repository
from xporthls.ir.platform_ir import PlatformIR
from xporthls.ir.migration_contract import MigrationContract
from xporthls.trace.run_logger import RunTrace, utc_now, new_run_dir, run_command


def cmd_env(args: argparse.Namespace) -> int:
    run_dir = new_run_dir("env")
    checks = {
        "python": run_command(["python3", "--version"]),
        "git": run_command(["git", "--version"]),
        "vivado": run_command(["vivado", "-version"], timeout=20),
        "vitis": run_command(["vitis", "-v"], timeout=20),
        "vpp": run_command(["v++", "--version"], timeout=20),
        "vitis_hls_help": run_command(["vitis_hls", "--help"], timeout=20),
    }
    data = {
        "environment": {
            "cwd": os.getcwd(),
            "PATH": os.environ.get("PATH", ""),
            "XILINX_VIVADO": os.environ.get("XILINX_VIVADO", ""),
            "XILINX_VITIS": os.environ.get("XILINX_VITIS", ""),
            "XILINX_HLS": os.environ.get("XILINX_HLS", ""),
            "XILINXD_LICENSE_FILE": os.environ.get("XILINXD_LICENSE_FILE", "")
        },
        "checks": checks
    }
    out = run_dir / "environment.json"
    out.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")

    trace = RunTrace(
        command="env",
        started_at=utc_now(),
        status="ok",
        artifacts=[str(out)]
    )
    trace.save(str(run_dir / "trace.json"))

    print(f"[xporthls] Environment report written to: {out}")
    return 0


def cmd_scan(args: argparse.Namespace) -> int:
    ir = scan_repository(args.case)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    ir.save(str(out))

    run_dir = new_run_dir("scan")
    trace = RunTrace(
        command=f"scan --case {args.case} --out {args.out}",
        started_at=utc_now(),
        status="ok",
        metadata={
            "case": args.case,
            "num_files": len(ir.source_files),
            "num_xrt_calls": len(ir.host_apis),
            "num_kernel_candidates": len(ir.kernels),
            "num_buffers": len(ir.buffers),
            "num_kernel_invocations": len(ir.kernel_invocations),
            "num_sync_operations": len(ir.sync_operations),
            "num_host_transfers": len(ir.host_transfers),
            "num_unknowns": len(ir.unknowns),
            "warnings": ir.warnings
        },
        artifacts=[str(out)]
    )
    trace.save(str(run_dir / "trace.json"))

    print(f"[xporthls] ApplicationIR written to: {out}")
    print(f"[xporthls] Files: {len(ir.source_files)}")
    print(f"[xporthls] XRT calls: {len(ir.host_apis)}")
    print(f"[xporthls] Kernel candidates: {len(ir.kernels)}")
    print(f"[xporthls] Buffers: {len(ir.buffers)}")
    print(f"[xporthls] Kernel invocations: {len(ir.kernel_invocations)}")
    print(f"[xporthls] Sync operations: {len(ir.sync_operations)}")
    print(f"[xporthls] Host transfers: {len(ir.host_transfers)}")
    print(f"[xporthls] Unknowns: {len(ir.unknowns)}")
    if ir.warnings:
        print("[xporthls] Warnings:")
        for w in ir.warnings:
            print(f"  - {w}")
    return 0


def cmd_contract(args: argparse.Namespace) -> int:
    with open(args.app_ir, "r", encoding="utf-8") as f:
        app = json.load(f)
    platform = PlatformIR.load_json(args.platform)

    contract = MigrationContract(
        contract_id=f"{app.get('project', 'unknown')}_to_{platform.platform_id}",
        source_project=app.get("project", "unknown"),
        target_platform=platform.platform_id,
        scope={
            "source_runtime": app.get("source_runtime", "XRT"),
            "target_ecosystem": platform.target.get("ecosystem", "AVED"),
            "target_board": platform.target.get("board", "Alveo V80"),
            "vivado": platform.target.get("vivado", "unknown"),
            "mode": platform.status
        },
        obligations=[
            {
                "id": "O1",
                "kind": "traceability",
                "text": "Every generated patch must be linked to source evidence, contract obligation and validation result."
            },
            {
                "id": "O2",
                "kind": "correctness_first",
                "text": "Functional correctness must be validated before any PPA optimization."
            },
            {
                "id": "O3",
                "kind": "version_awareness",
                "text": "Target generation must use the selected AVED/Vivado/QDMA version combination."
            }
        ],
        unsupported=[]
    )

    if platform.status.startswith("stub"):
        contract.unsupported.append({
            "kind": "platform_stub",
            "reason": "Real AVED project is not available yet. L4/L5 validation will be marked unavailable."
        })

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    contract.save(str(out))
    print(f"[xporthls] MigrationContract written to: {out}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    root = Path(args.runs)
    if not root.exists():
        print(f"[xporthls] Runs directory does not exist: {root}")
        return 1

    traces = sorted(root.glob("*/trace.json"))
    print(f"[xporthls] Found {len(traces)} trace files under {root}")
    for t in traces[-20:]:
        try:
            data = json.loads(t.read_text(encoding="utf-8"))
            print(f"- {t.parent.name}: {data.get('command')} [{data.get('status')}]")
        except Exception:
            print(f"- {t.parent.name}: unreadable trace")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="xporthls", description="XPortHLS command line interface")
    sub = p.add_subparsers(dest="cmd", required=True)

    env_p = sub.add_parser("env", help="Collect local toolchain environment information")
    env_p.set_defaults(func=cmd_env)

    scan_p = sub.add_parser("scan", help="Scan an XRT/HLS repository and emit ApplicationIR")
    scan_p.add_argument("--case", required=True, help="Path to case repository")
    scan_p.add_argument("--out", required=True, help="Output ApplicationIR JSON path")
    scan_p.set_defaults(func=cmd_scan)

    contract_p = sub.add_parser("contract", help="Create a first MigrationContract from ApplicationIR and PlatformIR")
    contract_p.add_argument("--app-ir", required=True, help="ApplicationIR JSON path")
    contract_p.add_argument("--platform", required=True, help="PlatformIR JSON path")
    contract_p.add_argument("--out", required=True, help="Output MigrationContract JSON path")
    contract_p.set_defaults(func=cmd_contract)

    report_p = sub.add_parser("report", help="Summarize traces")
    report_p.add_argument("--runs", default="/mnt/data/xporthls_runs", help="Runs directory")
    report_p.set_defaults(func=cmd_report)

    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
