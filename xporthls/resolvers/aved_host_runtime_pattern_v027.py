from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


HOST_GAP_ID = "GAP-XRT-HOST-001"

REMAINING_BLOCKING_GAPS_V022 = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

XRT_HOST_ACTION_SPECS = [
    {
        "source_action_id": "XRT_OPEN_DEVICE",
        "source_terms": ["xrt::device", "device(", "xrt device"],
        "target_action_id": "AVED_OPEN_QDMA_AND_CONTROL_BUS",
        "target_terms": ["QdmaDevice", "AxiLiteBus", "/dev/qdma", "qdma"],
        "mapping_rule": "Replace XRT device abstraction with explicit QDMA data path and AXI-Lite control bus handles.",
        "dependency": "none_for_pattern_extraction",
    },
    {
        "source_action_id": "XRT_LOAD_XCLBIN",
        "source_terms": ["xclbin", "load_xclbin", "program"],
        "target_action_id": "AVED_PDI_ALREADY_PROGRAMMED_OR_PLATFORM_SETUP",
        "target_terms": ["pdi", "ami_tool", "create_design.tcl", "build_all"],
        "mapping_rule": "Do not carry xclbin into target host runtime; AVED/V80 deployment is PDI/platform-flow related and handled by platform resolver.",
        "dependency": "GAP-PLATFORM-001",
    },
    {
        "source_action_id": "XRT_CREATE_KERNEL",
        "source_terms": ["xrt::kernel", "kernel(", "run("],
        "target_action_id": "AVED_HLS_IP_INSTANCE_CONTROL_BASE",
        "target_terms": ["AxiLiteBus", "AP_CTRL", "create_bd_cell", "s_axilite"],
        "mapping_rule": "Replace XRT kernel object with explicit HLS IP instance and AXI-Lite control/register base evidence.",
        "dependency": "GAP-PLATFORM-001 + GAP-HLS-INTERFACE-001",
    },
    {
        "source_action_id": "XRT_ALLOC_BO",
        "source_terms": ["xrt::bo", "bo(", "group_id", "buffer"],
        "target_action_id": "HOST_BUFFER_PLUS_TARGET_HBM_PC_ADDRESS",
        "target_terms": ["HBM_PC_ADDR", "0x4000000000", "slot_bytes", "byte_offset", "QdmaDevice"],
        "mapping_rule": "Replace xrt::bo allocation/group selection with host buffer plus explicit V80 HBM/PC target address; exact map depends on memory resolver.",
        "dependency": "GAP-MEM-HBM-001",
    },
    {
        "source_action_id": "XRT_SYNC_TO_DEVICE",
        "source_terms": ["sync", "XCL_BO_SYNC_BO_TO_DEVICE", "to device", "write"],
        "target_action_id": "QDMA_WRITE_TO_TARGET_ADDRESS",
        "target_terms": ["write_from_buffer", "qdma", "QdmaDevice"],
        "mapping_rule": "Map host-to-device buffer sync to QDMA write into target HBM/PC address.",
        "dependency": "GAP-MEM-HBM-001",
    },
    {
        "source_action_id": "XRT_SYNC_FROM_DEVICE",
        "source_terms": ["sync", "XCL_BO_SYNC_BO_FROM_DEVICE", "from device", "read"],
        "target_action_id": "QDMA_READ_FROM_TARGET_ADDRESS",
        "target_terms": ["read_to_buffer", "qdma", "QdmaDevice"],
        "mapping_rule": "Map device-to-host buffer sync to QDMA read from target HBM/PC address.",
        "dependency": "GAP-MEM-HBM-001",
    },
    {
        "source_action_id": "XRT_SET_KERNEL_ARGS",
        "source_terms": ["set_arg", "kernel(", "run.set_arg", "group_id", "argument"],
        "target_action_id": "AXILITE_REGISTER_WRITES",
        "target_terms": ["qdma_reg_write", "AxiLiteBus", "s_axilite", "write"],
        "mapping_rule": "Map XRT kernel argument setup to ordered AXI-Lite register writes; exact offsets depend on HLS interface/register-map resolver.",
        "dependency": "GAP-HLS-INTERFACE-001",
    },
    {
        "source_action_id": "XRT_RUN_START",
        "source_terms": ["run.start", ".start(", "start"],
        "target_action_id": "AP_CTRL_START_BIT_WRITE",
        "target_terms": ["AP_CTRL", "start", "AxiLiteBus", "qdma_reg_write"],
        "mapping_rule": "Map XRT run.start to AP_CTRL start bit write on the target HLS IP AXI-Lite control interface.",
        "dependency": "GAP-HLS-INTERFACE-001",
    },
    {
        "source_action_id": "XRT_RUN_WAIT",
        "source_terms": ["run.wait", ".wait(", "wait"],
        "target_action_id": "AP_CTRL_DONE_IDLE_POLLING",
        "target_terms": ["AP_CTRL", "done", "idle", "wait_done", "wait_idle", "qdma_reg_read"],
        "mapping_rule": "Map XRT run.wait to AP_CTRL done/idle polling with timeout/error diagnostics.",
        "dependency": "none_for_pattern_extraction",
    },
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


def iter_leaf_strings(obj: Any, prefix: str = ""):
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = f"{prefix}.{k}" if prefix else str(k)
            yield from iter_leaf_strings(v, key)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            key = f"{prefix}[{i}]"
            yield from iter_leaf_strings(v, key)
    else:
        if obj is None:
            return
        yield prefix, str(obj)


def collect_term_evidence(obj: Any, terms: list[str], max_items: int = 20) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    lower_terms = [t.lower() for t in terms]
    for path, value in iter_leaf_strings(obj):
        low = value.lower()
        matched = [terms[i] for i, t in enumerate(lower_terms) if t in low]
        if matched:
            snippet = re.sub(r"\s+", " ", value).strip()
            out.append({
                "path": path,
                "matched_terms": sorted(set(matched)),
                "snippet": snippet[:700],
            })
            if len(out) >= max_items:
                break
    return out


def count_terms(obj: Any, terms: list[str]) -> dict[str, int]:
    counts = Counter({t: 0 for t in terms})
    lower_terms = [t.lower() for t in terms]
    for _, value in iter_leaf_strings(obj):
        low = value.lower()
        for original, term in zip(terms, lower_terms):
            counts[original] += low.count(term)
    return dict(counts)


def nested_get(obj: dict[str, Any], path: list[str], default=None):
    cur: Any = obj
    for item in path:
        if not isinstance(cur, dict) or item not in cur:
            return default
        cur = cur[item]
    return cur


def get_contract_blocking_gap_ids(contract: dict[str, Any]) -> list[str]:
    summary = contract.get("summary", {})
    for key in ["blocking_gap_ids", "blocking_gaps", "blocking_ids"]:
        val = summary.get(key)
        if isinstance(val, list):
            return list(val)

    ids: list[str] = []
    for g in contract.get("gaps", []):
        if isinstance(g, dict) and (g.get("blocks_migration") is True or g.get("severity") == "blocking"):
            gid = g.get("gap_id") or g.get("id")
            if gid:
                ids.append(gid)
    return ids


def source_host_profile(application_ir: dict[str, Any], pattern_pairing: dict[str, Any]) -> dict[str, Any]:
    all_terms = sorted(set(t for spec in XRT_HOST_ACTION_SPECS for t in spec["source_terms"]))
    counts = count_terms(application_ir, all_terms)
    evidence = collect_term_evidence(application_ir, all_terms, max_items=80)

    pairing_host = None
    for p in pattern_pairing.get("pairings", []):
        if isinstance(p, dict) and p.get("gap_id") == HOST_GAP_ID:
            pairing_host = p
            break

    return {
        "schema_version": "source_xrt_host_profile.v1",
        "source_terms": all_terms,
        "term_counts": counts,
        "total_hits": sum(counts.values()),
        "evidence": evidence,
        "pairing_state": pairing_host.get("pairing_state") if pairing_host else None,
        "pairing_score": pairing_host.get("scoring", {}).get("score") if pairing_host else None,
        "pairing_source_evidence": pairing_host.get("source_evidence", {}) if pairing_host else {},
    }


def target_host_profile(target_reference_ir: dict[str, Any]) -> dict[str, Any]:
    host = target_reference_ir.get("host_runtime_pattern", {})
    qdma = target_reference_ir.get("qdma_transfer_pattern", {})
    axilite = target_reference_ir.get("axi_lite_register_pattern", {})
    summary = target_reference_ir.get("summary", {})

    target_terms = sorted(set(t for spec in XRT_HOST_ACTION_SPECS for t in spec["target_terms"]))
    counts = count_terms(target_reference_ir, target_terms)
    evidence = collect_term_evidence(target_reference_ir, target_terms, max_items=100)

    return {
        "schema_version": "target_aved_host_profile.v1",
        "target_terms": target_terms,
        "term_counts": counts,
        "total_hits": sum(counts.values()),
        "summary_counts": {
            "qdma_evidence_count": summary.get("host_qdma_evidence_count", 0),
            "axi_lite_evidence_count": summary.get("host_axi_lite_evidence_count", 0),
            "ap_ctrl_evidence_count": summary.get("host_ap_ctrl_evidence_count", 0),
            "hbm_pc_addr_evidence_count": summary.get("hbm_pc_addr_evidence_count", 0),
            "hls_s_axilite_evidence_count": summary.get("hls_s_axilite_evidence_count", 0),
        },
        "host_runtime_evidence": {
            "qdma": host.get("evidence", {}).get("qdma", []),
            "axi_lite": host.get("evidence", {}).get("axi_lite", []),
            "ap_ctrl": host.get("evidence", {}).get("ap_ctrl", []),
            "hbm_pc_addr": host.get("evidence", {}).get("hbm_pc_addr", []),
            "device_node": host.get("evidence", {}).get("device_node", []),
            "verification": host.get("evidence", {}).get("verification", []),
        },
        "qdma_transfer_pattern": qdma,
        "axi_lite_register_pattern": axilite,
        "evidence": evidence,
    }


def action_has_evidence(profile: dict[str, Any], terms: list[str]) -> bool:
    counts = profile.get("term_counts", {})
    return any(counts.get(t, 0) > 0 for t in terms)


def build_action_mappings(source_profile: dict[str, Any], target_profile: dict[str, Any]) -> list[dict[str, Any]]:
    mappings: list[dict[str, Any]] = []
    for spec in XRT_HOST_ACTION_SPECS:
        source_has = action_has_evidence(source_profile, spec["source_terms"])
        target_has = action_has_evidence(target_profile, spec["target_terms"])

        state = (
            "mapped_with_source_and_target_evidence"
            if source_has and target_has else
            "mapped_with_target_evidence_source_sparse"
            if target_has else
            "mapped_but_needs_more_target_evidence"
        )

        mappings.append({
            "source_action_id": spec["source_action_id"],
            "target_action_id": spec["target_action_id"],
            "mapping_state": state,
            "mapping_rule": spec["mapping_rule"],
            "dependency": spec["dependency"],
            "source_terms": spec["source_terms"],
            "target_terms": spec["target_terms"],
            "source_evidence_count": sum(source_profile.get("term_counts", {}).get(t, 0) for t in spec["source_terms"]),
            "target_evidence_count": sum(target_profile.get("term_counts", {}).get(t, 0) for t in spec["target_terms"]),
            "source_evidence": collect_term_evidence(
                {"source_profile": source_profile.get("evidence", [])},
                spec["source_terms"],
                max_items=5,
            ),
            "target_evidence": collect_term_evidence(
                {"target_profile": target_profile.get("evidence", [])},
                spec["target_terms"],
                max_items=5,
            ),
            "trust_boundary": {
                "llm_used": False,
                "authoritative": False,
                "can_generate_code": False,
                "can_modify_contract": False,
                "requires_future_validation": True,
            },
        })
    return mappings


def build_unresolved_dependencies(action_mappings: list[dict[str, Any]]) -> list[dict[str, Any]]:
    deps: dict[str, set[str]] = {}
    for m in action_mappings:
        dep = m.get("dependency")
        if not dep or dep == "none_for_pattern_extraction":
            continue
        for piece in [x.strip() for x in dep.split("+")]:
            if piece.startswith("GAP-"):
                deps.setdefault(piece, set()).add(m["source_action_id"])

    return [
        {
            "gap_id": gid,
            "needed_by_source_actions": sorted(actions),
            "dependency_state": "required_before_host_gap_contract_resolution",
        }
        for gid, actions in sorted(deps.items())
    ]


def build_aved_host_runtime_pattern(
    application_ir: dict[str, Any],
    target_reference_ir: dict[str, Any],
    pattern_pairing: dict[str, Any],
    target_aware_plan: dict[str, Any],
    patched_contract: dict[str, Any],
    source_case_id: str = "hisparse_u280_profile",
    target_case_id: str = "spmv_on_v80",
) -> dict[str, Any]:
    src = source_host_profile(application_ir, pattern_pairing)
    tgt = target_host_profile(target_reference_ir)
    mappings = build_action_mappings(src, tgt)
    deps = build_unresolved_dependencies(mappings)

    contract_blockers = get_contract_blocking_gap_ids(patched_contract)
    host_plan = None
    for r in target_aware_plan.get("resolvers", []):
        if isinstance(r, dict) and r.get("gap_id") == HOST_GAP_ID:
            host_plan = r
            break

    mapped_with_both = sum(1 for m in mappings if m["mapping_state"] == "mapped_with_source_and_target_evidence")
    mapped_with_target = sum(1 for m in mappings if m["mapping_state"] == "mapped_with_target_evidence_source_sparse")
    needs_target = sum(1 for m in mappings if m["mapping_state"] == "mapped_but_needs_more_target_evidence")

    pattern_digest_material = {
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "gap_id": HOST_GAP_ID,
        "source_digest": json_digest(application_ir),
        "target_digest": target_reference_ir.get("facts_digest") or json_digest(target_reference_ir),
        "pattern_pairing_digest": pattern_pairing.get("pairing_digest"),
        "target_aware_plan_digest": target_aware_plan.get("plan_digest"),
        "mapping_states": {m["source_action_id"]: m["mapping_state"] for m in mappings},
        "contract_blockers": contract_blockers,
    }

    return {
        "schema_version": "aved_host_runtime_pattern.v1",
        "xporthls_version": "v0.0.27",
        "created_at_utc": utc_now(),
        "migration_direction": "XRT->AVED",
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "gap_id": HOST_GAP_ID,
        "resolver_name": "AVEDHostRuntimePatternResolver",
        "pattern_state": "host_runtime_pattern_extracted_not_resolved",
        "ready_for_contract_resolution": False,
        "source_ir_schema": application_ir.get("schema_version") or application_ir.get("schema"),
        "target_reference_schema": target_reference_ir.get("schema_version"),
        "pattern_pairing_schema": pattern_pairing.get("schema_version"),
        "target_aware_plan_schema": target_aware_plan.get("schema_version"),
        "contract_context": {
            "blocking_gap_ids": contract_blockers,
            "host_gap_still_blocking": HOST_GAP_ID in contract_blockers,
            "blocking_gap_count_after_v027": len(contract_blockers),
            "contract_mutation_allowed": False,
            "gaps_marked_resolved_by_v027": [],
        },
        "source_host_profile": src,
        "target_host_profile": tgt,
        "host_action_mappings": mappings,
        "unresolved_dependencies": deps,
        "target_aware_plan_ref": {
            "resolver_id": host_plan.get("resolver_id") if host_plan else None,
            "execution_readiness": host_plan.get("execution_readiness") if host_plan else None,
            "candidate_goal": host_plan.get("candidate_goal") if host_plan else None,
            "must_extract": host_plan.get("must_extract", []) if host_plan else [],
            "must_not_do": host_plan.get("must_not_do", []) if host_plan else [],
        },
        "next_steps": [
            {
                "next_version_candidate": "v0.0.28",
                "candidate": "HBMPCMemoryMappingResolver",
                "reason": "Host runtime pattern depends on target HBM/PC addresses for xrt::bo and QDMA transfer mapping.",
            },
            {
                "next_version_candidate": "v0.0.29",
                "candidate": "HLSInterfaceLoweringPatternResolver",
                "reason": "AXI-Lite register offset correctness depends on HLS interface/register-map normalization.",
            },
            {
                "next_version_candidate": "future",
                "candidate": "HostRuntimeContractPatchProposal",
                "reason": "Only after memory and HLS interface dependencies are validated can GAP-XRT-HOST-001 be proposed for contract patching.",
            },
        ],
        "trust_boundary": {
            "llm_used": False,
            "llm_annotations_allowed": False,
            "authoritative": False,
            "contract_modified": False,
            "migration_allowed_modified": False,
            "generator_unlocked": False,
            "can_resolve_gap": False,
            "can_generate_host_code": False,
            "pattern_only": True,
            "requires_future_memory_and_interface_validation": True,
        },
        "summary": {
            "host_action_mapping_count": len(mappings),
            "mapped_with_source_and_target_evidence_count": mapped_with_both,
            "mapped_with_target_evidence_source_sparse_count": mapped_with_target,
            "mapped_but_needs_more_target_evidence_count": needs_target,
            "source_xrt_host_total_hits": src.get("total_hits", 0),
            "target_host_total_hits": tgt.get("total_hits", 0),
            "target_qdma_evidence_count": tgt.get("summary_counts", {}).get("qdma_evidence_count", 0),
            "target_axi_lite_evidence_count": tgt.get("summary_counts", {}).get("axi_lite_evidence_count", 0),
            "target_ap_ctrl_evidence_count": tgt.get("summary_counts", {}).get("ap_ctrl_evidence_count", 0),
            "unresolved_dependency_count": len(deps),
            "host_gap_still_blocking": HOST_GAP_ID in contract_blockers,
            "gaps_marked_resolved_by_v027": 0,
            "contract_blocking_gap_count": len(contract_blockers),
            "llm_used": False,
            "contract_modified": False,
            "generator_unlock_allowed": False,
        },
        "pattern_digest": json_digest(pattern_digest_material),
        "llm_annotations": [],
    }


def build_aved_host_runtime_report(pattern: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "aved_host_runtime_pattern_report.v1",
        "xporthls_version": "v0.0.27",
        "created_at_utc": utc_now(),
        "migration_direction": pattern.get("migration_direction"),
        "source_case_id": pattern.get("source_case_id"),
        "target_case_id": pattern.get("target_case_id"),
        "gap_id": pattern.get("gap_id"),
        "resolver_name": pattern.get("resolver_name"),
        "pattern_state": pattern.get("pattern_state"),
        "ready_for_contract_resolution": pattern.get("ready_for_contract_resolution"),
        "summary": pattern.get("summary", {}),
        "action_mapping_overview": [
            {
                "source_action_id": m.get("source_action_id"),
                "target_action_id": m.get("target_action_id"),
                "mapping_state": m.get("mapping_state"),
                "dependency": m.get("dependency"),
                "source_evidence_count": m.get("source_evidence_count"),
                "target_evidence_count": m.get("target_evidence_count"),
            }
            for m in pattern.get("host_action_mappings", [])
        ],
        "unresolved_dependencies": pattern.get("unresolved_dependencies", []),
        "next_steps": pattern.get("next_steps", []),
        "trust_boundary": pattern.get("trust_boundary", {}),
        "llm_annotations": [],
    }
