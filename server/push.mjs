// Dairee's push sender: every few seconds it takes what the database put in
// push_outbox and sends it through Firebase Cloud Messaging to the phones in
// push_devices. Once a minute it asks the database for the round reminders.
//
// Runs as its own service (deploy/docker-compose.yml) from the same image,
// with the database's own password from the shared secrets volume. Needs
// FCM_SERVICE_ACCOUNT: the Firebase service account key (the JSON, or the
// JSON in base64). Without it the sender waits and says so in the log.

import { createRequire } from 'node:module';
import crypto from 'node:crypto';
import fs from 'node:fs';

const require = createRequire('/srv/backend/api/package.json');
const pg = require('pg');

const DB = {
  host: process.env.DB_HOST || 'db',
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME || 'dairee',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || readSecret('/secrets/db_password'),
  max: 2,
};

function readSecret(file) {
  try { return fs.readFileSync(file, 'utf8').trim(); } catch { return undefined; }
}

function serviceAccount() {
  const raw = (process.env.FCM_SERVICE_ACCOUNT || '').trim();
  if (!raw) return null;
  try {
    const text = raw.startsWith('{') ? raw : Buffer.from(raw, 'base64').toString('utf8');
    const j = JSON.parse(text);
    if (!j.client_email || !j.private_key || !j.project_id) throw new Error('missing fields');
    return j;
  } catch (e) {
    console.error('push: FCM_SERVICE_ACCOUNT is not a service account key:', e.message);
    return null;
  }
}

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

// ---------------------------------------------------------------- Google access token

let access = { token: '', until: 0 };

async function accessToken(sa) {
  if (access.token && Date.now() < access.until - 60_000) return access.token;
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  }));
  const sig = b64url(crypto.createSign('RSA-SHA256').update(`${head}.${claims}`).sign(sa.private_key));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${head}.${claims}.${sig}` }),
  });
  const j = await res.json();
  if (!j.access_token) throw new Error(`Google token: ${JSON.stringify(j).slice(0, 200)}`);
  access = { token: j.access_token, until: Date.now() + (j.expires_in || 3600) * 1000 };
  return access.token;
}

// ---------------------------------------------------------------- one message to one phone

async function send(sa, row) {
  const message = {
    token: row.token,
    notification: { title: row.title, body: row.body },
    data: { kind: row.kind || '', link: row.link || '' },
    android: {
      priority: 'high',
      notification: { channel_id: 'dairee', icon: 'ic_stat_dairee', color: '#1064D9', sound: 'default' },
    },
    apns: { payload: { aps: { sound: 'default', 'thread-id': row.kind || 'dairee' } } },
  };
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: 'POST',
    headers: { authorization: `Bearer ${await accessToken(sa)}`, 'content-type': 'application/json' },
    body: JSON.stringify({ message }),
  });
  if (res.ok) return 'sent';
  const text = await res.text();
  // The app was removed or the token was replaced: forget that phone.
  if (res.status === 404 || /UNREGISTERED|registration-token-not-registered|INVALID_ARGUMENT.*token/i.test(text)) return 'gone';
  throw new Error(`FCM ${res.status}: ${text.slice(0, 200)}`);
}

// ---------------------------------------------------------------- the loop

const pool = new pg.Pool(DB);
let warned = false;
let lastReminders = 0;

async function tick() {
  const sa = serviceAccount();
  if (!sa) {
    if (!warned) console.log('push: waiting for FCM_SERVICE_ACCOUNT; nothing is sent until it is set');
    warned = true;
    return;
  }
  if (Date.now() - lastReminders > 60_000) {
    lastReminders = Date.now();
    const r = await pool.query('select public.push_reminders() as n');
    if (r.rows[0].n > 0) console.log(`push: ${r.rows[0].n} reminders queued`);
  }
  const { rows } = await pool.query('select * from public.push_claim(50)');
  if (!rows.length) return;
  const ids = [...new Set(rows.map((r) => Number(r.id)))];
  const failed = new Map();
  let sent = 0;
  for (const row of rows) {
    if (!row.token) continue;
    try {
      const out = await send(sa, row);
      if (out === 'gone') await pool.query('select public.push_drop_device($1)', [row.token]);
      else sent++;
    } catch (e) {
      failed.set(Number(row.id), String(e.message || e).slice(0, 300));
    }
  }
  const done = ids.filter((id) => !failed.has(id));
  if (done.length) await pool.query('select public.push_done($1::bigint[])', [done]);
  for (const [id, err] of failed) await pool.query('select public.push_done($1::bigint[], $2)', [[id], err]);
  console.log(`push: ${ids.length} messages, ${sent} phones${failed.size ? `, ${failed.size} to retry` : ''}`);
}

async function loop() {
  for (;;) {
    try {
      await tick();
    } catch (e) {
      console.error('push:', e.message || e);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

console.log('push: started');
loop();
