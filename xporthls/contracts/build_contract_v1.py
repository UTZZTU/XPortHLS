from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from xporthls.ir.platform_ir import PlatformIR


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def index_sync_by_buffer(sync_operations: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for sync in sync_operations:
        buf = sync.get("buffer")
        if buf:
            out.setdefault(buf, []).append(sync)
    return out


def index_transfer_by_buffer(host_transfers: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for transfer in host_transfers:
        buf = transfer.get("buffer")
        if buf:
            out.setdefault(buf, []).append(transfer)
    return out


def build_execution_policy(app: dict[str, Any], platform: PlatformIR) -> dict[str, Any]:
    case = app.get("case_metadata", {}) or {}

    return {
        "schema_version": "execution_policy.v1",
        "policy_id": f"{case.get('case_id', app.get('project', 'unknown'))}_to_{platform.platform_id}",
        "case_id": case.get("case_id", app.get("project", "unknown")),
        "target_platform": platform.platform_id,
        "target_ecosystem": platform.target.get("ecosystem") or "AVED",
        "mode": "deterministic_pipeline_only",
        "llm_enabled": False,
        "reason": "LLM integration is intentionally disabled until ModelAdapter, Evidence Ledger, Budget Ledger and Agent Loop are implemented.",
        "validation_sequence": [
            "L0-pre",
            "generate",
            "L0-post",
            "L1-csim",
            "L2-cosim",
            "L3-synth",
            "L4-implementation",
            "L5-hardware"
        ],
        "budget": {
            "max_agent_iterations": 0,
            "max_llm_calls": 0,
            "max_patch_attempts": 0,
            "tool_budget_placeholders": {
                "csim": None,
                "cosim": None,
                "synth": None,
                "implementation": None
            }
        },
        "patch_policy": {
            "enabled": False,
            "reason": "PatchController and Agent Loop are not implemented yet.",
            "allowed_files": [],
            "requires_validation_after_patch": True
        },
        "evidence_policy": {
            "record_artifacts": True,
            "record_validation_reports": True,
            "record_budget_usage": True,
            "record_patch_ledger": True
        }
    }


def build_contract(app: dict[str, Any], platform: PlatformIR, policy_path: str | None) -> dict[str, Any]:
    case = app.get("case_metadata", {}) or {}
    facts = app.get("facts", {}) or {}
    xrt_facts = facts.get("xrt", {}) if isinstance(facts, dict) else {}
    hls_facts = facts.get("hls", {}) if isinstance(facts, dict) else {}
    build_facts = facts.get("build", {}) if isinstance(facts, dict) else {}

    buffers = app.get("buffers", []) or xrt_facts.get("buffers", [])
    host_transfers = app.get("host_transfers", []) or xrt_facts.get("host_transfers", [])
    sync_operations = app.get("sync_operations", []) or xrt_facts.get("sync_operations", [])
    kernel_invocations = app.get("kernel_invocations", []) or xrt_facts.get("kernel_invocations", [])
    run_waits = app.get("run_waits", []) or xrt_facts.get("run_waits", [])
    kernel_candidates = app.get("kernels", []) or hls_facts.get("kernel_candidates", [])
    build_targets = app.get("build_targets", []) or build_facts.get("targets", [])

    sync_by_buffer = index_sync_by_buffer(sync_operations)
    transfer_by_buffer = index_transfer_by_buffer(host_transfers)

    buffer_roles = []
    for buf in buffers:
        name = buf.get("name")
        syncs = sync_by_buffer.get(name, [])
        transfers = transfer_by_buffer.get(name, [])

        directions = sorted({s.get("direction") for s in syncs if s.get("direction")})
        operations = sorted({t.get("operation") for t in transfers if t.get("operation")})

        role = "unknown"
        if "host_to_device" in directions:
            role = "input"
        if "device_to_host" in directions:
            role = "output"
        if "host_to_device" in directions and "device_to_host" in directions:
            role = "inout"

        buffer_roles.append({
            "name": name,
            "role": role,
            "size_expr": buf.get("size_expr"),
            "group_id": buf.get("group_id"),
            "sync_directions": directions,
            "host_operations": operations,
            "evidence": {
                "allocation": buf.get("evidence"),
                "syncs": [s.get("evidence") for s in syncs],
                "transfers": [t.get("evidence") for t in transfers]
            }
        })

    scalar_args = []
    for inv in kernel_invocations:
        for arg in inv.get("scalar_args", []):
            if arg not in scalar_args:
                scalar_args.append(arg)

    target_ecosystem = platform.target.get("ecosystem") or "AVED"

    contract = {
        "schema_version": "migration_contract.v1",
        "state": "Proposed",
        "source_project": app.get("project", case.get("case_id", "unknown")),
        "case_id": case.get("case_id", app.get("project", "unknown")),
        "source_runtime": app.get("source_runtime", "XRT"),
        "target_platform": platform.platform_id,
        "target_ecosystem": target_ecosystem,
        "target_board": platform.target.get("board") or platform.board,
        "target_tool_flow": platform.target.get("tool_flow") or platform.tool_flow,
        "target_tool_version": platform.target.get("tool_version") or platform.tool_version,
        "platform_pack": {
            "platform_id": platform.platform_id,
            "name": platform.name,
            "status": platform.status,
            "source_kind": platform.source_kind,
            "pack_path": platform.pack_path,
            "aved_release": platform.aved_release
        },
        "execution_policy_ref": policy_path,
        "contract_states": {
            "allowed": ["Proposed", "StaticallyChecked", "RuntimeValidated"],
            "current": "Proposed",
            "next_required_validation": "L0-pre"
        },
        "contracts": {
            "functional": {
                "kind": "FunctionalContract",
                "goal": "Preserve source application behavior.",
                "golden": case.get("golden", {}),
                "test_entries": app.get("test_entries", []),
                "status": "Proposed"
            },
            "interface": {
                "kind": "InterfaceContract",
                "source_runtime": app.get("source_runtime", "XRT"),
                "target_ecosystem": target_ecosystem,
                "kernel_invocations": kernel_invocations,
                "kernel_candidates": kernel_candidates,
                "run_waits": run_waits,
                "status": "Proposed"
            },
            "memory": {
                "kind": "MemoryContract",
                "memory_type": case.get("memory_type", "unknown"),
                "num_buffers": len(buffers),
                "buffer_roles": buffer_roles,
                "rules_source": "Platform Pack memory_rules.json",
                "status": "Proposed"
            },
            "qdma": {
                "kind": "QdmaContract",
                "num_host_transfers": len(host_transfers),
                "num_sync_operations": len(sync_operations),
                "host_transfers": host_transfers,
                "sync_operations": sync_operations,
                "rules_source": "Platform Pack qdma_rules.json",
                "status": "Proposed"
            },
            "control": {
                "kind": "ControlContract",
                "scalar_args": scalar_args,
                "kernel_invocations": kernel_invocations,
                "rules_source": "Platform Pack register_rules.json",
                "status": "Proposed"
            },
            "build": {
                "kind": "BuildContract",
                "build_targets": build_targets,
                "target_tool_flow": platform.target.get("tool_flow") or platform.tool_flow,
                "target_tool_version": platform.target.get("tool_version") or platform.tool_version,
                "status": "Proposed"
            },
            "validation": {
                "kind": "ValidationContract",
                "required_sequence": ["L0-pre", "L0-post"],
                "future_sequence": ["L1-csim", "L2-cosim", "L3-synth", "L4-implementation", "L5-hardware"],
                "status": "Proposed"
            }
        },
        "obligations": [
            {
                "kind": "preserve_functionality",
                "contract": "functional",
                "status": "Proposed"
            },
            {
                "kind": "remove_xrt_runtime_dependency",
                "contract": "interface",
                "from": app.get("source_runtime", "XRT"),
                "to": target_ecosystem,
                "status": "Proposed"
            },
            {
                "kind": "map_xrt_buffers_to_platform_memory",
                "contract": "memory",
                "num_buffers": len(buffers),
                "status": "Proposed"
            },
            {
                "kind": "map_xrt_sync_to_qdma_transfers",
                "contract": "qdma",
                "num_sync_operations": len(sync_operations),
                "status": "Proposed"
            },
            {
                "kind": "validate_before_generation",
                "contract": "validation",
                "required": "L0-pre",
                "status": "Proposed"
            }
        ],
        "unknowns": app.get("unknowns", []),
        "warnings": [
            "MigrationContract v1 is structural and proposed. It must become StaticallyChecked after L0-pre.",
            "ExecutionPolicy is stored separately and referenced by execution_policy_ref."
        ]
    }

    return contract


def main() -> int:
    parser = argparse.ArgumentParser(description="Build XPortHLS MigrationContract v1 and ExecutionPolicy v1")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--policy-out", required=True)
    args = parser.parse_args()

    app = load_json(args.app_ir)
    platform = PlatformIR.load_json(args.platform)

    policy = build_execution_policy(app, platform)
    save_json(args.policy_out, policy)

    contract = build_contract(app, platform, args.policy_out)
    save_json(args.out, contract)

    print(f"[xporthls] MigrationContract v1 written to: {args.out}")
    print(f"[xporthls] ExecutionPolicy v1 written to: {args.policy_out}")
    print(f"[xporthls] Contract state: {contract['state']}")
    print(f"[xporthls] Target platform: {contract['target_platform']}")
    print(f"[xporthls] Target ecosystem: {contract['target_ecosystem']}")
    print(f"[xporthls] Obligations: {len(contract['obligations'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
