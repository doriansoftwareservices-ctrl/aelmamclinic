# Phase 2 Observability Foundation

This folder contains the executable baseline for Phase 2.

## Scope

- Establish a shared observability runtime with stable codes and flow IDs.
- Instrument critical runtime entry points in `main`, `Auth`, `Push`, `Chat`,
  `Sync`, and `DB`.
- Inventory remaining silent catches in critical files for later epics.
- Provide a local runtime-event summary command for top failure classes.

## Commands

From repository root:

```bash
bash lib/phase2/check_observability_baseline.sh
bash lib/phase2/summarize_runtime_events.sh
bash scripts/phase2_verify.sh
```

## Outputs

- `docs/phase2/reports/<timestamp>/`
- `app_runtime_events.jsonl` in the app logs directory at runtime

## Gate Policy

- Critical-path observability must exist before Auth/Account/Sync refactors.
- Remaining silent catches in deep chat/sync domain logic must be inventoried
  explicitly if they are deferred to later phases.
