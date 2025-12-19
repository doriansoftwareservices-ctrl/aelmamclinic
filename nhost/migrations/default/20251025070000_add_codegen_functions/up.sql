-- add codegen helper functions (fixed)
create or replace function public.get_enum_types()
returns table(name text, labels text[])
language sql stable as $$
  select t.typname::text as name,
         array_agg(e.enumlabel order by e.enumsortorder)::text[] as labels
  from pg_type t
  join pg_enum e on e.enumtypid = t.oid
  join pg_namespace n on n.oid = t.typnamespace
  where n.nspname in ('public')
  group by t.typname
  order by t.typname;
$$;
create or replace function public.get_schema_info()
returns jsonb
language sql stable as $$
with tbls as (
  select table_schema, table_name
  from information_schema.tables
  where table_schema in ('public') and table_type = 'BASE TABLE'
),
cols as (
  select table_schema, table_name, column_name, data_type, udt_name,
         is_nullable, is_generated, column_default, ordinal_position
  from information_schema.columns
  where table_schema in ('public')
),
pks as (
  select kcu.table_schema, kcu.table_name, kcu.column_name, kcu.ordinal_position
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on tc.constraint_name = kcu.constraint_name
   and tc.table_schema   = kcu.table_schema
  where tc.constraint_type = 'PRIMARY KEY'
    and tc.table_schema in ('public')
),
fks as (
  select tc.table_schema,
         tc.table_name,
         kcu.column_name,
         ccu.table_schema as foreign_table_schema,
         ccu.table_name   as foreign_table_name,
         ccu.column_name  as foreign_column_name
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on tc.constraint_name = kcu.constraint_name
   and tc.table_schema   = kcu.table_schema
  join information_schema.constraint_column_usage ccu
    on ccu.constraint_name = tc.constraint_name
   and ccu.table_schema   = tc.table_schema
  where tc.constraint_type = 'FOREIGN KEY'
    and tc.table_schema in ('public')
),
enums as (
  select name, labels from public.get_enum_types()
)
select jsonb_build_object(
  'tables', (
    select coalesce(
      jsonb_agg(jsonb_build_object('schema', s.table_schema, 'name', s.table_name)),
      '[]'::jsonb
    )
    from (
      select distinct t.table_schema, t.table_name
      from tbls t
      order by t.table_schema, t.table_name
    ) s
  ),
  'columns', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', c.table_schema,
      'table',  c.table_name,
      'name',   c.column_name,
      'data_type', c.data_type,
      'udt_name',  c.udt_name,
      'is_nullable', c.is_nullable = 'YES',
      'is_generated', c.is_generated,
      'default', c.column_default
    ) order by c.table_schema, c.table_name, c.ordinal_position), '[]'::jsonb)
    from cols c
  ),
  'primary_keys', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', p.table_schema, 'table', p.table_name, 'column', p.column_name
    ) order by p.table_schema, p.table_name, p.column_name), '[]'::jsonb)
    from pks p
  ),
  'foreign_keys', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'schema', f.table_schema, 'table', f.table_name, 'column', f.column_name,
      'foreign_schema', f.foreign_table_schema,
      'foreign_table',  f.foreign_table_name,
      'foreign_column', f.foreign_column_name
    ) order by f.table_schema, f.table_name, f.column_name), '[]'::jsonb)
    from fks f
  ),
  'enums', (
    select coalesce(jsonb_agg(jsonb_build_object(
      'name', e.name, 'labels', e.labels
    )), '[]'::jsonb)
    from enums e
  )
);
$$;
-- refresh PostgREST cache
notify pgrst, 'reload schema';
