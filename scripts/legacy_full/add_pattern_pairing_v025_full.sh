#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Add Source-Target Pattern Pairing v0.0.25 modules"

mkdir -p xporthls/targetref
touch xporthls/targetref/__init__.py

cat > xporthls/targetref/pattern_pairing_v025.py <<'EOT'
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
EOT

cat > xporthls/targetref/validate_pattern_pairing_v025.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from xporthls.targetref.pattern_pairing_v025 import (
    REMAINING_BLOCKING_GAPS_V022,
    RESOLVED_BY_PRIOR_WORK,
)


@dataclass
class PatternPairingIssue:
    severity: str
    code: str
    message: str


@dataclass
class PatternPairingValidationReport:
    schema_version: str = "source_target_pattern_pairing_validation_report.v1"
    xporthls_version: str = "v0.0.25"
    status: str = "fail"
    issues: list[PatternPairingIssue] = field(default_factory=list)
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


def add_issue(issues: list[PatternPairingIssue], severity: str, code: str, message: str) -> None:
    issues.append(PatternPairingIssue(severity=severity, code=code, message=message))


def validate_pattern_pairing(pairing: dict[str, Any], guard_report: dict[str, Any] | None = None) -> PatternPairingValidationReport:
    issues: list[PatternPairingIssue] = []

    if pairing.get("schema_version") != "source_target_pattern_pairing.v1":
        add_issue(issues, "error", "SCHEMA", "Expected source_target_pattern_pairing.v1.")

    if pairing.get("xporthls_version") != "v0.0.25":
        add_issue(issues, "error", "VERSION", "Expected xporthls_version v0.0.25.")

    if pairing.get("migration_direction") != "XRT->AVED":
        add_issue(issues, "error", "MIGRATION_DIRECTION", "Expected migration_direction XRT->AVED.")

    if pairing.get("target_reference_schema") != "target_reference_ir.v1":
        add_issue(issues, "error", "TARGET_REFERENCE_SCHEMA", "Expected target_reference_ir.v1 input.")

    if pairing.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS", "v0.0.25 must not contain LLM annotations.")

    tb = pairing.get("trust_boundary", {})
    required_false = [
        "llm_used",
        "contract_modified",
        "migration_allowed_modified",
        "generator_unlocked",
        "can_resolve_gap",
        "can_unlock_generator",
    ]
    for key in required_false:
        if tb.get(key) is not False:
            add_issue(issues, "error", "TRUST_BOUNDARY", f"Trust boundary flag must be false: {key}")

    if tb.get("candidate_patterns_only") is not True:
        add_issue(issues, "error", "CANDIDATE_ONLY", "v0.0.25 must be candidate-pattern-only.")

    if tb.get("requires_future_resolver_and_validation") is not True:
        add_issue(issues, "error", "REQUIRES_FUTURE_VALIDATION", "v0.0.25 pairings must require future resolver and validation.")

    pairings = pairing.get("pairings", [])
    if len(pairings) != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "PAIRING_COUNT", "Expected one pairing per remaining blocking gap.")

    gap_ids = [p.get("gap_id") for p in pairings]
    if sorted(gap_ids) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "PAIRING_GAP_SET", f"Pairing gap set must equal remaining blocking gaps: {REMAINING_BLOCKING_GAPS_V022}")

    for resolved in RESOLVED_BY_PRIOR_WORK:
        if resolved in gap_ids:
            add_issue(issues, "error", "RESOLVED_GAP_REPAIRED", f"Resolved prior gap should not be paired as remaining blocker: {resolved}")

    allowed_states = {
        "paired_with_target_reference_evidence",
        "partial_target_reference_evidence",
        "unpaired_needs_more_evidence",
    }
    for p in pairings:
        gid = p.get("gap_id")
        if p.get("pairing_state") not in allowed_states:
            add_issue(issues, "error", "BAD_PAIRING_STATE", f"Bad pairing_state for {gid}: {p.get('pairing_state')}")
        if p.get("resolution_state") != "candidate_pattern_only_not_resolved":
            add_issue(issues, "error", "BAD_RESOLUTION_STATE", f"v0.0.25 must not resolve gaps: {gid}")
        ptb = p.get("trust_boundary", {})
        if ptb.get("llm_used") is not False:
            add_issue(issues, "error", "PAIRING_LLM_USED", f"Pairing must not use LLM: {gid}")
        if ptb.get("can_modify_contract") is not False:
            add_issue(issues, "error", "PAIRING_CONTRACT_MODIFY", f"Pairing must not modify contract: {gid}")
        if ptb.get("can_unlock_generator") is not False:
            add_issue(issues, "error", "PAIRING_GENERATOR_UNLOCK", f"Pairing must not unlock generator: {gid}")
        if ptb.get("requires_future_resolver") is not True:
            add_issue(issues, "error", "PAIRING_REQUIRES_RESOLVER", f"Pairing must require future resolver: {gid}")
        if p.get("scoring", {}).get("score", 0) <= 0:
            add_issue(issues, "warning", "LOW_PAIRING_SCORE", f"Pairing has no evidence score: {gid}")

    coverage = pairing.get("coverage", {})
    if sorted(coverage.get("expected_remaining_blocking_gaps", [])) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "COVERAGE_EXPECTED", "Coverage expected remaining blockers mismatch.")

    if sorted(coverage.get("paired_gap_ids", [])) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "COVERAGE_PAIRED", "Coverage paired gap ids mismatch.")

    if coverage.get("gaps_marked_resolved_by_v025") not in ([], None):
        add_issue(issues, "error", "GAPS_RESOLVED", "v0.0.25 must not mark gaps resolved.")

    summary = pairing.get("summary", {})
    if summary.get("gaps_marked_resolved_by_v025") != 0:
        add_issue(issues, "error", "SUMMARY_RESOLVED_COUNT", "v0.0.25 must mark zero gaps resolved.")
    if summary.get("llm_used") is not False:
        add_issue(issues, "error", "SUMMARY_LLM_USED", "summary.llm_used must be false.")
    if summary.get("contract_modified") is not False:
        add_issue(issues, "error", "SUMMARY_CONTRACT_MODIFIED", "summary.contract_modified must be false.")
    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "SUMMARY_GENERATOR_UNLOCK", "summary.generator_unlock_allowed must be false.")

    # Strong expected evidence checks from v0.0.24 target reference.
    target_profile = pairing.get("target_profile", {})
    host = target_profile.get("host_runtime", {})
    if host.get("qdma_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_QDMA_EVIDENCE", "Expected QDMA evidence from TargetReferenceIR.")
    if host.get("axi_lite_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_AXI_LITE_EVIDENCE", "Expected AXI-Lite evidence from TargetReferenceIR.")
    if host.get("ap_ctrl_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_AP_CTRL_EVIDENCE", "Expected AP_CTRL evidence from TargetReferenceIR.")

    platform = target_profile.get("platform", {})
    if platform.get("create_design_tcl_count", 0) <= 0:
        add_issue(issues, "error", "NO_CREATE_DESIGN_TCL", "Expected create_design.tcl evidence.")
    if platform.get("create_bd_design_tcl_count", 0) <= 0:
        add_issue(issues, "error", "NO_CREATE_BD_DESIGN_TCL", "Expected create_bd_design.tcl evidence.")

    memory = target_profile.get("memory", {})
    if memory.get("bd_assign_bd_address_count", 0) <= 0:
        add_issue(issues, "error", "NO_BD_ADDRESS", "Expected assign_bd_address evidence.")

    stream = target_profile.get("stream", {})
    if stream.get("connect_bd_intf_net_count", 0) <= 0:
        add_issue(issues, "error", "NO_BD_STREAM_CONNECTION", "Expected connect_bd_intf_net evidence.")

    hls = target_profile.get("hls_interface", {})
    if hls.get("axis_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_HLS_AXIS_EVIDENCE", "Expected HLS axis evidence.")
    if hls.get("packaging_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_HLS_PACKAGING_EVIDENCE", "Expected HLS packaging evidence.")

    # Placement should remain partial in v0.0.25.
    placement_pairings = [p for p in pairings if p.get("gap_id") == "GAP-PLACEMENT-SLR-001"]
    if placement_pairings:
        if placement_pairings[0].get("pairing_state") != "partial_target_reference_evidence":
            add_issue(issues, "error", "PLACEMENT_NOT_PARTIAL", "Placement must remain partial in v0.0.25.")

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

    return PatternPairingValidationReport(
        status=status,
        issues=issues,
        summary={
            "pairing_schema": pairing.get("schema_version"),
            "migration_direction": pairing.get("migration_direction"),
            "source_case_id": pairing.get("source_case_id"),
            "target_case_id": pairing.get("target_case_id"),
            "num_pairings": len(pairings),
            "paired_gap_count": summary.get("paired_gap_count"),
            "partial_gap_count": summary.get("partial_gap_count"),
            "unpaired_gap_count": summary.get("unpaired_gap_count"),
            "gaps_marked_resolved_by_v025": summary.get("gaps_marked_resolved_by_v025"),
            "llm_used": summary.get("llm_used"),
            "contract_modified": summary.get("contract_modified"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "guard_blocked": guard_report.get("decision", {}).get("blocked") if guard_report else None,
            "guard_allowed": guard_report.get("decision", {}).get("allowed") if guard_report else None,
            "num_errors": sum(1 for i in issues if i.severity == "error"),
            "num_warnings": sum(1 for i in issues if i.severity == "warning"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate source-target pattern pairing v0.0.25")
    parser.add_argument("--pairing", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    pairing = load_json(args.pairing)
    guard = load_json(args.guard_report) if args.guard_report else None

    report = validate_pattern_pairing(pairing, guard)
    report.save(args.out)

    print(f"[xporthls] Pattern pairing validation: {args.out}")
    print(f"[xporthls] Validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

cat > xporthls/targetref/run_pattern_pairing_v025.py <<'EOT'
from __future__ import annotations

import argparse
import json
from pathlib import Path

from xporthls.targetref.pattern_pairing_v025 import (
    build_pairing_report,
    build_source_target_pattern_pairing,
    load_json,
    save_json,
)
from xporthls.targetref.validate_pattern_pairing_v025 import validate_pattern_pairing


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.25 source-target pattern pairing")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--patched-contract", default=None)
    parser.add_argument("--resolver-plan", default=None)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--source-case-id", default="hisparse_u280_profile")
    parser.add_argument("--target-case-id", default="spmv_on_v80")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    application_ir = load_json(args.application_ir)
    target_reference_ir = load_json(args.target_reference_ir)
    patched_contract = load_json(args.patched_contract) if args.patched_contract else None
    resolver_plan = load_json(args.resolver_plan) if args.resolver_plan else None
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    pairing_path = out_dir / f"{prefix}_pattern_pairing_v025.json"
    report_path = out_dir / f"{prefix}_pattern_pairing_report_v025.json"
    validation_path = out_dir / f"{prefix}_pattern_pairing_validation_v025.json"

    pairing = build_source_target_pattern_pairing(
        application_ir=application_ir,
        target_reference_ir=target_reference_ir,
        patched_contract=patched_contract,
        resolver_plan=resolver_plan,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(pairing_path, pairing)

    report = build_pairing_report(pairing)
    save_json(report_path, report)

    validation = validate_pattern_pairing(pairing, guard)
    validation.save(validation_path)

    s = pairing["summary"]
    cov = pairing["coverage"]

    print(f"[xporthls] Pattern pairing: {pairing_path}")
    print(f"[xporthls] Pattern pairing report: {report_path}")
    print(f"[xporthls] Pattern pairing validation: {validation_path}")
    print(f"[xporthls] Schema: {pairing['schema_version']}")
    print(f"[xporthls] Migration direction: {pairing['migration_direction']}")
    print(f"[xporthls] Source case: {pairing['source_case_id']}")
    print(f"[xporthls] Target case: {pairing['target_case_id']}")
    print(f"[xporthls] Pairings: {s['num_pairings']}")
    print(f"[xporthls] Paired gaps: {s['paired_gap_count']}")
    print(f"[xporthls] Partial gaps: {s['partial_gap_count']}")
    print(f"[xporthls] Unpaired gaps: {s['unpaired_gap_count']}")
    print(f"[xporthls] Expected blockers: {cov['expected_remaining_blocking_gaps']}")
    print(f"[xporthls] Paired gap IDs: {cov['paired_gap_ids']}")
    print(f"[xporthls] Paired with target evidence: {cov['paired_with_target_reference_evidence']}")
    print(f"[xporthls] Partial target evidence: {cov['partial_target_reference_evidence']}")
    print(f"[xporthls] Unpaired needing evidence: {cov['unpaired_needs_more_evidence']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.25: {s['gaps_marked_resolved_by_v025']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Update README with v0.0.25 implementation note if needed"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
if not p.exists():
    p.write_text("# XPortHLS\n", encoding="utf-8")

text = p.read_text(encoding="utf-8")
section = """
## Source-Target Pattern Pairing v0.0.25

v0.0.25 adds deterministic source-target migration pattern pairing between the source-side HiSparse `ApplicationIR v2` and the target-side SPMV-on-V80 `TargetReferenceIR v1`.

This version produces candidate migration patterns for the six remaining post-v0.0.22 blocking gaps:

```text
GAP-XRT-HOST-001
GAP-PLATFORM-001
GAP-MEM-HBM-001
GAP-STREAM-AXIS-001
GAP-PLACEMENT-SLR-001
GAP-HLS-INTERFACE-001
```

It does not mark any gap as resolved. It does not modify the contract, does not unlock generation, and does not call an LLM.

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json
```
"""

if "## Source-Target Pattern Pairing v0.0.25" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"
    p.write_text(text, encoding="utf-8")
PY

echo "[3/7] Create v0.0.25 replay script"

cat > add_pattern_pairing_v025_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
RESOLVER_PLAN="${RESOLVER_PLAN:-experiments/runs/hisparse_u280_profile_gap_resolver_plan_v018.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_pattern_pairing_v025.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v025}"

PAIRING="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json"
PAIRING_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json"
PAIRING_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json"

echo "[v0.0.25] Python syntax check"

python3 -m py_compile \
  xporthls/targetref/pattern_pairing_v025.py \
  xporthls/targetref/validate_pattern_pairing_v025.py \
  xporthls/targetref/run_pattern_pairing_v025.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.25] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATCHED_CONTRACT"; do
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
  exit 3
fi

if [ -f "$RESOLVER_PLAN" ]; then
  RESOLVER_PLAN_ARG=(--resolver-plan "$RESOLVER_PLAN")
  echo "[xporthls] Found resolver plan: $RESOLVER_PLAN"
else
  RESOLVER_PLAN_ARG=()
  echo "[xporthls] WARNING: resolver plan not found, continuing without it: $RESOLVER_PLAN"
fi

echo "[v0.0.25] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.25] Run source-target pattern pairing"

python3 -m xporthls.targetref.run_pattern_pairing_v025 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --patched-contract "$PATCHED_CONTRACT" \
  "${RESOLVER_PLAN_ARG[@]}" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json
from pathlib import Path

pairing = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_pattern_pairing_v025.json", encoding="utf-8"))

s = pairing["summary"]
cov = pairing["coverage"]

print()
print("PatternPairing schema:", pairing["schema_version"])
print("Migration direction:", pairing["migration_direction"])
print("Source case:", pairing["source_case_id"])
print("Target case:", pairing["target_case_id"])
print("Pairings:", s["num_pairings"])
print("Paired gaps:", s["paired_gap_count"])
print("Partial gaps:", s["partial_gap_count"])
print("Unpaired gaps:", s["unpaired_gap_count"])
print("Expected remaining blockers:", cov["expected_remaining_blocking_gaps"])
print("Contract blocking IDs:", cov["contract_blocking_gap_ids"])
print("Paired gap IDs:", cov["paired_gap_ids"])
print("Paired with target evidence:", cov["paired_with_target_reference_evidence"])
print("Partial target evidence:", cov["partial_target_reference_evidence"])
print("Unpaired needing evidence:", cov["unpaired_needs_more_evidence"])
print("Resolved by prior work:", cov["resolved_by_prior_work"])
print("Gaps marked resolved by v0.0.25:", s["gaps_marked_resolved_by_v025"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for p in pairing["pairings"]:
    print(f"- {p['gap_id']}: {p['pairing_state']} score={p['scoring']['score']} next={p['proposed_source_to_target_mapping']['next_resolver']}")

expected = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert pairing["schema_version"] == "source_target_pattern_pairing.v1"
assert pairing["xporthls_version"] == "v0.0.25"
assert pairing["migration_direction"] == "XRT->AVED"
assert pairing["target_reference_schema"] == "target_reference_ir.v1"
assert pairing["llm_annotations"] == []
assert pairing["trust_boundary"]["llm_used"] is False
assert pairing["trust_boundary"]["contract_modified"] is False
assert pairing["trust_boundary"]["generator_unlocked"] is False
assert pairing["trust_boundary"]["can_resolve_gap"] is False
assert pairing["trust_boundary"]["can_unlock_generator"] is False
assert s["num_pairings"] == 6
assert s["gaps_marked_resolved_by_v025"] == 0
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(cov["paired_gap_ids"]) == sorted(expected)
assert cov["gaps_marked_resolved_by_v025"] == []
assert "GAP-KERNEL-NAME-001" not in cov["paired_gap_ids"]
assert "GAP-KERNEL-NAME-001" in cov["resolved_by_prior_work"]
assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected)
assert "GAP-KERNEL-NAME-001" not in guard["summary"]["blocking_gap_ids"]

# Strong expected coverage: all six should at least have target reference pairing evidence,
# but placement must remain partial.
states = {p["gap_id"]: p["pairing_state"] for p in pairing["pairings"]}
assert states["GAP-PLACEMENT-SLR-001"] == "partial_target_reference_evidence"
assert s["unpaired_gap_count"] == 0
PY

echo
echo "DONE."
EOT

chmod +x add_pattern_pairing_v025_replay.sh

echo "[4/7] Add targetref README note"

cat > xporthls/targetref/README_v025.md <<'EOT'
# Source-Target Pattern Pairing v0.0.25

This module pairs source-side HiSparse ApplicationIR evidence with target-side SPMV-on-V80 TargetReferenceIR evidence.

It produces candidate pattern pairings for the six post-v0.0.22 remaining blockers:

```text
GAP-XRT-HOST-001
GAP-PLATFORM-001
GAP-MEM-HBM-001
GAP-STREAM-AXIS-001
GAP-PLACEMENT-SLR-001
GAP-HLS-INTERFACE-001
```

This version is read-only and deterministic:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
Gaps resolved by v0.0.25: 0
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json
```
EOT

echo "[5/7] Run v0.0.25 replay"

./add_pattern_pairing_v025_replay.sh

echo "[6/7] Git status"

git status

echo "[7/7] v0.0.25 script complete"
