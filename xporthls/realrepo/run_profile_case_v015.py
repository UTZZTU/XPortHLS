from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class CaseStage:
    name: str
    command: list[str]
    return_code: int
    elapsed_sec: float


@dataclass
class ProfileCaseRun:
    schema_version: str
    case_id: str
    status: str
    repo_path: str
    target_platform: str
    target_ecosystem: str
    created_at_utc: str
    stages: list[CaseStage] = field(default_factory=list)
    artifacts: dict[str, str] = field(default_factory=dict)
    summary: dict[str, Any] = field(default_factory=dict)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def run_command(name: str, command: list[str], stages: list[CaseStage], timeout_sec: int) -> None:
    print(f"\n[xporthls-case] START {name}", flush=True)
    print("[xporthls-case] CMD:", " ".join(command), flush=True)

    started = time.time()

    try:
        proc = subprocess.run(command, timeout=timeout_sec)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        elapsed = time.time() - started
        stages.append(CaseStage(name=name, command=command, return_code=124, elapsed_sec=round(elapsed, 3)))
        print(f"[xporthls-case] TIMEOUT {name} after {timeout_sec}s", flush=True)
        raise RuntimeError(f"Case stage timed out: {name}")

    elapsed = time.time() - started
    stages.append(CaseStage(name=name, command=command, return_code=rc, elapsed_sec=round(elapsed, 3)))

    print(f"[xporthls-case] END {name} rc={rc} elapsed={elapsed:.2f}s", flush=True)

    if rc != 0:
        raise RuntimeError(f"Case stage failed: {name}")


def ensure_repo(repo_url: str, branch: str, checkout: str) -> None:
    checkout_path = Path(checkout)
    checkout_path.parent.mkdir(parents=True, exist_ok=True)

    skip_pull = os.environ.get("XPORT_HISPARSE_SKIP_PULL", "1") != "0"

    if not (checkout_path / ".git").exists():
        print(f"[xporthls-case] Cloning source repo: {repo_url}", flush=True)
        subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", branch, repo_url, checkout],
            check=True,
            timeout=600,
        )
        return

    print(f"[xporthls-case] Using existing checkout: {checkout}", flush=True)
    subprocess.run(["git", "-C", checkout, "checkout", branch], check=True, timeout=120)

    if skip_pull:
        print("[xporthls-case] Skip git pull by default. Set XPORT_HISPARSE_SKIP_PULL=0 to update.", flush=True)
    else:
        subprocess.run(["git", "-C", checkout, "pull", "--ff-only"], check=False, timeout=300)


def build_summary(artifacts: dict[str, str]) -> dict[str, Any]:
    census = load_json(artifacts["repo_census"])
    source = load_json(artifacts["source_profile"])
    build = load_json(artifacts["build_ir"])
    conn = load_json(artifacts["connectivity_ir"])
    hls = load_json(artifacts["hls_ir"])
    app = load_json(artifacts["application_ir_v2"])
    app_report = load_json(artifacts["application_ir_v2_report"])

    return {
        "repo_files": census.get("summary", {}).get("num_files"),
        "source_runtime": source.get("source_runtime"),
        "source_boards": source.get("source_boards_detected", []),
        "source_memory_model": source.get("source_memory_model"),
        "source_toolchains": source.get("source_toolchains_detected", {}),
        "build_files": build.get("summary", {}).get("num_build_files"),
        "build_targets": build.get("summary", {}).get("num_targets"),
        "build_commands": build.get("summary", {}).get("num_commands"),
        "detected_platforms": build.get("summary", {}).get("detected_platforms", []),
        "connectivity_config_files": conn.get("summary", {}).get("num_config_files"),
        "connectivity_directives": conn.get("summary", {}).get("num_directives"),
        "memory_mappings": conn.get("summary", {}).get("num_memory_mappings"),
        "stream_edges": conn.get("summary", {}).get("num_stream_edges"),
        "slr_assignments": conn.get("summary", {}).get("num_slr_assignments"),
        "memory_kinds": conn.get("summary", {}).get("memory_kinds", []),
        "hls_files": hls.get("summary", {}).get("num_hls_files"),
        "hls_kernel_candidates": hls.get("summary", {}).get("num_kernel_candidates"),
        "hls_interface_pragmas": hls.get("summary", {}).get("num_interface_pragmas"),
        "hls_m_axi": hls.get("summary", {}).get("num_m_axi"),
        "hls_axis": hls.get("summary", {}).get("num_axis"),
        "hls_s_axilite": hls.get("summary", {}).get("num_s_axilite"),
        "hls_dataflow": hls.get("summary", {}).get("num_dataflow"),
        "kernel_graph_nodes": app.get("kernel_graph", {}).get("summary", {}).get("num_kernels"),
        "configured_without_declared": app.get("kernel_graph", {}).get("summary", {}).get("num_configured_without_declared"),
        "declared_without_config": app.get("kernel_graph", {}).get("summary", {}).get("num_declared_without_config"),
        "unsupported_features": app.get("summary", {}).get("num_unsupported_features"),
        "unknowns": app.get("summary", {}).get("num_unknowns"),
        "application_ir_schema": app.get("schema_version"),
        "application_ir_validation_status": app_report.get("status"),
        "migration_status": app.get("migration_status"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a profile-only real repository case")
    parser.add_argument("--case-dir", default="cases/hisparse_u280_profile")
    parser.add_argument("--out-dir", default="experiments/runs")
    parser.add_argument("--stage-timeout-sec", type=int, default=1800)
    args = parser.parse_args()

    case_dir = Path(args.case_dir)
    source_ref = load_json(str(case_dir / "source_repo.json"))

    case_id = source_ref["case_id"]
    repo_url = source_ref["repository_url"]
    branch = source_ref.get("default_branch", "master")
    checkout = source_ref.get("local_checkout", "/mnt/data/xporthls_benchmarks/HiSparse")
    target_platform = source_ref["target"]["platform"]
    target_ecosystem = source_ref["target"]["ecosystem"]

    ensure_repo(repo_url, branch, checkout)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    artifact_prefix = "hisparse"

    artifacts = {
        "repo_census": str(out_dir / f"{artifact_prefix}_repo_census_v011.json"),
        "source_profile": str(out_dir / f"{artifact_prefix}_source_platform_profile_v011.json"),
        "compatibility_profile": str(out_dir / f"{artifact_prefix}_compatibility_profile_v011.json"),
        "realrepo_profile_report": str(out_dir / f"{artifact_prefix}_realrepo_profile_report_v011.json"),
        "build_ir": str(out_dir / f"{artifact_prefix}_build_ir_v012.json"),
        "connectivity_ir": str(out_dir / f"{artifact_prefix}_connectivity_ir_v012.json"),
        "build_connectivity_report": str(out_dir / f"{artifact_prefix}_build_connectivity_report_v012.json"),
        "hls_ir": str(out_dir / f"{artifact_prefix}_hls_interface_ir_v013.json"),
        "hls_report": str(out_dir / f"{artifact_prefix}_hls_interface_report_v013.json"),
        "application_ir_v2": str(out_dir / f"{artifact_prefix}_application_ir_v2_v014.json"),
        "application_ir_v2_report": str(out_dir / f"{artifact_prefix}_application_ir_v2_report_v014.json"),
        "case_run_report": str(out_dir / f"{case_id}_case_run_report_v015.json"),
    }

    stages: list[CaseStage] = []
    py = sys.executable

    run_command(
        "realrepo_profile_v011",
        [
            py, "-m", "xporthls.realrepo.run_realrepo_profile_v011",
            "--repo", checkout,
            "--case-id", artifact_prefix,
            "--target-platform", target_platform,
            "--target-ecosystem", target_ecosystem,
            "--out-dir", str(out_dir),
        ],
        stages,
        args.stage_timeout_sec,
    )

    run_command(
        "build_connectivity_v012",
        [
            py, "-m", "xporthls.realrepo.run_build_connectivity_v012",
            "--repo", checkout,
            "--case-id", artifact_prefix,
            "--out-dir", str(out_dir),
        ],
        stages,
        args.stage_timeout_sec,
    )

    run_command(
        "hls_interface_v013",
        [
            py, "-m", "xporthls.realrepo.run_hls_interface_v013",
            "--repo", checkout,
            "--case-id", artifact_prefix,
            "--build-ir", artifacts["build_ir"],
            "--connectivity-ir", artifacts["connectivity_ir"],
            "--out-dir", str(out_dir),
        ],
        stages,
        args.stage_timeout_sec,
    )

    run_command(
        "application_ir_v2_v014",
        [
            py, "-m", "xporthls.realrepo.run_application_ir_v2_v014",
            "--case-id", artifact_prefix,
            "--target-platform", target_platform,
            "--target-ecosystem", target_ecosystem,
            "--census", artifacts["repo_census"],
            "--source-profile", artifacts["source_profile"],
            "--build-ir", artifacts["build_ir"],
            "--connectivity-ir", artifacts["connectivity_ir"],
            "--hls-ir", artifacts["hls_ir"],
            "--compatibility-profile", artifacts["compatibility_profile"],
            "--out-dir", str(out_dir),
        ],
        stages,
        args.stage_timeout_sec,
    )

    summary = build_summary(artifacts)
    status = "pass" if all(s.return_code == 0 for s in stages) else "fail"

    run = ProfileCaseRun(
        schema_version="profile_case_run.v1",
        case_id=case_id,
        status=status,
        repo_path=checkout,
        target_platform=target_platform,
        target_ecosystem=target_ecosystem,
        created_at_utc=utc_now(),
        stages=stages,
        artifacts=artifacts,
        summary=summary,
    )

    save_json(artifacts["case_run_report"], {
        **asdict(run),
        "stages": [asdict(s) for s in stages],
    })

    print(f"\n[xporthls] Profile case run report: {artifacts['case_run_report']}", flush=True)
    print(f"[xporthls] Case ID: {case_id}", flush=True)
    print(f"[xporthls] Status: {status}", flush=True)
    print(f"[xporthls] Source runtime: {summary['source_runtime']}", flush=True)
    print(f"[xporthls] Source boards: {summary['source_boards']}", flush=True)
    print(f"[xporthls] Source memory: {summary['source_memory_model']}", flush=True)
    print(f"[xporthls] Build files: {summary['build_files']}", flush=True)
    print(f"[xporthls] Connectivity directives: {summary['connectivity_directives']}", flush=True)
    print(f"[xporthls] HLS kernel candidates: {summary['hls_kernel_candidates']}", flush=True)
    print(f"[xporthls] ApplicationIR schema: {summary['application_ir_schema']}", flush=True)
    print(f"[xporthls] ApplicationIR validation: {summary['application_ir_validation_status']}", flush=True)

    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
