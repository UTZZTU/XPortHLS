#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Add Source-to-Target Gap Contract builder"

mkdir -p xporthls/realrepo
touch xporthls/realrepo/__init__.py

cat > xporthls/realrepo/gap_contract_v016.py <<'EOT'
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


def load_platform_pack(platform_pack_dir: str | None) -> dict[str, Any]:
    if not platform_pack_dir:
        return {
            "path": None,
            "exists": False,
            "json_files": {},
            "platform_id": None,
            "capabilities": {},
        }

    root = Path(platform_pack_dir)
    data: dict[str, Any] = {
        "path": str(root),
        "exists": root.exists() and root.is_dir(),
        "json_files": {},
        "platform_id": None,
        "capabilities": {},
    }

    if not data["exists"]:
        return data

    for path in sorted(root.glob("*.json")):
        try:
            obj = load_json(path)
        except Exception as exc:
            obj = {"_load_error": str(exc)}
        data["json_files"][path.name] = {
            "path": str(path),
            "sha256": sha256_file(path),
            "content": obj,
        }

    platform_json = data["json_files"].get("platform.json", {}).get("content", {})
    capabilities_json = data["json_files"].get("capabilities.json", {}).get("content", {})

    data["platform_id"] = (
        platform_json.get("platform_id")
        or platform_json.get("id")
        or platform_json.get("name")
        or "v80_aved_2025_1_stub"
    )
    data["capabilities"] = capabilities_json

    return data


def evidence_ref(kind: str, path: str | None = None, pointer: str | None = None, value: Any | None = None) -> dict[str, Any]:
    return {
        "kind": kind,
        "path": path,
        "pointer": pointer,
        "value": value,
    }


def make_gap(
    gap_id: str,
    title: str,
    category: str,
    severity: str,
    source_feature: str,
    target_requirement: str,
    decision: str,
    required_action: str,
    evidence: list[dict[str, Any]],
    status: str = "open",
    owner_layer: str = "deterministic_pipeline",
    blocks_migration: bool | None = None,
) -> dict[str, Any]:
    if blocks_migration is None:
        blocks_migration = severity == "blocking"

    return {
        "id": gap_id,
        "title": title,
        "category": category,
        "severity": severity,
        "status": status,
        "blocks_migration": blocks_migration,
        "source_feature": source_feature,
        "target_requirement": target_requirement,
        "decision": decision,
        "required_action": required_action,
        "owner_layer": owner_layer,
        "evidence": evidence,
    }


def app_summary(app: dict[str, Any]) -> dict[str, Any]:
    return app.get("summary", {})


def app_target(app: dict[str, Any]) -> dict[str, Any]:
    return app.get("target", {})


def app_source(app: dict[str, Any]) -> dict[str, Any]:
    return app.get("source", {})


def get_memory_kinds(app: dict[str, Any]) -> list[str]:
    memory = app.get("memory_topology", {})
    kinds = memory.get("summary", {}).get("memory_kinds")
    if kinds:
        return kinds
    return memory.get("memory_kinds", [])


def collect_gap_candidates(app: dict[str, Any], app_ir_path: str) -> list[dict[str, Any]]:
    summary = app_summary(app)
    source = app_source(app)
    target = app_target(app)
    kernel_graph = app.get("kernel_graph", {}).get("summary", {})
    memory_topology = app.get("memory_topology", {}).get("summary", {})
    build_system = app.get("build_system", {})
    compatibility = app.get("compatibility", {})

    gaps: list[dict[str, Any]] = []

    source_runtime = app.get("source_runtime") or source.get("runtime")
    source_boards = source.get("boards", [])
    source_memory = source.get("memory_model")
    source_toolchains = source.get("toolchains", {})

    target_platform = target.get("platform")
    target_ecosystem = target.get("ecosystem")

    memory_kinds = get_memory_kinds(app)
    num_memory_mappings = int(summary.get("num_memory_mappings") or 0)
    num_stream_edges = int(summary.get("num_stream_edges") or 0)
    num_hls_interfaces = int(summary.get("num_hls_interface_pragmas") or 0)
    num_hls_kernels = int(summary.get("num_hls_kernel_candidates") or 0)
    num_configured_without_declared = int(kernel_graph.get("num_configured_without_declared") or 0)
    num_declared_without_config = int(kernel_graph.get("num_declared_without_config") or 0)

    if source_runtime == "XRT":
        gaps.append(make_gap(
            gap_id="GAP-XRT-HOST-001",
            title="XRT host runtime requires target host/control rewrite",
            category="host_runtime",
            severity="blocking",
            source_feature="XRT host runtime and xclbin execution model",
            target_requirement="AVED-native host/control path with QDMA/register semantics",
            decision="block_migration_until_host_runtime_contract_exists",
            required_action="Implement real XRT host semantic extraction and target AVED host/control contract.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/source/runtime", source_runtime),
                evidence_ref("application_ir", app_ir_path, "/summary/source_runtime", summary.get("source_runtime")),
            ],
        ))

    if source_boards and target_platform:
        if "U280" in source_boards and "v80" in str(target_platform).lower():
            gaps.append(make_gap(
                gap_id="GAP-PLATFORM-001",
                title="Source U280 platform must be mapped to target V80 AVED platform",
                category="platform",
                severity="blocking",
                source_feature="U280/XRT/Vitis platform profile",
                target_requirement="V80/AVED/2025.1 platform pack and supported target resource model",
                decision="block_migration_until_platform_mapping_policy_exists",
                required_action="Create explicit SourcePlatformProfile-to-PlatformPack mapping rules for U280 to V80 AVED.",
                evidence=[
                    evidence_ref("application_ir", app_ir_path, "/source/boards", source_boards),
                    evidence_ref("application_ir", app_ir_path, "/target/platform", target_platform),
                    evidence_ref("application_ir", app_ir_path, "/target/ecosystem", target_ecosystem),
                ],
            ))

    if source_memory == "HBM" or "HBM" in memory_kinds:
        gaps.append(make_gap(
            gap_id="GAP-MEM-HBM-001",
            title="Source HBM memory topology needs target memory mapping policy",
            category="memory_topology",
            severity="blocking",
            source_feature="HBM/DDR memory mappings from connectivity sp= directives",
            target_requirement="Target AVED memory topology and source-to-target bank/port mapping policy",
            decision="block_migration_until_memory_gap_contract_exists",
            required_action="Define Source-to-Target Memory Gap Contract for HBM/DDR banks, m_axi ports, bundle names and target buffers.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/memory_topology/summary/memory_kinds", memory_kinds),
                evidence_ref("application_ir", app_ir_path, "/summary/num_memory_mappings", num_memory_mappings),
                evidence_ref("application_ir", app_ir_path, "/memory_topology/summary", memory_topology),
            ],
        ))

    if num_stream_edges > 0 or int(summary.get("num_hls_interface_pragmas") or 0) > 0:
        interface_summary = app.get("interfaces", {}).get("interface_type_summary", {})
        if int(interface_summary.get("axis", 0) or 0) > 0 or num_stream_edges > 0:
            gaps.append(make_gap(
                gap_id="GAP-STREAM-AXIS-001",
                title="AXIS/K2K stream graph requires target stream mapping",
                category="streaming",
                severity="blocking",
                source_feature="AXIS interfaces, hls::stream variables and connectivity stream edges",
                target_requirement="Target AVED stream/K2K mapping policy and generated inter-kernel data movement plan",
                decision="block_migration_until_stream_graph_contract_exists",
                required_action="Implement stream edge contract and target mapping for AXIS ports and K2K edges.",
                evidence=[
                    evidence_ref("application_ir", app_ir_path, "/summary/num_stream_edges", num_stream_edges),
                    evidence_ref("application_ir", app_ir_path, "/interfaces/interface_type_summary", interface_summary),
                    evidence_ref("application_ir", app_ir_path, "/facts/hls/summary/num_stream_variables", app.get("facts", {}).get("hls", {}).get("summary", {}).get("num_stream_variables")),
                ],
            ))

    slr_assignments = int(app.get("facts", {}).get("connectivity", {}).get("summary", {}).get("num_slr_assignments") or 0)
    if slr_assignments > 0:
        gaps.append(make_gap(
            gap_id="GAP-PLACEMENT-SLR-001",
            title="Source SLR placement constraints require target placement policy",
            category="placement",
            severity="blocking",
            source_feature="SLR assignment directives in source connectivity",
            target_requirement="Target V80 placement policy or placement-stripping policy",
            decision="block_migration_until_placement_policy_exists",
            required_action="Define whether source SLR directives are translated, ignored with proof, or replaced by target placement constraints.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/facts/connectivity/summary/num_slr_assignments", slr_assignments),
            ],
        ))

    if num_configured_without_declared > 0:
        gaps.append(make_gap(
            gap_id="GAP-KERNEL-NAME-001",
            title="Configured kernel names are not fully resolved to declared HLS functions",
            category="kernel_graph",
            severity="blocking",
            source_feature="Connectivity compute-unit/kernel names",
            target_requirement="Complete kernel graph with every configured kernel mapped to a declared HLS function or justified external node",
            decision="block_migration_until_kernel_name_resolution_exists",
            required_action="Implement kernel/compute-unit name resolver using nk/sp/stream_connect plus build source references.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/kernel_graph/summary/num_configured_without_declared", num_configured_without_declared),
                evidence_ref("application_ir", app_ir_path, "/kernel_graph/configured_without_declared", app.get("kernel_graph", {}).get("configured_without_declared", [])),
            ],
        ))

    if num_declared_without_config > 0:
        gaps.append(make_gap(
            gap_id="GAP-KERNEL-NAME-002",
            title="Some declared HLS kernel candidates are not referenced by connectivity",
            category="kernel_graph",
            severity="warning",
            source_feature="HLS functions with kernel-like pragmas or stream/dataflow markers",
            target_requirement="Classify declared kernel candidates as top kernels, helper functions, inactive sources, or test-only code",
            decision="allow_profile_only_but_require_classification_before_generation",
            required_action="Add kernel candidate classification and helper-function filtering.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/kernel_graph/summary/num_declared_without_config", num_declared_without_config),
                evidence_ref("application_ir", app_ir_path, "/kernel_graph/declared_without_config", app.get("kernel_graph", {}).get("declared_without_config", [])),
            ],
            blocks_migration=False,
        ))

    if num_hls_kernels > 0 and num_hls_interfaces > 0:
        gaps.append(make_gap(
            gap_id="GAP-HLS-INTERFACE-001",
            title="HLS interfaces are extracted but not yet lowered into target interface contract",
            category="hls_interface",
            severity="blocking",
            source_feature="m_axi, axis, s_axilite, ap_ctrl_none and dataflow HLS pragmas",
            target_requirement="Target AVED kernel/control/data movement interface contract",
            decision="block_migration_until_hls_interface_lowering_exists",
            required_action="Lower HLS Interface IR into target-side interface and control contracts.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/summary/num_hls_kernel_candidates", num_hls_kernels),
                evidence_ref("application_ir", app_ir_path, "/summary/num_hls_interface_pragmas", num_hls_interfaces),
                evidence_ref("application_ir", app_ir_path, "/interfaces/interface_type_summary", app.get("interfaces", {}).get("interface_type_summary", {})),
            ],
        ))

    versions = source_toolchains.get("vitis_versions", [])
    if versions and "2020.2" in versions:
        gaps.append(make_gap(
            gap_id="GAP-TOOLCHAIN-001",
            title="Source Vitis 2020.2 flow requires tool-version transition review",
            category="toolchain",
            severity="warning",
            source_feature="Vitis 2020.2 build flow and U280 shell",
            target_requirement="Vivado/Vitis 2025.1 AVED target flow",
            decision="allow_profile_only_but_require_toolchain_transition_rules_before_generation",
            required_action="Define supported source-version assumptions and target 2025.1 translation rules.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/source/toolchains/vitis_versions", versions),
                evidence_ref("application_ir", app_ir_path, "/build_system/detected_platforms", build_system.get("detected_platforms", [])),
            ],
            blocks_migration=False,
        ))

    xclbin_refs = build_system.get("xclbin_refs", [])
    if xclbin_refs:
        gaps.append(make_gap(
            gap_id="GAP-BINARY-ARTIFACT-001",
            title="Source xclbin artifacts are not reusable for target AVED generation",
            category="binary_artifact",
            severity="info",
            source_feature="Existing xclbin artifact references",
            target_requirement="Generated target project must rebuild target artifacts from source and contracts",
            decision="ignore_binary_artifacts_for_generation",
            required_action="Use xclbin references only as source evidence; never reuse them as target artifacts.",
            evidence=[
                evidence_ref("application_ir", app_ir_path, "/build_system/xclbin_refs", xclbin_refs),
            ],
            blocks_migration=False,
        ))

    for item in compatibility.get("unsupported_features", []):
        feature = item.get("feature")
        if feature:
            gap_id = "GAP-APP-UNSUPPORTED-" + feature.upper().replace("-", "_").replace(" ", "_")
            existing = {g["id"] for g in gaps}
            if gap_id not in existing:
                gaps.append(make_gap(
                    gap_id=gap_id,
                    title=f"ApplicationIR unsupported feature: {feature}",
                    category="application_ir_unsupported",
                    severity="warning",
                    source_feature=feature,
                    target_requirement="Explicit target support or documented blocker policy",
                    decision="preserve_as_application_ir_gap",
                    required_action=item.get("required_capability") or "Add support or document the gap.",
                    evidence=[
                        evidence_ref("application_ir", app_ir_path, "/compatibility/unsupported_features", item),
                    ],
                    blocks_migration=False,
                ))

    return gaps


def merge_expected_gap_refs(gaps: list[dict[str, Any]], expected_gaps_path: str | None) -> dict[str, Any]:
    if not expected_gaps_path or not Path(expected_gaps_path).exists():
        return {
            "expected_gaps_ref": None,
            "expected_required_capabilities": [],
            "expected_unsupported_features": [],
            "expected_unknown_kinds": [],
            "matched_expected_capabilities": [],
            "missing_expected_capabilities": [],
        }

    expected = load_json(expected_gaps_path)
    required_caps = expected.get("expected_required_capabilities", [])
    unsupported_features = expected.get("expected_unsupported_features", [])
    unknown_kinds = expected.get("expected_unknown_kinds", [])

    actual_caps = []
    actual_features = []
    for gap in gaps:
        actual_caps.append(gap.get("required_action", ""))
        actual_features.append(gap.get("source_feature", ""))
        actual_features.append(gap.get("category", ""))

    # Match by broad substring because expected_gaps are case-pack expectations, not exact contract ids.
    joined = "\n".join(actual_caps + actual_features + [g.get("id", "") for g in gaps]).lower()
    matched_caps = [cap for cap in required_caps if cap.lower() in joined]
    missing_caps = [cap for cap in required_caps if cap.lower() not in joined]

    return {
        "expected_gaps_ref": expected_gaps_path,
        "expected_required_capabilities": required_caps,
        "expected_unsupported_features": unsupported_features,
        "expected_unknown_kinds": unknown_kinds,
        "matched_expected_capabilities": matched_caps,
        "missing_expected_capabilities": missing_caps,
    }


def build_gap_contract(
    case_id: str,
    app_ir_path: str,
    expected_gaps_path: str | None,
    platform_pack_dir: str | None,
    out_contract_path: str | None = None,
) -> dict[str, Any]:
    app = load_json(app_ir_path)
    platform_pack = load_platform_pack(platform_pack_dir)

    gaps = collect_gap_candidates(app, app_ir_path)
    expected_alignment = merge_expected_gap_refs(gaps, expected_gaps_path)

    blocking = [g for g in gaps if g.get("severity") == "blocking" and g.get("blocks_migration")]
    warnings = [g for g in gaps if g.get("severity") == "warning"]
    infos = [g for g in gaps if g.get("severity") == "info"]

    migration_allowed = len(blocking) == 0
    contract_state = "ready_for_planning" if migration_allowed else "blocked_profile_only"

    target = app_target(app)
    source = app_source(app)

    contract = {
        "schema_version": "source_to_target_gap_contract.v1",
        "contract_id": f"{case_id}.source_to_target_gap_contract.v1",
        "case_id": case_id,
        "created_at_utc": utc_now(),
        "contract_state": contract_state,
        "migration_status": "profile_only",
        "source_application_ir_ref": {
            "path": app_ir_path,
            "sha256": sha256_file(app_ir_path),
            "schema_version": app.get("schema_version"),
        },
        "expected_gaps_alignment": expected_alignment,
        "source": {
            "runtime": app.get("source_runtime") or source.get("runtime"),
            "boards": source.get("boards", []),
            "toolchains": source.get("toolchains", {}),
            "memory_model": source.get("memory_model"),
        },
        "target": {
            "platform": target.get("platform"),
            "ecosystem": target.get("ecosystem"),
            "platform_pack": {
                "path": platform_pack.get("path"),
                "exists": platform_pack.get("exists"),
                "platform_id": platform_pack.get("platform_id"),
                "json_files": {
                    name: {
                        "path": item.get("path"),
                        "sha256": item.get("sha256"),
                    }
                    for name, item in platform_pack.get("json_files", {}).items()
                },
            },
        },
        "policy": {
            "severity_semantics": {
                "blocking": "must be resolved before any target project generation or migration attempt",
                "warning": "does not fail profile-only validation but must be reviewed before generation",
                "info": "traceability note; does not block profiling or planning",
            },
            "llm_policy": {
                "llm_may_suggest_repairs": True,
                "llm_may_change_contract_without_validator": False,
                "llm_is_correctness_judge": False,
            },
        },
        "migration_decision": {
            "allowed": migration_allowed,
            "decision": "allow_planning" if migration_allowed else "block_target_generation",
            "reason": (
                "No blocking source-to-target gaps remain."
                if migration_allowed
                else "Blocking source-to-target gaps remain; v0.0.16 is contract/profile-only."
            ),
            "blocking_gap_ids": [g["id"] for g in blocking],
        },
        "gaps": gaps,
        "summary": {
            "num_gaps": len(gaps),
            "num_blocking": len(blocking),
            "num_warnings": len(warnings),
            "num_info": len(infos),
            "blocking_gap_ids": [g["id"] for g in blocking],
            "warning_gap_ids": [g["id"] for g in warnings],
            "info_gap_ids": [g["id"] for g in infos],
            "migration_allowed": migration_allowed,
            "contract_state": contract_state,
            "missing_expected_capabilities": expected_alignment.get("missing_expected_capabilities", []),
        },
        "traceability": {
            "application_ir_summary": app.get("summary", {}),
            "kernel_graph_summary": app.get("kernel_graph", {}).get("summary", {}),
            "memory_topology_summary": app.get("memory_topology", {}).get("summary", {}),
            "input_refs": app.get("input_refs", {}),
            "output_contract_path": out_contract_path,
        },
        "llm_annotations": [],
    }

    return contract


def main() -> int:
    parser = argparse.ArgumentParser(description="Build Source-to-Target Gap Contract v0.0.16")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--expected-gaps", default=None)
    parser.add_argument("--platform-pack", default="platform_packs/v80_aved_2025_1_stub")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contract = build_gap_contract(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        expected_gaps_path=args.expected_gaps,
        platform_pack_dir=args.platform_pack,
        out_contract_path=args.out,
    )
    save_json(args.out, contract)

    s = contract["summary"]
    print(f"[xporthls] Gap Contract written to: {args.out}")
    print(f"[xporthls] Contract schema: {contract['schema_version']}")
    print(f"[xporthls] Contract state: {contract['contract_state']}")
    print(f"[xporthls] Migration allowed: {s['migration_allowed']}")
    print(f"[xporthls] Gaps: {s['num_gaps']}")
    print(f"[xporthls] Blocking: {s['num_blocking']}")
    print(f"[xporthls] Warnings: {s['num_warnings']}")
    print(f"[xporthls] Info: {s['num_info']}")
    print(f"[xporthls] Blocking IDs: {s['blocking_gap_ids']}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add Gap Contract validator"

cat > xporthls/realrepo/validate_gap_contract_v016.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class GapContractIssue:
    severity: str
    code: str
    message: str


@dataclass
class GapContractValidationReport:
    status: str
    issues: list[GapContractIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[GapContractIssue], severity: str, code: str, message: str) -> None:
    issues.append(GapContractIssue(severity=severity, code=code, message=message))


def validate_gap_shape(gap: dict[str, Any], issues: list[GapContractIssue]) -> None:
    required_fields = [
        "id",
        "title",
        "category",
        "severity",
        "status",
        "blocks_migration",
        "source_feature",
        "target_requirement",
        "decision",
        "required_action",
        "evidence",
    ]

    for field_name in required_fields:
        if field_name not in gap:
            add_issue(issues, "error", "GAP_FIELD_MISSING", f"Gap {gap.get('id', '<unknown>')} missing field: {field_name}")

    if gap.get("severity") not in {"blocking", "warning", "info"}:
        add_issue(issues, "error", "GAP_SEVERITY_INVALID", f"Gap {gap.get('id')} has invalid severity: {gap.get('severity')!r}")

    if not isinstance(gap.get("evidence", []), list) or not gap.get("evidence"):
        add_issue(issues, "error", "GAP_EVIDENCE_MISSING", f"Gap {gap.get('id')} has no evidence list.")


def validate(contract: dict[str, Any]) -> GapContractValidationReport:
    issues: list[GapContractIssue] = []

    if contract.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA", "Expected source_to_target_gap_contract.v1.")

    if contract.get("migration_status") != "profile_only":
        add_issue(issues, "error", "MIGRATION_STATUS", "v0.0.16 gap contract must remain profile_only.")

    if contract.get("contract_state") not in {"blocked_profile_only", "ready_for_planning"}:
        add_issue(issues, "error", "CONTRACT_STATE", f"Unexpected contract_state: {contract.get('contract_state')!r}")

    source_ref = contract.get("source_application_ir_ref", {})
    if source_ref.get("schema_version") != "application_ir.v2":
        add_issue(issues, "error", "APP_IR_SCHEMA_REF", "Gap contract must reference application_ir.v2.")

    target = contract.get("target", {})
    if target.get("platform") != "v80_aved_2025_1_stub":
        add_issue(issues, "error", "TARGET_PLATFORM", "Expected target platform v80_aved_2025_1_stub.")
    if target.get("ecosystem") != "AVED":
        add_issue(issues, "error", "TARGET_ECOSYSTEM", "Expected target ecosystem AVED.")

    if contract.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", "Deterministic gap contract must not contain LLM annotations in v0.0.16.")

    gaps = contract.get("gaps", [])
    if not gaps:
        add_issue(issues, "error", "NO_GAPS", "Gap contract has no gaps.")

    for gap in gaps:
        validate_gap_shape(gap, issues)

    summary = contract.get("summary", {})
    if int(summary.get("num_gaps") or 0) != len(gaps):
        add_issue(issues, "error", "GAP_COUNT_MISMATCH", "summary.num_gaps does not match actual gaps length.")

    blocking = [g for g in gaps if g.get("severity") == "blocking" and g.get("blocks_migration")]
    warnings = [g for g in gaps if g.get("severity") == "warning"]
    infos = [g for g in gaps if g.get("severity") == "info"]

    if int(summary.get("num_blocking") or 0) != len(blocking):
        add_issue(issues, "error", "BLOCKING_COUNT_MISMATCH", "summary.num_blocking does not match actual blocking gaps length.")

    if int(summary.get("num_warnings") or 0) != len(warnings):
        add_issue(issues, "error", "WARNING_COUNT_MISMATCH", "summary.num_warnings does not match actual warning gaps length.")

    if int(summary.get("num_info") or 0) != len(infos):
        add_issue(issues, "error", "INFO_COUNT_MISMATCH", "summary.num_info does not match actual info gaps length.")

    migration = contract.get("migration_decision", {})
    if blocking:
        if migration.get("allowed") is not False:
            add_issue(issues, "error", "MIGRATION_ALLOWED_WITH_BLOCKERS", "migration_decision.allowed must be false when blocking gaps exist.")
        if contract.get("contract_state") != "blocked_profile_only":
            add_issue(issues, "error", "CONTRACT_STATE_WITH_BLOCKERS", "contract_state must be blocked_profile_only when blocking gaps exist.")

    required_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }

    actual_gap_ids = {g.get("id") for g in gaps}
    missing_required = sorted(required_gap_ids - actual_gap_ids)
    if missing_required:
        add_issue(issues, "error", "REQUIRED_GAP_MISSING", f"Missing required gap ids: {missing_required}")

    expected_alignment = contract.get("expected_gaps_alignment", {})
    missing_expected_caps = expected_alignment.get("missing_expected_capabilities", [])
    if missing_expected_caps:
        add_issue(
            issues,
            "warning",
            "EXPECTED_CAPABILITY_ALIGNMENT_INCOMPLETE",
            f"Some expected case-pack capabilities did not align by substring: {missing_expected_caps}",
        )

    app_summary = contract.get("traceability", {}).get("application_ir_summary", {})
    if int(app_summary.get("num_hls_kernel_candidates") or 0) <= 0:
        add_issue(issues, "error", "TRACE_APP_SUMMARY_NO_HLS_KERNELS", "Trace ApplicationIR summary has no HLS kernel candidates.")

    if int(app_summary.get("num_memory_mappings") or 0) <= 0:
        add_issue(issues, "error", "TRACE_APP_SUMMARY_NO_MEMORY_MAPPINGS", "Trace ApplicationIR summary has no memory mappings.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return GapContractValidationReport(
        status=status,
        issues=issues,
        summary={
            "contract_id": contract.get("contract_id"),
            "case_id": contract.get("case_id"),
            "schema_version": contract.get("schema_version"),
            "contract_state": contract.get("contract_state"),
            "migration_status": contract.get("migration_status"),
            "migration_allowed": migration.get("allowed"),
            "target_platform": target.get("platform"),
            "target_ecosystem": target.get("ecosystem"),
            "num_gaps": summary.get("num_gaps"),
            "num_blocking": summary.get("num_blocking"),
            "num_warnings": summary.get("num_warnings"),
            "num_info": summary.get("num_info"),
            "blocking_gap_ids": summary.get("blocking_gap_ids"),
            "missing_expected_capabilities": missing_expected_caps,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Source-to-Target Gap Contract v0.0.16")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contract = load_json(args.contract)
    report = validate(contract)
    report.save(args.out)

    print(f"[xporthls] Gap Contract validation written to: {args.out}")
    print(f"[xporthls] Gap Contract validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/7] Add Gap Contract orchestration runner"

cat > xporthls/realrepo/run_gap_contract_v016.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.realrepo.gap_contract_v016 import build_gap_contract, save_json
from xporthls.realrepo.validate_gap_contract_v016 import validate


def main() -> int:
    parser = argparse.ArgumentParser(description="Run v0.0.16 Source-to-Target Gap Contract pipeline")
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--expected-gaps", default="cases/hisparse_u280_profile/expected_gaps.json")
    parser.add_argument("--platform-pack", default="platform_packs/v80_aved_2025_1_stub")
    parser.add_argument("--out-dir", default="experiments/runs")
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    contract_path = out_dir / f"{args.case_id}_gap_contract_v016.json"
    report_path = out_dir / f"{args.case_id}_gap_contract_report_v016.json"

    contract = build_gap_contract(
        case_id=args.case_id,
        app_ir_path=args.app_ir,
        expected_gaps_path=args.expected_gaps,
        platform_pack_dir=args.platform_pack,
        out_contract_path=str(contract_path),
    )
    save_json(contract_path, contract)

    report = validate(contract)
    report.save(str(report_path))

    s = contract["summary"]
    print(f"[xporthls] Gap Contract: {contract_path}")
    print(f"[xporthls] Validation report: {report_path}")
    print(f"[xporthls] Contract state: {contract['contract_state']}")
    print(f"[xporthls] Migration allowed: {s['migration_allowed']}")
    print(f"[xporthls] Gaps: {s['num_gaps']}")
    print(f"[xporthls] Blocking: {s['num_blocking']}")
    print(f"[xporthls] Warnings: {s['num_warnings']}")
    print(f"[xporthls] Info: {s['num_info']}")
    print(f"[xporthls] Blocking IDs: {s['blocking_gap_ids']}")
    print(f"[xporthls] Missing expected capabilities: {s['missing_expected_capabilities']}")
    print(f"[xporthls] Validation status: {report.status}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/7] Update README with Gap Contract usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Source-to-target gap contract

XPortHLS can convert ApplicationIR v2 gaps into a deterministic source-to-target gap contract. The contract decides whether target generation is allowed and records blocking gaps, warnings, evidence, and required next capabilities.

Example:

```bash
python3 -m xporthls.realrepo.run_gap_contract_v016 \\
  --case-id hisparse_u280_profile \\
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \\
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \\
  --platform-pack platform_packs/v80_aved_2025_1_stub \\
  --out-dir experiments/runs
```

The builder writes:

```text
experiments/runs/hisparse_u280_profile_gap_contract_v016.json
experiments/runs/hisparse_u280_profile_gap_contract_report_v016.json
```

The contract is deterministic and profile-only at this stage. It does not generate an AVED project.
"""

if "## Source-to-target gap contract" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/7] Create v0.0.16 replay script"

cat > add_gap_contract_v016_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

echo "[v0.0.16] Python syntax check"

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
  xporthls/realrepo/run_gap_contract_v016.py

echo "[v0.0.16] Re-run HiSparse profile-only case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.16] Build Source-to-Target Gap Contract"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

python3 - <<'PY'
import json

case_validation = json.load(open("experiments/runs/hisparse_u280_profile_case_validation_v015.json"))
contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
report = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_report_v016.json"))

summary = contract["summary"]

print()
print("Case validation status:", case_validation["status"])
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Migration status:", contract["migration_status"])
print("Migration allowed:", contract["migration_decision"]["allowed"])
print("Target:", contract["target"])
print("Gaps:", summary["num_gaps"])
print("Blocking:", summary["num_blocking"])
print("Warnings:", summary["num_warnings"])
print("Info:", summary["num_info"])
print("Blocking IDs:", summary["blocking_gap_ids"])
print("Missing expected capabilities:", summary["missing_expected_capabilities"])
print("Validation status:", report["status"])

required_ids = {
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-KERNEL-NAME-001",
    "GAP-HLS-INTERFACE-001",
}
actual_ids = {gap["id"] for gap in contract["gaps"]}

assert case_validation["status"] in {"pass", "pass_with_warnings"}
assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["source_application_ir_ref"]["schema_version"] == "application_ir.v2"
assert contract["migration_status"] == "profile_only"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert contract["target"]["platform"] == "v80_aved_2025_1_stub"
assert contract["target"]["ecosystem"] == "AVED"
assert summary["num_gaps"] >= 6
assert summary["num_blocking"] >= 5
assert required_ids.issubset(actual_ids)
assert report["status"] in {"pass", "pass_with_warnings"}
PY

echo
echo "DONE."
EOT

chmod +x add_gap_contract_v016_replay.sh

echo "[6/7] Run v0.0.16 replay"

./add_gap_contract_v016_replay.sh

echo "[7/7] Git status"

git status
