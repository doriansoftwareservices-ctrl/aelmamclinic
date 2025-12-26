         create or replace function public.admin_bootstrap_clinic(
           clinic_name text,
           owner_email text,
           owner_role text default 'owner'
         )
         returns uuid
         language plpgsql
         security definer
         set search_path = public, auth
         as $$
         begin
           return public.admin_bootstrap_clinic_for_email(clinic_name, owner_email, owner_role);
         end;
         $$;

         revoke all on function public.admin_bootstrap_clinic(text, text, text) from public;
         grant execute on function public.admin_bootstrap_clinic(text, text, text) TO public;
         grant execute on function public.admin_bootstrap_clinic(text, text, text) TO public;
