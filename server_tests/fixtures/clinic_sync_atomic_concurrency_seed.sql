\set ON_ERROR_STOP on
BEGIN;
INSERT INTO auth.users(id,disabled) VALUES('20000000-0000-4000-8000-000000000020',false);
INSERT INTO public.accounts(id,frozen) VALUES('10000000-0000-4000-8000-000000000020',false);
INSERT INTO public.account_users(account_id,user_uid,disabled,role) VALUES('10000000-0000-4000-8000-000000000020','20000000-0000-4000-8000-000000000020',false,'owner');
INSERT INTO public.account_feature_permissions(account_id,user_uid,allow_all,can_create,can_update,can_delete) VALUES('10000000-0000-4000-8000-000000000020','20000000-0000-4000-8000-000000000020',true,true,true,true);
INSERT INTO public.item_types(id,account_id,device_id,local_id,name) VALUES('30000000-0000-4000-8000-000000000020','10000000-0000-4000-8000-000000000020','race-origin',20,'base');
COMMIT;
