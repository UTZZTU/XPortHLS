from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any
import json


@dataclass
class MigrationContract:
    contract_id: str
    source_project: str
    target_platform: str
    scope: dict[str, Any] = field(default_factory=dict)
    obligations: list[dict[str, Any]] = field(default_factory=list)
    unsupported: list[dict[str, Any]] = field(default_factory=list)
    validation_plan: list[str] = field(default_factory=lambda: [
        "L0_static",
        "L1_software",
        "L2_hls_csim",
        "L3_hls_synth",
        "L4_vivado_interface",
        "L5_board"
    ])

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    def save(self, path: str) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.to_dict(), f, indent=2, ensure_ascii=False)
            f.write("\n")
