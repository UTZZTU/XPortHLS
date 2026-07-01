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
