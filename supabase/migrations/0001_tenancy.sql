-- Dairee, stage 1: farms, the people who work on them, and what each may do.
--
-- One deployment serves many farms. Every farm's rows carry farm_id, and one
-- function, current_farm_id(), decides which farm the signed-in person is
-- working in. Every policy asks it; when tenancy changes shape, that one
-- definition changes, not two hundred policies.
--
-- Staff sign in through SkAuth (account.skifi.co): a WhatsApp code to their
-- number, an email code, Google, or an email and password the office made
-- for them. A staff row is linked to the sign-in the first time someone
-- signs in with the number or email on it (claim_staff, called by whoami).
--
-- Customers are not sign-ins at all: see 0005_portal.sql.

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------- small helpers

-- A number as people type it, as digits with the country code. Ten digits on
-- their own are taken as Indian.
create or replace function public.phone_digits(p text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^[0-9]{10}$' then '91' || d
    when d ~ '^00[0-9]+$' then substr(d, 3)
    when d ~ '^0[0-9]{10}$' then '91' || substr(d, 2)
    else nullif(d, '')
  end
  from (select regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g') as d) x;
$$;

create or replace function public.clean_email(e text) returns text
language sql immutable set search_path = '' as $$
  select nullif(lower(btrim(coalesce(e, ''))), '');
$$;

-- The signed-in person's verified number and email, from the sign-in token.
create or replace function public.my_phone() returns text
language sql stable set search_path = '' as $$
  select nullif(regexp_replace(coalesce(auth.jwt() ->> 'phone', ''), '[^0-9]', '', 'g'), '');
$$;

create or replace function public.my_email() returns text
language sql stable set search_path = '' as $$
  select public.clean_email(auth.email());
$$;

create or replace function public.new_token() returns text
language sql volatile set search_path = '' as $$
  select translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/=', '-_');
$$;

-- The farm the app asked for (the x-farm-id header), when it is a valid id.
create or replace function public.requested_farm() returns uuid
language plpgsql stable set search_path = '' as $$
declare v text := nullif(btrim(coalesce(current_setting('request.headers', true)::jsonb ->> 'x-farm-id', '')), '');
begin
  if v is null or v !~ '^[0-9a-fA-F-]{36}$' then return null; end if;
  return v::uuid;
exception when others then
  return null;
end $$;

-- True inside a security definer function or the server's own work, false for
-- a person writing through the API. Triggers use it to tell the two apart.
create or replace function public.trusted_writer() returns boolean
language sql stable set search_path = '' as $$
  select current_user not in ('anon', 'authenticated');
$$;

-- ---------------------------------------------------------------- farms

create table public.farms (
  id                       uuid primary key default gen_random_uuid(),
  name                     text not null check (char_length(btrim(name)) between 1 and 80),
  slug                     text not null unique check (slug ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$'),
  timezone                 text not null default 'Asia/Kolkata',
  currency                 text not null default 'INR' check (currency ~ '^[A-Z]{3}$'),
  phone                    text,
  address                  text check (char_length(address) <= 300),
  -- May customers pause their own milk and ask for changes from the portal?
  customer_pause           boolean not null default true,
  customer_requests        boolean not null default true,
  -- The packing windows: changes to a round close while it is being packed.
  morning_start            time not null default '06:00',
  morning_end              time not null default '09:00',
  evening_start            time not null default '16:00',
  evening_end              time not null default '19:00',
  bill_prefix              text not null default 'B' check (bill_prefix ~ '^[A-Z0-9-]{1,8}$'),
  created_by               uuid,
  created_at               timestamptz not null default now(),
  check (morning_start < morning_end and evening_start < evening_end)
);

-- The farm's clock. Never current_date: the server runs in UTC.
create or replace function public.farm_now(f uuid) returns timestamp
language sql stable set search_path = '' as $$
  select now() at time zone coalesce((select x.timezone from public.farms x where x.id = f), 'Asia/Kolkata');
$$;

create or replace function public.farm_today(f uuid) returns date
language sql stable set search_path = '' as $$
  select public.farm_now(f)::date;
$$;

create or replace function public.farms_check() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.name := btrim(new.name);
  new.slug := lower(btrim(new.slug));
  new.phone := public.phone_digits(new.phone);
  -- An unknown time zone fails here, with a plain message.
  begin
    perform now() at time zone new.timezone;
  exception when others then
    raise exception 'Unknown time zone %.', new.timezone using errcode = '22023';
  end;
  if tg_op = 'UPDATE' and not public.trusted_writer() then
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger farms_check before insert or update on public.farms
  for each row execute function public.farms_check();

-- ---------------------------------------------------------------- staff and pages

-- The pages a permission can name. A row per page, not an enum: adding one is
-- an insert. The key is the page's own routing key in the app.
create table public.staff_areas (
  key        text primary key check (key ~ '^[a-z_]+$'),
  label      text not null,
  sort_order int not null
);
insert into public.staff_areas (key, label, sort_order) values
  ('deliveries',  'Deliveries',   10),
  ('preparation', 'Preparation',  20),
  ('customers',   'Customers',    30),
  ('pauses',      'Pause / Stop', 40),
  ('payments',    'Payments',     50),
  ('reports',     'Reports',      60),
  ('cows',        'Cows',         70),
  ('staff',       'Staff',        80),
  ('settings',    'Settings',     90);

create table public.staff (
  id                   uuid primary key default gen_random_uuid(),
  farm_id              uuid not null references public.farms (id) on delete cascade,
  name                 text not null check (char_length(btrim(name)) between 1 and 80),
  phone                text check (phone ~ '^[0-9]{8,15}$'),
  email                text check (email = lower(btrim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  active               boolean not null default true,
  auth_user_id         uuid,                   -- the sign-in; null until they first sign in
  position             text check (char_length(position) <= 60),
  photo_path           text,
  qr_token             text not null default public.new_token(),
  can_deliver          boolean not null default false,
  can_care             boolean not null default false,
  is_admin             boolean not null default false,
  permissions          text[] not null default '{}',
  profile_editing      boolean not null default false,
  created_at           timestamptz not null default now(),
  check (coalesce(nullif(btrim(email), ''), nullif(btrim(phone), '')) is not null)
);
create unique index staff_farm_user on public.staff (farm_id, auth_user_id) where auth_user_id is not null;
create unique index staff_farm_phone on public.staff (farm_id, phone) where phone is not null;
create unique index staff_farm_email on public.staff (farm_id, email) where email is not null;
create index staff_by_user on public.staff (auth_user_id) where auth_user_id is not null;
create index staff_by_phone on public.staff (phone) where phone is not null;
create index staff_by_email on public.staff (email) where email is not null;
create index staff_farm on public.staff (farm_id);

-- ---------------------------------------------------------------- the boundary

-- The farm the signed-in person is working in. The app names it in the
-- x-farm-id header when someone works for more than one farm.
create or replace function public.current_farm_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.farm_id from public.staff s
  where s.auth_user_id = auth.uid() and s.active
  order by (s.farm_id = public.requested_farm()) desc nulls last, s.created_at
  limit 1;
$$;

alter table public.staff alter column farm_id set default public.current_farm_id();

-- The signed-in person's staff row in that farm.
create or replace function public.my_staff_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select s.id from public.staff s
  where s.auth_user_id = auth.uid() and s.active and s.farm_id = public.current_farm_id()
  limit 1;
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.staff s
    where s.auth_user_id = auth.uid() and s.active and s.is_admin
      and s.farm_id = public.current_farm_id()
  );
$$;

-- Admin is a separate fact, not a full list: an admin passes every check,
-- including for a page added next year.
create or replace function public.staff_can(p_area text) returns boolean
language sql stable security definer set search_path = '' as $$
  select public.is_admin() or exists (
    select 1 from public.staff s
    where s.auth_user_id = auth.uid() and s.active
      and s.farm_id = public.current_farm_id()
      and p_area = any (s.permissions)
  );
$$;

create or replace function public.can_deliver() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.staff_can('deliveries') or exists (
    select 1 from public.staff s
    where s.auth_user_id = auth.uid() and s.active and s.can_deliver
      and s.farm_id = public.current_farm_id()
  );
$$;

create or replace function public.can_care() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.staff_can('cows') or exists (
    select 1 from public.staff s
    where s.auth_user_id = auth.uid() and s.active and s.can_care
      and s.farm_id = public.current_farm_id()
  );
$$;

-- The name written next to anything the signed-in person does.
create or replace function public.my_name() returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select s.name from public.staff s where s.id = public.my_staff_id()),
    public.my_email(),
    case when public.my_phone() is not null then '+' || public.my_phone() end,
    'Someone'
  );
$$;

-- ---------------------------------------------------------------- staff rules

create or replace function public.staff_check() returns trigger
language plpgsql set search_path = '' as $$
declare bad text;
begin
  new.name := btrim(new.name);
  new.phone := public.phone_digits(new.phone);
  new.email := public.clean_email(new.email);
  new.position := nullif(btrim(coalesce(new.position, '')), '');
  if new.phone is not null and new.phone !~ '^[0-9]{8,15}$' then
    raise exception 'That number does not look right. Add the country code.' using errcode = '22023';
  end if;
  select string_agg(p, ', ') into bad from unnest(new.permissions) p
   where not exists (select 1 from public.staff_areas a where a.key = p);
  if bad is not null then
    raise exception 'Unknown page: %.', bad using errcode = '22023';
  end if;
  new.permissions := array(select distinct p from unnest(new.permissions) p order by p);

  if tg_op = 'UPDATE' then
    if new.farm_id is distinct from old.farm_id then
      raise exception 'Staff cannot move between farms.' using errcode = '42501';
    end if;
    -- A new number or email is a new person to sign in: the old sign-in lets go.
    if (new.phone is distinct from old.phone or new.email is distinct from old.email)
       and new.auth_user_id is not distinct from old.auth_user_id then
      new.auth_user_id := null;
    end if;
  end if;

  -- A sign-in links itself, when its owner signs in with the verified number
  -- or email (claim_staff). Nobody, not even an admin, points a row at
  -- somebody else's sign-in. Letting go of one is fine.
  if not public.trusted_writer() and new.auth_user_id is not null
     and (tg_op = 'INSERT' or new.auth_user_id is distinct from old.auth_user_id) then
    raise exception 'A person is linked when they first sign in.' using errcode = '42501';
  end if;

  if public.trusted_writer() or public.is_admin() then
    return new;
  end if;

  -- Row level security decides whether a row may be written, not which column
  -- changed. Without this, any staff login could make itself an admin.
  if tg_op = 'INSERT' then
    if new.is_admin or new.permissions <> '{}' or new.profile_editing then
      raise exception 'Only an admin can change what somebody may do.' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.is_admin        is distinct from old.is_admin
  or new.permissions     is distinct from old.permissions
  or new.profile_editing is distinct from old.profile_editing then
    raise exception 'Only an admin can change what somebody may do.' using errcode = '42501';
  end if;

  -- With the Staff page but not admin: the delivery and care team only. A new
  -- number or email on an office row would hand that row's pages to whoever
  -- owns the new number.
  if public.staff_can('staff') and (old.is_admin or old.permissions <> '{}')
     and (new.phone is distinct from old.phone or new.email is distinct from old.email
          or new.active is distinct from old.active) then
    raise exception 'Only an admin can change the number, email or access of office staff.' using errcode = '42501';
  end if;

  -- Someone editing their own profile (allowed by profile_editing) may change
  -- only their name, title and photo.
  if not public.staff_can('staff') then
    if old.auth_user_id is distinct from auth.uid() or not old.profile_editing then
      raise exception 'You can only change your own profile.' using errcode = '42501';
    end if;
    if new.phone is distinct from old.phone or new.email is distinct from old.email
       or new.active is distinct from old.active or new.can_deliver is distinct from old.can_deliver
       or new.can_care is distinct from old.can_care or new.qr_token is distinct from old.qr_token then
      raise exception 'Ask the office to change that.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger staff_check before insert or update on public.staff
  for each row execute function public.staff_check();

-- Removing office staff or admins is for admins.
create or replace function public.staff_delete_check() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not public.trusted_writer() and not public.is_admin() and (old.is_admin or old.permissions <> '{}') then
    raise exception 'Only an admin can remove office staff.' using errcode = '42501';
  end if;
  return old;
end $$;
create trigger staff_delete_check before delete on public.staff
  for each row execute function public.staff_delete_check();

-- A farm always keeps at least one active admin.
create or replace function public.staff_keep_admin() returns trigger
language plpgsql set search_path = '' as $$
declare f uuid := coalesce(old.farm_id, new.farm_id);
begin
  if not exists (select 1 from public.farms x where x.id = f) then return null; end if;  -- the farm itself is going
  if not exists (select 1 from public.staff s where s.farm_id = f and s.is_admin and s.active) then
    raise exception 'A farm needs at least one admin. Make someone else an admin first.' using errcode = '22023';
  end if;
  return null;
end $$;
create constraint trigger staff_keep_admin after update or delete on public.staff
  deferrable initially deferred
  for each row execute function public.staff_keep_admin();

-- ---------------------------------------------------------------- the audit log

create table public.audit_logs (
  id              uuid primary key default gen_random_uuid(),
  farm_id         uuid not null references public.farms (id) on delete cascade,
  action_type     text not null,
  entity_type     text not null,
  entity_id       text,
  old_values      jsonb,
  new_values      jsonb,
  performed_by    text not null,
  performed_by_id uuid,
  -- A sentence a person can read: "Textiles shop marked delivered for
  -- 2026-09-28, morning round", never just "mark_delivered".
  notes           text,
  created_at      timestamptz not null default now()
);
create index audit_logs_farm on public.audit_logs (farm_id, created_at desc);

create or replace function public.audit(p_farm uuid, p_action text, p_entity text, p_id text, p_notes text,
  p_old jsonb default null, p_new jsonb default null) returns void
language sql security definer set search_path = '' as $$
  insert into public.audit_logs (farm_id, action_type, entity_type, entity_id, old_values, new_values,
                                 performed_by, performed_by_id, notes)
  values (p_farm, p_action, p_entity, p_id, p_old, p_new, public.my_name(), auth.uid(), p_notes);
$$;

-- ---------------------------------------------------------------- row level security

alter table public.farms enable row level security;
alter table public.staff enable row level security;
alter table public.staff_areas enable row level security;
alter table public.audit_logs enable row level security;

-- A person sees the farms they work for.
create policy farms_read on public.farms for select to authenticated
  using (id in (select s.farm_id from public.staff s where s.auth_user_id = auth.uid() and s.active));
create policy farms_write on public.farms for update to authenticated
  using (id = (select public.current_farm_id()) and (select public.staff_can('settings')))
  with check (id = (select public.current_farm_id()));
-- Farms are created and deleted only through create_farm and delete_farm.
revoke insert, delete on public.farms from anon, authenticated;
revoke all on public.farms from anon;

create policy staff_areas_read on public.staff_areas for select to authenticated using (true);
revoke insert, update, delete on public.staff_areas from anon, authenticated;
revoke all on public.staff_areas from anon;

create policy staff_read on public.staff for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy staff_insert on public.staff for insert to authenticated
  with check (farm_id = (select public.current_farm_id()) and (select public.staff_can('staff')));
create policy staff_update on public.staff for update to authenticated
  using (farm_id = (select public.current_farm_id())
         and ((select public.staff_can('staff')) or auth_user_id = auth.uid()))
  with check (farm_id = (select public.current_farm_id()));
create policy staff_delete on public.staff for delete to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('staff')));
revoke all on public.staff from anon;

-- The log names prices and bill totals, so it needs the Payments page too.
create policy audit_read on public.audit_logs for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('settings'))
         and (select public.staff_can('payments')));
revoke insert, update, delete on public.audit_logs from anon, authenticated;
revoke all on public.audit_logs from anon;

-- ---------------------------------------------------------------- signing in

-- Links staff rows waiting for this person (by verified number or email) to
-- their sign-in. Rows already linked to someone else are left alone.
create or replace function public.claim_staff() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if auth.uid() is null then return 0; end if;
  update public.staff s set auth_user_id = auth.uid()
   where s.auth_user_id is null and s.active
     and ((public.my_phone() is not null and s.phone = public.my_phone())
       or (public.my_email() is not null and s.email = public.my_email()))
     and not exists (select 1 from public.staff o where o.farm_id = s.farm_id and o.auth_user_id = auth.uid());
  get diagnostics n = row_count;
  return n;
end $$;

-- Who is signed in, and every farm they work for with what they may do there.
create or replace function public.whoami() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare farms jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('id', null, 'farms', '[]'::jsonb);
  end if;
  perform public.claim_staff();
  select coalesce(jsonb_agg(jsonb_build_object(
      'farm_id', f.id, 'name', f.name, 'slug', f.slug, 'timezone', f.timezone, 'currency', f.currency,
      'staff_id', s.id, 'staff_name', s.name, 'position', s.position,
      'is_admin', s.is_admin, 'permissions', to_jsonb(s.permissions),
      'can_deliver', s.can_deliver, 'can_care', s.can_care,
      'profile_editing', s.profile_editing,
      'today', public.farm_today(f.id))
      order by s.created_at), '[]'::jsonb)
    into farms
    from public.staff s join public.farms f on f.id = s.farm_id
   where s.auth_user_id = auth.uid() and s.active;
  return jsonb_build_object(
    'id', auth.uid(), 'email', public.my_email(), 'phone', public.my_phone(),
    'farms', farms,
    'areas', (select jsonb_agg(jsonb_build_object('key', a.key, 'label', a.label) order by a.sort_order)
                from public.staff_areas a));
end $$;

-- A slug for a new farm: its name in lower case, made unique.
create or replace function public.farm_slug(p_name text) returns text
language plpgsql volatile set search_path = '' as $$
declare base text; s text; i int := 1;
begin
  base := trim(both '-' from regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'));
  base := left(trim(both '-' from base), 30);
  if base = '' or base is null then base := 'farm'; end if;
  s := base;
  while exists (select 1 from public.farms f where f.slug = s) loop
    i := i + 1;
    s := base || '-' || i;
  end loop;
  return s;
end $$;

-- Anyone signed in can start a farm, and becomes its first admin.
create or replace function public.create_farm(name text, timezone text default 'Asia/Kolkata', currency text default 'INR',
  my_name text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f public.farms%rowtype; n text := btrim(coalesce(create_farm.name, ''));
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  if n = '' then raise exception 'Give the farm a name.' using errcode = '22023'; end if;
  if (select count(*) from public.farms x where x.created_by = auth.uid()) >= 5 then
    raise exception 'You have already started 5 farms.' using errcode = '22023';
  end if;
  insert into public.farms (name, slug, timezone, currency, created_by)
  values (n, public.farm_slug(n), coalesce(nullif(create_farm.timezone, ''), 'Asia/Kolkata'),
          upper(coalesce(nullif(create_farm.currency, ''), 'INR')), auth.uid())
  returning * into f;
  insert into public.staff (farm_id, name, phone, email, auth_user_id, is_admin, position)
  values (f.id, coalesce(nullif(btrim(create_farm.my_name), ''), public.my_email(),
                         '+' || public.my_phone(), 'Owner'),
          public.my_phone(), public.my_email(), auth.uid(), true, 'Owner');
  perform public.seed_farm(f.id);
  perform public.audit(f.id, 'create_farm', 'farm', f.id::text, format('%s started the farm %s', public.my_name(), f.name));
  return jsonb_build_object('farm_id', f.id, 'slug', f.slug, 'name', f.name);
end $$;

-- Filled in by later migrations (vessels, the first price).
create or replace function public.seed_farm(f uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  null;
end $$;

-- An admin deletes the whole farm, typing its name to confirm.
create or replace function public.delete_farm(confirm_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare f public.farms%rowtype;
begin
  if not public.is_admin() then raise exception 'Only an admin can delete the farm.' using errcode = '42501'; end if;
  select * into f from public.farms x where x.id = public.current_farm_id();
  if lower(btrim(coalesce(confirm_name, ''))) <> lower(f.name) then
    raise exception 'Type the farm''s name exactly to delete it.' using errcode = '22023';
  end if;
  delete from public.farms x where x.id = f.id;
end $$;

-- Before an account is deleted (a store requirement): the person leaves every
-- farm. A farm where they are the only admin and nobody else works is deleted;
-- one where others work needs another admin first.
create or replace function public.delete_my_data() returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Sign in first.' using errcode = '42501'; end if;
  for r in select s.farm_id, f.name from public.staff s join public.farms f on f.id = s.farm_id
            where s.auth_user_id = auth.uid() and s.is_admin and s.active loop
    if not exists (select 1 from public.staff o where o.farm_id = r.farm_id and o.is_admin and o.active
                     and o.auth_user_id is distinct from auth.uid()) then
      if exists (select 1 from public.staff o where o.farm_id = r.farm_id and o.active
                   and o.auth_user_id is distinct from auth.uid()) then
        raise exception 'You are the only admin of %. Make someone else an admin first.', r.name using errcode = '22023';
      end if;
      delete from public.farms x where x.id = r.farm_id;
    end if;
  end loop;
  delete from public.staff s where s.auth_user_id = auth.uid();
  delete from auth.users u where u.id = auth.uid();
end $$;
