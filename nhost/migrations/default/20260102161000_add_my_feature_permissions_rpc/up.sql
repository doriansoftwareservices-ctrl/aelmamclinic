BEGIN;

CREATE OR REPLACE FUNCTION public.my_feature_permissions_rpc(hasura_session json, p_account uuid)
RETURNS SETOF public.v_my_feature_permissions
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
declare
  v_uid uuid := nullif(
    coalesce(hasura_session->>'x-hasura-user-id', public.request_uid_text(), ''),
    ''
  )::uuid;
  v_is_super boolean := coalesce(fn_is_super_admin(), false);
  v_allow_all boolean;
  v_allowed text[];
  v_can_create boolean;
  v_can_update boolean;
  v_can_delete boolean;
begin
  if v_uid is null then
    return;
  end if;

  if p_account is null then
    return query select null::uuid, false, array[]::text[], false, false, false;
  end if;

  if not v_is_super then
    if not exists (
      select 1
      from public.account_users au
      where au.account_id = p_account
        and au.user_uid = v_uid
        and coalesce(au.disabled, false) = false
    ) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  select
    coalesce(bool_or(coalesce(fp.allow_all, false)), false),
    coalesce(array_agg(distinct feat), array[]::text[]),
    coalesce(bool_or(coalesce(fp.can_create, false)), false),
    coalesce(bool_or(coalesce(fp.can_update, false)), false),
    coalesce(bool_or(coalesce(fp.can_delete, false)), false)
  into v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete
  from public.account_feature_permissions fp
  left join lateral unnest(fp.allowed_features) as feat on true
  where fp.account_id = p_account
    and fp.user_uid = v_uid;

  return query select p_account, v_allow_all, v_allowed, v_can_create, v_can_update, v_can_delete;
end;
$$;

REVOKE ALL ON FUNCTION public.my_feature_permissions_rpc(json, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.my_feature_permissions_rpc(json, uuid) TO PUBLIC;

COMMIT;
