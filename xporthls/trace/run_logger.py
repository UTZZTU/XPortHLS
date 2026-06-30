from __future__ import annotations

from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
import json
import os
import subprocess


@dataclass
class RunTrace:
    command: str
    started_at: str
    status: str = "started"
    metadata: dict[str, Any] = field(default_factory=dict)
    artifacts: list[str] = field(default_factory=list)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_run_dir(prefix: str = "run") -> Path:
    root = Path(os.environ.get("XPORT_HLS_RUN_ROOT", "/mnt/data/xporthls_runs"))
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    path = root / f"{prefix}_{stamp}"
    path.mkdir(parents=True, exist_ok=True)
    return path


def run_command(cmd: list[str], timeout: int = 30) -> dict[str, Any]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return {
            "cmd": cmd,
            "returncode": p.returncode,
            "stdout": p.stdout[:20000],
            "stderr": p.stderr[:20000],
        }
    except Exception as exc:
        return {
            "cmd": cmd,
            "returncode": None,
            "error": str(exc),
        }
