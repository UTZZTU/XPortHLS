#!/usr/bin/env bash
set -e

echo "[0/9] Backup current failed local state"

BACKUP_DIR="/mnt/data/xporthls_v007_failed_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

git status --porcelain > "$BACKUP_DIR/git_status.txt" || true
git diff > "$BACKUP_DIR/git_diff.patch" || true

for p in \
  add_platform_pack_v007.sh \
  rebuild_v007_clean_from_v006.sh \
  fix_v007_target_ecosystem.sh \
  finalize_v007_contract_schema.sh \
  rebuild_v007_final_clean.sh \
  repair_v007_once.sh \
  repair_v007_cli_patch.sh \
  xporthls/platforms \
  platform_packs/v80_aved_2025_1_stub
do
  if [ -e "$p" ]; then
    cp -a "$p" "$BACKUP_DIR/" || true
  fi
done

echo "[1/9] Reset tracked files back to v0.0.6 commit"

git reset --hard 6e9c6a9

echo "[2/9] Remove failed v0.0.7 untracked leftovers"

rm -rf \
  platform_packs/v80_aved_2025_1_stub \
  xporthls/platforms \
  add_platform_pack_v007.sh \
  rebuild_v007_clean_from_v006.sh \
  fix_v007_target_ecosystem.sh \
  finalize_v007_contract_schema.sh \
  repair_v007_once.sh \
  repair_v007_cli_patch.sh

echo "[3/9] Create clean Platform Pack v1"

PACK_DIR="platform_packs/v80_aved_2025_1_stub"

mkdir -p "$PACK_DIR/templates/hls"
mkdir -p "$PACK_DIR/templates/qdma_host"
mkdir -p "$PACK_DIR/templates/bd_tcl"
mkdir -p "$PACK_DIR/templates/build"
mkdir -p xporthls/platforms
touch xporthls/platforms/__init__.py

cat > "$PACK_DIR/platform.json" <<'EOT'
{
  "schema_version": "platform_pack.v1",
  "platform_id": "v80_aved_2025_1_stub",
  "name": "AMD Alveo V80 AVED 2025.1 Stub Platform Pack",
  "vendor": "AMD/Xilinx",
  "board": "Alveo V80",
  "target_family": "Versal",
  "status": "stub_pack_needs_manual_verification",
  "target": {
    "ecosystem": "AVED",
    "board": "Alveo V80",
    "tool_version": "2025.1",
    "tool_flow": "Vivado-centric AVED flow"
  },
  "tool_flow": "Vivado-centric AVED flow",
  "vivado_version": "2025.1",
  "vitis_version": "2025.1",
  "aved_release": {
    "release_name": "2025.1 tools V80 AVED release",
    "release_index_url": "https://xilinx.github.io/AVED/",
    "documentation_url": "https://xilinx.github.io/AVED/",
    "repository_url": "https://github.com/Xilinx/AVED",
    "repository_status": "obsolete_historical_reference",
    "verification_status": "stub_pack_needs_manual_verification"
  },
  "notes": [
    "This is an early XPortHLS Platform Pack for development.",
    "It freezes platform identity, source provenance, rule files and template layout.",
    "Rules marked verified=false must not be treated as final hardware facts."
  ]
}
EOT

cat > "$PACK_DIR/capabilities.json" <<'EOT'
{
  "schema_version": "platform_capabilities.v1",
  "platform_id": "v80_aved_2025_1_stub",
  "capabilities": {
    "aved_native_target": {
      "supported": true,
      "verified": true
    },
    "vivado_centric_flow": {
      "supported": true,
      "verified": true
    },
    "qdma": {
      "supported": true,
      "verified": false
    },
    "ddr_fixture_mapping": {
      "supported": true,
      "verified": false
    },
    "xrt_runtime_as_target": {
      "supported": false,
      "verified": true
    }
  }
}
EOT

cat > "$PACK_DIR/memory_rules.json" <<'EOT'
{
  "schema_version": "memory_rules.v1",
  "platform_id": "v80_aved_2025_1_stub",
  "rules": {
    "source_group_id_policy": {
      "description": "Use XRT kernel.group_id(N) as source memory binding candidate.",
      "verified": true
    },
    "ddr_fixture_policy": {
      "description": "Initial DDR fixture rule for light_ddr.",
      "verified": false
    },
    "hbm_policy": {
      "description": "HBM mapping is intentionally disabled until manually verified.",
      "supported": false,
      "verified": false
    }
  }
}
EOT

cat > "$PACK_DIR/qdma_rules.json" <<'EOT'
{
  "schema_version": "qdma_rules.v1",
  "platform_id": "v80_aved_2025_1_stub",
  "rules": {
    "sync_direction_mapping": {
      "verified": true,
      "mapping": {
        "XCL_BO_SYNC_BO_TO_DEVICE": "host_to_card",
        "XCL_BO_SYNC_BO_FROM_DEVICE": "card_to_host"
      }
    },
    "queue_policy": {
      "verified": false,
      "description": "Queue allocation policy is not verified in this stub pack."
    },
    "address_policy": {
      "verified": false,
      "description": "Device address assignment requires a later verified AddressMap."
    }
  }
}
EOT

cat > "$PACK_DIR/register_rules.json" <<'EOT'
{
  "schema_version": "register_rules.v1",
  "platform_id": "v80_aved_2025_1_stub",
  "rules": {
    "scalar_argument_policy": {
      "verified": true,
      "description": "Scalar arguments extracted from kernel invocation order become control candidates."
    },
    "register_address_policy": {
      "verified": false,
      "description": "Final register addresses are not assigned in this stub pack."
    }
  }
}
EOT

cat > "$PACK_DIR/templates/hls/kernel.cpp.tpl" <<'EOT'
// XPortHLS HLS kernel template.
// Platform: {{ platform_id }}
// Case: {{ case_id }}

extern "C" {
void {{ kernel_name }}() {
    // TODO: generated or migrated HLS kernel body.
}
}
EOT

cat > "$PACK_DIR/templates/qdma_host/host.cpp.tpl" <<'EOT'
// XPortHLS AVED-native QDMA host template.
// Platform: {{ platform_id }}
// Case: {{ case_id }}
//
// No XRT API should remain in generated AVED-native host code.

int main() {
    return 0;
}
EOT

cat > "$PACK_DIR/templates/bd_tcl/create_bd.tcl.tpl" <<'EOT'
# XPortHLS AVED BD Tcl template.
# Platform: {{ platform_id }}
# Case: {{ case_id }}
EOT

cat > "$PACK_DIR/templates/build/build.sh.tpl" <<'EOT'
#!/usr/bin/env bash
set -e
echo "XPortHLS generated build stub"
EOT

cat > "$PACK_DIR/templates/manifest.json.tpl" <<'EOT'
{
  "case_id": "{{ case_id }}",
  "target_platform": "{{ platform_id }}",
  "generator_status": "stub",
  "artifacts": {}
}
EOT

echo "[4/9] Add Platform Pack loader"

cat > xporthls/platforms/platform_pack.py <<'EOT'
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
EOT

echo "[5/9] Replace PlatformIR only, keep CLI untouched"

cat > xporthls/ir/platform_ir.py <<'EOT'
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
EOT

echo "[6/9] Update README checklist"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

text = text.replace("### Phase 5 — Platform Pack v1\n\nStatus: planned.", "### Phase 5 — Platform Pack v1\n\nStatus: in progress.")
text = text.replace("- [ ] Move platform stub into platform pack", "- [x] Move platform stub into platform pack")
text = text.replace("- [ ] Add capabilities file", "- [x] Add capabilities file")
text = text.replace("- [ ] Add memory rules", "- [x] Add memory rules")
text = text.replace("- [ ] Add QDMA rules", "- [x] Add QDMA rules")
text = text.replace("- [ ] Add register rules", "- [x] Add register rules")
text = text.replace("- [ ] Add template metadata", "- [x] Add template metadata")
text = text.replace("- [ ] Update PlatformIR loader", "- [x] Update PlatformIR loader")

p.write_text(text, encoding="utf-8")
PY

echo "[7/9] Create safe v0.0.7 replay script"

cat > add_platform_pack_v007.sh <<'EOT'
#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"

echo "[v0.0.7] Python syntax check"
python3 -m py_compile \
  xporthls/ir/platform_ir.py \
  xporthls/platforms/platform_pack.py \
  xporthls/cli.py

echo "[v0.0.7] Validate Platform Pack"
python3 -m xporthls.platforms.platform_pack \
  --pack "$PACK_DIR" \
  --out experiments/runs/v80_aved_2025_1_platform_pack_report_v007.json

echo "[v0.0.7] Check PlatformIR compatibility"
python3 - <<'PY'
from xporthls.ir.platform_ir import PlatformIR

p = PlatformIR.load_json("platform_packs/v80_aved_2025_1_stub")
print("PlatformIR id:", p.id)
print("PlatformIR status:", p.status)
print("PlatformIR target:", p.target)

assert p.id == "v80_aved_2025_1_stub"
assert p.target.get("ecosystem") == "AVED"
assert p.status
PY

echo "[v0.0.7] Run scan + contract + L0-pre using Platform Pack"
python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v007.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v007.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v007.json

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v007.json \
  --contract experiments/runs/light_ddr_migration_contract_v007.json \
  --out experiments/runs/light_ddr_l0_pre_report_v007.json

python3 - <<'PY'
import json

pack_report = json.load(open("experiments/runs/v80_aved_2025_1_platform_pack_report_v007.json"))
contract = json.load(open("experiments/runs/light_ddr_migration_contract_v007.json"))
l0 = json.load(open("experiments/runs/light_ddr_l0_pre_report_v007.json"))

print()
print("Platform Pack status:", pack_report["status"])
print("Platform ID:", pack_report["platform_id"])
print("Contract target_platform:", contract.get("target_platform"))
print("L0-pre status:", l0["status"])
print("L0-pre issues:", len(l0.get("issues", [])))

assert pack_report["status"] == "pass"
assert contract.get("target_platform") == "v80_aved_2025_1_stub"
assert l0["status"] == "pass"
assert len(l0.get("issues", [])) == 0
PY

echo
echo "DONE."
EOT

chmod +x add_platform_pack_v007.sh

echo "[8/9] Run full v0.0.7 replay"
./add_platform_pack_v007.sh

echo "[9/9] Final git status"
git status

echo
echo "Clean v0.0.7 final rebuild completed."
echo "Failed-state backup saved at: $BACKUP_DIR"
