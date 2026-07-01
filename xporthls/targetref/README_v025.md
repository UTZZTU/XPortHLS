# Source-Target Pattern Pairing v0.0.25

This module pairs source-side HiSparse ApplicationIR evidence with target-side SPMV-on-V80 TargetReferenceIR evidence.

It produces candidate pattern pairings for the six post-v0.0.22 remaining blockers:

```text
GAP-XRT-HOST-001
GAP-PLATFORM-001
GAP-MEM-HBM-001
GAP-STREAM-AXIS-001
GAP-PLACEMENT-SLR-001
GAP-HLS-INTERFACE-001
```

This version is read-only and deterministic:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
Gaps resolved by v0.0.25: 0
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_report_v025.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_pattern_pairing_validation_v025.json
```
