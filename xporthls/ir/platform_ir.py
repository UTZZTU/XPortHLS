from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any
import json


@dataclass
class PlatformIR:
    platform_id: str
    target: dict[str, Any]
    status: str = "unknown"
    notes: list[str] = field(default_factory=list)

    @staticmethod
    def load_json(path: str) -> "PlatformIR":
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return PlatformIR(
            platform_id=data.get("platform_id", "unknown"),
            status=data.get("status", "unknown"),
            target=data.get("target", {}),
            notes=data.get("notes", []),
        )

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2, ensure_ascii=False)
            f.write("\n")
