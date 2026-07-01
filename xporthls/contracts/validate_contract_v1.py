from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class ContractIssue:
    severity: str
    code: str
    message: str


@dataclass
class ContractValidationReport:
    status: str
    issues: list[ContractIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_contract(contract: dict[str, Any], policy: dict[str, Any] | None = None) -> ContractValidationReport:
    issues: list[ContractIssue] = []

    if contract.get("schema_version") != "migration_contract.v1":
        issues.append(ContractIssue("error", "CONTRACT_SCHEMA_VERSION", "Expected migration_contract.v1."))

    if contract.get("state") not in {"Proposed", "StaticallyChecked", "RuntimeValidated"}:
        issues.append(ContractIssue("error", "CONTRACT_STATE_INVALID", f"Invalid contract state: {contract.get('state')}"))

    for key in ["source_project", "target_platform", "target_ecosystem", "obligations", "contracts"]:
        if key not in contract:
            issues.append(ContractIssue("error", "CONTRACT_REQUIRED_FIELD_MISSING", f"Missing required field: {key}"))

    contracts = contract.get("contracts", {})
    required_subcontracts = ["functional", "interface", "memory", "qdma", "control", "build", "validation"]

    if not isinstance(contracts, dict):
        issues.append(ContractIssue("error", "CONTRACTS_NOT_OBJECT", "contracts must be an object."))
    else:
        for name in required_subcontracts:
            if name not in contracts:
                issues.append(ContractIssue("error", "SUBCONTRACT_MISSING", f"Missing subcontract: {name}"))

    obligations = contract.get("obligations", [])
    if not isinstance(obligations, list) or not obligations:
        issues.append(ContractIssue("error", "OBLIGATIONS_EMPTY", "Contract must include non-empty obligations list."))

    if contract.get("unknowns"):
        issues.append(ContractIssue("warning", "CONTRACT_HAS_UNKNOWNS", f"Contract contains {len(contract.get('unknowns', []))} unknowns."))

    if policy is not None:
        if policy.get("schema_version") != "execution_policy.v1":
            issues.append(ContractIssue("error", "POLICY_SCHEMA_VERSION", "Expected execution_policy.v1."))

        if policy.get("target_platform") != contract.get("target_platform"):
            issues.append(ContractIssue("error", "POLICY_TARGET_PLATFORM_MISMATCH", "ExecutionPolicy target_platform differs from contract."))

        if policy.get("target_ecosystem") != contract.get("target_ecosystem"):
            issues.append(ContractIssue("error", "POLICY_TARGET_ECOSYSTEM_MISMATCH", "ExecutionPolicy target_ecosystem differs from contract."))

        if policy.get("llm_enabled") is not False:
            issues.append(ContractIssue("warning", "POLICY_LLM_NOT_DISABLED", "LLM should remain disabled in v0.0.8."))

        seq = policy.get("validation_sequence", [])
        if "L0-pre" not in seq or "L0-post" not in seq:
            issues.append(ContractIssue("error", "POLICY_VALIDATION_SEQUENCE_INCOMPLETE", "ExecutionPolicy must include L0-pre and L0-post."))

    has_error = any(issue.severity == "error" for issue in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return ContractValidationReport(
        status=status,
        issues=issues,
        summary={
            "schema_version": contract.get("schema_version"),
            "state": contract.get("state"),
            "source_project": contract.get("source_project"),
            "target_platform": contract.get("target_platform"),
            "target_ecosystem": contract.get("target_ecosystem"),
            "num_obligations": len(contract.get("obligations", [])),
            "subcontracts": sorted(list((contract.get("contracts", {}) or {}).keys())),
            "has_execution_policy": policy is not None,
            "policy_schema_version": policy.get("schema_version") if policy else None
        }
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate MigrationContract v1")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--policy", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contract = load_json(args.contract)
    policy = load_json(args.policy) if args.policy else None

    report = validate_contract(contract, policy)
    report.save(args.out)

    print(f"[xporthls] Contract v1 validation report written to: {args.out}")
    print(f"[xporthls] Contract v1 validation status: {report.status}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
