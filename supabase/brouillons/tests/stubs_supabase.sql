-- Simule ce que Supabase fournit, pour tester dans un Postgres nu :
-- rôles, schéma auth, Vault, pg_cron, type vector (sans pgvector) et
-- l'event trigger ensure_rls / rls_auto_enable() créé par Supabase.
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
grant anon, authenticated, service_role to current_user;

create schema auth;
create table auth.users (
  id                uuid primary key,
  email             text,
  is_anonymous      boolean not null default false,
  raw_app_meta_data jsonb not null default '{}',
  last_sign_in_at   timestamptz,
  created_at        timestamptz not null default now()
);
create function auth.jwt() returns jsonb language sql stable as
  $$ select nullif(current_setting('request.jwt.claims', true), '')::jsonb $$;
create function auth.uid() returns uuid language sql stable as
  $$ select (auth.jwt() ->> 'sub')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;

create schema extensions;
create domain extensions.vector as float8[];
create function extensions.distance_cosinus(a float8[], b float8[]) returns float8
language sql immutable as $$
  select 1 - sum(x * y) / (sqrt(sum(x * x)) * sqrt(sum(y * y))) from unnest(a, b) as t(x, y)
$$;
create operator extensions.<=> (leftarg = float8[], rightarg = float8[], function = extensions.distance_cosinus);
grant usage on schema extensions to anon, authenticated, service_role;

create schema cron;
create table cron.job (jobid serial primary key, jobname text unique, schedule text, command text);
create function cron.schedule(nom text, planning text, commande text) returns bigint
language sql as $$ insert into cron.job (jobname, schedule, command) values (nom, planning, commande) returning jobid::bigint $$;
create function cron.unschedule(nom text) returns boolean
language sql as $$ with d as (delete from cron.job where jobname = nom returning 1) select exists (select 1 from d) $$;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;

-- Copie de la fonction Supabase relevée sur le projet (event trigger ensure_rls).
CREATE OR REPLACE FUNCTION public.rls_auto_enable()
 RETURNS event_trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  cmd record;
  tbl name;
BEGIN
  FOR cmd IN
    SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') THEN
      BEGIN
        SELECT c.relname INTO tbl FROM pg_catalog.pg_class c WHERE c.oid = cmd.objid;
        EXECUTE format('alter table if exists %I.%I enable row level security', cmd.schema_name, tbl);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
     END IF;
  END LOOP;
END;
$function$;
create event trigger ensure_rls on ddl_command_end
  when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  execute function public.rls_auto_enable();
