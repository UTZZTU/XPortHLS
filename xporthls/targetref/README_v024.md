# Target Reference Intake v0.0.24

This module converts a known-good AVED/V80 target reference project into `TargetReferenceIR v1`.

Current primary target reference:

```text
SPMV-on-V80-main
```

Expected external location:

```text
/mnt/data/xporthls_target_refs/SPMV-on-V80-main
```

This module is deterministic. It does not call an LLM, does not modify the gap contract, and does not unlock the generator.

Primary artifacts:

```text
experiments/runs/spmv_on_v80_target_reference_ir_v024.json
experiments/runs/spmv_on_v80_target_reference_report_v024.json
experiments/runs/spmv_on_v80_target_reference_validation_v024.json
```
