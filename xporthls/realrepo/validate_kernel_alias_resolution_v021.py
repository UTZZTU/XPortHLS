from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class V021Issue:
    severity: str
    code: str
    message: str


@dataclass
class V021ValidationReport:
    status: str
    issues: list[V021Issue] = field(default_factory=list)
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


def issue(issues: list[V021Issue], severity: str, code: str, message: str) -> None:
    issues.append(V021Issue(severity=severity, code=code, message=message))


def validate(alias_table: dict[str, Any], v2: dict[str, Any], proposal: dict[str, Any]) -> V021ValidationReport:
    issues: list[V021Issue] = []

    if alias_table.get("schema_version") != "kernel_alias_table.v1":
        issue(issues, "error", "ALIAS_TABLE_SCHEMA", "Expected kernel_alias_table.v1.")

    if v2.get("schema_version") != "kernel_name_resolution_report_v2.v1":
        issue(issues, "error", "V2_SCHEMA", "Expected kernel_name_resolution_report_v2.v1.")

    if proposal.get("schema_version") != "kernel_gap_contract_update_proposal.v1":
        issue(issues, "error", "PROPOSAL_SCHEMA", "Expected kernel_gap_contract_update_proposal.v1.")

    for obj_name, obj in [
        ("alias_table", alias_table),
        ("v2", v2),
        ("proposal", proposal),
    ]:
        if obj.get("llm_annotations") != []:
            issue(issues, "error", "LLM_ANNOTATIONS_NOT_EMPTY", f"{obj_name} must not contain LLM annotations.")
        policy = obj.get("policy", {})
        if policy.get("deterministic_only") is not True:
            issue(issues, "error", "POLICY_NOT_DETERMINISTIC", f"{obj_name} must be deterministic_only.")
        if policy.get("llm_used") is not False:
            issue(issues, "error", "LLM_USED", f"{obj_name} must not use LLM.")
        if policy.get("contract_state_changed") is not False:
            issue(issues, "error", "CONTRACT_STATE_CHANGED", f"{obj_name} must not change contract state.")
        if policy.get("gap_state_changed") is not False:
            issue(issues, "error", "GAP_STATE_CHANGED", f"{obj_name} must not change gap state.")
        if policy.get("generator_unlock_allowed") is not False:
            issue(issues, "error", "GENERATOR_UNLOCK_ALLOWED", f"{obj_name} must not unlock generator.")

    alias_summary = alias_table.get("summary", {})
    aliases = alias_table.get("aliases", [])
    if int(alias_summary.get("num_aliases") or -1) != len(aliases):
        issue(issues, "error", "ALIAS_COUNT_MISMATCH", "Alias summary count mismatch.")

    if int(alias_summary.get("num_aliases") or 0) <= 0:
        issue(issues, "error", "NO_ALIASES", "Expected at least one alias candidate from v0.0.20 diagnosis.")

    seen_alias_ids = set()
    seen_sources = set()
    for entry in aliases:
        aid = entry.get("alias_id")
        if aid in seen_alias_ids:
            issue(issues, "error", "DUPLICATE_ALIAS_ID", f"Duplicate alias id: {aid}")
        seen_alias_ids.add(aid)

        src = entry.get("source", {}).get("normalized")
        tgt = entry.get("target", {}).get("normalized")
        if not src or not tgt:
            issue(issues, "error", "ALIAS_ENDPOINT_MISSING", f"Alias {aid} missing source/target normalized names.")
        if src in seen_sources:
            issue(issues, "error", "DUPLICATE_ALIAS_SOURCE", f"Duplicate alias source: {src}")
        seen_sources.add(src)

        if entry.get("llm_used") is not False:
            issue(issues, "error", "ALIAS_LLM_USED", f"Alias {aid} must not use LLM.")
        if entry.get("requires_validator_before_contract_update") is not True:
            issue(issues, "error", "ALIAS_VALIDATOR_REQUIRED", f"Alias {aid} must require validator before contract update.")
        sim = entry.get("evidence", {}).get("nearest_declared_similarity")
        if not isinstance(sim, (int, float)) or float(sim) < 0.72:
            issue(issues, "error", "ALIAS_SIMILARITY_LOW", f"Alias {aid} similarity too low: {sim!r}")

    v2_summary = v2.get("summary", {})
    if int(v2_summary.get("num_total_matches") or 0) != int(v2_summary.get("num_v1_matches") or 0) + int(v2_summary.get("num_v2_alias_matches") or 0):
        issue(issues, "error", "V2_MATCH_TOTAL_MISMATCH", "V2 total matches must equal v1 + alias matches.")

    if int(v2_summary.get("num_v2_alias_matches") or 0) != int(alias_summary.get("num_aliases") or 0):
        issue(issues, "warning", "ALIAS_MATCH_COUNT_DIFFERS", "Some aliases may not have produced v2 matches.")

    if v2_summary.get("generator_unlock_allowed") is not False:
        issue(issues, "error", "V2_UNLOCK_ALLOWED", "V2 report must not unlock generator.")

    if v2.get("gap_transition_proposal", {}).get("generator_unlock_allowed") is not False:
        issue(issues, "error", "V2_TRANSITION_UNLOCK_ALLOWED", "V2 transition proposal must not unlock generator.")

    all_resolved = bool(v2_summary.get("all_configured_resolved"))
    proposal_summary = proposal.get("summary", {})
    delta = proposal.get("proposed_contract_delta", {})

    if proposal_summary.get("all_configured_resolved") != all_resolved:
        issue(issues, "error", "PROPOSAL_ALL_RESOLVED_MISMATCH", "Proposal all_configured_resolved mismatch.")

    if all_resolved:
        if proposal.get("proposal_state") != "ready_for_contract_patch_review":
            issue(issues, "error", "PROPOSAL_STATE_EXPECT_READY", "Resolved v2 should create ready_for_contract_patch_review proposal.")
        if "GAP-KERNEL-NAME-001" not in delta.get("remove_from_blocking_gap_ids", []):
            issue(issues, "error", "KERNEL_GAP_NOT_REMOVED_IN_DELTA", "Resolved v2 should propose removing GAP-KERNEL-NAME-001 from blocking list.")
    else:
        if proposal.get("proposal_state") != "not_ready_gap_remains_blocking":
            issue(issues, "error", "PROPOSAL_STATE_EXPECT_NOT_READY", "Partial v2 should keep proposal not ready.")
        if delta.get("remove_from_blocking_gap_ids"):
            issue(issues, "error", "PARTIAL_SHOULD_NOT_REMOVE_GAP", "Partial v2 must not remove blocking gap.")

    if delta.get("migration_allowed_after_this_single_gap_update") is not False:
        issue(issues, "error", "MIGRATION_ALLOWED_BY_SINGLE_GAP", "Single kernel-name update must not allow full migration.")

    if proposal_summary.get("generator_unlock_allowed") is not False:
        issue(issues, "error", "PROPOSAL_UNLOCK_ALLOWED", "Proposal must not unlock generator.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return V021ValidationReport(
        status=status,
        issues=issues,
        summary={
            "alias_schema": alias_table.get("schema_version"),
            "v2_schema": v2.get("schema_version"),
            "proposal_schema": proposal.get("schema_version"),
            "num_aliases": alias_summary.get("num_aliases"),
            "num_v1_matches": v2_summary.get("num_v1_matches"),
            "num_v2_alias_matches": v2_summary.get("num_v2_alias_matches"),
            "num_total_matches": v2_summary.get("num_total_matches"),
            "num_unresolved_configured": v2_summary.get("num_unresolved_configured"),
            "all_configured_resolved": v2_summary.get("all_configured_resolved"),
            "proposal_state": proposal.get("proposal_state"),
            "remove_from_blocking_gap_ids": delta.get("remove_from_blocking_gap_ids"),
            "remaining_blocking_count": delta.get("remaining_blocking_count"),
            "generator_unlock_allowed": False,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate kernel alias table and resolver v2 outputs v0.0.21")
    parser.add_argument("--alias-table", required=True)
    parser.add_argument("--v2-report", required=True)
    parser.add_argument("--proposal", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    alias_table = load_json(args.alias_table)
    v2 = load_json(args.v2_report)
    proposal = load_json(args.proposal)

    report = validate(alias_table, v2, proposal)
    report.save(args.out)

    print(f"[xporthls] Kernel Alias/Resolver v2 validation written to: {args.out}")
    print(f"[xporthls] Kernel Alias/Resolver v2 validation status: {report.status}")
    for i in report.issues:
        print(f"  - {i.severity.upper()} {i.code}: {i.message}")
    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
