-- A demo farm, for the screen pictures (tools/record_screens.py) and for
-- trying the app on a scratch server. Dates are relative to the farm's today.
-- Run on a database that has platform.sql and every migration, as postgres.
\set ON_ERROR_STOP on

create or replace function pg_temp.as_user(sub text, phone text, email text, farm uuid default null) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', sub, 'role', 'authenticated', 'phone', phone, 'email', email)::text, false);
  perform set_config('request.headers', json_build_object('x-farm-id', farm)::text, false);
  execute 'set role authenticated';
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- Asha starts the farm.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select public.create_farm('Green Meadows Dairy', 'Asia/Kolkata', 'INR', 'Asha Thomas');
reset role;
select set_config('demo.farm', (select id::text from public.farms where slug = 'green-meadows-dairy'), false);
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com', current_setting('demo.farm')::uuid);

insert into public.staff (name, phone, can_deliver, position) values
  ('Dev Kumar', '919800000001', true, 'Delivery'),
  ('Biju Joseph', '919800000002', true, 'Delivery');
insert into public.staff (name, email, permissions, position) values
  ('Omana Varghese', 'omana@example.com', '{customers,pauses,deliveries,preparation}', 'Office');
insert into public.staff (name, phone, can_care, position) values
  ('Rahul Menon', '919800000004', true, 'Cow care');

insert into public.milk_prices (price_per_liter, effective_from, notes)
values (62, public.farm_today(current_setting('demo.farm')::uuid) - 120, 'Price from the start');

-- Customers: three apartment buildings and a few houses.
do $$
declare
  f uuid := current_setting('demo.farm')::uuid;
  today date := public.farm_today(f);
  dev uuid := (select id from public.staff where name = 'Dev Kumar');
  biju uuid := (select id from public.staff where name = 'Biju Joseph');
  half uuid := (select id from public.containers where capacity_ml = 500);
  one uuid := (select id from public.containers where capacity_ml = 1000);
  two uuid := (select id from public.containers where capacity_ml = 2000);
  r record; c uuid; i int := 0;
begin
  for r in select * from (values
    ('Anitha Nair',      'Palm Grove',   'A 101', 'morning', 1.0, null::numeric, null::numeric),
    ('Rajesh Pillai',    'Palm Grove',   'A 204', 'morning', 1.5, null, null),
    ('Fathima Rasheed',  'Palm Grove',   'B 302', 'both',    0,   1.0, 0.5),
    ('Suresh Babu',      'Palm Grove',   'B 405', 'morning', 2.0, null, null),
    ('Meera Krishnan',   'Palm Grove',   'C 110', 'evening', 1.0, null, null),
    ('Thomas Mathew',    'Lake View',    '3B',    'morning', 1.0, null, null),
    ('Lakshmi Iyer',     'Lake View',    '5A',    'both',    0,   1.0, 1.0),
    ('Abdul Kareem',     'Lake View',    '7C',    'morning', 0.5, null, null),
    ('Divya Menon',      'Lake View',    '9D',    'morning', 1.5, null, null),
    ('George Kurian',    'Lake View',    '11A',   'evening', 2.0, null, null),
    ('Priya Suresh',     'Harbour Heights', '1204', 'morning', 1.0, null, null),
    ('Vinod Kumar',      'Harbour Heights', '1501', 'morning', 1.0, null, null),
    ('Shabna Ashraf',    'Harbour Heights', '1702', 'both',   0,   0.5, 0.5),
    ('Jacob Varghese',   'Harbour Heights', '2003', 'morning', 2.0, null, null),
    ('Remya Rajan',      'Harbour Heights', '2205', 'evening', 1.0, null, null),
    ('Sreedharan K',     null,           null,    'morning', 3.0, null, null),
    ('Hotel Malabar',    null,           null,    'both',    0,   8.0, 6.0),
    ('Mini Joseph',      null,           null,    'morning', 1.0, null, null)
  ) as v(name, building, room, slot, qty, mq, eq) loop
    i := i + 1;
    insert into public.customers (name, phone, building, room, address, route_order, delivery_slot, milk_quantity,
                                  morning_quantity, evening_quantity, delivery_staff_id, start_date, customer_type)
    values (r.name, '9198470' || lpad((10000 + i * 37)::text, 5, '0'), r.building, r.room,
            case when r.building is null then 'Near the temple road, house ' || (10 + i) end,
            i, r.slot, r.qty, r.mq, r.eq,
            case when r.building in ('Palm Grove', 'Lake View') or r.building is null and i % 2 = 0 then dev else biju end,
            today - 75, case when r.name like 'Hotel%' then 'business' else 'home' end)
    returning id into c;
    perform public.save_customer_vessels(c, case
      when r.name like 'Hotel%' then jsonb_build_array(
        jsonb_build_object('container_id', two, 'quantity', 4, 'slot', 'morning'),
        jsonb_build_object('container_id', two, 'quantity', 3, 'slot', 'evening'))
      when r.slot = 'both' then jsonb_build_array(
        jsonb_build_object('container_id', case when r.mq >= 1 then one else half end, 'quantity', greatest(1, r.mq::int), 'slot', 'morning'),
        jsonb_build_object('container_id', case when r.eq >= 1 then one else half end, 'quantity', greatest(1, r.eq::int), 'slot', 'evening'))
      when r.qty = 0.5 then jsonb_build_array(jsonb_build_object('container_id', half, 'quantity', 1, 'slot', r.slot))
      when r.qty = 1.5 then jsonb_build_array(
        jsonb_build_object('container_id', one, 'quantity', 1, 'slot', r.slot),
        jsonb_build_object('container_id', half, 'quantity', 1, 'slot', r.slot))
      when r.qty >= 3 then jsonb_build_array(jsonb_build_object('container_id', one, 'quantity', r.qty::int, 'slot', r.slot))
      else jsonb_build_array(jsonb_build_object('container_id', case when r.qty >= 2 then two else one end, 'quantity', 1, 'slot', r.slot))
    end);
  end loop;
  perform public.set_customer_price((select id from public.customers where name = 'Hotel Malabar'), 58);
end $$;

-- A pause, a holiday next week, a stopped customer and a temporary extra.
do $$
declare f uuid := current_setting('demo.farm')::uuid; today date := public.farm_today(f);
begin
  perform public.pause_customer((select id from public.customers where name = 'Divya Menon'), 'custom_range', today, today + 3, 'both', 'Away visiting family');
  perform public.pause_customer((select id from public.customers where name = 'Thomas Mathew'), 'custom_range', today + 6, today + 9, 'both', 'Holiday');
  perform public.set_temporary((select id from public.customers where name = 'Anitha Nair'), today, 'morning', 2, '[]', 'Guests at home');
  perform public.set_temporary((select id from public.customers where name = 'Suresh Babu'), today + 1, 'morning', 3, '[]', null);
end $$;

reset role;

-- Past rounds, as they would have been ticked: nearly every stop delivered,
-- a few missed. Written directly, so the audit log stays about today.
insert into public.delivery_records (farm_id, customer_id, delivery_date, slot, delivered, delivered_at, milk_quantity,
                                     containers, delivery_staff_id, updated_by, bottle_returned)
select current_setting('demo.farm')::uuid, e.customer_id, e.day, e.slot,
       (abs(hashtext(e.customer_id::text || e.day)) % 23) <> 0,
       (e.day + case when e.slot = 'morning' then time '06:10' else time '17:20' end)::timestamp at time zone 'Asia/Kolkata'
         + make_interval(mins => abs(hashtext(e.customer_id::text || e.day || e.slot)) % 50),
       case when (abs(hashtext(e.customer_id::text || e.day)) % 23) <> 0 then e.qty end,
       case when (abs(hashtext(e.customer_id::text || e.day)) % 23) <> 0 then e.containers end,
       c.delivery_staff_id, (select name from public.staff s where s.id = c.delivery_staff_id),
       -- Bottles come back the next round or so: only the last three days keep any out.
       e.day < public.farm_today(current_setting('demo.farm')::uuid) - 3 or (abs(hashtext(e.customer_id::text || e.day)) % 4) <> 0
from public.expected_rounds(current_setting('demo.farm')::uuid,
       public.farm_today(current_setting('demo.farm')::uuid) - 70, public.farm_today(current_setting('demo.farm')::uuid) - 1) e
join public.customers c on c.id = e.customer_id
where not e.paused and e.qty > 0;

-- Today: Dev is part way through the morning round.
select pg_temp.as_user('d3333333-3333-3333-3333-333333333333', '919800000001', null, current_setting('demo.farm')::uuid);
select public.whoami();
select public.set_delivery(e.customer_id, e.day, 'morning', true)
from public.expected_rounds(current_setting('demo.farm')::uuid, public.farm_today(current_setting('demo.farm')::uuid),
                            public.farm_today(current_setting('demo.farm')::uuid)) e
join public.customers c on c.id = e.customer_id
where e.slot = 'morning' and not e.paused and e.qty > 0 and c.building = 'Palm Grove';
select public.set_note((select id from public.customers where name = 'Rajesh Pillai'), public.farm_today(current_setting('demo.farm')::uuid),
                       'morning', 'Left with the security');
reset role;

-- Bills for last month, and some payments.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com', current_setting('demo.farm')::uuid);
do $$
declare f uuid := current_setting('demo.farm')::uuid; today date := public.farm_today(f);
  first_this date := date_trunc('month', today)::date;
  first_last date := (date_trunc('month', today) - interval '1 month')::date;
  b record; n int := 0;
begin
  perform public.generate_bills(first_last, first_this - 1, null, first_this);
  for b in select * from public.bill_balances order by bill_number loop
    n := n + 1;
    if n % 3 <> 0 then
      insert into public.payments (customer_id, amount, payment_date, payment_method, bill_id, recorded_by)
      values (b.customer_id, b.net_amount, least(today, first_this + (n % 6)), case when n % 2 = 0 then 'upi' else 'cash' end, b.bill_id, 'Asha Thomas');
    elsif n % 6 = 0 then
      insert into public.payments (customer_id, amount, payment_date, payment_method, bill_id, recorded_by)
      values (b.customer_id, round(b.net_amount / 2), least(today, first_this + 3), 'upi', b.bill_id, 'Asha Thomas');
    end if;
  end loop;
  insert into public.payments (customer_id, amount, payment_date, payment_method, counts_as_credit, notes, recorded_by)
  values ((select id from public.customers where name = 'Jacob Varghese'), 500, today - 1, 'cash', true, 'Paid ahead', 'Asha Thomas');
end $$;

-- The herd.
insert into public.cows (tag_number, name, breed, status, date_of_birth, location, lactation_number, last_calving_date,
                         pregnancy_status, last_ai_date)
select v.* from (values
  ('GM-01', 'Lakshmi', 'Holstein Friesian', 'milking', public.farm_today(current_setting('demo.farm')::uuid) - 2100, 'Shed 1', 3, public.farm_today(current_setting('demo.farm')::uuid) - 95, 'inseminated', public.farm_today(current_setting('demo.farm')::uuid) - 20),
  ('GM-02', 'Ganga',   'Jersey',            'milking', public.farm_today(current_setting('demo.farm')::uuid) - 1800, 'Shed 1', 2, public.farm_today(current_setting('demo.farm')::uuid) - 140, 'pregnant', public.farm_today(current_setting('demo.farm')::uuid) - 70),
  ('GM-03', 'Kaveri',  'Sahiwal',           'milking', public.farm_today(current_setting('demo.farm')::uuid) - 1500, 'Shed 1', 1, public.farm_today(current_setting('demo.farm')::uuid) - 60, 'open', null::date),
  ('GM-04', 'Nandini', 'Gir',               'milking', public.farm_today(current_setting('demo.farm')::uuid) - 2400, 'Shed 2', 4, public.farm_today(current_setting('demo.farm')::uuid) - 200, 'pregnant', public.farm_today(current_setting('demo.farm')::uuid) - 110),
  ('GM-05', 'Yamuna',  'Holstein Friesian', 'dry',     public.farm_today(current_setting('demo.farm')::uuid) - 2700, 'Shed 2', 5, public.farm_today(current_setting('demo.farm')::uuid) - 330, 'pregnant', public.farm_today(current_setting('demo.farm')::uuid) - 240),
  ('GM-06', 'Sita',    'Jersey',            'milking', public.farm_today(current_setting('demo.farm')::uuid) - 1300, 'Shed 2', 1, public.farm_today(current_setting('demo.farm')::uuid) - 40, 'open', null),
  ('GM-07', 'Malli',   'Vechur',            'heifer',  public.farm_today(current_setting('demo.farm')::uuid) - 600,  'Paddock', null, null, 'unknown', null),
  ('GM-08', null,      'Jersey',            'calf',    public.farm_today(current_setting('demo.farm')::uuid) - 90,   'Calf pen', null, null, 'unknown', null)
) v;
insert into public.milk_yield (cow_id, yield_date, slot, litres, recorded_by)
select c.id, d::date, s.slot,
       round((case c.breed when 'Holstein Friesian' then 9 when 'Jersey' then 6.5 when 'Gir' then 5.5 else 5 end
              + (abs(hashtext(c.id::text || d::date || s.slot)) % 15) / 10.0 - 0.7)
             * case when s.slot = 'evening' then 0.85 else 1 end, 1),
       'Rahul Menon'
from public.cows c
cross join generate_series(public.farm_today(current_setting('demo.farm')::uuid) - 27, public.farm_today(current_setting('demo.farm')::uuid) - 1, interval '1 day') d
cross join (values ('morning'), ('evening')) s(slot)
where c.status = 'milking';
insert into public.cow_health_logs (cow_id, observed_on, signs, severity, temperature_c, treatment, resolved_on, recorded_by)
select id, public.farm_today(current_setting('demo.farm')::uuid) - 12, '{fever,off feed}', 'mild', 39.8,
       'Medicine for two days', public.farm_today(current_setting('demo.farm')::uuid) - 9, 'Rahul Menon'
from public.cows where tag_number = 'GM-03';
insert into public.cow_breeding_events (cow_id, kind, event_date, bull, technician)
select id, 'ai', public.farm_today(current_setting('demo.farm')::uuid) - 20, 'HF 4417', 'Veterinary centre'
from public.cows where tag_number = 'GM-01';
insert into public.cow_vaccinations (cow_id, vaccine, given_on, next_due_on, given_by)
select id, 'Foot and mouth', public.farm_today(current_setting('demo.farm')::uuid) - 150,
       public.farm_today(current_setting('demo.farm')::uuid) + 30, 'Veterinary centre'
from public.cows where status in ('milking', 'dry');
insert into public.cow_weights (cow_id, weighed_on, weight_kg, body_condition_score)
select id, public.farm_today(current_setting('demo.farm')::uuid) - 5, 420, 3.5 from public.cows where tag_number = 'GM-01';
reset role;
