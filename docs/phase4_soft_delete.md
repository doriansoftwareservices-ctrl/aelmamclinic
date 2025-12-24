Phase 4 Soft Delete Alignment

Goal
- Align cloud schema with local soft-delete fields (isDeleted/deletedAt).
- Ensure SyncService can push deletions and realtime delete propagation works.

Change
- Added migration to append is_deleted/deleted_at to all sync tables.
- Added per-table index on is_deleted for query performance.

Migration
- nhost/migrations/default/20251224180000_add_soft_delete_columns/up.sql
- nhost/migrations/default/20251224180000_add_soft_delete_columns/down.sql

Notes
- This is schema-only; data remains untouched.
- Later phases will address request_uid_text safety and admin provisioning.
