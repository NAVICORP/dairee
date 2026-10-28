-- What the app needs beyond the stages: staff logins Dairee makes, the portal
-- switches on the Pause / Stop page, and the reports.

-- ---------------------------------------------------------------- staff logins
--
-- Staff with an email can be given an email and password login (a SkiFi
-- login made by Dairee through SkAuth's admin API, in the staff-login server
-- function). The decision of who may do that lives here, so it is made in one
-- place: an admin of the same farm as the person.

create or replace function public.staff_login_target(staff_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s public.staff%rowtype;
begin
  select * into s from public.staff x where x.id = staff_id;
  if not found or s.farm_id is distinct from public.current_farm_id() then
    raise exception 'That person is not on this farm.' using errcode = '42501';
  end if;
  if not public.is_admin() then
    raise exception 'Only an admin can make or reset logins.' using errcode = '42501';
  end if;
  return jsonb_build_object('staff_id', s.id, 'farm_id', s.farm_id, 'name', s.name, 'email', s.email, 'phone', s.phone,
    'login_id', s.login_id, 'auth_user_id', s.auth_user_id,
    'farm_name', (select f.name from public.farms f where f.id = s.farm_id), 'by', public.my_name());
end $$;

-- Called by the server function only (service role), after SkAuth answered.
create or replace function public.staff_login_made(staff_id uuid, login_id uuid, temporary boolean, note text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.staff%rowtype;
begin
  select * into s from public.staff x where x.id = staff_id;
  if not found then raise exception 'That person is gone.' using errcode = 'P0002'; end if;
  update public.staff x set login_id = staff_login_made.login_id, must_change_password = coalesce(temporary, false)
   where x.id = s.id;
  insert into public.audit_logs (farm_id, action_type, entity_type, entity_id, performed_by, notes)
  values (s.farm_id, 'staff_login', 'staff', s.id::text, coalesce(nullif(btrim(split_part(note, '|', 1)), ''), 'The office'),
          nullif(btrim(split_part(note, '|', 2)), ''));
end $$;

-- After someone picks their own password, the app stops asking.
create or replace function public.password_changed() returns void
language sql security definer set search_path = '' as $$
  update public.staff s set must_change_password = false where s.auth_user_id = auth.uid() and s.must_change_password;
$$;

-- ---------------------------------------------------------------- the portal switches
--
-- They sit on the Pause / Stop page, so that page (not Settings) controls them.
create or replace function public.set_portal_switches(customer_pause boolean default null, customer_requests boolean default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare f uuid := public.current_farm_id(); r public.farms%rowtype;
begin
  if not (public.staff_can('pauses') or public.staff_can('settings')) then
    raise exception 'You need the Pause / Stop page.' using errcode = '42501';
  end if;
  update public.farms x set
    customer_pause = coalesce(set_portal_switches.customer_pause, x.customer_pause),
    customer_requests = coalesce(set_portal_switches.customer_requests, x.customer_requests)
  where x.id = f returning * into r;
  perform public.audit(f, 'portal_switches', 'farm', f::text,
    format('Customers %s pause and %s ask for changes', case when r.customer_pause then 'can' else 'cannot' end,
           case when r.customer_requests then 'can' else 'cannot' end));
  return jsonb_build_object('customer_pause', r.customer_pause, 'customer_requests', r.customer_requests);
end $$;

-- ---------------------------------------------------------------- reports

-- Litres and stops per day and round.
create or replace function public.report_days(date_from date, date_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  if date_to - date_from > 400 then raise exception 'Pick up to about a year.' using errcode = '22023'; end if;
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

-- Per customer: litres and days delivered in a period.
create or replace function public.report_customers(date_from date, date_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if f is null then raise exception 'You are not on a farm yet.' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('customer_id', c.id, 'name', c.name, 'building', c.building, 'room', c.room,
      'liters', coalesce(x.l, 0), 'days', coalesce(x.d, 0), 'status', c.status)
      order by coalesce(x.l, 0) desc, c.name)
    from public.customers c
    left join (select r.customer_id, sum(r.milk_quantity) as l, count(distinct r.delivery_date) as d
                 from public.delivery_records r
                where r.farm_id = f and r.delivered and r.delivery_date between date_from and date_to
                group by 1) x on x.customer_id = c.id
    where c.farm_id = f and (x.l is not null or c.status = 'active')), '[]'::jsonb);
end $$;

-- Money by month: billed (net of discounts), collected, credit used, payments in.
create or replace function public.report_money(date_from date, date_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare f uuid := public.current_farm_id();
begin
  if not public.staff_can('payments') then
    raise exception 'You need the Payments page to see money.' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('month', m::date,
      'billed', coalesce((select sum(v.net_amount) from public.bill_balances v
                           where v.farm_id = f and date_trunc('month', v.period_from) = m), 0),
      'collected', coalesce((select sum(v.collected) from public.bill_balances v
                              where v.farm_id = f and date_trunc('month', v.period_from) = m), 0),
      'credit_applied', coalesce((select sum(v.credit_applied) from public.bill_balances v
                                   where v.farm_id = f and date_trunc('month', v.period_from) = m), 0),
      'outstanding', coalesce((select sum(v.balance_due) from public.bill_balances v
                                where v.farm_id = f and date_trunc('month', v.period_from) = m), 0),
      'received', coalesce((select sum(p.amount) from public.payments p
                             where p.farm_id = f and date_trunc('month', p.payment_date) = m), 0))
      order by m)
    from generate_series(date_trunc('month', date_from), date_trunc('month', date_to), interval '1 month') m), '[]'::jsonb);
end $$;

-- A customer's recent rounds, for their page in the office.
create or replace function public.customer_history(customer_id uuid, days int default 30) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.customers := public.customer_on_farm(customer_history.customer_id); today date;
begin
  today := public.farm_today(c.farm_id);
  return coalesce((
    select jsonb_agg(jsonb_build_object('day', e.day, 'slot', e.slot, 'due', e.qty, 'paused', e.paused,
      'temporary', e.temporary, 'delivered', coalesce(r.delivered, false), 'qty', r.milk_quantity, 'notes', r.notes,
      'bottle_returned', r.bottle_returned)
      order by e.day desc, e.slot desc)
    from public.expected_rounds(c.farm_id, today - greatest(1, least(days, 120)) + 1, today, c.id) e
    left join public.delivery_records r on r.customer_id = c.id and r.delivery_date = e.day and r.slot = e.slot), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- who may call what

revoke execute on function public.staff_login_made(uuid, uuid, boolean, text), public.report_days(date, date),
  public.report_customers(date, date), public.report_money(date, date), public.customer_history(uuid, int),
  public.staff_login_target(uuid), public.password_changed(), public.set_portal_switches(boolean, boolean)
  from public, anon, authenticated;
grant execute on function public.staff_login_target(uuid), public.password_changed(),
  public.set_portal_switches(boolean, boolean), public.report_days(date, date), public.report_customers(date, date),
  public.report_money(date, date), public.customer_history(uuid, int)
  to authenticated;
