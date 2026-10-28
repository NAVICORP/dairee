-- The pieces of a Supabase database that FarmiLife's migrations rely on,
-- written for a plain Postgres. Run once on an empty database, before the
-- migrations in supabase/migrations. Safe to run again.
--
-- Roles: PostgREST connects as `authenticator` and switches to `anon` or
-- `authenticated` from the token, exactly as on Supabase, so every grant and
-- row policy in the migrations keeps working unchanged. The API itself uses
-- `service_role` for work done on a user's behalf (sign up, files, Stripe).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
-- Supabase's defaults for the public schema: every new table, sequence and
-- function is open to the API roles, and row policies (plus the explicit
-- revokes in the migrations) decide what each person can actually do.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_trgm with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- auth: people, their sign-in methods and sessions
-- ---------------------------------------------------------------------------
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  aud                 text not null default 'authenticated',
  role                text not null default 'authenticated',
  email               text,
  encrypted_password  text,
  email_confirmed_at  timestamptz,
  phone               text,
  phone_confirmed_at  timestamptz,
  raw_app_meta_data   jsonb not null default '{}',
  raw_user_meta_data  jsonb not null default '{}',
  last_sign_in_at     timestamptz,
  banned_until        timestamptz,
  is_anonymous        boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz
);
create unique index if not exists users_email_key on auth.users (lower(email)) where email is not null;
create unique index if not exists users_phone_key on auth.users (phone) where phone is not null;

create table if not exists auth.identities (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users (id) on delete cascade,
  provider        text not null,
  provider_id     text not null,
  identity_data   jsonb not null default '{}',
  email           text,
  last_sign_in_at timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (provider, provider_id)
);
create index if not exists identities_user_idx on auth.identities (user_id);

create table if not exists auth.sessions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  user_agent  text,
  ip          text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists sessions_user_idx on auth.sessions (user_id);

-- Only a hash of each refresh token is kept: a stolen database copy cannot
-- be used to sign in as anyone.
create table if not exists auth.refresh_tokens (
  id          bigserial primary key,
  token_hash  text not null unique,
  session_id  uuid not null references auth.sessions (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  revoked     boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists refresh_tokens_session_idx on auth.refresh_tokens (session_id);

-- Links sent by email (confirm, magic link, recovery, email change). Hashed.
create table if not exists auth.one_time_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users (id) on delete cascade,
  token_type  text not null,
  token_hash  text not null unique,
  relates_to  text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists one_time_tokens_user_idx on auth.one_time_tokens (user_id, token_type);

-- PKCE: Google sign-in on the web, and confirm links opened in another tab.
create table if not exists auth.flow_state (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid references auth.users (id) on delete cascade,
  auth_code       text not null unique,
  code_challenge  text not null,
  code_challenge_method text not null default 's256',
  provider_type   text not null,
  redirect_to     text,
  created_at      timestamptz not null default now()
);

-- SkAuth's own sign-in at account.skifi.co: a browser that has signed in
-- there once is let straight through on the next app. Hashed cookie value.
create table if not exists auth.sso_sessions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token_hash    text not null unique,
  user_agent    text,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now()
);
create index if not exists sso_sessions_user_idx on auth.sso_sessions (user_id);

revoke all on all tables in schema auth from anon, authenticated;
grant all on all tables in schema auth to service_role;
grant all on all sequences in schema auth to service_role;
-- The migrations read names and emails from auth.users inside security
-- definer functions; those run as the owner, so no grant is needed here.

create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb;
$$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid;
$$;
create or replace function auth.role() returns text language sql stable as $$
  select coalesce(auth.jwt() ->> 'role', 'anon');
$$;
create or replace function auth.email() returns text language sql stable as $$
  select auth.jwt() ->> 'email';
$$;
grant execute on function auth.jwt(), auth.uid(), auth.role(), auth.email() to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- storage: which files exist and who may see them. The bytes live on disk;
-- the row decides access through the same policies as on Supabase.
-- ---------------------------------------------------------------------------
create schema if not exists storage;
grant usage on schema storage to anon, authenticated, service_role;

create table if not exists storage.buckets (
  id         text primary key,
  name       text not null unique,
  public     boolean not null default false,
  owner      uuid,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id         uuid primary key default gen_random_uuid(),
  bucket_id  text not null references storage.buckets (id),
  name       text not null,
  owner      uuid,
  owner_id   text,
  metadata   jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_accessed_at timestamptz not null default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;

grant select on storage.buckets to anon, authenticated;
grant select, insert, update, delete on storage.objects to authenticated;
grant all on all tables in schema storage to service_role;

create or replace function storage.foldername(name text) returns text[] language sql immutable as $$
  select (string_to_array(name, '/'))[1:array_length(string_to_array(name, '/'), 1) - 1];
$$;
create or replace function storage.filename(name text) returns text language sql immutable as $$
  select (string_to_array(name, '/'))[array_length(string_to_array(name, '/'), 1)];
$$;
grant execute on function storage.foldername(text), storage.filename(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Which files in supabase/migrations have been applied.
-- ---------------------------------------------------------------------------
create schema if not exists platform;
create table if not exists platform.migrations (
  name        text primary key,
  applied_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- An app's data brought over from elsewhere (Supabase) knows a person by the
-- old account id. When that person first signs in through SkAuth with the
-- same verified email, every reference to the old id is moved to the SkAuth
-- one: any uuid or uuid[] column in the app's own schemas, plus storage
-- owners. UUIDs are unique, so an equal value can only mean that person.
-- ---------------------------------------------------------------------------
create or replace function platform.remap_user(old_id uuid, new_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if old_id is null or new_id is null or old_id = new_id then return; end if;
  if exists (select 1 from auth.users where id = new_id) then
    -- The SkAuth account already has a mirror row: keep that one.
    delete from auth.identities where user_id = old_id;
  end if;
  set local session_replication_role = replica;
  for r in
    select c.table_schema, c.table_name, c.column_name, c.data_type
      from information_schema.columns c
      join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name and t.table_type = 'BASE TABLE'
     where c.table_schema not in ('pg_catalog', 'information_schema', 'platform', 'extensions')
       and (c.data_type = 'uuid' or (c.data_type = 'ARRAY' and c.udt_name = '_uuid'))
  loop
    if r.table_schema = 'auth' and r.table_name = 'users' and r.column_name = 'id' then continue; end if;
    if r.data_type = 'uuid' then
      execute format('update %I.%I set %I = $2 where %I = $1', r.table_schema, r.table_name, r.column_name, r.column_name) using old_id, new_id;
    else
      execute format('update %I.%I set %I = array_replace(%I, $1, $2) where $1 = any(%I)', r.table_schema, r.table_name, r.column_name, r.column_name, r.column_name) using old_id, new_id;
    end if;
  end loop;
  update storage.objects set owner_id = new_id::text where owner_id = old_id::text;
  if exists (select 1 from auth.users where id = new_id) then
    delete from auth.users where id = old_id;
  else
    update auth.users set id = new_id where id = old_id;
  end if;
end $$;
revoke all on function platform.remap_user(uuid, uuid) from public;
