-- Dairee, stage 6: the herd.
--
-- A separate world from the round. The only place they meet is milk produced
-- against milk delivered (herd_vs_round). Changing herd records needs the Cows
-- page or the "cares for cows" duty; reading is open to the farm's staff.

create table public.cows (
  id                        uuid primary key default gen_random_uuid(),
  farm_id                   uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  tag_number                text not null check (char_length(btrim(tag_number)) between 1 and 30),
  ear_tag                   text check (char_length(ear_tag) <= 30),
  name                      text check (char_length(name) <= 60),
  breed                     text check (char_length(breed) <= 60),
  sex                       text not null default 'female' check (sex in ('female', 'male')),
  date_of_birth             date,
  status                    text not null default 'milking' check (status in ('milking', 'dry', 'heifer', 'calf', 'sold', 'dead')),
  location                  text check (char_length(location) <= 60),
  qr_token                  text not null default public.new_token(),
  photo_path                text,
  purchase_date             date,
  purchase_price            numeric(12,2),
  lactation_number          int check (lactation_number >= 0),
  calving_count             int check (calving_count >= 0),
  last_calving_date         date,
  pregnancy_status          text not null default 'unknown' check (pregnancy_status in ('unknown', 'open', 'inseminated', 'pregnant')),
  last_ai_date              date,
  ai_bull                   text check (char_length(ai_bull) <= 60),
  ai_attempts               int check (ai_attempts >= 0),
  pregnancy_checked_on      date,
  expected_calving_override date,
  notes                     text check (char_length(notes) <= 1000),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (farm_id, tag_number)
);
create unique index cows_qr on public.cows (qr_token);

create table public.milk_yield (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id      uuid not null references public.cows (id) on delete cascade,
  yield_date  date not null,
  slot        text not null check (slot in ('morning', 'evening')),
  litres      numeric(6,2) not null check (litres >= 0 and litres <= 80),
  recorded_by text,
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now(),
  unique (cow_id, yield_date, slot)
);
create index milk_yield_farm_day on public.milk_yield (farm_id, yield_date);

create table public.cow_health_logs (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id        uuid not null references public.cows (id) on delete cascade,
  observed_on   date not null,
  signs         text[] not null default '{}',
  severity      text check (severity in ('mild', 'moderate', 'severe')),
  temperature_c numeric(4,1) check (temperature_c between 30 and 45),
  treatment     text check (char_length(treatment) <= 300),
  remarks       text check (char_length(remarks) <= 500),
  photo_url     text,
  resolved_on   date,
  recorded_by   text,
  created_at    timestamptz not null default now()
);

create table public.cow_vaccinations (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id      uuid not null references public.cows (id) on delete cascade,
  vaccine     text not null check (char_length(btrim(vaccine)) between 1 and 80),
  given_on    date not null,
  next_due_on date,
  batch       text check (char_length(batch) <= 40),
  given_by    text check (char_length(given_by) <= 60),
  notes       text check (char_length(notes) <= 300),
  created_at  timestamptz not null default now()
);

create table public.cow_heat_logs (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id      uuid not null references public.cows (id) on delete cascade,
  observed_on date not null,
  detected    boolean not null default true,
  intensity   text check (intensity in ('weak', 'medium', 'strong')),
  signs       text[] not null default '{}',
  notes       text check (char_length(notes) <= 300),
  created_at  timestamptz not null default now()
);

create table public.cow_breeding_events (
  id         uuid primary key default gen_random_uuid(),
  farm_id    uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id     uuid not null references public.cows (id) on delete cascade,
  kind       text not null check (kind in ('ai', 'natural', 'pregnancy_check', 'calving', 'abortion', 'dry_off')),
  event_date date not null,
  bull       text check (char_length(bull) <= 60),
  technician text check (char_length(technician) <= 60),
  result     text check (char_length(result) <= 60),
  notes      text check (char_length(notes) <= 300),
  created_at timestamptz not null default now()
);

create table public.cow_weights (
  id                   uuid primary key default gen_random_uuid(),
  farm_id              uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id               uuid not null references public.cows (id) on delete cascade,
  weighed_on           date not null,
  weight_kg            numeric(6,1) not null check (weight_kg > 0 and weight_kg < 2000),
  body_condition_score numeric(2,1) check (body_condition_score between 1 and 5),
  created_at           timestamptz not null default now()
);

create table public.cow_photos (
  id           uuid primary key default gen_random_uuid(),
  farm_id      uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id       uuid not null references public.cows (id) on delete cascade,
  storage_path text not null,
  caption      text check (char_length(caption) <= 120),
  uploaded_by  text,
  created_at   timestamptz not null default now()
);

create table public.cow_assignments (
  id             uuid primary key default gen_random_uuid(),
  farm_id        uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id         uuid not null references public.cows (id) on delete cascade,
  worker_id      uuid not null references public.staff (id) on delete cascade,
  responsibility text not null default 'care' check (char_length(responsibility) <= 40),
  assigned_on    date not null,
  unassigned_on  date,
  created_at     timestamptz not null default now()
);

-- The human-readable timeline: written by triggers on the tables above, so a
-- cow's page is one query rather than nine.
create table public.cow_events (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null references public.farms (id) on delete cascade,
  cow_id      uuid not null references public.cows (id) on delete cascade,
  kind        text not null,
  summary     text not null,
  detail      jsonb,
  actor       text,
  occurred_at timestamptz not null default now()
);
create index cow_events_cow on public.cow_events (cow_id, occurred_at desc);

create table public.feed_items (
  id            uuid primary key default gen_random_uuid(),
  farm_id       uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  label         text not null check (char_length(btrim(label)) between 1 and 60),
  unit          text not null default 'kg' check (char_length(unit) <= 12),
  cost_per_unit numeric(10,2) check (cost_per_unit >= 0),
  active        boolean not null default true
);

create table public.feed_records (
  id                    uuid primary key default gen_random_uuid(),
  farm_id               uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  cow_id                uuid not null references public.cows (id) on delete cascade,
  feed_date             date not null,
  slot                  text not null check (slot in ('morning', 'evening')),
  item_id               uuid not null references public.feed_items (id) on delete restrict,
  quantity              numeric(8,2) not null check (quantity > 0),
  -- Feed costs change; what was spent in March does not.
  cost_per_unit_at_time numeric(10,2),
  created_at            timestamptz not null default now()
);
create index feed_records_farm_day on public.feed_records (farm_id, feed_date);

-- ---------------------------------------------------------------- checks and the timeline

create or replace function public.herd_row_check() returns trigger
language plpgsql set search_path = '' as $$
declare cow_farm uuid;
begin
  if tg_op = 'UPDATE' and new.farm_id is distinct from old.farm_id then
    raise exception 'Records cannot move between farms.' using errcode = '42501';
  end if;
  if tg_table_name <> 'cows' then
    select c.farm_id into cow_farm from public.cows c where c.id = new.cow_id;
    if cow_farm is distinct from new.farm_id then
      raise exception 'That cow is not on this farm.' using errcode = '22023';
    end if;
  end if;
  if tg_table_name = 'cows' then
    new.tag_number := btrim(new.tag_number);
    new.updated_at := now();
  elsif tg_table_name = 'feed_records' then
    if not exists (select 1 from public.feed_items i where i.id = new.item_id and i.farm_id = new.farm_id) then
      raise exception 'That feed is not on this farm.' using errcode = '22023';
    end if;
    if tg_op = 'INSERT' and new.cost_per_unit_at_time is null then
      new.cost_per_unit_at_time := (select i.cost_per_unit from public.feed_items i where i.id = new.item_id);
    end if;
  elsif tg_table_name = 'cow_assignments' then
    if not exists (select 1 from public.staff s where s.id = new.worker_id and s.farm_id = new.farm_id) then
      raise exception 'That worker is not on this farm.' using errcode = '22023';
    end if;
  end if;
  return new;
end $$;

create or replace function public.cow_event(f uuid, cow uuid, p_kind text, p_summary text, p_detail jsonb) returns void
language sql security definer set search_path = '' as $$
  insert into public.cow_events (farm_id, cow_id, kind, summary, detail, actor)
  values (f, cow, p_kind, p_summary, p_detail, public.my_name());
$$;

create or replace function public.herd_timeline() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j jsonb := to_jsonb(new); o jsonb; s text;
begin
  if tg_op = 'UPDATE' then o := to_jsonb(old); end if;
  s := case tg_table_name
    when 'cows' then case when tg_op = 'INSERT' then format('Added to the herd as %s', j ->> 'status')
                          when (o ->> 'status') is distinct from (j ->> 'status') then format('Now %s', j ->> 'status') end
    when 'cow_health_logs' then format('Health: %s', coalesce(
      (select nullif(string_agg(x, ', '), '') from jsonb_array_elements_text(j -> 'signs') x), 'checked'))
    when 'cow_vaccinations' then format('Vaccinated: %s', j ->> 'vaccine')
    when 'cow_heat_logs' then case when (j ->> 'detected')::boolean then 'In heat' else 'Heat check, not in heat' end
    when 'cow_breeding_events' then format('Breeding: %s', replace(j ->> 'kind', '_', ' '))
    when 'cow_weights' then format('Weighed %s kg', j ->> 'weight_kg')
    when 'cow_photos' then 'New photo'
    when 'cow_assignments' then 'Worker assigned'
  end;
  -- Other tables log their first entry only; a cow also logs a change of status.
  if s is not null and (tg_op = 'INSERT' or tg_table_name = 'cows') then
    perform public.cow_event((j ->> 'farm_id')::uuid,
      case when tg_table_name = 'cows' then (j ->> 'id')::uuid else (j ->> 'cow_id')::uuid end,
      tg_table_name, s, j - 'farm_id');
  end if;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['cows', 'milk_yield', 'cow_health_logs', 'cow_vaccinations', 'cow_heat_logs',
                           'cow_breeding_events', 'cow_weights', 'cow_photos', 'cow_assignments', 'feed_records'] loop
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.herd_row_check()',
                   t || '_check', t);
  end loop;
  foreach t in array array['cows', 'cow_health_logs', 'cow_vaccinations', 'cow_heat_logs', 'cow_breeding_events',
                           'cow_weights', 'cow_photos', 'cow_assignments'] loop
    execute format('create trigger %I after insert or update on public.%I for each row execute function public.herd_timeline()',
                   t || '_timeline', t);
  end loop;
  -- Row level security: the farm's staff read; the Cows page or the care duty writes.
  foreach t in array array['cows', 'milk_yield', 'cow_health_logs', 'cow_vaccinations', 'cow_heat_logs',
                           'cow_breeding_events', 'cow_weights', 'cow_photos', 'cow_assignments', 'feed_items', 'feed_records'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %I on public.%I for select to authenticated using (farm_id = (select public.current_farm_id()))',
                   t || '_read', t);
    execute format('create policy %I on public.%I for all to authenticated
                      using (farm_id = (select public.current_farm_id()) and (select public.can_care()))
                      with check (farm_id = (select public.current_farm_id()) and (select public.can_care()))',
                   t || '_write', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

alter table public.cow_events enable row level security;
create policy cow_events_read on public.cow_events for select to authenticated
  using (farm_id = (select public.current_farm_id()));
revoke insert, update, delete on public.cow_events from authenticated;
revoke all on public.cow_events from anon;

-- Money in the herd (purchase prices, feed costs) follows the money rule: the
-- columns are there for the office; the app shows them only with Payments.

-- Milk the herd gave against milk the round took, day by day.
create or replace function public.herd_vs_round(date_from date, date_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('day', d::date,
      'produced', coalesce((select sum(y.litres) from public.milk_yield y where y.farm_id = f and y.yield_date = d::date), 0),
      'delivered', coalesce((select sum(r.milk_quantity) from public.delivery_records r
                              where r.farm_id = f and r.delivery_date = d::date and r.delivered), 0))
      order by d)
    from generate_series(date_from, date_to, interval '1 day') d), '[]'::jsonb);
end $$;
