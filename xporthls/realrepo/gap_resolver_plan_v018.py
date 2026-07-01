from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def sha256_file(path: str | Path) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None

    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def evidence_ref(kind: str, path: str | None = None, pointer: str | None = None, value: Any | None = None) -> dict[str, Any]:
    return {
        "kind": kind,
        "path": path,
        "pointer": pointer,
        "value": value,
    }


def normalize_gap_id(text: str) -> str:
    return text.strip().upper().replace(" ", "-").replace("_", "-")


def required_inputs_for_gap(gap_id: str) -> list[dict[str, Any]]:
    mapping = {
        "GAP-XRT-HOST-001": [
            {"name": "ApplicationIR v2", "kind": "application_ir.v2", "required": True},
            {"name": "XRT host semantic extraction", "kind": "real_xrt_host_semantics.v1", "required": True},
            {"name": "QDMA/register target rules", "kind": "platform_pack_rules", "required": True},
        ],
        "GAP-PLATFORM-001": [
            {"name": "SourcePlatformProfile", "kind": "source_platform_profile.v1", "required": True},
            {"name": "Target PlatformPack", "kind": "platform_pack.v1", "required": True},
            {"name": "Source-to-target platform mapping policy", "kind": "platform_mapping_policy.v1", "required": True},
        ],
        "GAP-MEM-HBM-001": [
            {"name": "MemoryTopologyIR", "kind": "memory_topology_ir.v1", "required": True},
            {"name": "ConnectivityIR memory mappings", "kind": "connectivity_ir.v1.sp", "required": True},
            {"name": "Target memory rules", "kind": "platform_pack.memory_rules", "required": True},
        ],
        "GAP-STREAM-AXIS-001": [
            {"name": "ConnectivityIR stream edges", "kind": "connectivity_ir.v1.stream_connect", "required": True},
            {"name": "HLS InterfaceIR AXIS ports", "kind": "hls_interface_ir.v1.axis", "required": True},
            {"name": "Target stream mapping policy", "kind": "stream_graph_mapping_policy.v1", "required": True},
        ],
        "GAP-PLACEMENT-SLR-001": [
            {"name": "ConnectivityIR SLR assignments", "kind": "connectivity_ir.v1.slr", "required": True},
            {"name": "Target placement policy", "kind": "placement_policy.v1", "required": True},
        ],
        "GAP-KERNEL-NAME-001": [
            {"name": "KernelGraphIR", "kind": "kernel_graph_ir.v1", "required": True},
            {"name": "BuildIR kernel source references", "kind": "build_ir.v1", "required": True},
            {"name": "ConnectivityIR nk directives", "kind": "connectivity_ir.v1.nk", "required": True},
        ],
        "GAP-HLS-INTERFACE-001": [
            {"name": "HLS InterfaceIR", "kind": "hls_interface_ir.v1", "required": True},
            {"name": "Target kernel interface rules", "kind": "platform_pack.interface_rules", "required": True},
            {"name": "Host/control contract", "kind": "host_control_contract.v1", "required": True},
        ],
    }
    return mapping.get(gap_id, [
        {"name": "Gap evidence", "kind": "gap_contract_evidence", "required": True},
        {"name": "Manual deterministic policy", "kind": "policy_stub", "required": True},
    ])


def expected_outputs_for_gap(gap_id: str) -> list[dict[str, Any]]:
    mapping = {
        "GAP-XRT-HOST-001": [
            {"name": "HostRuntimeRewritePlan", "schema": "host_runtime_rewrite_plan.v1"},
            {"name": "HostControlContract", "schema": "host_control_contract.v1"},
        ],
        "GAP-PLATFORM-001": [
            {"name": "SourcePlatformMappingPlan", "schema": "source_platform_mapping_plan.v1"},
            {"name": "TargetPlatformAssumptionSet", "schema": "target_platform_assumption_set.v1"},
        ],
        "GAP-MEM-HBM-001": [
            {"name": "MemoryMappingPlan", "schema": "memory_mapping_plan.v1"},
            {"name": "SourceToTargetMemoryGapContract", "schema": "source_to_target_memory_gap_contract.v1"},
        ],
        "GAP-STREAM-AXIS-001": [
            {"name": "StreamGraphMappingPlan", "schema": "stream_graph_mapping_plan.v1"},
            {"name": "StreamEdgeResolutionReport", "schema": "stream_edge_resolution_report.v1"},
        ],
        "GAP-PLACEMENT-SLR-001": [
            {"name": "PlacementPolicyPlan", "schema": "placement_policy_plan.v1"},
            {"name": "PlacementDirectiveResolutionReport", "schema": "placement_directive_resolution_report.v1"},
        ],
        "GAP-KERNEL-NAME-001": [
            {"name": "KernelNameResolutionPlan", "schema": "kernel_name_resolution_plan.v1"},
            {"name": "KernelGraphResolutionReport", "schema": "kernel_graph_resolution_report.v1"},
        ],
        "GAP-HLS-INTERFACE-001": [
            {"name": "HlsInterfaceLoweringPlan", "schema": "hls_interface_lowering_plan.v1"},
            {"name": "TargetInterfaceContract", "schema": "target_interface_contract.v1"},
        ],
    }
    return mapping.get(gap_id, [
        {"name": "GenericGapResolutionPlan", "schema": "generic_gap_resolution_plan.v1"},
    ])


def resolver_type_for_gap(gap_id: str, category: str) -> str:
    mapping = {
        "GAP-XRT-HOST-001": "HostRuntimeRewritePlan",
        "GAP-PLATFORM-001": "SourcePlatformMappingPlan",
        "GAP-MEM-HBM-001": "MemoryMappingPlan",
        "GAP-STREAM-AXIS-001": "StreamGraphMappingPlan",
        "GAP-PLACEMENT-SLR-001": "PlacementPolicyPlan",
        "GAP-KERNEL-NAME-001": "KernelNameResolutionPlan",
        "GAP-HLS-INTERFACE-001": "HlsInterfaceLoweringPlan",
    }
    if gap_id in mapping:
        return mapping[gap_id]

    category_mapping = {
        "host_runtime": "HostRuntimeRewritePlan",
        "platform": "SourcePlatformMappingPlan",
        "memory_topology": "MemoryMappingPlan",
        "streaming": "StreamGraphMappingPlan",
        "placement": "PlacementPolicyPlan",
        "kernel_graph": "KernelNameResolutionPlan",
        "hls_interface": "HlsInterfaceLoweringPlan",
    }
    return category_mapping.get(category, "GenericGapResolutionPlan")


def plan_steps_for_gap(gap_id: str) -> list[dict[str, Any]]:
    common_prefix = [
        {
            "step_id": "collect_evidence",
            "kind": "analysis",
            "description": "Collect deterministic evidence from ApplicationIR, GapContract and source profile artifacts.",
            "llm_allowed": False,
            "must_be_deterministic": True,
        },
        {
            "step_id": "validate_preconditions",
            "kind": "validation",
            "description": "Validate that required input IRs and platform-pack facts exist before attempting resolution.",
            "llm_allowed": False,
            "must_be_deterministic": True,
        },
    ]

    mapping = {
        "GAP-XRT-HOST-001": [
            {
                "step_id": "extract_real_xrt_host_semantics",
                "kind": "extractor",
                "description": "Extract buffers, kernels, xclbin loading, command queue behavior, sync directions, host transfers and run ordering from real host code.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "map_xrt_control_to_aved_control",
                "kind": "policy_mapping",
                "description": "Map XRT runtime semantics into AVED host/control and QDMA/register assumptions.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-PLATFORM-001": [
            {
                "step_id": "compare_source_and_target_platforms",
                "kind": "policy_mapping",
                "description": "Compare U280/Vitis/XRT source platform facts against V80/AVED PlatformPack facts.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_platform_mapping_policy",
                "kind": "contract_output",
                "description": "Emit explicit assumptions and blocked/allowed source platform features.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-MEM-HBM-001": [
            {
                "step_id": "classify_source_memory_banks",
                "kind": "analysis",
                "description": "Classify HBM/DDR memory mappings, m_axi ports, bundle names and connectivity sp directives.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_memory_mapping_policy",
                "kind": "contract_output",
                "description": "Emit source-to-target memory mapping plan or explicit unsupported-bank blockers.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-STREAM-AXIS-001": [
            {
                "step_id": "resolve_stream_edges",
                "kind": "analysis",
                "description": "Resolve stream_connect edges against HLS AXIS ports and hls::stream variables.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_stream_graph_mapping",
                "kind": "contract_output",
                "description": "Emit target stream/K2K mapping plan or blocking unsupported stream edges.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-PLACEMENT-SLR-001": [
            {
                "step_id": "classify_slr_directives",
                "kind": "analysis",
                "description": "Classify source SLR constraints and decide whether each is translated, dropped with proof or blocked.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_placement_policy",
                "kind": "contract_output",
                "description": "Emit target placement policy for V80 AVED or explicit no-translation policy.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-KERNEL-NAME-001": [
            {
                "step_id": "resolve_configured_to_declared_kernels",
                "kind": "resolver",
                "description": "Map connectivity configured kernels and compute units to declared HLS functions using normalized names and build source refs.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_kernel_graph_resolution_report",
                "kind": "contract_output",
                "description": "Emit resolved kernel graph and explicit unresolved names.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
        "GAP-HLS-INTERFACE-001": [
            {
                "step_id": "lower_hls_interfaces",
                "kind": "lowering",
                "description": "Lower m_axi, axis, s_axilite, ap_ctrl and dataflow pragmas into target interface contracts.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
            {
                "step_id": "emit_target_interface_contract",
                "kind": "contract_output",
                "description": "Emit target-side kernel interface/control/data movement contract.",
                "llm_allowed": False,
                "must_be_deterministic": True,
            },
        ],
    }

    suffix = [
        {
            "step_id": "validate_resolution_artifacts",
            "kind": "validation",
            "description": "Validate resolver outputs before changing gap state.",
            "llm_allowed": False,
            "must_be_deterministic": True,
        },
        {
            "step_id": "update_gap_state_if_validated",
            "kind": "state_transition",
            "description": "Only a validator may transition the gap from open/planned to resolved or downgraded.",
            "llm_allowed": False,
            "must_be_deterministic": True,
        },
    ]

    return common_prefix + mapping.get(gap_id, [
        {
            "step_id": "create_generic_resolution_policy",
            "kind": "policy_mapping",
            "description": "Create a deterministic resolution policy for this gap category.",
            "llm_allowed": False,
            "must_be_deterministic": True,
        },
    ]) + suffix


def build_resolver_entry(gap: dict[str, Any], contract_path: str, order: int) -> dict[str, Any]:
    gap_id = gap.get("id")
    category = gap.get("category")
    severity = gap.get("severity")
    blocks_migration = bool(gap.get("blocks_migration"))
    resolver_type = resolver_type_for_gap(gap_id, category)

    must_resolve = severity == "blocking" and blocks_migration

    return {
        "resolver_id": f"RESOLVE-{gap_id}",
        "gap_id": gap_id,
        "order": order,
        "resolver_type": resolver_type,
        "category": category,
        "severity": severity,
        "blocks_migration": blocks_migration,
        "must_resolve_before_generation": must_resolve,
        "resolution_state": "planned",
        "execution_mode": "deterministic_only",
        "llm_role": {
            "allowed": False,
            "reason": "v0.0.18 records deterministic resolver plans only; LLM may later suggest patch plans but cannot change gap state or decide correctness.",
        },
        "source_gap": {
            "title": gap.get("title"),
            "source_feature": gap.get("source_feature"),
            "target_requirement": gap.get("target_requirement"),
            "gap_decision": gap.get("decision"),
            "required_action": gap.get("required_action"),
        },
        "required_inputs": required_inputs_for_gap(gap_id),
        "expected_outputs": expected_outputs_for_gap(gap_id),
        "steps": plan_steps_for_gap(gap_id),
        "preconditions": [
            {
                "id": "contract_schema_valid",
                "description": "Source-to-target gap contract must validate before this resolver can execute.",
                "required": True,
            },
            {
                "id": "source_evidence_available",
                "description": "All evidence referenced by the gap must be available and traceable.",
                "required": True,
            },
            {
                "id": "target_policy_available",
                "description": "Target PlatformPack or target mapping policy must exist for the resolver category.",
                "required": True,
            },
        ],
        "success_criteria": [
            {
                "id": "resolver_output_schema_valid",
                "description": "Resolver output artifacts must pass their own schema validators.",
            },
            {
                "id": "gap_evidence_preserved",
                "description": "The resolver must preserve traceability from source evidence to target assumptions.",
            },
            {
                "id": "no_unvalidated_state_change",
                "description": "No gap may be marked resolved without validator approval.",
            },
        ],
        "evidence": [
            evidence_ref("gap_contract", contract_path, f"/gaps/{order - 1}", {"gap_id": gap_id}),
            evidence_ref("gap_contract", contract_path, f"/summary/blocking_gap_ids", None),
        ],
    }


def execution_order(gap: dict[str, Any]) -> int:
    gap_id = normalize_gap_id(gap.get("id", ""))

    order = {
        "GAP-KERNEL-NAME-001": 10,
        "GAP-PLATFORM-001": 20,
        "GAP-MEM-HBM-001": 30,
        "GAP-STREAM-AXIS-001": 40,
        "GAP-PLACEMENT-SLR-001": 50,
        "GAP-HLS-INTERFACE-001": 60,
        "GAP-XRT-HOST-001": 70,
        "GAP-KERNEL-NAME-002": 110,
        "GAP-TOOLCHAIN-001": 120,
        "GAP-BINARY-ARTIFACT-001": 130,
    }
    return order.get(gap_id, 1000)


def build_gap_resolver_plan(case_id: str, contract_path: str, out_path: str | None = None) -> dict[str, Any]:
    contract = load_json(contract_path)
    gaps = contract.get("gaps", [])
    sorted_gaps = sorted(gaps, key=execution_order)

    resolvers = [
        build_resolver_entry(gap, contract_path, i + 1)
        for i, gap in enumerate(sorted_gaps)
    ]

    blocking_resolvers = [r for r in resolvers if r["must_resolve_before_generation"]]
    warning_resolvers = [r for r in resolvers if r["severity"] == "warning"]
    info_resolvers = [r for r in resolvers if r["severity"] == "info"]

    plan_allowed_to_execute = False

    plan = {
        "schema_version": "gap_resolver_plan.v1",
        "plan_id": f"{case_id}.gap_resolver_plan.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "plan_state": "planned_profile_only",
        "migration_status": "profile_only",
        "source_contract_ref": {
            "path": contract_path,
            "sha256": sha256_file(contract_path),
            "schema_version": contract.get("schema_version"),
            "contract_id": contract.get("contract_id"),
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
        },
        "target": contract.get("target", {}),
        "source": contract.get("source", {}),
        "planning_policy": {
            "generation_allowed": False,
            "resolver_execution_allowed": plan_allowed_to_execute,
            "reason": "v0.0.18 creates resolver plans only. It does not execute resolvers or mark gaps as resolved.",
            "state_transition_policy": {
                "allowed_initial_state": "planned",
                "resolver_may_change_gap_state": False,
                "validator_required_for_state_change": True,
                "generator_must_still_obey_gap_contract": True,
            },
            "llm_policy": {
                "llm_may_rank_or_explain_plan": True,
                "llm_may_execute_resolver": False,
                "llm_may_change_gap_state": False,
                "llm_is_correctness_judge": False,
            },
        },
        "resolvers": resolvers,
        "dependency_graph": {
            "schema_version": "gap_resolver_dependency_graph.v1",
            "nodes": [r["resolver_id"] for r in resolvers],
            "edges": [
                {
                    "from": "RESOLVE-GAP-KERNEL-NAME-001",
                    "to": "RESOLVE-GAP-HLS-INTERFACE-001",
                    "reason": "Interface lowering needs resolved top kernels and helper classification.",
                },
                {
                    "from": "RESOLVE-GAP-PLATFORM-001",
                    "to": "RESOLVE-GAP-MEM-HBM-001",
                    "reason": "Memory mapping needs target platform assumptions.",
                },
                {
                    "from": "RESOLVE-GAP-MEM-HBM-001",
                    "to": "RESOLVE-GAP-HLS-INTERFACE-001",
                    "reason": "HLS interface lowering needs m_axi memory mapping decisions.",
                },
                {
                    "from": "RESOLVE-GAP-STREAM-AXIS-001",
                    "to": "RESOLVE-GAP-HLS-INTERFACE-001",
                    "reason": "HLS interface lowering needs stream mapping decisions.",
                },
                {
                    "from": "RESOLVE-GAP-HLS-INTERFACE-001",
                    "to": "RESOLVE-GAP-XRT-HOST-001",
                    "reason": "Host rewrite needs target kernel interface/control contract.",
                },
            ],
        },
        "summary": {
            "num_resolvers": len(resolvers),
            "num_blocking_resolvers": len(blocking_resolvers),
            "num_warning_resolvers": len(warning_resolvers),
            "num_info_resolvers": len(info_resolvers),
            "blocking_resolver_ids": [r["resolver_id"] for r in blocking_resolvers],
            "warning_resolver_ids": [r["resolver_id"] for r in warning_resolvers],
            "info_resolver_ids": [r["resolver_id"] for r in info_resolvers],
            "generation_allowed": False,
            "resolver_execution_allowed": plan_allowed_to_execute,
            "contract_blocking_gap_ids": contract.get("summary", {}).get("blocking_gap_ids", []),
            "output_plan_path": out_path,
        },
        "traceability": {
            "contract_summary": contract.get("summary", {}),
            "contract_migration_decision": contract.get("migration_decision", {}),
            "contract_source_application_ir_ref": contract.get("source_application_ir_ref", {}),
        },
        "llm_annotations": [],
    }

    return plan


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Gap Contract Resolver Plan v0.0.18")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    plan = build_gap_resolver_plan(
        case_id=args.case_id,
        contract_path=args.contract,
        out_path=args.out,
    )
    save_json(args.out, plan)

    s = plan["summary"]
    print(f"[xporthls] Gap Resolver Plan written to: {args.out}")
    print(f"[xporthls] Plan schema: {plan['schema_version']}")
    print(f"[xporthls] Plan state: {plan['plan_state']}")
    print(f"[xporthls] Generation allowed: {s['generation_allowed']}")
    print(f"[xporthls] Resolver execution allowed: {s['resolver_execution_allowed']}")
    print(f"[xporthls] Resolvers: {s['num_resolvers']}")
    print(f"[xporthls] Blocking resolvers: {s['num_blocking_resolvers']}")
    print(f"[xporthls] Warning resolvers: {s['num_warning_resolvers']}")
    print(f"[xporthls] Info resolvers: {s['num_info_resolvers']}")
    print(f"[xporthls] Blocking resolver IDs: {s['blocking_resolver_ids']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
