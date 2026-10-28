-- Dairee, stage 4: prices, bills, payments, discounts and credit.
--
-- The invariant that keeps this honest, asserted before and after every money
-- migration and in the tests:
--
--     sum(payments) = collected + credit held + credit applied
--
-- collected      payments made against a bill, up to what that bill needed
-- credit applied advance and overpaid money that a bill has taken
-- credit held    advance and overpaid money not used yet: the customer's, not income
--
-- Money is read only by people with the Payments page, and never by the round.

-- ---------------------------------------------------------------- prices

-- A dated series, not a column: a bill for September uses September's price
-- even when it is made in November.
create table public.milk_prices (
  id              uuid primary key default gen_random_uuid(),
  farm_id         uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  price_per_liter numeric(10,2) not null check (price_per_liter >= 0),
  effective_from  date not null,
  effective_to    date,
  is_active       boolean not null default true,
  notes           text check (char_length(notes) <= 200),
  created_at      timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);
create index milk_prices_farm on public.milk_prices (farm_id, effective_from desc);

-- The price that applied on a day, or null when none was set yet.
create or replace function public.price_on(f uuid, d date) returns numeric
language sql stable security definer set search_path = '' as $$
  select p.price_per_liter from public.milk_prices p
  where p.farm_id = f and p.is_active and p.effective_from <= d and (p.effective_to is null or p.effective_to >= d)
  order by p.effective_from desc, p.created_at desc
  limit 1;
$$;

-- A customer's own price overrides the farm's, from when it was set.
create table public.customer_prices (
  customer_id     uuid primary key references public.customers (id) on delete cascade,
  farm_id         uuid not null references public.farms (id) on delete cascade,
  price_per_liter numeric(10,2) not null check (price_per_liter >= 0),
  updated_at      timestamptz not null default now(),
  updated_by      text
);

-- ---------------------------------------------------------------- bills and payments

create table public.bills (
  id              uuid primary key default gen_random_uuid(),
  farm_id         uuid not null references public.farms (id) on delete cascade,
  customer_id     uuid not null references public.customers (id) on delete restrict,
  seq             int not null,
  bill_number     text not null,
  period_from     date not null,
  period_to       date not null,
  bill_date       date not null,
  milk_price      numeric(10,2) not null,     -- frozen: the price that applied, not today's
  total_liters    numeric(10,3) not null,
  total_amount    numeric(12,2) not null check (total_amount >= 0),
  delivered_days  int not null,
  missed_days     int not null,
  paused_days     int not null,
  discount_amount numeric(12,2) not null default 0 check (discount_amount >= 0),
  credit_before   numeric(12,2) not null default 0,   -- what they had in hand for this bill
  credit_applied  numeric(12,2) not null default 0,   -- how much of it this bill took
  notes           text check (char_length(notes) <= 300),
  created_by      text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (period_to >= period_from),
  unique (farm_id, seq),
  unique (farm_id, bill_number),
  -- A customer can never be billed twice for the same days.
  constraint bills_no_overlap exclude using gist (
    customer_id with =,
    daterange(period_from, period_to, '[]') with &&
  )
);
create index bills_farm on public.bills (farm_id, bill_date desc);
create index bills_customer on public.bills (customer_id, period_from);

create table public.payments (
  id               uuid primary key default gen_random_uuid(),
  farm_id          uuid not null default public.current_farm_id() references public.farms (id) on delete cascade,
  customer_id      uuid not null references public.customers (id) on delete restrict,
  amount           numeric(12,2) not null check (amount > 0),
  payment_date     date not null,
  payment_method   text not null default 'cash' check (payment_method in ('cash', 'upi', 'bank', 'other')),
  bill_id          uuid references public.bills (id) on delete set null,
  -- Money not paid against a bill is the customer's credit until a bill uses it.
  counts_as_credit boolean not null default false,
  receipt_number   text check (char_length(receipt_number) <= 40),
  notes            text check (char_length(notes) <= 300),
  recorded_by      text,
  created_at       timestamptz not null default now()
);
create index payments_customer on public.payments (customer_id, payment_date);
create index payments_bill on public.payments (bill_id) where bill_id is not null;
create index payments_farm on public.payments (farm_id, payment_date desc);

-- What each customer holds in credit, kept by recompute_customer_credit.
create table public.customer_credit (
  customer_id uuid primary key references public.customers (id) on delete cascade,
  farm_id     uuid not null references public.farms (id) on delete cascade,
  held        numeric(12,2) not null default 0,
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------- credit: one authority
--
-- The only thing allowed to set credit_before and credit_applied. Called by
-- triggers on bills and on payments, so correcting or deleting an advance
-- fixes every bill it ever touched.
--
-- The pool is every payment not made against a bill, plus whatever a payment
-- against a bill paid beyond that bill. The pool pays the oldest bills first.
create or replace function public.recompute_customer_credit(p_customer uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare pool numeric := 0; b record; due numeric; take numeric; f uuid;
begin
  -- One recount per customer at a time: two payments saved at the same moment
  -- would each count without the other and the last to finish would win.
  select c.farm_id into f from public.customers c where c.id = p_customer for no key update;
  if f is null then return 0; end if;
  select coalesce(sum(p.amount), 0) into pool from public.payments p
   where p.customer_id = p_customer and p.bill_id is null;
  select pool + coalesce(sum(greatest(0, x.direct - x.net)), 0) into pool from (
    select greatest(0, bl.total_amount - bl.discount_amount) as net,
           coalesce((select sum(p.amount) from public.payments p where p.bill_id = bl.id), 0) as direct
    from public.bills bl where bl.customer_id = p_customer) x;
  for b in
    select bl.id, bl.credit_before, bl.credit_applied, greatest(0, bl.total_amount - bl.discount_amount) as net,
           coalesce((select sum(p.amount) from public.payments p where p.bill_id = bl.id), 0) as direct
    from public.bills bl where bl.customer_id = p_customer
    order by bl.period_from, bl.bill_date, bl.seq
  loop
    due := greatest(0, b.net - b.direct);
    take := least(pool, due);
    if b.credit_before is distinct from pool or b.credit_applied is distinct from take then
      update public.bills x set credit_before = pool, credit_applied = take where x.id = b.id;
    end if;
    pool := pool - take;
  end loop;
  insert into public.customer_credit (customer_id, farm_id, held, updated_at)
  values (p_customer, f, pool, now())
  on conflict on constraint customer_credit_pkey do update set held = excluded.held, updated_at = now()
    where public.customer_credit.held is distinct from excluded.held;
  return pool;
end $$;

create or replace function public.payments_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform public.recompute_customer_credit(old.customer_id); end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.customer_id is distinct from old.customer_id) then
    perform public.recompute_customer_credit(new.customer_id);
  end if;
  return null;
end $$;
create trigger payments_changed after insert or update or delete on public.payments
  for each row execute function public.payments_changed();

create or replace function public.payments_check() returns trigger
language plpgsql set search_path = '' as $$
declare b public.bills%rowtype;
begin
  if new.bill_id is not null then
    select * into b from public.bills x where x.id = new.bill_id;
    if not found or b.customer_id <> new.customer_id then
      raise exception 'That bill belongs to someone else.' using errcode = '22023';
    end if;
  end if;
  if not exists (select 1 from public.customers c where c.id = new.customer_id and c.farm_id = new.farm_id) then
    raise exception 'That customer is not on this farm.' using errcode = '22023';
  end if;
  new.counts_as_credit := new.bill_id is null;
  new.receipt_number := nullif(btrim(coalesce(new.receipt_number, '')), '');
  if tg_op = 'INSERT' then
    if not public.trusted_writer() or new.recorded_by is null then new.recorded_by := public.my_name(); end if;
    new.created_at := now();
  else
    if new.farm_id is distinct from old.farm_id then
      raise exception 'Payments cannot move between farms.' using errcode = '42501';
    end if;
    new.recorded_by := old.recorded_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger payments_check before insert or update on public.payments
  for each row execute function public.payments_check();

create or replace function public.bills_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then perform public.recompute_customer_credit(old.customer_id); end if;
  if tg_op = 'INSERT' or (tg_op = 'UPDATE' and new.customer_id is distinct from old.customer_id) then
    perform public.recompute_customer_credit(new.customer_id);
  end if;
  return null;
end $$;
create trigger bills_changed after insert or delete or update of total_amount, discount_amount, customer_id, period_from, bill_date
  on public.bills for each row execute function public.bills_changed();

create or replace function public.bills_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if new.farm_id is distinct from old.farm_id or new.customer_id is distinct from old.customer_id then
    raise exception 'A bill cannot move to someone else.' using errcode = '42501';
  end if;
  if new.discount_amount > new.total_amount then
    raise exception 'The discount is more than the bill.' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger bills_touch before update on public.bills
  for each row execute function public.bills_touch();

-- ---------------------------------------------------------------- what is owed: one answer

-- Every screen and every printed bill reads this. Nothing does its own
-- subtraction: a second idea of "what is owed" always drifts.
create view public.bill_balances with (security_invoker = true) as
select b.id as bill_id,
       b.farm_id,
       b.customer_id,
       b.bill_number,
       b.period_from,
       b.period_to,
       b.bill_date,
       b.total_amount,
       b.discount_amount,
       greatest(0, b.total_amount - b.discount_amount)                       as net_amount,
       b.credit_before,
       b.credit_applied,
       coalesce(p.paid, 0)                                                    as amount_paid,
       least(coalesce(p.paid, 0), greatest(0, b.total_amount - b.discount_amount)) as collected,
       coalesce(p.paid, 0) + b.credit_applied                                 as amount_covered,
       greatest(0, greatest(0, b.total_amount - b.discount_amount)
                   - coalesce(p.paid, 0) - b.credit_applied)                  as balance_due
from public.bills b
left join lateral (
  select sum(x.amount) as paid from public.payments x where x.bill_id = b.id
) p on true;

-- ---------------------------------------------------------------- row level security

alter table public.milk_prices enable row level security;
alter table public.customer_prices enable row level security;
alter table public.bills enable row level security;
alter table public.payments enable row level security;
alter table public.customer_credit enable row level security;

-- Money is refused outright without the Payments page: a figure glimpsed is a figure known.
-- The price feeds every bill, so it is Payments too, even on the Settings page.
create policy prices_read on public.milk_prices for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
create policy prices_write on public.milk_prices for all to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')))
  with check (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));

create policy customer_prices_read on public.customer_prices for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
revoke insert, update, delete on public.customer_prices from authenticated;

create policy bills_read on public.bills for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
create policy bills_update on public.bills for update to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')))
  with check (farm_id = (select public.current_farm_id()));
create policy bills_delete on public.bills for delete to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
-- Bills are made by generate_bills; only the discount and the note are edited by hand.
revoke insert, update on public.bills from authenticated;
grant update (discount_amount, notes) on public.bills to authenticated;

create policy payments_read on public.payments for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
create policy payments_write on public.payments for all to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')))
  with check (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));

create policy credit_read on public.customer_credit for select to authenticated
  using (farm_id = (select public.current_farm_id()) and (select public.staff_can('payments')));
revoke insert, update, delete on public.customer_credit from authenticated;

revoke all on public.milk_prices, public.customer_prices, public.bills, public.payments,
  public.customer_credit, public.bill_balances from anon;
grant select on public.bill_balances to authenticated;

-- ---------------------------------------------------------------- customer prices

create or replace function public.set_customer_price(customer_id uuid, price numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(set_customer_price.customer_id); old numeric;
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to set a price.' using errcode = '42501';
  end if;
  if price is not null and price < 0 then raise exception 'A price cannot be negative.' using errcode = '22023'; end if;
  select p.price_per_liter into old from public.customer_prices p where p.customer_id = c.id;
  if price is null then
    delete from public.customer_prices p where p.customer_id = c.id;
  else
    insert into public.customer_prices (customer_id, farm_id, price_per_liter, updated_by)
    values (c.id, c.farm_id, price, public.my_name())
    on conflict on constraint customer_prices_pkey do update set price_per_liter = excluded.price_per_liter,
      updated_at = now(), updated_by = excluded.updated_by;
  end if;
  perform public.audit(c.farm_id, 'set_price', 'customer', c.id::text,
    case when price is null then format('%s back on the farm price', c.name)
         else format('%s now pays %s a litre', c.name, price) end,
    jsonb_build_object('price', old), jsonb_build_object('price', price));
end $$;

-- ---------------------------------------------------------------- making bills

-- The figures for one customer and period, straight from the delivery records.
create or replace function public.bill_figures(c public.customers, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb; own numeric;
begin
  select p.price_per_liter into own from public.customer_prices p where p.customer_id = c.id;
  with recs as (
    select d.delivery_date, d.slot, coalesce(d.milk_quantity, 0) as qty,
           coalesce(own, public.price_on(c.farm_id, d.delivery_date)) as price
    from public.delivery_records d
    where d.customer_id = c.id and d.delivered and d.delivery_date between p_from and p_to
  ), days as (
    select e.day,
           bool_or(not e.paused and e.qty > 0) as wanted,
           bool_and(e.paused) as all_paused
    from public.expected_rounds(c.farm_id, p_from, p_to, c.id) e
    group by e.day
  ), done as (
    select distinct r.delivery_date as day from recs r where r.qty > 0
  )
  select jsonb_build_object(
    'liters', coalesce((select sum(qty) from recs), 0),
    'amount', coalesce((select sum(round(qty * price, 2)) from recs), 0),
    'unpriced', (select min(delivery_date) from recs where price is null),
    'prices', coalesce((select jsonb_agg(distinct price) from recs where price is not null), '[]'::jsonb),
    'delivered_days', (select count(*) from done),
    'missed_days', (select count(*) from days where days.wanted and days.day not in (select day from done)),
    'paused_days', (select count(*) from days where days.all_paused and days.day not in (select day from done)))
  into r;
  return r;
end $$;

-- Bills for a period: every customer with milk delivered in it, or the ones
-- named. Customers already billed for any of those days are skipped, never
-- billed twice.
create or replace function public.generate_bills(period_from date, period_to date, customer_ids uuid[] default null,
  bill_date date default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  f uuid := public.current_farm_id(); fm public.farms%rowtype; c public.customers%rowtype; fig jsonb;
  made jsonb := '[]'; skipped jsonb := '[]'; nseq int; price numeric; bd date; bid uuid;
  pf date := generate_bills.period_from; pt date := generate_bills.period_to;
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to make bills.' using errcode = '42501';
  end if;
  if pf is null or pt is null or pt < pf then
    raise exception 'Pick a period: the last day on or after the first.' using errcode = '22023';
  end if;
  if pt - pf > 92 then raise exception 'Bill up to three months at a time.' using errcode = '22023'; end if;
  select * into fm from public.farms x where x.id = f for update;   -- one bill run at a time per farm
  bd := coalesce(generate_bills.bill_date, public.farm_today(f));
  for c in
    select x.* from public.customers x
    where x.farm_id = f and (customer_ids is null or x.id = any (customer_ids))
      and exists (select 1 from public.delivery_records d where d.customer_id = x.id and d.delivered
                    and d.delivery_date between pf and pt)
    order by x.name
  loop
    if exists (select 1 from public.bills b where b.customer_id = c.id
                 and daterange(b.period_from, b.period_to, '[]') && daterange(pf, pt, '[]')) then
      skipped := skipped || jsonb_build_array(jsonb_build_object('customer_id', c.id, 'name', c.name,
        'reason', 'Already billed for some of these days'));
      continue;
    end if;
    fig := public.bill_figures(c, pf, pt);
    if (fig ->> 'unpriced') is not null then
      skipped := skipped || jsonb_build_array(jsonb_build_object('customer_id', c.id, 'name', c.name,
        'reason', format('No milk price set for %s', fig ->> 'unpriced')));
      continue;
    end if;
    if (fig ->> 'liters')::numeric <= 0 then
      skipped := skipped || jsonb_build_array(jsonb_build_object('customer_id', c.id, 'name', c.name,
        'reason', 'Nothing delivered'));
      continue;
    end if;
    price := case when jsonb_array_length(fig -> 'prices') = 1 then (fig -> 'prices' ->> 0)::numeric
                  else round((fig ->> 'amount')::numeric / (fig ->> 'liters')::numeric, 2) end;
    select coalesce(max(b.seq), 0) + 1 into nseq from public.bills b where b.farm_id = f;
    insert into public.bills (farm_id, customer_id, seq, bill_number, period_from, period_to, bill_date, milk_price,
                              total_liters, total_amount, delivered_days, missed_days, paused_days, notes, created_by)
    values (f, c.id, nseq, fm.bill_prefix || '-' || to_char(bd, 'YYMM') || '-' || lpad(nseq::text, 4, '0'),
            pf, pt, bd, price,
            (fig ->> 'liters')::numeric, (fig ->> 'amount')::numeric,
            (fig ->> 'delivered_days')::int, (fig ->> 'missed_days')::int, (fig ->> 'paused_days')::int,
            case when jsonb_array_length(fig -> 'prices') > 1 then 'The price changed during this period.' end,
            public.my_name())
    returning id into bid;
    made := made || jsonb_build_array(bid);
  end loop;
  perform public.audit(f, 'generate_bills', 'bills', null,
    format('%s bills made for %s to %s (%s skipped)', jsonb_array_length(made), pf, pt, jsonb_array_length(skipped)));
  return jsonb_build_object('made', jsonb_array_length(made), 'bill_ids', made, 'skipped', skipped);
end $$;

-- Deliveries corrected after a bill was made: the bill takes the new figures,
-- keeping its number, discount and payments.
create or replace function public.refresh_bill(bill_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare b public.bills%rowtype; c public.customers; fig jsonb;
begin
  select * into b from public.bills x where x.id = bill_id;
  if not found or b.farm_id is distinct from public.current_farm_id() then
    raise exception 'That bill is not on this farm.' using errcode = '42501';
  end if;
  if not public.staff_can('payments') then raise exception 'You need the Payments page.' using errcode = '42501'; end if;
  c := public.customer_on_farm(b.customer_id);
  fig := public.bill_figures(c, b.period_from, b.period_to);
  if (fig ->> 'unpriced') is not null then
    raise exception 'No milk price set for %.', fig ->> 'unpriced' using errcode = '22023';
  end if;
  update public.bills x set
    total_liters = (fig ->> 'liters')::numeric,
    total_amount = (fig ->> 'amount')::numeric,
    milk_price = case when jsonb_array_length(fig -> 'prices') = 1 then (fig -> 'prices' ->> 0)::numeric
                      when (fig ->> 'liters')::numeric > 0 then round((fig ->> 'amount')::numeric / (fig ->> 'liters')::numeric, 2)
                      else x.milk_price end,
    delivered_days = (fig ->> 'delivered_days')::int,
    missed_days = (fig ->> 'missed_days')::int,
    paused_days = (fig ->> 'paused_days')::int,
    discount_amount = least(x.discount_amount, (fig ->> 'amount')::numeric)
  where x.id = b.id;
  perform public.audit(b.farm_id, 'refresh_bill', 'bill', b.id::text,
    format('Bill %s for %s refreshed: %s now %s', b.bill_number, c.name, b.total_amount, fig ->> 'amount'));
end $$;

-- ---------------------------------------------------------------- the money picture

-- For the Payments screen and for checking the invariant.
create or replace function public.money_summary(date_from date default null, date_to date default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id(); r jsonb;
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to see money.' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'billed', coalesce(sum(v.net_amount), 0),
    'discounts', coalesce(sum(v.discount_amount), 0),
    'collected', coalesce(sum(v.collected), 0),
    'credit_applied', coalesce(sum(v.credit_applied), 0),
    'outstanding', coalesce(sum(v.balance_due), 0),
    'bills', count(*),
    'unpaid_bills', count(*) filter (where v.balance_due > 0))
  into r
  from public.bill_balances v
  where v.farm_id = f
    and (date_from is null or v.bill_date >= date_from) and (date_to is null or v.bill_date <= date_to);
  return r || jsonb_build_object(
    'credit_held', coalesce((select sum(k.held) from public.customer_credit k where k.farm_id = f), 0),
    'payments', coalesce((select sum(p.amount) from public.payments p where p.farm_id = f
                            and (date_from is null or p.payment_date >= date_from)
                            and (date_to is null or p.payment_date <= date_to)), 0));
end $$;

-- sum(payments) = collected + credit held + credit applied, for one farm.
create or replace function public.money_invariant_for(f uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with t as (
    select
      coalesce((select sum(p.amount) from public.payments p where p.farm_id = f), 0) as payments,
      coalesce((select sum(v.collected) from public.bill_balances v where v.farm_id = f), 0) as collected,
      coalesce((select sum(v.credit_applied) from public.bill_balances v where v.farm_id = f), 0) as applied,
      coalesce((select sum(k.held) from public.customer_credit k where k.farm_id = f), 0) as held
  )
  select jsonb_build_object('payments', payments, 'collected', collected, 'credit_applied', applied,
                            'credit_held', held, 'ok', payments = collected + applied + held)
  from t;
$$;

-- The same check for the signed-in person's farm, shown in Settings.
create or replace function public.money_invariant() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to see money.' using errcode = '42501';
  end if;
  return public.money_invariant_for(public.current_farm_id());
end $$;

-- Each customer's position: what they owe on bills, and the credit they hold.
create or replace function public.customer_balances() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to see money.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('customer_id', c.id, 'name', c.name, 'building', c.building, 'room', c.room,
      'phone', c.phone, 'status', c.status,
      'outstanding', coalesce(b.due, 0), 'unpaid_bills', coalesce(b.n, 0), 'credit', coalesce(k.held, 0),
      'price', cp.price_per_liter, 'last_payment', lp.payment_date)
      order by coalesce(b.due, 0) desc, c.name)
    from public.customers c
    left join (select v.customer_id, sum(v.balance_due) as due, count(*) filter (where v.balance_due > 0) as n
                 from public.bill_balances v where v.farm_id = f group by 1) b on b.customer_id = c.id
    left join public.customer_credit k on k.customer_id = c.id
    left join public.customer_prices cp on cp.customer_id = c.id
    left join lateral (select max(p.payment_date) as payment_date from public.payments p where p.customer_id = c.id) lp on true
    where c.farm_id = f), '[]'::jsonb);
end $$;

-- A first price for a new farm is the owner's to set; nothing is assumed.
