-- Dairee's database rules, end to end, as the people who use it.
-- Run on a scratch database after platform.sql and every migration. Everything
-- happens in one transaction that is rolled back at the end.
begin;

create or replace function pg_temp.as_user(sub text, phone text, email text, farm uuid default null) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', sub, 'role', 'authenticated', 'phone', phone, 'email', email)::text, true);
  perform set_config('request.headers', json_build_object('x-farm-id', farm)::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', '{}', true);
  execute 'set local role anon';
end $$;
create or replace function pg_temp.ok(cond boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(cond, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok: %', what;
end $$;
-- Expects the statement to fail with a message containing `msg`.
create or replace function pg_temp.fails(stmt text, msg text, what text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    if position(lower(msg) in lower(sqlerrm)) > 0 then raise notice 'ok: %', what; return; end if;
    raise exception 'FAILED: % (wrong error: %)', what, sqlerrm;
  end;
  raise exception 'FAILED: % (no error)', what;
end $$;
-- Row count of a statement: a refused UPDATE or DELETE does not raise, it
-- changes nothing. Tests assert on the count, never on an exception.
create or replace function pg_temp.rows(stmt text) returns int language plpgsql as $$
declare n int;
begin
  execute stmt;
  get diagnostics n = row_count;
  return n;
end $$;
create temp table t (k text primary key, v text);
grant all on t to authenticated, anon;
create or replace function pg_temp.put(key text, val text) returns void language sql as $$
  insert into t values (key, val) on conflict (k) do update set v = excluded.v;
$$;
create or replace function pg_temp.get(key text) returns text language sql as $$ select v from t where k = key; $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- People
--   Asha  owner of Green Meadows (email)          a1111111-...
--   Babu  owner of another farm (email)           b2222222-...
--   Dev   delivery, Green Meadows (WhatsApp only) d3333333-...
--   Omana office, Green Meadows, no money (email) e4444444-...

-- ---------------------------------------------------------------- stage 1: farms and staff
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.ok((public.whoami() -> 'farms') = '[]'::jsonb, 'a new sign-in has no farm yet');
select pg_temp.put('f1', (public.create_farm('Green Meadows', 'Asia/Kolkata', 'INR', 'Asha')) ->> 'farm_id');
select pg_temp.ok(public.whoami() -> 'farms' -> 0 ->> 'name' = 'Green Meadows', 'Asha started Green Meadows');
select pg_temp.ok((public.whoami() -> 'farms' -> 0 ->> 'is_admin')::boolean, 'and is its admin');
select pg_temp.ok((select slug from public.farms) = 'green-meadows', 'the farm got a slug');
select pg_temp.ok((select count(*) from public.containers) = 4, 'the farm starts with four vessels');
insert into public.staff (name, phone, can_deliver) values ('Dev', '98000 00001', true);
insert into public.staff (name, email, permissions) values ('Omana', 'Omana@Example.com', '{customers,pauses,deliveries,preparation}');
select pg_temp.ok((select phone from public.staff where name = 'Dev') = '919800000001', 'numbers are kept with the country code');
select pg_temp.ok((select email from public.staff where name = 'Omana') = 'omana@example.com', 'emails are kept in lower case');
select pg_temp.fails($$insert into public.staff (name) values ('Nobody')$$, 'staff_check', 'a staff member needs a number or an email');
select pg_temp.fails($$insert into public.staff (name, phone, permissions) values ('X', '9800000009', '{nonsense}')$$,
  'Unknown page', 'a permission must be a real page');
reset role;

select pg_temp.as_user('b2222222-2222-2222-2222-222222222222', null, 'babu@example.com');
select pg_temp.put('f2', (public.create_farm('Hill Dairy')) ->> 'farm_id');
insert into public.customers (name, phone, milk_quantity) values ('Hill customer', '9811111111', 2);
select pg_temp.ok((select count(*) from public.staff) = 1, 'Babu sees only his own farm''s staff');
select pg_temp.ok((select count(*) from public.farms) = 1, 'and only his own farm');
reset role;

-- Dev signs in with a WhatsApp code: his staff row is claimed by the number.
select pg_temp.as_user('d3333333-3333-3333-3333-333333333333', '919800000001', null);
select pg_temp.ok(public.whoami() -> 'farms' -> 0 ->> 'name' = 'Green Meadows', 'Dev is linked to his staff row by his number');
select pg_temp.ok(not (public.whoami() -> 'farms' -> 0 ->> 'is_admin')::boolean, 'Dev is not an admin');
select pg_temp.ok(public.can_deliver(), 'Dev is on the delivery team');
select pg_temp.fails($$update public.staff set is_admin = true where name = 'Dev'$$, 'Only an admin',
  'Dev cannot make himself an admin');
select pg_temp.fails($$update public.staff set permissions = '{payments}' where name = 'Dev'$$, 'Only an admin',
  'Dev cannot give himself the Payments page');
select pg_temp.ok(pg_temp.rows($$update public.staff set can_deliver = false where name = 'Omana'$$) = 0,
  'a refused update on someone else changes nothing (no error, zero rows)');
select pg_temp.ok((select count(*) from public.customers where name = 'Hill customer') = 0, 'Dev cannot see another farm''s customers');
reset role;

select pg_temp.as_user('e4444444-4444-4444-4444-444444444444', null, 'omana@example.com');
select pg_temp.ok(public.whoami() -> 'farms' -> 0 ->> 'name' = 'Green Meadows', 'Omana is linked by her email');
select pg_temp.ok(public.staff_can('customers') and not public.staff_can('payments'), 'Omana has Customers but not Payments');
select pg_temp.fails($$insert into public.staff (name, phone) values ('Sneaky', '9800000077')$$,
  'new row violates row-level security', 'Omana cannot add staff (no Staff page)');
reset role;

-- The last admin cannot leave.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
savepoint last_admin;
select pg_temp.fails($$update public.staff set is_admin = false where name = 'Asha'; set constraints all immediate$$,
  'at least one admin', 'a farm keeps at least one admin');
rollback to savepoint last_admin;

-- ---------------------------------------------------------------- stage 2: customers and the round
insert into public.customers (name, phone, building, room, milk_quantity, morning_quantity, evening_quantity, delivery_slot, route_order, start_date)
values ('Textiles shop', '9822222222', 'Tower 1', '101', 1, null, null, 'morning', 1, current_date - 40),
       ('Rahman', '9833333333', 'Tower 1', '205', 0, 1, 2, 'both', 2, current_date - 40),
       ('Leela', '9844444444', 'Tower 2', '3B', 0.5, null, null, 'evening', 1, current_date - 40);
select pg_temp.ok((select milk_quantity from public.customers where name = 'Rahman') = 3,
  'a twice-a-day customer''s day total is the two rounds added');
select pg_temp.fails($$update public.customers set delivery_slot = 'both', morning_quantity = null where name = 'Leela'$$,
  'morning and the evening quantity', 'both rounds need both quantities');
update public.customers set delivery_slot = 'morning', morning_quantity = 5 where name = 'Leela';
select pg_temp.ok((select morning_quantity is null from public.customers where name = 'Leela'), 'one-round customers keep no round quantities');
update public.customers set delivery_slot = 'evening' where name = 'Leela';

select pg_temp.put('c1', (select id::text from public.customers where name = 'Textiles shop'));
select pg_temp.put('c2', (select id::text from public.customers where name = 'Rahman'));
select pg_temp.put('c3', (select id::text from public.customers where name = 'Leela'));
select pg_temp.put('can5', (select id::text from public.containers where capacity_ml = 5000));
select pg_temp.put('b1', (select id::text from public.containers where capacity_ml = 1000));
select pg_temp.put('b500', (select id::text from public.containers where capacity_ml = 500));

-- The same 5 litre can, morning and evening: two rows, both kept.
select public.save_customer_vessels(pg_temp.get('c2')::uuid, jsonb_build_array(
  jsonb_build_object('container_id', pg_temp.get('can5'), 'slot', 'morning', 'quantity', 1),
  jsonb_build_object('container_id', pg_temp.get('can5'), 'slot', 'evening', 'quantity', 1)));
select pg_temp.ok((select count(*) from public.customer_containers where customer_id = pg_temp.get('c2')::uuid) = 2,
  'the same vessel on both rounds is saved twice, once per round');
select public.save_customer_vessels(pg_temp.get('c1')::uuid, jsonb_build_array(
  jsonb_build_object('container_id', pg_temp.get('b1'), 'slot', 'morning', 'quantity', 1)));
-- A failed save leaves the old set in place: the delete and the insert are one.
select pg_temp.fails(format($$select public.save_customer_vessels(%L, '[{"container_id":"00000000-0000-0000-0000-000000000000","slot":"morning","quantity":1}]')$$,
  pg_temp.get('c1')), 'not on this farm', 'a bad vessel is refused');
select pg_temp.ok((select count(*) from public.customer_containers where customer_id = pg_temp.get('c1')::uuid) = 1,
  'and the customer keeps the vessels they had');
select pg_temp.fails($$insert into public.customer_containers (farm_id, customer_id, container_id, quantity, slot)
  select farm_id, id, id, 1, 'morning' from public.customers limit 1$$, 'permission denied', 'vessels are only written through the save function');

select pg_temp.put('today', (public.farm_today(pg_temp.get('f1')::uuid))::text);
select pg_temp.ok(jsonb_array_length(public.round(pg_temp.get('today')::date, 'morning') -> 'stops') = 2,
  'the morning round has the shop and Rahman');
select pg_temp.ok(jsonb_array_length(public.round(pg_temp.get('today')::date, 'evening') -> 'stops') = 2,
  'the evening round has Rahman and Leela');
select pg_temp.ok((select (s ->> 'qty')::numeric from jsonb_array_elements(public.round(pg_temp.get('today')::date, 'evening') -> 'stops') s
                    where s ->> 'name' = 'Rahman') = 2, 'Rahman takes 2 litres in the evening, not half of 3');
select pg_temp.ok((public.preparation(pg_temp.get('today')::date) -> 'slots' -> 'evening' ->> 'unassigned_litres')::numeric = 0.5,
  'Leela has no vessels: her half litre shows as unassigned, with her name');
select pg_temp.ok((public.preparation(pg_temp.get('today')::date) -> 'slots' -> 'morning' -> 'vessels' -> 0 ->> 'name') is not null,
  'the packing list counts vessels');
reset role;

-- Dev ticks the shop off.
select pg_temp.as_user('d3333333-3333-3333-3333-333333333333', '919800000001', null);
select public.set_delivery(pg_temp.get('c1')::uuid, pg_temp.get('today')::date, 'morning', true);
select pg_temp.ok((select delivered and milk_quantity = 1 and containers -> 0 ->> 'name' = '1 litre bottle'
                     from public.delivery_records where customer_id = pg_temp.get('c1')::uuid),
  'Dev marked the shop delivered, with the litre and the bottle copied in');
select pg_temp.ok((select count(*) from public.audit_logs) = 0, 'Dev cannot read the audit log');
select pg_temp.fails(format($$select public.set_delivery(%L, %L::date - 5, 'morning', true)$$, pg_temp.get('c2'), pg_temp.get('today')),
  'office', 'delivery staff cannot change old rounds');
select pg_temp.fails(format($$select public.set_delivery(%L, %L::date + 1, 'morning', true)$$, pg_temp.get('c2'), pg_temp.get('today')),
  'not happened yet', 'nobody can tick tomorrow');
select pg_temp.fails($$insert into public.delivery_records (farm_id, customer_id, delivery_date, slot) select farm_id, id, current_date, 'morning' from public.customers limit 1$$,
  'permission denied', 'delivery records are only written through set_delivery');
reset role;

select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.ok((select notes from public.audit_logs where action_type = 'mark_delivered')
                  like 'Textiles shop marked delivered for %morning round', 'the audit log reads as a sentence');
select pg_temp.ok(((public.day_summary(pg_temp.get('today')::date)) -> 'slots' -> 'morning' ->> 'delivered')::int = 1,
  'the day summary counts one door done');
-- Bottles still out: yesterday's bottle at the shop shows on today's round
-- until somebody marks it back, and the round lists the delivery team.
select public.set_delivery(pg_temp.get('c1')::uuid, pg_temp.get('today')::date - 1, 'morning', true);
select pg_temp.ok((select (s ->> 'bottles_out')::int = 1 and s -> 'bottle_days' -> 0 ->> 'day' = (pg_temp.get('today')::date - 1)::text
                     from jsonb_array_elements(public.round(pg_temp.get('today')::date, 'morning') -> 'stops') s
                    where s ->> 'customer_id' = pg_temp.get('c1')), 'yesterday''s bottle at the shop is still to collect today');
select public.set_bottle_returned(pg_temp.get('c1')::uuid, pg_temp.get('today')::date - 1, 'morning', true);
select pg_temp.ok((select (s ->> 'bottles_out')::int = 0
                     from jsonb_array_elements(public.round(pg_temp.get('today')::date, 'morning') -> 'stops') s
                    where s ->> 'customer_id' = pg_temp.get('c1')), 'and once it is back, it is gone');
select pg_temp.ok(public.round(pg_temp.get('today')::date, 'morning') -> 'staff' @> '[{"name": "Dev"}]', 'the round lists the delivery team');
select pg_temp.ok((select s ->> 'delivered_at' is not null
                     from jsonb_array_elements(public.round(pg_temp.get('today')::date, 'morning') -> 'stops') s
                    where s ->> 'customer_id' = pg_temp.get('c1')), 'a delivered stop says when');

-- ---------------------------------------------------------------- stage 3: pauses and temporary deliveries
select public.pause_customer(pg_temp.get('c1')::uuid, 'custom_range', pg_temp.get('today')::date + 1, pg_temp.get('today')::date + 3);
select public.set_temporary(pg_temp.get('c2')::uuid, pg_temp.get('today')::date + 1, 'morning', 5,
  jsonb_build_array(jsonb_build_object('container_id', pg_temp.get('can5'), 'quantity', 1)), 'Guests');
select pg_temp.put('tmr', (pg_temp.get('today')::date + 1)::text);
select pg_temp.ok((select paused from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('tmr')::date, pg_temp.get('tmr')::date)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'the shop is paused tomorrow');
select pg_temp.ok((select qty = 5 and temporary from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('tmr')::date, pg_temp.get('tmr')::date)
                    where customer_id = pg_temp.get('c2')::uuid and slot = 'morning'), 'Rahman gets 5 litres tomorrow morning');
select pg_temp.ok((select qty = 2 and not temporary from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('tmr')::date, pg_temp.get('tmr')::date)
                    where customer_id = pg_temp.get('c2')::uuid and slot = 'evening'), 'and his usual 2 in the evening');
select pg_temp.ok((select morning_quantity = 1 from public.customers where id = pg_temp.get('c2')::uuid),
  'a temporary delivery changes nothing permanent');
select pg_temp.ok((select qty = 1 from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('tmr')::date + 1, pg_temp.get('tmr')::date + 1)
                    where customer_id = pg_temp.get('c2')::uuid and slot = 'morning'), 'the day after, Rahman is back to normal');
-- A temporary delivery wins over a pause on the same round.
select public.set_temporary(pg_temp.get('c1')::uuid, pg_temp.get('today')::date + 2, 'morning', 3);
select pg_temp.ok((select qty = 3 and not paused from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('today')::date + 2, pg_temp.get('today')::date + 2)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'a temporary delivery wins over a pause');
select public.resume_customer(pg_temp.get('c1')::uuid, pg_temp.get('today')::date + 2);
select pg_temp.ok((select paused from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('tmr')::date, pg_temp.get('tmr')::date)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'resuming from a later day keeps tomorrow paused');
select pg_temp.ok(not (select paused from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('today')::date + 3, pg_temp.get('today')::date + 3)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'and ends the pause from that day');
reset role;

-- The packing windows: today and future dates ask different questions.
do $$
declare f uuid := pg_temp.get('f1')::uuid; now_t time := public.farm_now(f)::time;
begin
  if now_t < '03:00' or now_t > '20:00' then raise notice 'skipped: window checks need the farm clock between 03:00 and 20:00'; return; end if;
  -- Packing right now.
  update public.farms set morning_start = now_t - interval '1 hour', morning_end = now_t + interval '1 hour' where id = f;
  perform pg_temp.ok(not public.today_round_open(f, 'morning'), 'while packing, today''s morning is closed');
  perform pg_temp.ok(not public.future_round_open(f, 'morning'), 'and future mornings wait until packing ends');
  -- Packing finished an hour ago.
  update public.farms set morning_start = now_t - interval '3 hours', morning_end = now_t - interval '1 hour' where id = f;
  perform pg_temp.ok(not public.today_round_open(f, 'morning'), 'after packing, today''s morning stays closed (the milk has gone)');
  perform pg_temp.ok(public.future_round_open(f, 'morning'), 'but tomorrow''s morning is open again');
  -- Packing starts later.
  update public.farms set morning_start = now_t + interval '1 hour', morning_end = now_t + interval '2 hours' where id = f;
  perform pg_temp.ok(public.today_round_open(f, 'morning'), 'before packing, today''s morning can still change');
  perform pg_temp.ok(not public.round_open(f, public.farm_today(f) - 1, 'morning'), 'yesterday can never change');
end $$;

-- ---------------------------------------------------------------- stage 4: money
select pg_temp.as_user('d3333333-3333-3333-3333-333333333333', '919800000001', null);
select pg_temp.fails($$select public.money_summary()$$, 'Payments page', 'Dev cannot see money');
select pg_temp.ok((select count(*) from public.bills) = 0 and (select count(*) from public.payments) = 0
                  and (select count(*) from public.milk_prices) = 0, 'money tables are empty to Dev');
reset role;

select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
-- Milk was 35 a litre, and 38 from 20 days ago.
insert into public.milk_prices (price_per_liter, effective_from) values (35, current_date - 60), (38, current_date - 20);
-- The shop took a litre every morning for the last 30 days (back-filled by the office).
do $$
declare d date;
begin
  for d in select generate_series(current_date - 30, current_date - 1, interval '1 day')::date loop
    perform public.set_delivery(pg_temp.get('c1')::uuid, d, 'morning', true);
  end loop;
end $$;
select pg_temp.put('bills', (public.generate_bills(current_date - 30, current_date - 21))::text);
select pg_temp.ok((pg_temp.get('bills')::jsonb ->> 'made')::int = 1, 'one bill made for the first ten days');
select pg_temp.ok((select total_liters = 10 and total_amount = 350 and milk_price = 35 from public.bills),
  'ten days at the price of the time: 350 at 35');
select pg_temp.ok(((public.generate_bills(current_date - 25, current_date - 15)) -> 'skipped' -> 0 ->> 'reason') like 'Already billed%',
  'the same days are never billed twice');
select pg_temp.fails($$insert into public.bills (farm_id, customer_id, seq, bill_number, period_from, period_to, bill_date, milk_price,
  total_liters, total_amount, delivered_days, missed_days, paused_days) select farm_id, customer_id, 99, 'X', period_from, period_to,
  bill_date, 1, 1, 1, 0, 0, 0 from public.bills limit 1$$, 'permission denied', 'bills are only made by generate_bills');

select pg_temp.put('bill1', (select id::text from public.bills));
-- Paid 400 against a bill of 350: the extra 50 is the shop's, not income.
insert into public.payments (customer_id, amount, payment_date, payment_method, bill_id)
values (pg_temp.get('c1')::uuid, 400, current_date - 19, 'upi', pg_temp.get('bill1')::uuid);
select pg_temp.ok((select balance_due = 0 and collected = 350 from public.bill_balances), 'the bill is settled, 350 collected');
select pg_temp.ok((select held = 50 from public.customer_credit where customer_id = pg_temp.get('c1')::uuid), 'the extra 50 is held as credit');
select pg_temp.ok((public.money_summary() ->> 'collected')::numeric = 350, 'credit does not count as collected until used');
select pg_temp.ok((public.money_invariant() ->> 'ok')::boolean, 'payments = collected + held + applied');

select public.generate_bills(current_date - 20, current_date - 11);
select pg_temp.ok((select total_amount = 380 and credit_before = 50 and credit_applied = 50 from public.bills where period_from = current_date - 20),
  'the next bill (10 days at 38) takes the 50 credit by itself');
select pg_temp.ok((select balance_due = 330 from public.bill_balances where period_from = current_date - 20), 'leaving 330 to pay');
select pg_temp.ok((select held = 0 from public.customer_credit where customer_id = pg_temp.get('c1')::uuid), 'and no credit left');
select pg_temp.ok((public.money_invariant() ->> 'ok')::boolean, 'the invariant still holds');

-- The advance is corrected to 370: every bill it touched is fixed.
update public.payments set amount = 370 where bill_id = pg_temp.get('bill1')::uuid;
select pg_temp.ok((select credit_applied = 20 from public.bills where period_from = current_date - 20),
  'correcting the payment fixes the later bill''s credit');
select pg_temp.ok((public.money_invariant() ->> 'ok')::boolean, 'the invariant holds after a correction');

-- A discount reduces what is owed; it is not a payment.
update public.bills set discount_amount = 30 where period_from = current_date - 20;
select pg_temp.ok((select net_amount = 350 and balance_due = 330 and amount_paid = 0 from public.bill_balances where period_from = current_date - 20),
  'a discount lowers the bill, and is not money paid');
select pg_temp.ok((public.money_summary() ->> 'collected')::numeric = 350, 'and never shows as collected');
select pg_temp.fails($$update public.bills set credit_applied = 999$$, 'permission denied', 'nobody sets credit by hand');

-- An advance not tied to a bill: held, then used by the next bill.
insert into public.payments (customer_id, amount, payment_date, payment_method) values (pg_temp.get('c1')::uuid, 500, current_date - 5, 'cash');
select pg_temp.ok((select credit_applied from public.bills where period_from = current_date - 20) = 350,
  'an advance pays the oldest bill with something due first');
select pg_temp.ok((select held = 170 from public.customer_credit where customer_id = pg_temp.get('c1')::uuid), 'the rest is held');
select public.generate_bills(current_date - 10, current_date - 1);
select pg_temp.ok((select b.credit_applied = 170 and b.balance_due = 210 from public.bill_balances b join public.bills x on x.id = b.bill_id
                    where x.period_from = current_date - 10), 'the next bill takes what is left of the advance');
select pg_temp.ok((public.money_invariant() ->> 'ok')::boolean, 'the invariant holds with an advance');
select pg_temp.ok(((public.customer_balances()) -> 0 ->> 'outstanding')::numeric = 210, 'the shop owes 210 in all');
-- Deleting the advance puts the bills back.
delete from public.payments where bill_id is null;
select pg_temp.ok((select credit_applied = 20 from public.bills where period_from = current_date - 20), 'deleting the advance undoes what it paid');
select pg_temp.ok((public.money_invariant() ->> 'ok')::boolean, 'the invariant holds after a delete');
select pg_temp.fails(format($$delete from public.customers where id = %L$$, pg_temp.get('c1')), 'violates foreign key',
  'a customer with bills cannot be deleted, only stopped');
reset role;

-- Babu's farm sees none of it.
select pg_temp.as_user('b2222222-2222-2222-2222-222222222222', null, 'babu@example.com');
select pg_temp.ok((select count(*) from public.bills) = 0 and (select count(*) from public.bill_balances) = 0,
  'another farm sees no bills');
select pg_temp.ok(not exists (select 1 from jsonb_array_elements(public.round(current_date, 'morning') -> 'stops') s
                               where s ->> 'name' = 'Rahman'), 'another farm''s round never shows Green Meadows customers');
reset role;

-- ---------------------------------------------------------------- stage 5: the customer portal
select pg_temp.as_user('e4444444-4444-4444-4444-444444444444', null, 'omana@example.com');
select pg_temp.put('pw', (public.issue_customer_password(pg_temp.get('c1')::uuid)) ->> 'password');
select pg_temp.ok(pg_temp.get('pw') ~ '^Text[0-9]{4}$', 'the temporary password is four letters of the name and four random digits');
reset role;

select pg_temp.as_anon();
select pg_temp.fails($$select * from public.customer_logins$$, 'permission denied', 'nobody reads the login table');
select pg_temp.fails($$select * from public.customers$$, 'permission denied', 'anonymous callers read no customers');
select pg_temp.ok((public.portal_sign_in('9822222222', 'wrong') ->> 'error') like '%do not match%', 'a wrong password is refused');
select pg_temp.put('tok', (public.portal_sign_in('+91 98222 22222', pg_temp.get('pw'))) ->> 'token');
select pg_temp.ok(length(pg_temp.get('tok')) > 40, 'the right password gives a session');
select pg_temp.fails(format($$select public.portal_home(%L)$$, pg_temp.get('tok')), 'own password', 'a temporary password must be changed first');
select public.portal_change_password(pg_temp.get('tok'), pg_temp.get('pw'), 'milk-every-day');
select pg_temp.ok((public.portal_home(pg_temp.get('tok')) -> 'customer' ->> 'name') = 'Textiles shop', 'the portal shows the shop');
select pg_temp.ok((public.portal_home(pg_temp.get('tok')) -> 'account' ->> 'outstanding')::numeric = 710,
  'the portal owes exactly what the bills say (330 + 380)');
select pg_temp.ok(jsonb_array_length(public.portal_bills(pg_temp.get('tok')) -> 'bills') = 3, 'the portal lists the shop''s three bills');
select pg_temp.fails($$select public.portal_home('not-a-token')$$, 'sign in again', 'a made-up token is refused');
select pg_temp.fails($$select public.round(current_date, 'morning')$$, 'permission denied', 'the portal cannot call office functions');
reset role;
-- The office pauses the shop; the shop can still resume.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
update public.farms set morning_start = '00:00', morning_end = '00:01', evening_start = '23:58', evening_end = '23:59';
select public.pause_customer(pg_temp.get('c1')::uuid, 'until_resumed', pg_temp.get('today')::date + 1);
reset role;
select pg_temp.as_anon();
select pg_temp.ok(exists (select 1 from jsonb_array_elements(public.portal_home(pg_temp.get('tok')) -> 'changes' -> 'pauses') p
                          where p ->> 'kind' = 'until_resumed' and p ->> 'set_by' = 'office'), 'the shop sees the office''s pause');
select public.portal_resume(pg_temp.get('tok'));
reset role;
select pg_temp.ok(not (select paused from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('today')::date + 5, pg_temp.get('today')::date + 5)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'and resumed it from the portal');
select pg_temp.as_anon();
select public.portal_request(pg_temp.get('tok'), pg_temp.get('today')::date + 2, 'morning', 4);
reset role;
select pg_temp.ok((select status from public.temporary_requests) = 'pending', 'a request waits for the office');
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select public.decide_request((select id from public.temporary_requests), true, 'Done');
select pg_temp.ok((select qty = 4 and temporary from public.expected_rounds(pg_temp.get('f1')::uuid, pg_temp.get('today')::date + 2, pg_temp.get('today')::date + 2)
                    where customer_id = pg_temp.get('c1')::uuid and slot = 'morning'), 'an approved request becomes a temporary delivery');

-- ---------------------------------------------------------------- stage 6: the herd
insert into public.cows (tag_number, name, status) values ('KL-001', 'Lakshmi', 'milking');
insert into public.milk_yield (cow_id, yield_date, slot, litres) select id, current_date - 1, 'morning', 9.5 from public.cows;
insert into public.cow_vaccinations (cow_id, vaccine, given_on) select id, 'FMD', current_date from public.cows;
select pg_temp.ok((select count(*) from public.cow_events) = 2, 'the cow''s timeline fills itself');
insert into public.cow_breeding_events (cow_id, kind, event_date, bull) select id, 'ai', current_date - 20, 'HF 4417' from public.cows;
insert into public.cow_weights (cow_id, weighed_on, weight_kg) select id, current_date, 420 from public.cows;
select pg_temp.ok((select summary from public.cow_events where kind = 'cow_breeding_events') = 'Inseminated, bull HF 4417',
  'the timeline says what happened in words');
select pg_temp.ok((select summary from public.cow_events where kind = 'cow_weights') = 'Weighed 420 kg', 'weights without trailing zeros');
select pg_temp.ok((select (occurred_at at time zone 'Asia/Kolkata')::date from public.cow_events where kind = 'cow_breeding_events') = current_date - 20,
  'a record entered later shows on the day it happened');
select pg_temp.ok(((public.herd_vs_round(current_date - 1, current_date - 1)) -> 0 ->> 'produced')::numeric = 9.5,
  'milk produced is set against milk delivered');
reset role;
select pg_temp.as_user('d3333333-3333-3333-3333-333333333333', '919800000001', null);
select pg_temp.fails($$insert into public.cows (tag_number) values ('X')$$, 'row-level security', 'Dev does not care for the cows');
select pg_temp.ok((select count(*) from public.cows) = 1, 'but can see them');
reset role;

-- ---------------------------------------------------------------- reports and switches
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.ok(jsonb_array_length(public.report_days(current_date - 6, current_date)) = 7, 'a week of report days');
select pg_temp.ok((public.report_customers(current_date - 30, current_date) -> 0 ->> 'name') = 'Textiles shop', 'the shop took the most milk');
select pg_temp.ok(jsonb_array_length(public.report_money(current_date - 40, current_date)) >= 1, 'money by month');
select pg_temp.ok(jsonb_array_length(public.customer_history(pg_temp.get('c1')::uuid, 7)) >= 1, 'a customer''s recent rounds');
reset role;
select pg_temp.as_user('e4444444-4444-4444-4444-444444444444', null, 'omana@example.com');
select pg_temp.ok(not (public.set_portal_switches(false, null) ->> 'customer_pause')::boolean, 'the Pause / Stop page turns customer pausing off');
select pg_temp.fails($$select public.report_money(current_date - 40, current_date)$$, 'Payments page', 'reports of money need Payments');
reset role;
select pg_temp.as_user('e4444444-4444-4444-4444-444444444444', null, 'omana@example.com');
select pg_temp.ok((select count(*) from public.milk_prices) = 0, 'without Payments, the milk price is hidden too');
reset role;

-- ---------------------------------------------------------------- the review's holes, closed
-- Nobody points a staff row at somebody else's sign-in, not even an admin.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.fails($$update public.staff set auth_user_id = 'b2222222-2222-2222-2222-222222222222' where name = 'Dev'$$,
  'linked when they first sign in', 'an admin cannot link somebody else''s sign-in');
select pg_temp.fails($$insert into public.staff (name, email, auth_user_id) values ('Fake', 'fake@example.com', 'b2222222-2222-2222-2222-222222222222')$$,
  'linked when they first sign in', 'nor add a row already linked');
update public.staff set permissions = '{customers,pauses,deliveries,preparation,staff,settings}' where name = 'Omana';
reset role;
-- With the Staff page but not admin: the delivery team only.
select pg_temp.as_user('e4444444-4444-4444-4444-444444444444', null, 'omana@example.com');
select pg_temp.fails($$update public.staff set email = 'omana2@example.com' where is_admin$$, 'Only an admin',
  'the Staff page cannot move an admin''s email to a new owner');
select pg_temp.fails($$delete from public.staff where is_admin$$, 'Only an admin', 'nor remove an admin');
select pg_temp.ok(pg_temp.rows($$update public.staff set phone = '919800000099' where name = 'Dev'$$) = 1,
  'but can fix a delivery person''s number');
select pg_temp.fails($$select public.resume_customer('$$ || pg_temp.get('c1') || $$', current_date - 5)$$, 'Past days are history',
  'resuming cannot rewrite past days');
reset role;
-- A billed day stays as billed.
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.fails($$select public.set_delivery('$$ || pg_temp.get('c1') || $$', current_date - 25, 'morning', false)$$,
  'on a bill already', 'a billed day cannot be ticked differently');
-- Removing a pause that has started keeps its past days.
reset role;
insert into public.customer_pauses (farm_id, customer_id, pause_type, from_date, to_date, slot, set_by)
values (pg_temp.get('f1')::uuid, pg_temp.get('c1')::uuid, 'custom_range', pg_temp.get('today')::date - 3, pg_temp.get('today')::date + 3, 'both', 'office');
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select public.remove_pause((select id from public.customer_pauses where from_date = pg_temp.get('today')::date - 3));
select pg_temp.ok((select to_date from public.customer_pauses where from_date = pg_temp.get('today')::date - 3) = pg_temp.get('today')::date - 1,
  'removing a running pause ends it yesterday');
reset role;
-- The portal locks a number after eight wrong passwords, and the count sticks.
select pg_temp.as_anon();
select pg_temp.ok((public.portal_sign_in('9822222222', 'wrong') ->> 'error') like '%do not match%', 'a wrong password is answered');
select public.portal_sign_in('9822222222', 'wrong') from generate_series(1, 8);
reset role;
select pg_temp.ok((select locked_until is not null from public.customer_logins l
                   join public.customers c on c.id = l.customer_id where c.phone = '919822222222'), 'eight wrong tries lock the number');
select pg_temp.as_anon();
select pg_temp.ok((public.portal_sign_in('9822222222', 'whatever') ->> 'error') like 'Too many tries%', 'and say so');
reset role;
select pg_temp.ok(public.temporary_password('Lakshmi') ~ '^Laks[0-9]{4}$', 'a temporary password is the name and four random digits');

-- ---------------------------------------------------------------- leaving
select pg_temp.as_user('b2222222-2222-2222-2222-222222222222', null, 'babu@example.com');
select public.delete_my_data();
reset role;
select pg_temp.ok(not exists (select 1 from public.farms where id = pg_temp.get('f2')::uuid),
  'an owner working alone takes the farm with them when they delete their account');
select pg_temp.as_user('a1111111-1111-1111-1111-111111111111', null, 'asha@example.com');
select pg_temp.fails($$select public.delete_my_data()$$, 'only admin', 'an owner with staff must hand over first');
reset role;

rollback;
