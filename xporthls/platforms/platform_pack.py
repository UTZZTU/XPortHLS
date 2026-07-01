from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


REQUIRED_PACK_FILES = [
    "platform.json",
    "capabilities.json",
    "memory_rules.json",
    "qdma_rules.json",
    "register_rules.json",
]


@dataclass
class PlatformPackIssue:
    severity: str
    code: str
    message: str


@dataclass
class PlatformPackReport:
    status: str
    platform_id: str
    pack_path: str
    stage: str = "platform-pack"
    issues: list[PlatformPackIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


@dataclass
class PlatformPack:
    root: str
    platform: dict[str, Any]
    capabilities: dict[str, Any]
    memory_rules: dict[str, Any]
    qdma_rules: dict[str, Any]
    register_rules: dict[str, Any]
    templates: dict[str, str]

    @property
    def platform_id(self) -> str:
        return str(self.platform.get("platform_id") or "unknown_platform")

    def to_platform_ir_dict(self) -> dict[str, Any]:
        return {
            "id": self.platform_id,
            "platform_id": self.platform_id,
            "name": self.platform.get("name", self.platform_id),
            "status": self.platform.get("status", "stub_pack_needs_manual_verification"),
            "target": self.platform.get("target", {
                "ecosystem": "AVED",
                "board": self.platform.get("board", "unknown"),
                "tool_version": self.platform.get("vivado_version", "unknown"),
                "tool_flow": self.platform.get("tool_flow", "unknown")
            }),
            "vendor": self.platform.get("vendor", "unknown"),
            "board": self.platform.get("board", "unknown"),
            "target_family": self.platform.get("target_family", "unknown"),
            "tool_flow": self.platform.get("tool_flow", "unknown"),
            "vivado_version": self.platform.get("vivado_version", "unknown"),
            "vitis_version": self.platform.get("vitis_version", "unknown"),
            "source_kind": "platform_pack",
            "pack_path": self.root,
            "aved_release": self.platform.get("aved_release", {}),
            "capabilities": self.capabilities,
            "memory_rules": self.memory_rules,
            "qdma_rules": self.qdma_rules,
            "register_rules": self.register_rules,
            "templates": self.templates,
            "metadata": self.platform,
        }


def _load_json(path: Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _discover_templates(root: Path) -> dict[str, str]:
    templates_root = root / "templates"
    out: dict[str, str] = {}

    if not templates_root.exists():
        return out

    for path in sorted(templates_root.rglob("*")):
        if path.is_file():
            out[str(path.relative_to(root))] = path.read_text(encoding="utf-8")

    return out


def load_platform_pack(pack_path: str) -> PlatformPack:
    root = Path(pack_path).resolve()

    if not root.exists():
        raise FileNotFoundError(f"Platform pack does not exist: {root}")

    if not root.is_dir():
        raise NotADirectoryError(f"Platform pack path is not a directory: {root}")

    return PlatformPack(
        root=str(root),
        platform=_load_json(root / "platform.json"),
        capabilities=_load_json(root / "capabilities.json"),
        memory_rules=_load_json(root / "memory_rules.json"),
        qdma_rules=_load_json(root / "qdma_rules.json"),
        register_rules=_load_json(root / "register_rules.json"),
        templates=_discover_templates(root),
    )


def validate_platform_pack(pack_path: str) -> PlatformPackReport:
    root = Path(pack_path).resolve()
    issues: list[PlatformPackIssue] = []

    if not root.exists():
        return PlatformPackReport(
            status="fail",
            platform_id="unknown",
            pack_path=str(root),
            issues=[PlatformPackIssue("error", "PLATFORM_PACK_MISSING", f"Missing platform pack: {root}")],
        )

    for name in REQUIRED_PACK_FILES:
        if not (root / name).exists():
            issues.append(PlatformPackIssue("error", "PLATFORM_PACK_FILE_MISSING", f"Missing required file: {name}"))

    try:
        pack = load_platform_pack(str(root))
        platform_id = pack.platform_id
    except Exception as exc:
        return PlatformPackReport(
            status="fail",
            platform_id="unknown",
            pack_path=str(root),
            issues=issues + [PlatformPackIssue("error", "PLATFORM_PACK_LOAD_FAILED", str(exc))],
        )

    if pack.platform.get("schema_version") != "platform_pack.v1":
        issues.append(PlatformPackIssue("warning", "PLATFORM_SCHEMA_VERSION_UNKNOWN", "Unexpected platform schema version."))

    required_templates = [
        "templates/hls/kernel.cpp.tpl",
        "templates/qdma_host/host.cpp.tpl",
        "templates/bd_tcl/create_bd.tcl.tpl",
        "templates/build/build.sh.tpl",
        "templates/manifest.json.tpl",
    ]

    for tpl in required_templates:
        if tpl not in pack.templates:
            issues.append(PlatformPackIssue("warning", "PLATFORM_TEMPLATE_MISSING", f"Missing template: {tpl}"))

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return PlatformPackReport(
        status=status,
        platform_id=platform_id,
        pack_path=str(root),
        issues=issues,
        summary={
            "platform_id": platform_id,
            "board": pack.platform.get("board"),
            "vivado_version": pack.platform.get("vivado_version"),
            "vitis_version": pack.platform.get("vitis_version"),
            "tool_flow": pack.platform.get("tool_flow"),
            "num_templates": len(pack.templates),
            "required_files": REQUIRED_PACK_FILES,
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an XPortHLS Platform Pack")
    parser.add_argument("--pack", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = validate_platform_pack(args.pack)
    report.save(args.out)

    print(f"[xporthls] Platform Pack report written to: {args.out}")
    print(f"[xporthls] Platform Pack status: {report.status}")
    print(f"[xporthls] Platform ID: {report.platform_id}")

    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
