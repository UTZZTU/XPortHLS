#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Add Target-Aware Gap Resolution Plan v0.0.26 modules"

mkdir -p xporthls/targetref
touch xporthls/targetref/__init__.py

cat > xporthls/targetref/target_aware_resolver_plan_v026.py <<'EOT'
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
EOT

cat > xporthls/targetref/validate_target_aware_resolver_plan_v026.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from xporthls.targetref.target_aware_resolver_plan_v026 import (
    REMAINING_BLOCKING_GAPS_V022,
    RESOLVED_PRIOR_GAPS,
)


@dataclass
class TargetAwarePlanIssue:
    severity: str
    code: str
    message: str


@dataclass
class TargetAwarePlanValidationReport:
    schema_version: str = "target_aware_gap_resolution_plan_validation_report.v1"
    xporthls_version: str = "v0.0.26"
    status: str = "fail"
    issues: list[TargetAwarePlanIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)
    llm_annotations: list[Any] = field(default_factory=list)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[TargetAwarePlanIssue], severity: str, code: str, message: str) -> None:
    issues.append(TargetAwarePlanIssue(severity=severity, code=code, message=message))


def validate_target_aware_plan(plan: dict[str, Any], guard_report: dict[str, Any] | None = None) -> TargetAwarePlanValidationReport:
    issues: list[TargetAwarePlanIssue] = []

    if plan.get("schema_version") != "target_aware_gap_resolution_plan.v1":
        add_issue(issues, "error", "SCHEMA", "Expected target_aware_gap_resolution_plan.v1.")

    if plan.get("xporthls_version") != "v0.0.26":
        add_issue(issues, "error", "VERSION", "Expected xporthls_version v0.0.26.")

    if plan.get("migration_direction") != "XRT->AVED":
        add_issue(issues, "error", "MIGRATION_DIRECTION", "Expected migration_direction XRT->AVED.")

    if plan.get("target_reference_schema") != "target_reference_ir.v1":
        add_issue(issues, "error", "TARGET_REFERENCE_SCHEMA", "Expected target_reference_ir.v1.")

    if plan.get("pattern_pairing_schema") != "source_target_pattern_pairing.v1":
        add_issue(issues, "error", "PATTERN_PAIRING_SCHEMA", "Expected source_target_pattern_pairing.v1.")

    if plan.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS", "v0.0.26 must not contain LLM annotations.")

    tb = plan.get("trust_boundary", {})
    required_false = [
        "llm_used",
        "contract_modified",
        "migration_allowed_modified",
        "generator_unlocked",
        "can_resolve_gap",
        "can_execute_resolver",
    ]
    for key in required_false:
        if tb.get(key) is not False:
            add_issue(issues, "error", "TRUST_BOUNDARY", f"Trust boundary flag must be false: {key}")

    if tb.get("plan_only") is not True:
        add_issue(issues, "error", "PLAN_ONLY", "v0.0.26 must be a plan-only stage.")

    if tb.get("requires_future_resolver_and_validation") is not True:
        add_issue(issues, "error", "FUTURE_VALIDATION", "Plan must require future resolver and validation.")

    contract_context = plan.get("contract_context", {})
    if sorted(contract_context.get("expected_remaining_blocking_gap_ids", [])) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "EXPECTED_BLOCKERS", "Expected remaining blocking gaps mismatch.")

    blockers = contract_context.get("blocking_gap_ids", [])
    if sorted(blockers) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "CONTRACT_BLOCKERS", "Contract blockers must remain the six post-v0.0.22 blockers.")

    for gid in RESOLVED_PRIOR_GAPS:
        if gid in blockers:
            add_issue(issues, "error", "RESOLVED_GAP_BLOCKING", f"Resolved prior gap must not be blocking: {gid}")

    if contract_context.get("contract_mutation_allowed") is not False:
        add_issue(issues, "error", "CONTRACT_MUTATION_ALLOWED", "Contract mutation must not be allowed in v0.0.26.")

    resolvers = plan.get("resolvers", [])
    if len(resolvers) != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "RESOLVER_COUNT", "Expected one target-aware resolver plan per remaining blocker.")

    resolver_gap_ids = [r.get("gap_id") for r in resolvers]
    if sorted(resolver_gap_ids) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "RESOLVER_GAP_SET", "Resolver gap set mismatch.")

    seen_priorities: set[int] = set()
    for r in resolvers:
        gid = r.get("gap_id")
        priority = r.get("priority")
        if not isinstance(priority, int):
            add_issue(issues, "error", "BAD_PRIORITY", f"Resolver priority must be int: {gid}")
        elif priority in seen_priorities:
            add_issue(issues, "error", "DUPLICATE_PRIORITY", f"Duplicate priority: {priority}")
        else:
            seen_priorities.add(priority)

        if r.get("ready_for_contract_resolution") is not False:
            add_issue(issues, "error", "READY_FOR_CONTRACT_RESOLUTION", f"v0.0.26 must not make gaps ready for contract resolution: {gid}")

        if r.get("contract_state_after_v026") != "unchanged_blocking":
            add_issue(issues, "error", "CONTRACT_STATE_CHANGE", f"Resolver must keep contract state unchanged/blocking: {gid}")

        rtb = r.get("trust_boundary", {})
        for key in ["llm_used", "authoritative", "can_execute", "can_modify_contract", "can_mark_gap_resolved", "can_unlock_generator"]:
            if rtb.get(key) is not False:
                add_issue(issues, "error", "RESOLVER_TRUST_BOUNDARY", f"{gid} trust flag must be false: {key}")
        if rtb.get("plan_only") is not True:
            add_issue(issues, "error", "RESOLVER_PLAN_ONLY", f"{gid} must be plan-only.")

        if not r.get("must_extract"):
            add_issue(issues, "error", "MISSING_MUST_EXTRACT", f"Resolver must list must_extract: {gid}")
        if not r.get("must_not_do"):
            add_issue(issues, "error", "MISSING_MUST_NOT_DO", f"Resolver must list must_not_do: {gid}")
        if not r.get("validation_requirements"):
            add_issue(issues, "error", "MISSING_VALIDATION_REQUIREMENTS", f"Resolver must list validation requirements: {gid}")

        if gid == "GAP-PLACEMENT-SLR-001":
            if r.get("execution_readiness") != "normalize_evidence_only":
                add_issue(issues, "error", "PLACEMENT_NOT_NORMALIZE_ONLY", "Placement must be normalize-only in v0.0.26.")
            if r.get("resolver_name") != "PlacementEvidenceNormalizer":
                add_issue(issues, "error", "PLACEMENT_RESOLVER_NAME", "Placement resolver must be PlacementEvidenceNormalizer.")

    summary = plan.get("summary", {})
    if summary.get("gaps_marked_resolved_by_v026") != 0:
        add_issue(issues, "error", "RESOLVED_BY_V026", "v0.0.26 must mark zero gaps resolved.")
    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK", "v0.0.26 must not unlock generator.")
    if summary.get("llm_used") is not False:
        add_issue(issues, "error", "SUMMARY_LLM_USED", "summary.llm_used must be false.")
    if summary.get("contract_modified") is not False:
        add_issue(issues, "error", "SUMMARY_CONTRACT_MODIFIED", "summary.contract_modified must be false.")
    if summary.get("contract_blocking_gap_count") != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "BLOCKING_COUNT", "Contract blocking count must remain six.")

    target_evidence = plan.get("target_evidence_context", {})
    required_positive_evidence = [
        "target_reference_files",
        "target_reference_variants",
        "qdma_evidence_count",
        "axi_lite_evidence_count",
        "hls_axis_evidence_count",
        "create_design_tcl_count",
        "create_bd_design_tcl_count",
        "bd_connect_bd_intf_net_count",
        "bd_assign_bd_address_count",
    ]
    for key in required_positive_evidence:
        val = target_evidence.get(key)
        if not isinstance(val, int) or val <= 0:
            add_issue(issues, "error", "TARGET_EVIDENCE", f"Expected positive target evidence count: {key}")

    if target_evidence.get("has_f_version_correctness") is not True:
        add_issue(issues, "error", "F_VERSION_CORRECTNESS", "Expected F_VERSION_CORRECTNESS evidence from target reference.")

    pair_ctx = plan.get("pattern_pairing_context", {})
    if pair_ctx.get("num_pairings") != 6:
        add_issue(issues, "error", "PAIRING_COUNT", "Expected six pairings from v0.0.25.")
    if pair_ctx.get("unpaired_gap_count") != 0:
        add_issue(issues, "error", "UNPAIRED_GAPS", "Expected zero unpaired gaps from v0.0.25.")
    if pair_ctx.get("gaps_marked_resolved_by_v025") != 0:
        add_issue(issues, "error", "V025_RESOLVED_GAPS", "v0.0.25 should have resolved zero gaps.")

    rec = plan.get("v027_recommendation", {})
    if rec.get("recommended_next_resolver") != "AVEDHostRuntimePatternResolver":
        add_issue(issues, "warning", "V027_RECOMMENDATION", "Expected AVEDHostRuntimePatternResolver as recommended next resolver.")
    if rec.get("recommended_gap_id") != "GAP-XRT-HOST-001":
        add_issue(issues, "warning", "V027_GAP", "Expected GAP-XRT-HOST-001 as recommended next gap.")

    if guard_report is not None:
        if guard_report.get("schema_version") != "generator_guard_report.v1":
            add_issue(issues, "error", "GUARD_SCHEMA", "Expected generator_guard_report.v1.")
        if guard_report.get("decision", {}).get("blocked") is not True:
            add_issue(issues, "error", "GUARD_NOT_BLOCKED", "Generator guard must remain blocked.")
        if guard_report.get("decision", {}).get("allowed") is not False:
            add_issue(issues, "error", "GUARD_ALLOWED", "Generator guard must not allow generation.")
        guard_blockers = guard_report.get("summary", {}).get("blocking_gap_ids", [])
        if sorted(guard_blockers) != sorted(REMAINING_BLOCKING_GAPS_V022):
            add_issue(issues, "error", "GUARD_BLOCKERS", "Guard blocking IDs must remain the six post-v0.0.22 blockers.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return TargetAwarePlanValidationReport(
        status=status,
        issues=issues,
        summary={
            "plan_schema": plan.get("schema_version"),
            "migration_direction": plan.get("migration_direction"),
            "source_case_id": plan.get("source_case_id"),
            "target_case_id": plan.get("target_case_id"),
            "num_resolvers": len(resolvers),
            "ready_for_next_resolver_design_count": summary.get("ready_for_next_resolver_design_count"),
            "normalize_only_count": summary.get("normalize_only_count"),
            "missing_evidence_count": summary.get("missing_evidence_count"),
            "gaps_marked_resolved_by_v026": summary.get("gaps_marked_resolved_by_v026"),
            "contract_blocking_gap_count": summary.get("contract_blocking_gap_count"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "llm_used": summary.get("llm_used"),
            "contract_modified": summary.get("contract_modified"),
            "recommended_next_resolver": rec.get("recommended_next_resolver"),
            "recommended_gap_id": rec.get("recommended_gap_id"),
            "guard_blocked": guard_report.get("decision", {}).get("blocked") if guard_report else None,
            "guard_allowed": guard_report.get("decision", {}).get("allowed") if guard_report else None,
            "num_errors": sum(1 for i in issues if i.severity == "error"),
            "num_warnings": sum(1 for i in issues if i.severity == "warning"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate target-aware resolver plan v0.0.26")
    parser.add_argument("--plan", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    plan = load_json(args.plan)
    guard = load_json(args.guard_report) if args.guard_report else None

    report = validate_target_aware_plan(plan, guard)
    report.save(args.out)

    print(f"[xporthls] Target-aware plan validation: {args.out}")
    print(f"[xporthls] Validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

cat > xporthls/targetref/run_target_aware_resolver_plan_v026.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.targetref.target_aware_resolver_plan_v026 import (
    build_target_aware_resolver_plan,
    build_target_aware_resolver_report,
    load_json,
    save_json,
)
from xporthls.targetref.validate_target_aware_resolver_plan_v026 import validate_target_aware_plan


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.26 target-aware resolver plan")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--pattern-pairing", required=True)
    parser.add_argument("--patched-contract", required=True)
    parser.add_argument("--old-resolver-plan", default=None)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--source-case-id", default="hisparse_u280_profile")
    parser.add_argument("--target-case-id", default="spmv_on_v80")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    app_ir = load_json(args.application_ir)
    target_ir = load_json(args.target_reference_ir)
    pairing = load_json(args.pattern_pairing)
    patched_contract = load_json(args.patched_contract)
    old_plan = load_json(args.old_resolver_plan) if args.old_resolver_plan else None
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    plan_path = out_dir / f"{prefix}_target_aware_resolver_plan_v026.json"
    report_path = out_dir / f"{prefix}_target_aware_resolver_plan_report_v026.json"
    validation_path = out_dir / f"{prefix}_target_aware_resolver_plan_validation_v026.json"

    plan = build_target_aware_resolver_plan(
        application_ir=app_ir,
        target_reference_ir=target_ir,
        pattern_pairing=pairing,
        patched_contract=patched_contract,
        old_resolver_plan=old_plan,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(plan_path, plan)

    report = build_target_aware_resolver_report(plan)
    save_json(report_path, report)

    validation = validate_target_aware_plan(plan, guard)
    validation.save(validation_path)

    s = plan["summary"]
    rec = plan["v027_recommendation"]

    print(f"[xporthls] Target-aware resolver plan: {plan_path}")
    print(f"[xporthls] Target-aware resolver report: {report_path}")
    print(f"[xporthls] Target-aware resolver validation: {validation_path}")
    print(f"[xporthls] Schema: {plan['schema_version']}")
    print(f"[xporthls] Migration direction: {plan['migration_direction']}")
    print(f"[xporthls] Source case: {plan['source_case_id']}")
    print(f"[xporthls] Target case: {plan['target_case_id']}")
    print(f"[xporthls] Resolvers: {s['num_resolvers']}")
    print(f"[xporthls] Ready for next resolver design: {s['ready_for_next_resolver_design_count']}")
    print(f"[xporthls] Normalize-only: {s['normalize_only_count']}")
    print(f"[xporthls] Missing evidence: {s['missing_evidence_count']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.26: {s['gaps_marked_resolved_by_v026']}")
    print(f"[xporthls] Contract blocking gap count: {s['contract_blocking_gap_count']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] v0.0.27 recommended resolver: {rec['recommended_next_resolver']}")
    print(f"[xporthls] v0.0.27 recommended gap: {rec['recommended_gap_id']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Update README with v0.0.26 implementation note if needed"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
if not p.exists():
    p.write_text("# XPortHLS\n", encoding="utf-8")

text = p.read_text(encoding="utf-8")
section = """
## Target-Aware Gap Resolution Plan v0.0.26

v0.0.26 upgrades the old resolver plan using target-side SPMV-on-V80 evidence and v0.0.25 source-target pattern pairings.

This version produces `target_aware_gap_resolution_plan.v1` for the six remaining blockers. It assigns concrete next resolver names, priorities, required input evidence, dependencies, validation requirements, and explicit forbidden actions.

It does not execute resolvers, does not mark any gap as resolved, does not modify the contract, does not unlock the generator, and does not call an LLM.

Recommended next concrete resolver after v0.0.26:

```text
v0.0.27 — AVEDHostRuntimePatternResolver for GAP-XRT-HOST-001
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json
```
"""

if "## Target-Aware Gap Resolution Plan v0.0.26" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"
    p.write_text(text, encoding="utf-8")
PY

echo "[3/7] Create v0.0.26 replay script"

cat > add_target_aware_resolver_plan_v026_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATTERN_PAIRING="${PATTERN_PAIRING:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
OLD_RESOLVER_PLAN="${OLD_RESOLVER_PLAN:-experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_target_aware_plan_v026.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v026}"

PLAN="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json"
PLAN_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json"
PLAN_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json"

echo "[v0.0.26] Python syntax check"

python3 -m py_compile \
  xporthls/targetref/target_aware_resolver_plan_v026.py \
  xporthls/targetref/validate_target_aware_resolver_plan_v026.py \
  xporthls/targetref/run_target_aware_resolver_plan_v026.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.26] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATTERN_PAIRING" "$PATCHED_CONTRACT"; do
  if [ ! -f "$f" ]; then
    echo "[xporthls] MISSING: $f"
    missing=1
  else
    echo "[xporthls] Found: $f"
  fi
done

if [ "$missing" -ne 0 ]; then
  echo
  echo "[xporthls] ERROR: Required artifacts are missing."
  echo "Re-run prior versions first:"
  echo "  - v0.0.14/v0.0.15 for ApplicationIR v2"
  echo "  - v0.0.22 for patched gap contract"
  echo "  - v0.0.24 for TargetReferenceIR"
  echo "  - v0.0.25 for PatternPairing"
  exit 3
fi

if [ -f "$OLD_RESOLVER_PLAN" ]; then
  OLD_RESOLVER_PLAN_ARG=(--old-resolver-plan "$OLD_RESOLVER_PLAN")
  echo "[xporthls] Found old resolver plan: $OLD_RESOLVER_PLAN"
else
  OLD_RESOLVER_PLAN_ARG=()
  echo "[xporthls] WARNING: old resolver plan not found, continuing without it: $OLD_RESOLVER_PLAN"
fi

echo "[v0.0.26] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.26] Run target-aware resolver plan"

python3 -m xporthls.targetref.run_target_aware_resolver_plan_v026 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --pattern-pairing "$PATTERN_PAIRING" \
  --patched-contract "$PATCHED_CONTRACT" \
  "${OLD_RESOLVER_PLAN_ARG[@]}" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json

plan = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_target_aware_plan_v026.json", encoding="utf-8"))

s = plan["summary"]
ctx = plan["contract_context"]
rec = plan["v027_recommendation"]

print()
print("TargetAwarePlan schema:", plan["schema_version"])
print("Migration direction:", plan["migration_direction"])
print("Source case:", plan["source_case_id"])
print("Target case:", plan["target_case_id"])
print("Resolvers:", s["num_resolvers"])
print("Ready for next resolver design:", s["ready_for_next_resolver_design_count"])
print("Normalize-only:", s["normalize_only_count"])
print("Missing evidence:", s["missing_evidence_count"])
print("Contract blockers:", ctx["blocking_gap_ids"])
print("Resolved prior gaps:", ctx["resolved_prior_gaps"])
print("Gaps marked resolved by v0.0.26:", s["gaps_marked_resolved_by_v026"])
print("Contract blocking gap count:", s["contract_blocking_gap_count"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Recommended v0.0.27 resolver:", rec["recommended_next_resolver"])
print("Recommended v0.0.27 gap:", rec["recommended_gap_id"])
print("Alternative next resolver:", rec["alternative_next_resolver"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for item in plan["recommended_execution_order"]:
    print(f"{item['order']}. {item['gap_id']} -> {item['resolver_name']} [{item['execution_readiness']}]")

expected = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert plan["schema_version"] == "target_aware_gap_resolution_plan.v1"
assert plan["xporthls_version"] == "v0.0.26"
assert plan["migration_direction"] == "XRT->AVED"
assert plan["target_reference_schema"] == "target_reference_ir.v1"
assert plan["pattern_pairing_schema"] == "source_target_pattern_pairing.v1"
assert plan["llm_annotations"] == []
assert plan["trust_boundary"]["llm_used"] is False
assert plan["trust_boundary"]["contract_modified"] is False
assert plan["trust_boundary"]["generator_unlocked"] is False
assert plan["trust_boundary"]["can_resolve_gap"] is False
assert plan["trust_boundary"]["can_execute_resolver"] is False
assert s["num_resolvers"] == 6
assert s["ready_for_next_resolver_design_count"] >= 5
assert s["normalize_only_count"] == 1
assert s["missing_evidence_count"] == 0
assert s["gaps_marked_resolved_by_v026"] == 0
assert s["contract_blocking_gap_count"] == 6
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(ctx["blocking_gap_ids"]) == sorted(expected)
assert "GAP-KERNEL-NAME-001" not in ctx["blocking_gap_ids"]
assert "GAP-KERNEL-NAME-001" in ctx["resolved_prior_gaps"]
assert rec["recommended_next_resolver"] == "AVEDHostRuntimePatternResolver"
assert rec["recommended_gap_id"] == "GAP-XRT-HOST-001"
assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected)

resolver_by_gap = {r["gap_id"]: r for r in plan["resolvers"]}
assert resolver_by_gap["GAP-PLACEMENT-SLR-001"]["execution_readiness"] == "normalize_evidence_only"
assert resolver_by_gap["GAP-PLACEMENT-SLR-001"]["ready_for_contract_resolution"] is False
for gid, r in resolver_by_gap.items():
    assert r["ready_for_contract_resolution"] is False
    assert r["contract_state_after_v026"] == "unchanged_blocking"
    assert r["trust_boundary"]["can_execute"] is False
    assert r["trust_boundary"]["can_mark_gap_resolved"] is False
PY

echo
echo "DONE."
EOT

chmod +x add_target_aware_resolver_plan_v026_replay.sh

echo "[4/7] Add targetref README note"

cat > xporthls/targetref/README_v026.md <<'EOT'
# Target-Aware Gap Resolution Plan v0.0.26

This module upgrades the previous gap resolver plan using:

```text
ApplicationIR v2
TargetReferenceIR v1
Source-Target Pattern Pairing v1
Patched post-v0.0.22 Gap Contract
```

It creates a target-aware plan for the six remaining blockers.

This version is plan-only:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
Gaps resolved by v0.0.26: 0
```

Recommended next implementation milestone:

```text
v0.0.27 — AVEDHostRuntimePatternResolver for GAP-XRT-HOST-001
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_report_v026.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_validation_v026.json
```
EOT

echo "[5/7] Run v0.0.26 replay"

./add_target_aware_resolver_plan_v026_replay.sh

echo "[6/7] Git status"

git status

echo "[7/7] v0.0.26 script complete"
