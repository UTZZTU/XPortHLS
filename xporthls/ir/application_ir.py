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
