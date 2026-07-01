from __future__ import annotations

import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class L0Issue:
    severity: str
    code: str
    message: str


@dataclass
class L0Report:
    status: str
    stage: str
    issues: list[L0Issue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def classify_status(issues: list[L0Issue]) -> str:
    has_error = any(issue.severity == "error" for issue in issues)
    return "fail" if has_error else "pass_with_warnings" if issues else "pass"
