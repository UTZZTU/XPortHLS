from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class TargetReferenceIssue:
    severity: str
    code: str
    message: str


@dataclass
class TargetReferenceValidationReport:
    schema_version: str = "target_reference_validation_report.v1"
    xporthls_version: str = "v0.0.24"
    status: str = "fail"
    issues: list[TargetReferenceIssue] = field(default_factory=list)
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


def add_issue(issues: list[TargetReferenceIssue], severity: str, code: str, message: str) -> None:
    issues.append(TargetReferenceIssue(severity=severity, code=code, message=message))


def validate_target_reference(ir: dict[str, Any], guard_report: dict[str, Any] | None = None) -> TargetReferenceValidationReport:
    issues: list[TargetReferenceIssue] = []

    if ir.get("schema_version") != "target_reference_ir.v1":
        add_issue(issues, "error", "SCHEMA", "Expected target_reference_ir.v1.")

    if ir.get("xporthls_version") != "v0.0.24":
        add_issue(issues, "error", "VERSION", "Expected xporthls_version v0.0.24.")

    if ir.get("migration_direction") != "XRT->AVED":
        add_issue(issues, "error", "MIGRATION_DIRECTION", "Expected migration_direction XRT->AVED.")

    if ir.get("target_ecosystem") != "AVED":
        add_issue(issues, "error", "TARGET_ECOSYSTEM", "Expected target_ecosystem AVED.")

    if ir.get("target_board") != "V80":
        add_issue(issues, "error", "TARGET_BOARD", "Expected target_board V80.")

    if ir.get("llm_annotations") != []:
        add_issue(issues, "error", "LLM_ANNOTATIONS", "v0.0.24 target reference facts must not contain LLM annotations.")

    tb = ir.get("trust_boundary", {})
    for key in ["llm_used", "contract_modified", "migration_allowed_modified", "generator_unlocked"]:
        if tb.get(key) is not False:
            add_issue(issues, "error", "TRUST_BOUNDARY", f"Trust boundary flag must be false: {key}")

    if tb.get("target_reference_requires_validation_before_resolver_rule") is not True:
        add_issue(issues, "error", "REFERENCE_VALIDATION_REQUIRED", "Target reference evidence must require validation before becoming resolver rule.")

    repo = ir.get("repository_summary", {})
    if repo.get("files_total", 0) <= 0:
        add_issue(issues, "error", "NO_FILES", "Target reference repository has no files.")

    if repo.get("documentation_files", 0) <= 0:
        add_issue(issues, "warning", "NO_DOCS", "No documentation files found in target reference.")

    docs = ir.get("documentation_index", {})
    if docs.get("num_documents", 0) <= 0:
        add_issue(issues, "warning", "DOC_INDEX_EMPTY", "Documentation index is empty.")

    variants = ir.get("variant_index", {})
    if variants.get("num_variants", 0) <= 0:
        add_issue(issues, "warning", "NO_VARIANTS", "No variant.yaml files found. Target reference may be incomplete or layout changed.")

    host = ir.get("host_runtime_pattern", {}).get("summary", {})
    if host.get("qdma_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_QDMA_EVIDENCE", "No QDMA host evidence found.")
    if host.get("axi_lite_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_AXI_LITE_EVIDENCE", "No AXI-Lite host evidence found.")
    if host.get("ap_ctrl_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_AP_CTRL_EVIDENCE", "No AP_CTRL host evidence found.")

    hls = ir.get("hls_ip_packaging_pattern", {}).get("summary", {})
    if hls.get("m_axi_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_M_AXI_EVIDENCE", "No HLS m_axi evidence found.")
    if hls.get("axis_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_AXIS_EVIDENCE", "No HLS axis evidence found.")
    if hls.get("packaging_evidence_count", 0) <= 0:
        add_issue(issues, "warning", "NO_HLS_PACKAGING_EVIDENCE", "No HLS IP packaging evidence found.")

    vivado = ir.get("vivado_aved_project_pattern", {})
    if vivado.get("create_design_tcl_count", 0) <= 0:
        add_issue(issues, "warning", "NO_CREATE_DESIGN_TCL", "No create_design.tcl found.")
    if vivado.get("create_bd_design_tcl_count", 0) <= 0:
        add_issue(issues, "warning", "NO_CREATE_BD_DESIGN_TCL", "No create_bd_design.tcl found.")

    bd = ir.get("bd_tcl_pattern", {}).get("command_counts", {})
    if bd.get("connect_bd_intf_net", 0) <= 0:
        add_issue(issues, "warning", "NO_BD_INTF_CONNECTIONS", "No connect_bd_intf_net evidence found.")
    if bd.get("assign_bd_address", 0) <= 0:
        add_issue(issues, "warning", "NO_BD_ADDRESS_ASSIGNMENT", "No assign_bd_address evidence found.")

    mem = ir.get("hbm_pc_address_map", {}).get("summary", {})
    if mem.get("candidate_file_count", 0) <= 0:
        add_issue(issues, "warning", "NO_MEMORY_CANDIDATES", "No HBM/PC memory candidate files found.")

    stream = ir.get("stream_connection_pattern", {}).get("summary", {})
    if stream.get("axis_term_count", 0) <= 0 and stream.get("connect_bd_intf_net_count", 0) <= 0:
        add_issue(issues, "warning", "NO_STREAM_EVIDENCE", "No stream/AXIS evidence found.")

    fixes = ir.get("known_correctness_fixes", {}).get("summary", {})
    if fixes.get("has_f_version_correctness") is not True:
        add_issue(issues, "warning", "NO_F_VERSION_CORRECTNESS", "No F_VERSION_CORRECTNESS evidence found. Confirm shuffler fix documentation is present.")

    manual_ops = ir.get("manual_operation_trace", {}).get("operations", [])
    if len(manual_ops) <= 0:
        add_issue(issues, "warning", "NO_MANUAL_OPERATION_TRACE", "No inferred manual operation trace entries found.")

    summary = ir.get("summary", {})
    if summary.get("contract_modified") is not False:
        add_issue(issues, "error", "CONTRACT_MODIFIED", "v0.0.24 must not modify the gap contract.")
    if summary.get("generator_unlock_allowed") is not False:
        add_issue(issues, "error", "GENERATOR_UNLOCK", "v0.0.24 must not unlock generation.")
    if summary.get("llm_used") is not False:
        add_issue(issues, "error", "LLM_USED", "v0.0.24 target reference intake must not use LLM.")

    if guard_report is not None:
        if guard_report.get("schema_version") != "generator_guard_report.v1":
            add_issue(issues, "error", "GUARD_SCHEMA", "Expected generator_guard_report.v1.")
        if guard_report.get("decision", {}).get("blocked") is not True:
            add_issue(issues, "error", "GUARD_NOT_BLOCKED", "Generator guard must remain blocked.")
        if guard_report.get("decision", {}).get("allowed") is not False:
            add_issue(issues, "error", "GUARD_ALLOWED", "Generator guard must not allow generation.")
        if "GAP-KERNEL-NAME-001" in guard_report.get("summary", {}).get("blocking_gap_ids", []):
            add_issue(issues, "error", "RESOLVED_GAP_BLOCKING", "GAP-KERNEL-NAME-001 should not reappear in patched guard blockers.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return TargetReferenceValidationReport(
        status=status,
        issues=issues,
        summary={
            "target_reference_schema": ir.get("schema_version"),
            "migration_direction": ir.get("migration_direction"),
            "target_ecosystem": ir.get("target_ecosystem"),
            "target_board": ir.get("target_board"),
            "files_total": repo.get("files_total"),
            "documentation_files": repo.get("documentation_files"),
            "variant_count": variants.get("num_variants"),
            "host_qdma_evidence_count": host.get("qdma_evidence_count"),
            "host_axi_lite_evidence_count": host.get("axi_lite_evidence_count"),
            "host_ap_ctrl_evidence_count": host.get("ap_ctrl_evidence_count"),
            "hls_m_axi_evidence_count": hls.get("m_axi_evidence_count"),
            "hls_axis_evidence_count": hls.get("axis_evidence_count"),
            "hls_packaging_evidence_count": hls.get("packaging_evidence_count"),
            "create_design_tcl_count": vivado.get("create_design_tcl_count"),
            "create_bd_design_tcl_count": vivado.get("create_bd_design_tcl_count"),
            "bd_connect_bd_intf_net_count": bd.get("connect_bd_intf_net", 0),
            "bd_assign_bd_address_count": bd.get("assign_bd_address", 0),
            "manual_operation_count": len(manual_ops),
            "has_f_version_correctness": fixes.get("has_f_version_correctness"),
            "llm_used": summary.get("llm_used"),
            "contract_modified": summary.get("contract_modified"),
            "generator_unlock_allowed": summary.get("generator_unlock_allowed"),
            "guard_blocked": guard_report.get("decision", {}).get("blocked") if guard_report else None,
            "num_errors": sum(1 for i in issues if i.severity == "error"),
            "num_warnings": sum(1 for i in issues if i.severity == "warning"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate target reference IR v0.0.24")
    parser.add_argument("--target-reference-ir", required=True)
    parser.add_argument("--guard-report", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    ir = load_json(args.target_reference_ir)
    guard = load_json(args.guard_report) if args.guard_report else None
    report = validate_target_reference(ir, guard)
    report.save(args.out)

    print(f"[xporthls] Target reference validation: {args.out}")
    print(f"[xporthls] Validation status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
