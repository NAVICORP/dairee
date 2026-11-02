"""Dairee's logo: a bottle of milk with a tick, on deep navy. The round,
delivered. Drawn here as SVG, then written out as every icon the app, the
stores and the site use, so a change here reaches all of them at once.

    pip install numpy pillow playwright
    python3 tools/brand/brand.py

Writes:
- tools/brand/logo.svg                the logo as artwork, 1024 x 1024
- web/assets/brand/dairee-icon.svg    the icon with rounded corners
- web/assets/brand/dairee-mark.svg    the bottle and tick alone, for print
- the app, Android, iPhone, web app and site icons (PNG and favicon.ico)
- web/assets/brand/og.png             the picture shown when a link is shared
"""
import base64
import io
import os
import struct

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

NAVY = '#0B2A63'     # the tile, and the Android icon background
BLUE = '#1064D9'     # the cap and the tick

# ---------------------------------------------------------------- the artwork

BOTTLE = ('M412 292 L612 292 L612 334 C612 396 724 414 724 505 L724 810 '
          'C724 850 694 880 654 880 L370 880 C330 880 300 850 300 810 L300 505 '
          'C300 414 412 396 412 334 Z')
CAP = dict(x=394, y=206, w=236, h=100, r=34)
# Where the bottle and the tick sit on the 1024 board, found once by centring
# the pair: the bottle leans back a little and the tick sits over its foot.
BOTTLE_AT = 'translate(413,519) rotate(-10) scale(0.92) translate(-512,-560)'
TICK_AT = (665, 691)
TICK_R = 150

DEFS = f'''<defs>
  <radialGradient id="bg" cx="45%" cy="30%" r="78%">
    <stop offset="0" stop-color="#1F55A8"/><stop offset=".55" stop-color="{NAVY}"/><stop offset="1" stop-color="#04112B"/>
  </radialGradient>
  <linearGradient id="milk" x1="0" x2="1" y1="0" y2="0">
    <stop offset="0" stop-color="#E6EFFC"/><stop offset=".28" stop-color="#F8FBFF"/>
    <stop offset=".72" stop-color="#EEF4FD"/><stop offset="1" stop-color="#C9DAF2"/>
  </linearGradient>
  <linearGradient id="cap" x1="0" x2="0" y1="0" y2="1">
    <stop offset="0" stop-color="#4C9BFF"/><stop offset="1" stop-color="{BLUE}"/>
  </linearGradient>
  <linearGradient id="tick" x1="0" x2="0" y1="0" y2="1">
    <stop offset="0" stop-color="#4C9BFF"/><stop offset="1" stop-color="{BLUE}"/>
  </linearGradient>
  <clipPath id="bottle"><path d="{BOTTLE}"/></clipPath>
  <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="18"/></filter>
</defs>'''


def mark():
    """The bottle and the tick, on nothing."""
    cx, cy = TICK_AT
    c = CAP
    return f'''<g transform="{BOTTLE_AT}">
    <ellipse cx="512" cy="905" rx="220" ry="34" fill="#04112B" opacity=".3" filter="url(#blur)"/>
    <path d="{BOTTLE}" fill="url(#milk)"/>
    <g clip-path="url(#bottle)"><rect x="338" y="470" width="36" height="340" rx="18" fill="#FFFFFF"/></g>
    <path d="{BOTTLE}" fill="none" stroke="#FFFFFF" stroke-opacity=".75" stroke-width="6"/>
    <rect x="{c['x']}" y="{c['y']}" width="{c['w']}" height="{c['h']}" rx="{c['r']}" fill="url(#cap)"/>
    <rect x="{c['x'] + 22}" y="{c['y'] + 16}" width="{c['w'] - 44}" height="20" rx="10" fill="#FFFFFF" opacity=".32"/>
  </g>
  <g transform="translate({cx},{cy})">
    <circle r="{TICK_R}" cy="22" fill="#04112B" opacity=".35" filter="url(#blur)"/>
    <circle r="{TICK_R}" fill="url(#tick)"/>
    <circle r="{TICK_R - 3}" fill="none" stroke="#FFFFFF" stroke-opacity=".4" stroke-width="6"/>
    <path d="M-68 4 L-20 52 L72 -48" fill="none" stroke="#FFFFFF" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>
  </g>'''


def mono():
    """One colour, for Android's themed icons: the bottle with a gap cut
    round the tick, and the tick's mark cut out of its circle."""
    cx, cy = TICK_AT
    c = CAP
    return f'''<mask id="gap" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#fff"/><circle cx="{cx}" cy="{cy}" r="{TICK_R + 26}" fill="#000"/>
  </mask>
  <mask id="cut" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#fff"/>
    <path transform="translate({cx},{cy})" d="M-68 4 L-20 52 L72 -48" fill="none" stroke="#000" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>
  </mask>
  <g mask="url(#gap)"><g transform="{BOTTLE_AT}" fill="#fff">
    <path d="{BOTTLE}"/><rect x="{c['x']}" y="{c['y']}" width="{c['w']}" height="{c['h']}" rx="{c['r']}"/>
  </g></g>
  <circle cx="{cx}" cy="{cy}" r="{TICK_R}" fill="#fff" mask="url(#cut)"/>'''


def svg(size=1024, tile=True, radius=0.0, scale=1.0, flat=None, body=None):
    """The logo at `size` px. `tile` draws the navy board (or `flat`, one
    colour), `radius` rounds its corners, `scale` shrinks the bottle and tick
    towards the middle, `body` swaps in other artwork (the one-colour mark)."""
    r = f' rx="{radius * 1024:.0f}"' if radius else ''
    board = f'<rect width="1024" height="1024"{r} fill="{flat or "url(#bg)"}"/>' if tile else ''
    t = f'translate({512 - 512 * scale:.2f},{512 - 512 * scale:.2f}) scale({scale})'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}">'
            f'{DEFS}{board}<g transform="{t}">{body or mark()}</g></svg>')


# How the logo is shown: the full board, the bottle and tick at full size.
TILE = {'tile': True}
ROUND = 0.2237  # the corner of an iPhone icon, where the icon draws its own


def share_card(page):
    """The picture shown when a link to the site is shared: 1200 x 630, the
    icon and the line from the top of the front page, on navy."""
    def font(name):
        with open(os.path.join(ROOT, 'web/assets/fonts', name), 'rb') as f:
            return 'data:font/woff2;base64,' + base64.b64encode(f.read()).decode()
    page.set_viewport_size({'width': 1200, 'height': 630})
    page.set_content(f"""<html><head><style>
@font-face{{font-family:B;font-weight:500 800;src:url({font('bricolage.woff2')})}}
@font-face{{font-family:M;font-weight:400 800;src:url({font('manrope.woff2')})}}
body{{margin:0;width:1200px;height:630px;overflow:hidden;color:#fff;font-family:M;
  background:radial-gradient(900px 600px at 85% 0%,#1A4A97,#071C42 60%,#04112B)}}
.in{{position:absolute;left:96px;top:96px;right:96px}}
svg{{display:block;border-radius:34px;box-shadow:0 30px 60px -30px rgba(0,0,0,.7),0 0 0 1px rgba(255,255,255,.12)}}
h1{{font-family:B;font-weight:700;font-size:84px;line-height:1;margin:44px 0 0;letter-spacing:0}}
p{{font-size:30px;font-weight:600;color:#D3E3FB;margin:26px 0 0;letter-spacing:0}}
</style></head><body><div class="in">{svg(150, **TILE)}<h1>Run your dairy<br>from your phone.</h1>
<p>dairee.skifi.co</p></div></body></html>""")
    page.evaluate('document.fonts.ready')
    page.wait_for_timeout(300)
    path = os.path.join(ROOT, 'web/assets/brand/og.png')
    Image.open(io.BytesIO(page.screenshot())).convert('RGB').save(path, optimize=True)
    print('web/assets/brand/og.png 1200 x 630')


def main():
    with open(os.path.join(HERE, 'logo.svg'), 'w') as f:
        f.write(svg(**TILE).replace(' width="1024" height="1024"', ''))
    with open(os.path.join(ROOT, 'web/assets/brand/dairee-icon.svg'), 'w') as f:
        f.write(svg(**TILE, radius=ROUND).replace(' width="1024" height="1024"', ''))
    with open(os.path.join(ROOT, 'web/assets/brand/dairee-mark.svg'), 'w') as f:
        f.write(svg(tile=False).replace(' width="1024" height="1024"', ''))

    out = {}

    def want(path, size, **kw):
        out[os.path.join(ROOT, path)] = (size, kw)

    # The app's own copies: the store icon, and the rounded tile it shows.
    want('app/assets/brand/icon.png', 1024, **TILE)
    want('app/assets/brand/mark.png', 512, **TILE, radius=ROUND)
    # Android: the full icon for old launchers; adaptive icons get the navy
    # board behind and the bottle and tick in front, inside the 66 of 108
    # safe circle; themed icons get the one-colour mark.
    for d, s in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        a = int(s * 108 / 48)
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher.png', s, **TILE, radius=ROUND)
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher_background.png', a, **TILE, body='<g/>')
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png', a, tile=False, scale=0.66)
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher_monochrome.png', a, tile=False, scale=0.62, body=mono())
    # iPhone: square and opaque; iOS rounds the corners itself.
    for name, s in {'20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60, '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87,
                    '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120, '60x60@2x': 120, '60x60@3x': 180,
                    '76x76@1x': 76, '76x76@2x': 152, '83.5x83.5@2x': 167, '1024x1024@1x': 1024}.items():
        want(f'app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-{name}.png', s, **TILE)
    # iPhone launch screen: the rounded tile on the app's paper colour.
    for suffix, s in {'': 96, '@2x': 192, '@3x': 288}.items():
        want(f'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage{suffix}.png', s, **TILE, radius=ROUND)
    # The web app.
    want('app/web/favicon.png', 32, **TILE, radius=ROUND)
    want('app/web/icons/mark.png', 192, **TILE, radius=ROUND)
    want('app/web/icons/Icon-192.png', 192, **TILE, radius=ROUND)
    want('app/web/icons/Icon-512.png', 512, **TILE, radius=ROUND)
    want('app/web/icons/Icon-maskable-192.png', 192, **TILE, scale=0.8)
    want('app/web/icons/Icon-maskable-512.png', 512, **TILE, scale=0.8)
    want('app/web/icons/apple-touch-icon.png', 180, **TILE)
    # The site.
    want('web/assets/brand/icon-64.png', 64, **TILE, radius=ROUND)
    want('web/assets/brand/icon-128.png', 128, **TILE, radius=ROUND)
    want('web/assets/brand/touch-180.png', 180, **TILE)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()

        def render(size, **kw):
            # Drawn four times over and scaled down, so small icons stay crisp.
            big = size * 4 if size < 256 else size
            page.set_viewport_size({'width': big, 'height': big})
            page.set_content(f'<html><body style="margin:0;background:transparent">{svg(big, **kw)}</body></html>')
            png = page.screenshot(omit_background=True, clip={'x': 0, 'y': 0, 'width': big, 'height': big})
            im = Image.open(io.BytesIO(png)).convert('RGBA')
            if big != size:
                im = im.resize((size, size), Image.LANCZOS)
            # Store icons must be opaque where they have a full square board.
            return im.convert('RGB') if kw.get('tile', True) and not kw.get('radius') else im

        for path, (size, kw) in out.items():
            os.makedirs(os.path.dirname(path), exist_ok=True)
            render(size, **kw).save(path, optimize=True)
            print(os.path.relpath(path, ROOT), size)
        ico = {s: render(s, **TILE, radius=ROUND) for s in (16, 32, 48)}
        share_card(page)
        browser.close()

    blobs = []
    for s, im in ico.items():
        b = io.BytesIO()
        im.save(b, format='PNG')
        blobs.append((s, b.getvalue()))
    head = struct.pack('<HHH', 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    entries, data = b'', b''
    for s, blob in blobs:
        entries += struct.pack('<BBBBHHII', s % 256, s % 256, 0, 0, 1, 32, len(blob), offset + len(data))
        data += blob
    with open(os.path.join(ROOT, 'web/favicon.ico'), 'wb') as f:
        f.write(head + entries + data)
    print('web/favicon.ico, tools/brand/logo.svg, web/assets/brand/dairee-icon.svg, dairee-mark.svg')


def centre():
    """Prints how far the bottle and tick sit from the middle of the board,
    for setting BOTTLE_AT and TICK_AT."""
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={'width': 1024, 'height': 1024})
        page.set_content(f'<html><body style="margin:0;background:transparent">{svg(tile=False, body=mono())}</body></html>')
        a = np.array(Image.open(io.BytesIO(page.screenshot(omit_background=True))).convert('RGBA'))[..., 3]
        browser.close()
    ys, xs = np.nonzero(a > 40)
    print('box', xs.min(), ys.min(), xs.max(), ys.max(),
          'off centre by', round((xs.min() + xs.max()) / 2 - 512), round((ys.min() + ys.max()) / 2 - 512))


if __name__ == '__main__':
    import sys
    centre() if sys.argv[1:] == ['centre'] else main()
