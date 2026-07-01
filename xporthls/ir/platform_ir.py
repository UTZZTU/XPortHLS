from __future__ import annotations

import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any

from xporthls.platforms.platform_pack import load_platform_pack


@dataclass
class PlatformIR:
    id: str
    name: str
    target: dict[str, Any] = field(default_factory=dict)
    status: str = "stub"
    vendor: str = "unknown"
    board: str = "unknown"
    target_family: str = "unknown"
    tool_flow: str = "unknown"
    vivado_version: str = "unknown"
    vitis_version: str = "unknown"
    source_kind: str = "json"
    pack_path: str | None = None
    aved_release: dict[str, Any] = field(default_factory=dict)
    capabilities: dict[str, Any] = field(default_factory=dict)
    memory_rules: dict[str, Any] = field(default_factory=dict)
    qdma_rules: dict[str, Any] = field(default_factory=dict)
    register_rules: dict[str, Any] = field(default_factory=dict)
    templates: dict[str, str] = field(default_factory=dict)
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def platform_id(self) -> str:
        return self.id

    @property
    def target_platform(self) -> str:
        return self.id

    @property
    def tool_version(self) -> str:
        return str(self.target.get("tool_version") or self.vivado_version or "unknown")

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "PlatformIR":
        platform_id = str(
            data.get("id")
            or data.get("platform_id")
            or data.get("target_platform")
            or data.get("name")
            or "unknown_platform"
        )

        target = dict(data.get("target", {}) or {})
        target["ecosystem"] = target.get("ecosystem") or data.get("ecosystem") or "AVED"
        target["board"] = target.get("board") or data.get("board") or "unknown"
        target["tool_version"] = (
            target.get("tool_version")
            or data.get("tool_version")
            or data.get("vivado_version")
            or data.get("version")
            or "unknown"
        )
        target["tool_flow"] = target.get("tool_flow") or data.get("tool_flow") or "unknown"

        return PlatformIR(
            id=platform_id,
            name=str(data.get("name", platform_id)),
            target=target,
            status=str(data.get("status", "stub")),
            vendor=str(data.get("vendor", "unknown")),
            board=str(data.get("board", target.get("board", "unknown"))),
            target_family=str(data.get("target_family", target.get("target_family", "unknown"))),
            tool_flow=str(data.get("tool_flow", target.get("tool_flow", "unknown"))),
            vivado_version=str(data.get("vivado_version", target.get("tool_version", "unknown"))),
            vitis_version=str(data.get("vitis_version", "unknown")),
            source_kind=str(data.get("source_kind", "json")),
            pack_path=data.get("pack_path"),
            aved_release=dict(data.get("aved_release", {}) or {}),
            capabilities=dict(data.get("capabilities", {}) or {}),
            memory_rules=dict(data.get("memory_rules", data.get("memory_model", {})) or {}),
            qdma_rules=dict(data.get("qdma_rules", {}) or {}),
            register_rules=dict(data.get("register_rules", {}) or {}),
            templates=dict(data.get("templates", {}) or {}),
            metadata=dict(data.get("metadata", data) or {}),
        )

    @staticmethod
    def load(path: str) -> "PlatformIR":
        p = Path(path)

        if p.is_dir():
            pack = load_platform_pack(str(p))
            return PlatformIR.from_dict(pack.to_platform_ir_dict())

        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)

        return PlatformIR.from_dict(data)

    @staticmethod
    def load_json(path: str) -> "PlatformIR":
        return PlatformIR.load(path)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)
