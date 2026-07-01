from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def directory_digest(path: Path) -> tuple[str, int]:
    entries: list[dict[str, Any]] = []

    for file_path in sorted(path.rglob("*")):
        if not file_path.is_file():
            continue

        entries.append({
            "relative_path": str(file_path.relative_to(path)),
            "size_bytes": file_path.stat().st_size,
            "sha256": sha256_file(file_path)
        })

    payload = json.dumps(entries, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest(), len(entries)


def make_file_artifact(role: str, path: str, artifact_type: str, stage: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists() and p.is_file()

    record: dict[str, Any] = {
        "role": role,
        "type": artifact_type,
        "stage": stage,
        "path": str(p),
        "exists": exists,
        "kind": "file"
    }

    if exists:
        record.update({
            "size_bytes": p.stat().st_size,
            "sha256": sha256_file(p)
        })

    return record


def make_directory_artifact(role: str, path: str, artifact_type: str, stage: str) -> dict[str, Any]:
    p = Path(path)
    exists = p.exists() and p.is_dir()

    record: dict[str, Any] = {
        "role": role,
        "type": artifact_type,
        "stage": stage,
        "path": str(p),
        "exists": exists,
        "kind": "directory"
    }

    if exists:
        digest, num_files = directory_digest(p)
        record.update({
            "num_files": num_files,
            "sha256": digest
        })

    return record


def build_artifact_registry(
    run_id: str,
    case_id: str,
    target_platform: str,
    target_ecosystem: str,
    artifacts: list[dict[str, Any]],
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "schema_version": "artifact_registry.v1",
        "run_id": run_id,
        "case_id": case_id,
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "created_at_utc": utc_now(),
        "artifacts": artifacts,
        "summary": {
            "num_artifacts": len(artifacts),
            "num_missing": sum(1 for a in artifacts if not a.get("exists")),
            "roles": sorted(a.get("role") for a in artifacts)
        },
        "metadata": metadata or {}
    }


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)
