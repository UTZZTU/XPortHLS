from __future__ import annotations

import hashlib
import json
import re
from collections import Counter
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

RESOLVED_BY_PRIOR_WORK = [
    "GAP-KERNEL-NAME-001",
]


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, obj: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def json_digest(obj: Any) -> str:
    return sha256_text(json.dumps(obj, sort_keys=True, ensure_ascii=False))


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


def count_terms(obj: Any, terms: list[str]) -> dict[str, int]:
    counter = Counter({t: 0 for t in terms})
    for _, value in iter_leaf_strings(obj):
        low = value.lower()
        for t in terms:
            counter[t] += low.count(t.lower())
    return dict(counter)


def collect_term_evidence(obj: Any, terms: list[str], max_items: int = 20) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for path, value in iter_leaf_strings(obj):
        low = value.lower()
        matched = [t for t in terms if t.lower() in low]
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


def get_contract_blocking_gap_ids(contract: dict[str, Any]) -> list[str]:
    # Support both explicit summary and gap-list shapes from earlier versions.
    summary = contract.get("summary", {})
    for key in ["blocking_gap_ids", "blocking_gaps", "blocking_ids"]:
        if isinstance(summary.get(key), list):
            return list(summary[key])

    gaps = contract.get("gaps", [])
    ids = []
    if isinstance(gaps, list):
        for g in gaps:
            if isinstance(g, dict):
                if g.get("blocks_migration") is True or g.get("severity") == "blocking":
                    gid = g.get("gap_id") or g.get("id")
                    if gid:
                        ids.append(gid)
    return ids


def get_contract_resolved_gap_ids(contract: dict[str, Any]) -> list[str]:
    summary = contract.get("summary", {})
    for key in ["resolved_gap_ids", "resolved_gaps", "resolved_ids"]:
        if isinstance(summary.get(key), list):
            return list(summary[key])

    gaps = contract.get("gaps", [])
    ids = []
    if isinstance(gaps, list):
        for g in gaps:
            if isinstance(g, dict):
                if g.get("resolution_state") or g.get("severity") == "resolved":
                    gid = g.get("gap_id") or g.get("id")
                    if gid:
                        ids.append(gid)
    return ids


def source_profile(app_ir: dict[str, Any]) -> dict[str, Any]:
    profiles = {
        "xrt_host": ["xrt", "xrt::", "xclbin", "xrt::device", "xrt::kernel", "xrt::bo", "run.start", "run.wait", "sync"],
        "platform": ["u280", "xilinx_u280", "platform", ".xpfm", "v++", "connectivity"],
        "memory": ["hbm", "ddr", "bank", "group_id", "memory", "m_axi", "bundle"],
        "stream": ["stream", "axis", "hls::stream", "stream_edges", "connectivity"],
        "placement": ["slr", "placement", "floorplan", "compute-unit", "cu"],
        "hls_interface": ["pragma", "interface", "m_axi", "s_axilite", "axis", "ap_ctrl", "dataflow"],
        "kernel_name": ["kernel", "configured", "declared", "function"],
    }

    out: dict[str, Any] = {}
    for name, terms in profiles.items():
        counts = count_terms(app_ir, terms)
        out[name] = {
            "terms": terms,
            "term_counts": counts,
            "total_hits": sum(counts.values()),
            "evidence": collect_term_evidence(app_ir, terms, max_items=20),
        }
    return out


def target_profile(target_ir: dict[str, Any]) -> dict[str, Any]:
    summary = target_ir.get("summary", {})
    bd_commands = target_ir.get("bd_tcl_pattern", {}).get("command_counts", {})
    hls_summary = target_ir.get("hls_ip_packaging_pattern", {}).get("summary", {})
    host_summary = target_ir.get("host_runtime_pattern", {}).get("summary", {})
    mem_summary = target_ir.get("hbm_pc_address_map", {}).get("summary", {})
    stream_summary = target_ir.get("stream_connection_pattern", {}).get("summary", {})
    vivado_summary = target_ir.get("vivado_aved_project_pattern", {})

    placement_terms = ["slr", "xdc", "pblock", "place_design", "phys_opt", "timing", "wns", "floorplan"]
    placement_counts = count_terms(target_ir, placement_terms)

    return {
        "host_runtime": {
            "qdma_evidence_count": host_summary.get("qdma_evidence_count", 0),
            "axi_lite_evidence_count": host_summary.get("axi_lite_evidence_count", 0),
            "ap_ctrl_evidence_count": host_summary.get("ap_ctrl_evidence_count", 0),
            "device_node_evidence_count": host_summary.get("device_node_evidence_count", 0),
            "evidence_paths": {
                "qdma": "target_ir.host_runtime_pattern.evidence.qdma",
                "axi_lite": "target_ir.host_runtime_pattern.evidence.axi_lite",
                "ap_ctrl": "target_ir.host_runtime_pattern.evidence.ap_ctrl",
            },
        },
        "platform": {
            "create_design_tcl_count": summary.get("create_design_tcl_count", 0),
            "create_bd_design_tcl_count": summary.get("create_bd_design_tcl_count", 0),
            "tcl_evidence_count": len(vivado_summary.get("tcl_evidence", [])),
            "evidence_paths": {
                "create_design": "target_ir.vivado_aved_project_pattern.create_design_files",
                "create_bd_design": "target_ir.vivado_aved_project_pattern.create_bd_design_files",
                "tcl_evidence": "target_ir.vivado_aved_project_pattern.tcl_evidence",
            },
        },
        "memory": {
            "hbm_pc_addr_evidence_count": mem_summary.get("hbm_pc_addr_evidence_count", 0),
            "hbm_base_evidence_count": mem_summary.get("hbm_base_evidence_count", 0),
            "hbm_stride_evidence_count": mem_summary.get("hbm_stride_evidence_count", 0),
            "pc_stride_evidence_count": mem_summary.get("pc_stride_evidence_count", 0),
            "slot_bytes_evidence_count": mem_summary.get("slot_bytes_evidence_count", 0),
            "bd_assign_bd_address_count": bd_commands.get("assign_bd_address", 0),
            "evidence_paths": {
                "hbm_pc": "target_ir.hbm_pc_address_map.evidence",
                "assign_bd_address": "target_ir.bd_tcl_pattern.connection_and_address_records",
            },
        },
        "stream": {
            "axis_term_count": stream_summary.get("axis_term_count", 0),
            "hls_stream_count": stream_summary.get("hls_stream_count", 0),
            "connect_bd_intf_net_count": bd_commands.get("connect_bd_intf_net", 0),
            "axis_duplicate_count": stream_summary.get("axis_duplicate_count", 0),
            "axis_merge_count": stream_summary.get("axis_merge_count", 0),
            "evidence_paths": {
                "stream_connection": "target_ir.stream_connection_pattern.evidence",
                "bd_connections": "target_ir.bd_tcl_pattern.connection_and_address_records",
            },
        },
        "placement": {
            "placement_term_counts": placement_counts,
            "total_placement_hits": sum(placement_counts.values()),
            "evidence": collect_term_evidence(target_ir, placement_terms, max_items=20),
            "evidence_paths": {
                "placement_terms": "recursive target_ir search for slr/xdc/pblock/place/timing terms",
            },
        },
        "hls_interface": {
            "m_axi_evidence_count": hls_summary.get("m_axi_evidence_count", 0),
            "axis_evidence_count": hls_summary.get("axis_evidence_count", 0),
            "s_axilite_evidence_count": hls_summary.get("s_axilite_evidence_count", 0),
            "ap_ctrl_evidence_count": hls_summary.get("ap_ctrl_evidence_count", 0),
            "dataflow_evidence_count": hls_summary.get("dataflow_evidence_count", 0),
            "packed_word_evidence_count": hls_summary.get("packed_word_evidence_count", 0),
            "packaging_evidence_count": hls_summary.get("packaging_evidence_count", 0),
            "evidence_paths": {
                "interface": "target_ir.hls_ip_packaging_pattern.interface_evidence",
                "packaging": "target_ir.hls_ip_packaging_pattern.packaging_evidence",
            },
        },
        "manual_operations": target_ir.get("manual_operation_trace", {}).get("operations", []),
        "known_correctness_fixes": target_ir.get("known_correctness_fixes", {}),
    }


def target_manual_ops_for_gap(target_ir: dict[str, Any], gap_id: str) -> list[dict[str, Any]]:
    ops = target_ir.get("manual_operation_trace", {}).get("operations", [])
    return [op for op in ops if op.get("migration_relevance") == gap_id]


def target_fix_evidence_for_gap(target_ir: dict[str, Any], gap_id: str) -> list[dict[str, Any]]:
    fixes = target_ir.get("known_correctness_fixes", {}).get("classified_fixes", [])
    matched: list[dict[str, Any]] = []
    for fix in fixes:
        rel = fix.get("migration_relevance", [])
        if gap_id in rel:
            matched.append(fix)
    return matched


def pairing_state(score: int, gap_id: str) -> str:
    if gap_id == "GAP-PLACEMENT-SLR-001":
        # Placement is intentionally conservative. Even if timing/placement words exist,
        # v0.0.25 cannot claim enough target placement contract evidence.
        return "partial_target_reference_evidence"
    if score >= 3:
        return "paired_with_target_reference_evidence"
    if score >= 1:
        return "partial_target_reference_evidence"
    return "unpaired_needs_more_evidence"


def build_pairing(
    gap_id: str,
    source_kind: str,
    target_kind: str,
    source: dict[str, Any],
    target: dict[str, Any],
    target_ir: dict[str, Any],
    proposed_mapping: dict[str, Any],
) -> dict[str, Any]:
    src = source.get(source_kind, {})
    tgt = target.get(target_kind, {})
    score = 0
    scoring_reasons: list[str] = []

    if src.get("total_hits", 0) > 0:
        score += 1
        scoring_reasons.append("source evidence present")

    if gap_id == "GAP-XRT-HOST-001":
        if tgt.get("qdma_evidence_count", 0) > 0:
            score += 1
            scoring_reasons.append("target QDMA evidence present")
        if tgt.get("axi_lite_evidence_count", 0) > 0 and tgt.get("ap_ctrl_evidence_count", 0) > 0:
            score += 1
            scoring_reasons.append("target AXI-Lite/AP_CTRL evidence present")

    elif gap_id == "GAP-PLATFORM-001":
        if tgt.get("create_design_tcl_count", 0) > 0:
            score += 1
            scoring_reasons.append("target create_design.tcl evidence present")
        if tgt.get("create_bd_design_tcl_count", 0) > 0:
            score += 1
            scoring_reasons.append("target create_bd_design.tcl evidence present")

    elif gap_id == "GAP-MEM-HBM-001":
        if tgt.get("hbm_pc_addr_evidence_count", 0) > 0 or tgt.get("hbm_base_evidence_count", 0) > 0:
            score += 1
            scoring_reasons.append("target HBM/PC address evidence present")
        if tgt.get("bd_assign_bd_address_count", 0) > 0:
            score += 1
            scoring_reasons.append("target BD address assignment evidence present")

    elif gap_id == "GAP-STREAM-AXIS-001":
        if tgt.get("axis_term_count", 0) > 0 or tgt.get("hls_stream_count", 0) > 0:
            score += 1
            scoring_reasons.append("target AXIS/HLS stream evidence present")
        if tgt.get("connect_bd_intf_net_count", 0) > 0:
            score += 1
            scoring_reasons.append("target BD interface connection evidence present")

    elif gap_id == "GAP-PLACEMENT-SLR-001":
        if tgt.get("total_placement_hits", 0) > 0:
            score += 1
            scoring_reasons.append("target placement/timing terms present")
        scoring_reasons.append("placement remains partial because target placement constraints are not yet normalized")

    elif gap_id == "GAP-HLS-INTERFACE-001":
        if tgt.get("m_axi_evidence_count", 0) > 0 or tgt.get("axis_evidence_count", 0) > 0 or tgt.get("s_axilite_evidence_count", 0) > 0:
            score += 1
            scoring_reasons.append("target HLS interface evidence present")
        if tgt.get("packaging_evidence_count", 0) > 0:
            score += 1
            scoring_reasons.append("target HLS IP packaging evidence present")

    manual_ops = target_manual_ops_for_gap(target_ir, gap_id)
    if manual_ops:
        score += 1
        scoring_reasons.append("manual operation trace references this gap")

    fixes = target_fix_evidence_for_gap(target_ir, gap_id)
    if fixes:
        score += 1
        scoring_reasons.append("known correctness fix evidence references this gap")

    state = pairing_state(score, gap_id)

    return {
        "pair_id": f"PAIR-{gap_id.replace('GAP-', '').replace('-001', '')}-V025",
        "gap_id": gap_id,
        "pairing_state": state,
        "resolution_state": "candidate_pattern_only_not_resolved",
        "source_kind": source_kind,
        "target_kind": target_kind,
        "source_evidence": {
            "term_hits": src.get("total_hits", 0),
            "term_counts": src.get("term_counts", {}),
            "sample_evidence": src.get("evidence", [])[:10],
        },
        "target_evidence": tgt,
        "manual_operation_trace": manual_ops,
        "known_correctness_fixes": fixes,
        "proposed_source_to_target_mapping": proposed_mapping,
        "scoring": {
            "score": score,
            "reasons": scoring_reasons,
        },
        "trust_boundary": {
            "llm_used": False,
            "authoritative": False,
            "can_modify_contract": False,
            "can_unlock_generator": False,
            "requires_future_resolver": True,
            "requires_validation_before_gap_resolution": True,
        },
    }


def build_source_target_pattern_pairing(
    application_ir: dict[str, Any],
    target_reference_ir: dict[str, Any],
    patched_contract: dict[str, Any] | None = None,
    resolver_plan: dict[str, Any] | None = None,
    source_case_id: str = "hisparse_u280_profile",
    target_case_id: str = "spmv_on_v80",
) -> dict[str, Any]:
    src = source_profile(application_ir)
    tgt = target_profile(target_reference_ir)

    mappings = {
        "GAP-XRT-HOST-001": {
            "source_concepts": ["xrt::device", "xrt::kernel", "xrt::bo", "run.start", "run.wait", "xclbin"],
            "target_concepts": ["QDMA transfer", "AXI-Lite register control", "AP_CTRL start/done/idle polling", "host verification"],
            "candidate_rule": "Expand XRT host runtime abstractions into explicit AVED/V80 QDMA transfer plus AXI-Lite/AP_CTRL control sequence.",
            "next_resolver": "AVEDHostRuntimePatternResolver",
        },
        "GAP-PLATFORM-001": {
            "source_concepts": ["U280 platform", "source v++/connectivity build metadata", "xclbin/platform shell"],
            "target_concepts": ["AVED Vivado project template", "create_design.tcl", "create_bd_design.tcl", "PDI-oriented flow"],
            "candidate_rule": "Map source platform/build intent to AVED/V80 Vivado project and BD/Tcl construction flow.",
            "next_resolver": "AVEDPlatformProjectPatternResolver",
        },
        "GAP-MEM-HBM-001": {
            "source_concepts": ["U280 HBM banks", "group_id", "m_axi bundles", "memory mappings"],
            "target_concepts": ["V80 HBM/PC address map", "QDMA target addresses", "assign_bd_address", "slot/offset mapping"],
            "candidate_rule": "Map source HBM bank/bundle/group intent to target HBM pseudo-channel address and BD address assignment evidence.",
            "next_resolver": "HBMPCMemoryMappingResolver",
        },
        "GAP-STREAM-AXIS-001": {
            "source_concepts": ["connectivity stream edges", "HLS axis ports", "hls::stream"],
            "target_concepts": ["Vivado BD connect_bd_intf_net", "AXIS interface pins", "axis_duplicate/axis_merge where present"],
            "candidate_rule": "Map source stream edges and axis interfaces to target BD interface connection operations.",
            "next_resolver": "AVEDStreamGraphResolver",
        },
        "GAP-PLACEMENT-SLR-001": {
            "source_concepts": ["U280 SLR assignments", "placement directives", "compute unit placement"],
            "target_concepts": ["V80/Vivado placement/timing evidence", "future xdc/pblock/timing normalized evidence"],
            "candidate_rule": "Keep placement as partial until target placement constraints and reports are normalized.",
            "next_resolver": "PlacementEvidenceNormalizer",
        },
        "GAP-HLS-INTERFACE-001": {
            "source_concepts": ["m_axi", "axis", "s_axilite", "ap_ctrl", "dataflow", "kernel interface pragmas"],
            "target_concepts": ["HLS IP packaging", "packed ap_uint external memory words", "AXIS interfaces", "s_axilite/AP_CTRL"],
            "candidate_rule": "Map source HLS interface contracts to target Vivado-packaged HLS IP interface patterns.",
            "next_resolver": "HLSInterfaceLoweringPatternResolver",
        },
    }

    pairings = [
        build_pairing(
            "GAP-XRT-HOST-001", "xrt_host", "host_runtime", src, tgt, target_reference_ir, mappings["GAP-XRT-HOST-001"]
        ),
        build_pairing(
            "GAP-PLATFORM-001", "platform", "platform", src, tgt, target_reference_ir, mappings["GAP-PLATFORM-001"]
        ),
        build_pairing(
            "GAP-MEM-HBM-001", "memory", "memory", src, tgt, target_reference_ir, mappings["GAP-MEM-HBM-001"]
        ),
        build_pairing(
            "GAP-STREAM-AXIS-001", "stream", "stream", src, tgt, target_reference_ir, mappings["GAP-STREAM-AXIS-001"]
        ),
        build_pairing(
            "GAP-PLACEMENT-SLR-001", "placement", "placement", src, tgt, target_reference_ir, mappings["GAP-PLACEMENT-SLR-001"]
        ),
        build_pairing(
            "GAP-HLS-INTERFACE-001", "hls_interface", "hls_interface", src, tgt, target_reference_ir, mappings["GAP-HLS-INTERFACE-001"]
        ),
    ]

    contract_blocking = get_contract_blocking_gap_ids(patched_contract) if patched_contract else list(REMAINING_BLOCKING_GAPS_V022)
    contract_resolved = get_contract_resolved_gap_ids(patched_contract) if patched_contract else list(RESOLVED_BY_PRIOR_WORK)

    coverage = {
        "expected_remaining_blocking_gaps": list(REMAINING_BLOCKING_GAPS_V022),
        "contract_blocking_gap_ids": contract_blocking,
        "contract_resolved_gap_ids": contract_resolved,
        "paired_gap_ids": [p["gap_id"] for p in pairings],
        "paired_with_target_reference_evidence": [
            p["gap_id"] for p in pairings if p["pairing_state"] == "paired_with_target_reference_evidence"
        ],
        "partial_target_reference_evidence": [
            p["gap_id"] for p in pairings if p["pairing_state"] == "partial_target_reference_evidence"
        ],
        "unpaired_needs_more_evidence": [
            p["gap_id"] for p in pairings if p["pairing_state"] == "unpaired_needs_more_evidence"
        ],
        "resolved_by_prior_work": list(RESOLVED_BY_PRIOR_WORK),
        "gaps_marked_resolved_by_v025": [],
    }

    pairing_digest_material = {
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "source_digest": json_digest(application_ir),
        "target_digest": target_reference_ir.get("facts_digest") or json_digest(target_reference_ir.get("summary", {})),
        "contract_blocking": contract_blocking,
        "pairing_states": {p["gap_id"]: p["pairing_state"] for p in pairings},
        "pairing_scores": {p["gap_id"]: p["scoring"]["score"] for p in pairings},
    }

    out = {
        "schema_version": "source_target_pattern_pairing.v1",
        "xporthls_version": "v0.0.25",
        "created_at_utc": utc_now(),
        "migration_direction": "XRT->AVED",
        "source_case_id": source_case_id,
        "target_case_id": target_case_id,
        "source_ir_schema": application_ir.get("schema_version") or application_ir.get("schema"),
        "target_reference_schema": target_reference_ir.get("schema_version"),
        "input_artifact_digests": {
            "application_ir_digest": json_digest(application_ir),
            "target_reference_ir_digest": json_digest(target_reference_ir),
            "patched_contract_digest": json_digest(patched_contract) if patched_contract else None,
            "resolver_plan_digest": json_digest(resolver_plan) if resolver_plan else None,
        },
        "source_profile": src,
        "target_profile": tgt,
        "pairings": pairings,
        "coverage": coverage,
        "next_resolver_candidates": [
            {
                "gap_id": p["gap_id"],
                "next_resolver": p["proposed_source_to_target_mapping"]["next_resolver"],
                "pairing_state": p["pairing_state"],
                "ready_for_resolver_planning": p["pairing_state"] in {
                    "paired_with_target_reference_evidence",
                    "partial_target_reference_evidence",
                },
                "ready_for_contract_resolution": False,
            }
            for p in pairings
        ],
        "trust_boundary": {
            "llm_used": False,
            "llm_annotations_allowed": False,
            "authoritative": False,
            "contract_modified": False,
            "migration_allowed_modified": False,
            "generator_unlocked": False,
            "can_resolve_gap": False,
            "can_unlock_generator": False,
            "candidate_patterns_only": True,
            "requires_future_resolver_and_validation": True,
        },
        "summary": {
            "num_pairings": len(pairings),
            "expected_blocking_gap_count": len(REMAINING_BLOCKING_GAPS_V022),
            "contract_blocking_gap_count": len(contract_blocking),
            "paired_gap_count": len([p for p in pairings if p["pairing_state"] == "paired_with_target_reference_evidence"]),
            "partial_gap_count": len([p for p in pairings if p["pairing_state"] == "partial_target_reference_evidence"]),
            "unpaired_gap_count": len([p for p in pairings if p["pairing_state"] == "unpaired_needs_more_evidence"]),
            "gaps_marked_resolved_by_v025": 0,
            "llm_used": False,
            "contract_modified": False,
            "generator_unlock_allowed": False,
        },
        "pairing_digest": json_digest(pairing_digest_material),
        "llm_annotations": [],
    }

    return out


def build_pairing_report(pairing: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema_version": "source_target_pattern_pairing_report.v1",
        "xporthls_version": "v0.0.25",
        "created_at_utc": utc_now(),
        "migration_direction": pairing.get("migration_direction"),
        "source_case_id": pairing.get("source_case_id"),
        "target_case_id": pairing.get("target_case_id"),
        "summary": pairing.get("summary", {}),
        "coverage": pairing.get("coverage", {}),
        "pairing_overview": [
            {
                "gap_id": p["gap_id"],
                "pairing_state": p["pairing_state"],
                "score": p["scoring"]["score"],
                "candidate_rule": p["proposed_source_to_target_mapping"]["candidate_rule"],
                "next_resolver": p["proposed_source_to_target_mapping"]["next_resolver"],
                "manual_operation_count": len(p.get("manual_operation_trace", [])),
                "correctness_fix_count": len(p.get("known_correctness_fixes", [])),
            }
            for p in pairing.get("pairings", [])
        ],
        "trust_boundary": pairing.get("trust_boundary", {}),
        "llm_annotations": [],
    }
