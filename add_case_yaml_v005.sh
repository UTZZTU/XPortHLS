#!/usr/bin/env bash
set -e

echo "[1/7] Add case.yaml for light_ddr"

cat > cases/light_ddr/case.yaml <<'EOT'
case_id: light_ddr
role: lightweight_fixture
description: Local lightweight XRT/Vitis HLS-style DDR fixture for XPortHLS development.
source_runtime: XRT
memory_type: DDR
complexity: low
host_entry: src/host.cpp
kernel_sources:
  - src/vadd.cpp
build_entry: Makefile
golden:
  type: json
  path: tests/golden.json
validation_targets:
  - L0
  - L1
tags:
  - single_kernel
  - ddr
  - xrt_host
  - hls_kernel
EOT

echo "[2/7] Add case config loader"

mkdir -p xporthls/cases
touch xporthls/cases/__init__.py

cat > xporthls/cases/case_config.py <<'EOT'
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any


def _parse_scalar(value: str) -> Any:
    v = value.strip()

    if v == "":
        return ""

    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]

    if v.lower() == "true":
        return True

    if v.lower() == "false":
        return False

    if v.lower() in {"null", "none"}:
        return None

    try:
        return int(v)
    except ValueError:
        pass

    try:
        return float(v)
    except ValueError:
        pass

    return v


def parse_simple_yaml(text: str) -> dict[str, Any]:
    """
    A tiny YAML subset parser for XPortHLS case.yaml files.

    Supported:
    - top-level key: value
    - top-level key:
        child: value
    - top-level key:
        - item
        - item

    This avoids adding PyYAML as a dependency during early project scaffolding.
    It is intentionally limited and should be replaced by PyYAML later if needed.
    """

    data: dict[str, Any] = {}
    current_key: str | None = None

    for raw in text.splitlines():
        if not raw.strip():
            continue

        stripped_no_comment = raw.split("#", 1)[0].rstrip()
        if not stripped_no_comment.strip():
            continue

        indent = len(stripped_no_comment) - len(stripped_no_comment.lstrip(" "))
        line = stripped_no_comment.strip()

        if indent == 0:
            current_key = None
            if ":" not in line:
                continue

            key, value = line.split(":", 1)
            key = key.strip()
            value = value.strip()

            if value == "":
                data[key] = {}
                current_key = key
            else:
                data[key] = _parse_scalar(value)

        elif indent >= 2 and current_key:
            if line.startswith("- "):
                if not isinstance(data.get(current_key), list):
                    data[current_key] = []
                data[current_key].append(_parse_scalar(line[2:].strip()))
            elif ":" in line:
                if not isinstance(data.get(current_key), dict):
                    data[current_key] = {}
                child_key, child_value = line.split(":", 1)
                data[current_key][child_key.strip()] = _parse_scalar(child_value.strip())

    return data


@dataclass
class CaseConfig:
    case_id: str
    role: str = "unknown"
    description: str = ""
    source_runtime: str = "XRT"
    memory_type: str = "unknown"
    complexity: str = "unknown"
    host_entry: str | None = None
    kernel_sources: list[str] = field(default_factory=list)
    build_entry: str | None = None
    golden: dict[str, Any] = field(default_factory=dict)
    validation_targets: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    case_file: str | None = None

    @staticmethod
    def from_dict(data: dict[str, Any], case_file: str | None = None, fallback_case_id: str = "unknown") -> "CaseConfig":
        return CaseConfig(
            case_id=str(data.get("case_id") or fallback_case_id),
            role=str(data.get("role", "unknown")),
            description=str(data.get("description", "")),
            source_runtime=str(data.get("source_runtime", "XRT")),
            memory_type=str(data.get("memory_type", "unknown")),
            complexity=str(data.get("complexity", "unknown")),
            host_entry=data.get("host_entry"),
            kernel_sources=list(data.get("kernel_sources", []) or []),
            build_entry=data.get("build_entry"),
            golden=dict(data.get("golden", {}) or {}),
            validation_targets=list(data.get("validation_targets", []) or []),
            tags=list(data.get("tags", []) or []),
            case_file=case_file,
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def load_case_config(case_path: str) -> CaseConfig:
    root = Path(case_path).resolve()
    case_file = root / "case.yaml"

    if not case_file.exists():
        return CaseConfig(
            case_id=root.name,
            role="unregistered_case",
            description="No case.yaml found; generated fallback metadata.",
            case_file=None,
        )

    data = parse_simple_yaml(case_file.read_text(encoding="utf-8"))
    return CaseConfig.from_dict(
        data,
        case_file=str(case_file.relative_to(root)),
        fallback_case_id=root.name,
    )


def validate_case_config(case: CaseConfig, case_root: str) -> list[dict[str, Any]]:
    root = Path(case_root).resolve()
    issues: list[dict[str, Any]] = []

    if not case.case_id:
        issues.append({
            "severity": "error",
            "code": "CASE_NO_ID",
            "message": "case.yaml must define case_id."
        })

    if case.source_runtime != "XRT":
        issues.append({
            "severity": "warning",
            "code": "CASE_SOURCE_RUNTIME_NOT_XRT",
            "message": f"Expected source_runtime XRT, got {case.source_runtime}."
        })

    if not case.validation_targets:
        issues.append({
            "severity": "warning",
            "code": "CASE_NO_VALIDATION_TARGETS",
            "message": "case.yaml should define validation_targets."
        })

    if case.host_entry and not (root / case.host_entry).exists():
        issues.append({
            "severity": "warning",
            "code": "CASE_HOST_ENTRY_MISSING",
            "message": f"host_entry does not exist: {case.host_entry}"
        })

    for kernel_src in case.kernel_sources:
        if not (root / kernel_src).exists():
            issues.append({
                "severity": "warning",
                "code": "CASE_KERNEL_SOURCE_MISSING",
                "message": f"kernel source does not exist: {kernel_src}"
            })

    golden_path = case.golden.get("path") if isinstance(case.golden, dict) else None
    if golden_path and not (root / golden_path).exists():
        issues.append({
            "severity": "warning",
            "code": "CASE_GOLDEN_MISSING",
            "message": f"golden file does not exist: {golden_path}"
        })

    return issues
EOT

echo "[3/7] Update ApplicationIR with case_metadata"

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
    case_metadata: dict[str, Any] = field(default_factory=dict)

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
            "case": self.case_metadata,
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

echo "[4/7] Update repo scanner to load case.yaml"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/scanner/repo_scanner.py")
text = path.read_text(encoding="utf-8")

if "from xporthls.cases.case_config import load_case_config, validate_case_config" not in text:
    text = text.replace(
        "from xporthls.scanner.xrt_semantic_extractor import extract_xrt_semantics\n",
        "from xporthls.scanner.xrt_semantic_extractor import extract_xrt_semantics\n"
        "from xporthls.cases.case_config import load_case_config, validate_case_config\n"
    )

old = '''    ir = ApplicationIR(project=root.name)

    for path in sorted(root.rglob("*")):
'''

new = '''    case_cfg = load_case_config(str(root))
    ir = ApplicationIR(
        project=case_cfg.case_id,
        source_runtime=case_cfg.source_runtime,
        case_metadata=case_cfg.to_dict(),
    )

    for case_issue in validate_case_config(case_cfg, str(root)):
        if case_issue["severity"] == "error":
            ir.unknowns.append({
                "kind": "case_config",
                "code": case_issue["code"],
                "message": case_issue["message"]
            })
        else:
            ir.warnings.append(f'{case_issue["code"]}: {case_issue["message"]}')

    if case_cfg.golden:
        ir.test_entries.append({
            "kind": "golden",
            "source": "case.yaml",
            **case_cfg.golden,
        })

    if case_cfg.host_entry:
        ir.test_entries.append({
            "kind": "host_entry",
            "source": "case.yaml",
            "path": case_cfg.host_entry,
        })

    for path in sorted(root.rglob("*")):
'''

if old not in text:
    raise SystemExit("Expected repo scanner initialization block not found.")

path.write_text(text.replace(old, new), encoding="utf-8")
PY

echo "[5/7] Update L0 checker for case metadata"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/validators/l0_static_checker.py")
text = path.read_text(encoding="utf-8")

old = '''    facts = app.get("facts", {})

    if not source_files:
'''

new = '''    facts = app.get("facts", {})
    case_metadata = app.get("case_metadata", {})

    if not case_metadata:
        issues.append(L0Issue("warning", "NO_CASE_METADATA", "ApplicationIR has no case_metadata. Add case.yaml for this case."))
    else:
        if not case_metadata.get("case_id"):
            issues.append(L0Issue("error", "CASE_METADATA_NO_ID", "case_metadata must include case_id."))
        if not case_metadata.get("validation_targets"):
            issues.append(L0Issue("warning", "CASE_METADATA_NO_VALIDATION_TARGETS", "case_metadata should include validation_targets."))

    if not source_files:
'''

if old not in text:
    raise SystemExit("Expected L0 facts block not found.")

text = text.replace(old, new)

old_summary = '''            "schema_version": facts.get("schema_version", "unknown") if isinstance(facts, dict) else "missing",
            "num_source_files": len(source_files),
'''

new_summary = '''            "schema_version": facts.get("schema_version", "unknown") if isinstance(facts, dict) else "missing",
            "case_id": case_metadata.get("case_id", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_role": case_metadata.get("role", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_memory_type": case_metadata.get("memory_type", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_validation_targets": case_metadata.get("validation_targets", []) if isinstance(case_metadata, dict) else [],
            "num_source_files": len(source_files),
'''

if old_summary not in text:
    raise SystemExit("Expected L0 summary block not found.")

path.write_text(text.replace(old_summary, new_summary), encoding="utf-8")
PY

echo "[6/7] Update CLI scan summary for case metadata"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/cli.py")
text = path.read_text(encoding="utf-8")

old = '''    print(f"[xporthls] ApplicationIR written to: {out}")
    print(f"[xporthls] Files: {len(ir.source_files)}")
'''

new = '''    print(f"[xporthls] ApplicationIR written to: {out}")
    if ir.case_metadata:
        print(f"[xporthls] Case: {ir.case_metadata.get('case_id')} ({ir.case_metadata.get('role')})")
        print(f"[xporthls] Memory type: {ir.case_metadata.get('memory_type')}")
        print(f"[xporthls] Validation targets: {ir.case_metadata.get('validation_targets')}")
    print(f"[xporthls] Files: {len(ir.source_files)}")
'''

if old not in text:
    raise SystemExit("Expected CLI ApplicationIR written block not found.")

path.write_text(text.replace(old, new), encoding="utf-8")
PY

echo "[7/7] Update README checklist"

python3 - <<'PY'
from pathlib import Path

path = Path("README.md")
if not path.exists():
    raise SystemExit("README.md not found.")

text = path.read_text(encoding="utf-8")

text = text.replace("### Phase 4 — case.yaml and Case Registry\n\nStatus: planned.", "### Phase 4 — case.yaml and Case Registry\n\nStatus: in progress.")
text = text.replace("- [ ] Add `cases/light_ddr/case.yaml`", "- [x] Add `cases/light_ddr/case.yaml`")
text = text.replace("- [ ] Add case metadata", "- [x] Add case metadata")
text = text.replace("- [ ] Add source runtime", "- [x] Add source runtime")
text = text.replace("- [ ] Add memory type", "- [x] Add memory type")
text = text.replace("- [ ] Add validation targets", "- [x] Add validation targets")
text = text.replace("- [ ] Add golden/test command fields", "- [x] Add golden/test command fields")
text = text.replace("- [ ] Update scanner to read case.yaml", "- [x] Update scanner to read case.yaml")

path.write_text(text, encoding="utf-8")
PY

echo
echo "[test] Run scan + contract + L0"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v005.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v005.json \
  --platform config/platforms/v80_aved_2025_1_stub.json \
  --out experiments/runs/light_ddr_migration_contract_v005.json

python3 -m xporthls.validators.run_l0 \
  --app-ir experiments/runs/light_ddr_application_ir_v005.json \
  --contract experiments/runs/light_ddr_migration_contract_v005.json \
  --out experiments/runs/light_ddr_l0_report_v005.json

python3 - <<'PY'
import json

app = json.load(open("experiments/runs/light_ddr_application_ir_v005.json"))
report = json.load(open("experiments/runs/light_ddr_l0_report_v005.json"))

print()
print("Case metadata:")
print(json.dumps(app.get("case_metadata", {}), indent=2))
print()
print("facts.case:")
print(json.dumps(app.get("facts", {}).get("case", {}), indent=2))
print()
print("L0 status:", report.get("status"))
print("L0 summary:")
print(json.dumps(report.get("summary", {}), indent=2))
PY

echo
echo "DONE."
echo "Check:"
echo "  cat experiments/runs/light_ddr_l0_report_v005.json"
echo "  git status"
