/*
 * dairee.skifi.co: the plain pages, the Dairee web app, and the door to the API.
 *
 * /                         the front page
 * /privacy, /terms, /support, /delete-account
 * /app/...                  the web app (the same Flutter app as on the phones)
 * /app/sw.js                the service worker: keeps the app's shell so it
 *                           opens offline, and never touches the API
 * /login                    to the app
 * /c/<farm>                 a farm's customers: to the app, customer sign-in
 * /rest/v1, /auth/v1, /functions/v1, /storage/v1, /platform   passed to the API
 *
 * Plain Node, no packages. Text goes out compressed (brotli or gzip).
 */
import { createServer } from 'node:http';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { Readable } from 'node:stream';
import zlib from 'node:zlib';

const ROOT = path.resolve(process.env.SITE_ROOT || path.join(import.meta.dirname, '..', 'web'));
const APP = path.resolve(process.env.APP_ROOT || path.join(import.meta.dirname, '..', 'app', 'build', 'web'));
const API = (process.env.API_INTERNAL || 'http://dairee-api:8000').replace(/\/$/, '');
const PORT = Number(process.env.PORT || 8000);
const ORIGIN = (process.env.SITE_URL || 'https://dairee.skifi.co').replace(/\/$/, '');
const HOST = new URL(ORIGIN).host;
const MOVED = new Set([`www.${HOST}`, ...(process.env.OLD_HOSTS || '').split(',')]
  .map((h) => h.trim().toLowerCase()).filter((h) => h && h !== HOST));

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.webp': 'image/webp', '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.txt': 'text/plain; charset=utf-8', '.wasm': 'application/wasm', '.map': 'application/json',
  '.webmanifest': 'application/manifest+json', '.bin': 'application/octet-stream', '.frag': 'text/plain; charset=utf-8',
};
const TEXT = new Set(['.html', '.js', '.mjs', '.css', '.json', '.svg', '.txt', '.webmanifest', '.wasm', '.ttf', '.otf', '.frag']);
const API_PATHS = /^\/(rest|auth|functions|storage)\/v1(\/|$)|^\/platform\//;
const SECURITY = {
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(), microphone=(), geolocation=()',
};
const CSP = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; " +
  "connect-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const read = (rel) => readFileSync(path.join(ROOT, rel), 'utf8');

function encodingFor(req) {
  const a = String(req.headers['accept-encoding'] || '');
  return /\bbr\b/.test(a) ? 'br' : /\bgzip\b/.test(a) ? 'gzip' : null;
}
function squeeze(buf, enc, best) {
  return enc === 'br'
    ? zlib.brotliCompressSync(buf, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: best ? 10 : 5, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length } })
    : zlib.gzipSync(buf, { level: best ? 9 : 6 });
}

/* Pages link /assets files with ?v=<hash of the file>, so browsers keep them
   for a year and still pick up a change straight away. */
const ver = new Map();
function verOf(rel) {
  const f = path.join(ROOT, rel);
  let st;
  try { st = statSync(f); } catch { return null; }
  const hit = ver.get(rel);
  if (hit && hit.m === st.mtimeMs) return hit.v;
  const v = createHash('sha1').update(readFileSync(f)).digest('hex').slice(0, 8);
  ver.set(rel, { m: st.mtimeMs, v });
  return v;
}
const stampAssets = (html) => html.replace(/(href|src)="(\/assets\/[\w./-]+\.(?:js|css|png|jpg|webp|svg|woff2))"/g, (all, attr, rel) => {
  const v = verOf(rel);
  return v ? `${attr}="${rel}?v=${v}"` : all;
});

function sendBody(req, res, status, type, body, extra = {}) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body);
  const ext = Object.entries(TYPES).find(([, t]) => t === type)?.[0] ?? '';
  const enc = TEXT.has(ext) && buf.length > 1024 ? encodingFor(req) : null;
  const out = enc ? squeeze(buf, enc, false) : buf;
  res.writeHead(status, {
    ...SECURITY,
    'content-type': type,
    'content-length': String(out.length),
    ...(TEXT.has(ext) ? { vary: 'accept-encoding' } : {}),
    ...(enc ? { 'content-encoding': enc } : {}),
    ...extra,
  });
  res.end(req.method === 'HEAD' ? undefined : out);
}

/* Files, compressed once and kept, with an ETag so an unchanged file costs a
   304 and nothing more. CI compresses the large ones ahead of time
   (server/pack.mjs: name.br, name.gz next to the file); those go out as they
   are. Anything else is compressed here, quickly for a big file, since the
   server answers no one else while it compresses. */
const packed = new Map();
const SIBLING = { br: '.br', gzip: '.gz' };
function fileEntry(file, enc) {
  const st = statSync(file);
  const key = `${enc || 'raw'}:${file}`;
  const hit = packed.get(key);
  if (hit && hit.m === st.mtimeMs && hit.size === st.size) return hit;
  const raw = readFileSync(file);
  const ready = enc && existsSync(file + SIBLING[enc]) ? readFileSync(file + SIBLING[enc]) : null;
  const body = ready || (enc ? squeeze(raw, enc, raw.length < 256 * 1024) : raw);
  const etag = `"${createHash('sha1').update(raw).digest('base64url').slice(0, 20)}${enc ? `-${enc}` : ''}"`;
  const entry = { m: st.mtimeMs, size: st.size, body, etag };
  packed.set(key, entry);
  return entry;
}
function encodingOf(req, file, ext) {
  const enc = encodingFor(req);
  if (!enc) return null;
  if (existsSync(file + SIBLING[enc])) return enc;
  return TEXT.has(ext) && statSync(file).size > 1024 ? enc : null;
}
function sendFile(req, res, file, cache, extra = {}) {
  const ext = path.extname(file).toLowerCase();
  const enc = encodingOf(req, file, ext);
  const e = fileEntry(file, enc);
  const head = {
    ...SECURITY,
    'content-type': TYPES[ext] || 'application/octet-stream',
    'cache-control': cache,
    etag: e.etag,
    vary: 'accept-encoding',
    ...extra,
  };
  if (req.headers['if-none-match'] === e.etag) {
    res.writeHead(304, head);
    return res.end();
  }
  res.writeHead(200, { ...head, 'content-length': String(e.body.length), ...(enc ? { 'content-encoding': enc } : {}) });
  res.end(req.method === 'HEAD' ? undefined : e.body);
}

/** A plain page (privacy, terms, support) in the Dairee shell. */
function shell(title, body) {
  return stampAssets(`<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="Dairee: run a dairy farm. The milk round, customers, bills and the herd.">
<meta name="theme-color" content="#F7F9FC">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/assets/brand/touch-180.png">
<link rel="stylesheet" href="/assets/site.css">
</head>
<body class="plain">
<header class="bar"><a class="brand" href="/"><img src="/assets/brand/icon-64.png" alt="" width="34" height="34">Dairee</a><a class="btn btn--small" href="/app/">Open Dairee</a></header>
<main class="doc">
${body}
</main>
${footer()}
</body>
</html>`);
}
const footer = () => `<footer class="foot"><p><a href="/privacy">Privacy</a><a href="/terms">Terms</a><a href="/support">Support</a><a href="/delete-account">Delete an account</a></p><p>Made by <a href="https://skifi.co" target="_blank" rel="noopener">SkiFi</a></p></footer>`;

const PAGES = {
  '/privacy': ['Privacy | Dairee', 'pages/privacy.html'],
  '/terms': ['Terms | Dairee', 'pages/terms.html'],
  '/support': ['Support | Dairee', 'pages/support.html'],
  '/delete-account': ['Deleting an account | Dairee', 'pages/delete-account.html'],
};

// ---------------------------------------------------------------- the web app

/* The service worker keeps this build's files under a cache named for the
   build, so a new release replaces the old shell in one go. It answers only
   for the app's own files: anything under /rest, /auth or /functions goes to
   the network every time. A cached bill is a wrong bill.

   It keeps what this browser uses, not every file of the build: the build
   carries several CanvasKit engines (about 30 MB in all) and a browser uses
   one. The page sets it up once the app is running and then tells it which
   files it used, which come from the browser's own cache (a 304 each), so the
   first visit spends its connection on the app alone. */
let swCache = { at: 0, body: '' };
function serviceWorker() {
  const index = path.join(APP, 'index.html');
  if (!existsSync(index)) return '';
  const st = statSync(index);
  if (swCache.at === st.mtimeMs) return swCache.body;
  const files = [];
  const walk = (dir, rel) => {
    for (const name of readdirSync(dir)) {
      const f = path.join(dir, name);
      const r = rel ? `${rel}/${name}` : name;
      if (statSync(f).isDirectory()) { walk(f, r); continue; }
      if (/^(sw\.js|flutter_service_worker\.js|version\.json|\.last_build_id|NOTICES)$/.test(name) || /\.(map|br|gz|symbols)$/.test(r)) continue;
      files.push(`/app/${r}`);
    }
  };
  walk(APP, '');
  const hash = createHash('sha1');
  for (const f of files.sort()) {
    const st2 = statSync(path.join(APP, f.slice(5)));
    hash.update(`${f}:${st2.size}:${st2.mtimeMs}`);
  }
  const version = hash.digest('hex').slice(0, 12);
  const known = ['/app/', ...files.filter((f) => f !== '/app/index.html')];
  // Every visit needs these. The engine is kept once the browser has used it.
  const core = known.filter((f) => !f.startsWith('/app/canvaskit/'));
  const body = `// Dairee's service worker, build ${version}.
const CACHE = 'dairee-shell-${version}';
const KNOWN = new Set(${JSON.stringify(known)});
const CORE = ${JSON.stringify(core)};
const API = /^\\/(rest|auth|functions|storage)\\/v1(\\/|$)|^\\/platform\\//;
const keep = (c, paths) => Promise.all(paths.map((p) => c.match(p).then((hit) => hit || c.add(p)).catch(() => {})));
self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(CACHE);
    await c.addAll(CORE);
    // What the last build kept for this browser (its engine) is kept again.
    // Only from a shell cache: the older caches held every engine.
    const before = new Set();
    for (const k of await caches.keys()) {
      if (!k.startsWith('dairee-shell-') || k === CACHE) continue;
      for (const r of await (await caches.open(k)).keys()) before.add(new URL(r.url).pathname);
    }
    await keep(c, [...before].filter((p) => KNOWN.has(p)));
    await self.skipWaiting();
  })());
});
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k.startsWith('dairee-') && k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});
// The page lists the files it used.
self.addEventListener('message', (e) => {
  const used = e.data && Array.isArray(e.data.keep) ? e.data.keep : [];
  const paths = [...new Set(used.map((u) => { try { return new URL(u, location.href).pathname; } catch { return ''; } }))].filter((p) => KNOWN.has(p));
  e.waitUntil(caches.open(CACHE).then((c) => keep(c, paths)));
});
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin || API.test(url.pathname) || !url.pathname.startsWith('/app/')) return;
  if (req.mode === 'navigate') {
    // The page itself: the network first, the kept shell when offline.
    e.respondWith(fetch(req).catch(() => caches.match('/app/')));
    return;
  }
  if (!KNOWN.has(url.pathname)) return;
  e.respondWith(caches.open(CACHE).then(async (c) => {
    const hit = await c.match(req, { ignoreSearch: true });
    if (hit) return hit;
    const res = await fetch(req);
    if (res.status === 200) c.put(url.pathname, res.clone()).catch(() => {});
    return res;
  }));
});
`;
  swCache = { at: st.mtimeMs, body };
  return body;
}

function serveApp(req, res, p) {
  if (!existsSync(path.join(APP, 'index.html'))) {
    return sendBody(req, res, 503, TYPES['.html'], shell('Dairee', '<h1>One moment</h1><p>The app is being updated. Try again in a minute.</p>'),
      { 'cache-control': 'no-store', 'retry-after': '30' });
  }
  if (p === '/app/sw.js') {
    return sendBody(req, res, 200, TYPES['.js'], serviceWorker(), { 'cache-control': 'no-cache', 'service-worker-allowed': '/app/' });
  }
  let rel;
  try { rel = decodeURIComponent(p.slice('/app/'.length)); } catch { rel = ''; }
  const f = path.resolve(APP, rel || 'index.html');
  const inside = f === APP || f.startsWith(APP + path.sep);
  const extra = { 'x-robots-tag': 'noindex', 'x-frame-options': 'DENY' };
  if (inside && rel && existsSync(f) && statSync(f).isFile()) {
    // Flutter's file names do not change between builds, so every file is
    // checked again on use (a cheap 304 when nothing changed).
    return sendFile(req, res, f, 'no-cache', extra);
  }
  // Any other address inside the app is a screen of the app.
  return sendFile(req, res, path.join(APP, 'index.html'), 'no-cache', extra);
}

// ---------------------------------------------------------------- the API

/* expect: Windows PowerShell sends "Expect: 100-continue", which fetch refuses to pass on. */
const HOP = new Set(['connection', 'keep-alive', 'proxy-connection', 'transfer-encoding', 'upgrade', 'te', 'trailer', 'host', 'content-length', 'expect']);
async function proxy(req, res) {
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) {
    if (HOP.has(k) || v == null) continue;
    headers.set(k, Array.isArray(v) ? v.join(', ') : v);
  }
  headers.set('x-forwarded-for', String(req.headers['x-forwarded-for'] || req.socket.remoteAddress || ''));
  headers.set('x-forwarded-proto', String(req.headers['x-forwarded-proto'] || 'https'));
  headers.set('x-forwarded-host', String(req.headers.host || ''));
  const hasBody = !['GET', 'HEAD'].includes(req.method);
  let up;
  try {
    up = await fetch(API + req.url, {
      method: req.method, headers, redirect: 'manual',
      body: hasBody ? Readable.toWeb(req) : undefined,
      duplex: hasBody ? 'half' : undefined,
    });
  } catch (e) {
    console.error('api unreachable', e.message);
    res.writeHead(502, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    return res.end('{"message":"The Dairee server is starting up. Try again in a moment."}');
  }
  const out = { 'cache-control': 'no-store' };
  up.headers.forEach((v, k) => { if (!HOP.has(k) && k !== 'content-encoding') out[k] = v; });
  const len = up.headers.get('content-length');
  const enc = /json|text/.test(up.headers.get('content-type') || '') && !(len != null && Number(len) < 1024) ? encodingFor(req) : null;
  if (enc) {
    delete out['content-length'];
    out['content-encoding'] = enc;
    out.vary = out.vary ? `${out.vary}, accept-encoding` : 'accept-encoding';
  }
  res.writeHead(up.status, out);
  if (!up.body || req.method === 'HEAD') return res.end();
  const from = Readable.fromWeb(up.body);
  if (!enc) return from.pipe(res);
  const z = enc === 'br' ? zlib.createBrotliCompress({ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 4 } }) : zlib.createGzip({ level: 5 });
  from.pipe(z).pipe(res);
}

// ---------------------------------------------------------------- the server

function notFound(req, res) {
  sendBody(req, res, 404, TYPES['.html'], shell('Not found | Dairee', '<h1>Nothing here</h1><p><a href="/">Back to Dairee</a></p>'),
    { 'cache-control': 'no-store', 'x-robots-tag': 'noindex', 'content-security-policy': CSP });
}
function redirect(res, to, permanent = false) {
  res.writeHead(permanent ? 301 : 302, { location: to, 'cache-control': permanent ? 'public, max-age=86400' : 'no-store' });
  res.end();
}

async function handle(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  if (p === '/health') return sendBody(req, res, 200, TYPES['.json'], '{"ok":true}', { 'cache-control': 'no-store' });
  if (API_PATHS.test(p)) return proxy(req, res);
  const host = String(req.headers.host || '').toLowerCase().replace(/:\d+$/, '');
  if (MOVED.has(host) && (req.method === 'GET' || req.method === 'HEAD')) return redirect(res, ORIGIN + req.url, true);
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { allow: 'GET, HEAD' });
    return res.end();
  }

  if (p === '/app') return redirect(res, `/app/${url.search}`, true);
  if (p.startsWith('/app/')) return serveApp(req, res, p);
  if (p === '/login' || p === '/login/') return redirect(res, '/app/');
  const farm = p.match(/^\/c(?:\/([a-z0-9-]{1,40}))?\/?$/);
  if (farm) return redirect(res, `/app/?customer=${farm[1] ? encodeURIComponent(farm[1]) : '1'}`);

  if (p === '/') {
    return sendBody(req, res, 200, TYPES['.html'], stampAssets(read('home.html')),
      { 'cache-control': 'public, max-age=300', 'content-security-policy': CSP, 'x-frame-options': 'DENY' });
  }
  const page = PAGES[p.replace(/\/$/, '')];
  if (page) {
    return sendBody(req, res, 200, TYPES['.html'], shell(page[0], read(page[1])),
      { 'cache-control': 'public, max-age=300', 'content-security-policy': CSP, 'x-frame-options': 'DENY' });
  }
  if (p === '/robots.txt') return sendBody(req, res, 200, TYPES['.txt'], 'User-agent: *\nDisallow: /app/\nDisallow: /c/\n', { 'cache-control': 'public, max-age=3600' });
  if (p === '/favicon.ico') return sendFile(req, res, path.join(ROOT, 'favicon.ico'), 'public, max-age=86400');
  if (p.startsWith('/assets/')) {
    let rel;
    try { rel = decodeURIComponent(p); } catch { return notFound(req, res); }
    const f = path.resolve(ROOT, `.${rel}`);
    if (!f.startsWith(path.join(ROOT, 'assets') + path.sep) || !existsSync(f) || !statSync(f).isFile()) return notFound(req, res);
    return sendFile(req, res, f, url.searchParams.has('v') ? 'public, max-age=31536000, immutable' : 'public, max-age=3600');
  }
  return notFound(req, res);
}

const server = createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.error('request failed', req.url, e);
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'text/plain' });
    res.end('Something went wrong.');
  });
});
// Traefik keeps connections to us open for up to 90 seconds. Node closes an
// idle one after 5 by default, and a request Traefik sends down a connection
// at the moment Node closes it comes back as a 502 (seen on the first open of
// the web app, when many files load at once). So Node waits longer than Traefik.
server.keepAliveTimeout = 120_000;
server.headersTimeout = 125_000;
server.listen(PORT, () => console.log(`dairee site on :${PORT}, api ${API}, app ${APP}`));
