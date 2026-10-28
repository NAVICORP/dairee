// Opens the built web app in a real browser, the way a farm would: served by
// server/site.mjs at /app/, then a customer link (/c/<farm>), then once more
// with the network gone to check the offline shell. Writes pictures to
// web-shots/ and prints what it saw as notices on the run.
//
//   node server/site.mjs &   (APP_ROOT pointing at app/build/web)
//   node .github/scripts/web_check.mjs http://127.0.0.1:8000
import { mkdirSync } from 'node:fs';
import { chromium } from 'playwright';

const base = process.argv[2] || 'http://127.0.0.1:8000';
mkdirSync('web-shots', { recursive: true });
const problems = [];
const say = (m) => console.log(`::notice title=Web app::${m}`);

const browser = await chromium.launch({ args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
const page = await context.newPage();
page.on('pageerror', (e) => problems.push(`page error: ${e.message}`));
page.on('console', (m) => {
  if (m.type() === 'error') problems.push(`console: ${m.text()}`);
});

async function ready(what) {
  // Flutter puts its view in <flutter-view> once the first frame is drawn.
  await page.waitForSelector('flutter-view', { state: 'attached', timeout: 60000 });
  await page.waitForTimeout(4000);
  const boot = await page.$('#boot');
  if (boot && (await boot.isVisible())) problems.push(`${what}: the loading screen never went away`);
}

await page.goto(`${base}/app/`, { waitUntil: 'load' });
await ready('the app');
await page.screenshot({ path: 'web-shots/web-1-app.png' });
say(`/app/ opened: "${await page.title()}"`);

// A farm's link for its customers goes to customer sign-in.
await page.goto(`${base}/c/green-meadows-dairy`, { waitUntil: 'load' });
if (!page.url().includes('/app/?customer=green-meadows-dairy')) problems.push(`the customer link went to ${page.url()}`);
await ready('the customer link');
await page.screenshot({ path: 'web-shots/web-2-customer-link.png' });
say(`a customer link opens ${new URL(page.url()).pathname}${new URL(page.url()).search}`);

// The offline shell: the service worker keeps the app itself, never the API.
const sw = await page.evaluate(async () => {
  if (!('serviceWorker' in navigator)) return 'no service worker support';
  const r = await navigator.serviceWorker.ready;
  return r.active ? r.active.scriptURL : 'not active';
});
say(`service worker: ${sw}`);
await page.reload({ waitUntil: 'load' });
await page.waitForTimeout(2000);
await context.setOffline(true);
await page.goto(`${base}/app/`, { waitUntil: 'load' }).catch((e) => problems.push(`offline: ${e.message}`));
await ready('offline').catch((e) => problems.push(`offline: ${e.message}`));
await page.screenshot({ path: 'web-shots/web-3-offline.png' });
await context.setOffline(false);

// A phone-sized window.
const phone = await browser.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
phone.on('pageerror', (e) => problems.push(`phone page error: ${e.message}`));
await phone.goto(`${base}/app/`, { waitUntil: 'load' });
await phone.waitForSelector('flutter-view', { state: 'attached', timeout: 60000 });
await phone.waitForTimeout(4000);
await phone.screenshot({ path: 'web-shots/web-4-phone.png' });

await browser.close();
// The offline visit is expected to log failed network requests for the API.
const real = problems.filter((p) => !/net::ERR_INTERNET_DISCONNECTED|Failed to load resource/.test(p));
if (real.length) {
  for (const p of real) console.log(`::error title=Web app::${p}`);
  process.exit(1);
}
say('no errors in the browser');
