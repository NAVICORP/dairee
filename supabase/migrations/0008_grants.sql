-- Who may call which function.
--
-- Everything is closed first, then opened one by one. The platform's defaults
-- open every new function to the API roles, so a later migration that adds
-- functions must end with its own revoke and grants, the same way.

revoke execute on all functions in schema public from public, anon, authenticated;

-- Used inside row policies, column defaults and triggers, which run as the
-- person writing: they need to be callable, and each checks who is asking.
grant execute on function
  public.phone_digits(text), public.clean_email(text), public.my_phone(), public.my_email(), public.new_token(),
  public.requested_farm(), public.trusted_writer(), public.farm_now(uuid), public.farm_today(uuid),
  public.current_farm_id(), public.my_staff_id(), public.is_admin(), public.staff_can(text),
  public.can_deliver(), public.can_care(), public.my_name()
  to authenticated;

-- Read-only helpers that run as the caller, so row level security still
-- limits them to the caller's own farm.
grant execute on function
  public.expected_rounds(uuid, date, date, uuid), public.standing_qty(public.customers, text),
  public.vessels_json(uuid, text), public.round_window(uuid, text), public.future_round_open(uuid, text),
  public.today_round_open(uuid, text), public.round_open(uuid, date, text), public.day_locked(uuid, date),
  public.slot_words(text)
  to authenticated;

-- The office and the round.
grant execute on function
  public.whoami(), public.create_farm(text, text, text, text), public.delete_farm(text), public.delete_my_data(),
  public.save_customer_vessels(uuid, jsonb), public.set_customer_price(uuid, numeric),
  public.pause_customer(uuid, text, date, date, text, text, date[]), public.resume_customer(uuid, date),
  public.remove_pause(uuid), public.set_temporary(uuid, date, text, numeric, jsonb, text),
  public.remove_temporary(uuid), public.decide_request(uuid, boolean, text),
  public.round(date, text), public.set_delivery(uuid, date, text, boolean, numeric, text),
  public.set_note(uuid, date, text, text), public.set_bottle_returned(uuid, date, text, boolean),
  public.lock_day(date, boolean), public.preparation(date), public.day_summary(date),
  public.generate_bills(date, date, uuid[], date), public.refresh_bill(uuid),
  public.money_summary(date, date), public.money_invariant(), public.customer_balances(),
  public.issue_customer_password(uuid), public.revoke_customer_login(uuid), public.customer_logins_status(),
  public.herd_vs_round(date, date)
  to authenticated;

-- The customer portal: no sign-in, a session token instead.
grant execute on function
  public.portal_sign_in(text, text, text), public.portal_sign_out(text),
  public.portal_change_password(text, text, text), public.portal_home(text), public.portal_deliveries(text, date),
  public.portal_bills(text), public.portal_vessels(text), public.portal_pause(text, text, date, date, text, date[], text),
  public.portal_resume(text), public.portal_remove_pause(text, uuid), public.portal_request(text, date, text, numeric, jsonb, text),
  public.portal_withdraw_request(text, uuid)
  to anon, authenticated;

-- The API never needs these, and TRUNCATE would pass by row level security.
revoke truncate, trigger, references on all tables in schema public from public, anon, authenticated;
