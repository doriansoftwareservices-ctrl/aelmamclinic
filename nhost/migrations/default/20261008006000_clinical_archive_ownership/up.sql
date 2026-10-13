BEGIN;
-- Keep legacy clinical PHI inaccessible even when the API connector inherits
-- the original migration owner's privileges. No login or membership is granted.
DO $role$
DECLARE r record;
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='clinical_integrity_archivist') THEN
  CREATE ROLE clinical_integrity_archivist NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
 END IF;
 SELECT * INTO r FROM pg_roles WHERE rolname='clinical_integrity_archivist';
 IF r.rolcanlogin OR r.rolsuper OR r.rolcreatedb OR r.rolcreaterole OR r.rolbypassrls THEN
  RAISE EXCEPTION 'clinical_archive_owner_role_is_not_restricted';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_auth_members WHERE roleid=r.oid) THEN
  RAISE EXCEPTION 'clinical_archive_owner_has_unexpected_memberships';
 END IF;
END $role$;
ALTER SCHEMA clinical_integrity_private OWNER TO clinical_integrity_archivist;
ALTER TABLE clinical_integrity_private.legacy_link_preimages OWNER TO clinical_integrity_archivist;
REVOKE ALL ON SCHEMA clinical_integrity_private FROM PUBLIC;
REVOKE ALL ON TABLE clinical_integrity_private.legacy_link_preimages FROM PUBLIC;
COMMIT;
