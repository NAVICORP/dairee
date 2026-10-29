/* The App Store creative assets: the product page header (3840 x 1646, 21:9)
   and the search results picture (3840 x 2560, 3:2). Dairee navy, one short
   line, and the app itself in three phones.

   node tools/store/creative.cjs <folder with the app screens> <out folder>

   The app screens are the ones tools/store/make.cjs uses (the `screens`
   branch). Needs Playwright with Chromium. Apple wants the main subject near
   the centre, so the phones and the line sit in the middle and the sides are
   only background. Writes <out>/creative/header.png and search.png. */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { device, css, url } = require('./make.cjs');

const [, , SHOTS = 'shots', OUT = 'store'] = process.argv;

const pick = (name) => {
  const f = path.join(SHOTS, `${name}.png`);
  if (!fs.existsSync(f)) throw new Error(`missing ${name}.png in ${SHOTS}`);
  return f;
};

/* x is the centre, y the top, w the body width, r a tilt in degrees */
function phone(id, shot, { x, y, w, r = 0, z = 1 }) {
  return device(w, pick(shot), x - w / 2, y,
    `0 0 0 ${w * 0.002}px rgba(0,0,0,.4),0 ${w * 0.06}px ${w * 0.12}px ${-w * 0.03}px rgba(0,0,0,.7)`,
    id, `transform:rotate(${r}deg);transform-origin:50% 0;z-index:${z}`);
}

function page(W, H, title, size, top, phones) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(W)}
  body{height:${H}px;position:relative;color:#fff;
    background:radial-gradient(${W * 0.55}px ${H * 0.9}px at 50% 18%,#1D4E9E 0%,#0A2556 45%,#061535 75%,#040E26 100%)}
  .glow{position:absolute;inset:0;background:
    radial-gradient(${W * 0.22}px ${H * 0.5}px at 12% 105%,rgba(125,196,255,.16),transparent 70%),
    radial-gradient(${W * 0.22}px ${H * 0.5}px at 88% 105%,rgba(72,149,238,.28),transparent 70%)}
  h1{position:absolute;left:0;right:0;top:${top}px;margin:0 auto;max-width:${W * 0.72}px;text-align:center;font-family:"Bricolage";font-weight:700;
    font-size:${size}px;line-height:1.04;text-wrap:balance;z-index:5}
  h1 b{color:#7DC4FF;font-weight:700}
  ${phones.map((p) => p.css).join('\n')}
  </style></head><body><div class="glow"></div><h1>${title}</h1>${phones.map((p) => p.html).join('')}</body></html>`;
}

(async () => {
  const browser = await chromium.launch();
  const tmp = fs.mkdtempSync('/tmp/dairee-creative-');
  async function render(html, W, H, file, phones) {
    const p = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
    const f = path.join(tmp, 'p.html');
    fs.writeFileSync(f, html);
    await p.goto('file://' + f);
    await p.evaluate(() => document.fonts.ready);
    await p.waitForFunction((n) => (window.drawn || 0) >= n, phones);
    await p.waitForTimeout(200);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    await p.screenshot({ path: file, clip: { x: 0, y: 0, width: W, height: H } });
    await p.close();
    console.log('made', file);
  }

  /* Header, 21:9. One line on top, three phones rising from the bottom edge. */
  {
    const W = 3840, H = 1646, cx = W / 2;
    await render(page(W, H, 'Run your dairy <b>from your phone</b>', 150, 150, [
      phone('left', '09-today', { x: cx - 760, y: 640, w: 600, r: -7, z: 1 }),
      phone('right', '90-portal-home', { x: cx + 760, y: 640, w: 600, r: 7, z: 1 }),
      phone('mid', '10-round', { x: cx, y: 470, w: 700, z: 2 }),
    ]), W, H, path.join(OUT, 'creative', 'header.png'), 3);
  }

  /* Search results, 3:2. Says what the app does, shows the app. */
  {
    const W = 3840, H = 2560, cx = W / 2;
    await render(page(W, H, 'Milk rounds, bills <b>and your herd</b>', 200, 210, [
      phone('left', '10-round', { x: cx - 930, y: 1000, w: 780, r: -7, z: 1 }),
      phone('right', '60-herd', { x: cx + 930, y: 1000, w: 780, r: 7, z: 1 }),
      phone('mid', '41-payments', { x: cx, y: 780, w: 900, z: 2 }),
    ]), W, H, path.join(OUT, 'creative', 'search.png'), 3);
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
