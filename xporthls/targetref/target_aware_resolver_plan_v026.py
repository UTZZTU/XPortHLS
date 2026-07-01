from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REMAINING_BLOCKING_GAPS_V022 = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

RESOLVED_PRIOR_GAPS = [
    "GAP-KERNEL-NAME-001",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def json_digest(obj: Any) -> str:
    return sha256_text(json.dumps(obj, sort_keys=True, ensure_ascii=False))


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, obj: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def get_pairing_by_gap(pairing: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for p in pairing.get("pairings", []):
        if isinstance(p, dict) and p.get("gap_id"):
            out[p["gap_id"]] = p
    return out


def get_contract_blocking_gap_ids(contract: dict[str, Any]) -> list[str]:
    summary = contract.get("summary", {})
    for key in ["blocking_gap_ids", "blocking_gaps", "blocking_ids"]:
        val = summary.get(key)
        if isinstance(val, list):
            return list(val)

    ids: list[str] = []
    for g in contract.get("gaps", []):
        if not isinstance(g, dict):
            continue
        if g.get("blocks_migration") is True or g.get("severity") == "blocking":
            gid = g.get("gap_id") or g.get("id")
            if gid:
                ids.append(gid)
    return ids


def get_contract_resolved_gap_ids(contract: dict[str, Any]) -> list[str]:
    summary = contract.get("summary", {})
    for key in ["resolved_gap_ids", "resolved_gaps", "resolved_ids"]:
        val = summary.get(key)
        if isinstance(val, list):
            return list(val)

    ids: list[str] = []
    for g in contract.get("gaps", []):
        if not isinstance(g, dict):
            continue
        if g.get("severity") == "resolved" or g.get("resolution_state"):
            gid = g.get("gap_id") or g.get("id")
            if gid:
                ids.append(gid)
    return ids


def evidence_count_from_pairing(p: dict[str, Any]) -> int:
    score = p.get("scoring", {}).get("score", 0)
    try:
        return int(score)
    except Exception:
        return 0


def resolver_specs() -> dict[str, dict[str, Any]]:
    return {
        "GAP-XRT-HOST-001": {
            "resolver_name": "AVEDHostRuntimePatternResolver",
            "priority": 10,
            "readiness_policy": "ready_for_resolver_design",
            "candidate_goal": "Derive a target-side host runtime contract from XRT host actions and AVED/V80 QDMA + AXI-Lite + AP_CTRL evidence.",
            "must_extract": [
                "source XRT host actions: device/xclbin/kernel/bo/sync/run.start/run.wait",
                "target QDMA device and transfer API pattern",
                "target AXI-Lite register write/read pattern",
                "target AP_CTRL start/done/idle polling pattern",
                "host verification and timeout behavior",
            ],
            "must_not_do": [
                "do not generate final host code",
                "do not mark GAP-XRT-HOST-001 resolved",
                "do not modify the gap contract",
                "do not unlock generator",
            ],
            "inputs": [
                "ApplicationIR source_profile.xrt_host",
                "TargetReferenceIR host_runtime_pattern",
                "TargetReferenceIR qdma_transfer_pattern",
                "TargetReferenceIR axi_lite_register_pattern",
                "PatternPairing GAP-XRT-HOST-001",
            ],
            "expected_next_artifacts": [
                "aved_host_runtime_pattern_v027.json",
                "aved_host_runtime_pattern_report_v027.json",
                "aved_host_runtime_pattern_validation_v027.json",
            ],
            "validation_requirements": [
                "all host runtime facts must be evidence-backed",
                "XRT actions must map to explicit QDMA/control actions",
                "AP_CTRL behavior must be represented but not executed",
                "no contract mutation",
            ],
        },
        "GAP-PLATFORM-001": {
            "resolver_name": "AVEDPlatformProjectPatternResolver",
            "priority": 50,
            "readiness_policy": "ready_for_resolver_design_after_host_memory_interface_patterns",
            "candidate_goal": "Derive AVED/V80 project-template and Vivado BD/Tcl construction requirements from target reference evidence.",
            "must_extract": [
                "create_design.tcl structure",
                "create_bd_design.tcl structure",
                "IP repository setup",
                "Vivado project part/platform fields",
                "PDI-oriented AVED build flow entry points",
            ],
            "must_not_do": [
                "do not create a real target project yet",
                "do not replace AVED templates blindly",
                "do not mark GAP-PLATFORM-001 resolved",
            ],
            "inputs": [
                "TargetReferenceIR vivado_aved_project_pattern",
                "TargetReferenceIR bd_tcl_pattern",
                "PatternPairing GAP-PLATFORM-001",
            ],
            "expected_next_artifacts": [
                "aved_platform_project_pattern_v0xx.json",
                "aved_platform_project_pattern_validation_v0xx.json",
            ],
            "validation_requirements": [
                "project template facts must point to target evidence",
                "BD/Tcl commands must remain target-reference facts",
                "no generated AVED project is produced at this stage",
            ],
        },
        "GAP-MEM-HBM-001": {
            "resolver_name": "HBMPCMemoryMappingResolver",
            "priority": 20,
            "readiness_policy": "ready_for_resolver_design",
            "candidate_goal": "Map source HBM bank/group_id/bundle intent to V80 HBM/PC address and Vivado BD address-assignment evidence.",
            "must_extract": [
                "source memory mappings and group_id/bundle facts",
                "target HBM/PC base/stride/offset evidence",
                "QDMA target address usage",
                "assign_bd_address evidence",
                "variant-level HBM/SK mapping hints",
            ],
            "must_not_do": [
                "do not assign new addresses without validation",
                "do not mark GAP-MEM-HBM-001 resolved",
                "do not claim DDR<->HBM conversion support",
            ],
            "inputs": [
                "ApplicationIR source_profile.memory",
                "TargetReferenceIR hbm_pc_address_map",
                "TargetReferenceIR bd_tcl_pattern.connection_and_address_records",
                "TargetReferenceIR variant_index",
                "PatternPairing GAP-MEM-HBM-001",
            ],
            "expected_next_artifacts": [
                "hbm_pc_memory_mapping_plan_v0xx.json",
                "hbm_pc_memory_mapping_validation_v0xx.json",
            ],
            "validation_requirements": [
                "all address formulae must be evidence-backed",
                "no overlapping target regions",
                "source buffer sizes and target slot sizes must be checked before resolution",
            ],
        },
        "GAP-STREAM-AXIS-001": {
            "resolver_name": "AVEDStreamGraphResolver",
            "priority": 40,
            "readiness_policy": "ready_for_resolver_design_after_hls_interface_pattern",
            "candidate_goal": "Map source connectivity stream edges to target Vivado BD AXIS interface connections.",
            "must_extract": [
                "source stream edge graph",
                "source producer/consumer kernel names",
                "target connect_bd_intf_net evidence",
                "target AXIS pin naming conventions",
                "axis_duplicate/axis_merge patterns when present",
                "F_VERSION_CORRECTNESS shuffler evidence where relevant",
            ],
            "must_not_do": [
                "do not instantiate or connect real BD yet",
                "do not mark GAP-STREAM-AXIS-001 resolved",
                "do not treat shuffler fix as optimization",
            ],
            "inputs": [
                "ApplicationIR source_profile.stream",
                "TargetReferenceIR stream_connection_pattern",
                "TargetReferenceIR bd_tcl_pattern",
                "TargetReferenceIR known_correctness_fixes",
                "PatternPairing GAP-STREAM-AXIS-001",
            ],
            "expected_next_artifacts": [
                "aved_stream_graph_pattern_v0xx.json",
                "aved_stream_graph_pattern_validation_v0xx.json",
            ],
            "validation_requirements": [
                "producer/consumer counts must match",
                "stream edges must be evidence-backed",
                "shuffler correctness fixes must remain F_VERSION_CORRECTNESS",
            ],
        },
        "GAP-PLACEMENT-SLR-001": {
            "resolver_name": "PlacementEvidenceNormalizer",
            "priority": 60,
            "readiness_policy": "normalize_only_not_ready_for_resolution",
            "candidate_goal": "Normalize placement/timing/SLR evidence and keep the gap blocking until target placement constraints/reports are sufficient.",
            "must_extract": [
                "source SLR assignment evidence",
                "target placement/timing/XDC/Pblock evidence if present",
                "missing target placement constraint evidence",
                "timing report availability",
            ],
            "must_not_do": [
                "do not mark GAP-PLACEMENT-SLR-001 resolved",
                "do not infer V80 placement from U280 SLR constraints",
                "do not claim placement portability",
            ],
            "inputs": [
                "ApplicationIR source_profile.placement",
                "TargetReferenceIR placement recursive evidence",
                "PatternPairing GAP-PLACEMENT-SLR-001",
            ],
            "expected_next_artifacts": [
                "placement_evidence_normalization_v0xx.json",
                "placement_evidence_validation_v0xx.json",
            ],
            "validation_requirements": [
                "placement remains partial",
                "missing evidence must be explicit",
                "resolver must not reduce blocking count",
            ],
        },
        "GAP-HLS-INTERFACE-001": {
            "resolver_name": "HLSInterfaceLoweringPatternResolver",
            "priority": 30,
            "readiness_policy": "ready_for_resolver_design",
            "candidate_goal": "Derive target HLS IP interface lowering requirements from source HLS interface facts and SPMV-on-V80 HLS IP packaging evidence.",
            "must_extract": [
                "source m_axi/axis/s_axilite/ap_ctrl/dataflow facts",
                "target HLS IP packaging flow",
                "target packed ap_uint external memory word evidence",
                "target s_axilite/AP_CTRL conventions",
                "target AXIS interface evidence",
            ],
            "must_not_do": [
                "do not rewrite HLS kernels yet",
                "do not mark GAP-HLS-INTERFACE-001 resolved",
                "do not mix correctness fixes with PPA-only optimizations",
            ],
            "inputs": [
                "ApplicationIR source_profile.hls_interface",
                "TargetReferenceIR hls_ip_packaging_pattern",
                "TargetReferenceIR axi_lite_register_pattern",
                "PatternPairing GAP-HLS-INTERFACE-001",
            ],
            "expected_next_artifacts": [
                "hls_interface_lowering_pattern_v0xx.json",
                "hls_interface_lowering_validation_v0xx.json",
            ],
            "validation_requirements": [
                "external memory width changes must be evidence-backed",
                "s_axilite/AP_CTRL must match host-control pattern",
                "stream ports must be cross-checked with stream graph resolver",
            ],
        },
    }


def dependency_edges() -> list[dict[str, str]]:
    return [
        {
            "from": "GAP-XRT-HOST-001",
            "to": "GAP-MEM-HBM-001",
            "relationship": "host QDMA transfers require memory/address mapping",
        },
        {
            "from": "GAP-HLS-INTERFACE-001",
            "to": "GAP-STREAM-AXIS-001",
            "relationship": "stream graph requires normalized HLS AXIS interfaces",
        },
        {
            "from": "GAP-HLS-INTERFACE-001",
            "to": "GAP-PLATFORM-001",
            "relationship": "platform BD integration requires packaged HLS IP interface facts",
        },
        {
            "from": "GAP-MEM-HBM-001",
            "to": "GAP-PLATFORM-001",
            "relationship": "platform BD/address plan depends on memory mapping plan",
        },
        {
            "from": "GAP-STREAM-AXIS-001",
            "to": "GAP-PLATFORM-001",
            "relationship": "platform BD construction depends on stream connection plan",
        },
        {
            "from": "GAP-PLACEMENT-SLR-001",
            "to": "GAP-PLATFORM-001",
            "relationship": "placement evidence affects later Vivado implementation, but remains partial in this version",
        },
    ]


def build_target_aware_resolver_plan(
    application_ir: dict[str, Any],
    target_reference_ir: dict[str, Any],
    pattern_pairing: dict[str, Any],
    patched_contract: dict[str, Any],
    old_resolver_plan: dict[str, Any] | None = None,
    source_case_id: str = "hisparse_u280_profile",
    target_case_id: str = "spmv_on_v80",
) -> dict[str, Any]:
    specs = resolver_specs()
    pair_by_gap = get_pairing_by_gap(pattern_pairing)
    contract_blockers = get_contract_blocking_gap_ids(patched_contract)
    contract_resolved = get_contract_resolved_gap_ids(patched_contract)

    resolvers: list[dict[str, Any]] = []
    for gap_id in REMAINING_BLOCKING_GAPS_V022:
        spec = specs[gap_id]
        pairing = pair_by_gap.get(gap_id, {})
        pairing_state = pairing.get("pairing_state", "missing_pairing")
        score = evidence_count_from_pairing(pairing)

        if gap_id == "GAP-PLACEMENT-SLR-001":
            execution_readiness = "normalize_evidence_only"
            ready_for_contract_resolution = False
        elif pairing_state == "paired_with_target_reference_evidence":
            execution_readiness = "ready_for_next_resolver_design"
            ready_for_contract_resolution = False
        elif pairing_state == "partial_target_reference_evidence":
            execution_readiness = "needs_more_target_evidence_before_resolver"
            ready_for_contract_resolution = False
        else:
            execution_readiness = "blocked_missing_pairing_evidence"
            ready_for_contract_resolution = False

        resolvers.append({
            "resolver_id": f"TARGET-AWARE-RESOLVE-{gap_id.replace('GAP-', '')}",
            "gap_id": gap_id,
            "resolver_name": spec["resolver_name"],
            "priority": spec["priority"],
            "pairing_state": pairing_state,
            "pairing_score": score,
            "execution_readiness": execution_readiness,
            "ready_for_contract_resolution": ready_for_contract_resolution,
            "contract_state_after_v026": "unchanged_blocking",
            "candidate_goal": spec["candidate_goal"],
            "readiness_policy": spec["readiness_policy"],
            "must_extract": spec["must_extract"],
            "must_not_do": spec["must_not_do"],
            "inputs": spec["inputs"],
            "expected_next_artifacts": spec["expected_next_artifacts"],
            "validation_requirements": spec["validation_requirements"],
            "source_target_mapping": pairing.get("proposed_source_to_target_mapping", {}),
            "manual_operation_trace": pairing.get("manual_operation_trace", []),
            "known_correctness_fixes": pairing.get("known_correctness_fixes", []),
            "evidence_refs": {
                "pattern_pairing_pair_id": pairing.get("pair_id"),
                "application_ir_digest": json_digest(application_ir),
                "target_reference_facts_digest": target_reference_ir.get("facts_digest"),
                "pattern_pairing_digest": pattern_pairing.get("pairing_digest"),
            },
            "trust_boundary": {
                "llm_used": False,
                "authoritative": False,
                "can_execute": False,
                "can_modify_contract": False,
                "can_mark_gap_resolved": False,
                "can_unlock_generator": False,
                "plan_only": True,
            },
        })

    ordered = sorted(resolvers, key=lambda r: r["priority"])
    recommended_execution_order = [
        {
            "order": i + 1,
            "gap_id": r["gap_id"],
            "resolver_name": r["resolver_name"],
            "execution_readiness": r["execution_readiness"],
            "note": (
                "recommended first concrete resolver candidate"
                if i == 0 else
                "planned after prerequisite evidence is normalized"
            ),
        }
        for i, r in enumerate(ordered)
    ]

    plan_digest_material = {
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "contract_blockers": contract_blockers,
        "contract_resolved": contract_resolved,
        "pairing_digest": pattern_pairing.get("pairing_digest"),
        "target_reference_digest": target_reference_ir.get("facts_digest"),
        "resolver_names": {r["gap_id"]: r["resolver_name"] for r in resolvers},
        "resolver_readiness": {r["gap_id"]: r["execution_readiness"] for r in resolvers},
        "priorities": {r["gap_id"]: r["priority"] for r in resolvers},
    }

    return {
        "schema_version": "target_aware_gap_resolution_plan.v1",
        "xporthls_version": "v0.0.26",
        "created_at_utc": utc_now(),
        "migration_direction": "XRT->AVED",
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "source_ir_schema": application_ir.get("schema_version") or application_ir.get("schema"),
        "target_reference_schema": target_reference_ir.get("schema_version"),
        "pattern_pairing_schema": pattern_pairing.get("schema_version"),
        "patched_contract_schema": patched_contract.get("schema_version"),
        "input_artifact_digests": {
            "application_ir_digest": json_digest(application_ir),
            "target_reference_ir_digest": json_digest(target_reference_ir),
            "pattern_pairing_digest": json_digest(pattern_pairing),
            "patched_contract_digest": json_digest(patched_contract),
            "old_resolver_plan_digest": json_digest(old_resolver_plan) if old_resolver_plan else None,
        },
        "contract_context": {
            "blocking_gap_ids": contract_blockers,
            "resolved_gap_ids": contract_resolved,
            "expected_remaining_blocking_gap_ids": list(REMAINING_BLOCKING_GAPS_V022),
            "resolved_prior_gaps": list(RESOLVED_PRIOR_GAPS),
            "contract_mutation_allowed": False,
            "blocking_gap_count_after_v026": len(contract_blockers),
        },
        "target_evidence_context": {
            "target_reference_files": target_reference_ir.get("summary", {}).get("files_total"),
            "target_reference_variants": target_reference_ir.get("summary", {}).get("variant_count"),
            "qdma_evidence_count": target_reference_ir.get("summary", {}).get("host_qdma_evidence_count"),
            "axi_lite_evidence_count": target_reference_ir.get("summary", {}).get("host_axi_lite_evidence_count"),
            "hls_axis_evidence_count": target_reference_ir.get("summary", {}).get("hls_axis_evidence_count"),
            "create_design_tcl_count": target_reference_ir.get("summary", {}).get("create_design_tcl_count"),
            "create_bd_design_tcl_count": target_reference_ir.get("summary", {}).get("create_bd_design_tcl_count"),
            "bd_connect_bd_intf_net_count": target_reference_ir.get("summary", {}).get("bd_connect_bd_intf_net_count"),
            "bd_assign_bd_address_count": target_reference_ir.get("summary", {}).get("bd_assign_bd_address_count"),
            "has_f_version_correctness": target_reference_ir.get("summary", {}).get("has_f_version_correctness"),
        },
        "pattern_pairing_context": {
            "num_pairings": pattern_pairing.get("summary", {}).get("num_pairings"),
            "paired_gap_count": pattern_pairing.get("summary", {}).get("paired_gap_count"),
            "partial_gap_count": pattern_pairing.get("summary", {}).get("partial_gap_count"),
            "unpaired_gap_count": pattern_pairing.get("summary", {}).get("unpaired_gap_count"),
            "gaps_marked_resolved_by_v025": pattern_pairing.get("summary", {}).get("gaps_marked_resolved_by_v025"),
        },
        "resolvers": resolvers,
        "dependency_edges": dependency_edges(),
        "recommended_execution_order": recommended_execution_order,
        "v027_recommendation": {
            "recommended_next_version": "v0.0.27",
            "recommended_next_resolver": "AVEDHostRuntimePatternResolver",
            "recommended_gap_id": "GAP-XRT-HOST-001",
            "reason": "Host runtime is the clearest XRT->AVED semantic expansion and has direct QDMA, AXI-Lite, and AP_CTRL target evidence.",
            "alternative_next_resolver": "HBMPCMemoryMappingResolver",
            "alternative_gap_id": "GAP-MEM-HBM-001",
            "why_not_placement_next": "Placement remains partial and should be normalized later, not resolved next.",
        },
        "trust_boundary": {
            "llm_used": False,
            "llm_annotations_allowed": False,
            "authoritative": False,
            "contract_modified": False,
            "migration_allowed_modified": False,
            "generator_unlocked": False,
            "can_resolve_gap": False,
            "can_execute_resolver": False,
            "plan_only": True,
            "requires_future_resolver_and_validation": True,
        },
        "summary": {
            "num_resolvers": len(resolvers),
            "blocking_resolvers": len(resolvers),
            "ready_for_next_resolver_design_count": sum(1 for r in resolvers if r["execution_readiness"] == "ready_for_next_resolver_design"),
            "normalize_only_count": sum(1 for r in resolvers if r["execution_readiness"] == "normalize_evidence_only"),
            "missing_evidence_count": sum(1 for r in resolvers if r["execution_readiness"] == "blocked_missing_pairing_evidence"),
            "gaps_marked_resolved_by_v026": 0,
            "contract_blocking_gap_count": len(contract_blockers),
            "generator_unlock_allowed": False,
            "llm_used": False,
            "contract_modified": False,
        },
        "plan_digest": json_digest(plan_digest_material),
        "llm_annotations": [],
    }


def build_target_aware_resolver_report(plan: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "target_aware_gap_resolution_plan_report.v1",
        "xporthls_version": "v0.0.26",
        "created_at_utc": utc_now(),
        "migration_direction": plan.get("migration_direction"),
        "source_case_id": plan.get("source_case_id"),
        "target_case_id": plan.get("target_case_id"),
        "summary": plan.get("summary", {}),
        "contract_context": plan.get("contract_context", {}),
        "target_evidence_context": plan.get("target_evidence_context", {}),
        "pattern_pairing_context": plan.get("pattern_pairing_context", {}),
        "recommended_execution_order": plan.get("recommended_execution_order", []),
        "v027_recommendation": plan.get("v027_recommendation", {}),
        "resolver_overview": [
            {
                "gap_id": r["gap_id"],
                "resolver_name": r["resolver_name"],
                "priority": r["priority"],
                "pairing_state": r["pairing_state"],
                "pairing_score": r["pairing_score"],
                "execution_readiness": r["execution_readiness"],
                "ready_for_contract_resolution": r["ready_for_contract_resolution"],
                "contract_state_after_v026": r["contract_state_after_v026"],
            }
            for r in sorted(plan.get("resolvers", []), key=lambda x: x.get("priority", 9999))
        ],
        "trust_boundary": plan.get("trust_boundary", {}),
        "llm_annotations": [],
    }
