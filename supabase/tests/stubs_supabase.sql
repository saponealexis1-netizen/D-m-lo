-- Simule ce que Supabase fournit, pour tester la migration dans un Postgres nu :
-- rôles, schéma auth, Vault, pg_net, pg_cron et le type vector (sans pgvector).
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
grant anon, authenticated, service_role to current_user;

create schema auth;
create table auth.users (
  id              uuid primary key,
  email           text,
  is_anonymous    boolean not null default false,
  last_sign_in_at timestamptz,
  created_at      timestamptz not null default now()
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
  select 1 - sum(x * y) / (sqrt(sum(x * x)) * sqrt(sum(y * y)))
    from unnest(a, b) as t(x, y)
$$;
create operator extensions.<=> (leftarg = float8[], rightarg = float8[], function = extensions.distance_cosinus);
grant usage on schema extensions to anon, authenticated, service_role;

create schema vault;
create table vault.decrypted_secrets (name text primary key, decrypted_secret text);

create schema net;
create table net.appels (id bigserial primary key, url text, body jsonb, headers jsonb);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
                              headers jsonb default '{}', timeout_milliseconds integer default 5000)
returns bigint language sql as $$
  insert into net.appels (url, body, headers) values (url, body, headers) returning id
$$;

create schema cron;
create table cron.jobs (nom text primary key, planning text, commande text);
create function cron.schedule(nom text, planning text, commande text) returns bigint
language sql as $$
  insert into cron.jobs values (nom, planning, commande) returning 1::bigint
$$;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
