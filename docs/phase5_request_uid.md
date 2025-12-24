Phase 5 request_uid Safety

Goal
- Avoid invalid UUID cast errors when request context is missing/invalid.
- Standardize usage: nullif(public.request_uid_text(), '')::uuid.

Change
- Rewrote all occurrences of public.request_uid_text()::uuid in migrations.
- Left existing nullif(...) usage unchanged.

Updated Files
- nhost/migrations/default/20250901090100_rpc_my_account_id_and_my_accounts/up.sql
- nhost/migrations/default/20250912235900_fn_is_super_admin_stub/up.sql
- nhost/migrations/default/20250913020000_restore_domain_policies/up.sql
- nhost/migrations/default/2025091402_chat_policies/up.sql
- nhost/migrations/default/2025091404_fn_sign_chat_attachment/up.sql
- nhost/migrations/default/2025091405_views_chat/up.sql
- nhost/migrations/default/2025091506_fix_chat_participants_policies/up.sql
- nhost/migrations/default/20250921000000_chat_reactions/up.sql
- nhost/migrations/default/2025092102_storage_chat_attachments/up.sql
- nhost/migrations/default/20250923000000_profiles_table/up.sql
- nhost/migrations/default/20250924000000_admin_attach_employee_redeploy/up.sql
- nhost/migrations/default/20251025080000_patch/up.sql
- nhost/migrations/default/20251105011000_chat_delivery_and_aliases/up.sql
- nhost/migrations/default/20251105012000_chat_group_invitations/up.sql
- nhost/migrations/default/20251106090000_phase1_backend_fixes/up.sql
- nhost/migrations/default/20251220124000_fn_is_super_admin_gql_returns_table/up.sql
- nhost/migrations/default/20251220130000_fix_jwt_claims_json_cast/up.sql
- nhost/migrations/default/20251221180000_rpc_return_tables_for_hasura/down.sql
- nhost/migrations/default/20251221180000_rpc_return_tables_for_hasura/up.sql
- nhost/migrations/default/20251221183000_rpc_return_views/up.sql
