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
