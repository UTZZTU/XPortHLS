#!/usr/bin/env bash
set -e

echo "[1/7] Add contract promotion tool"

cat > xporthls/contracts/promote_contract_v1.py <<'EOT'
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def promote_contract(contract: dict[str, Any], l0_report: dict[str, Any], l0_report_path: str) -> dict[str, Any]:
    if contract.get("schema_version") != "migration_contract.v1":
        raise ValueError(f"Expected migration_contract.v1, got {contract.get('schema_version')}")

    if contract.get("state") != "Proposed":
        raise ValueError(f"Expected Proposed contract state, got {contract.get('state')}")

    if l0_report.get("stage") != "L0-pre":
        raise ValueError(f"Expected L0-pre report, got {l0_report.get('stage')}")

    if l0_report.get("status") != "pass":
        raise ValueError(f"L0-pre must be pass before promotion, got {l0_report.get('status')}")

    if len(l0_report.get("issues", [])) != 0:
        raise ValueError("L0-pre report has issues; refusing to promote contract.")

    promoted = json.loads(json.dumps(contract))
    promoted["state"] = "StaticallyChecked"

    if "contract_states" not in promoted:
        promoted["contract_states"] = {
            "allowed": ["Proposed", "StaticallyChecked", "RuntimeValidated"]
        }

    promoted["contract_states"]["current"] = "StaticallyChecked"
    promoted["contract_states"]["previous"] = "Proposed"
    promoted["contract_states"]["next_required_validation"] = "L0-post"

    promoted.setdefault("validation_evidence", [])
    promoted["validation_evidence"].append({
        "stage": "L0-pre",
        "status": l0_report.get("status"),
        "report_path": l0_report_path,
        "summary": l0_report.get("summary", {}),
        "promotion": "Proposed_to_StaticallyChecked"
    })

    promoted.setdefault("warnings", [])
    promoted["warnings"].append(
        "Contract promoted to StaticallyChecked because L0-pre passed with zero issues."
    )

    return promoted


def main() -> int:
    parser = argparse.ArgumentParser(description="Promote MigrationContract v1 after successful L0-pre")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--l0-report", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    contract = load_json(args.contract)
    l0_report = load_json(args.l0_report)

    promoted = promote_contract(contract, l0_report, args.l0_report)
    save_json(args.out, promoted)

    print(f"[xporthls] StaticallyChecked MigrationContract written to: {args.out}")
    print(f"[xporthls] Contract state: {promoted.get('state')}")
    print(f"[xporthls] Next validation: {promoted.get('contract_states', {}).get('next_required_validation')}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/7] Add generator package"

mkdir -p xporthls/generators
touch xporthls/generators/__init__.py

cat > xporthls/generators/stub_generator.py <<'EOT'
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from xporthls.ir.platform_ir import PlatformIR


def load_json(path: str) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def write_text(path: Path, text: str, executable: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if executable:
        path.chmod(0o755)


def first_kernel_name(contract: dict[str, Any]) -> str:
    interface = contract.get("contracts", {}).get("interface", {})
    invocations = interface.get("kernel_invocations", [])

    for inv in invocations:
        if inv.get("kernel_name"):
            return str(inv["kernel_name"])

    candidates = interface.get("kernel_candidates", [])
    for cand in candidates:
        if cand.get("name"):
            return str(cand["name"])

    return "kernel_stub"


def build_manifest(
    app: dict[str, Any],
    contract: dict[str, Any],
    policy: dict[str, Any] | None,
    platform: PlatformIR,
    out_dir: Path,
    kernel_name: str,
    contract_path: str,
    policy_path: str | None,
) -> dict[str, Any]:
    case_id = contract.get("case_id") or app.get("project") or "unknown_case"
    target_platform = contract.get("target_platform") or platform.platform_id
    target_ecosystem = contract.get("target_ecosystem") or platform.target.get("ecosystem") or "AVED"

    memory = contract.get("contracts", {}).get("memory", {})
    qdma = contract.get("contracts", {}).get("qdma", {})
    control = contract.get("contracts", {}).get("control", {})

    return {
        "schema_version": "xporthls_generated_manifest.v1",
        "case_id": case_id,
        "target_platform": target_platform,
        "target_ecosystem": target_ecosystem,
        "generator": "stub_generator.v1",
        "generator_status": "stub",
        "contract_state": contract.get("state"),
        "contract_ref": contract_path,
        "execution_policy_ref": policy_path,
        "platform_pack": {
            "platform_id": platform.platform_id,
            "source_kind": platform.source_kind,
            "pack_path": platform.pack_path,
            "status": platform.status
        },
        "artifacts": {
            "hls_ip": f"hls/{kernel_name}.cpp",
            "host": "host/qdma_host.cpp",
            "bd_tcl": "bd_tcl/create_bd.tcl",
            "build": "build/build.sh",
            "readme": "README.md"
        },
        "source_summary": {
            "num_buffers": memory.get("num_buffers", 0),
            "num_host_transfers": qdma.get("num_host_transfers", 0),
            "num_sync_operations": qdma.get("num_sync_operations", 0),
            "num_kernel_invocations": control.get("num_kernel_invocations", 0)
        },
        "output_dir": str(out_dir)
    }


def generate_hls(kernel_name: str, contract: dict[str, Any]) -> str:
    memory = contract.get("contracts", {}).get("memory", {})
    buffer_roles = memory.get("buffer_roles", [])

    comment_lines = []
    for buf in buffer_roles:
        comment_lines.append(
            f"// Buffer {buf.get('name')}: role={buf.get('role')} group_id={buf.get('group_id')} size={buf.get('size_expr')}"
        )

    comments = "\n".join(comment_lines) if comment_lines else "// No buffer roles available yet."

    return f"""// Generated by XPortHLS stub_generator.v1.
// This is a deterministic scaffold, not a final optimized kernel.

{comments}

extern "C" {{
void {kernel_name}() {{
    // TODO(v0.0.9): insert migrated HLS kernel body in a later generator version.
}}
}}
"""


def generate_host(contract: dict[str, Any]) -> str:
    qdma = contract.get("contracts", {}).get("qdma", {})
    transfers = qdma.get("host_transfers", [])
    syncs = qdma.get("sync_operations", [])

    transfer_lines = []
    for t in transfers:
        transfer_lines.append(
            f"// Host transfer: buffer={t.get('buffer')} op={t.get('operation')} host_expr={t.get('host_expr')}"
        )

    sync_lines = []
    for s in syncs:
        sync_lines.append(
            f"// Sync direction: buffer={s.get('buffer')} direction={s.get('direction')}"
        )

    transfer_text = "\n".join(transfer_lines) if transfer_lines else "// No host transfers extracted."
    sync_text = "\n".join(sync_lines) if sync_lines else "// No sync operations extracted."

    return f"""// Generated by XPortHLS stub_generator.v1.
// AVED-native host scaffold.
// No source-runtime APIs or xclbin loading are allowed in this generated stub.

{transfer_text}
{sync_text}

int main() {{
    // TODO(v0.0.9): generate QDMA setup and transfer calls after verified AVED rules are available.
    return 0;
}}
"""


def generate_bd_tcl(contract: dict[str, Any]) -> str:
    return f"""# Generated by XPortHLS stub_generator.v1.
# Target platform: {contract.get('target_platform')}
# Target ecosystem: {contract.get('target_ecosystem')}
# TODO(v0.0.9): instantiate generated IP and connect to AVED base design.
"""


def generate_build_script(contract: dict[str, Any]) -> str:
    return f"""#!/usr/bin/env bash
set -e
echo "XPortHLS generated build stub"
echo "Target platform: {contract.get('target_platform')}"
echo "Contract state: {contract.get('state')}"
"""


def generate_readme(manifest: dict[str, Any]) -> str:
    return f"""# XPortHLS Generated Stub Project

Case: `{manifest.get('case_id')}`

Target platform: `{manifest.get('target_platform')}`

Target ecosystem: `{manifest.get('target_ecosystem')}`

Generator: `{manifest.get('generator')}`

Status: `{manifest.get('generator_status')}`

This directory is a deterministic scaffold generated for validation-loop development.
It is not a final AVED hardware project.
"""


def run_generator(
    app_ir_path: str,
    contract_path: str,
    policy_path: str | None,
    platform_path: str,
    out_dir: str,
    clean: bool = False,
) -> dict[str, Any]:
    app = load_json(app_ir_path)
    contract = load_json(contract_path)
    policy = load_json(policy_path) if policy_path else None
    platform = PlatformIR.load_json(platform_path)

    if contract.get("schema_version") != "migration_contract.v1":
        raise ValueError(f"Expected migration_contract.v1, got {contract.get('schema_version')}")

    if contract.get("state") != "StaticallyChecked":
        raise ValueError(
            f"Generator requires StaticallyChecked contract. Got state={contract.get('state')}"
        )

    if policy is not None and policy.get("schema_version") != "execution_policy.v1":
        raise ValueError(f"Expected execution_policy.v1, got {policy.get('schema_version')}")

    out = Path(out_dir).resolve()

    if clean and out.exists():
        for path in sorted(out.rglob("*"), reverse=True):
            if path.is_file() or path.is_symlink():
                path.unlink()
            elif path.is_dir():
                path.rmdir()

    out.mkdir(parents=True, exist_ok=True)

    kernel_name = first_kernel_name(contract)
    manifest = build_manifest(
        app=app,
        contract=contract,
        policy=policy,
        platform=platform,
        out_dir=out,
        kernel_name=kernel_name,
        contract_path=contract_path,
        policy_path=policy_path,
    )

    write_text(out / "hls" / f"{kernel_name}.cpp", generate_hls(kernel_name, contract))
    write_text(out / "host" / "qdma_host.cpp", generate_host(contract))
    write_text(out / "bd_tcl" / "create_bd.tcl", generate_bd_tcl(contract))
    write_text(out / "build" / "build.sh", generate_build_script(contract), executable=True)
    write_text(out / "README.md", generate_readme(manifest))
    save_json(out / "xporthls_generated_manifest.json", manifest)

    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate an XPortHLS deterministic stub project")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--contract", required=True)
    parser.add_argument("--policy", default=None)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--clean", action="store_true")
    args = parser.parse_args()

    manifest = run_generator(
        app_ir_path=args.app_ir,
        contract_path=args.contract,
        policy_path=args.policy,
        platform_path=args.platform,
        out_dir=args.out_dir,
        clean=args.clean,
    )

    print(f"[xporthls] Generated stub project: {args.out_dir}")
    print(f"[xporthls] Target platform: {manifest.get('target_platform')}")
    print(f"[xporthls] Artifacts: {len(manifest.get('artifacts', {}))}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/7] Update README checklist"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

text = text.replace("### Phase 8 — Generator Stub\n\nStatus: planned.", "### Phase 8 — Generator Stub\n\nStatus: in progress.")
text = text.replace("- [ ] Add HLS IP generator stub", "- [x] Add HLS IP generator stub")
text = text.replace("- [ ] Add register map generator stub", "- [ ] Add register map generator stub")
text = text.replace("- [ ] Add address map generator stub", "- [ ] Add address map generator stub")
text = text.replace("- [ ] Add QDMA host generator stub", "- [x] Add QDMA host generator stub")
text = text.replace("- [ ] Add BD/Tcl generator stub", "- [x] Add BD/Tcl generator stub")
text = text.replace("- [ ] Add build script generator stub", "- [x] Add build script generator stub")
text = text.replace("- [ ] Generate light_ddr target skeleton", "- [x] Generate light_ddr target skeleton")

p.write_text(text, encoding="utf-8")
PY

echo "[4/7] Create v0.0.9 replay script"

cat > add_generator_stub_v009_replay.sh <<'EOT'
#!/usr/bin/env bash
set -e

PACK_DIR="platform_packs/v80_aved_2025_1_stub"
GEN_DIR="experiments/runs/light_ddr_generated_v009"

echo "[v0.0.9] Python syntax check"

python3 -m py_compile \
  xporthls/contracts/build_contract_v1.py \
  xporthls/contracts/validate_contract_v1.py \
  xporthls/contracts/promote_contract_v1.py \
  xporthls/generators/stub_generator.py \
  xporthls/validators/l0_post_checker.py \
  xporthls/validators/run_l0.py

echo "[v0.0.9] Build ApplicationIR + Contract v1 + ExecutionPolicy"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v009.json

python3 -m xporthls.contracts.build_contract_v1 \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --platform "$PACK_DIR" \
  --out experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --policy-out experiments/runs/light_ddr_execution_policy_v009.json

python3 -m xporthls.contracts.validate_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --policy experiments/runs/light_ddr_execution_policy_v009.json \
  --out experiments/runs/light_ddr_contract_v1_report_v009.json

echo "[v0.0.9] Run L0-pre and promote contract"

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --out experiments/runs/light_ddr_l0_pre_report_v009.json

python3 -m xporthls.contracts.promote_contract_v1 \
  --contract experiments/runs/light_ddr_migration_contract_v009_proposed.json \
  --l0-report experiments/runs/light_ddr_l0_pre_report_v009.json \
  --out experiments/runs/light_ddr_migration_contract_v009_static.json

echo "[v0.0.9] Generate stub target project"

python3 -m xporthls.generators.stub_generator \
  --app-ir experiments/runs/light_ddr_application_ir_v009.json \
  --contract experiments/runs/light_ddr_migration_contract_v009_static.json \
  --policy experiments/runs/light_ddr_execution_policy_v009.json \
  --platform "$PACK_DIR" \
  --out-dir "$GEN_DIR" \
  --clean

echo "[v0.0.9] Run L0-post on generated project"

python3 -m xporthls.validators.run_l0 \
  --stage post \
  --project "$GEN_DIR" \
  --contract experiments/runs/light_ddr_migration_contract_v009_static.json \
  --out experiments/runs/light_ddr_l0_post_report_v009.json

python3 - <<'PY'
import json
from pathlib import Path

manifest = json.load(open("experiments/runs/light_ddr_generated_v009/xporthls_generated_manifest.json"))
static_contract = json.load(open("experiments/runs/light_ddr_migration_contract_v009_static.json"))
post = json.load(open("experiments/runs/light_ddr_l0_post_report_v009.json"))

print()
print("Generated manifest schema:", manifest["schema_version"])
print("Generated target_platform:", manifest["target_platform"])
print("Generated artifacts:", sorted(manifest["artifacts"].keys()))
print("Contract state:", static_contract["state"])
print("L0-post status:", post["status"])
print("L0-post issues:", len(post.get("issues", [])))
print("Forbidden source-runtime hits:", post.get("summary", {}).get("num_forbidden_xrt_hits"))

assert manifest["schema_version"] == "xporthls_generated_manifest.v1"
assert manifest["target_platform"] == "v80_aved_2025_1_stub"
assert static_contract["state"] == "StaticallyChecked"
assert post["status"] == "pass"
assert len(post.get("issues", [])) == 0
assert post.get("summary", {}).get("num_forbidden_xrt_hits") == 0

for rel in manifest["artifacts"].values():
    assert (Path("experiments/runs/light_ddr_generated_v009") / rel).exists(), rel
PY

echo
echo "DONE."
EOT

chmod +x add_generator_stub_v009_replay.sh

echo "[5/7] Run v0.0.9 replay"

./add_generator_stub_v009_replay.sh

echo "[6/7] Show generated tree"

find experiments/runs/light_ddr_generated_v009 -maxdepth 3 -type f | sort

echo "[7/7] Show git status"

git status
