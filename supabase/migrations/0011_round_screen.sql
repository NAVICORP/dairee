-- Dairee: the round as the delivery screen shows it, the way Mazra's did.
-- Each stop also carries who takes it, when it was delivered and the bottles
-- still out from earlier rounds (with the days they went), and the round
-- carries the delivery team for the filter.

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
      -- Bottles that went out on an earlier round (up to two months back)
      -- and have not been marked back: how many, and on which rounds.
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

-- The sample farms were made with a bottle left out on one round in four,
-- for two months, so every bottle customer looked weeks behind. A real round
-- gets its bottles back the next day or so: only the last three days keep
-- any out. (Sample Dairy, the reviewers' farm; the demo farm is made fresh
-- in tools/demo.sql the same way.)
update public.delivery_records d
   set bottle_returned = true, returned_at = d.delivered_at + interval '1 day'
 where d.farm_id in (select id from public.farms where created_by = 'a5a5a5a5-0000-4000-8000-00000000d001')
   and d.delivered and not d.bottle_returned
   and d.delivery_date < public.farm_today(d.farm_id) - 3;
