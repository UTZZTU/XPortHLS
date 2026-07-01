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
