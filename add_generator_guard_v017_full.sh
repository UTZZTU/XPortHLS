#!/usr/bin/env bash
set -euo pipefail

echo "[1/6] Add contract-gated generator guard"

mkdir -p xporthls/generators
touch xporthls/generators/__init__.py

cat > xporthls/generators/generator_guard.py <<'EOT'
from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass, asdict, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


@dataclass
class GuardIssue:
    severity: str
    code: str
    message: str


@dataclass
class GeneratorGuardDecision:
    allowed: bool
    blocked: bool
    reason: str
    exit_code: int
    issue_codes: list[str] = field(default_factory=list)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_json(path: str | Path, data: dict[str, Any]) -> None:
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def sha256_file(path: str | Path) -> str | None:
    p = Path(path)
    if not p.exists() or not p.is_file():
        return None

    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def simplify_gap(gap: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": gap.get("id"),
        "title": gap.get("title"),
        "category": gap.get("category"),
        "severity": gap.get("severity"),
        "blocks_migration": gap.get("blocks_migration"),
        "status": gap.get("status"),
        "decision": gap.get("decision"),
        "required_action": gap.get("required_action"),
    }


def evaluate_contract(contract: dict[str, Any]) -> tuple[GeneratorGuardDecision, list[GuardIssue]]:
    issues: list[GuardIssue] = []

    schema = contract.get("schema_version")
    if schema != "source_to_target_gap_contract.v1":
        issues.append(GuardIssue(
            severity="error",
            code="CONTRACT_SCHEMA_INVALID",
            message=f"Expected source_to_target_gap_contract.v1, got {schema!r}.",
        ))

    if contract.get("migration_status") != "profile_only":
        issues.append(GuardIssue(
            severity="warning",
            code="MIGRATION_STATUS_NOT_PROFILE_ONLY",
            message=f"Unexpected migration_status: {contract.get('migration_status')!r}.",
        ))

    migration_decision = contract.get("migration_decision", {})
    summary = contract.get("summary", {})

    migration_allowed = bool(migration_decision.get("allowed"))
    contract_state = contract.get("contract_state")
    num_blocking = int(summary.get("num_blocking") or 0)

    blocking_gaps = [
        gap
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "blocking" and gap.get("blocks_migration")
    ]

    if num_blocking != len(blocking_gaps):
        issues.append(GuardIssue(
            severity="error",
            code="BLOCKING_COUNT_MISMATCH",
            message=f"summary.num_blocking={num_blocking}, actual blocking gaps={len(blocking_gaps)}.",
        ))

    if migration_allowed and blocking_gaps:
        issues.append(GuardIssue(
            severity="error",
            code="MIGRATION_ALLOWED_WITH_BLOCKING_GAPS",
            message="Contract allows migration while blocking gaps still exist.",
        ))

    if migration_allowed and contract_state != "ready_for_planning":
        issues.append(GuardIssue(
            severity="error",
            code="ALLOWED_CONTRACT_STATE_INVALID",
            message=f"migration allowed requires contract_state ready_for_planning, got {contract_state!r}.",
        ))

    if not migration_allowed:
        issues.append(GuardIssue(
            severity="blocking",
            code="CONTRACT_BLOCKS_GENERATION",
            message="Gap contract does not allow target generation.",
        ))

    if contract_state == "blocked_profile_only":
        issues.append(GuardIssue(
            severity="blocking",
            code="CONTRACT_STATE_BLOCKED_PROFILE_ONLY",
            message="Contract state is blocked_profile_only.",
        ))

    error_codes = [i.code for i in issues if i.severity == "error"]
    blocking_codes = [i.code for i in issues if i.severity == "blocking"]

    if error_codes:
        return (
            GeneratorGuardDecision(
                allowed=False,
                blocked=True,
                reason="Contract is invalid or internally inconsistent.",
                exit_code=3,
                issue_codes=error_codes + blocking_codes,
            ),
            issues,
        )

    if blocking_codes or not migration_allowed or num_blocking > 0:
        return (
            GeneratorGuardDecision(
                allowed=False,
                blocked=True,
                reason="Target generation blocked by source-to-target gap contract.",
                exit_code=2,
                issue_codes=blocking_codes,
            ),
            issues,
        )

    return (
        GeneratorGuardDecision(
            allowed=True,
            blocked=False,
            reason="Gap contract allows target generation.",
            exit_code=0,
            issue_codes=[],
        ),
        issues,
    )


def build_guard_report(
    contract_path: str,
    requested_output_dir: str,
    generator_name: str,
    requested_action: str,
    dry_run: bool = True,
) -> dict[str, Any]:
    contract = load_json(contract_path)
    decision, issues = evaluate_contract(contract)

    output_path = Path(requested_output_dir)
    output_exists_before = output_path.exists()

    if decision.allowed and not dry_run:
        output_path.mkdir(parents=True, exist_ok=True)
        marker = output_path / "GENERATION_ALLOWED_BY_CONTRACT.txt"
        marker.write_text(
            "Generation was allowed by source-to-target gap contract.\n",
            encoding="utf-8",
        )

    output_exists_after = output_path.exists()

    blocking_gaps = [
        simplify_gap(gap)
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "blocking" and gap.get("blocks_migration")
    ]

    warning_gaps = [
        simplify_gap(gap)
        for gap in contract.get("gaps", [])
        if gap.get("severity") == "warning"
    ]

    return {
        "schema_version": "generator_guard_report.v1",
        "created_at_utc": utc_now(),
        "generator_name": generator_name,
        "requested_action": requested_action,
        "requested_output_dir": requested_output_dir,
        "dry_run": dry_run,
        "contract_ref": {
            "path": contract_path,
            "sha256": sha256_file(contract_path),
            "schema_version": contract.get("schema_version"),
            "contract_id": contract.get("contract_id"),
            "case_id": contract.get("case_id"),
            "contract_state": contract.get("contract_state"),
            "migration_status": contract.get("migration_status"),
            "migration_allowed": contract.get("migration_decision", {}).get("allowed"),
        },
        "decision": asdict(decision),
        "issues": [asdict(i) for i in issues],
        "blocking_gaps": blocking_gaps,
        "warning_gaps": warning_gaps,
        "output_protection": {
            "output_exists_before": output_exists_before,
            "output_exists_after": output_exists_after,
            "output_created_by_guard": (not output_exists_before) and output_exists_after,
            "blocked_generation_created_output": decision.blocked and ((not output_exists_before) and output_exists_after),
        },
        "summary": {
            "allowed": decision.allowed,
            "blocked": decision.blocked,
            "exit_code": decision.exit_code,
            "num_issues": len(issues),
            "num_blocking_gaps": len(blocking_gaps),
            "num_warning_gaps": len(warning_gaps),
            "blocking_gap_ids": [g.get("id") for g in blocking_gaps],
            "warning_gap_ids": [g.get("id") for g in warning_gaps],
        },
    }


def enforce_guard(
    contract_path: str,
    requested_output_dir: str,
    report_out: str,
    generator_name: str = "stub_generator",
    requested_action: str = "generate_target_project",
    dry_run: bool = True,
    expect_blocked: bool = False,
) -> int:
    report = build_guard_report(
        contract_path=contract_path,
        requested_output_dir=requested_output_dir,
        generator_name=generator_name,
        requested_action=requested_action,
        dry_run=dry_run,
    )
    save_json(report_out, report)

    decision = report["decision"]

    print(f"[xporthls] Generator guard report: {report_out}")
    print(f"[xporthls] Generator: {generator_name}")
    print(f"[xporthls] Requested action: {requested_action}")
    print(f"[xporthls] Contract: {contract_path}")
    print(f"[xporthls] Allowed: {decision['allowed']}")
    print(f"[xporthls] Blocked: {decision['blocked']}")
    print(f"[xporthls] Reason: {decision['reason']}")
    print(f"[xporthls] Blocking gaps: {report['summary']['blocking_gap_ids']}")
    print(f"[xporthls] Output created by guard: {report['output_protection']['output_created_by_guard']}")

    if expect_blocked:
        if decision["blocked"]:
            print("[xporthls] Expected block observed.")
            return 0
        print("[xporthls] ERROR: expected generation to be blocked, but it was allowed.")
        return 1

    return int(decision["exit_code"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Contract-gated generator guard")
    parser.add_argument("--contract", required=True)
    parser.add_argument("--requested-output-dir", required=True)
    parser.add_argument("--report-out", required=True)
    parser.add_argument("--generator-name", default="stub_generator")
    parser.add_argument("--requested-action", default="generate_target_project")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--expect-blocked", action="store_true")
    args = parser.parse_args()

    return enforce_guard(
        contract_path=args.contract,
        requested_output_dir=args.requested_output_dir,
        report_out=args.report_out,
        generator_name=args.generator_name,
        requested_action=args.requested_action,
        dry_run=args.dry_run,
        expect_blocked=args.expect_blocked,
    )


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[2/6] Add guarded generator wrapper"

cat > xporthls/generators/run_guarded_stub_generation_v017.py <<'EOT'
from __future__ import annotations

import argparse
from pathlib import Path

from xporthls.generators.generator_guard import enforce_guard


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a contract-gated target generation attempt. In v0.0.17 this is a guard-only wrapper."
    )
    parser.add_argument("--contract", required=True)
    parser.add_argument("--case-id", default="hisparse_u280_profile")
    parser.add_argument("--requested-output-dir", default=None)
    parser.add_argument("--report-out", default=None)
    parser.add_argument("--generator-name", default="stub_generator")
    parser.add_argument("--expect-blocked", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    requested_output_dir = args.requested_output_dir
    if requested_output_dir is None:
        requested_output_dir = f"experiments/runs/{args.case_id}_guarded_generated_v017"

    report_out = args.report_out
    if report_out is None:
        report_out = f"experiments/runs/{args.case_id}_generator_guard_report_v017.json"

    Path(report_out).parent.mkdir(parents=True, exist_ok=True)

    return enforce_guard(
        contract_path=args.contract,
        requested_output_dir=requested_output_dir,
        report_out=report_out,
        generator_name=args.generator_name,
        requested_action="generate_target_project",
        dry_run=args.dry_run,
        expect_blocked=args.expect_blocked,
    )


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[3/6] Add generator guard validator"

cat > xporthls/generators/validate_generator_guard_v017.py <<'EOT'
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Any


@dataclass
class GeneratorGuardIssue:
    severity: str
    code: str
    message: str


@dataclass
class GeneratorGuardValidationReport:
    status: str
    issues: list[GeneratorGuardIssue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str | Path) -> None:
        out = Path(path)
        out.parent.mkdir(parents=True, exist_ok=True)
        with open(out, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def load_json(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def add_issue(issues: list[GeneratorGuardIssue], severity: str, code: str, message: str) -> None:
    issues.append(GeneratorGuardIssue(severity=severity, code=code, message=message))


def validate(report: dict[str, Any], expect_blocked: bool = True) -> GeneratorGuardValidationReport:
    issues: list[GeneratorGuardIssue] = []

    if report.get("schema_version") != "generator_guard_report.v1":
        add_issue(issues, "error", "REPORT_SCHEMA", "Expected generator_guard_report.v1.")

    contract = report.get("contract_ref", {})
    decision = report.get("decision", {})
    output = report.get("output_protection", {})
    summary = report.get("summary", {})

    if contract.get("schema_version") != "source_to_target_gap_contract.v1":
        add_issue(issues, "error", "CONTRACT_SCHEMA", "Guard report must reference source_to_target_gap_contract.v1.")

    if expect_blocked:
        if decision.get("allowed") is not False:
            add_issue(issues, "error", "EXPECTED_ALLOWED_FALSE", "Guard should not allow generation for blocked HiSparse contract.")
        if decision.get("blocked") is not True:
            add_issue(issues, "error", "EXPECTED_BLOCKED_TRUE", "Guard should block generation for blocked HiSparse contract.")
        if int(decision.get("exit_code") or 0) not in {2, 3}:
            add_issue(issues, "error", "EXPECTED_BLOCK_EXIT_CODE", f"Expected guard block exit code 2 or 3, got {decision.get('exit_code')!r}.")
        if contract.get("contract_state") != "blocked_profile_only":
            add_issue(issues, "error", "CONTRACT_STATE_NOT_BLOCKED", "Expected contract_state blocked_profile_only.")
        if contract.get("migration_allowed") is not False:
            add_issue(issues, "error", "CONTRACT_MIGRATION_ALLOWED_NOT_FALSE", "Expected migration_allowed false.")
        if int(summary.get("num_blocking_gaps") or 0) <= 0:
            add_issue(issues, "error", "NO_BLOCKING_GAPS", "Expected at least one blocking gap.")
        if output.get("blocked_generation_created_output"):
            add_issue(issues, "error", "BLOCKED_GENERATION_CREATED_OUTPUT", "Blocked generation must not create requested output directory.")

    required_gap_ids = {
        "GAP-XRT-HOST-001",
        "GAP-PLATFORM-001",
        "GAP-MEM-HBM-001",
        "GAP-STREAM-AXIS-001",
        "GAP-KERNEL-NAME-001",
        "GAP-HLS-INTERFACE-001",
    }
    actual_gap_ids = set(summary.get("blocking_gap_ids", []))
    missing = sorted(required_gap_ids - actual_gap_ids)
    if missing:
        add_issue(issues, "error", "REQUIRED_BLOCKING_GAPS_MISSING", f"Missing required blocking gap ids: {missing}")

    if report.get("llm_annotations"):
        add_issue(issues, "error", "LLM_ANNOTATIONS_NOT_ALLOWED", "Generator guard report must not include LLM annotations.")

    has_error = any(i.severity == "error" for i in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return GeneratorGuardValidationReport(
        status=status,
        issues=issues,
        summary={
            "schema_version": report.get("schema_version"),
            "generator_name": report.get("generator_name"),
            "requested_action": report.get("requested_action"),
            "contract_schema": contract.get("schema_version"),
            "contract_state": contract.get("contract_state"),
            "migration_allowed": contract.get("migration_allowed"),
            "guard_allowed": decision.get("allowed"),
            "guard_blocked": decision.get("blocked"),
            "guard_exit_code": decision.get("exit_code"),
            "num_blocking_gaps": summary.get("num_blocking_gaps"),
            "blocking_gap_ids": summary.get("blocking_gap_ids"),
            "output_created_by_guard": output.get("output_created_by_guard"),
            "blocked_generation_created_output": output.get("blocked_generation_created_output"),
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate generator guard report v0.0.17")
    parser.add_argument("--guard-report", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--expect-blocked", action="store_true")
    args = parser.parse_args()

    report = load_json(args.guard_report)
    validation = validate(report, expect_blocked=args.expect_blocked)
    validation.save(args.out)

    print(f"[xporthls] Generator guard validation written to: {args.out}")
    print(f"[xporthls] Generator guard validation status: {validation.status}")

    for issue in validation.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if validation.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Update README with contract-gated generator guard usage"

python3 - <<'PY'
from pathlib import Path

p = Path("README.md")
text = p.read_text(encoding="utf-8")

section = """
## Contract-gated generator guard

XPortHLS prevents target generation when the source-to-target gap contract blocks migration. A generator wrapper must read the gap contract before creating target output.

Example:

```bash
python3 -m xporthls.generators.run_guarded_stub_generation_v017 \\
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \\
  --case-id hisparse_u280_profile \\
  --expect-blocked \\
  --dry-run
```

For the HiSparse profile-only case, generation is expected to be blocked because the contract contains blocking gaps such as XRT host rewrite, U280-to-V80 platform mapping, HBM memory topology mapping, AXIS/K2K stream mapping, SLR placement, kernel-name resolution, and HLS interface lowering.
"""

if "## Contract-gated generator guard" not in text:
    text = text.rstrip() + "\n\n" + section.strip() + "\n"

p.write_text(text, encoding="utf-8")
PY

echo "[5/6] Create v0.0.17 replay script"

cat > add_generator_guard_v017_replay.sh <<'EOT'
#!/usr/bin/env bash
set -euo pipefail

export XPORT_HISPARSE_SKIP_PULL="${XPORT_HISPARSE_SKIP_PULL:-1}"

REQUESTED_OUT="experiments/runs/hisparse_u280_profile_guarded_generated_v017"
GUARD_REPORT="experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"
GUARD_VALIDATION="experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"

echo "[v0.0.17] Python syntax check"

python3 -m py_compile \
  xporthls/realrepo/repo_census.py \
  xporthls/realrepo/source_platform_profiler.py \
  xporthls/realrepo/compatibility_profiler.py \
  xporthls/realrepo/validate_realrepo_profile_v011.py \
  xporthls/realrepo/run_realrepo_profile_v011.py \
  xporthls/realrepo/build_connectivity_extractor.py \
  xporthls/realrepo/validate_build_connectivity_v012.py \
  xporthls/realrepo/run_build_connectivity_v012.py \
  xporthls/realrepo/hls_interface_extractor.py \
  xporthls/realrepo/validate_hls_interface_v013.py \
  xporthls/realrepo/run_hls_interface_v013.py \
  xporthls/realrepo/application_ir_v2_builder.py \
  xporthls/realrepo/validate_application_ir_v2_v014.py \
  xporthls/realrepo/run_application_ir_v2_v014.py \
  xporthls/realrepo/run_profile_case_v015.py \
  xporthls/realrepo/validate_profile_case_v015.py \
  xporthls/realrepo/run_hisparse_profile_case_v015.py \
  xporthls/realrepo/gap_contract_v016.py \
  xporthls/realrepo/validate_gap_contract_v016.py \
  xporthls/realrepo/run_gap_contract_v016.py \
  xporthls/generators/generator_guard.py \
  xporthls/generators/run_guarded_stub_generation_v017.py \
  xporthls/generators/validate_generator_guard_v017.py

echo "[v0.0.17] Re-run v0.0.15 profile case baseline"

python3 -m xporthls.realrepo.run_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --out-dir experiments/runs \
  --stage-timeout-sec 1800

python3 -m xporthls.realrepo.validate_profile_case_v015 \
  --case-dir cases/hisparse_u280_profile \
  --case-run-report experiments/runs/hisparse_u280_profile_case_run_report_v015.json \
  --out experiments/runs/hisparse_u280_profile_case_validation_v015.json

echo "[v0.0.17] Re-run v0.0.16 gap contract baseline"

python3 -m xporthls.realrepo.run_gap_contract_v016 \
  --case-id hisparse_u280_profile \
  --app-ir experiments/runs/hisparse_application_ir_v2_v014.json \
  --expected-gaps cases/hisparse_u280_profile/expected_gaps.json \
  --platform-pack platform_packs/v80_aved_2025_1_stub \
  --out-dir experiments/runs

echo "[v0.0.17] Ensure blocked generation output path is absent"

rm -rf "$REQUESTED_OUT"

echo "[v0.0.17] Attempt guarded generation; this must be blocked"

python3 -m xporthls.generators.run_guarded_stub_generation_v017 \
  --contract experiments/runs/hisparse_u280_profile_gap_contract_v016.json \
  --case-id hisparse_u280_profile \
  --requested-output-dir "$REQUESTED_OUT" \
  --report-out "$GUARD_REPORT" \
  --generator-name stub_generator \
  --expect-blocked \
  --dry-run

echo "[v0.0.17] Validate generator guard report"

python3 -m xporthls.generators.validate_generator_guard_v017 \
  --guard-report "$GUARD_REPORT" \
  --out "$GUARD_VALIDATION" \
  --expect-blocked

python3 - <<'PY'
import json
from pathlib import Path

contract = json.load(open("experiments/runs/hisparse_u280_profile_gap_contract_v016.json"))
guard = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_report_v017.json"))
validation = json.load(open("experiments/runs/hisparse_u280_profile_generator_guard_validation_v017.json"))

requested_out = Path("experiments/runs/hisparse_u280_profile_guarded_generated_v017")

print()
print("Contract schema:", contract["schema_version"])
print("Contract state:", contract["contract_state"])
print("Contract migration allowed:", contract["migration_decision"]["allowed"])
print("Guard schema:", guard["schema_version"])
print("Guard allowed:", guard["decision"]["allowed"])
print("Guard blocked:", guard["decision"]["blocked"])
print("Guard exit code:", guard["decision"]["exit_code"])
print("Guard reason:", guard["decision"]["reason"])
print("Blocking gaps:", guard["summary"]["blocking_gap_ids"])
print("Output exists after guard:", requested_out.exists())
print("Blocked generation created output:", guard["output_protection"]["blocked_generation_created_output"])
print("Guard validation status:", validation["status"])

required_ids = {
    "GAP-XRT-HOST-001",
    "GAP-PLATFORM-001",
    "GAP-MEM-HBM-001",
    "GAP-STREAM-AXIS-001",
    "GAP-KERNEL-NAME-001",
    "GAP-HLS-INTERFACE-001",
}
actual_ids = set(guard["summary"]["blocking_gap_ids"])

assert contract["schema_version"] == "source_to_target_gap_contract.v1"
assert contract["contract_state"] == "blocked_profile_only"
assert contract["migration_decision"]["allowed"] is False
assert guard["schema_version"] == "generator_guard_report.v1"
assert guard["contract_ref"]["schema_version"] == "source_to_target_gap_contract.v1"
assert guard["decision"]["allowed"] is False
assert guard["decision"]["blocked"] is True
assert guard["decision"]["exit_code"] == 2
assert guard["output_protection"]["blocked_generation_created_output"] is False
assert not requested_out.exists()
assert required_ids.issubset(actual_ids)
assert validation["status"] == "pass"
PY

echo
echo "DONE."
EOT

chmod +x add_generator_guard_v017_replay.sh

echo "[6/6] Run v0.0.17 replay"

./add_generator_guard_v017_replay.sh

echo "[v0.0.17] Git status"

git status
