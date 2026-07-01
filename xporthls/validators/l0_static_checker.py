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
