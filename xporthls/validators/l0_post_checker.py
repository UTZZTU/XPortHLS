from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from xporthls.validators.l0_common import L0Issue, L0Report, classify_status, load_json


FORBIDDEN_XRT_PATTERNS = {
    "FORBIDDEN_XRT_DEVICE": re.compile(r"\bxrt::device\b"),
    "FORBIDDEN_XRT_KERNEL": re.compile(r"\bxrt::kernel\b"),
    "FORBIDDEN_XRT_BO": re.compile(r"\bxrt::bo\b"),
    "FORBIDDEN_XCLBIN_LOAD": re.compile(r"\bload_xclbin\s*\("),
    "FORBIDDEN_XCLBIN_ARTIFACT": re.compile(r"\.xclbin\b"),
}

TEXT_SUFFIXES = {
    ".c", ".cc", ".cpp", ".cxx",
    ".h", ".hh", ".hpp",
    ".tcl", ".cfg", ".ini",
    ".json", ".yaml", ".yml",
    ".mk", ".cmake", ".txt", ".md"
}


def _is_text_candidate(path: Path) -> bool:
    if path.name in {"Makefile", "CMakeLists.txt"}:
        return True
    return path.suffix.lower() in TEXT_SUFFIXES


def _load_manifest(root: Path) -> tuple[dict[str, Any] | None, Path | None]:
    for name in ["xporthls_generated_manifest.json", "manifest.json"]:
        p = root / name
        if p.exists():
            try:
                return json.loads(p.read_text(encoding="utf-8")), p
            except Exception:
                return None, p
    return None, None


def run_l0_post(project_path: str, contract_path: str | None = None) -> L0Report:
    root = Path(project_path).resolve()
    issues: list[L0Issue] = []

    contract: dict[str, Any] | None = None
    if contract_path:
        contract = load_json(contract_path)

    if not root.exists():
        return L0Report(
            status="fail",
            stage="L0-post",
            issues=[L0Issue("error", "GENERATED_PROJECT_MISSING", f"Generated project path does not exist: {root}")],
            summary={"project_path": str(root), "has_contract": contract is not None},
        )

    if not root.is_dir():
        return L0Report(
            status="fail",
            stage="L0-post",
            issues=[L0Issue("error", "GENERATED_PROJECT_NOT_DIR", f"Generated project path is not a directory: {root}")],
            summary={"project_path": str(root), "has_contract": contract is not None},
        )

    files = [p for p in sorted(root.rglob("*")) if p.is_file()]
    text_files = [p for p in files if _is_text_candidate(p)]

    if not files:
        issues.append(L0Issue("error", "GENERATED_PROJECT_EMPTY", "Generated project has no files."))

    manifest, manifest_path = _load_manifest(root)
    if manifest_path is None:
        issues.append(L0Issue(
            "warning",
            "NO_GENERATED_MANIFEST",
            "Generated project should include xporthls_generated_manifest.json.",
        ))
    elif manifest is None:
        issues.append(L0Issue(
            "error",
            "GENERATED_MANIFEST_INVALID",
            f"Could not parse generated manifest: {manifest_path.relative_to(root)}",
        ))
    else:
        for key in ["case_id", "target_platform", "artifacts"]:
            if key not in manifest:
                issues.append(L0Issue(
                    "warning",
                    f"GENERATED_MANIFEST_MISSING_{key.upper()}",
                    f"Generated manifest should include '{key}'.",
                ))

    forbidden_hits: list[dict[str, Any]] = []

    for p in text_files:
        try:
            text = p.read_text(encoding="utf-8", errors="ignore")
        except Exception:
            continue

        for lineno, line in enumerate(text.splitlines(), start=1):
            for code, pattern in FORBIDDEN_XRT_PATTERNS.items():
                if pattern.search(line):
                    forbidden_hits.append({
                        "code": code,
                        "file": str(p.relative_to(root)),
                        "line": lineno,
                        "evidence": line.strip(),
                    })

    for hit in forbidden_hits[:20]:
        issues.append(L0Issue(
            "error",
            hit["code"],
            f"Forbidden XRT artifact/API remains in generated project at {hit['file']}:{hit['line']} -> {hit['evidence']}",
        ))

    if len(forbidden_hits) > 20:
        issues.append(L0Issue(
            "error",
            "FORBIDDEN_XRT_TOO_MANY",
            f"Found {len(forbidden_hits)} forbidden XRT references; showing first 20.",
        ))

    if contract is not None:
        target_platform = contract.get("target_platform")
        if manifest and target_platform and manifest.get("target_platform") != target_platform:
            issues.append(L0Issue(
                "warning",
                "GENERATED_TARGET_PLATFORM_MISMATCH",
                f"Manifest target_platform {manifest.get('target_platform')} does not match contract target_platform {target_platform}.",
            ))

    status = classify_status(issues)

    return L0Report(
        status=status,
        stage="L0-post",
        issues=issues,
        summary={
            "project_path": str(root),
            "num_files": len(files),
            "num_text_files": len(text_files),
            "has_manifest": manifest is not None,
            "manifest_path": str(manifest_path.relative_to(root)) if manifest_path else None,
            "num_forbidden_xrt_hits": len(forbidden_hits),
            "has_contract": contract is not None,
            "target_platform": contract.get("target_platform") if contract else None,
        },
    )
