#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add Gap Contract Resolver Plan builder"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/gap_resolver_plan_v018.py <<'EOT'
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
EOT

echo "[2/6] Add Gap Resolver Plan validator"

cat > xporthls/realrepo/validate_gap_resolver_plan_v018.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class ResolverPlanIssue:
    severity: str
    code: str
    message: str


@dataclass
class ResolverPlanValidationReport:
    status: str
    issues: list[ResolverPlanIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[ResolverPlanIssue], severity: str, code: str, message: str) -> None:
    issues.append(ResolverPlanIssue(severity=severity, code=code, message=message))


def validate_resolver_shape(resolver: dict[str, Any], issues: list[ResolverPlanIssue]) -> None:
    required = [
        "resolver_id",
        "gap_id",
        "order",
        "resolver_type",
        "category",
        "severity",
        "blocks_migration",
        "must_resolve_before_generation",
        "resolution_state",
        "execution_mode",
        "required_inputs",
        "expected_outputs",
        "steps",
        "preconditions",
        "success_criteria",
        "evidence",
    ]

    for field in required:
        if field not in resolver:
            add_issue(issues, "error", "RESOLVER_FIELD_MISSING", f"Resolver {resolver.get('resolver_id', '<unknown>')} missing field: {field}")

    if resolver.get("resolution_state") != "planned":
        add_issue(issues, "error", "RESOLVER_STATE_NOT_PLANNED", f"Resolver {resolver.get('resolver_id')} must start as planned.")

    if resolver.get("execution_mode") != "deterministic_only":
        add_issue(issues, "error", "RESOLVER_EXECUTION_MODE", f"Resolver {resolver.get('resolver_id')} must be deterministic_only.")

    if not isinstance(resolver.get("steps", []), list) or len(resolver.get("steps", [])) < 3:
        add_issue(issues, "error", "RESOLVER_STEPS_TOO_FEW", f"Resolver {resolver.get('resolver_id')} has too few steps.")

    for step in resolver.get("steps", []):
        if step.get("llm_allowed") is not False:
            add_issue(issues, "error", "STEP_LLM_ALLOWED", f"Step {step.get('step_id')} in {resolver.get('resolver_id')} must not allow LLM execution.")
        if step.get("must_be_deterministic") is not True:
            add_issue(issues, "error", "STEP_NOT_DETERMINISTIC", f"Step {step.get('step_id')} in {resolver.get('resolver_id')} must be deterministic.")

    if not resolver.get("required_inputs"):
        add_issue(issues, "error", "RESOLVER_INPUTS_MISSING", f"Resolver {resolver.get('resolver_id')} has no required_inputs.")

    if not resolver.get("expected_outputs"):
        add_issue(issues, "error", "RESOLVER_OUTPUTS_MISSING", f"Resolver {resolver.get('resolver_id')} has no expected_outputs.")


def validate(plan: dict[str, Any], contract: dict[str, Any] | None = None) -> ResolverPlanValidationReport:
    issues: list[ResolverPlanIssue] = []

    if plan.get("schema_version") != "gap_resolver_plan.v1":
        add_issue(issues, "error", "PLAN_SCHEMA", "Expected gap_resolver_plan.v1.")

    if plan.get("plan_state") != "planned_profile_only":
        add_issue(issues, "error", "PLAN_STATE", "v0.0.18 plan_state must be planned_profile_only.")

    if plan.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.18 resolver plan must remain profile_only.")

    source_ref = plan.get("source_contract_ref", {})
    if source_ref.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA_REF", "Resolver plan must reference source_to_target_gap_contract.v1.")

    if source_ref.get("contract_state") != "blocked_profile_only":
        add_issue(issues, "error", "CONTRACT_STATE_REF", "Resolver plan currently expects blocked_profile_only contract.")

    if source_ref.get("migration_allowed") is not False:
        add_issue(issues, "error", "CONTRACT_MIGRATION_ALLOWED_REF", "Resolver plan expects migration_allowed false.")

    policy = plan.get("planning_policy", {})
    if policy.get("generation_allowed") is not False:
        add_issue(issues, "error", "PLAN_GENERATION_ALLOWED", "v0.0.18 must not allow generation.")

    if policy.get("resolver_execution_allowed") is not False:
        add_issue(issues, "error", "RESOLVER_EXECUTION_ALLOWED", "v0.0.18 must not execute resolvers.")

    llm_policy = policy.get("llm_policy", {})
    if llm_policy.get("llm_may_execute_resolver") is not False:
        add_issue(issues, "error", "LLM_EXECUTE_POLICY", "LLM must not execute resolver.")
    if llm_policy.get("llm_may_change_gap_state") is not False:
        add_issue(issues, "error", "LLM_STATE_CHANGE_POLICY", "LLM must not change gap state.")
    if llm_policy.get("llm_is_correctness_judge") is not False:
        add_issue(issues, "error", "LLM_JUDGE_POLICY", "LLM must not be correctness judge.")

    resolvers = plan.get("resolvers", [])
    if not resolvers:
        add_issue(issues, "error", "NO_RESOLVERS", "Resolver plan has no resolvers.")

    resolver_ids = []
    gap_ids = []
    for resolver in resolvers:
        validate_resolver_shape(resolver, issues)
        resolver_ids.append(resolver.get("resolver_id"))
        gap_ids.append(resolver.get("gap_id"))

    if len(resolver_ids) != len(set(resolver_ids)):
        add_issue(issues, "error", "DUPLICATE_RESOLVER_IDS", "Resolver IDs must be unique.")

    if len(gap_ids) != len(set(gap_ids)):
        add_issue(issues, "error", "DUPLICATE_GAP_IDS", "Each gap should have exactly one resolver entry.")

    summary = plan.get("summary", {})
    if int(summary.get("num_resolvers") or 0) != len(resolvers):
        add_issue(issues, "error", "RESOLVER_COUNT_MISMATCH", "summary.num_resolvers does not match resolver list length.")

    blocking_resolvers = [
        r for r in resolvers
        if r.get("must_resolve_before_generation") is True
    ]

    if int(summary.get("num_blocking_resolvers") or 0) != len(blocking_resolvers):
        add_issue(issues, "error", "BLOCKING_RESOLVER_COUNT_MISMATCH", "summary.num_blocking_resolvers mismatch.")

    expected_blocking_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-PLACEMENT-SLR-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }
    actual_gap_ids = set(gap_ids)

    missing_required = sorted(expected_blocking_gap_ids - actual_gap_ids)
    if missing_required:
        add_issue(issues, "error", "REQUIRED_RESOLVERS_MISSING", f"Missing required resolver gap ids: {missing_required}")

    expected_types = {
        "GAP-XRT-HOST-001": "HostRuntimeRewritePlan",
        "GAP-PLATFORM-001": "SourcePlatformMappingPlan",
        "GAP-MEM-HBM-001": "MemoryMappingPlan",
        "GAP-STREAM-AXIS-001": "StreamGraphMappingPlan",
        "GAP-PLACEMENT-SLR-001": "PlacementPolicyPlan",
        "GAP-KERNEL-NAME-001": "KernelNameResolutionPlan",
        "GAP-HLS-INTERFACE-001": "HlsInterfaceLoweringPlan",
    }

    by_gap = {r.get("gap_id"): r for r in resolvers}
    for gap_id, expected_type in expected_types.items():
        resolver = by_gap.get(gap_id)
        if not resolver:
            continue
        if resolver.get("resolver_type") != expected_type:
            add_issue(
                issues,
                "error",
                "RESOLVER_TYPE_MISMATCH",
                f"{gap_id}: expected {expected_type}, got {resolver.get('resolver_type')!r}",
            )
        if resolver.get("must_resolve_before_generation") is not True:
            add_issue(
                issues,
                "error",
                "BLOCKING_RESOLVER_NOT_REQUIRED",
                f"{gap_id}: must_resolve_before_generation should be true.",
            )

    graph = plan.get("dependency_graph", {})
    graph_nodes = set(graph.get("nodes", []))
    missing_graph_nodes = sorted(set(resolver_ids) - graph_nodes)
    if missing_graph_nodes:
        add_issue(issues, "error", "DEPENDENCY_GRAPH_NODE_MISSING", f"Dependency graph missing nodes: {missing_graph_nodes}")

    for edge in graph.get("edges", []):
        if edge.get("from") not in graph_nodes or edge.get("to") not in graph_nodes:
            add_issue(issues, "error", "DEPENDENCY_GRAPH_EDGE_INVALID", f"Invalid edge: {edge}")

    if plan.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Resolver plan must not contain LLM annotations in v0.0.18.")

    if contract is not None:
        contract_gap_ids = {g.get("id") for g in contract.get("gaps", [])}
        missing_from_plan = sorted(contract_gap_ids - actual_gap_ids)
        if missing_from_plan:
            add_issue(issues, "error", "CONTRACT_GAP_WITHOUT_RESOLVER", f"Contract gaps missing resolver entries: {missing_from_plan}")

        contract_blocking = set(contract.get("summary", {}).get("blocking_gap_ids", []))
        planned_blocking = {r.get("gap_id") for r in blocking_resolvers}
        if contract_blocking != planned_blocking:
            add_issue(
                issues,
                "error",
                "CONTRACT_BLOCKING_MISMATCH",
                f"Contract blocking gaps {sorted(contract_blocking)} != planned blocking gaps {sorted(planned_blocking)}",
            )

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ResolverPlanValidationReport(
        status=status,
        issues=issues,
        summary={
            "plan_id": plan.get("plan_id"),
            "case_id": plan.get("case_id"),
            "schema_version": plan.get("schema_version"),
            "plan_state": plan.get("plan_state"),
            "migration_status": plan.get("migration_status"),
            "source_contract_schema": source_ref.get("schema_version"),
            "source_contract_state": source_ref.get("contract_state"),
            "source_contract_migration_allowed": source_ref.get("migration_allowed"),
            "generation_allowed": policy.get("generation_allowed"),
            "resolver_execution_allowed": policy.get("resolver_execution_allowed"),
            "num_resolvers": summary.get("num_resolvers"),
            "num_blocking_resolvers": summary.get("num_blocking_resolvers"),
            "num_warning_resolvers": summary.get("num_warning_resolvers"),
            "num_info_resolvers": summary.get("num_info_resolvers"),
            "blocking_resolver_ids": summary.get("blocking_resolver_ids"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Gap Resolver Plan v0.0.18")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--contract", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    plan = load_json(args.plan)
    contract = load_json(args.contract) if args.contract else None
    report = validate(plan, contract)
    report.save(args.out)

    print(f"[xporthls] Gap Resolver Plan validation written to: {args.out}")
    print(f"[xporthls] Gap Resolver Plan validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/6] Add Gap Resolver Plan orchestration runner"

cat > xporthls/realrepo/run_gap_resolver_plan_v018.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_resolver_plan_v018 import build_gap_resolver_plan, save_json
from xporthls.realrepo.validate_gap_resolver_plan_v018 import load_json, validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.18 Gap Resolver Plan pipeline")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    plan_path = out_dir / f"{args.case_id}_gap_resolver_plan_v018.json"
    report_path = out_dir / f"{args.case_id}_gap_resolver_plan_report_v018.json"

    plan = build_gap_resolver_plan(
        case_id=args.case_id,
        contract_path=args.contract,
        out_path=str(plan_path),
    )
    save_json(plan_path, plan)

    contract = load_json(args.contract)
    report = validate(plan, contract)
    report.save(report_path)

    s = plan["summary"]
    print(f"[xporthls] Gap Resolver Plan: {plan_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Plan state: {plan['plan_state']}")
    print(f"[xporthls] Generation allowed: {s['generation_allowed']}")
    print(f"[xporthls] Resolver execution allowed: {s['resolver_execution_allowed']}")
    print(f"[xporthls] Resolvers: {s['num_resolvers']}")
    print(f"[xporthls] Blocking resolvers: {s['num_blocking_resolvers']}")
    print(f"[xporthls] Warnings resolvers: {s['num_warning_resolvers']}")
    print(f"[xporthls] Info resolvers: {s['num_info_resolvers']}")
    print(f"[xporthls] Blocking resolver IDs: {s['blocking_resolver_ids']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README with Gap Resolver Plan usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Gap resolver plan

XPortHLS can turn a blocked source-to-target gap contract into a deterministic resolver plan. The plan does not execute resolvers and does not mark any gap as resolved. It records the required inputs, output schemas, ordered steps, dependency graph, success criteria, and state-transition policy for each gap.

Example:

```bash
python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \\
  --case-id hisparse_u280_profile \\
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \\
  --out-dir experiments/runs
```

The runner writes:

```text
experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json
experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json
```

For the HiSparse profile-only case, the resolver plan is expected to remain profile-only and generation-blocked.
"""

if "## Gap resolver plan" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.18 replay script"

cat > add_gap_resolver_plan_v018_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

PLAN_PATH="experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"
PLAN_REPORT="experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json"

echo "[v0.0.18] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/hls_interface_extractor.py \
  xporthls/realrepo/validate_hls_interface_v013.py \
  xporthls/realrepo/run_hls_interface_v013.py \
  xporthls/realrepo/application_ir_v2_builder.py \
  xporthls/realrepo/validate_application_ir_v2_v014.py \
  xporthls/realrepo/run_application_ir_v2_v014.py \
  xporthls/realrepo/run_profile_case_v015.py \
  xporthls/realrepo/validate_profile_case_v015.py \
  xporthls/realrepo/run_hisparse_profile_case_v015.py \
  xporthls/realrepo/gap_contract_v016.py \
  xporthls/realrepo/validate_gap_contract_v016.py \
  xporthls/realrepo/run_gap_contract_v016.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py \
  xporthls/generators/validate_generator_guard_v017.py \
  xporthls/realrepo/gap_resolver_plan_v018.py \
  xporthls/realrepo/validate_gap_resolver_plan_v018.py \
  xporthls/realrepo/run_gap_resolver_plan_v018.py

echo "[v0.0.18] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.18] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.18] Re-run v0.0.17 generator guard baseline"

rm -rf experiments/runs/hisparse_u280_profile_guarded_generated_v017

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir experiments/runs/hisparse_u280_profile_guarded_generated_v017 \
  --report-out experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json \
  --out experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json \
  --expect-blocked

echo "[v0.0.18] Build Gap Resolver Plan"

python3 -m xporthls.realrepo.run_gap_resolver_plan_v018 \
  --case-id hisparse_u280_profile \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --out-dir experiments/runs

python3 - <<'PY'
import json
from pathlib import Path

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))
plan = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json"))
report = json.load(open("experiments/runs/hisparse_u280_profile_gap_resolver_plan_report_v018.json"))

summary = plan["summary"]
resolver_types = {r["gap_id"]: r["resolver_type"] for r in plan["resolvers"]}

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Plan schema:", plan["schema_version"])
print("Plan state:", plan["plan_state"])
print("Migration status:", plan["migration_status"])
print("Generation allowed:", summary["generation_allowed"])
print("Resolver execution allowed:", summary["resolver_execution_allowed"])
print("Resolvers:", summary["num_resolvers"])
print("Blocking resolvers:", summary["num_blocking_resolvers"])
print("Warning resolvers:", summary["num_warning_resolvers"])
print("Info resolvers:", summary["num_info_resolvers"])
print("Blocking resolver IDs:", summary["blocking_resolver_ids"])
print("Resolver types:", resolver_types)
print("Validation status:", report["status"])

required_types = {
    "GAP-XRT-HOST-001": "HostRuntimeRewritePlan",
    "GAP-PLATFORM-001": "SourcePlatformMappingPlan",
    "GAP-MEM-HBM-001": "MemoryMappingPlan",
    "GAP-STREAM-AXIS-001": "StreamGraphMappingPlan",
    "GAP-PLACEMENT-SLR-001": "PlacementPolicyPlan",
    "GAP-KERNEL-NAME-001": "KernelNameResolutionPlan",
    "GAP-HLS-INTERFACE-001": "HlsInterfaceLoweringPlan",
}

assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert plan["schema_version"] == "gap_resolver_plan.v1"
assert plan["plan_state"] == "planned_profile_only"
assert plan["migration_status"] == "profile_only"
assert summary["generation_allowed"] is False
assert summary["resolver_execution_allowed"] is False
assert summary["num_blocking_resolvers"] == len(contract["summary"]["blocking_gap_ids"])
assert summary["num_resolvers"] == contract["summary"]["num_gaps"]
assert report["status"] == "pass"

for gap_id, resolver_type in required_types.items():
    assert resolver_types[gap_id] == resolver_type, (gap_id, resolver_types.get(gap_id))
PY

echo
echo "DONE."
EOT

chmod +x add_gap_resolver_plan_v018_replay.sh

echo "[6/6] Run v0.0.18 replay"

./add_gap_resolver_plan_v018_replay.sh

echo "[v0.0.18] Git status"

git status
