from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_budget_ledger(run_id: str, case_id: str, target_platform: str) -> dict[str, Any]:
    return {
        "schema_version": "budget_ledger.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "created_at_utc": utc_now(),
        "mode": "deterministic_pipeline_only",
        "llm_enabled": False,
        "tool_calls": [],
        "llm_calls": [],
        "summary": {
            "num_tool_calls": 0,
            "num_failed_tool_calls": 0,
            "num_llm_calls": 0,
            "total_wall_time_sec": 0.0,
            "total_prompt_tokens": 0,
            "total_completion_tokens": 0,
            "total_tokens": 0
        }
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def _tail(text: str, max_lines: int = 40) -> str:
    lines = text.splitlines()
    return "\n".join(lines[-max_lines:])


def refresh_summary(ledger: dict[str, Any]) -> None:
    calls = ledger.get("tool_calls", [])
    ledger["summary"] = {
        "num_tool_calls": len(calls),
        "num_failed_tool_calls": sum(1 for c in calls if c.get("return_code") != 0),
        "num_llm_calls": len(ledger.get("llm_calls", [])),
        "total_wall_time_sec": round(sum(float(c.get("duration_sec", 0.0)) for c in calls), 6),
        "total_prompt_tokens": 0,
        "total_completion_tokens": 0,
        "total_tokens": 0
    }


def run_logged(
    ledger: dict[str, Any],
    stage: str,
    name: str,
    command: list[str],
    cwd: str | None = None,
    partial_ledger_path: str | None = None,
) -> subprocess.CompletedProcess[str]:
    start_wall = utc_now()
    start = time.perf_counter()

    print(f"[xporthls-budget] START {stage}/{name}")
    print("[xporthls-budget] CMD:", " ".join(command))

    proc = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        capture_output=True,
    )

    duration = time.perf_counter() - start
    end_wall = utc_now()

    if proc.stdout:
        print(proc.stdout, end="")
    if proc.stderr:
        print(proc.stderr, file=sys.stderr, end="")

    record = {
        "stage": stage,
        "name": name,
        "command": command,
        "started_at_utc": start_wall,
        "ended_at_utc": end_wall,
        "duration_sec": round(duration, 6),
        "return_code": proc.returncode,
        "stdout_tail": _tail(proc.stdout),
        "stderr_tail": _tail(proc.stderr),
        "budget": {
            "credit_cost": 1,
            "llm_prompt_tokens": 0,
            "llm_completion_tokens": 0,
            "llm_total_tokens": 0
        }
    }

    ledger.setdefault("tool_calls", []).append(record)
    refresh_summary(ledger)

    if partial_ledger_path:
        save_json(partial_ledger_path, ledger)

    print(f"[xporthls-budget] END {stage}/{name} rc={proc.returncode} duration={duration:.3f}s")

    if proc.returncode != 0:
        raise RuntimeError(f"Command failed at {stage}/{name}: {' '.join(command)}")

    return proc
