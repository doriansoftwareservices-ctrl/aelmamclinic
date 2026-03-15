## Nhost Authority

- `nhost/metadata/` is the single authoritative metadata source used for deploy/apply.
- `nhost/metadata_snapshots/` stores exported snapshots for audit/reference only.
- `nhost/migrations/` remains the authoritative migrations source.
- Root-level `metadata.json` must not be recreated in `nhost/`; snapshots belong under `nhost/metadata_snapshots/`.
