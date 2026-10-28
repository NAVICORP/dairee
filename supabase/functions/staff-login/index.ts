// Dairee: email and password logins for staff, made by an admin.
//
// POST /functions/v1/staff-login  { action: "create" | "reset" | "remove", staff_id }
// with the admin's own sign-in and the farm in x-farm-id.
//
// 1. The database decides whether the caller may do this (staff_login_target:
//    an admin of the same farm as the person). Nothing here re-decides it.
// 2. The login itself is made at SkAuth through the admin API, with this
//    server's service key, which never leaves the server.
// 3. A plain message comes back for the office to read.
//
// Staff who sign in with WhatsApp need none of this: the code goes to their
// number, and the staff row is matched by that number.
import { SignJWT } from 'npm:jose';

const SELF = Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:8000';
const SECRET = new TextEncoder().encode(Deno.env.get('JWT_SECRET') ?? '');

type Target = { staff_id: string; name: string; email: string | null; phone: string | null; login_id: string | null; farm_name: string; by: string };

const reply = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

async function serviceToken() {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({ role: 'service_role' }).setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuedAt(now).setExpirationTime(now + 120).sign(SECRET);
}

async function call(path: string, init: { method?: string; body?: unknown; auth: string; farm?: string }) {
  const headers: Record<string, string> = { 'content-type': 'application/json', apikey: 'public', authorization: init.auth };
  if (init.farm) headers['x-farm-id'] = init.farm;
  const r = await fetch(SELF + path, { method: init.method ?? 'POST', headers, body: init.body === undefined ? undefined : JSON.stringify(init.body) });
  const text = await r.text();
  let json: unknown = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  return { ok: r.ok, status: r.status, json: json as Record<string, unknown> | null };
}

// The first four letters of the name and four digits: of the mobile number
// when there is one, otherwise picked at random. Temporary by design: the app
// asks for a new password before it shows anything.
function temporaryPassword(name: string, phone: string | null) {
  const letters = (name.replace(/[^A-Za-z]/g, '') + 'xxxx').slice(0, 4);
  const word = letters.charAt(0).toUpperCase() + letters.slice(1).toLowerCase();
  const digits = phone ? phone.replace(/\D/g, '').slice(-10).slice(0, 4) : String(crypto.getRandomValues(new Uint32Array(1))[0] % 10000).padStart(4, '0');
  return word + digits;
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return reply({ error: 'Use POST.' }, 405);
  const auth = req.headers.get('authorization') ?? '';
  const farm = req.headers.get('x-farm-id') ?? '';
  let body: { action?: string; staff_id?: string } = {};
  try { body = await req.json(); } catch { /* empty */ }
  const action = String(body.action ?? '');
  if (!['create', 'reset', 'remove'].includes(action) || !body.staff_id) return reply({ error: 'Nothing to do.' }, 400);

  // 1. May the caller do this? Asked as the caller, so the database decides.
  const t = await call('/rest/v1/rpc/staff_login_target', { auth, farm, body: { staff_id: body.staff_id } });
  if (!t.ok) return reply({ error: String(t.json?.message ?? 'Only an admin can do that.') }, t.status === 401 ? 401 : 403);
  const target = t.json as unknown as Target;
  const service = `Bearer ${await serviceToken()}`;
  const record = (loginId: string | null, temporary: boolean, note: string) =>
    call('/rest/v1/rpc/staff_login_made', { auth: service, body: { staff_id: target.staff_id, login_id: loginId, temporary, note: `${target.by}|${note}` } });

  if (action === 'create') {
    if (!target.email) return reply({ error: `Add an email for ${target.name} first. Staff with only a mobile number sign in with a WhatsApp code.` }, 400);
    if (target.login_id) return reply({ error: `${target.name} already has a login. Reset its password instead.` }, 400);
    const password = temporaryPassword(target.name, target.phone);
    const made = await call('/auth/v1/admin/users', {
      auth: service,
      body: { email: target.email, password, email_confirm: true, app_metadata: { role: 'staff' }, user_metadata: { full_name: target.name } },
    });
    if (!made.ok) {
      const msg = String(made.json?.msg ?? made.json?.message ?? '').toLowerCase();
      if (msg.includes('already') || msg.includes('registered') || made.status === 422) {
        return reply({ ok: true, existing: true, email: target.email,
          message: `${target.email} already has a SkiFi login. ${target.name} signs in with it (or with a code sent to that email).` });
      }
      return reply({ error: 'The login could not be made just now. Try again in a minute.' }, 502);
    }
    const id = String(made.json?.id ?? '');
    await record(id || null, true, `${target.name} was given an email and password login`);
    return reply({ ok: true, email: target.email, password, message: `Login made for ${target.name}.` });
  }

  if (action === 'reset') {
    if (!target.login_id) return reply({ error: `${target.name} has no Dairee login to reset. Make one first, or they can use a code.` }, 400);
    const password = temporaryPassword(target.name, target.phone);
    const r = await call(`/auth/v1/admin/users/${target.login_id}`, { method: 'PUT', auth: service, body: { password } });
    if (!r.ok) {
      if (r.status === 404) {
        await record(null, false, `${target.name}'s old login was gone`);
        return reply({ error: 'That login no longer exists. Make a new one.' }, 400);
      }
      return reply({ error: String(r.json?.msg ?? 'The password could not be reset just now.') }, 502);
    }
    await record(target.login_id, true, `${target.name}'s password was reset`);
    return reply({ ok: true, email: target.email, password, message: `New temporary password for ${target.name}.` });
  }

  // remove
  if (target.login_id) {
    const r = await call(`/auth/v1/admin/users/${target.login_id}`, { method: 'DELETE', auth: service });
    if (!r.ok && r.status !== 404) return reply({ error: String(r.json?.msg ?? 'The login could not be removed just now.') }, 502);
  }
  await record(null, false, `${target.name}'s email and password login was removed`);
  return reply({ ok: true, message: `${target.name} can no longer sign in with a password.` });
});
