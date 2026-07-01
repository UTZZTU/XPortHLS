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
class ApplicationIR:
    project: str
    source_runtime: str = "XRT"
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
    unknowns: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.to_json())
            f.write("\n")
