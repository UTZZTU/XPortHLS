#!/usr/bin/env bash
set -e

echo "[1/5] Upgrade ApplicationIR to v1 facts/annotations/unknowns"

cat > xporthls/ir/application_ir.py <<'EOT'
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any
import json


@dataclass
class SourceFile:
    path: str
    kind: str


@dataclass
class XrtCall:
    file: str
    line: int
    expression: str
    api: str


@dataclass
class LlmAnnotation:
    field: str
    value: Any
    source: str = "llm"
    confidence: float | None = None
    evidence: list[str] = field(default_factory=list)
    requires_validation: bool = True


@dataclass
class ApplicationIR:
    """
    ApplicationIR v1.

    Design principle:
    - facts: extracted by deterministic scanners/parsers/tools.
    - llm_annotations: optional candidate semantic hints; never overwrite facts.
    - unknowns: unresolved fields requiring validation, fallback, or user/tool evidence.

    For backward compatibility, top-level legacy fields are still kept.
    """

    project: str
    source_runtime: str = "XRT"

    # Legacy/top-level fields kept for compatibility.
    source_files: list[SourceFile] = field(default_factory=list)
    kernels: list[dict[str, Any]] = field(default_factory=list)
    host_apis: list[XrtCall] = field(default_factory=list)

    buffers: list[dict[str, Any]] = field(default_factory=list)
    memory_groups: list[dict[str, Any]] = field(default_factory=list)
    host_transfers: list[dict[str, Any]] = field(default_factory=list)
    sync_operations: list[dict[str, Any]] = field(default_factory=list)
    kernel_objects: list[dict[str, Any]] = field(default_factory=list)
    kernel_invocations: list[dict[str, Any]] = field(default_factory=list)
    run_waits: list[dict[str, Any]] = field(default_factory=list)

    build_targets: list[dict[str, Any]] = field(default_factory=list)
    test_entries: list[dict[str, Any]] = field(default_factory=list)
    connectivity: list[dict[str, Any]] = field(default_factory=list)

    # v1 trust-boundary fields.
    llm_annotations: list[dict[str, Any]] = field(default_factory=list)
    unknowns: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def build_facts(self) -> dict[str, Any]:
        return {
            "schema_version": "application_ir.v1",
            "project": self.project,
            "source_runtime": self.source_runtime,
            "source_files": [asdict(x) for x in self.source_files],
            "xrt": {
                "host_apis": [asdict(x) for x in self.host_apis],
                "kernel_objects": self.kernel_objects,
                "buffers": self.buffers,
                "host_transfers": self.host_transfers,
                "sync_operations": self.sync_operations,
                "kernel_invocations": self.kernel_invocations,
                "run_waits": self.run_waits,
                "memory_groups": self.memory_groups,
            },
            "hls": {
                "kernel_candidates": self.kernels,
                "connectivity": self.connectivity,
            },
            "build": {
                "targets": self.build_targets,
            },
            "tests": {
                "entries": self.test_entries,
            },
        }

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["facts"] = self.build_facts()
        return data

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.to_json())
            f.write("\n")
EOT

echo "[2/5] Add ApplicationIR schema checker"

cat > xporthls/ir/schema_checks.py <<'EOT'
from __future__ import annotations

from typing import Any


def check_application_ir_schema(app: dict[str, Any]) -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []

    facts = app.get("facts")
    if not isinstance(facts, dict):
        issues.append({
            "severity": "error",
            "code": "APP_IR_NO_FACTS",
            "message": "ApplicationIR v1 requires a facts object."
        })
        return issues

    if facts.get("schema_version") != "application_ir.v1":
        issues.append({
            "severity": "warning",
            "code": "APP_IR_SCHEMA_VERSION_UNKNOWN",
            "message": f"Unexpected ApplicationIR schema version: {facts.get('schema_version')}"
        })

    for key in ["xrt", "hls", "build", "tests"]:
        if key not in facts or not isinstance(facts[key], dict):
            issues.append({
                "severity": "error",
                "code": f"APP_IR_FACTS_MISSING_{key.upper()}",
                "message": f"ApplicationIR facts.{key} is missing or not an object."
            })

    if not isinstance(app.get("llm_annotations", []), list):
        issues.append({
            "severity": "error",
            "code": "APP_IR_LLM_ANNOTATIONS_NOT_LIST",
            "message": "ApplicationIR llm_annotations must be a list."
        })

    if not isinstance(app.get("unknowns", []), list):
        issues.append({
            "severity": "error",
            "code": "APP_IR_UNKNOWNS_NOT_LIST",
            "message": "ApplicationIR unknowns must be a list."
        })

    # Safety rule: LLM annotations must be marked as annotations, not facts.
    for idx, ann in enumerate(app.get("llm_annotations", [])):
        if not isinstance(ann, dict):
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_NOT_OBJECT",
                "message": f"llm_annotations[{idx}] is not an object."
            })
            continue

        if ann.get("source") != "llm":
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_SOURCE",
                "message": f"llm_annotations[{idx}] should explicitly use source='llm'."
            })

        if "requires_validation" not in ann:
            issues.append({
                "severity": "warning",
                "code": "APP_IR_LLM_ANNOTATION_VALIDATION_FLAG",
                "message": f"llm_annotations[{idx}] should include requires_validation."
            })

    return issues
EOT

echo "[3/5] Update L0 checker to validate ApplicationIR v1"

cat > xporthls/validators/l0_static_checker.py <<'EOT'
from __future__ import annotations

import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any

from xporthls.ir.schema_checks import check_application_ir_schema


@dataclass
class L0Issue:
    severity: str
    code: str
    message: str


@dataclass
class L0Report:
    status: str
    issues: list[L0Issue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def run_l0_static(app_ir_path: str, contract_path: str | None = None) -> L0Report:
    with open(app_ir_path, "r", encoding="utf-8") as f:
        app = json.load(f)

    contract = None
    if contract_path:
        with open(contract_path, "r", encoding="utf-8") as f:
            contract = json.load(f)

    issues: list[L0Issue] = []

    for issue in check_application_ir_schema(app):
        issues.append(L0Issue(
            severity=issue["severity"],
            code=issue["code"],
            message=issue["message"]
        ))

    source_files = app.get("source_files", [])
    host_apis = app.get("host_apis", [])
    kernels = app.get("kernels", [])
    build_targets = app.get("build_targets", [])
    buffers = app.get("buffers", [])
    kernel_invocations = app.get("kernel_invocations", [])
    sync_operations = app.get("sync_operations", [])
    host_transfers = app.get("host_transfers", [])
    unknowns = app.get("unknowns", [])
    facts = app.get("facts", {})

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if host_apis and not buffers:
        issues.append(L0Issue("warning", "NO_XRT_BUFFERS", "XRT API calls were detected, but no xrt::bo buffers were extracted."))

    if buffers and not kernel_invocations:
        issues.append(L0Issue("warning", "NO_KERNEL_INVOCATION", "Buffers were detected, but no kernel invocation was extracted."))

    if buffers and not sync_operations:
        issues.append(L0Issue("warning", "NO_SYNC_OPERATIONS", "Buffers were detected, but no bo.sync operations were extracted."))

    if buffers and not host_transfers:
        issues.append(L0Issue("warning", "NO_HOST_TRANSFERS", "Buffers were detected, but no bo.write/bo.read operations were extracted."))

    if unknowns:
        issues.append(L0Issue("warning", "IR_UNKNOWNS_PRESENT", f"ApplicationIR contains {len(unknowns)} unknown semantic fields."))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))

    if facts:
        xrt_facts = facts.get("xrt", {})
        if len(xrt_facts.get("buffers", [])) != len(buffers):
            issues.append(L0Issue(
                "error",
                "FACTS_BUFFER_MISMATCH",
                "facts.xrt.buffers length does not match top-level buffers length."
            ))

        if len(xrt_facts.get("kernel_invocations", [])) != len(kernel_invocations):
            issues.append(L0Issue(
                "error",
                "FACTS_KERNEL_INVOCATION_MISMATCH",
                "facts.xrt.kernel_invocations length does not match top-level kernel_invocations length."
            ))

    if contract is not None:
        if not contract.get("obligations"):
            issues.append(L0Issue("error", "NO_CONTRACT_OBLIGATIONS", "MigrationContract has no obligations."))
        if not contract.get("target_platform"):
            issues.append(L0Issue("error", "NO_TARGET_PLATFORM", "MigrationContract has no target platform."))

    has_error = any(issue.severity == "error" for issue in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return L0Report(
        status=status,
        issues=issues,
        summary={
            "project": app.get("project", "unknown"),
            "schema_version": facts.get("schema_version", "unknown") if isinstance(facts, dict) else "missing",
            "num_source_files": len(source_files),
            "num_xrt_calls": len(host_apis),
            "num_kernel_candidates": len(kernels),
            "num_build_targets": len(build_targets),
            "num_buffers": len(buffers),
            "num_kernel_invocations": len(kernel_invocations),
            "num_sync_operations": len(sync_operations),
            "num_host_transfers": len(host_transfers),
            "num_unknowns": len(unknowns),
            "has_facts": isinstance(facts, dict) and bool(facts),
            "has_contract": contract is not None,
        },
    )
EOT

echo "[4/5] Update CLI scan summary for ApplicationIR v1"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/cli.py")
text = path.read_text(encoding="utf-8")

needle = '''    print(f"[xporthls] Unknowns: {len(ir.unknowns)}")
    if ir.warnings:
'''

replacement = '''    print(f"[xporthls] Unknowns: {len(ir.unknowns)}")
    print("[xporthls] ApplicationIR schema: application_ir.v1")
    if ir.warnings:
'''

if needle not in text:
    raise SystemExit("CLI summary block not found; no changes made.")

path.write_text(text.replace(needle, replacement), encoding="utf-8")
PY

echo "[5/5] Run scan + contract + L0"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v004.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v004.json \
  --platform config/platforms/v80_aved_2025_1_stub.json \
  --out experiments/runs/light_ddr_migration_contract_v004.json

python3 -m xporthls.validators.run_l0 \
  --app-ir experiments/runs/light_ddr_application_ir_v004.json \
  --contract experiments/runs/light_ddr_migration_contract_v004.json \
  --out experiments/runs/light_ddr_l0_report_v004.json

python3 - <<'PY'
import json

app_path = "experiments/runs/light_ddr_application_ir_v004.json"
report_path = "experiments/runs/light_ddr_l0_report_v004.json"

app = json.load(open(app_path))
report = json.load(open(report_path))

print()
print("ApplicationIR v1 quick check:")
print("schema_version:", app.get("facts", {}).get("schema_version"))
print("facts keys:", list(app.get("facts", {}).keys()))
print("facts.xrt keys:", list(app.get("facts", {}).get("xrt", {}).keys()))
print("llm_annotations:", len(app.get("llm_annotations", [])))
print("unknowns:", len(app.get("unknowns", [])))
print("L0 status:", report.get("status"))
PY

echo
echo "DONE."
echo "Check:"
echo "  cat experiments/runs/light_ddr_l0_report_v004.json"
echo "  git status"
