#!/usr/bin/env bash
set -e

echo "[1/8] Add common L0 report classes"

cat > xporthls/validators/l0_common.py <<'EOT'
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
EOT

echo "[2/8] Add L0-pre checker"

cat > xporthls/validators/l0_pre_checker.py <<'EOT'
from __future__ import annotations

from typing import Any

from xporthls.ir.schema_checks import check_application_ir_schema
from xporthls.validators.l0_common import L0Issue, L0Report, classify_status, load_json


def run_l0_pre(app_ir_path: str, contract_path: str | None = None) -> L0Report:
    app = load_json(app_ir_path)

    contract: dict[str, Any] | None = None
    if contract_path:
        contract = load_json(contract_path)

    issues: list[L0Issue] = []

    for issue in check_application_ir_schema(app):
        issues.append(L0Issue(
            severity=issue["severity"],
            code=issue["code"],
            message=issue["message"],
        ))

    source_files = app.get("source_files", [])
    host_apis = app.get("host_apis", [])
    kernels = app.get("kernels", [])
    build_targets = app.get("build_targets", [])
    buffers = app.get("buffers", [])
    kernel_invocations = app.get("kernel_invocations", [])
    sync_operations = app.get("sync_operations", [])
    host_transfers = app.get("host_transfers", [])
    unknowns = app.get("unknowns", [])
    facts = app.get("facts", {})
    case_metadata = app.get("case_metadata", {})

    if not case_metadata:
        issues.append(L0Issue(
            "warning",
            "NO_CASE_METADATA",
            "ApplicationIR has no case_metadata. Add case.yaml for this case.",
        ))
    else:
        if not case_metadata.get("case_id"):
            issues.append(L0Issue("error", "CASE_METADATA_NO_ID", "case_metadata must include case_id."))
        if not case_metadata.get("validation_targets"):
            issues.append(L0Issue(
                "warning",
                "CASE_METADATA_NO_VALIDATION_TARGETS",
                "case_metadata should include validation_targets.",
            ))

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if host_apis and not buffers:
        issues.append(L0Issue(
            "warning",
            "NO_XRT_BUFFERS",
            "XRT API calls were detected, but no xrt::bo buffers were extracted.",
        ))

    if buffers and not kernel_invocations:
        issues.append(L0Issue(
            "warning",
            "NO_KERNEL_INVOCATION",
            "Buffers were detected, but no kernel invocation was extracted.",
        ))

    if buffers and not sync_operations:
        issues.append(L0Issue(
            "warning",
            "NO_SYNC_OPERATIONS",
            "Buffers were detected, but no bo.sync operations were extracted.",
        ))

    if buffers and not host_transfers:
        issues.append(L0Issue(
            "warning",
            "NO_HOST_TRANSFERS",
            "Buffers were detected, but no bo.write/bo.read operations were extracted.",
        ))

    if unknowns:
        issues.append(L0Issue(
            "warning",
            "IR_UNKNOWNS_PRESENT",
            f"ApplicationIR contains {len(unknowns)} unknown semantic fields.",
        ))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))

    if facts:
        xrt_facts = facts.get("xrt", {})
        if len(xrt_facts.get("buffers", [])) != len(buffers):
            issues.append(L0Issue(
                "error",
                "FACTS_BUFFER_MISMATCH",
                "facts.xrt.buffers length does not match top-level buffers length.",
            ))

        if len(xrt_facts.get("kernel_invocations", [])) != len(kernel_invocations):
            issues.append(L0Issue(
                "error",
                "FACTS_KERNEL_INVOCATION_MISMATCH",
                "facts.xrt.kernel_invocations length does not match top-level kernel_invocations length.",
            ))

        facts_case = facts.get("case", {})
        if facts_case and facts_case != case_metadata:
            issues.append(L0Issue(
                "error",
                "FACTS_CASE_METADATA_MISMATCH",
                "facts.case does not match top-level case_metadata.",
            ))

    if contract is not None:
        if not contract.get("obligations"):
            issues.append(L0Issue("error", "NO_CONTRACT_OBLIGATIONS", "MigrationContract has no obligations."))
        if not contract.get("target_platform"):
            issues.append(L0Issue("error", "NO_TARGET_PLATFORM", "MigrationContract has no target platform."))
        if not contract.get("source_project"):
            issues.append(L0Issue("error", "NO_SOURCE_PROJECT", "MigrationContract has no source project."))

    status = classify_status(issues)

    return L0Report(
        status=status,
        stage="L0-pre",
        issues=issues,
        summary={
            "project": app.get("project", "unknown"),
            "schema_version": facts.get("schema_version", "unknown") if isinstance(facts, dict) else "missing",
            "case_id": case_metadata.get("case_id", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_role": case_metadata.get("role", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_memory_type": case_metadata.get("memory_type", "unknown") if isinstance(case_metadata, dict) else "missing",
            "case_validation_targets": case_metadata.get("validation_targets", []) if isinstance(case_metadata, dict) else [],
            "num_source_files": len(source_files),
            "num_xrt_calls": len(host_apis),
            "num_kernel_candidates": len(kernels),
            "num_build_targets": len(build_targets),
            "num_buffers": len(buffers),
            "num_kernel_invocations": len(kernel_invocations),
            "num_sync_operations": len(sync_operations),
            "num_host_transfers": len(host_transfers),
            "num_unknowns": len(unknowns),
            "has_facts": isinstance(facts, dict) and bool(facts),
            "has_contract": contract is not None,
        },
    )
EOT

echo "[3/8] Add L0-post checker"

cat > xporthls/validators/l0_post_checker.py <<'EOT'
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
EOT

echo "[4/8] Keep old l0_static_checker.py as compatibility wrapper"

cat > xporthls/validators/l0_static_checker.py <<'EOT'
from __future__ import annotations

from xporthls.validators.l0_common import L0Issue, L0Report
from xporthls.validators.l0_pre_checker import run_l0_pre


def run_l0_static(app_ir_path: str, contract_path: str | None = None) -> L0Report:
    """
    Backward-compatible wrapper.

    Historical name:
      run_l0_static

    Current name:
      run_l0_pre
    """
    return run_l0_pre(app_ir_path, contract_path)
EOT

echo "[5/8] Update standalone L0 runner"

cat > xporthls/validators/run_l0.py <<'EOT'
from __future__ import annotations

import argparse

from xporthls.validators.l0_pre_checker import run_l0_pre
from xporthls.validators.l0_post_checker import run_l0_post


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XPortHLS L0 validation")
    parser.add_argument("--stage", choices=["pre", "post"], default="pre")
    parser.add_argument("--app-ir", default=None, help="ApplicationIR JSON path for L0-pre")
    parser.add_argument("--contract", default=None, help="MigrationContract JSON path")
    parser.add_argument("--project", default=None, help="Generated project path for L0-post")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    if args.stage == "pre":
        if not args.app_ir:
            parser.error("--app-ir is required for --stage pre")
        report = run_l0_pre(args.app_ir, args.contract)
    else:
        if not args.project:
            parser.error("--project is required for --stage post")
        report = run_l0_post(args.project, args.contract)

    report.save(args.out)

    print(f"[xporthls] {report.stage} report written to: {args.out}")
    print(f"[xporthls] {report.stage} status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[6/8] Add CLI validate command"

python3 - <<'PY'
from pathlib import Path

path = Path("xporthls/cli.py")
text = path.read_text(encoding="utf-8")

if "from xporthls.validators.l0_pre_checker import run_l0_pre" not in text:
    text = text.replace(
        "from xporthls.trace.run_logger import RunTrace, utc_now, new_run_dir, run_command\n",
        "from xporthls.trace.run_logger import RunTrace, utc_now, new_run_dir, run_command\n"
        "from xporthls.validators.l0_pre_checker import run_l0_pre\n"
        "from xporthls.validators.l0_post_checker import run_l0_post\n"
    )

if "def cmd_validate(args: argparse.Namespace)" not in text:
    marker = "\ndef cmd_report(args: argparse.Namespace) -> int:\n"
    insert = '''
def cmd_validate(args: argparse.Namespace) -> int:
    if args.level == "L0-pre":
        if not args.app_ir:
            raise SystemExit("--app-ir is required for L0-pre")
        report = run_l0_pre(args.app_ir, args.contract)
    elif args.level == "L0-post":
        if not args.project:
            raise SystemExit("--project is required for L0-post")
        report = run_l0_post(args.project, args.contract)
    else:
        raise SystemExit(f"Unsupported validation level: {args.level}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    report.save(str(out))

    print(f"[xporthls] {report.stage} report written to: {out}")
    print(f"[xporthls] {report.stage} status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


'''
    if marker not in text:
        raise SystemExit("Could not find cmd_report marker.")
    text = text.replace(marker, "\n" + insert + "def cmd_report(args: argparse.Namespace) -> int:\n")

if 'validate_p = sub.add_parser("validate"' not in text:
    marker = '''    report_p = sub.add_parser("report", help="Summarize traces")
'''
    insert = '''    validate_p = sub.add_parser("validate", help="Run validation levels")
    validate_p.add_argument("--level", required=True, choices=["L0-pre", "L0-post"])
    validate_p.add_argument("--app-ir", default=None, help="ApplicationIR JSON path for L0-pre")
    validate_p.add_argument("--contract", default=None, help="MigrationContract JSON path")
    validate_p.add_argument("--project", default=None, help="Generated project path for L0-post")
    validate_p.add_argument("--out", required=True, help="Output validation report JSON path")
    validate_p.set_defaults(func=cmd_validate)

'''
    if marker not in text:
        raise SystemExit("Could not find report parser marker.")
    text = text.replace(marker, insert + marker)

path.write_text(text, encoding="utf-8")
PY

echo "[7/8] Update README checklist"

python3 - <<'PY'
from pathlib import Path

path = Path("README.md")
text = path.read_text(encoding="utf-8")

text = text.replace("### Phase 7 — L0-pre and L0-post\n\nStatus: planned.", "### Phase 7 — L0-pre and L0-post\n\nStatus: in progress.")
text = text.replace("- [ ] Split current L0 checker into L0-pre and L0-post", "- [x] Split current L0 checker into L0-pre and L0-post")
text = text.replace("- [ ] L0-pre checks source project, ApplicationIR, Platform Pack and MigrationContract", "- [x] L0-pre checks source project, ApplicationIR, case metadata and MigrationContract")
text = text.replace("- [ ] L0-post checks generated project, forbidden APIs, register/address maps and templates", "- [x] L0-post checks generated project and forbidden XRT API/artifact leftovers")
text = text.replace("- [ ] Add JSON reports for both stages", "- [x] Add JSON reports for both stages")

path.write_text(text, encoding="utf-8")
PY

echo "[8/8] Run L0-pre and L0-post tests"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir_v006.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir_v006.json \
  --platform config/platforms/v80_aved_2025_1_stub.json \
  --out experiments/runs/light_ddr_migration_contract_v006.json

python3 -m xporthls.validators.run_l0 \
  --stage pre \
  --app-ir experiments/runs/light_ddr_application_ir_v006.json \
  --contract experiments/runs/light_ddr_migration_contract_v006.json \
  --out experiments/runs/light_ddr_l0_pre_report_v006.json

GEN_STUB="experiments/runs/light_ddr_generated_stub_v006"
mkdir -p "$GEN_STUB/hls" "$GEN_STUB/host" "$GEN_STUB/bd_tcl" "$GEN_STUB/build"

cat > "$GEN_STUB/xporthls_generated_manifest.json" <<'EOT'
{
  "case_id": "light_ddr",
  "target_platform": "v80_aved_2025_1_stub",
  "generator_status": "stub",
  "artifacts": {
    "hls_ip": "hls/vadd.cpp",
    "host": "host/qdma_host.cpp",
    "bd_tcl": "bd_tcl/create_bd.tcl",
    "build": "build/build.sh"
  }
}
EOT

cat > "$GEN_STUB/hls/vadd.cpp" <<'EOT'
extern "C" {
void vadd(const int* in1, const int* in2, int* out, int n) {
    for (int i = 0; i < n; ++i) {
        out[i] = in1[i] + in2[i];
    }
}
}
EOT

cat > "$GEN_STUB/host/qdma_host.cpp" <<'EOT'
// Stub QDMA host generated by XPortHLS.
// No XRT API should remain in this generated host skeleton.
int main() {
    return 0;
}
EOT

cat > "$GEN_STUB/bd_tcl/create_bd.tcl" <<'EOT'
# Stub BD Tcl generated by XPortHLS.
EOT

cat > "$GEN_STUB/build/build.sh" <<'EOT'
#!/usr/bin/env bash
echo "Stub build script"
EOT

python3 -m xporthls.validators.run_l0 \
  --stage post \
  --project "$GEN_STUB" \
  --contract experiments/runs/light_ddr_migration_contract_v006.json \
  --out experiments/runs/light_ddr_l0_post_report_v006.json

python3 -m xporthls.cli validate \
  --level L0-pre \
  --app-ir experiments/runs/light_ddr_application_ir_v006.json \
  --contract experiments/runs/light_ddr_migration_contract_v006.json \
  --out experiments/runs/light_ddr_l0_pre_report_v006_cli.json

python3 - <<'PY'
import json

pre = json.load(open("experiments/runs/light_ddr_l0_pre_report_v006.json"))
post = json.load(open("experiments/runs/light_ddr_l0_post_report_v006.json"))
cli_pre = json.load(open("experiments/runs/light_ddr_l0_pre_report_v006_cli.json"))

print()
print("L0-pre status:", pre["status"])
print("L0-post status:", post["status"])
print("CLI L0-pre status:", cli_pre["status"])
print()
print("L0-post summary:")
print(json.dumps(post["summary"], indent=2))
PY

echo
echo "DONE."
echo "Check:"
echo "  cat experiments/runs/light_ddr_l0_pre_report_v006.json"
echo "  cat experiments/runs/light_ddr_l0_post_report_v006.json"
echo "  git status"
