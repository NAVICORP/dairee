-- Dairee, stage 5: the customer portal.
--
-- Customers are not sign-ins: there are hundreds of them and they would never
-- finish an email confirmation. They sign in with their mobile number and a
-- password the farm gives them, checked here, and get a session token. Every
-- portal function takes that token and finds the customer, and the farm, from
-- it: a farm id is never accepted from the phone.
--
-- Both tables below have row level security on and no policies at all: they
-- are keys to the building, reachable only by the functions in this file.
-- Never include them in an export.

create table public.customer_logins (
  customer_id   uuid primary key references public.customers (id) on delete cascade,
  farm_id       uuid not null references public.farms (id) on delete cascade,
  password_hash text not null,              -- bcrypt via pgcrypto
  is_temporary  boolean not null default true,
  issued_at     timestamptz not null default now(),
  issued_by     text,
  changed_at    timestamptz,
  failed_count  int not null default 0,
  locked_until  timestamptz
);

create table public.customer_sessions (
  token_hash   text primary key,            -- sha256 of the token; the token itself is never stored
  customer_id  uuid not null references public.customers (id) on delete cascade,
  farm_id      uuid not null references public.farms (id) on delete cascade,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '180 days'
);
create index customer_sessions_customer on public.customer_sessions (customer_id);

alter table public.customer_logins enable row level security;
alter table public.customer_sessions enable row level security;
revoke all on public.customer_logins, public.customer_sessions from anon, authenticated;

create or replace function public.token_hash(t text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(t, ''), 'sha256'), 'hex');
$$;

-- ---------------------------------------------------------------- the office hands out passwords

-- The first four letters of the name and the first four digits of the mobile
-- number. Guessable by anyone who knows both, which is acceptable only because
-- it is temporary: the portal asks for a new password before showing anything.
create or replace function public.temporary_password(p_name text, p_phone text) returns text
language sql immutable set search_path = '' as $$
  select initcap(rpad(left(regexp_replace(coalesce(p_name, ''), '[^A-Za-z]', '', 'g'), 4), 4, 'x'))
      || left(case when length(d) > 10 then right(d, 10) else d end, 4)
  from (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as d) x;
$$;

create or replace function public.issue_customer_password(customer_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(issue_customer_password.customer_id); pw text;
begin
  if not public.staff_can('customers') then
    raise exception 'You need the Customers page to give out passwords.' using errcode = '42501';
  end if;
  pw := public.temporary_password(c.name, c.phone);
  insert into public.customer_logins (customer_id, farm_id, password_hash, is_temporary, issued_at, issued_by)
  values (c.id, c.farm_id, extensions.crypt(pw, extensions.gen_salt('bf', 8)), true, now(), public.my_name())
  on conflict on constraint customer_logins_pkey do update set password_hash = excluded.password_hash, is_temporary = true,
    issued_at = now(), issued_by = excluded.issued_by, changed_at = null, failed_count = 0, locked_until = null;
  delete from public.customer_sessions s where s.customer_id = c.id;
  perform public.audit(c.farm_id, 'issue_password', 'customer', c.id::text,
    format('%s gave %s a new temporary password', public.my_name(), c.name));
  return jsonb_build_object('phone', c.phone, 'password', pw, 'name', c.name);
end $$;

create or replace function public.revoke_customer_login(customer_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(revoke_customer_login.customer_id);
begin
  if not public.staff_can('customers') then raise exception 'You need the Customers page.' using errcode = '42501'; end if;
  delete from public.customer_logins l where l.customer_id = c.id;
  delete from public.customer_sessions s where s.customer_id = c.id;
  perform public.audit(c.farm_id, 'revoke_login', 'customer', c.id::text, format('%s can no longer sign in', c.name));
end $$;

-- Which customers can sign in, for the Customers screen. No hashes leave.
create or replace function public.customer_logins_status() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.current_farm_id() is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_object_agg(l.customer_id, jsonb_build_object(
      'temporary', l.is_temporary, 'issued_at', l.issued_at,
      'last_seen', (select max(s.last_seen_at) from public.customer_sessions s where s.customer_id = l.customer_id)))
    from public.customer_logins l where l.farm_id = public.current_farm_id()), '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------- sessions

-- The customer behind a token, or an error that sends the portal back to sign-in.
create or replace function public.portal_customer(p_token text) returns public.customers
language plpgsql security definer set search_path = '' as $$
declare s public.customer_sessions%rowtype; c public.customers%rowtype;
begin
  select * into s from public.customer_sessions x where x.token_hash = public.token_hash(p_token);
  if not found or s.expires_at < now() then
    raise exception 'Please sign in again.' using errcode = 'PT401';
  end if;
  select * into c from public.customers x where x.id = s.customer_id;
  if not found or c.status <> 'active' then
    raise exception 'Your account is closed. Please call the farm.' using errcode = 'PT401';
  end if;
  if s.last_seen_at < now() - interval '1 hour' then
    update public.customer_sessions x set last_seen_at = now(), expires_at = now() + interval '180 days'
     where x.token_hash = s.token_hash;
  end if;
  return c;
end $$;

create or replace function public.portal_sign_in(phone text, password text, farm text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  ph text := public.phone_digits(portal_sign_in.phone); r record; hits jsonb := '[]'; n int := 0;
  hit_customer uuid; hit_farm uuid; hit_temp boolean; t text;
begin
  if ph is null or coalesce(password, '') = '' then
    raise exception 'Enter your mobile number and password.' using errcode = '22023';
  end if;
  for r in
    select l.*, c.name as customer_name, f.name as farm_name, f.slug
    from public.customer_logins l
    join public.customers c on c.id = l.customer_id
    join public.farms f on f.id = l.farm_id
    where c.phone = ph and c.status = 'active'
      and (farm is null or f.slug = lower(btrim(farm)))
  loop
    if r.locked_until is not null and r.locked_until > now() then continue; end if;
    if r.password_hash = extensions.crypt(password, r.password_hash) then
      n := n + 1;
      hit_customer := r.customer_id; hit_farm := r.farm_id; hit_temp := r.is_temporary;
      hits := hits || jsonb_build_array(jsonb_build_object('farm', r.slug, 'farm_name', r.farm_name, 'name', r.customer_name));
      update public.customer_logins l set failed_count = 0, locked_until = null where l.customer_id = r.customer_id;
    else
      update public.customer_logins l set failed_count = l.failed_count + 1,
             locked_until = case when l.failed_count + 1 >= 8 then now() + interval '15 minutes' end
       where l.customer_id = r.customer_id;
    end if;
  end loop;
  if n = 0 then
    raise exception 'That number and password do not match. Check them, or ask the farm for a new password.'
      using errcode = '28P01';
  end if;
  if n > 1 then
    -- The same number and password at two farms: the portal asks which one.
    return jsonb_build_object('choose', hits);
  end if;
  t := public.new_token() || public.new_token();
  insert into public.customer_sessions (token_hash, customer_id, farm_id) values (public.token_hash(t), hit_customer, hit_farm);
  -- Old sessions beyond the latest five go.
  delete from public.customer_sessions s where s.customer_id = hit_customer and s.token_hash not in (
    select x.token_hash from public.customer_sessions x where x.customer_id = hit_customer order by x.created_at desc limit 5);
  return jsonb_build_object('token', t, 'must_change_password', hit_temp);
end $$;

create or replace function public.portal_sign_out(token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.customer_sessions s where s.token_hash = public.token_hash(token);
$$;

create or replace function public.portal_change_password(token text, old_password text, new_password text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); l public.customer_logins%rowtype;
begin
  select * into l from public.customer_logins x where x.customer_id = c.id;
  if not found or l.password_hash <> extensions.crypt(coalesce(old_password, ''), l.password_hash) then
    raise exception 'Your current password is not right.' using errcode = '28P01';
  end if;
  if char_length(coalesce(new_password, '')) < 6 then
    raise exception 'Choose a password of at least 6 characters.' using errcode = '22023';
  end if;
  if new_password = old_password then
    raise exception 'Choose a password different from the old one.' using errcode = '22023';
  end if;
  update public.customer_logins x set password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 8)),
         is_temporary = false, changed_at = now()
   where x.customer_id = c.id;
  -- Every other phone signed in as this customer is signed out.
  delete from public.customer_sessions s where s.customer_id = c.id and s.token_hash <> public.token_hash(token);
end $$;

-- ---------------------------------------------------------------- what the portal shows

create or replace function public.portal_must_change(c public.customers) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if exists (select 1 from public.customer_logins l where l.customer_id = c.id and l.is_temporary) then
    raise exception 'Choose your own password first.' using errcode = 'PT403';
  end if;
end $$;

-- Which of the next days can still be changed, per round, so the phone never decides.
create or replace function public.portal_open_days(f uuid, days int default 14) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_agg(jsonb_build_object('day', d::date,
           'morning', public.round_open(f, d::date, 'morning'),
           'evening', public.round_open(f, d::date, 'evening')) order by d)
  from generate_series(public.farm_today(f), public.farm_today(f) + days - 1, interval '1 day') d;
$$;

create or replace function public.portal_home(token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.customers := public.portal_customer(token); fm public.farms%rowtype;
  today date; first date; credit numeric;
begin
  perform public.portal_must_change(c);
  select * into fm from public.farms x where x.id = c.farm_id;
  today := public.farm_today(fm.id);
  first := date_trunc('month', today)::date;
  select coalesce(k.held, 0) into credit from public.customer_credit k where k.customer_id = c.id;
  return jsonb_build_object(
    'customer', jsonb_build_object('id', c.id, 'name', c.name, 'phone', c.phone, 'building', c.building, 'room', c.room,
      'address', c.address, 'delivery_slot', c.delivery_slot, 'milk_quantity', c.milk_quantity,
      'morning_quantity', public.standing_qty(c, 'morning'), 'evening_quantity', public.standing_qty(c, 'evening'),
      'qr_token', c.qr_token, 'start_date', c.start_date,
      'vessels', jsonb_build_object('morning', public.vessels_json(c.id, 'morning'), 'evening', public.vessels_json(c.id, 'evening'))),
    'farm', jsonb_build_object('name', fm.name, 'slug', fm.slug, 'phone', fm.phone, 'currency', fm.currency,
      'customer_pause', fm.customer_pause, 'customer_requests', fm.customer_requests,
      'morning_start', fm.morning_start, 'evening_start', fm.evening_start),
    'today', today,
    'month', public.portal_month(c, first),
    'account', jsonb_build_object(
      -- Only generated bills count toward what is owed; unbilled milk never does.
      'outstanding', coalesce((select sum(v.balance_due) from public.bill_balances v where v.customer_id = c.id), 0),
      'credit', coalesce(credit, 0),
      'unpaid_bills', (select count(*) from public.bill_balances v where v.customer_id = c.id and v.balance_due > 0)),
    'changes', public.portal_changes(c),
    'open_days', public.portal_open_days(fm.id, 14));
end $$;

-- A month of milk: each day and round, what was due and what went.
create or replace function public.portal_month(c public.customers, p_first date) returns jsonb
language sql stable security definer set search_path = '' as $$
  with e as (
    select * from public.expected_rounds(c.farm_id, p_first, (p_first + interval '1 month - 1 day')::date, c.id)
  ), r as (
    select d.delivery_date, d.slot, d.delivered, d.milk_quantity, d.bottle_returned, d.notes
    from public.delivery_records d
    where d.customer_id = c.id and d.delivery_date between p_first and (p_first + interval '1 month - 1 day')::date
  ), k as (
    select e.day, e.slot from e union select r.delivery_date, r.slot from r
  )
  select jsonb_build_object(
    'month', p_first,
    'delivered_liters', coalesce((select sum(r.milk_quantity) from r where r.delivered), 0),
    'delivered_days', (select count(distinct r.delivery_date) from r where r.delivered),
    'paused_days', (select count(*) from (select e.day from e group by e.day having bool_and(e.paused)) x),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', k.day, 'slot', k.slot,
               'due', coalesce(e.qty, 0), 'paused', coalesce(e.paused, false), 'temporary', coalesce(e.temporary, false),
               'delivered', coalesce(r.delivered, false), 'qty', r.milk_quantity, 'notes', r.notes)
               order by k.day, k.slot desc)
      from k
      left join e on e.day = k.day and e.slot = k.slot
      left join r on r.delivery_date = k.day and r.slot = k.slot), '[]'::jsonb));
$$;

create or replace function public.portal_deliveries(token text, month date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token);
begin
  perform public.portal_must_change(c);
  return public.portal_month(c, date_trunc('month', coalesce(month, public.farm_today(c.farm_id)))::date);
end $$;

-- Pauses, temporary deliveries and requests from today on.
create or replace function public.portal_changes(c public.customers) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'pauses', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.pause_type, 'from', p.from_date, 'to', p.to_date,
                                          'slot', p.slot, 'reason', p.reason, 'set_by', p.set_by) order by p.from_date)
      from public.customer_pauses p
      where p.customer_id = c.id and p.is_active
        and (p.to_date is null or p.to_date >= public.farm_today(c.farm_id))), '[]'::jsonb),
    'pause_dates', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'day', d.pause_date, 'slot', d.slot, 'set_by', d.set_by) order by d.pause_date)
      from public.customer_pause_dates d
      where d.customer_id = c.id and d.pause_date >= public.farm_today(c.farm_id)), '[]'::jsonb),
    'temporary', coalesce((
      select jsonb_agg(jsonb_build_object('id', t.id, 'day', t.delivery_date, 'slot', t.slot, 'quantity', t.quantity,
                                          'vessels', t.containers, 'note', t.note) order by t.delivery_date, t.slot desc)
      from public.temporary_deliveries t
      where t.customer_id = c.id and t.delivery_date >= public.farm_today(c.farm_id)), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'day', r.delivery_date, 'slot', r.slot, 'quantity', r.quantity,
                                          'vessels', r.containers, 'note', r.note, 'status', r.status,
                                          'decided_note', r.decided_note) order by r.delivery_date, r.slot desc)
      from public.temporary_requests r
      where r.customer_id = c.id and r.delivery_date >= public.farm_today(c.farm_id) and r.status <> 'withdrawn'), '[]'::jsonb));
$$;

create or replace function public.portal_bills(token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token);
begin
  perform public.portal_must_change(c);
  return jsonb_build_object(
    'currency', (select f.currency from public.farms f where f.id = c.farm_id),
    'outstanding', coalesce((select sum(v.balance_due) from public.bill_balances v where v.customer_id = c.id), 0),
    'credit', coalesce((select k.held from public.customer_credit k where k.customer_id = c.id), 0),
    'bills', coalesce((
      select jsonb_agg(jsonb_build_object('id', v.bill_id, 'number', v.bill_number, 'from', v.period_from, 'to', v.period_to,
               'date', v.bill_date, 'liters', b.total_liters, 'price', b.milk_price, 'total', v.total_amount,
               'discount', v.discount_amount, 'net', v.net_amount, 'paid', v.amount_paid, 'credit_applied', v.credit_applied,
               'balance', v.balance_due, 'delivered_days', b.delivered_days, 'missed_days', b.missed_days,
               'paused_days', b.paused_days)
               order by v.period_from desc)
      from public.bill_balances v join public.bills b on b.id = v.bill_id
      where v.customer_id = c.id), '[]'::jsonb),
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'amount', p.amount, 'date', p.payment_date, 'method', p.payment_method,
               'bill_number', b.bill_number, 'receipt', p.receipt_number, 'advance', p.bill_id is null)
               order by p.payment_date desc, p.created_at desc)
      from public.payments p left join public.bills b on b.id = p.bill_id
      where p.customer_id = c.id), '[]'::jsonb));
end $$;

create or replace function public.portal_vessels(token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token);
begin
  return coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name, 'category', k.category,
                                                       'capacity_ml', k.capacity_ml) order by k.sort_order, k.capacity_ml)
                   from public.containers k where k.farm_id = c.farm_id and k.active), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- what customers can change

create or replace function public.portal_check_open(f uuid, d date, p_slot text) returns void
language plpgsql stable security definer set search_path = '' as $$
declare w record;
begin
  if public.round_open(f, d, p_slot) then return; end if;
  if d < public.farm_today(f) then raise exception 'That day has passed.' using errcode = '22023'; end if;
  if public.day_locked(f, d) then raise exception 'That day is closed. Please call the farm.' using errcode = '22023'; end if;
  select * into w from public.round_window(f, case when p_slot = 'evening' then 'evening' else 'morning' end) w;
  if d = public.farm_today(f) then
    raise exception 'Today''s % milk is already being packed. Please call the farm.', coalesce(nullif(p_slot, 'both'), 'morning')
      using errcode = '22023';
  end if;
  raise exception 'Changes are closed while the % milk is packed, until %. Please try again then.',
    coalesce(nullif(p_slot, 'both'), 'morning'), to_char(w.ends, 'HH24:MI') using errcode = '22023';
end $$;

create or replace function public.portal_pause(token text, kind text, from_date date default null, to_date date default null,
  slot text default 'both', dates date[] default null, reason text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); today date; d date;
begin
  perform public.portal_must_change(c);
  if not (select f.customer_pause from public.farms f where f.id = c.farm_id) then
    raise exception 'Please call the farm to pause your milk.' using errcode = '42501';
  end if;
  today := public.farm_today(c.farm_id);
  if kind = 'dates' then
    foreach d in array coalesce(dates, '{}') loop perform public.portal_check_open(c.farm_id, d, coalesce(slot, 'both')); end loop;
  else
    perform public.portal_check_open(c.farm_id,
      case kind when 'today_only' then today when 'tomorrow_only' then today + 1 else from_date end, coalesce(slot, 'both'));
  end if;
  perform public.add_pause(c, kind, from_date, to_date, slot, reason, dates, 'customer', c.name);
  perform public.audit(c.farm_id, 'portal_pause', 'customer', c.id::text,
    format('%s paused their own milk (%s, %s)', c.name, replace(kind, '_', ' '), public.slot_words(coalesce(slot, 'both'))));
  return public.portal_changes(c);
end $$;

-- Resuming works whoever paused: being paused by the office is no reason to
-- take the button away.
create or replace function public.portal_resume(token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); today date; d date;
begin
  perform public.portal_must_change(c);
  today := public.farm_today(c.farm_id);
  d := case when public.round_open(c.farm_id, today, 'both') then today else today + 1 end;
  perform public.portal_check_open(c.farm_id, d, 'both');
  perform public.end_pauses(c, d);
  perform public.audit(c.farm_id, 'portal_resume', 'customer', c.id::text, format('%s resumed their milk from %s', c.name, d));
  return public.portal_changes(c);
end $$;

-- Removing one pause or one paused date, before its first round is packed.
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
  perform public.portal_check_open(c.farm_id, p.day, p.slot);
  delete from public.customer_pauses x where x.id = p.id;
  delete from public.customer_pause_dates x where x.id = p.id;
  perform public.audit(c.farm_id, 'portal_remove_pause', 'customer', c.id::text, format('%s removed a pause for %s', c.name, p.day));
  return public.portal_changes(c);
end $$;

-- "Send 5 litres on Saturday": a request the office approves or refuses.
create or replace function public.portal_request(token text, day date, slot text, quantity numeric,
  vessels jsonb default '[]', note text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token);
begin
  perform public.portal_must_change(c);
  if not (select f.customer_requests from public.farms f where f.id = c.farm_id) then
    raise exception 'Please call the farm to change an amount.' using errcode = '42501';
  end if;
  if slot not in ('morning', 'evening') then raise exception 'Pick a round.' using errcode = '22023'; end if;
  if quantity is null or quantity < 0 or quantity > 100 then raise exception 'Give an amount in litres.' using errcode = '22023'; end if;
  perform public.portal_check_open(c.farm_id, day, slot);
  if (select count(*) from public.temporary_requests r where r.customer_id = c.id and r.status = 'pending') >= 20 then
    raise exception 'You have many requests waiting. Please wait for the farm to answer.' using errcode = '22023';
  end if;
  update public.temporary_requests r set status = 'withdrawn'
   where r.customer_id = c.id and r.delivery_date = day and r.slot = portal_request.slot and r.status = 'pending';
  insert into public.temporary_requests (farm_id, customer_id, delivery_date, slot, quantity, containers, note)
  values (c.farm_id, c.id, day, slot, quantity, public.clean_vessels(c.farm_id, vessels), nullif(btrim(note), ''));
  perform public.audit(c.farm_id, 'portal_request', 'customer', c.id::text,
    format('%s asked for %s L on %s, %s', c.name, quantity, day, public.slot_words(slot)));
  return public.portal_changes(c);
end $$;

create or replace function public.portal_withdraw_request(token text, request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c public.customers := public.portal_customer(token); n int;
begin
  update public.temporary_requests r set status = 'withdrawn'
   where r.id = request_id and r.customer_id = c.id and r.status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'That request was already answered.' using errcode = '22023'; end if;
  return public.portal_changes(c);
end $$;
