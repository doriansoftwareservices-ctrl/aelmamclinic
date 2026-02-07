-- Fix: auth.users.locale is NOT NULL without a default, which breaks dashboard user creation
alter table auth.users
  alter column locale set default 'en';

update auth.users
  set locale='en'
where locale is null;
