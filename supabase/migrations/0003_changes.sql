-- Dairee, stage 3: pauses, temporary deliveries, and when a round can still change.
--
-- A pause is never a deletion: the standing order is untouched, and the pause
-- is read on the day. A temporary delivery is the opposite ("5 litres on
-- Saturday, we have guests"): it changes nothing permanent either. Both are
-- read by expected_rounds(), the one place that decides what a round holds.

create table public.customer_pauses (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  pause_type  text not null check (pause_type in ('today_only', 'tomorrow_only', 'custom_range', 'until_resumed')),
  from_date   date not null,
  to_date     date,                                -- null: until resumed
  slot        text not null default 'both' check (slot in ('morning', 'evening', 'both')),
  reason      text check (char_length(reason) <= 200),
  is_active   boolean not null default true,
  set_by      text not null default 'office' check (set_by in ('office', 'customer')),
  set_by_name text,
  created_at  timestamptz not null default now(),
  check (to_date is null or to_date >= from_date),
  check ((pause_type = 'until_resumed') = (to_date is null))
);
create index customer_pauses_customer on public.customer_pauses (customer_id, from_date);
create index customer_pauses_farm on public.customer_pauses (farm_id) where is_active;

create table public.customer_pause_dates (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete cascade,
  pause_date  date not null,
  slot        text not null default 'both' check (slot in ('morning', 'evening', 'both')),
  reason      text check (char_length(reason) <= 200),
  set_by      text not null default 'office' check (set_by in ('office', 'customer')),
  set_by_name text,
  created_at  timestamptz not null default now(),
  unique (customer_id, pause_date, slot)
);
create index customer_pause_dates_farm on public.customer_pause_dates (farm_id, pause_date);

create table public.temporary_deliveries (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  customer_id   uuid not null references public.customers (id) on delete cascade,
  delivery_date date not null,
  slot          text not null check (slot in ('morning', 'evening')),
  quantity      numeric(8,3) not null check (quantity >= 0),
  -- The vessels, copied in, not referenced: renaming or retiring a vessel in
  -- settings must not change what this says was packed.
  containers    jsonb not null default '[]',
  note          text check (char_length(note) <= 200),
  created_by    text,
  request_id    uuid,
  created_at    timestamptz not null default now(),
  unique (customer_id, delivery_date, slot)
);
create index temporary_deliveries_farm on public.temporary_deliveries (farm_id, delivery_date);

-- A customer's request is a conversation; the temporary delivery is the fact.
create table public.temporary_requests (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null references public.farms (id) on delete cascade,
  customer_id   uuid not null references public.customers (id) on delete cascade,
  delivery_date date not null,
  slot          text not null check (slot in ('morning', 'evening')),
  quantity      numeric(8,3) not null check (quantity >= 0),
  containers    jsonb not null default '[]',
  note          text check (char_length(note) <= 200),
  status        text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'withdrawn')),
  requested_at  timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    text,
  decided_note  text check (char_length(decided_note) <= 200)
);
create index temporary_requests_farm on public.temporary_requests (farm_id, status, delivery_date);

alter table public.customer_pauses enable row level security;
alter table public.customer_pause_dates enable row level security;
alter table public.temporary_deliveries enable row level security;
alter table public.temporary_requests enable row level security;

create policy pauses_read on public.customer_pauses for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy pause_dates_read on public.customer_pause_dates for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy temporary_read on public.temporary_deliveries for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy requests_read on public.temporary_requests for select to authenticated
  using (farm_id = (select public.current_farm_id()));
-- All four are written through the functions below, which check the page,
-- the packing windows and closed days.
revoke insert, update, delete on public.customer_pauses, public.customer_pause_dates,
  public.temporary_deliveries, public.temporary_requests from authenticated;
revoke all on public.customer_pauses, public.customer_pause_dates,
  public.temporary_deliveries, public.temporary_requests from anon;

-- ---------------------------------------------------------------- what a round holds

-- One row per customer, date and round, for every customer the round would
-- reach: their standing quantity and vessels, overridden by a pause (nothing
-- goes) and by a temporary delivery (which wins over a pause, being the later
-- and more specific wish). Every screen, the packing list and the bills read
-- this one function, so they can never disagree about what was due.
create or replace function public.expected_rounds(p_farm uuid, p_from date, p_to date, p_customer uuid default null)
returns table (customer_id uuid, day date, slot text, standing_qty numeric, qty numeric, containers jsonb,
               paused boolean, paused_by text, temporary boolean)
language sql stable set search_path = '' as $$
  with days as (
    select d::date as day from generate_series(p_from, p_to, interval '1 day') d
  ), slots as (
    select unnest(array['morning', 'evening']) as slot
  ), standing as (
    select c.id as customer_id, d.day, s.slot, public.standing_qty(c, s.slot) as qty
    from public.customers c cross join days d cross join slots s
    where c.farm_id = p_farm and c.status = 'active' and c.start_date <= d.day
      and (p_customer is null or c.id = p_customer)
      and public.standing_qty(c, s.slot) > 0
  ), temp as (
    select t.customer_id, t.delivery_date as day, t.slot, t.quantity, t.containers
    from public.temporary_deliveries t join public.customers c on c.id = t.customer_id
    where t.farm_id = p_farm and t.delivery_date between p_from and p_to
      and c.status = 'active'
      and (p_customer is null or t.customer_id = p_customer)
  ), keys as (
    select customer_id, day, slot from standing
    union
    select customer_id, day, slot from temp
  )
  select k.customer_id, k.day, k.slot,
         coalesce(st.qty, 0) as standing_qty,
         case when t.customer_id is not null then t.quantity
              when p.paused_by is not null then 0
              else coalesce(st.qty, 0) end as qty,
         case when t.customer_id is not null then t.containers
              when p.paused_by is not null then '[]'::jsonb
              else public.vessels_json(k.customer_id, k.slot) end as containers,
         (t.customer_id is null and p.paused_by is not null) as paused,
         case when t.customer_id is null then p.paused_by end as paused_by,
         (t.customer_id is not null) as temporary
  from keys k
  left join standing st on st.customer_id = k.customer_id and st.day = k.day and st.slot = k.slot
  left join temp t on t.customer_id = k.customer_id and t.day = k.day and t.slot = k.slot
  left join lateral (
    select coalesce(
      (select pd.set_by from public.customer_pause_dates pd
        where pd.customer_id = k.customer_id and pd.pause_date = k.day and pd.slot in (k.slot, 'both') limit 1),
      (select cp.set_by from public.customer_pauses cp
        where cp.customer_id = k.customer_id and cp.is_active and cp.from_date <= k.day
          and (cp.to_date is null or cp.to_date >= k.day) and cp.slot in (k.slot, 'both') limit 1)
    ) as paused_by
  ) p on true;
$$;

-- ---------------------------------------------------------------- when a round can still change
--
-- Two questions, not one. They look alike, and reusing the first for today
-- would reopen the morning round at nine o'clock, after the milk has gone.

create or replace function public.round_window(f uuid, p_slot text, out starts time, out ends time)
language sql stable set search_path = '' as $$
  select case p_slot when 'morning' then x.morning_start else x.evening_start end,
         case p_slot when 'morning' then x.morning_end else x.evening_end end
  from public.farms x where x.id = f;
$$;

-- A future date: open whenever the clock is outside that round's packing window.
create or replace function public.future_round_open(f uuid, p_slot text) returns boolean
language sql stable set search_path = '' as $$
  select not (public.farm_now(f)::time >= w.starts and public.farm_now(f)::time < w.ends)
  from public.round_window(f, p_slot) w;
$$;

-- Today: open only until packing starts.
create or replace function public.today_round_open(f uuid, p_slot text) returns boolean
language sql stable set search_path = '' as $$
  select public.farm_now(f)::time < w.starts from public.round_window(f, p_slot) w;
$$;

-- Can a customer still change this round? Asked on the server, in the farm's
-- time zone, never on the phone, whose clock may be set anywhere.
create or replace function public.round_open(f uuid, p_day date, p_slot text) returns boolean
language plpgsql stable set search_path = '' as $$
declare today date := public.farm_today(f);
begin
  if p_day < today or public.day_locked(f, p_day) then return false; end if;
  if p_slot = 'both' then
    return public.round_open(f, p_day, 'morning') and public.round_open(f, p_day, 'evening');
  end if;
  if p_day = today then return public.today_round_open(f, p_slot); end if;
  return public.future_round_open(f, p_slot);
end $$;

-- ---------------------------------------------------------------- office: pauses

create or replace function public.customer_on_farm(p_customer uuid) returns public.customers
language plpgsql stable security definer set search_path = '' as $$
declare c public.customers%rowtype;
begin
  select * into c from public.customers x where x.id = p_customer;
  if not found or c.farm_id is distinct from public.current_farm_id() then
    raise exception 'That customer is not on this farm.' using errcode = '42501';
  end if;
  return c;
end $$;

create or replace function public.slot_words(p_slot text) returns text
language sql immutable set search_path = '' as $$
  select case p_slot when 'morning' then 'morning round' when 'evening' then 'evening round' else 'both rounds' end;
$$;

-- Shared by the office and the portal. `who` is 'office' or 'customer'.
create or replace function public.add_pause(c public.customers, p_kind text, p_from date, p_to date, p_slot text,
  p_reason text, p_dates date[], who text, who_name text) returns void
language plpgsql security definer set search_path = '' as $$
declare today date := public.farm_today(c.farm_id); d date;
begin
  p_slot := coalesce(nullif(p_slot, ''), 'both');
  if p_slot not in ('morning', 'evening', 'both') then raise exception 'Pick a round.' using errcode = '22023'; end if;
  if p_kind = 'dates' then
    if p_dates is null or cardinality(p_dates) = 0 then raise exception 'Pick at least one date.' using errcode = '22023'; end if;
    if cardinality(p_dates) > 62 then raise exception 'Pick up to 62 dates at once.' using errcode = '22023'; end if;
    foreach d in array p_dates loop
      if d < today then raise exception 'Dates in the past cannot be paused.' using errcode = '22023'; end if;
      insert into public.customer_pause_dates (farm_id, customer_id, pause_date, slot, reason, set_by, set_by_name)
      values (c.farm_id, c.id, d, p_slot, nullif(btrim(p_reason), ''), who, who_name)
      on conflict on constraint customer_pause_dates_customer_id_pause_date_slot_key do nothing;
    end loop;
    return;
  end if;
  if p_kind = 'today_only' then p_from := today; p_to := today;
  elsif p_kind = 'tomorrow_only' then p_from := today + 1; p_to := today + 1;
  elsif p_kind = 'until_resumed' then p_to := null;
  elsif p_kind <> 'custom_range' then raise exception 'Unknown kind of pause.' using errcode = '22023';
  end if;
  if p_from is null then raise exception 'Pick the first day.' using errcode = '22023'; end if;
  if p_from < today then raise exception 'A pause cannot start in the past.' using errcode = '22023'; end if;
  if p_kind = 'custom_range' and (p_to is null or p_to < p_from) then
    raise exception 'Pick a last day on or after the first.' using errcode = '22023';
  end if;
  insert into public.customer_pauses (farm_id, customer_id, pause_type, from_date, to_date, slot, reason, set_by, set_by_name)
  values (c.farm_id, c.id, p_kind, p_from, p_to, p_slot, nullif(btrim(p_reason), ''), who, who_name);
end $$;

create or replace function public.pause_customer(customer_id uuid, kind text, from_date date default null,
  to_date date default null, slot text default 'both', reason text default null, dates date[] default null) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(pause_customer.customer_id);
begin
  if not public.staff_can('pauses') then
    raise exception 'You need the Pause / Stop page to pause milk.' using errcode = '42501';
  end if;
  perform public.add_pause(c, kind, from_date, to_date, slot, reason, dates, 'office', public.my_name());
  perform public.audit(c.farm_id, 'pause', 'customer', c.id::text,
    format('%s paused (%s, %s)', c.name, replace(kind, '_', ' '), public.slot_words(coalesce(slot, 'both'))),
    null, jsonb_build_object('kind', kind, 'from', from_date, 'to', to_date, 'slot', slot, 'dates', dates));
end $$;

-- Resuming ends open pauses and any pause still ahead, from a given day
-- (today by default). Past days stay as they were: they are history.
create or replace function public.end_pauses(c public.customers, p_from date) returns int
language plpgsql security definer set search_path = '' as $$
declare n int := 0; m int;
begin
  -- Pauses that have not started yet go entirely.
  delete from public.customer_pauses p where p.customer_id = c.id and p.is_active and p.from_date >= p_from;
  get diagnostics m = row_count; n := n + m;
  -- Pauses already running stop the day before.
  update public.customer_pauses p
     set to_date = p_from - 1, pause_type = 'custom_range'
   where p.customer_id = c.id and p.is_active and p.from_date < p_from
     and (p.to_date is null or p.to_date >= p_from);
  get diagnostics m = row_count; n := n + m;
  delete from public.customer_pause_dates d where d.customer_id = c.id and d.pause_date >= p_from;
  get diagnostics m = row_count; n := n + m;
  return n;
end $$;

create or replace function public.resume_customer(customer_id uuid, from_date date default null) returns int
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(resume_customer.customer_id); n int;
begin
  if not public.staff_can('pauses') then
    raise exception 'You need the Pause / Stop page to resume milk.' using errcode = '42501';
  end if;
  n := public.end_pauses(c, coalesce(from_date, public.farm_today(c.farm_id)));
  perform public.audit(c.farm_id, 'resume', 'customer', c.id::text,
    format('%s resumed from %s', c.name, coalesce(from_date, public.farm_today(c.farm_id))));
  return n;
end $$;

create or replace function public.remove_pause(pause_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare p public.customer_pauses%rowtype; c public.customers;
begin
  select * into p from public.customer_pauses x where x.id = pause_id;
  if not found then
    -- A single date, perhaps.
    select x.customer_id into p.customer_id from public.customer_pause_dates x where x.id = pause_id;
    if not found then raise exception 'That pause was already removed.' using errcode = 'P0002'; end if;
    c := public.customer_on_farm(p.customer_id);
    if not public.staff_can('pauses') then raise exception 'You need the Pause / Stop page.' using errcode = '42501'; end if;
    delete from public.customer_pause_dates x where x.id = pause_id;
  else
    c := public.customer_on_farm(p.customer_id);
    if not public.staff_can('pauses') then raise exception 'You need the Pause / Stop page.' using errcode = '42501'; end if;
    delete from public.customer_pauses x where x.id = pause_id;
  end if;
  perform public.audit(c.farm_id, 'remove_pause', 'customer', c.id::text, format('A pause for %s was removed', c.name));
end $$;

-- ---------------------------------------------------------------- office: temporary deliveries

create or replace function public.clean_vessels(f uuid, items jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare out jsonb := '[]'; it jsonb; k public.containers%rowtype;
begin
  if items is null or jsonb_typeof(items) <> 'array' then return '[]'::jsonb; end if;
  for it in select * from jsonb_array_elements(items) loop
    if coalesce((it ->> 'quantity')::int, 0) <= 0 then continue; end if;
    select * into k from public.containers x where x.id = (it ->> 'container_id')::uuid and x.farm_id = f;
    if not found then raise exception 'That vessel is not on this farm.' using errcode = '22023'; end if;
    out := out || jsonb_build_array(jsonb_build_object('container_id', k.id, 'name', k.name, 'category', k.category,
                                    'capacity_ml', k.capacity_ml, 'quantity', (it ->> 'quantity')::int));
  end loop;
  return out;
end $$;

create or replace function public.set_temporary(customer_id uuid, day date, slot text, quantity numeric,
  vessels jsonb default '[]', note text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(set_temporary.customer_id); id uuid;
begin
  if not public.staff_can('pauses') then
    raise exception 'You need the Pause / Stop page for temporary deliveries.' using errcode = '42501';
  end if;
  if slot not in ('morning', 'evening') then raise exception 'Pick a round.' using errcode = '22023'; end if;
  if day < public.farm_today(c.farm_id) then raise exception 'That day has passed.' using errcode = '22023'; end if;
  if public.day_locked(c.farm_id, day) then raise exception 'That day is closed.' using errcode = '22023'; end if;
  if quantity is null or quantity < 0 then raise exception 'Give a quantity.' using errcode = '22023'; end if;
  insert into public.temporary_deliveries (farm_id, customer_id, delivery_date, slot, quantity, containers, note, created_by)
  values (c.farm_id, c.id, day, slot, quantity, public.clean_vessels(c.farm_id, vessels), nullif(btrim(note), ''), public.my_name())
  on conflict on constraint temporary_deliveries_customer_id_delivery_date_slot_key do update
    set quantity = excluded.quantity, containers = excluded.containers, note = excluded.note, created_by = excluded.created_by
  returning temporary_deliveries.id into id;
  perform public.audit(c.farm_id, 'temporary', 'customer', c.id::text,
    format('%s gets %s L on %s, %s', c.name, quantity, day, public.slot_words(slot)));
  return id;
end $$;

create or replace function public.remove_temporary(temporary_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.temporary_deliveries%rowtype; c public.customers;
begin
  select * into t from public.temporary_deliveries x where x.id = temporary_id;
  if not found then raise exception 'That change was already removed.' using errcode = 'P0002'; end if;
  c := public.customer_on_farm(t.customer_id);
  if not public.staff_can('pauses') then raise exception 'You need the Pause / Stop page.' using errcode = '42501'; end if;
  if public.day_locked(c.farm_id, t.delivery_date) then raise exception 'That day is closed.' using errcode = '22023'; end if;
  delete from public.temporary_deliveries x where x.id = temporary_id;
  perform public.audit(c.farm_id, 'remove_temporary', 'customer', c.id::text,
    format('%s back to the usual on %s, %s', c.name, t.delivery_date, public.slot_words(t.slot)));
end $$;

-- Approving a request makes it a temporary delivery; refusing keeps the
-- conversation and changes nothing.
create or replace function public.decide_request(request_id uuid, approve boolean, note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.temporary_requests%rowtype; c public.customers; tid uuid;
begin
  select * into r from public.temporary_requests x where x.id = request_id for update;
  if not found then raise exception 'That request is gone.' using errcode = 'P0002'; end if;
  c := public.customer_on_farm(r.customer_id);
  if not public.staff_can('pauses') then raise exception 'You need the Pause / Stop page.' using errcode = '42501'; end if;
  if r.status <> 'pending' then raise exception 'That request was already answered.' using errcode = '22023'; end if;
  if approve then
    if r.delivery_date < public.farm_today(c.farm_id) then raise exception 'That day has passed.' using errcode = '22023'; end if;
    insert into public.temporary_deliveries (farm_id, customer_id, delivery_date, slot, quantity, containers, note, created_by, request_id)
    values (c.farm_id, c.id, r.delivery_date, r.slot, r.quantity, r.containers, r.note, public.my_name(), r.id)
    on conflict on constraint temporary_deliveries_customer_id_delivery_date_slot_key do update
      set quantity = excluded.quantity, containers = excluded.containers, note = excluded.note,
          created_by = excluded.created_by, request_id = excluded.request_id
    returning id into tid;
  end if;
  update public.temporary_requests x
     set status = case when approve then 'approved' else 'rejected' end,
         decided_at = now(), decided_by = public.my_name(), decided_note = nullif(btrim(decide_request.note), '')
   where x.id = r.id;
  perform public.audit(c.farm_id, case when approve then 'approve_request' else 'reject_request' end, 'customer', c.id::text,
    format('%s %s %s''s request for %s L on %s, %s', public.my_name(), case when approve then 'approved' else 'refused' end,
           c.name, r.quantity, r.delivery_date, public.slot_words(r.slot)));
end $$;
