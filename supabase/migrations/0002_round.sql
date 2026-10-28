-- Dairee, stage 2: customers, the vessels milk goes out in, and the round.
--
-- Milk goes out on rounds: morning and evening. A customer on both rounds has
-- a quantity for each, and those are two numbers, not one halved. Everything
-- downstream (packing, ticks, bills, pauses) is per round, and a day's
-- delivery is one record per customer per date per round.

-- ---------------------------------------------------------------- customers

create table public.customers (
  id                     uuid primary key default gen_random_uuid(),
  farm_id                uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  name                   text not null check (char_length(btrim(name)) between 1 and 80),
  phone                  text not null check (phone ~ '^[0-9]{8,15}$'),
  customer_type          text not null default 'home' check (char_length(customer_type) between 1 and 30),
  building               text check (char_length(building) <= 60),   -- tower, block, street: what the round groups by
  room                   text check (char_length(room) <= 30),
  address                text check (char_length(address) <= 300),
  route_order            int not null default 0,                    -- walking order on the round
  milk_quantity          numeric(8,3) not null default 0 check (milk_quantity >= 0),   -- the day's total
  morning_quantity       numeric(8,3) check (morning_quantity > 0), -- set only when delivery_slot = 'both'
  evening_quantity       numeric(8,3) check (evening_quantity > 0),
  delivery_slot          text not null default 'morning' check (delivery_slot in ('morning', 'evening', 'both')),
  delivery_staff_id      uuid references public.staff (id) on delete set null,
  start_date             date not null default current_date,
  status                 text not null default 'active' check (status in ('active', 'stopped')),
  remarks                text check (char_length(remarks) <= 500),
  qr_token               text not null default public.new_token(),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index customers_farm on public.customers (farm_id, status);
create index customers_phone on public.customers (phone);
create unique index customers_qr on public.customers (qr_token);

-- The day total always agrees with the round quantities, decided here and
-- never by a screen, or two screens will disagree.
create or replace function public.customers_check() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.name := btrim(new.name);
  new.phone := public.phone_digits(new.phone);
  if new.phone is null or new.phone !~ '^[0-9]{8,15}$' then
    raise exception 'Add the customer''s mobile number with the country code.' using errcode = '22023';
  end if;
  new.building := nullif(btrim(coalesce(new.building, '')), '');
  new.room := nullif(btrim(coalesce(new.room, '')), '');
  if new.delivery_slot = 'both' then
    if coalesce(new.morning_quantity, 0) <= 0 or coalesce(new.evening_quantity, 0) <= 0 then
      raise exception 'Give the morning and the evening quantity.' using errcode = '22023';
    end if;
    new.milk_quantity := new.morning_quantity + new.evening_quantity;
  else
    new.morning_quantity := null;
    new.evening_quantity := null;
  end if;
  new.updated_at := now();
  if tg_op = 'UPDATE' then
    if new.farm_id is distinct from old.farm_id then
      raise exception 'Customers cannot move between farms.' using errcode = '42501';
    end if;
    if not public.trusted_writer() then
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end $$;
create trigger customers_check before insert or update on public.customers
  for each row execute function public.customers_check();

-- How much a customer takes on a round, by their standing order.
create or replace function public.standing_qty(c public.customers, p_slot text) returns numeric
language sql immutable set search_path = '' as $$
  select case
    when c.delivery_slot = 'both' then case p_slot when 'morning' then c.morning_quantity else c.evening_quantity end
    when c.delivery_slot = p_slot then c.milk_quantity
    else 0
  end;
$$;

-- ---------------------------------------------------------------- vessels

create table public.containers (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 40),
  category    text not null check (category in ('bottle', 'can', 'packet', 'other')),
  capacity_ml int not null check (capacity_ml between 50 and 100000),
  active      boolean not null default true,
  sort_order  int not null default 0
);
create index containers_farm on public.containers (farm_id);

create table public.customer_containers (
  id           uuid primary key default gen_random_uuid(),
  farm_id      uuid not null references public.farms (id) on delete cascade,
  customer_id  uuid not null references public.customers (id) on delete cascade,
  container_id uuid not null references public.containers (id) on delete restrict,
  quantity     int not null check (quantity > 0),
  slot         text not null check (slot in ('morning', 'evening')),
  -- The slot is part of the key: the same 5 litre can morning and evening is
  -- two rows. A key without it once left twice-a-day customers with nothing.
  unique (customer_id, container_id, slot)
);
create index customer_containers_customer on public.customer_containers (customer_id);

-- Vessels as copied into a record: name, size and kind as they were that day.
create or replace function public.vessels_json(p_customer uuid, p_slot text) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'container_id', k.id, 'name', k.name, 'category', k.category,
           'capacity_ml', k.capacity_ml, 'quantity', cc.quantity) order by k.sort_order, k.capacity_ml), '[]'::jsonb)
  from public.customer_containers cc join public.containers k on k.id = cc.container_id
  where cc.customer_id = p_customer and cc.slot = p_slot;
$$;

-- ---------------------------------------------------------------- deliveries

create table public.delivery_records (
  id                uuid primary key default gen_random_uuid(),
  farm_id           uuid not null references public.farms (id) on delete cascade,
  customer_id       uuid not null references public.customers (id) on delete cascade,
  delivery_date     date not null,
  slot              text not null check (slot in ('morning', 'evening')),
  delivered         boolean not null default false,
  delivered_at      timestamptz,
  bottle_returned   boolean not null default false,
  returned_at       timestamptz,
  milk_quantity     numeric(8,3) check (milk_quantity >= 0),  -- what actually went
  containers        jsonb,                                  -- the vessels, copied in
  delivery_staff_id uuid references public.staff (id) on delete set null,
  notes             text check (char_length(notes) <= 300),  -- what the doorstep reported
  updated_at        timestamptz not null default now(),
  updated_by        text,
  unique (customer_id, delivery_date, slot)
);
create index delivery_records_farm_day on public.delivery_records (farm_id, delivery_date, slot);

-- A closed day stops moving once it has been walked or billed.
create table public.daily_delivery_locks (
  id          uuid primary key default gen_random_uuid(),
  farm_id     uuid not null references public.farms (id) on delete cascade,
  lock_date   date not null,
  is_locked   boolean not null default true,
  locked_at   timestamptz,
  locked_by   text not null,
  unlocked_at timestamptz,
  unique (farm_id, lock_date)
);

create or replace function public.day_locked(f uuid, d date) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select l.is_locked from public.daily_delivery_locks l where l.farm_id = f and l.lock_date = d), false);
$$;

-- ---------------------------------------------------------------- row level security
--
-- Reading is open to anyone working for the farm: the office's pages lean on
-- each other (reports count deliveries, preparation reads customers). Changing
-- a table is gated by the page that owns it. Money is the exception, below.

alter table public.customers enable row level security;
alter table public.containers enable row level security;
alter table public.customer_containers enable row level security;
alter table public.delivery_records enable row level security;
alter table public.daily_delivery_locks enable row level security;

create policy customers_read on public.customers for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy customers_insert on public.customers for insert to authenticated
  with check (farm_id = (select public.current_farm_id()) and (select public.staff_can('customers')));
create policy customers_update on public.customers for update to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('customers')))
  with check (farm_id = (select public.current_farm_id()));
create policy customers_delete on public.customers for delete to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('customers')));

revoke all on public.customers from anon;

create policy containers_read on public.containers for select to authenticated
  using (farm_id = (select public.current_farm_id()));
create policy containers_write on public.containers for all to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('settings')))
  with check (farm_id = (select public.current_farm_id()) and (select public.staff_can('settings')));

create policy customer_containers_read on public.customer_containers for select to authenticated
  using (farm_id = (select public.current_farm_id()));
-- Written only through save_customer_vessels, which swaps a customer's whole set at once.
revoke insert, update, delete on public.customer_containers from anon, authenticated;

create policy delivery_records_read on public.delivery_records for select to authenticated
  using (farm_id = (select public.current_farm_id()));
-- Written only through set_delivery and set_bottle_returned.
revoke insert, update, delete on public.delivery_records from anon, authenticated;

create policy locks_read on public.daily_delivery_locks for select to authenticated
  using (farm_id = (select public.current_farm_id()));
revoke insert, update, delete on public.daily_delivery_locks from anon, authenticated;

revoke all on public.containers, public.customer_containers, public.delivery_records, public.daily_delivery_locks from anon;

-- ---------------------------------------------------------------- vessels for a customer

-- The whole set is swapped in one transaction: a delete that succeeds with an
-- insert that fails leaves nothing behind, because both roll back together.
create or replace function public.save_customer_vessels(customer_id uuid, items jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers%rowtype; it jsonb; n int := 0;
begin
  select * into c from public.customers x where x.id = save_customer_vessels.customer_id;
  if not found or c.farm_id is distinct from public.current_farm_id() then
    raise exception 'That customer is not on this farm.' using errcode = '42501';
  end if;
  if not public.staff_can('customers') then
    raise exception 'You need the Customers page to change vessels.' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(items, '[]'::jsonb)) <> 'array' then
    raise exception 'Nothing to save.' using errcode = '22023';
  end if;
  delete from public.customer_containers cc where cc.customer_id = c.id;
  for it in select * from jsonb_array_elements(coalesce(items, '[]'::jsonb)) loop
    if not exists (select 1 from public.containers k where k.id = (it ->> 'container_id')::uuid and k.farm_id = c.farm_id) then
      raise exception 'That vessel is not on this farm.' using errcode = '22023';
    end if;
    if coalesce((it ->> 'quantity')::int, 0) <= 0 then continue; end if;
    insert into public.customer_containers (farm_id, customer_id, container_id, quantity, slot)
    values (c.farm_id, c.id, (it ->> 'container_id')::uuid, (it ->> 'quantity')::int, it ->> 'slot')
    on conflict on constraint customer_containers_customer_id_container_id_slot_key
    do update set quantity = public.customer_containers.quantity + excluded.quantity;
    n := n + 1;
  end loop;
  perform public.audit(c.farm_id, 'save_vessels', 'customer', c.id::text,
    format('Vessels for %s changed (%s %s)', c.name, n, case n when 1 then 'line' else 'lines' end));
  return jsonb_build_object('morning', public.vessels_json(c.id, 'morning'), 'evening', public.vessels_json(c.id, 'evening'));
end $$;

-- ---------------------------------------------------------------- seeding a farm

create or replace function public.seed_farm(f uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.containers (farm_id, name, category, capacity_ml, sort_order) values
    (f, '500 ml bottle', 'bottle', 500, 10),
    (f, '1 litre bottle', 'bottle', 1000, 20),
    (f, '2 litre can', 'can', 2000, 30),
    (f, '5 litre can', 'can', 5000, 40);
end $$;
