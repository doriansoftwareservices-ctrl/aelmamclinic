Phase 3 Metadata and GraphQL Execution

Goal
- Track all core domain tables in Hasura metadata.
- Grant role permissions at the GraphQL layer while relying on database RLS.
- Ensure sync tables are accessible for queries/mutations used by the app.

Approach
- Added select/insert/update/delete permissions for roles: me, user, superadmin.
- Used columns: "*" with filter/check: {} to defer enforcement to RLS policies.
- Kept existing view/function permissions intact.

Updated File
- nhost/metadata/databases/default/tables/tables.yaml

Notes
- Duplicate audit_logs entry removed to avoid metadata conflicts.
- Chat tables were included to align with app usage and existing RLS policies.
