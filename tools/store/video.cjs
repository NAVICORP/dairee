/* Dairee's intro video for YouTube (and the Play listing): 1920 x 1080,
   30 fps, about 37 seconds. The logo, then the app in a phone with one line
   per scene, then an end card with the web address.

   node tools/store/video.cjs <folder with the app screens> <work folder>
   python3 tools/store/music.py <work folder>/music.wav 36.8
   ffmpeg -framerate 30 -i <work>/frames/f%05d.jpg -i <work>/music.wav \
     -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k \
     -shortest -movflags +faststart dairee-intro.mp4

   The app screens are the ones tools/store/make.cjs uses (the `screens`
   branch). They have no status bar, so their edges are stretched to make
   room for one, as in the store pictures. ONLY=1.5,6,12 renders just the
   frames nearest those seconds, for a quick look. Also writes the YouTube
   thumbnail (1280 x 720) to <work folder>/thumbnail.png. */
const { chromium } = require('playwright');
const fs = require('fs');
const path = require('path');
const { device, css, url, BAR, FONTS, ICON } = require('./make.cjs');

const [, , SHOTS = 'shots', WORK = 'video'] = process.argv;
const W = 1920, H = 1080, FPS = 30;
const SITE = 'dairee.skifi.co';

/* scenes: start, end (seconds), caption, subline, screens (crossfaded in order) */
const SCENES = [
  { a: 3.2, b: 8.2, cap: 'Both rounds <b>at a glance</b>', sub: 'Morning and evening, what is packed and what is left.', shots: ['09-today'] },
  { a: 8.2, b: 13.4, cap: 'Pack it, then <b>tick every door</b>', sub: 'Litres, bottles to collect and who paused.', shots: ['13-packing', '10-round'] },
  { a: 13.4, b: 18.4, cap: 'Pause or change <b>any day</b>', sub: 'Customers ask in the app and you approve.', shots: ['20-customers', '24-pause-sheet', '30-changes'] },
  { a: 18.4, b: 23.2, cap: 'See who <b>still has to pay</b>', sub: 'Bills every month, payments in one tap.', shots: ['41-payments', '43-bill'] },
  { a: 23.2, b: 28.0, cap: 'Customers see <b>their own milk</b>', sub: 'Deliveries, bills and a code to pay, on their phone.', shots: ['90-portal-home', '92-portal-changes'] },
  { a: 28.0, b: 32.6, cap: 'Milk from <b>every cow</b>', sub: 'Milking, health and breeding for the whole herd.', shots: ['60-herd', '61-cow'] },
];
const END = 36.8;

/* phone: iPhone 16 Plus proportions, as in make.cjs */
const devW = 420, bez = devW * 0.0424, scrW = devW - bez * 2, scrH = scrW * 932 / 430;
const inner = scrW * 55 / 430, rad = inner + bez, pt = scrW / 430, devH = scrH + bez * 2;

const shotList = [];
SCENES.forEach((s, i) => s.shots.forEach((f, j) => {
  const file = path.join(SHOTS, `${f}.png`);
  if (!fs.existsSync(file)) throw new Error(`missing ${f}.png in ${SHOTS}`);
  shotList.push({ i, j, src: url(file) });
}));

const html = `<!doctype html><html><head><meta charset="utf-8"><style>${css(W)}
html,body{height:${H}px}
body{color:#fff;position:relative;
  background:radial-gradient(1500px 1100px at 78% 12%,#1D4E9E 0%,#0A2556 55%,#061535 100%)}
.glow{position:absolute;inset:0;background:radial-gradient(900px 700px at 8% 100%,rgba(125,196,255,.14),transparent 70%),radial-gradient(700px 600px at 72% 60%,rgba(72,149,238,.26),transparent 70%)}
.logo{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:34px}
.logo .row{display:flex;align-items:center;gap:34px}
.logo img{width:190px;height:190px;border-radius:46px;box-shadow:0 30px 60px -24px rgba(0,0,0,.75)}
.logo .word{font-family:"Bricolage";font-weight:700;font-size:180px;line-height:1}
.logo p{font-size:54px;font-weight:600;color:rgba(211,227,251,.92)}
.logo p b,.cap b{color:#7DC4FF;font-weight:700}
.copy{position:absolute;left:170px;width:860px;top:0;bottom:0}
.cap{position:absolute;left:0;right:0;bottom:calc(50% + 6px);font-family:"Bricolage";font-weight:700;font-size:96px;line-height:1.04;text-wrap:balance}
.sub{position:absolute;left:0;right:0;top:calc(50% + 34px);font-size:40px;font-weight:600;color:rgba(211,227,251,.88);line-height:1.3}
.dev{position:absolute;left:${1340 - devW / 2}px;top:${(H - devH) / 2}px;width:${devW}px;height:${devH}px;border-radius:${rad}px;background:#04070D;padding:${bez}px;
  box-shadow:inset 0 0 0 ${devW * 0.0055}px #5B6578,inset 0 0 0 ${devW * 0.013}px #1A2130,0 0 0 2px rgba(0,0,0,.4),0 50px 100px -28px rgba(0,0,0,.75)}
.dev::before,.dev::after{content:"";position:absolute;width:${devW * 0.011}px;background:#2C3444}
.dev::before{right:${-devW * 0.009}px;top:27%;height:11.5%;border-radius:0 4px 4px 0}
.dev::after{left:${-devW * 0.009}px;top:17%;height:22%;border-radius:4px 0 0 4px;
  background:linear-gradient(#2C3444 0 15%,transparent 15% 29%,#2C3444 29% 60%,transparent 60% 69%,#2C3444 69% 100%)}
.scr{position:relative;width:${scrW}px;height:${scrH}px;border-radius:${inner}px;overflow:hidden;background:#F7F9FC;color:#0B1B33}
.scr canvas{position:absolute;inset:0;width:100%;height:100%;opacity:0}
.island{position:absolute;left:50%;top:${11 * pt}px;width:${126 * pt}px;height:${37.3 * pt}px;margin-left:${-63 * pt}px;border-radius:99px;background:#000;z-index:3}
.bar{position:absolute;left:0;right:0;top:0;height:${59 * pt}px;display:flex;align-items:center;justify-content:space-between;padding:0 ${31 * pt}px 0 ${46 * pt}px;
  font-family:-apple-system,"SF Pro Text","Manrope",sans-serif;font-weight:600;font-size:${17 * pt}px;z-index:2}
.sys{display:flex;gap:${6 * pt}px;align-items:center}
.sys svg{display:block;height:${11.5 * pt}px;width:auto;fill:currentColor}
.sys .bat{height:${13 * pt}px}
.sys .wifi{fill:none;stroke:currentColor}
.home{position:absolute;left:50%;bottom:${8 * pt}px;width:${144 * pt}px;height:${5 * pt}px;margin-left:${-72 * pt}px;border-radius:9px;background:#0B1B33;z-index:2}
.end{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:30px;opacity:0}
.end .row{display:flex;align-items:center;gap:30px}
.end img{width:150px;height:150px;border-radius:36px;box-shadow:0 26px 50px -20px rgba(0,0,0,.75)}
.end .word{font-family:"Bricolage";font-weight:700;font-size:140px;line-height:1}
.end p{font-size:46px;font-weight:600;color:rgba(211,227,251,.92)}
.end p b{color:#7DC4FF}
.end .url{display:inline-block;margin-top:6px;padding:14px 34px;border-radius:99px;background:#7DC4FF;color:#061535;font-weight:800;font-size:44px}
</style></head><body><div class="glow"></div>
<div class="logo" id="logo"><div class="row"><img id="logoIcon" src="${url(ICON)}"><span class="word" id="logoWord">Dairee</span></div><p id="logoSub">Run your dairy <b>from your phone</b></p></div>
<div class="copy">${SCENES.map((s, i) => `<h1 class="cap" id="cap${i}">${s.cap}</h1><p class="sub" id="sub${i}">${s.sub}</p>`).join('')}</div>
<div class="dev" id="dev"><div class="scr">${shotList.map((s, k) => `<canvas id="shot${k}" width="${Math.round(scrW * 2)}" height="${Math.round(scrH * 2)}"></canvas>`).join('')}
${BAR}<i class="island"></i><i class="home"></i></div></div>
<div class="end" id="end"><div class="row"><img src="${url(ICON)}"><span class="word">Dairee</span></div><p>Run your dairy <b>from your phone</b></p><span class="url">${SITE}</span></div>
<script>
const SC = ${JSON.stringify(SCENES.map((s) => ({ a: s.a, b: s.b, n: s.shots.length })))};
const SHOTS = ${JSON.stringify(shotList)};
const END = ${END};
/* each screen goes on its canvas below a status bar; the screen's own edges
   are stretched into the room the status bar and home bar take */
window.ready = Promise.all(SHOTS.map((s, k) => new Promise((done) => {
  const img = new Image();
  img.onload = () => {
    const cv = document.getElementById('shot' + k), g = cv.getContext('2d');
    const W = cv.width, H = cv.height, top = Math.round(${54 * pt * 2}), bottom = Math.round(${20 * pt * 2});
    const iw = img.naturalWidth, ih = img.naturalHeight;
    const h = H - top - bottom, w = Math.round(iw * h / ih), x = Math.round((W - w) / 2);
    g.imageSmoothingQuality = 'high';
    g.drawImage(img, 0, 0, iw, ih, x, top, w, h);
    g.drawImage(img, 0, 0, iw, 1, x, 0, w, top);
    g.drawImage(img, 0, ih - 1, iw, 1, x, top + h, w, bottom);
    g.drawImage(img, 0, 0, 1, ih, 0, top, x, h);
    g.drawImage(img, iw - 1, 0, 1, ih, x + w, top, W - x - w, h);
    g.drawImage(img, 0, 0, 1, 1, 0, 0, x, top);
    g.drawImage(img, iw - 1, 0, 1, 1, x + w, 0, W - x - w, top);
    g.drawImage(img, 0, ih - 1, 1, 1, 0, top + h, x, bottom);
    g.drawImage(img, iw - 1, ih - 1, 1, 1, x + w, top + h, W - x - w, bottom);
    done();
  };
  img.src = s.src;
})));
const clamp = (x) => Math.max(0, Math.min(1, x));
const ease = (x) => { x = clamp(x); return x < .5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; };
const out = (x) => { x = clamp(x); return 1 - Math.pow(1 - x, 3); };
const $ = (id) => document.getElementById(id);
function fadeWin(t, a, b, fi, fo) { return Math.min(out((t - a) / fi), 1 - ease((t - (b - fo)) / fo)); }
window.render = (t) => {
  /* logo */
  $('logo').style.opacity = Math.min(out((t - 0.2) / 0.8), 1 - ease((t - 2.6) / 0.6));
  const pop = out((t - 0.2) / 0.9);
  $('logoIcon').style.transform = 'scale(' + (0.6 + 0.4 * pop) + ') rotate(' + (-12 * (1 - pop)) + 'deg)';
  $('logoWord').style.transform = 'translateX(' + (40 * (1 - out((t - 0.45) / 0.9))) + 'px)';
  $('logoWord').style.opacity = out((t - 0.45) / 0.7);
  $('logoSub').style.opacity = out((t - 1.0) / 0.7);
  $('logoSub').style.transform = 'translateY(' + (24 * (1 - out((t - 1.0) / 0.8))) + 'px)';
  $('logo').style.transform = 'scale(' + (1 + 0.04 * ease((t - 2.4) / 0.8)) + ')';
  /* phone: rises in at the first scene, leaves before the end card */
  const first = SC[0].a, last = SC[SC.length - 1].b;
  const pin = out((t - (first - 0.4)) / 1.0), pout = ease((t - (last - 0.5)) / 0.8);
  $('dev').style.opacity = Math.min(pin, 1 - pout);
  $('dev').style.transform = 'translateY(' + (140 * (1 - pin) + 120 * pout) + 'px) rotate(' + (4 * (1 - pin)) + 'deg)';
  /* captions */
  SC.forEach((s, i) => {
    const fi = i === 0 ? 0.9 : 0.6, fo = 0.45;
    const enter = 1 - out((t - s.a) / 0.8), leave = ease((t - (s.b - fo)) / fo);
    $('cap' + i).style.opacity = fadeWin(t, s.a, s.b, fi, fo);
    $('cap' + i).style.transform = 'translateY(' + (40 * enter - 30 * leave) + 'px)';
    $('sub' + i).style.opacity = fadeWin(t, s.a + 0.25, s.b, 0.7, fo);
    $('sub' + i).style.transform = 'translateY(' + (30 * (1 - out((t - s.a - 0.25) / 0.8)) - 30 * leave) + 'px)';
  });
  /* screens: crossfade between scenes, and between the screens inside a scene */
  SHOTS.forEach((s, k) => {
    const sc = SC[s.i];
    const len = (sc.b - sc.a) / sc.n;
    const a = sc.a + s.j * len, b = a + len;
    const isFirst = s.i === 0 && s.j === 0;
    const isLast = s.i === SC.length - 1 && s.j === sc.n - 1;
    const o = Math.min(isFirst ? (t >= a - 1 ? 1 : 0) : out((t - (a - 0.2)) / 0.45), isLast ? 1 : 1 - clamp((t - (b + 0.25)) / 0.01));
    $('shot' + k).style.opacity = o;
  });
  /* end card */
  const eo = out((t - (last + 0.2)) / 0.9);
  $('end').style.opacity = Math.min(eo, 1 - ease((t - (END - 0.6)) / 0.6));
  $('end').style.transform = 'translateY(' + (30 * (1 - eo)) + 'px)';
};
</script></body></html>`;

/* YouTube thumbnail, 1280 x 720: the name and the line on the left, the round in a phone on the right */
function thumbnail() {
  const d = device(380, path.join(SHOTS, '10-round.png'), 830, 70, '0 0 0 1px rgba(0,0,0,.4),0 40px 80px -20px rgba(0,0,0,.7)', 'thumb', 'transform:rotate(6deg);transform-origin:50% 0');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${css(1280)}
  body{height:720px;position:relative;color:#fff;overflow:hidden;
    background:radial-gradient(1000px 760px at 78% 15%,#1D4E9E 0%,#0A2556 58%,#061535 100%)}
  .glow{position:absolute;inset:0;background:radial-gradient(560px 420px at 0% 100%,rgba(125,196,255,.18),transparent 70%)}
  .copy{position:absolute;left:76px;top:0;bottom:0;width:700px;display:flex;flex-direction:column;justify-content:center;gap:30px}
  .mark{display:flex;align-items:center;gap:24px}
  .mark img{width:120px;height:120px;border-radius:30px;box-shadow:0 18px 36px -16px rgba(0,0,0,.7)}
  .mark span{font-family:"Bricolage";font-weight:700;font-size:112px;line-height:1}
  h1{font-family:"Bricolage";font-weight:700;font-size:84px;line-height:1.02;text-wrap:balance}
  h1 b{color:#7DC4FF;font-weight:700}
  ${d.css}
  </style></head><body><div class="glow"></div>
  <div class="copy"><div class="mark"><img src="${url(ICON)}"><span>Dairee</span></div><h1>Run your dairy <b>from your phone</b></h1></div>
  ${d.html}</body></html>`;
}

(async () => {
  const frames = path.join(WORK, 'frames');
  fs.mkdirSync(frames, { recursive: true });
  const browser = await chromium.launch();

  const tp = await browser.newPage({ viewport: { width: 1280, height: 720 }, deviceScaleFactor: 1 });
  fs.writeFileSync(path.join(WORK, 'thumbnail.html'), thumbnail());
  await tp.goto('file://' + path.resolve(WORK, 'thumbnail.html'));
  await tp.evaluate(() => document.fonts.ready);
  await tp.waitForFunction(() => (window.drawn || 0) >= 1);
  await tp.waitForTimeout(150);
  await tp.screenshot({ path: path.join(WORK, 'thumbnail.png') });
  await tp.close();
  console.log('made', path.join(WORK, 'thumbnail.png'));

  const f = path.resolve(WORK, 'video.html');
  fs.writeFileSync(f, html);
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  await page.goto('file://' + f);
  await page.evaluate(() => document.fonts.ready);
  await page.evaluate(() => window.ready);
  await page.waitForTimeout(300);
  const only = process.env.ONLY ? process.env.ONLY.split(',').map(Number) : null;
  const total = Math.round(END * FPS);
  for (let n = 0; n < total; n++) {
    const t = n / FPS;
    if (only && !only.some((x) => Math.abs(x - t) < 0.5 / FPS)) continue;
    await page.evaluate((t) => window.render(t), t);
    await page.screenshot({ path: path.join(frames, `f${String(n).padStart(5, '0')}.jpg`), type: 'jpeg', quality: 94 });
  }
  await browser.close();
  console.log('frames', total);
})().catch((e) => { console.error(e); process.exit(1); });
