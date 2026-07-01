#!/usr/bin/env bash
set -euo pipefail

echo "[1/8] Add AVED Host Runtime Pattern Resolver v0.0.27 modules"

mkdir -p xporthls/resolvers
touch xporthls/resolvers/__init__.py

mkdir -p scripts/replay scripts/legacy_full

# Keep this full script under the organized scripts layout.
FULL_SCRIPT_DST="scripts/legacy_full/add_aved_host_runtime_pattern_v027_full.sh"
if [ -f "$0" ]; then
  src_real="$(realpath "$0")"
  dst_real="$(realpath -m "$FULL_SCRIPT_DST")"
  if [ "$src_real" != "$dst_real" ]; then
    cp "$0" "$FULL_SCRIPT_DST"
    chmod +x "$FULL_SCRIPT_DST"
  fi
fi

cat > xporthls/resolvers/aved_host_runtime_pattern_v027.py <<'EOT'
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
EOT

cat > xporthls/resolvers/validate_aved_host_runtime_pattern_v027.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from xporthls.resolvers.aved_host_runtime_pattern_v027 import (
    HOST_GAP_ID,
    REMAINING_BLOCKING_GAPS_V022,
)


@dataclass
class AvedHostRuntimeIssue:
    severity: str
    code: str
    message: str


@dataclass
class AvedHostRuntimeValidationReport:
    schema_version: str = "aved_host_runtime_pattern_validation_report.v1"
    xporthls_version: str = "v0.0.27"
    status: str = "fail"
    issues: list[AvedHostRuntimeIssue] = field(default_factory=list)
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


def add_issue(issues: list[AvedHostRuntimeIssue], severity: str, code: str, message: str) -> None:
    issues.append(AvedHostRuntimeIssue(severity=severity, code=code, message=message))


def validate_aved_host_runtime_pattern(pattern: dict[str, Any], guard_report: dict[str, Any] | None = None) -> AvedHostRuntimeValidationReport:
    issues: list[AvedHostRuntimeIssue] = []

    if pattern.get("schema_version") != "aved_host_runtime_pattern.v1":
        add_issue(issues, "error", "SCHEMA", "Expected aved_host_runtime_pattern.v1.")

    if pattern.get("xporthls_version") != "v0.0.27":
        add_issue(issues, "error", "VERSION", "Expected xporthls_version v0.0.27.")

    if pattern.get("migration_direction") != "XRT->AVED":
        add_issue(issues, "error", "MIGRATION_DIRECTION", "Expected migration_direction XRT->AVED.")

    if pattern.get("gap_id") != HOST_GAP_ID:
        add_issue(issues, "error", "GAP_ID", f"Expected gap_id {HOST_GAP_ID}.")

    if pattern.get("resolver_name") != "AVEDHostRuntimePatternResolver":
        add_issue(issues, "error", "RESOLVER_NAME", "Expected AVEDHostRuntimePatternResolver.")

    if pattern.get("pattern_state") != "host_runtime_pattern_extracted_not_resolved":
        add_issue(issues, "error", "PATTERN_STATE", "Pattern must be extracted but not resolved.")

    if pattern.get("ready_for_contract_resolution") is not False:
        add_issue(issues, "error", "READY_FOR_CONTRACT_RESOLUTION", "v0.0.27 must not make host gap ready for contract resolution.")

    if pattern.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS", "v0.0.27 must not contain LLM annotations.")

    tb = pattern.get("trust_boundary", {})
    required_false = [
        "llm_used",
        "contract_modified",
        "migration_allowed_modified",
        "generator_unlocked",
        "can_resolve_gap",
        "can_generate_host_code",
    ]
    for key in required_false:
        if tb.get(key) is not False:
            add_issue(issues, "error", "TRUST_BOUNDARY", f"Trust boundary flag must be false: {key}")

    if tb.get("pattern_only") is not True:
        add_issue(issues, "error", "PATTERN_ONLY", "v0.0.27 must be pattern-only.")

    if tb.get("requires_future_memory_and_interface_validation") is not True:
        add_issue(issues, "error", "FUTURE_VALIDATION_REQUIRED", "Host runtime pattern must require future memory/interface validation.")

    ctx = pattern.get("contract_context", {})
    blockers = ctx.get("blocking_gap_ids", [])
    if sorted(blockers) != sorted(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "CONTRACT_BLOCKERS", "Contract blockers must remain the six post-v0.0.22 blockers.")

    if ctx.get("host_gap_still_blocking") is not True:
        add_issue(issues, "error", "HOST_GAP_NOT_BLOCKING", "GAP-XRT-HOST-001 must remain blocking in v0.0.27.")

    if ctx.get("gaps_marked_resolved_by_v027") not in ([], None):
        add_issue(issues, "error", "GAPS_RESOLVED", "v0.0.27 must not mark gaps resolved.")

    if ctx.get("contract_mutation_allowed") is not False:
        add_issue(issues, "error", "CONTRACT_MUTATION_ALLOWED", "Contract mutation must not be allowed.")

    mappings = pattern.get("host_action_mappings", [])
    if len(mappings) < 8:
        add_issue(issues, "error", "ACTION_MAPPING_COUNT", "Expected at least 8 host action mappings.")

    required_source_actions = {
        "XRT_OPEN_DEVICE",
        "XRT_LOAD_XCLBIN",
        "XRT_CREATE_KERNEL",
        "XRT_ALLOC_BO",
        "XRT_SYNC_TO_DEVICE",
        "XRT_SYNC_FROM_DEVICE",
        "XRT_SET_KERNEL_ARGS",
        "XRT_RUN_START",
        "XRT_RUN_WAIT",
    }
    got_actions = {m.get("source_action_id") for m in mappings}
    missing_actions = sorted(required_source_actions - got_actions)
    if missing_actions:
        add_issue(issues, "error", "MISSING_ACTIONS", f"Missing required host action mappings: {missing_actions}")

    for m in mappings:
        mid = m.get("source_action_id")
        if not m.get("target_action_id"):
            add_issue(issues, "error", "MISSING_TARGET_ACTION", f"Missing target action for {mid}.")
        if not m.get("mapping_rule"):
            add_issue(issues, "error", "MISSING_MAPPING_RULE", f"Missing mapping rule for {mid}.")
        mtb = m.get("trust_boundary", {})
        for key in ["llm_used", "authoritative", "can_generate_code", "can_modify_contract"]:
            if mtb.get(key) is not False:
                add_issue(issues, "error", "MAPPING_TRUST_BOUNDARY", f"{mid} trust flag must be false: {key}")
        if mtb.get("requires_future_validation") is not True:
            add_issue(issues, "error", "MAPPING_FUTURE_VALIDATION", f"{mid} must require future validation.")

    summary = pattern.get("summary", {})
    if summary.get("host_action_mapping_count") != len(mappings):
        add_issue(issues, "error", "SUMMARY_MAPPING_COUNT", "summary.host_action_mapping_count mismatch.")

    if summary.get("source_xrt_host_total_hits", 0) <= 0:
        add_issue(issues, "warning", "SOURCE_XRT_EVIDENCE_SPARSE", "Source XRT host evidence appears sparse; inspect ApplicationIR.")

    if summary.get("target_qdma_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_QDMA_EVIDENCE", "Target QDMA evidence is required.")
    if summary.get("target_axi_lite_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_AXI_LITE_EVIDENCE", "Target AXI-Lite evidence is required.")
    if summary.get("target_ap_ctrl_evidence_count", 0) <= 0:
        add_issue(issues, "error", "NO_AP_CTRL_EVIDENCE", "Target AP_CTRL evidence is required.")

    if summary.get("host_gap_still_blocking") is not True:
        add_issue(issues, "error", "SUMMARY_HOST_GAP_NOT_BLOCKING", "Host gap must remain blocking.")
    if summary.get("gaps_marked_resolved_by_v027") != 0:
        add_issue(issues, "error", "SUMMARY_RESOLVED_COUNT", "v0.0.27 must resolve zero gaps.")
    if summary.get("contract_blocking_gap_count") != len(REMAINING_BLOCKING_GAPS_V022):
        add_issue(issues, "error", "SUMMARY_BLOCKING_COUNT", "Contract blocking count must remain six.")
    if summary.get("llm_used") is not False:
        add_issue(issues, "error", "SUMMARY_LLM_USED", "summary.llm_used must be false.")
    if summary.get("contract_modified") is not False:
        add_issue(issues, "error", "SUMMARY_CONTRACT_MODIFIED", "summary.contract_modified must be false.")
    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "SUMMARY_GENERATOR_UNLOCK", "summary.generator_unlock_allowed must be false.")

    deps = pattern.get("unresolved_dependencies", [])
    dep_ids = {d.get("gap_id") for d in deps}
    if "GAP-MEM-HBM-001" not in dep_ids:
        add_issue(issues, "error", "MISSING_MEMORY_DEPENDENCY", "Host runtime pattern must record dependency on HBM/PC memory mapping.")
    if "GAP-HLS-INTERFACE-001" not in dep_ids:
        add_issue(issues, "error", "MISSING_HLS_INTERFACE_DEPENDENCY", "Host runtime pattern must record dependency on HLS interface/register mapping.")
    if "GAP-PLATFORM-001" not in dep_ids:
        add_issue(issues, "error", "MISSING_PLATFORM_DEPENDENCY", "Host runtime pattern must record dependency on platform/IP instance mapping.")

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

    return AvedHostRuntimeValidationReport(
        status=status,
        issues=issues,
        summary={
            "pattern_schema": pattern.get("schema_version"),
            "migration_direction": pattern.get("migration_direction"),
            "gap_id": pattern.get("gap_id"),
            "resolver_name": pattern.get("resolver_name"),
            "pattern_state": pattern.get("pattern_state"),
            "ready_for_contract_resolution": pattern.get("ready_for_contract_resolution"),
            "host_action_mapping_count": summary.get("host_action_mapping_count"),
            "mapped_with_source_and_target_evidence_count": summary.get("mapped_with_source_and_target_evidence_count"),
            "mapped_with_target_evidence_source_sparse_count": summary.get("mapped_with_target_evidence_source_sparse_count"),
            "mapped_but_needs_more_target_evidence_count": summary.get("mapped_but_needs_more_target_evidence_count"),
            "target_qdma_evidence_count": summary.get("target_qdma_evidence_count"),
            "target_axi_lite_evidence_count": summary.get("target_axi_lite_evidence_count"),
            "target_ap_ctrl_evidence_count": summary.get("target_ap_ctrl_evidence_count"),
            "unresolved_dependency_count": summary.get("unresolved_dependency_count"),
            "host_gap_still_blocking": summary.get("host_gap_still_blocking"),
            "gaps_marked_resolved_by_v027": summary.get("gaps_marked_resolved_by_v027"),
            "contract_blocking_gap_count": summary.get("contract_blocking_gap_count"),
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
    parser = argparse.ArgumentParser(description="Validate AVED host runtime pattern v0.0.27")
    parser.add_argument("--pattern", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    pattern = load_json(args.pattern)
    guard = load_json(args.guard_report) if args.guard_report else None

    report = validate_aved_host_runtime_pattern(pattern, guard)
    report.save(args.out)

    print(f"[xporthls] AVED host runtime validation: {args.out}")
    print(f"[xporthls] Validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

cat > xporthls/resolvers/run_aved_host_runtime_pattern_v027.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.resolvers.aved_host_runtime_pattern_v027 import (
    build_aved_host_runtime_pattern,
    build_aved_host_runtime_report,
    load_json,
    save_json,
)
from xporthls.resolvers.validate_aved_host_runtime_pattern_v027 import validate_aved_host_runtime_pattern


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.27 AVED host runtime pattern resolver")
    parser.add_argument("--application-ir", required=True)
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--pattern-pairing", required=True)
    parser.add_argument("--target-aware-plan", required=True)
    parser.add_argument("--patched-contract", required=True)
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
    target_aware_plan = load_json(args.target_aware_plan)
    patched_contract = load_json(args.patched_contract)
    guard = load_json(args.guard_report) if args.guard_report else None

    prefix = f"{args.source_case_id}_to_{args.target_case_id}"
    pattern_path = out_dir / f"{prefix}_aved_host_runtime_pattern_v027.json"
    report_path = out_dir / f"{prefix}_aved_host_runtime_pattern_report_v027.json"
    validation_path = out_dir / f"{prefix}_aved_host_runtime_pattern_validation_v027.json"

    pattern = build_aved_host_runtime_pattern(
        application_ir=app_ir,
        target_reference_ir=target_ir,
        pattern_pairing=pairing,
        target_aware_plan=target_aware_plan,
        patched_contract=patched_contract,
        source_case_id=args.source_case_id,
        target_case_id=args.target_case_id,
    )
    save_json(pattern_path, pattern)

    report = build_aved_host_runtime_report(pattern)
    save_json(report_path, report)

    validation = validate_aved_host_runtime_pattern(pattern, guard)
    validation.save(validation_path)

    s = pattern["summary"]

    print(f"[xporthls] AVED host runtime pattern: {pattern_path}")
    print(f"[xporthls] AVED host runtime report: {report_path}")
    print(f"[xporthls] AVED host runtime validation: {validation_path}")
    print(f"[xporthls] Schema: {pattern['schema_version']}")
    print(f"[xporthls] Migration direction: {pattern['migration_direction']}")
    print(f"[xporthls] Gap ID: {pattern['gap_id']}")
    print(f"[xporthls] Resolver: {pattern['resolver_name']}")
    print(f"[xporthls] Pattern state: {pattern['pattern_state']}")
    print(f"[xporthls] Ready for contract resolution: {pattern['ready_for_contract_resolution']}")
    print(f"[xporthls] Host action mappings: {s['host_action_mapping_count']}")
    print(f"[xporthls] Mapped with source+target evidence: {s['mapped_with_source_and_target_evidence_count']}")
    print(f"[xporthls] Mapped with target evidence / source sparse: {s['mapped_with_target_evidence_source_sparse_count']}")
    print(f"[xporthls] Needs more target evidence: {s['mapped_but_needs_more_target_evidence_count']}")
    print(f"[xporthls] Target QDMA evidence: {s['target_qdma_evidence_count']}")
    print(f"[xporthls] Target AXI-Lite evidence: {s['target_axi_lite_evidence_count']}")
    print(f"[xporthls] Target AP_CTRL evidence: {s['target_ap_ctrl_evidence_count']}")
    print(f"[xporthls] Unresolved dependency count: {s['unresolved_dependency_count']}")
    print(f"[xporthls] Host gap still blocking: {s['host_gap_still_blocking']}")
    print(f"[xporthls] Gaps marked resolved by v0.0.27: {s['gaps_marked_resolved_by_v027']}")
    print(f"[xporthls] Contract blocking gap count: {s['contract_blocking_gap_count']}")
    print(f"[xporthls] LLM used: {s['llm_used']}")
    print(f"[xporthls] Contract modified: {s['contract_modified']}")
    print(f"[xporthls] Generator unlock allowed: {s['generator_unlock_allowed']}")
    print(f"[xporthls] Validation status: {validation.status}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/8] Update README with v0.0.27 implementation note if needed"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
if not p.exists():
    p.write_text("# XPortHLS\n", encoding="utf-8")

text = p.read_text(encoding="utf-8")
section = """
## AVED Host Runtime Pattern Resolver v0.0.27

v0.0.27 adds the first target-aware resolver pattern for `GAP-XRT-HOST-001`.

It extracts a verified candidate host runtime mapping between source XRT host actions and target AVED/V80 host mechanisms:

```text
xrt::device / xrt::kernel / xrt::bo / run.start / run.wait
  ->
QDMA transfer + AXI-Lite register access + AP_CTRL polling
```

This version generates `aved_host_runtime_pattern.v1`. It is still pattern-only:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
GAP-XRT-HOST-001 resolved: false
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json
```
"""

if "## AVED Host Runtime Pattern Resolver v0.0.27" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"
    p.write_text(text, encoding="utf-8")
PY

echo "[3/8] Create v0.0.27 replay script"

cat > scripts/replay/add_aved_host_runtime_pattern_v027_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

APP_IR="${APP_IR:-experiments/runs/hisparse_application_ir_v2_v014.json}"
TARGET_IR="${TARGET_IR:-experiments/runs/spmv_on_v80_target_reference_ir_v024.json}"
PATTERN_PAIRING="${PATTERN_PAIRING:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json}"
TARGET_AWARE_PLAN="${TARGET_AWARE_PLAN:-experiments/runs/hisparse_u280_profile_to_spmv_on_v80_target_aware_resolver_plan_v026.json}"
PATCHED_CONTRACT="${PATCHED_CONTRACT:-experiments/runs/hisparse_u280_profile_gap_contract_patched_v022.json}"
GUARD_REPORT="${GUARD_REPORT:-experiments/runs/hisparse_u280_profile_generator_guard_aved_host_runtime_v027.json}"
REQUESTED_OUT="${REQUESTED_OUT:-experiments/runs/hisparse_u280_profile_guarded_generated_v027}"

PATTERN="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json"
PATTERN_REPORT="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json"
PATTERN_VALIDATION="experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json"

echo "[v0.0.27] Python syntax check"

python3 -m py_compile \
  xporthls/resolvers/aved_host_runtime_pattern_v027.py \
  xporthls/resolvers/validate_aved_host_runtime_pattern_v027.py \
  xporthls/resolvers/run_aved_host_runtime_pattern_v027.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py

echo "[v0.0.27] Check required input artifacts"

missing=0
for f in "$APP_IR" "$TARGET_IR" "$PATTERN_PAIRING" "$TARGET_AWARE_PLAN" "$PATCHED_CONTRACT"; do
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
  echo "  - v0.0.26 for TargetAwareResolverPlan"
  exit 3
fi

echo "[v0.0.27] Run generator guard against patched contract"

rm -rf "$REQUESTED_OUT"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract "$PATCHED_CONTRACT" \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.27] Run AVED host runtime pattern resolver"

python3 -m xporthls.resolvers.run_aved_host_runtime_pattern_v027 \
  --application-ir "$APP_IR" \
  --target-reference-ir "$TARGET_IR" \
  --pattern-pairing "$PATTERN_PAIRING" \
  --target-aware-plan "$TARGET_AWARE_PLAN" \
  --patched-contract "$PATCHED_CONTRACT" \
  --guard-report "$GUARD_REPORT" \
  --source-case-id hisparse_u280_profile \
  --target-case-id spmv_on_v80 \
  --out-dir experiments/runs

python3 - <<'PY'
import json

pattern = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json", encoding="utf-8"))
report = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json", encoding="utf-8"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json", encoding="utf-8"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_aved_host_runtime_v027.json", encoding="utf-8"))

s = pattern["summary"]

print()
print("AVEDHostRuntimePattern schema:", pattern["schema_version"])
print("Migration direction:", pattern["migration_direction"])
print("Gap ID:", pattern["gap_id"])
print("Resolver:", pattern["resolver_name"])
print("Pattern state:", pattern["pattern_state"])
print("Ready for contract resolution:", pattern["ready_for_contract_resolution"])
print("Host action mappings:", s["host_action_mapping_count"])
print("Mapped with source+target evidence:", s["mapped_with_source_and_target_evidence_count"])
print("Mapped with target evidence / source sparse:", s["mapped_with_target_evidence_source_sparse_count"])
print("Needs more target evidence:", s["mapped_but_needs_more_target_evidence_count"])
print("Source XRT host hits:", s["source_xrt_host_total_hits"])
print("Target host hits:", s["target_host_total_hits"])
print("Target QDMA evidence:", s["target_qdma_evidence_count"])
print("Target AXI-Lite evidence:", s["target_axi_lite_evidence_count"])
print("Target AP_CTRL evidence:", s["target_ap_ctrl_evidence_count"])
print("Unresolved dependencies:", pattern["unresolved_dependencies"])
print("Host gap still blocking:", s["host_gap_still_blocking"])
print("Gaps marked resolved by v0.0.27:", s["gaps_marked_resolved_by_v027"])
print("Contract blocking gap count:", s["contract_blocking_gap_count"])
print("LLM used:", s["llm_used"])
print("Contract modified:", s["contract_modified"])
print("Generator unlock allowed:", s["generator_unlock_allowed"])
print("Validation status:", validation["status"])
print("Validation warnings:", validation["summary"]["num_warnings"])
print("Validation errors:", validation["summary"]["num_errors"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocking IDs:", guard["summary"]["blocking_gap_ids"])

for m in pattern["host_action_mappings"]:
    print(f"- {m['source_action_id']} -> {m['target_action_id']} [{m['mapping_state']}] dep={m['dependency']}")

expected_blockers = [
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-PLACEMENT-SLR-001",
    "GAP-HLS-INTERFACE-001",
]

assert pattern["schema_version"] == "aved_host_runtime_pattern.v1"
assert pattern["xporthls_version"] == "v0.0.27"
assert pattern["migration_direction"] == "XRT->AVED"
assert pattern["gap_id"] == "GAP-XRT-HOST-001"
assert pattern["resolver_name"] == "AVEDHostRuntimePatternResolver"
assert pattern["pattern_state"] == "host_runtime_pattern_extracted_not_resolved"
assert pattern["ready_for_contract_resolution"] is False
assert pattern["llm_annotations"] == []
assert pattern["trust_boundary"]["llm_used"] is False
assert pattern["trust_boundary"]["contract_modified"] is False
assert pattern["trust_boundary"]["generator_unlocked"] is False
assert pattern["trust_boundary"]["can_resolve_gap"] is False
assert pattern["trust_boundary"]["can_generate_host_code"] is False
assert s["host_action_mapping_count"] >= 8
assert s["target_qdma_evidence_count"] > 0
assert s["target_axi_lite_evidence_count"] > 0
assert s["target_ap_ctrl_evidence_count"] > 0
assert s["host_gap_still_blocking"] is True
assert s["gaps_marked_resolved_by_v027"] == 0
assert s["contract_blocking_gap_count"] == 6
assert s["llm_used"] is False
assert s["contract_modified"] is False
assert s["generator_unlock_allowed"] is False
assert sorted(pattern["contract_context"]["blocking_gap_ids"]) == sorted(expected_blockers)
assert "GAP-KERNEL-NAME-001" not in pattern["contract_context"]["blocking_gap_ids"]

dep_ids = {d["gap_id"] for d in pattern["unresolved_dependencies"]}
assert "GAP-MEM-HBM-001" in dep_ids
assert "GAP-HLS-INTERFACE-001" in dep_ids
assert "GAP-PLATFORM-001" in dep_ids

assert validation["status"] in {"pass", "pass_with_warnings"}
assert validation["summary"]["num_errors"] == 0
assert guard["decision"]["blocked"] is True
assert guard["decision"]["allowed"] is False
assert sorted(guard["summary"]["blocking_gap_ids"]) == sorted(expected_blockers)
PY

echo
echo "DONE."
EOT

chmod +x scripts/replay/add_aved_host_runtime_pattern_v027_replay.sh

echo "[4/8] Add resolver README note"

cat > xporthls/resolvers/README_v027.md <<'EOT'
# AVED Host Runtime Pattern Resolver v0.0.27

This module extracts the first target-aware host runtime pattern for:

```text
GAP-XRT-HOST-001
```

It maps source XRT host actions to target AVED/V80 host mechanisms:

```text
xrt::device / xrt::kernel / xrt::bo / bo.sync / run.start / run.wait
  ->
QDMA transfer + AXI-Lite register access + AP_CTRL polling
```

This version is pattern-only:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
GAP-XRT-HOST-001 resolved: false
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json
```
EOT

echo "[5/8] Run v0.0.27 replay"

./scripts/replay/add_aved_host_runtime_pattern_v027_replay.sh

echo "[6/8] Ensure full script is in scripts/legacy_full"

if [ ! -f "$FULL_SCRIPT_DST" ]; then
  echo "[xporthls] WARNING: full script copy missing at $FULL_SCRIPT_DST"
else
  chmod +x "$FULL_SCRIPT_DST"
  echo "[xporthls] Full script copied to $FULL_SCRIPT_DST"
fi

echo "[7/8] Git status"

git status

echo "[8/8] v0.0.27 script complete"
