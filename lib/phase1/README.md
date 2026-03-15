# Phase 1 Baseline and Governance

This folder contains the executable baseline for Phase 1.

## Scope

- Client: `lib`
- Backend functions: `functions`
- Backend metadata/migrations: `nhost`

## Goals

1. Establish a repeatable quality baseline command.
2. Create issue traceability from audit findings to files and test gates.
3. Freeze and track critical-path files to avoid conflicting edits.
4. Produce a machine-readable tracker for Phase 1 closure.

## Commands

From repository root:

```bash
bash lib/phase1/run_phase1_baseline.sh
```

Sub-checks:

```bash
bash lib/phase1/check_lib_baseline.sh
bash functions/phase1/check_functions_baseline.sh
bash nhost/phase1/check_nhost_baseline.sh
```

## Outputs

- `lib/phase1/issue_traceability.yaml`
- `lib/phase1/tracker.yaml`
- `lib/phase1/critical_path_files.txt`
- `lib/phase1/phase1_baseline_latest.txt`

## Gate policy

- Phase 2 (security hotfix) starts only after Phase 1 artifacts are complete.
- Any new change to critical-path files must reference an issue id from
  `issue_traceability.yaml`.
