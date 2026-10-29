/* The store pictures: each app screen in a phone on Dairee's navy with a
   short caption, for the App Store (1290 x 2796) and Google Play
   (1080 x 1920), plus the Play feature graphic (1024 x 500) and icon.

   node tools/store/make.cjs <folder with the app screens> <out folder>

   The app screens are the phone pictures CI puts on the `screens` branch
   (app/test_screens/screens_test.dart, the demo farm of tools/demo.sql):
     git worktree add /tmp/screens origin/screens
     node tools/store/make.cjs /tmp/screens store
   They have no status bar, so the screen's own edges are stretched to make
   room for one. Needs Playwright with Chromium. */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');

const [, , SHOTS = 'shots', OUT = 'store'] = process.argv;
const REPO = path.resolve(__dirname, '..', '..');
const FONTS = path.join(REPO, 'web', 'assets', 'fonts');
const ICON = path.join(REPO, 'app', 'assets', 'brand', 'icon.png');

/* order, screen, caption (the highlighted words in <b>) */
const FRAMES = [
  ['10-round', 'Tick every door <b>on the round</b>'],
  ['09-today', 'Both rounds <b>at a glance</b>'],
  ['20-customers', 'Every customer, <b>by building</b>'],
  ['24-pause-sheet', 'Pause or change <b>any day</b>'],
  ['41-payments', 'See who <b>still has to pay</b>'],
  ['90-portal-home', 'Customers see <b>their own milk</b>'],
  ['60-herd', 'Milk from <b>every cow</b>'],
];
const FEATURE = '10-round';

/* the iPhone status bar: time, signal, wifi, battery */
const BAR = '<div class="bar"><span>9:41</span><span class="sys"><svg viewBox="0 0 18 12"><rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/><rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></svg><svg class="wifi" viewBox="0 0 16 12"><path d="M1.4 4.7a9.6 9.6 0 0 1 13.2 0M3.9 7.4a6 6 0 0 1 8.2 0M6.5 10.1a2.3 2.3 0 0 1 3 0" stroke-width="1.9" stroke-linecap="round"/></svg><svg class="bat" viewBox="0 0 27 13"><rect x=".6" y=".6" width="22.8" height="11.8" rx="3.4" fill="none" stroke="currentColor" stroke-opacity=".4" stroke-width="1.2"/><rect x="2.4" y="2.4" width="19.2" height="8.2" rx="2"/><path d="M25 4.4v4.2a2.3 2.3 0 0 0 0-4.2z" opacity=".45"/></svg></span></div>';

const url = (f) => 'file://' + path.resolve(f);

function css(W) {
  return `
  @font-face{font-family:"Manrope";font-weight:400 800;src:url(${url(path.join(FONTS, 'manrope.woff2'))}) format("woff2")}
  @font-face{font-family:"Bricolage";font-weight:500 800;src:url(${url(path.join(FONTS, 'bricolage.woff2'))}) format("woff2")}
  *{margin:0;box-sizing:border-box;letter-spacing:0}
  html,body{width:${W}px;overflow:hidden}
  body{font-family:"Manrope",sans-serif;-webkit-font-smoothing:antialiased}`;
}

/* An iPhone 16 Plus, true to size: body 77.8 x 160.9 mm, screen 430 x 932
   points, bezel 3.3 mm, display corners 55 pt. The app screen is drawn on a
   canvas below a status bar; its top, bottom and side edges are stretched to
   fill the space the status bar and home bar take. */
function device(devW, shot, left, top, shadow) {
  const bez = devW * 0.0424, scrW = devW - bez * 2, scrH = scrW * 932 / 430;
  const inner = scrW * 55 / 430, rad = inner + bez, pt = scrW / 430;
  const css = `
  .dev{position:absolute;left:${left}px;top:${top}px;width:${devW}px;height:${scrH + bez * 2}px;border-radius:${rad}px;
    background:#04070D;padding:${bez}px;
    box-shadow:inset 0 0 0 ${devW * 0.0055}px #5B6578,inset 0 0 0 ${devW * 0.013}px #1A2130,${shadow}}
  .dev::before,.dev::after{content:"";position:absolute;width:${devW * 0.011}px;background:#2C3444}
  .dev::before{right:${-devW * 0.009}px;top:27%;height:11.5%;border-radius:0 4px 4px 0}
  .dev::after{left:${-devW * 0.009}px;top:17%;height:22%;border-radius:4px 0 0 4px;
    background:linear-gradient(#2C3444 0 15%,transparent 15% 29%,#2C3444 29% 60%,transparent 60% 69%,#2C3444 69% 100%)}
  .scr{position:relative;width:${scrW}px;height:${scrH}px;border-radius:${inner}px;overflow:hidden;background:#F7F9FC}
  .scr canvas{position:absolute;inset:0;width:${scrW}px;height:${scrH}px}
  .island{position:absolute;left:50%;top:${11 * pt}px;width:${126 * pt}px;height:${37.3 * pt}px;margin-left:${-63 * pt}px;border-radius:99px;background:#000}
  .bar{position:absolute;left:0;right:0;top:0;height:${59 * pt}px;display:flex;align-items:center;justify-content:space-between;padding:0 ${31 * pt}px 0 ${46 * pt}px;
    color:#0B1B33;font-family:-apple-system,"SF Pro Text","Manrope",sans-serif;font-weight:600;font-size:${17 * pt}px}
  .sys{display:flex;gap:${6 * pt}px;align-items:center}
  .sys svg{display:block;height:${11.5 * pt}px;width:auto;fill:currentColor}
  .sys .bat{height:${13 * pt}px}
  .sys .wifi{fill:none;stroke:currentColor}
  .home{position:absolute;left:50%;bottom:${8 * pt}px;width:${144 * pt}px;height:${5 * pt}px;margin-left:${-72 * pt}px;border-radius:9px;background:#0B1B33}`;
  const html = `<div class="dev"><div class="scr"><canvas id="c" width="${Math.round(scrW)}" height="${Math.round(scrH)}"></canvas>${BAR}<i class="island"></i><i class="home"></i></div></div>
  <script>
  (() => {
    const img = new Image();
    img.onload = () => {
      const cv = document.getElementById('c'), g = cv.getContext('2d');
      const W = cv.width, H = cv.height, top = Math.round(${54 * pt}), bottom = Math.round(${20 * pt});
      const iw = img.naturalWidth, ih = img.naturalHeight;
      const h = H - top - bottom, w = Math.round(iw * h / ih), x = Math.round((W - w) / 2);
      g.imageSmoothingQuality = 'high';
      g.drawImage(img, 0, 0, iw, ih, x, top, w, h);
      g.drawImage(img, 0, 0, iw, 1, x, 0, w, top);                     /* above: the top row */
      g.drawImage(img, 0, ih - 1, iw, 1, x, top + h, w, bottom);       /* below: the bottom row */
      g.drawImage(img, 0, 0, 1, ih, 0, top, x, h);                     /* sides: the edge columns */
      g.drawImage(img, iw - 1, 0, 1, ih, x + w, top, W - x - w, h);
      g.drawImage(img, 0, 0, 1, 1, 0, 0, x, top);
      g.drawImage(img, iw - 1, 0, 1, 1, x + w, 0, W - x - w, top);
      g.drawImage(img, 0, ih - 1, 1, 1, 0, top + h, x, bottom);
      g.drawImage(img, iw - 1, ih - 1, 1, 1, x + w, top + h, W - x - w, bottom);
      window.drawn = true;
    };
    img.src = ${JSON.stringify(url(shot))};
  })();
  </script>`;
  return { css, html };
}

function framePage(W, H, shot, caption) {
  const s = W / 1290;                       /* everything is laid out for 1290 wide */
  const tall = H / W > 2;                   /* App Store frames are taller than Play ones */
  const capTop = (tall ? 230 : 150) * s;
  const capSize = (tall ? 112 : 96) * s;
  const devW = (tall ? 1010 : 860) * s;
  const devTop = (tall ? 640 : 470) * s;
  const d = device(devW, shot, (W - devW) / 2, devTop, `0 0 0 ${2 * s}px rgba(0,0,0,.4),0 ${60 * s}px ${120 * s}px ${-30 * s}px rgba(0,0,0,.7)`);
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(W)}
  body{height:${H}px;position:relative;color:#fff;
    background:radial-gradient(${1400 * s}px ${1200 * s}px at 80% 8%,#1D4E9E 0%,#0A2556 55%,#061535 100%)}
  .glow{position:absolute;inset:0;background:radial-gradient(${700 * s}px ${600 * s}px at 10% 100%,rgba(125,196,255,.16),transparent 70%),radial-gradient(${600 * s}px ${500 * s}px at 85% 55%,rgba(72,149,238,.26),transparent 70%)}
  h1{position:absolute;left:${90 * s}px;right:${90 * s}px;top:${capTop}px;text-align:center;font-family:"Bricolage";font-weight:700;
    font-size:${capSize}px;line-height:1.04;text-wrap:balance}
  h1 b{color:#7DC4FF;font-weight:700}
  ${d.css}
  </style></head><body><div class="glow"></div><h1>${caption}</h1>${d.html}</body></html>`;
}

function featurePage(shot) {
  const W = 1024, H = 500;
  const d = device(300, shot, 650, 64, '0 0 0 1px rgba(0,0,0,.4),0 40px 80px -20px rgba(0,0,0,.7)');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(W)}
  body{height:${H}px;position:relative;color:#fff;overflow:hidden;
    background:radial-gradient(700px 520px at 78% 20%,#1D4E9E 0%,#0A2556 58%,#061535 100%)}
  .glow{position:absolute;inset:0;background:radial-gradient(420px 320px at 0% 100%,rgba(125,196,255,.16),transparent 70%)}
  .copy{position:absolute;left:64px;top:0;bottom:0;display:flex;flex-direction:column;justify-content:center;gap:18px;width:540px}
  .mark{display:flex;align-items:center;gap:20px}
  .mark img{width:104px;height:104px;border-radius:26px;box-shadow:0 18px 36px -16px rgba(0,0,0,.7)}
  .mark span{font-family:"Bricolage";font-weight:700;font-size:92px;line-height:1}
  p{font-size:31px;font-weight:600;color:rgba(211,227,251,.92);line-height:1.3}
  p b{color:#7DC4FF;font-weight:700}
  ${d.css}
  </style></head><body><div class="glow"></div>
  <div class="copy"><div class="mark"><img src="${url(ICON)}"><span>Dairee</span></div><p>Run your dairy <b>from your phone</b></p></div>
  ${d.html}</body></html>`;
}

(async () => {
  const pick = (name) => {
    const f = path.join(SHOTS, `${name}.png`);
    if (!fs.existsSync(f)) throw new Error(`missing ${name}.png in ${SHOTS}`);
    return f;
  };
  const tmp = fs.mkdtempSync('/tmp/dairee-store-');
  const browser = await chromium.launch();
  async function render(html, W, H, file, canvas = true) {
    const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
    const f = path.join(tmp, 'p.html');
    fs.writeFileSync(f, html);
    await page.goto('file://' + f);
    await page.evaluate(() => document.fonts.ready);
    if (canvas) await page.waitForFunction(() => window.drawn === true);
    await page.waitForTimeout(150);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    await page.screenshot({ path: file, clip: { x: 0, y: 0, width: W, height: H } });
    await page.close();
    console.log('made', file);
  }
  for (const [i, [name, caption]] of FRAMES.entries()) {
    const shot = pick(name);
    await render(framePage(1290, 2796, shot, caption), 1290, 2796, path.join(OUT, 'ios', `${i + 1}.png`));
    await render(framePage(1080, 1920, shot, caption), 1080, 1920, path.join(OUT, 'play', `${i + 1}.png`));
  }
  await render(featurePage(pick(FEATURE)), 1024, 500, path.join(OUT, 'play', 'feature.png'));
  await render(`<!doctype html><html><head><style>*{margin:0}body{width:512px;height:512px}img{display:block;width:512px;height:512px}</style></head><body><img src="${url(ICON)}"></body></html>`,
    512, 512, path.join(OUT, 'play', 'icon.png'), false);
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
