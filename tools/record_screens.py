"""Records what the server answers for the demo farm (tools/demo.sql), so the
screen pictures (app/test_screens) show real answers from the real database
rules, without a server running during the Flutter tests.

    python3 tools/record_screens.py app/test_screens/fixtures.json

Connects with the usual PG* settings (PGHOST, PGPORT, PGUSER, PGDATABASE).
Needs psycopg: pip install "psycopg[binary]".
"""
import json
import sys

import psycopg

ASHA = ('a1111111-1111-1111-1111-111111111111', None, 'asha@example.com')
DEV = ('d3333333-3333-3333-3333-333333333333', '919800000001', None)
RAHUL = ('f5555555-5555-5555-5555-555555555555', '919800000004', None)

conn = psycopg.connect(autocommit=False)


def run(who, sql, args=None, farm=None):
    """One statement as a signed-in person (or anon), its first column as JSON."""
    with conn.cursor() as cur:
        if who is None:
            cur.execute("select set_config('request.jwt.claims', '{\"role\":\"anon\"}', true)")
            cur.execute("select set_config('request.headers', '{}', true)")
            cur.execute('set local role anon')
        else:
            sub, phone, email = who
            claims = json.dumps({'sub': sub, 'role': 'authenticated', 'phone': phone, 'email': email})
            cur.execute("select set_config('request.jwt.claims', %s, true)", (claims,))
            cur.execute("select set_config('request.headers', %s, true)", (json.dumps({'x-farm-id': farm}),))
            cur.execute('set local role authenticated')
        cur.execute(sql, args)
        row = cur.fetchone()
    conn.commit()
    return row[0] if row else None


def rows(sql, args=None, farm=None):
    return run(ASHA, f"select coalesce(json_agg(t), '[]'::json) from ({sql}) t", args, farm) or []


with conn.cursor() as cur:
    cur.execute("select id::text, public.farm_today(id)::text from public.farms where slug = 'green-meadows-dairy'")
    farm, today = cur.fetchone()
conn.commit()

# The people sign in once, which links their staff rows.
for who in (ASHA, DEV, RAHUL):
    run(who, 'select public.whoami()', farm=farm)

out = {'today': today, 'farm_id': farm, 'rpc': {}, 'as': {}, 'portal': {}, 'tables': {}}


def rpc(name, sql, args=None, who=ASHA):
    out['rpc' if who is ASHA else 'as'].setdefault(name, None)
    value = run(who, sql, args, farm)
    if who is ASHA:
        out['rpc'][name] = value
    return value


# The portal: Lakshmi Iyer signs in, sets her own password, asks for an
# extra delivery and pauses a day.
pw = run(ASHA, "select public.issue_customer_password((select id from public.customers where name = 'Lakshmi Iyer')) ->> 'password'", farm=farm)
phone = run(ASHA, "select phone from public.customers where name = 'Lakshmi Iyer'", farm=farm)
token = run(None, "select public.portal_sign_in(%s, %s, null) ->> 'token'", (phone, pw))
run(None, 'select public.portal_change_password(%s, %s, %s)::text', (token, pw, 'lakshmi-2026'))
run(None, "select public.portal_request(%s, (%s::date + 2), 'evening', 2.0, '[]'::jsonb, 'Family visiting')::text", (token, today))
run(None, "select public.portal_pause(%s, 'dates', null, null, 'both', array[(%s::date + 5)], 'Out for the day')::text", (token, today))

d = today
rpc('whoami', 'select public.whoami()')
rpc('round', "select public.round(%s::date, 'morning')", (d,))
rpc('preparation', 'select public.preparation(%s::date)', (d,))
rpc('day_summary', 'select public.day_summary(%s::date)', (d,))
rpc('money_summary', "select public.money_summary(date_trunc('month', %s::date)::date, %s::date)", (d, d))
rpc('customer_balances', 'select public.customer_balances()')
rpc('money_invariant', 'select public.money_invariant()')
rpc('customer_logins_status', 'select public.customer_logins_status()')
rpc('report_days', 'select public.report_days(%s::date - 29, %s::date)', (d, d))
rpc('report_customers', 'select public.report_customers(%s::date - 29, %s::date)', (d, d))
rpc('report_money', 'select public.report_money(%s::date - 29, %s::date)', (d, d))
rpc('herd_vs_round', 'select public.herd_vs_round(%s::date - 13, %s::date)', (d, d))
rpc('customer_history', "select public.customer_history((select id from public.customers where name = 'Anitha Nair'), 30)")
# Answers that depend on the day and round asked for, kept as name@day@round.
tomorrow = run(ASHA, 'select (%s::date + 1)::text', (d,), farm)
for day in (d, tomorrow):
    out['rpc'][f'preparation@{day}'] = run(ASHA, 'select public.preparation(%s::date)', (day,), farm)
    for slot in ('morning', 'evening'):
        out['rpc'][f'round@{day}@{slot}'] = run(ASHA, 'select public.round(%s::date, %s)', (day, slot), farm)

out['as']['dev'] = {
    'whoami': run(DEV, 'select public.whoami()', farm=farm),
    'round': run(DEV, "select public.round(%s::date, 'morning')", (d,), farm),
    f'round@{d}@morning': run(DEV, "select public.round(%s::date, 'morning')", (d,), farm),
    f'round@{d}@evening': run(DEV, "select public.round(%s::date, 'evening')", (d,), farm),
}
out['as']['rahul'] = {'whoami': run(RAHUL, 'select public.whoami()', farm=farm)}

out['portal'] = {
    'portal_home': run(None, 'select public.portal_home(%s)', (token,)),
    'portal_deliveries': run(None, "select public.portal_deliveries(%s, date_trunc('month', %s::date)::date)", (token, d)),
    'portal_bills': run(None, 'select public.portal_bills(%s)', (token,)),
    'portal_vessels': run(None, 'select public.portal_vessels(%s)', (token,)),
}

t = out['tables']
for name in ('farms', 'staff', 'containers', 'customers', 'customer_pauses', 'customer_pause_dates', 'temporary_deliveries',
             'temporary_requests', 'bill_balances', 'bills', 'payments', 'customer_credit', 'milk_prices', 'cows'):
    t[name] = rows(f'select * from public.{name}', farm=farm)
t['customer_containers'] = rows(
    'select cc.*, json_build_object(\'name\', c.name, \'category\', c.category, \'capacity_ml\', c.capacity_ml) as containers '
    'from public.customer_containers cc join public.containers c on c.id = cc.container_id', farm=farm)
t['delivery_records'] = rows('select * from public.delivery_records where delivery_date >= %s::date - 6', (d,), farm)
t['milk_yield'] = rows('select * from public.milk_yield', farm=farm)
t['cow_events'] = rows('select * from public.cow_events order by occurred_at desc limit 200', farm=farm)
t['audit_logs'] = rows('select * from public.audit_logs order by created_at desc limit 80', farm=farm)

missing = [k for k, v in out['rpc'].items() if v is None]
if missing:
    sys.exit(f'No answer for: {missing}')
with open(sys.argv[1], 'w') as f:
    json.dump(out, f, indent=1, sort_keys=True)
print(f"Recorded the demo farm for {today}: {len(t['customers'])} customers, {len(t['bill_balances'])} bills, "
      f"{len(t['cows'])} cows, {len(out['rpc']['round'].get('stops', []) if isinstance(out['rpc']['round'], dict) else out['rpc']['round'])} stops on the round.")
