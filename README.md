# XPortHLS

**XPortHLS** is a version-aware migration agent framework for migrating XRT/Vitis HLS applications into native AVED projects.

Recommended competition title:

> XPortHLS: Version-Aware Migration of XRT-Based HLS Applications to Native AVED Projects

## 1. Core Principle

XPortHLS is not a free-form code generation chatbot.

It follows:

> Compiler-like Migration Pipeline + Agentic Repair Loop

The deterministic pipeline handles facts, IR, contracts, templates, validation and trace.  
The LLM only provides candidate explanations, migration plans, failure diagnosis and bounded local patch suggestions.

The LLM is **not**:

- the source of platform facts
- the executor
- the correctness judge
- the owner of trace records

Correctness is decided by contracts, static checks, tools and tests.

---

## 2. Current Repository Status

Current implementation:

```text
XPortHLS v0.0.2
```

Implemented so far:

- Project scaffold
- CLI entry
- Environment reporting
- Trace logger
- Repository scanner v0
- ApplicationIR v0
- PlatformIR v0
- MigrationContract v0
- L0 static checker v0
- light_ddr fixture
- Git initialized

Current working flow:

```text
cases/light_ddr
  ↓
repo scanner
  ↓
ApplicationIR
  ↓
MigrationContract
  ↓
L0 static checker
  ↓
trace
```

---

## 3. Eight-Layer Architecture

XPortHLS uses eight layers:

| Layer | Responsibility | Current Code Status |
|---|---|---|
| 1. Case Layer | case.yaml, source code, tests, golden outputs, complexity tags | light_ddr exists, case.yaml not yet |
| 2. Platform Pack Layer | AVED version pack, capabilities, QDMA/memory/register rules, templates | stub JSON exists |
| 3. Front-end Layer | repo scan, XRT semantic extraction, HLS interface extraction, build graph extraction | scanner v0 exists |
| 4. IR / Contract Layer | ApplicationIR, PlatformIR, MigrationContract and subcontracts | v0 exists |
| 5. Generation Layer | HLS IP, register map, address map, QDMA host, BD/Tcl, build scripts | directory only |
| 6. Validation Layer | L0-pre, L0-post, L1, L2, L3, L4, L5 | L0 v0 exists |
| 7. Agent Loop Layer | diagnosis, patch planning, patch control, rollback, revalidation | directory only |
| 8. Evidence Layer | trace, artifact registry, patch ledger, budget ledger, replay | trace v0 exists |

---

## 4. LLM Participation Policy

| Layer | LLM Participation | Degree | LLM Role | Not Allowed |
|---|---:|---:|---|---|
| 1. Case Layer | No runtime role | 0–5% | May help write case descriptions offline | Must not invent tests or golden outputs |
| 2. Platform Pack | Offline only | 5–15% | Help read docs and propose candidate rules | Must not define runtime platform facts dynamically |
| 3. Front-end | Low to medium | 20–30% | Semantic hints for non-standard repository structure and wrappers | Must not overwrite extracted facts |
| 4. IR / Contract | Low to medium | 15–25% | Suggest annotations, unknowns and special mapping candidates | Must not create final facts or verified contracts |
| 5. Generation | Medium | 20–40% | Plan generation steps or produce small bounded diffs | Must not freely generate the whole platform project |
| 6. Validation | No execution role | 0–5% | May read summarized reports for later diagnosis | Must not judge pass/fail or fake tool results |
| 7. Agent Loop | High but controlled | 50–70% | Diagnose root cause, choose failure type, propose patch plan | Must not apply unbounded patches or skip validation |
| 8. Evidence | No write role | 0–5% | May read trace summary for diagnosis or reporting | Must not edit trace, budget, patch ledger or tool records |

Main rule:

> LLM outputs are always candidates. Contracts, controllers, tools and tests decide what is accepted.

---

## 5. Planned Development Checklist

### Phase 0 — Repository Scaffold

Status: done.

- [x] Create repository structure
- [x] Add CLI
- [x] Add ApplicationIR v0
- [x] Add PlatformIR v0
- [x] Add MigrationContract v0
- [x] Add trace logger
- [x] Add AVED/V80 2025.1 stub platform config
- [x] Initialize Git

### Phase 1 — Minimal Case and L0

Status: done.

- [x] Add light_ddr fixture
- [x] Add XRT-style host.cpp
- [x] Add HLS-style vadd.cpp
- [x] Add golden.json
- [x] Add L0 static checker v0
- [x] Run scan → contract → L0
- [x] Commit v0.0.2 baseline

### Phase 2 — XRT Semantic Extractor v1

Status: next.

Goal:

Extract structured XRT host semantics instead of only matching strings.

Checklist:

- [ ] Add `xporthls/scanner/xrt_semantic_extractor.py`
- [ ] Extract `xrt::bo` buffer names
- [ ] Extract buffer size expressions
- [ ] Extract `kernel.group_id(N)`
- [ ] Extract `bo.write(...)`
- [ ] Extract `bo.read(...)`
- [ ] Extract `bo.sync(XCL_BO_SYNC_BO_TO_DEVICE)`
- [ ] Extract `bo.sync(XCL_BO_SYNC_BO_FROM_DEVICE)`
- [ ] Extract kernel invocation argument order
- [ ] Extract `run.wait()`
- [ ] Add structured output to ApplicationIR
- [ ] Test on `cases/light_ddr`

Expected structured result example:

```json
{
  "buffers": [
    {
      "name": "bo_in1",
      "size_expr": "n * sizeof(int)",
      "group_id": 0,
      "sync_direction": "host_to_device"
    }
  ],
  "kernel_invocations": [
    {
      "kernel": "vadd",
      "args": ["bo_in1", "bo_in2", "bo_out", "n"]
    }
  ]
}
```

### Phase 3 — ApplicationIR v1

Status: planned.

- [ ] Split ApplicationIR into `facts`, `llm_annotations`, and `unknowns`
- [ ] Keep scanner facts separate from LLM semantic hints
- [ ] Add schema validation
- [ ] Add unknown-field reporting
- [ ] Update L0 checker to reject unsafe generated facts
- [ ] Update CLI output

### Phase 4 — case.yaml and Case Registry

Status: planned.

- [ ] Add `cases/light_ddr/case.yaml`
- [ ] Add case metadata
- [ ] Add source runtime
- [ ] Add memory type
- [ ] Add validation targets
- [ ] Add golden/test command fields
- [ ] Update scanner to read case.yaml

### Phase 5 — Platform Pack v1

Status: planned.

Replace single JSON stub with versioned platform pack directory.

Target structure:

```text
platform_packs/v80_aved_2025_1_stub/
  platform.json
  capabilities.json
  memory_rules.json
  qdma_rules.json
  register_rules.json
  templates/
    hls/
    bd_tcl/
    qdma_host/
    build/
```

Checklist:

- [ ] Move platform stub into platform pack
- [ ] Add capabilities file
- [ ] Add memory rules
- [ ] Add QDMA rules
- [ ] Add register rules
- [ ] Add template metadata
- [ ] Update PlatformIR loader

### Phase 6 — MigrationContract v1

Status: planned.

- [ ] Add contract states: Proposed, StaticallyChecked, RuntimeValidated
- [ ] Add FunctionalContract
- [ ] Add InterfaceContract
- [ ] Add MemoryContract
- [ ] Add ControlContract
- [ ] Add BuildContract
- [ ] Add ValidationContract
- [ ] Keep ExecutionPolicy separate from MigrationContract
- [ ] Allow Generator to read only StaticallyChecked contracts

### Phase 7 — L0-pre and L0-post

Status: planned.

- [ ] Split current L0 checker into L0-pre and L0-post
- [ ] L0-pre checks source project, ApplicationIR, Platform Pack and MigrationContract
- [ ] L0-post checks generated project, forbidden APIs, register/address maps and templates
- [ ] Add JSON reports for both stages

### Phase 8 — Generator Stub

Status: planned.

- [ ] Add HLS IP generator stub
- [ ] Add register map generator stub
- [ ] Add address map generator stub
- [ ] Add QDMA host generator stub
- [ ] Add BD/Tcl generator stub
- [ ] Add build script generator stub
- [ ] Generate light_ddr target skeleton

### Phase 9 — Evidence System

Status: planned.

- [ ] Add Artifact Registry
- [ ] Add Patch Ledger
- [ ] Add Budget Ledger
- [ ] Add Replay command
- [ ] Record model calls, token usage, tool calls, patches, validation results and wall time

### Phase 10 — Knowledge Pack

Status: planned.

Start with local Markdown/JSON knowledge pack, not a large vector database.

- [ ] Add `xporthls/knowledge/rules/xrt_api_rules.json`
- [ ] Add `xporthls/knowledge/rules/qdma_rules.json`
- [ ] Add `xporthls/knowledge/rules/memory_rules.json`
- [ ] Add `xporthls/knowledge/rules/register_rules.json`
- [ ] Add `xporthls/knowledge/rules/failure_taxonomy.json`
- [ ] Add version metadata to each rule
- [ ] Add source URL and verification status
- [ ] Add simple keyword search before vector search

### Phase 11 — Agent Loop

Status: planned.

- [ ] Add ModelAdapter
- [ ] Add LogParser
- [ ] Add Diagnoser
- [ ] Add PatchPlanner
- [ ] Add PatchController
- [ ] Add rollback support
- [ ] Add validation-after-patch policy
- [ ] Add fixed Failure Taxonomy

### Phase 12 — Real Cases

Status: planned.

- [ ] Add HiSparse original XRT/U280 case
- [ ] Add HiSparse manually migrated V80/AVED case
- [ ] Extract diff and migration trajectory
- [ ] Add one public light DDR case
- [ ] Add one public medium HBM or multi-kernel case
- [ ] Add fault injection tasks

---

## 6. Current Immediate Next Step

The next implementation task is:

```text
XRT Semantic Extractor v1
```

This is the foundation for QDMA host generation, register mapping, memory contract generation and later Agent repair.

Do not start with a large vector database or LLM integration first.

Correct order:

```text
XRT semantics
  ↓
ApplicationIR v1
  ↓
case.yaml
  ↓
L0-pre
  ↓
Platform Pack v1
  ↓
Generator stub
  ↓
Evidence system
  ↓
Agent loop
```

---

## 7. GitHub Backup

Repository name:

```text
XPortHLS
```

Recommended branch:

```text
main
```

Do not commit:

- `.env`
- real API keys
- Vivado build directories
- generated `.pdi`, `.bit`, `.xclbin`, `.xo`
- huge logs
- AMD/Xilinx binary packages
- EULA-restricted files
