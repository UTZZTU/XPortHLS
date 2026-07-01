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
