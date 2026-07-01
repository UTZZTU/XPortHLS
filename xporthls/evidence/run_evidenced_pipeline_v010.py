from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from xporthls.evidence.artifact_registry import (
    build_artifact_registry,
    load_json,
    make_directory_artifact,
    make_file_artifact,
    save_json,
)
from xporthls.evidence.budget_ledger import new_budget_ledger, run_logged, save_json as save_budget_json


def default_run_id(case_id: str) -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"{case_id}_v010_{stamp}"


def build_replay_manifest(
    run_id: str,
    case_id: str,
    target_platform: str,
    target_ecosystem: str,
    budget_ledger: dict[str, Any],
    paths: dict[str, str],
) -> dict[str, Any]:
    return {
        "schema_version": "replay_manifest.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "working_directory": str(Path.cwd()),
        "commands": [
            {
                "stage": c.get("stage"),
                "name": c.get("name"),
                "command": c.get("command"),
                "return_code": c.get("return_code")
            }
            for c in budget_ledger.get("tool_calls", [])
        ],
        "paths": paths,
        "replay_note": "Run these commands from repository root. Runtime outputs are intentionally stored under experiments/runs."
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.10 evidenced XPortHLS pipeline")
    parser.add_argument("--case", default="cases/light_ddr")
    parser.add_argument("--case-id", default="light_ddr")
    parser.add_argument("--platform", default="platform_packs/v80_aved_2025_1_stub")
    parser.add_argument("--target-platform", default="v80_aved_2025_1_stub")
    parser.add_argument("--target-ecosystem", default="AVED")
    parser.add_argument("--run-id", default=None)
    args = parser.parse_args()

    case_id = args.case_id
    run_id = args.run_id or default_run_id(case_id)

    paths = {
        "application_ir": "experiments/runs/light_ddr_application_ir_v010.json",
        "contract_proposed": "experiments/runs/light_ddr_migration_contract_v010_proposed.json",
        "execution_policy": "experiments/runs/light_ddr_execution_policy_v010.json",
        "contract_validation_report": "experiments/runs/light_ddr_contract_v1_report_v010.json",
        "l0_pre_report": "experiments/runs/light_ddr_l0_pre_report_v010.json",
        "contract_static": "experiments/runs/light_ddr_migration_contract_v010_static.json",
        "generated_project": "experiments/runs/light_ddr_generated_v010",
        "l0_post_report": "experiments/runs/light_ddr_l0_post_report_v010.json",
        "artifact_registry": "experiments/runs/light_ddr_artifact_registry_v010.json",
        "budget_ledger": "experiments/runs/light_ddr_budget_ledger_v010.json",
        "replay_manifest": "experiments/runs/light_ddr_replay_manifest_v010.json",
    }

    ledger = new_budget_ledger(run_id, case_id, args.target_platform)
    partial_budget = paths["budget_ledger"]

    py = sys.executable

    run_logged(
        ledger,
        "scan",
        "application_ir",
        [py, "-m", "xporthls.cli", "scan", "--case", args.case, "--out", paths["application_ir"]],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "build_contract_v1",
        [
            py, "-m", "xporthls.contracts.build_contract_v1",
            "--app-ir", paths["application_ir"],
            "--platform", args.platform,
            "--out", paths["contract_proposed"],
            "--policy-out", paths["execution_policy"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "validate_contract_v1",
        [
            py, "-m", "xporthls.contracts.validate_contract_v1",
            "--contract", paths["contract_proposed"],
            "--policy", paths["execution_policy"],
            "--out", paths["contract_validation_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "validation",
        "l0_pre",
        [
            py, "-m", "xporthls.validators.run_l0",
            "--stage", "pre",
            "--app-ir", paths["application_ir"],
            "--contract", paths["contract_proposed"],
            "--out", paths["l0_pre_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "contract",
        "promote_contract_v1",
        [
            py, "-m", "xporthls.contracts.promote_contract_v1",
            "--contract", paths["contract_proposed"],
            "--l0-report", paths["l0_pre_report"],
            "--out", paths["contract_static"],
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "generation",
        "stub_generator",
        [
            py, "-m", "xporthls.generators.stub_generator",
            "--app-ir", paths["application_ir"],
            "--contract", paths["contract_static"],
            "--policy", paths["execution_policy"],
            "--platform", args.platform,
            "--out-dir", paths["generated_project"],
            "--clean",
        ],
        partial_ledger_path=partial_budget,
    )

    run_logged(
        ledger,
        "validation",
        "l0_post",
        [
            py, "-m", "xporthls.validators.run_l0",
            "--stage", "post",
            "--project", paths["generated_project"],
            "--contract", paths["contract_static"],
            "--out", paths["l0_post_report"],
        ],
        partial_ledger_path=partial_budget,
    )

    static_contract = load_json(paths["contract_static"])
    manifest_path = str(Path(paths["generated_project"]) / "xporthls_generated_manifest.json")

    artifacts = [
        make_file_artifact("application_ir", paths["application_ir"], "json", "scan"),
        make_file_artifact("migration_contract_proposed", paths["contract_proposed"], "json", "contract"),
        make_file_artifact("execution_policy", paths["execution_policy"], "json", "contract"),
        make_file_artifact("contract_v1_validation_report", paths["contract_validation_report"], "json", "contract"),
        make_file_artifact("l0_pre_report", paths["l0_pre_report"], "json", "validation"),
        make_file_artifact("migration_contract_static", paths["contract_static"], "json", "contract"),
        make_directory_artifact("generated_project", paths["generated_project"], "directory", "generation"),
        make_file_artifact("generated_manifest", manifest_path, "json", "generation"),
        make_file_artifact("l0_post_report", paths["l0_post_report"], "json", "validation"),
    ]

    registry = build_artifact_registry(
        run_id=run_id,
        case_id=case_id,
        target_platform=static_contract.get("target_platform", args.target_platform),
        target_ecosystem=static_contract.get("target_ecosystem", args.target_ecosystem),
        artifacts=artifacts,
        metadata={
            "xporthls_version": "v0.0.10",
            "pipeline": "ApplicationIR -> Contract v1 -> L0-pre -> StaticallyChecked -> Generator stub -> L0-post",
            "platform_pack": args.platform
        }
    )

    replay = build_replay_manifest(
        run_id=run_id,
        case_id=case_id,
        target_platform=static_contract.get("target_platform", args.target_platform),
        target_ecosystem=static_contract.get("target_ecosystem", args.target_ecosystem),
        budget_ledger=ledger,
        paths=paths,
    )

    save_json(paths["artifact_registry"], registry)
    save_budget_json(paths["budget_ledger"], ledger)
    save_json(paths["replay_manifest"], replay)

    print(f"[xporthls] ArtifactRegistry written to: {paths['artifact_registry']}")
    print(f"[xporthls] BudgetLedger written to: {paths['budget_ledger']}")
    print(f"[xporthls] ReplayManifest written to: {paths['replay_manifest']}")
    print(f"[xporthls] Run ID: {run_id}")
    print(f"[xporthls] Tool calls: {ledger['summary']['num_tool_calls']}")
    print(f"[xporthls] LLM calls: {ledger['summary']['num_llm_calls']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
