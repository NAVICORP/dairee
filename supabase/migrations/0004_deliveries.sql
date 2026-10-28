-- Dairee, stage 2 continued: the round as the screens see it, ticking it off,
-- closing a day, and the packing list.

-- Today's (or any day's) round: who is on it, how much each takes, and what
-- has happened at each door. Grouping and order are the app's job; the facts
-- are decided here.
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
    'stops', coalesce((
      select jsonb_agg(jsonb_build_object(
        'customer_id', c.id, 'name', c.name, 'phone', c.phone, 'building', c.building, 'room', c.room,
        'address', c.address, 'route_order', c.route_order, 'customer_type', c.customer_type,
        'delivery_staff_id', c.delivery_staff_id,
        'qty', coalesce(e.qty, 0), 'standing_qty', coalesce(e.standing_qty, 0),
        'vessels', coalesce(r.containers, e.containers, '[]'::jsonb),
        'paused', coalesce(e.paused, false), 'paused_by', e.paused_by, 'temporary', coalesce(e.temporary, false),
        'expected', e.customer_id is not null,
        'record_id', r.id, 'delivered', coalesce(r.delivered, false), 'delivered_at', r.delivered_at,
        'delivered_qty', r.milk_quantity, 'bottle_returned', coalesce(r.bottle_returned, false),
        'notes', r.notes, 'delivered_by', r.updated_by)
        order by coalesce(c.building, ''), c.route_order, c.room, c.name)
      from public.customers c
      left join public.expected_rounds(f, round.day, round.day) e
        on e.customer_id = c.id and e.slot = round.slot
      left join public.delivery_records r
        on r.customer_id = c.id and r.delivery_date = round.day and r.slot = round.slot
      where c.farm_id = f and (e.customer_id is not null or r.id is not null)
    ), '[]'::jsonb));
end $$;

-- Tick a door, or untick it. Delivery staff may work today's and
-- yesterday's rounds; the office may correct any day that is not closed.
create or replace function public.set_delivery(customer_id uuid, day date, slot text, delivered boolean,
  quantity numeric default null, notes text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.customers := public.customer_on_farm(set_delivery.customer_id);
  e record; rec public.delivery_records%rowtype; today date := public.farm_today(c.farm_id);
begin
  if not public.can_deliver() then
    raise exception 'You are not on the delivery team.' using errcode = '42501';
  end if;
  if slot not in ('morning', 'evening') then raise exception 'Pick a round.' using errcode = '22023'; end if;
  if public.day_locked(c.farm_id, day) then
    raise exception 'That day is closed. Ask the office to open it.' using errcode = '22023';
  end if;
  if day > today then raise exception 'That round has not happened yet.' using errcode = '22023'; end if;
  -- A billed day stays as billed, so the bill and the round never disagree.
  if exists (select 1 from public.bills b where b.customer_id = c.id and day between b.period_from and b.period_to) then
    raise exception 'That day is on a bill already. To correct it, delete the bill, make the change and make the bill again.'
      using errcode = '22023';
  end if;
  if not public.staff_can('deliveries') and day < today - 1 then
    raise exception 'Ask the office to correct older rounds.' using errcode = '42501';
  end if;
  if quantity is not null and quantity < 0 then raise exception 'A quantity cannot be negative.' using errcode = '22023'; end if;
  select * into e from public.expected_rounds(c.farm_id, day, day, c.id) x where x.slot = set_delivery.slot;
  insert into public.delivery_records as d (farm_id, customer_id, delivery_date, slot, delivered, delivered_at,
         milk_quantity, containers, delivery_staff_id, notes, updated_at, updated_by)
  values (c.farm_id, c.id, day, slot, delivered, case when delivered then now() end,
          case when delivered then coalesce(quantity, e.qty, 0) end,
          case when delivered then coalesce(e.containers, '[]'::jsonb) end,
          public.my_staff_id(), nullif(btrim(coalesce(notes, '')), ''), now(), public.my_name())
  on conflict on constraint delivery_records_customer_id_delivery_date_slot_key do update set
    delivered = excluded.delivered,
    delivered_at = case when excluded.delivered then coalesce(d.delivered_at, now()) end,
    milk_quantity = case when excluded.delivered then coalesce(quantity, d.milk_quantity, excluded.milk_quantity) end,
    containers = case when excluded.delivered then coalesce(d.containers, excluded.containers) end,
    delivery_staff_id = excluded.delivery_staff_id,
    notes = coalesce(excluded.notes, d.notes),
    updated_at = now(), updated_by = excluded.updated_by
  returning * into rec;
  perform public.audit(c.farm_id, case when delivered then 'mark_delivered' else 'unmark_delivered' end,
    'delivery', rec.id::text,
    format('%s %s for %s, %s', c.name, case when delivered then 'marked delivered' else 'marked not delivered' end,
           day, public.slot_words(slot)));
  return to_jsonb(rec);
end $$;

create or replace function public.set_note(customer_id uuid, day date, slot text, notes text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(set_note.customer_id);
begin
  if not public.can_deliver() then raise exception 'You are not on the delivery team.' using errcode = '42501'; end if;
  if public.day_locked(c.farm_id, day) then raise exception 'That day is closed.' using errcode = '22023'; end if;
  insert into public.delivery_records as d (farm_id, customer_id, delivery_date, slot, notes, delivery_staff_id, updated_by)
  values (c.farm_id, c.id, day, slot, nullif(btrim(coalesce(notes, '')), ''), public.my_staff_id(), public.my_name())
  on conflict on constraint delivery_records_customer_id_delivery_date_slot_key do update set notes = excluded.notes, updated_at = now(), updated_by = excluded.updated_by;
end $$;

create or replace function public.set_bottle_returned(customer_id uuid, day date, slot text, returned boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(set_bottle_returned.customer_id); n int;
begin
  if not public.can_deliver() then raise exception 'You are not on the delivery team.' using errcode = '42501'; end if;
  if public.day_locked(c.farm_id, day) then raise exception 'That day is closed.' using errcode = '22023'; end if;
  update public.delivery_records d set bottle_returned = returned, returned_at = case when returned then now() end,
         updated_at = now(), updated_by = public.my_name()
   where d.customer_id = c.id and d.delivery_date = day and d.slot = set_bottle_returned.slot and d.delivered;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Mark the delivery first.' using errcode = '22023'; end if;
  perform public.audit(c.farm_id, 'bottle_returned', 'customer', c.id::text,
    format('%s bottles %s for %s, %s', c.name, case when returned then 'collected' else 'not collected' end, day, public.slot_words(slot)));
end $$;

create or replace function public.lock_day(day date, locked boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if not public.staff_can('deliveries') then
    raise exception 'You need the Deliveries page to close a day.' using errcode = '42501';
  end if;
  insert into public.daily_delivery_locks (farm_id, lock_date, is_locked, locked_at, locked_by, unlocked_at)
  values (f, day, locked, case when locked then now() end, public.my_name(), case when not locked then now() end)
  on conflict on constraint daily_delivery_locks_farm_id_lock_date_key do update set is_locked = excluded.is_locked,
    locked_at = case when excluded.is_locked then now() else public.daily_delivery_locks.locked_at end,
    unlocked_at = case when excluded.is_locked then public.daily_delivery_locks.unlocked_at else now() end,
    locked_by = excluded.locked_by;
  perform public.audit(f, case when locked then 'lock_day' else 'unlock_day' end, 'day', day::text,
    format('%s %s', day, case when locked then 'closed' else 'opened again' end));
end $$;

-- What to pack for a day: vessels per round and per building, and the litres
-- no vessel covers (a customer with a quantity but no vessels), so nobody has
-- to wonder why milk sits in an "unassigned" line.
create or replace function public.preparation(day date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id(); slots jsonb := '{}'; s text;
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  foreach s in array array['morning', 'evening'] loop
    slots := slots || jsonb_build_object(s, (
      with e as (
        select x.*, coalesce(c.building, '') as building, c.name
        from public.expected_rounds(f, preparation.day, preparation.day) x
        join public.customers c on c.id = x.customer_id
        where x.slot = s
      ), live as (
        select * from e where not e.paused and e.qty > 0
      ), v as (
        select live.building, j ->> 'name' as name, j ->> 'category' as category,
               (j ->> 'capacity_ml')::int as cap, (j ->> 'quantity')::int as n
        from live cross join lateral jsonb_array_elements(live.containers) j
      ), cover as (
        select live.customer_id, live.name, live.building, live.qty,
               coalesce((select sum((j ->> 'capacity_ml')::numeric * (j ->> 'quantity')::int) / 1000
                           from jsonb_array_elements(live.containers) j), 0) as covered
        from live
      )
      select jsonb_build_object(
        'litres', coalesce((select sum(qty) from live), 0),
        'customers', (select count(*) from live),
        'paused', (select count(*) from e where e.paused),
        'temporary', (select count(*) from e where e.temporary),
        'vessels', coalesce((
          select jsonb_agg(jsonb_build_object('name', t.name, 'category', t.category, 'capacity_ml', t.cap, 'count', t.n)
                           order by t.cap, t.name)
          from (select v.name, v.category, v.cap, sum(v.n) as n from v group by 1, 2, 3) t), '[]'::jsonb),
        'buildings', coalesce((
          select jsonb_agg(jsonb_build_object('building', b.building, 'litres', b.l, 'customers', b.c,
            'vessels', coalesce((
              select jsonb_agg(jsonb_build_object('name', t.name, 'capacity_ml', t.cap, 'count', t.n) order by t.cap, t.name)
              from (select v.name, v.cap, sum(v.n) as n from v where v.building = b.building group by 1, 2) t), '[]'::jsonb))
            order by b.building)
          from (select live.building, sum(live.qty) as l, count(*) as c from live group by 1) b), '[]'::jsonb),
        'unassigned', coalesce((
          select jsonb_agg(jsonb_build_object('customer_id', cover.customer_id, 'name', cover.name,
                                              'building', cover.building, 'litres', cover.qty - cover.covered)
                           order by cover.building, cover.name)
          from cover where cover.qty - cover.covered > 0.0005), '[]'::jsonb),
        'unassigned_litres', coalesce((select sum(greatest(0, cover.qty - cover.covered)) from cover), 0))
    ));
  end loop;
  return jsonb_build_object('day', day, 'slots', slots);
end $$;

-- The wall board and the top of the Deliveries screen: how far the rounds have got.
create or replace function public.day_summary(day date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  return jsonb_build_object('day', day, 'today', public.farm_today(f), 'locked', public.day_locked(f, day), 'slots', (
    select jsonb_object_agg(t.slot, t.o) from (
      select s.slot, jsonb_build_object(
        'stops', count(e.customer_id) filter (where not e.paused and e.qty > 0),
        'delivered', count(e.customer_id) filter (where not e.paused and e.qty > 0 and r.delivered),
        'litres', coalesce(sum(e.qty) filter (where not e.paused), 0),
        'litres_delivered', coalesce(sum(r.milk_quantity) filter (where r.delivered), 0),
        'paused', count(e.customer_id) filter (where e.paused),
        'bottles_out', count(r.id) filter (where r.delivered and not r.bottle_returned
                                             and exists (select 1 from jsonb_array_elements(coalesce(r.containers, '[]')) j
                                                          where j ->> 'category' = 'bottle'))) as o
      from (select unnest(array['morning', 'evening']) as slot) s
      left join public.expected_rounds(f, day_summary.day, day_summary.day) e on e.slot = s.slot
      left join public.delivery_records r
        on r.customer_id = e.customer_id and r.delivery_date = day_summary.day and r.slot = s.slot
      group by s.slot
    ) t));
end $$;
