-- Push notifications on the phones (Android and iPhone, through Firebase
-- Cloud Messaging). The database decides who hears about what; the `push`
-- service (server/push.mjs) sends what lands in push_outbox.
--
-- Staff hear about customers' pauses and requests (the Pause / Stop page),
-- problems reported at a door (Deliveries), and a reminder when the day is
-- still open. Delivery staff get a reminder before each round. Customers
-- hear about a new bill, a payment and the answer to their request.

-- ---------------------------------------------------------------- devices

create table public.push_devices (
  token        text primary key check (char_length(token) between 20 and 4096),
  platform     text not null check (platform in ('android', 'ios')),
  auth_user_id uuid,                                    -- staff: their sign-in
  customer_id  uuid references public.customers (id) on delete cascade,  -- customers: the portal
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  check ((auth_user_id is null) <> (customer_id is null))
);
create index push_devices_user on public.push_devices (auth_user_id) where auth_user_id is not null;
create index push_devices_customer on public.push_devices (customer_id) where customer_id is not null;
alter table public.push_devices enable row level security;
revoke all on public.push_devices from anon, authenticated;

-- A phone signed in as staff. One token is one phone: it moves to whoever
-- signs in on it last.
create or replace function public.register_device(token text, platform text) returns void
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if auth.uid() is null then raise exception 'Not signed in.' using errcode = '42501'; end if;
  insert into public.push_devices (token, platform, auth_user_id)
  values (register_device.token, register_device.platform, auth.uid())
  on conflict (token) do update set platform = excluded.platform, auth_user_id = excluded.auth_user_id,
    customer_id = null, last_seen_at = now();
end $$;

create or replace function public.forget_device(token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_devices d where d.token = forget_device.token and d.auth_user_id = auth.uid();
$$;

-- A phone signed in to the customer portal.
create or replace function public.portal_register_device(token text, device text, platform text) returns void
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c public.customers;
begin
  c := public.portal_customer(token);
  insert into public.push_devices (token, platform, customer_id)
  values (device, platform, c.id)
  on conflict (token) do update set platform = excluded.platform, customer_id = excluded.customer_id,
    auth_user_id = null, last_seen_at = now();
end $$;

create or replace function public.portal_forget_device(token text, device text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers;
begin
  c := public.portal_customer(token);
  delete from public.push_devices d where d.token = device and d.customer_id = c.id;
end $$;

revoke all on function public.register_device(text, text), public.forget_device(text),
  public.portal_register_device(text, text, text), public.portal_forget_device(text, text) from public;
grant execute on function public.register_device(text, text), public.forget_device(text) to authenticated;
grant execute on function public.portal_register_device(text, text, text), public.portal_forget_device(text, text) to anon, authenticated;

-- ---------------------------------------------------------------- the outbox

-- Who a message is for: one customer, one staff member, the staff who can
-- open a page (and every admin), the delivery staff, or the admins.
create table public.push_outbox (
  id          bigint generated always as identity primary key,
  farm_id     uuid not null references public.farms (id) on delete cascade,
  audience    text not null check (audience ~ '^(customer|staff):[0-9a-f-]{36}$|^area:[a-z_]+$|^(deliverers|admins)$'),
  kind        text not null check (kind in ('request', 'pause', 'problem', 'bill', 'payment', 'answer', 'round', 'open_day')),
  title       text not null check (char_length(title) <= 120),
  body        text not null check (char_length(body) <= 300),
  link        text,                                  -- where a tap opens: a page key
  dedupe      text,                                  -- sent once per farm
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    int not null default 0,
  last_error  text
);
create unique index push_outbox_dedupe on public.push_outbox (farm_id, dedupe) where dedupe is not null;
create index push_outbox_waiting on public.push_outbox (id) where sent_at is null;
alter table public.push_outbox enable row level security;
revoke all on public.push_outbox from anon, authenticated;

create or replace function public.push_enqueue(f uuid, audience text, kind text, title text, body text,
  link text default null, dedupe text default null) returns void
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  insert into public.push_outbox (farm_id, audience, kind, title, body, link, dedupe)
  values (push_enqueue.f, push_enqueue.audience, push_enqueue.kind, left(push_enqueue.title, 120),
          left(push_enqueue.body, 300), push_enqueue.link, push_enqueue.dedupe)
  on conflict (farm_id, dedupe) where dedupe is not null do nothing;
end $$;
revoke all on function public.push_enqueue(uuid, text, text, text, text, text, text) from public, anon, authenticated;

-- Words the messages share.
create or replace function public.push_litres(q numeric) returns text
language sql immutable set search_path = '' as $$
  select trim(trailing '.' from trim(trailing '0' from to_char(coalesce(q, 0), 'FM999990.000'))) || ' L';
$$;
create or replace function public.push_day(d date) returns text
language sql immutable set search_path = '' as $$
  select to_char(d, 'Dy FMDD Mon');
$$;
create or replace function public.push_money(f uuid, amount numeric) returns text
language sql stable set search_path = '' as $$
  select case coalesce((select x.currency from public.farms x where x.id = f), 'INR')
           when 'INR' then '₹' when 'USD' then '$' when 'EUR' then '€' when 'GBP' then '£'
           else coalesce((select x.currency from public.farms x where x.id = f), '') || ' ' end
         || case when amount = trunc(amount) then to_char(amount, 'FM999G999G990') else to_char(round(amount, 2), 'FM999G999G990D00') end;
$$;

-- ---------------------------------------------------------------- what happens

-- A customer asks for more or less milk on a day.
create or replace function public.push_on_request() returns trigger
language plpgsql security definer set search_path = '' as $$
declare who text;
begin
  select c.name into who from public.customers c where c.id = new.customer_id;
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform public.push_enqueue(new.farm_id, 'area:pauses', 'request', 'Request from ' || coalesce(who, 'a customer'),
      public.push_litres(new.quantity) || ' on ' || public.push_day(new.delivery_date) || ', ' || new.slot
        || coalesce('. ' || nullif(btrim(new.note), ''), ''),
      'pauses');
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status in ('approved', 'rejected') then
    perform public.push_enqueue(new.farm_id, 'customer:' || new.customer_id, 'answer',
      case new.status when 'approved' then 'Request approved' else 'Request declined' end,
      public.push_litres(new.quantity) || ' on ' || public.push_day(new.delivery_date) || ', ' || new.slot
        || coalesce('. ' || nullif(btrim(new.decided_note), ''), ''),
      'changes');
  end if;
  return new;
end $$;
create trigger push_on_request after insert or update of status on public.temporary_requests
  for each row execute function public.push_on_request();

-- A customer pauses from the portal. Some dates make one row per date, so a
-- customer's pauses within two minutes are told once.
create or replace function public.push_on_pause() returns trigger
language plpgsql security definer set search_path = '' as $$
declare who text; what text;
begin
  if new.set_by <> 'customer' then return new; end if;
  select c.name into who from public.customers c where c.id = new.customer_id;
  if tg_table_name = 'customer_pauses' then
    what := case when new.to_date is null then 'From ' || public.push_day(new.from_date) || ' until they resume'
                 when new.to_date = new.from_date then 'On ' || public.push_day(new.from_date)
                 else public.push_day(new.from_date) || ' to ' || public.push_day(new.to_date) end;
  else
    what := 'On ' || public.push_day(new.pause_date) || ' and other days';
  end if;
  if new.slot <> 'both' then what := what || ', ' || new.slot || ' only'; end if;
  perform public.push_enqueue(new.farm_id, 'area:pauses', 'pause', coalesce(who, 'A customer') || ' paused milk', what,
    'pauses', 'pause:' || new.customer_id || ':' || floor(extract(epoch from now()) / 120)::bigint);
  return new;
end $$;
create trigger push_on_pause after insert on public.customer_pauses
  for each row execute function public.push_on_pause();
create trigger push_on_pause after insert on public.customer_pause_dates
  for each row execute function public.push_on_pause();

-- A problem reported at a door.
create or replace function public.push_on_problem() returns trigger
language plpgsql security definer set search_path = '' as $$
declare who text;
begin
  if new.notes is null or new.notes is not distinct from (case when tg_op = 'UPDATE' then old.notes end) then return new; end if;
  select c.name into who from public.customers c where c.id = new.customer_id;
  perform public.push_enqueue(new.farm_id, 'area:deliveries', 'problem', 'Problem at ' || coalesce(who, 'a door'),
    new.notes || ' (' || public.push_day(new.delivery_date) || ', ' || new.slot || ')', 'today');
  return new;
end $$;
create trigger push_on_problem after insert or update of notes on public.delivery_records
  for each row execute function public.push_on_problem();

-- A bill made for a customer.
create or replace function public.push_on_bill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.push_enqueue(new.farm_id, 'customer:' || new.customer_id, 'bill', 'Your bill is ready',
    public.push_money(new.farm_id, new.total_amount - new.discount_amount - new.credit_applied) || ' for '
      || public.push_litres(new.total_liters) || ', ' || public.push_day(new.period_from) || ' to ' || public.push_day(new.period_to),
    'bills', 'bill:' || new.id);
  return new;
end $$;
create trigger push_on_bill after insert on public.bills
  for each row execute function public.push_on_bill();

-- A payment recorded for a customer.
create or replace function public.push_on_payment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.push_enqueue(new.farm_id, 'customer:' || new.customer_id, 'payment', 'Payment received',
    public.push_money(new.farm_id, new.amount) || ' on ' || public.push_day(new.payment_date) || '. Thank you.',
    'bills', 'payment:' || new.id);
  return new;
end $$;
create trigger push_on_payment after insert on public.payments
  for each row execute function public.push_on_payment();

-- ---------------------------------------------------------------- reminders

-- Called every minute by the push service. In each farm's own time zone:
-- 05:30 the morning round, 16:00 the evening round (for delivery staff,
-- when the round has stops), and 21:00 a nudge to admins when today is still open.
create or replace function public.push_reminders() returns int
language plpgsql security definer set search_path = '' as $$
declare f record; local timestamp; today date; stops int; litres numeric; made int := 0;
begin
  for f in select x.id, x.timezone from public.farms x loop
    local := now() at time zone f.timezone;
    today := local::date;
    if local::time >= time '05:30' and local::time < time '07:00' then
      select count(*), sum(r.qty) into stops, litres
        from public.expected_rounds(f.id, today, today) r where r.slot = 'morning' and not r.paused and r.qty > 0;
      if stops > 0 then
        perform public.push_enqueue(f.id, 'deliverers', 'round', 'Morning round',
          stops || case when stops = 1 then ' stop, ' else ' stops, ' end || public.push_litres(litres) || ' to deliver today.',
          'today', 'round:morning:' || today);
        made := made + 1;
      end if;
    end if;
    if local::time >= time '16:00' and local::time < time '17:30' then
      select count(*), sum(r.qty) into stops, litres
        from public.expected_rounds(f.id, today, today) r where r.slot = 'evening' and not r.paused and r.qty > 0;
      if stops > 0 then
        perform public.push_enqueue(f.id, 'deliverers', 'round', 'Evening round',
          stops || case when stops = 1 then ' stop, ' else ' stops, ' end || public.push_litres(litres) || ' to deliver.',
          'today', 'round:evening:' || today);
        made := made + 1;
      end if;
    end if;
    if local::time >= time '21:00' and local::time < time '22:30'
       and exists (select 1 from public.expected_rounds(f.id, today, today) r where not r.paused and r.qty > 0)
       and not public.day_locked(f.id, today) then
      perform public.push_enqueue(f.id, 'admins', 'open_day', 'Today is still open',
        'Check the rounds and close the day, so nobody changes it by mistake.', 'today', 'open_day:' || today);
      made := made + 1;
    end if;
  end loop;
  return made;
end $$;
revoke all on function public.push_reminders() from public, anon, authenticated;

-- ---------------------------------------------------------------- sending

-- The next messages to send, with every phone each one goes to. Claims them,
-- so two senders never send the same one.
create or replace function public.push_claim(max_rows int default 50)
returns table (id bigint, token text, platform text, title text, body text, link text, kind text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
begin
  return query
  with picked as (
    update public.push_outbox o set attempts = o.attempts + 1
    where o.id in (select x.id from public.push_outbox x
                   where x.sent_at is null and x.attempts < 5 and x.created_at > now() - interval '1 day'
                   order by x.id limit max_rows for update skip locked)
    returning o.*
  )
  select p.id, d.token, d.platform, p.title, p.body, p.link, p.kind
  from picked p
  join public.push_devices d on (
       (p.audience like 'customer:%' and d.customer_id = substr(p.audience, 10)::uuid)
    or (d.auth_user_id is not null and exists (
          select 1 from public.staff s
          where s.auth_user_id = d.auth_user_id and s.farm_id = p.farm_id and s.active
            and case
                  when p.audience like 'staff:%' then s.id = substr(p.audience, 7)::uuid
                  when p.audience like 'area:%' then s.is_admin or substr(p.audience, 6) = any (s.permissions)
                  when p.audience = 'deliverers' then s.can_deliver
                  when p.audience = 'admins' then s.is_admin
                  else false end)))
  union all
  -- Messages nobody can receive still need marking as done.
  select p.id, null, null, null, null, null, null from picked p;
end $$;

create or replace function public.push_done(ids bigint[], error text default null) returns void
language sql security definer set search_path = '' as $$
  update public.push_outbox set sent_at = case when error is null then now() else sent_at end, last_error = error
  where id = any (ids);
$$;

create or replace function public.push_drop_device(token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_devices d where d.token = push_drop_device.token;
$$;
revoke all on function public.push_claim(int), public.push_done(bigint[], text), public.push_drop_device(text)
  from public, anon, authenticated;
