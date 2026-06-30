#!/usr/bin/env bash
set -e

echo "[1/6] Creating light_ddr fixture"

mkdir -p cases/light_ddr/src cases/light_ddr/data cases/light_ddr/tests

cat > cases/light_ddr/README.md <<'EOT'
# light_ddr

A lightweight XRT/Vitis HLS-style DDR example used as the first development fixture for XPortHLS.

Purpose:

- Validate repository scanning.
- Validate ApplicationIR extraction.
- Validate XRT host API detection.
- Validate HLS pragma/kernel candidate detection.
- Validate L0 static checks.

This is not the final benchmark. It is a local fixture for developing XPortHLS without V80/AVED access.
EOT

cat > cases/light_ddr/src/host.cpp <<'EOT'
#include <iostream>
#include <vector>
#include <cstdint>

// This file is a scanner fixture. It intentionally uses XRT-style API names.
// It does not need to compile on machines without XRT headers.

#include "xrt/xrt_device.h"
#include "xrt/xrt_bo.h"
#include "xrt/xrt_kernel.h"

int main(int argc, char** argv) {
    const int n = 1024;
    std::vector<int> in1(n, 1);
    std::vector<int> in2(n, 2);
    std::vector<int> out(n, 0);

    auto device = xrt::device(0);
    auto uuid = device.load_xclbin("vadd.xclbin");
    auto kernel = xrt::kernel(device, uuid, "vadd");

    auto bo_in1 = xrt::bo(device, n * sizeof(int), kernel.group_id(0));
    auto bo_in2 = xrt::bo(device, n * sizeof(int), kernel.group_id(1));
    auto bo_out = xrt::bo(device, n * sizeof(int), kernel.group_id(2));

    bo_in1.write(in1.data());
    bo_in2.write(in2.data());

    bo_in1.sync(XCL_BO_SYNC_BO_TO_DEVICE);
    bo_in2.sync(XCL_BO_SYNC_BO_TO_DEVICE);

    auto run = kernel(bo_in1, bo_in2, bo_out, n);
    run.wait();

    bo_out.sync(XCL_BO_SYNC_BO_FROM_DEVICE);
    bo_out.read(out.data());

    for (int i = 0; i < n; ++i) {
        if (out[i] != 3) {
            std::cerr << "Mismatch at " << i << std::endl;
            return 1;
        }
    }

    std::cout << "PASS" << std::endl;
    return 0;
}
EOT

cat > cases/light_ddr/src/vadd.cpp <<'EOT'
#include <stdint.h>

extern "C" {
void vadd(const int* in1, const int* in2, int* out, int n) {
#pragma HLS INTERFACE m_axi port=in1 offset=slave bundle=gmem0
#pragma HLS INTERFACE m_axi port=in2 offset=slave bundle=gmem1
#pragma HLS INTERFACE m_axi port=out offset=slave bundle=gmem2
#pragma HLS INTERFACE s_axilite port=in1 bundle=control
#pragma HLS INTERFACE s_axilite port=in2 bundle=control
#pragma HLS INTERFACE s_axilite port=out bundle=control
#pragma HLS INTERFACE s_axilite port=n bundle=control
#pragma HLS INTERFACE s_axilite port=return bundle=control

    for (int i = 0; i < n; ++i) {
#pragma HLS PIPELINE II=1
        out[i] = in1[i] + in2[i];
    }
}
}
EOT

cat > cases/light_ddr/Makefile <<'EOT'
# Scanner fixture Makefile.
# Final build rules will be replaced by generated AVED/Vivado scripts.

APP := host
KERNEL := vadd

.PHONY: all clean test

all:
	@echo "Placeholder build for $(APP) and $(KERNEL)"

test:
	@echo "Placeholder test"

clean:
	rm -rf build
EOT

cat > cases/light_ddr/tests/golden.json <<'EOT'
{
  "test": "vadd_light_ddr",
  "n": 1024,
  "input_value_1": 1,
  "input_value_2": 2,
  "expected_value": 3,
  "tolerance": {
    "abs": 0,
    "rel": 0
  }
}
EOT

echo "[2/6] Creating L0 static checker"

cat > xporthls/validators/l0_static_checker.py <<'EOT'
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
    issues: list[L0Issue] = field(default_factory=list)
    summary: dict[str, Any] = field(default_factory=dict)

    def save(self, path: str) -> None:
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(asdict(self), f, indent=2, ensure_ascii=False)
            f.write("\n")


def run_l0_static(app_ir_path: str, contract_path: str | None = None) -> L0Report:
    with open(app_ir_path, "r", encoding="utf-8") as f:
        app = json.load(f)

    contract = None
    if contract_path:
        with open(contract_path, "r", encoding="utf-8") as f:
            contract = json.load(f)

    issues: list[L0Issue] = []

    source_files = app.get("source_files", [])
    host_apis = app.get("host_apis", [])
    kernels = app.get("kernels", [])
    build_targets = app.get("build_targets", [])

    if not source_files:
        issues.append(L0Issue("error", "NO_SOURCE_FILES", "No source files were discovered."))

    if not host_apis:
        issues.append(L0Issue("warning", "NO_XRT_CALLS", "No XRT API calls were detected."))

    if not kernels:
        issues.append(L0Issue("warning", "NO_KERNEL_CANDIDATES", "No HLS kernel candidates were detected."))

    if not build_targets:
        issues.append(L0Issue("warning", "NO_BUILD_ENTRY", "No Makefile/CMake build entry was detected."))

    if contract is not None:
        if not contract.get("obligations"):
            issues.append(L0Issue("error", "NO_CONTRACT_OBLIGATIONS", "MigrationContract has no obligations."))
        if not contract.get("target_platform"):
            issues.append(L0Issue("error", "NO_TARGET_PLATFORM", "MigrationContract has no target platform."))

    has_error = any(issue.severity == "error" for issue in issues)
    status = "fail" if has_error else "pass_with_warnings" if issues else "pass"

    return L0Report(
        status=status,
        issues=issues,
        summary={
            "project": app.get("project", "unknown"),
            "num_source_files": len(source_files),
            "num_xrt_calls": len(host_apis),
            "num_kernel_candidates": len(kernels),
            "num_build_targets": len(build_targets),
            "has_contract": contract is not None,
        },
    )
EOT

echo "[3/6] Adding standalone L0 runner"

cat > xporthls/validators/run_l0.py <<'EOT'
from __future__ import annotations

import argparse
from xporthls.validators.l0_static_checker import run_l0_static


def main() -> int:
    parser = argparse.ArgumentParser(description="Run XPortHLS L0 static validation")
    parser.add_argument("--app-ir", required=True)
    parser.add_argument("--contract", default=None)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    report = run_l0_static(args.app_ir, args.contract)
    report.save(args.out)

    print(f"[xporthls] L0 report written to: {args.out}")
    print(f"[xporthls] L0 status: {report.status}")
    for issue in report.issues:
        print(f"  - {issue.severity.upper()} {issue.code}: {issue.message}")

    return 0 if report.status in {"pass", "pass_with_warnings"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
EOT

echo "[4/6] Updating notes"

cat > docs/appendix/development_log.md <<'EOT'
# XPortHLS Development Log

## v0.0.1

Initial scaffold:

- CLI skeleton
- Environment report
- ApplicationIR dataclass
- PlatformIR dataclass
- MigrationContract dataclass
- Repository scanner
- Trace logger
- AVED 2025.1 stub platform

## v0.0.2

Added local light_ddr fixture and L0 static checker.

Purpose:

- Test XRT API scanning.
- Test HLS pragma scanning.
- Test build entry detection.
- Test basic static validation without V80/AVED.
EOT

echo "[5/6] Running light_ddr scan + contract + L0"

python3 -m xporthls.cli scan \
  --case cases/light_ddr \
  --out experiments/runs/light_ddr_application_ir.json

python3 -m xporthls.cli contract \
  --app-ir experiments/runs/light_ddr_application_ir.json \
  --platform config/platforms/v80_aved_2025_1_stub.json \
  --out experiments/runs/light_ddr_migration_contract.json

python3 -m xporthls.validators.run_l0 \
  --app-ir experiments/runs/light_ddr_application_ir.json \
  --contract experiments/runs/light_ddr_migration_contract.json \
  --out experiments/runs/light_ddr_l0_report.json

echo "[6/6] Git commit"

git add .
git commit -m "Add light DDR fixture and L0 static checker" || true

echo
echo "DONE."
echo
echo "Check outputs:"
echo "  cat experiments/runs/light_ddr_application_ir.json"
echo "  cat experiments/runs/light_ddr_l0_report.json"
