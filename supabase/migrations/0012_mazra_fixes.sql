-- Dairee: bugs already found and fixed in Mazra, its predecessor, closed here
-- before they reach a real farm. Each part names the Mazra fix it follows.

-- ---------------------------------------------------------------- 1. a ceiling on the litres
--
-- Mazra: five mornings stood at 750 litres against a standing order of 0.75.
-- A decimal point was lost and nothing objected, because 750 is a number.
-- No single delivery, standing order or one-day change is ever this big.
-- NOT VALID: rows already saved stay as they are; new and edited rows are
-- checked. The app reads an entry back before it gets anywhere near this.

alter table public.delivery_records
  add constraint delivery_records_litres_sane check (milk_quantity is null or milk_quantity <= 200) not valid;
alter table public.temporary_deliveries
  add constraint temporary_deliveries_litres_sane check (quantity <= 200) not valid;
alter table public.customers
  add constraint customers_litres_sane check (
    case when delivery_slot = 'both' then morning_quantity <= 200 and evening_quantity <= 200
         else milk_quantity <= 200 end) not valid;

-- ---------------------------------------------------------------- 2. a customer starts on the farm's today
--
-- Mazra: dates were taken from the server's clock, which runs in UTC, so
-- between midnight and half past five in India "today" was still yesterday.
-- A new customer's first day is the farm's today, not the server's.

alter table public.customers alter column start_date drop default;

create or replace function public.customers_start_date() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.start_date is null then
    new.start_date := public.farm_today(new.farm_id);
  end if;
  return new;
end $$;
create trigger customers_start_date before insert on public.customers
  for each row execute function public.customers_start_date();

-- ---------------------------------------------------------------- 3. a bill never runs past today
--
-- Mazra: a month picked while it was still running gave a bill for days
-- nobody had milked through, and every day still to come was counted as a
-- missed delivery on a bill the customer reads. The period now ends today at
-- the latest, and a day still to come is never a missed one.

create or replace function public.bill_figures(c public.customers, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb; own numeric; today date := public.farm_today(c.farm_id);
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
    from public.expected_rounds(c.farm_id, p_from, least(p_to, today), c.id) e
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
  -- Days still to come are not billed: the period stops at today.
  pt := least(pt, public.farm_today(f));
  if pt < pf then
    raise exception 'That period has not started yet. Bills are for days that have passed.' using errcode = '22023';
  end if;
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
  return jsonb_build_object('made', jsonb_array_length(made), 'bill_ids', made, 'skipped', skipped,
                            'period_from', pf, 'period_to', pt);
end $$;

-- A report stops at today too: a range typed a week ahead drew a row of
-- blanks for every day that had not happened.
create or replace function public.report_days(date_from date, date_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  if date_to - date_from > 400 then raise exception 'Pick up to about a year.' using errcode = '22023'; end if;
  date_to := least(date_to, public.farm_today(f));
  return coalesce((
    select jsonb_agg(jsonb_build_object('day', d::date,
      'morning', coalesce((select sum(r.milk_quantity) from public.delivery_records r
                            where r.farm_id = f and r.delivery_date = d::date and r.slot = 'morning' and r.delivered), 0),
      'evening', coalesce((select sum(r.milk_quantity) from public.delivery_records r
                            where r.farm_id = f and r.delivery_date = d::date and r.slot = 'evening' and r.delivered), 0),
      'stops', (select count(*) from public.delivery_records r
                 where r.farm_id = f and r.delivery_date = d::date and r.delivered),
      'produced', coalesce((select sum(y.litres) from public.milk_yield y where y.farm_id = f and y.yield_date = d::date), 0))
      order by d)
    from generate_series(date_from, date_to, interval '1 day') d), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- 4. a bottle from a closed day can still come back
--
-- Mazra: a bottle still out could not be collected, so it stayed on the list
-- for good. Here a closed day refused it: once the office closes its days,
-- no earlier bottle could ever be marked back. The bottle comes back today,
-- so an earlier round's bottle may be marked back even when its day is
-- closed. Undoing it, and anything on a closed today, still needs the day open.

create or replace function public.set_bottle_returned(customer_id uuid, day date, slot text, returned boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(set_bottle_returned.customer_id); n int;
begin
  if not public.can_deliver() then raise exception 'You are not on the delivery team.' using errcode = '42501'; end if;
  if public.day_locked(c.farm_id, day) and not (returned and day < public.farm_today(c.farm_id)) then
    raise exception 'That day is closed.' using errcode = '22023';
  end if;
  update public.delivery_records d set bottle_returned = returned, returned_at = case when returned then now() end,
         updated_at = now(), updated_by = public.my_name()
   where d.customer_id = c.id and d.delivery_date = day and d.slot = set_bottle_returned.slot and d.delivered;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Mark the delivery first.' using errcode = '22023'; end if;
  perform public.audit(c.farm_id, 'bottle_returned', 'customer', c.id::text,
    format('%s bottles %s for %s, %s', c.name, case when returned then 'collected' else 'not collected' end, day, public.slot_words(slot)));
end $$;

-- ---------------------------------------------------------------- 5. the round says which rounds a house is on
--
-- Mazra: the "behind on bottles" flag started at two bottles out, which is the
-- normal state of a house on both rounds, so those houses were flagged every
-- single morning. The app needs the house's rounds to set the bar one above.

create or replace function public.round(day date, slot text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  if slot not in ('morning', 'evening') then raise exception 'Pick a round.' using errcode = '22023'; end if;
  return jsonb_build_object(
    'day', day, 'slot', slot,
    'locked', public.day_locked(f, day),
    'today', public.farm_today(f),
    'staff', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name)
      from public.staff s where s.farm_id = f and s.active and s.can_deliver
    ), '[]'::jsonb),
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
        'customer_id', c.id, 'name', c.name, 'phone', c.phone, 'building', c.building, 'room', c.room,
        'address', c.address, 'route_order', c.route_order, 'customer_type', c.customer_type,
        'delivery_slot', c.delivery_slot,
        'delivery_staff_id', c.delivery_staff_id, 'staff_name', st.name,
        'qty', coalesce(e.qty, 0), 'standing_qty', coalesce(e.standing_qty, 0),
        'vessels', coalesce(r.containers, e.containers, '[]'::jsonb),
        'paused', coalesce(e.paused, false), 'paused_by', e.paused_by, 'temporary', coalesce(e.temporary, false),
        'expected', e.customer_id is not null,
        'record_id', r.id, 'delivered', coalesce(r.delivered, false), 'delivered_at', r.delivered_at,
        'delivered_qty', r.milk_quantity, 'bottle_returned', coalesce(r.bottle_returned, false),
        'notes', r.notes, 'delivered_by', r.updated_by,
        'bottles_out', coalesce(b.bottles, 0), 'bottle_days', coalesce(b.days, '[]'::jsonb))
        order by coalesce(c.building, ''), c.route_order, c.room, c.name)
      from public.customers c
      left join public.staff st on st.id = c.delivery_staff_id
      left join public.expected_rounds(f, round.day, round.day) e
        on e.customer_id = c.id and e.slot = round.slot
      left join public.delivery_records r
        on r.customer_id = c.id and r.delivery_date = round.day and r.slot = round.slot
      left join lateral (
        select sum(x.n)::int as bottles,
               jsonb_agg(jsonb_build_object('day', x.delivery_date, 'slot', x.slot, 'bottles', x.n)
                         order by x.delivery_date, x.slot = 'evening') as days
        from (
          select d.delivery_date, d.slot,
                 (select coalesce(sum(greatest(coalesce((v ->> 'quantity')::int, 1), 0)), 0)
                    from jsonb_array_elements(coalesce(d.containers, '[]'::jsonb)) v
                   where v ->> 'category' = 'bottle') as n
          from public.delivery_records d
          where d.customer_id = c.id and d.delivered and not d.bottle_returned
            and d.delivery_date >= round.day - 60
            and (d.delivery_date < round.day
                 or (d.delivery_date = round.day and d.slot = 'morning' and round.slot = 'evening'))
        ) x
        where x.n > 0
      ) b on true
      where c.farm_id = f and (e.customer_id is not null or r.id is not null)
    ), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- 6. a pause asks about the customer's own round
--
-- Mazra: pausing was checked against a switch for the whole farm, so a
-- morning customer could not pause while the evening milk was being packed.
-- A pause for "both rounds" now asks only about the rounds this customer is
-- on, and a closed round is named correctly.

-- The rounds a portal change touches for this customer.
create or replace function public.portal_slot_for(c public.customers, p_slot text) returns text
language sql immutable set search_path = '' as $$
  select case
    when coalesce(nullif(p_slot, ''), 'both') <> 'both' then p_slot
    when c.delivery_slot in ('morning', 'evening') then c.delivery_slot
    else 'both'
  end;
$$;

create or replace function public.portal_check_open(f uuid, d date, p_slot text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare w record;
begin
  if p_slot = 'both' then
    perform public.portal_check_open(f, d, 'morning');
    perform public.portal_check_open(f, d, 'evening');
    return;
  end if;
  if public.round_open(f, d, p_slot) then return; end if;
  if d < public.farm_today(f) then raise exception 'That day has passed.' using errcode = '22023'; end if;
  if public.day_locked(f, d) then raise exception 'That day is closed. Please call the farm.' using errcode = '22023'; end if;
  select * into w from public.round_window(f, p_slot) w;
  if d = public.farm_today(f) then
    raise exception 'Today''s % milk is already being packed. Please call the farm.', p_slot using errcode = '22023';
  end if;
  raise exception 'Changes are closed while the % milk is packed, until %. Please try again then.',
    p_slot, to_char(w.ends, 'HH24:MI') using errcode = '22023';
end $$;

create or replace function public.portal_pause(token text, kind text, from_date date default null, to_date date default null,
  slot text default 'both', dates date[] default null, reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); today date; d date; own text;
begin
  perform public.portal_must_change(c);
  if not (select f.customer_pause from public.farms f where f.id = c.farm_id) then
    raise exception 'Please call the farm to pause your milk.' using errcode = '42501';
  end if;
  today := public.farm_today(c.farm_id);
  own := public.portal_slot_for(c, slot);
  if kind = 'dates' then
    foreach d in array coalesce(dates, '{}') loop perform public.portal_check_open(c.farm_id, d, own); end loop;
  else
    perform public.portal_check_open(c.farm_id,
      case kind when 'today_only' then today when 'tomorrow_only' then today + 1 else from_date end, own);
  end if;
  perform public.add_pause(c, kind, from_date, to_date, slot, reason, dates, 'customer', c.name);
  perform public.audit(c.farm_id, 'portal_pause', 'customer', c.id::text,
    format('%s paused their own milk (%s, %s)', c.name, replace(kind, '_', ' '), public.slot_words(coalesce(slot, 'both'))));
  return public.portal_changes(c);
end $$;

-- Resuming is held to the same rule: milk restarting while the van is
-- loaded is the same surprise the other way round.
create or replace function public.portal_resume(token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); today date; d date; own text;
begin
  perform public.portal_must_change(c);
  today := public.farm_today(c.farm_id);
  own := public.portal_slot_for(c, 'both');
  d := case when public.round_open(c.farm_id, today, own) then today else today + 1 end;
  perform public.portal_check_open(c.farm_id, d, own);
  perform public.end_pauses(c, d);
  perform public.audit(c.farm_id, 'portal_resume', 'customer', c.id::text, format('%s resumed their milk from %s', c.name, d));
  return public.portal_changes(c);
end $$;

create or replace function public.portal_remove_pause(token text, pause_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); p record;
begin
  perform public.portal_must_change(c);
  select x.id, x.from_date as day, x.slot, false as single into p from public.customer_pauses x
   where x.id = pause_id and x.customer_id = c.id;
  if not found then
    select x.id, x.pause_date as day, x.slot, true as single into p from public.customer_pause_dates x
     where x.id = pause_id and x.customer_id = c.id;
  end if;
  if p.id is null then raise exception 'That pause was already removed.' using errcode = 'P0002'; end if;
  if p.day <= public.farm_today(c.farm_id) and not p.single then
    -- Already running: end it from the next open day instead.
    perform public.portal_resume(token);
    return public.portal_changes(c);
  end if;
  perform public.portal_check_open(c.farm_id, p.day, public.portal_slot_for(c, p.slot));
  delete from public.customer_pauses x where x.id = p.id;
  delete from public.customer_pause_dates x where x.id = p.id;
  perform public.audit(c.farm_id, 'portal_remove_pause', 'customer', c.id::text, format('%s removed a pause for %s', c.name, p.day));
  return public.portal_changes(c);
end $$;

-- ---------------------------------------------------------------- 7. taking a request back is a change too
--
-- Mazra: taking today's request back after the van is loaded is the same
-- surprise as making it, so it is held to the same clock. Any later day may
-- be taken back whenever the customer likes.

create or replace function public.portal_withdraw_request(token text, request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); r public.temporary_requests%rowtype;
begin
  perform public.portal_must_change(c);
  select * into r from public.temporary_requests x
   where x.id = request_id and x.customer_id = c.id and x.status = 'pending' for update;
  if not found then raise exception 'That request was already answered.' using errcode = '22023'; end if;
  if r.delivery_date <= public.farm_today(c.farm_id) then
    perform public.portal_check_open(c.farm_id, r.delivery_date, r.slot);
  end if;
  update public.temporary_requests x set status = 'withdrawn' where x.id = r.id;
  return public.portal_changes(c);
end $$;

-- ---------------------------------------------------------------- who may call what

revoke execute on function public.customers_start_date(), public.portal_slot_for(public.customers, text)
  from public, anon, authenticated;
