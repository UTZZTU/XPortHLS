#!/usr/bin/env bash
set -e

echo "[1/7] Add contracts package"

mkdir -p xporthls/contracts
touch xporthls/contracts/__init__.py

cat > xporthls/contracts/build_contract_v1.py <<'EOT'
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from xporthls.ir.platform_ir import PlatformIR


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def index_sync_by_buffer(sync_operations: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for sync in sync_operations:
        buf = sync.get("buffer")
        if buf:
            out.setdefault(buf, []).append(sync)
    return out


def index_transfer_by_buffer(host_transfers: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for transfer in host_transfers:
        buf = transfer.get("buffer")
        if buf:
            out.setdefault(buf, []).append(transfer)
    return out


def build_execution_policy(app: dict[str, Any], platform: PlatformIR) -> dict[str, Any]:
    case = app.get("case_metadata", {}) or {}

    return {
        "schema_version": "execution_policy.v1",
        "policy_id": f"{case.get('case_id', app.get('project', 'unknown'))}_to_{platform.platform_id}",
        "case_id": case.get("case_id", app.get("project", "unknown")),
        "target_platform": platform.platform_id,
        "target_ecosystem": platform.target.get("ecosystem") or "AVED",
        "mode": "deterministic_pipeline_only",
        "llm_enabled": False,
        "reason": "LLM integration is intentionally disabled until ModelAdapter, Evidence Ledger, Budget Ledger and Agent Loop are implemented.",
        "validation_sequence": [
            "L0-pre",
            "generate",
            "L0-post",
            "L1-csim",
            "L2-cosim",
            "L3-synth",
            "L4-implementation",
            "L5-hardware"
        ],
        "budget": {
            "max_agent_iterations": 0,
            "max_llm_calls": 0,
            "max_patch_attempts": 0,
            "tool_budget_placeholders": {
                "csim": None,
                "cosim": None,
                "synth": None,
                "implementation": None
            }
        },
        "patch_policy": {
            "enabled": False,
            "reason": "PatchController and Agent Loop are not implemented yet.",
            "allowed_files": [],
            "requires_validation_after_patch": True
        },
        "evidence_policy": {
            "record_artifacts": True,
            "record_validation_reports": True,
            "record_budget_usage": True,
            "record_patch_ledger": True
        }
    }


def build_contract(app: dict[str, Any], platform: PlatformIR, policy_path: str | None) -> dict[str, Any]:
    case = app.get("case_metadata", {}) or {}
    facts = app.get("facts", {}) or {}
    xrt_facts = facts.get("xrt", {}) if isinstance(facts, dict) else {}
    hls_facts = facts.get("hls", {}) if isinstance(facts, dict) else {}
    build_facts = facts.get("build", {}) if isinstance(facts, dict) else {}

    buffers = app.get("buffers", []) or xrt_facts.get("buffers", [])
    host_transfers = app.get("host_transfers", []) or xrt_facts.get("host_transfers", [])
    sync_operations = app.get("sync_operations", []) or xrt_facts.get("sync_operations", [])
    kernel_invocations = app.get("kernel_invocations", []) or xrt_facts.get("kernel_invocations", [])
    run_waits = app.get("run_waits", []) or xrt_facts.get("run_waits", [])
    kernel_candidates = app.get("kernels", []) or hls_facts.get("kernel_candidates", [])
    build_targets = app.get("build_targets", []) or build_facts.get("targets", [])

    sync_by_buffer = index_sync_by_buffer(sync_operations)
    transfer_by_buffer = index_transfer_by_buffer(host_transfers)

    buffer_roles = []
    for buf in buffers:
        name = buf.get("name")
        syncs = sync_by_buffer.get(name, [])
        transfers = transfer_by_buffer.get(name, [])

        directions = sorted({s.get("direction") for s in syncs if s.get("direction")})
        operations = sorted({t.get("operation") for t in transfers if t.get("operation")})

        role = "unknown"
        if "host_to_device" in directions:
            role = "input"
        if "device_to_host" in directions:
            role = "output"
        if "host_to_device" in directions and "device_to_host" in directions:
            role = "inout"

        buffer_roles.append({
            "name": name,
            "role": role,
            "size_expr": buf.get("size_expr"),
            "group_id": buf.get("group_id"),
            "sync_directions": directions,
            "host_operations": operations,
            "evidence": {
                "allocation": buf.get("evidence"),
                "syncs": [s.get("evidence") for s in syncs],
                "transfers": [t.get("evidence") for t in transfers]
            }
        })

    scalar_args = []
    for inv in kernel_invocations:
        for arg in inv.get("scalar_args", []):
            if arg not in scalar_args:
                scalar_args.append(arg)

    target_ecosystem = platform.target.get("ecosystem") or "AVED"

    contract = {
        "schema_version": "migration_contract.v1",
        "state": "Proposed",
        "source_project": app.get("project", case.get("case_id", "unknown")),
        "case_id": case.get("case_id", app.get("project", "unknown")),
        "source_runtime": app.get("source_runtime", "XRT"),
        "target_platform": platform.platform_id,
        "target_ecosystem": target_ecosystem,
        "target_board": platform.target.get("board") or platform.board,
        "target_tool_flow": platform.target.get("tool_flow") or platform.tool_flow,
        "target_tool_version": platform.target.get("tool_version") or platform.tool_version,
        "platform_pack": {
            "platform_id": platform.platform_id,
            "name": platform.name,
            "status": platform.status,
            "source_kind": platform.source_kind,
            "pack_path": platform.pack_path,
            "aved_release": platform.aved_release
        },
        "execution_policy_ref": policy_path,
        "contract_states": {
            "allowed": ["Proposed", "StaticallyChecked", "RuntimeValidated"],
            "current": "Proposed",
            "next_required_validation": "L0-pre"
        },
        "contracts": {
            "functional": {
                "kind": "FunctionalContract",
                "goal": "Preserve source application behavior.",
                "golden": case.get("golden", {}),
                "test_entries": app.get("test_entries", []),
                "status": "Proposed"
            },
            "interface": {
                "kind": "InterfaceContract",
                "source_runtime": app.get("source_runtime", "XRT"),
                "target_ecosystem": target_ecosystem,
                "kernel_invocations": kernel_invocations,
                "kernel_candidates": kernel_candidates,
                "run_waits": run_waits,
                "status": "Proposed"
            },
            "memory": {
                "kind": "MemoryContract",
                "memory_type": case.get("memory_type", "unknown"),
                "num_buffers": len(buffers),
                "buffer_roles": buffer_roles,
                "rules_source": "Platform Pack memory_rules.json",
                "status": "Proposed"
            },
            "qdma": {
                "kind": "QdmaContract",
                "num_host_transfers": len(host_transfers),
                "num_sync_operations": len(sync_operations),
                "host_transfers": host_transfers,
                "sync_operations": sync_operations,
                "rules_source": "Platform Pack qdma_rules.json",
                "status": "Proposed"
            },
            "control": {
                "kind": "ControlContract",
                "scalar_args": scalar_args,
                "kernel_invocations": kernel_invocations,
                "rules_source": "Platform Pack register_rules.json",
                "status": "Proposed"
            },
            "build": {
                "kind": "BuildContract",
                "build_targets": build_targets,
                "target_tool_flow": platform.target.get("tool_flow") or platform.tool_flow,
                "target_tool_version": platform.target.get("tool_version") or platform.tool_version,
                "status": "Proposed"
            },
            "validation": {
                "kind": "ValidationContract",
                "required_sequence": ["L0-pre", "L0-post"],
                "future_sequence": ["L1-csim", "L2-cosim", "L3-synth", "L4-implementation", "L5-hardware"],
                "status": "Proposed"
            }
        },
        "obligations": [
            {
                "kind": "preserve_functionality",
                "contract": "functional",
                "status": "Proposed"
            },
            {
                "kind": "remove_xrt_runtime_dependency",
                "contract": "interface",
                "from": app.get("source_runtime", "XRT"),
                "to": target_ecosystem,
                "status": "Proposed"
            },
            {
                "kind": "map_xrt_buffers_to_platform_memory",
                "contract": "memory",
                "num_buffers": len(buffers),
                "status": "Proposed"
            },
            {
                "kind": "map_xrt_sync_to_qdma_transfers",
                "contract": "qdma",
                "num_sync_operations": len(sync_operations),
                "status": "Proposed"
            },
            {
                "kind": "validate_before_generation",
                "contract": "validation",
                "required": "L0-pre",
                "status": "Proposed"
            }
        ],
        "unknowns": app.get("unknowns", []),
        "warnings": [
            "MigrationContract v1 is structural and proposed. It must become StaticallyChecked after L0-pre.",
            "ExecutionPolicy is stored separately and referenced by execution_policy_ref."
        ]
    }

    return contract


def main() -> int:
    parser = argparse.ArgumentParser(description="Build XPortHLS MigrationContract v1 and ExecutionPolicy v1")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--policy-out", required=True)
    args = parser.parse_args()

    app = load_json(args.app_ir)
    platform = PlatformIR.load_json(args.platform)

    policy = build_execution_policy(app, platform)
    save_json(args.policy_out, policy)

    contract = build_contract(app, platform, args.policy_out)
    save_json(args.out, contract)

    print(f"[xporthls] MigrationContract v1 written to: {args.out}")
    print(f"[xporthls] ExecutionPolicy v1 written to: {args.policy_out}")
    print(f"[xporthls] Contract state: {contract['state']}")
    print(f"[xporthls] Target platform: {contract['target_platform']}")
    print(f"[xporthls] Target ecosystem: {contract['target_ecosystem']}")
    print(f"[xporthls] Obligations: {len(contract['obligations'])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add contract v1 validator"

cat > xporthls/contracts/validate_contract_v1.py <<'EOT'
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
EOT

echo "[3/7] Update README checklist"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

text = text.replace("### Phase 6 — MigrationContract v1\n\nStatus: planned.", "### Phase 6 — MigrationContract v1\n\nStatus: in progress.")
text = text.replace("- [ ] Add contract states: Proposed, StaticallyChecked, RuntimeValidated", "- [x] Add contract states: Proposed, StaticallyChecked, RuntimeValidated")
text = text.replace("- [ ] Add FunctionalContract", "- [x] Add FunctionalContract")
text = text.replace("- [ ] Add InterfaceContract", "- [x] Add InterfaceContract")
text = text.replace("- [ ] Add MemoryContract", "- [x] Add MemoryContract")
text = text.replace("- [ ] Add ControlContract", "- [x] Add ControlContract")
text = text.replace("- [ ] Add BuildContract", "- [x] Add BuildContract")
text = text.replace("- [ ] Add ValidationContract", "- [x] Add ValidationContract")
text = text.replace("- [ ] Keep ExecutionPolicy separate from MigrationContract", "- [x] Keep ExecutionPolicy separate from MigrationContract")
text = text.replace("- [ ] Allow Generator to read only StaticallyChecked contracts", "- [ ] Allow Generator to read only StaticallyChecked contracts")

p.write_text(text, encoding="utf-8")
PY

echo "[4/7] Create v0.0.8 replay script"

cat > add_contract_v1_v008_replay.sh <<'EOT'
#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"

echo "[v0.0.8] Python syntax check"

python3 -m py_compile \
  xporthls/contracts/build_contract_v1.py \
  xporthls/contracts/validate_contract_v1.py \
  xporthls/ir/platform_ir.py \
  xporthls/platforms/platform_pack.py \
  xporthls/cli.py

echo "[v0.0.8] Prepare ApplicationIR"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v008.json

echo "[v0.0.8] Build MigrationContract v1 + ExecutionPolicy v1"

python3 -m xporthls.contracts.build_contract_v1 \
  --app-ir experiments/runs/light_ddr_application_ir_v008.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v008.json \
  --policy-out experiments/runs/light_ddr_execution_policy_v008.json

echo "[v0.0.8] Validate MigrationContract v1"

python3 -m xporthls.contracts.validate_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v008.json \
  --policy experiments/runs/light_ddr_execution_policy_v008.json \
  --out experiments/runs/light_ddr_contract_v1_report_v008.json

echo "[v0.0.8] Run existing L0-pre against MigrationContract v1"

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v008.json \
  --contract experiments/runs/light_ddr_migration_contract_v008.json \
  --out experiments/runs/light_ddr_l0_pre_report_v008.json

python3 - <<'PY'
import json

contract = json.load(open("experiments/runs/light_ddr_migration_contract_v008.json"))
policy = json.load(open("experiments/runs/light_ddr_execution_policy_v008.json"))
creport = json.load(open("experiments/runs/light_ddr_contract_v1_report_v008.json"))
l0 = json.load(open("experiments/runs/light_ddr_l0_pre_report_v008.json"))

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["state"])
print("Target platform:", contract["target_platform"])
print("Target ecosystem:", contract["target_ecosystem"])
print("Subcontracts:", sorted(contract["contracts"].keys()))
print("ExecutionPolicy schema:", policy["schema_version"])
print("ExecutionPolicy llm_enabled:", policy["llm_enabled"])
print("Contract validation:", creport["status"])
print("L0-pre status:", l0["status"])
print("L0-pre issues:", len(l0.get("issues", [])))

assert contract["schema_version"] == "migration_contract.v1"
assert contract["state"] == "Proposed"
assert contract["target_platform"] == "v80_aved_2025_1_stub"
assert contract["target_ecosystem"] == "AVED"
assert policy["schema_version"] == "execution_policy.v1"
assert policy["llm_enabled"] is False
assert creport["status"] == "pass"
assert l0["status"] == "pass"
assert len(l0.get("issues", [])) == 0
PY

echo
echo "DONE."
EOT

chmod +x add_contract_v1_v008_replay.sh

echo "[5/7] Run v0.0.8 replay"

./add_contract_v1_v008_replay.sh

echo "[6/7] Show git status"

git status

echo "[7/7] v0.0.8 completed locally"
