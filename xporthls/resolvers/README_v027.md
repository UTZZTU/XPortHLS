# AVED Host Runtime Pattern Resolver v0.0.27

This module extracts the first target-aware host runtime pattern for:

```text
GAP-XRT-HOST-001
```

It maps source XRT host actions to target AVED/V80 host mechanisms:

```text
xrt::device / xrt::kernel / xrt::bo / bo.sync / run.start / run.wait
  ->
QDMA transfer + AXI-Lite register access + AP_CTRL polling
```

This version is pattern-only:

```text
LLM used: false
Contract modified: false
Generator unlocked: false
GAP-XRT-HOST-001 resolved: false
```

Expected artifacts:

```text
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_report_v027.json
experiments/runs/hisparse_u280_profile_to_spmv_on_v80_aved_host_runtime_pattern_validation_v027.json
```
