# XPortHLS Scripts

This directory keeps replay, legacy, and bootstrap shell scripts out of the repository root.

## Directory Layout

```text
scripts/
  README.md

  replay/
    Stable replay entry points for reproducing versioned milestones.

  legacy_full/
    Large historical full-generation scripts. Preserved for auditability,
    but not recommended as daily entry points.

  bootstrap/
    Early one-off project bootstrap scripts from the initial scaffold and
    early IR / contract / generator setup.
```

## scripts/replay

`./scripts/replay/` contains stable replay entry points.

Use this directory when you want to reproduce a specific versioned milestone.

Examples:

```bash
./scripts/replay/add_model_adapter_v023_replay.sh
./scripts/replay/add_target_reference_intake_v024_replay.sh
./scripts/replay/add_pattern_pairing_v025_replay.sh
./scripts/replay/add_target_aware_resolver_plan_v026_replay.sh
```

These scripts are preferred over root-level one-off scripts.

## scripts/legacy_full

`./scripts/legacy_full/` contains large historical full-generation scripts.

These scripts are preserved for auditability and reproducibility of earlier development steps, but they are not the preferred daily execution path.

Examples:

```text
add_model_adapter_v023_full.sh
add_target_reference_intake_v024_full.sh
add_pattern_pairing_v025_full.sh
add_target_aware_resolver_plan_v026_full.sh
```

Use them only when you intentionally want to replay the full generated patch process.

## scripts/bootstrap

`./scripts/bootstrap/` contains early one-off project bootstrap scripts.

Examples:

```text
add_application_ir_v1.sh
add_case_yaml_v005.sh
add_contract_v1_v008.sh
add_evidence_system_v010.sh
add_generator_stub_v009.sh
add_light_ddr_and_l0.sh
add_platform_pack_v007.sh
add_xrt_semantic_extractor_v1.sh
rebuild_v007_final_clean.sh
split_l0_pre_post_v006.sh
```

These scripts document how the initial project scaffold and early IR / contract / generator layers were created.

## Repository Root Policy

The repository root should stay clean.

Do not keep new versioned `.sh` scripts in the root directory.

Preferred locations:

```text
scripts/replay/       stable replay scripts
scripts/legacy_full/  full historical generation scripts
scripts/bootstrap/    early setup scripts
```

From v0.0.27 onward, new scripts should follow this rule:

```text
Full script:
  scripts/legacy_full/add_<feature>_vXXX_full.sh

Replay script:
  scripts/replay/add_<feature>_vXXX_replay.sh
```

## What Should Be Committed

Commit:

```text
Python source code
validators
runner modules
stable replay scripts
legacy full scripts, if useful for auditability
README updates
small case metadata
schema files
```

Do not commit:

```text
runtime artifacts
external benchmark repositories
target reference repositories
large zip files
generated experiment outputs
Vivado / HLS / AVED build products
```

## Do Not Commit Runtime Artifacts

Do not commit files such as:

```text
experiments/runs/*.json
experiments/runs/*_v024.json
experiments/runs/*_v025.json
experiments/runs/*_v026.json
experiments/runs/*_generated*
```

Do not commit external repositories or large references:

```text
/mnt/data/xporthls_benchmarks/HiSparse
/mnt/data/xporthls_target_refs/SPMV-on-V80-main
/mnt/data/SPMV-on-V80-main.zip
SPMV-on-V80-main.zip
```

## Recommended Replay Usage

From the repository root:

```bash
cd /home/wwb/XPortHLS

./scripts/replay/add_target_reference_intake_v024_replay.sh
./scripts/replay/add_pattern_pairing_v025_replay.sh
./scripts/replay/add_target_aware_resolver_plan_v026_replay.sh
```

## Notes

The scripts are part of the reproducibility evidence, so they should not be deleted casually.

However, root-level script clutter makes the repository harder to read. Keeping scripts under `scripts/` makes the project look more like a stable framework and less like a collection of temporary shell commands.
