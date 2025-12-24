-- Remove hard-coded super admin seed to keep the source of truth in the server.

DELETE FROM public.super_admins
WHERE email = 'admin@elmam.com';
