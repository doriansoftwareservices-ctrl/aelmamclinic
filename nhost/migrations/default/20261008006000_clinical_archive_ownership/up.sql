BEGIN;

-- Nhost managed PostgreSQL executes Hasura migrations without CREATEROLE.
-- The original version tried to CREATE ROLE clinical_integrity_archivist and
-- transfer ownership; Nhost rejected that operation with SQLSTATE 42501.
--
-- Keep the previously archived clinical preimages in their existing private
-- schema with an owner-only ACL. Nothing is deleted, moved, or disclosed.
-- This blocks ordinary database roles and does not expose this schema through
-- GraphQL metadata. Hasura / database administrators who own the objects
-- remain trusted and are NOT isolated from the archive by this fallback.
-- Dedicated owner-role isolation would require privileged Nhost provisioning.
--
-- Avoid FORCE ROW LEVEL SECURITY without an approved database backup policy:
-- default-deny RLS can block data export by ordinary pg_dump identities.

DO $preflight$
BEGIN
  IF to_regnamespace('clinical_integrity_private') IS NULL
     OR to_regclass('clinical_integrity_private.legacy_link_preimages') IS NULL THEN
    RAISE EXCEPTION 'clinical_archive_missing: expected migration 20261008005000'
      USING ERRCODE = '42P01';
  END IF;
END $preflight$;

REVOKE ALL ON SCHEMA clinical_integrity_private FROM PUBLIC;
REVOKE ALL ON TABLE clinical_integrity_private.legacy_link_preimages FROM PUBLIC;

-- Fail closed if ANY non-owner role has been granted privileges on the private
-- archive. PostgreSQL superusers and membership in the owner role remain
-- outside ACL-based isolation and must be managed by infrastructure policy.
DO $acl_guard$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_namespace AS n,
         LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) AS a
    WHERE n.nspname = 'clinical_integrity_private'
      AND a.grantee <> n.nspowner
  ) THEN
    RAISE EXCEPTION 'clinical_archive_schema_grants_not_owner_only'
      USING ERRCODE = '42501';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace,
         LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) AS a
    WHERE n.nspname = 'clinical_integrity_private'
      AND c.relname = 'legacy_link_preimages'
      AND a.grantee <> c.relowner
  ) THEN
    RAISE EXCEPTION 'clinical_archive_table_grants_not_owner_only'
      USING ERRCODE = '42501';
  END IF;

  RAISE NOTICE 'clinical archive secured with owner-only ACL (managed Nhost role model)';
END $acl_guard$;

COMMIT;
