-- Fresh private cluster only. Supporting plan/claims helpers are synthetic;
-- the identity helper and both owner function definitions are production SQL.
CREATE SCHEMA auth;
CREATE TABLE public.elmam_owner_fixture_marker(value text PRIMARY KEY);
INSERT INTO public.elmam_owner_fixture_marker VALUES ('local_owner_onboarding_20261020');
CREATE TABLE auth.users (
  id uuid PRIMARY KEY, email text, disabled boolean DEFAULT false,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE public.accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text, clinic_name_en text,
  city_ar text, street_ar text, near_ar text, city_en text, street_en text,
  near_en text, phone text, phone2 text, frozen boolean DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.account_users (
  user_uid uuid REFERENCES auth.users, account_id uuid REFERENCES public.accounts,
  role text, disabled boolean DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_uid,account_id)
);
CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users, email text, role text,
  account_id uuid REFERENCES public.accounts
);
CREATE TABLE public.account_subscriptions (
  account_id uuid REFERENCES public.accounts, plan_code text, status text,
  start_at timestamptz, end_at timestamptz, approved_at timestamptz
);
CREATE TABLE public.account_feature_permissions (
  account_id uuid PRIMARY KEY REFERENCES public.accounts, plan_code text
);
CREATE VIEW public.v_uuid_result AS SELECT NULL::uuid AS id WHERE false;
CREATE FUNCTION public.apply_plan_permissions(a uuid, p text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
  IF current_setting('fixture.fail_plan',true)='true' THEN
    RAISE EXCEPTION 'fixture_plan_failure';
  END IF;
  INSERT INTO public.account_feature_permissions VALUES(a,p)
  ON CONFLICT(account_id) DO UPDATE SET plan_code=excluded.plan_code;
END $$;
CREATE FUNCTION public.auth_set_user_claims(u uuid, r text, a uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$ BEGIN
  UPDATE auth.users SET metadata=jsonb_build_object('role',r,'account_id',a) WHERE id=u;
END $$;
CREATE FUNCTION public.fixture_owner_insert_barrier() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
  IF current_setting('fixture.owner_barrier',true)='true' THEN
    PERFORM pg_advisory_xact_lock(202610200010);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER fixture_owner_insert_barrier BEFORE INSERT ON public.accounts
FOR EACH ROW EXECUTE FUNCTION public.fixture_owner_insert_barrier();
