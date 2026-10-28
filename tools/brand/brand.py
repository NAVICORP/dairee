"""Dairee's logo: the D with a sprout and a field (tools/brand/logo-source.png),
traced into vector shapes once, then written out as every icon the app, the
stores and the site use, so a change here reaches all of them at once.

    pip install potracer numpy pillow playwright
    python3 tools/brand/brand.py

Writes:
- web/assets/brand/dairee-mark.svg   the logo as vector, in its two blues (for print)
- web/assets/brand/dairee-icon.svg   the logo as it is shown: white on a blue tile
- app/lib/ui/brand_mark.dart         the same shapes as Flutter paths
- the app, Android, iPhone, web app and site icons (PNG and favicon.ico)
"""
import io
import json
import os
import struct

import numpy as np
import potrace
from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(HERE, 'logo-source.png')

MAIN = '#1064D9'     # the D, the sprout and the field
LIGHT = '#4895EE'    # the path across the field
WHITE = '#FFFFFF'
PAPER = '#F7F9FC'


# ---------------------------------------------------------------- tracing

def trace():
    im = np.array(Image.open(SOURCE).convert('RGBA')).astype(int)
    r, g, a = im[..., 0], im[..., 1], im[..., 3]
    solid = a > 127
    light = solid & (r > 45) & (g > 125)
    main = solid & ~light

    def curves(mask):
        # potracer traces the False pixels, so it is handed the inverse.
        path = potrace.Bitmap(~mask).trace(turdsize=20, alphamax=1.0, opticurve=True, opttolerance=0.2)
        out = []
        for c in path:
            cmds = [('M', (c.start_point.x, c.start_point.y))]
            for s in c.segments:
                if s.is_corner:
                    cmds += [('L', (s.c.x, s.c.y)), ('L', (s.end_point.x, s.end_point.y))]
                else:
                    cmds.append(('C', (s.c1.x, s.c1.y, s.c2.x, s.c2.y, s.end_point.x, s.end_point.y)))
            out.append(cmds)
        return out

    shapes = {'main': curves(main), 'light': curves(light)}
    ys, xs = np.nonzero(solid)
    box = (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1)
    return shapes, box


def normalise(shapes, box):
    """Moves the logo into a 1000 x 1000 box, centred, keeping its proportions."""
    x0, y0, x1, y1 = box
    k = 1000 / max(x1 - x0, y1 - y0)
    dx = (1000 - (x1 - x0) * k) / 2 - x0 * k
    dy = (1000 - (y1 - y0) * k) / 2 - y0 * k
    out = {}
    for name, cs in shapes.items():
        out[name] = [[(op, tuple(round(v * k + (dx if i % 2 == 0 else dy), 2) for i, v in enumerate(vals))) for op, vals in c] for c in cs]
    return out


def path_d(curves):
    parts = []
    for c in curves:
        for op, v in c:
            pts = ' '.join(f'{v[i]:g},{v[i + 1]:g}' for i in range(0, len(v), 2))
            parts.append(f'{op}{pts}')
        parts.append('Z')
    return ' '.join(parts)


# ---------------------------------------------------------------- drawing

def svg(shapes, size, bg=None, scale=1.0, radius=0.0, fg=None):
    """The logo at `size` px, at `scale` of the canvas, on `bg` (or clear).
    With `fg`, every shape is drawn in that one colour (white on the blue
    tile: the thin gap between the field and the path then shows blue)."""
    tile = f'<rect width="1000" height="1000" rx="{radius * 1000:.0f}" fill="{bg}"/>' if bg else ''
    t = f'translate({500 - 500 * scale:.2f},{500 - 500 * scale:.2f}) scale({scale})'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000" width="{size}" height="{size}">{tile}'
            f'<g transform="{t}"><path fill-rule="evenodd" fill="{fg or MAIN}" d="{path_d(shapes["main"])}"/>'
            f'<path fill-rule="evenodd" fill="{fg or LIGHT}" d="{path_d(shapes["light"])}"/></g></svg>')


# How the logo is shown as an icon: the shapes in white on a blue tile, the
# D taking 60 of every 100 points across.
TILE = {'bg': MAIN, 'fg': WHITE, 'scale': 0.6}
ROUND = 0.24  # corners, where the icon draws its own


def share_card(page, shapes):
    """The picture shown when a link to the site is shared: 1200 x 630, the
    app icon and the line from the top of the front page, on navy."""
    import base64
    def font(name):
        with open(os.path.join(ROOT, 'web/assets/fonts', name), 'rb') as f:
            return 'data:font/woff2;base64,' + base64.b64encode(f.read()).decode()
    icon = svg(shapes, 150, **TILE, radius=ROUND)
    page.set_viewport_size({'width': 1200, 'height': 630})
    page.set_content(f"""<html><head><style>
@font-face{{font-family:B;font-weight:500 800;src:url({font('bricolage.woff2')})}}
@font-face{{font-family:M;font-weight:400 800;src:url({font('manrope.woff2')})}}
body{{margin:0;width:1200px;height:630px;overflow:hidden;color:#fff;font-family:M;
  background:radial-gradient(900px 600px at 85% 0%,#1A4A97,#071C42 60%,#04112B)}}
.in{{position:absolute;left:96px;top:96px;right:96px}}
svg{{display:block;border-radius:36px;box-shadow:0 30px 60px -30px rgba(0,0,0,.7)}}
h1{{font-family:B;font-weight:700;font-size:84px;line-height:1;margin:44px 0 0;letter-spacing:0}}
p{{font-size:30px;font-weight:600;color:#D3E3FB;margin:26px 0 0;letter-spacing:0}}
</style></head><body><div class="in">{icon}<h1>Run your dairy<br>from your phone.</h1>
<p>dairee.skifi.co</p></div></body></html>""")
    page.evaluate('document.fonts.ready')
    page.wait_for_timeout(300)
    path = os.path.join(ROOT, 'web/assets/brand/og.png')
    Image.open(io.BytesIO(page.screenshot())).convert('RGB').save(path, optimize=True)
    print('web/assets/brand/og.png 1200 x 630')


def dart(shapes):
    lines = [
        '// Written by tools/brand/brand.py from tools/brand/logo-source.png. Do not edit by hand.',
        "import 'dart:ui';",
        '',
        '/// The logo in a 1000 x 1000 box: the D, the sprout and the field.',
        'Path daireeMain() => _p(_main);',
        '',
        '/// The light path across the field.',
        'Path daireeLight() => _p(_light);',
        '',
        'const int daireeMainColour = 0xFF' + MAIN[1:] + ';',
        'const int daireeLightColour = 0xFF' + LIGHT[1:] + ';',
        '',
        'Path _p(List<List<double>> curves) {',
        '  final p = Path()..fillType = PathFillType.evenOdd;',
        '  for (final c in curves) {',
        '    var i = 0;',
        '    while (i < c.length) {',
        '      final op = c[i++];',
        '      if (op == 0) {',
        '        p.moveTo(c[i++], c[i++]);',
        '      } else if (op == 1) {',
        '        p.lineTo(c[i++], c[i++]);',
        '      } else {',
        '        p.cubicTo(c[i++], c[i++], c[i++], c[i++], c[i++], c[i++]);',
        '      }',
        '    }',
        '    p.close();',
        '  }',
        '  return p;',
        '}',
        '',
    ]
    code = {'M': 0, 'L': 1, 'C': 2}
    for name in ('main', 'light'):
        lines.append(f'const List<List<double>> _{name} = [')
        for c in shapes[name]:
            flat = []
            for op, v in c:
                flat.append(str(code[op]))
                flat += [f'{x:g}' for x in v]
            lines.append('  [' + ', '.join(f if '.' in f else f + '.0' for f in flat) + '],')
        lines.append('];')
        lines.append('')
    return '\n'.join(lines)


def main():
    shapes, box = trace()
    shapes = normalise(shapes, box)

    with open(os.path.join(ROOT, 'web/assets/brand/dairee-mark.svg'), 'w') as f:
        f.write(svg(shapes, 1000).replace(' width="1000" height="1000"', ''))
    with open(os.path.join(ROOT, 'web/assets/brand/dairee-icon.svg'), 'w') as f:
        f.write(svg(shapes, 1000, **TILE, radius=ROUND).replace(' width="1000" height="1000"', ''))
    with open(os.path.join(ROOT, 'app/lib/ui/brand_mark.dart'), 'w') as f:
        f.write(dart(shapes))

    out = {}

    def want(path, size, **kw):
        out[os.path.join(ROOT, path)] = (size, kw)

    # The app's own copies.
    want('app/assets/brand/icon.png', 1024, **TILE)
    want('app/assets/brand/mark.png', 512, **TILE, radius=ROUND)
    want('app/assets/brand/icon-foreground.png', 1024, fg=WHITE, scale=0.4)
    # Android: the full icon for old launchers; the adaptive foreground (on the
    # blue of ic_launcher_background) keeps the D inside the 66 of 108 safe circle.
    for d, s in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher.png', s, **TILE, radius=0.22)
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png', int(s * 108 / 48), fg=WHITE, scale=0.4)
    # iPhone: square and opaque; iOS rounds the corners itself.
    for name, s in {'20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60, '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87,
                    '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120, '60x60@2x': 120, '60x60@3x': 180,
                    '76x76@1x': 76, '76x76@2x': 152, '83.5x83.5@2x': 167, '1024x1024@1x': 1024}.items():
        want(f'app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-{name}.png', s, **TILE)
    # iPhone launch screen: the rounded tile on the app's paper colour.
    for suffix, s in {'': 96, '@2x': 192, '@3x': 288}.items():
        want(f'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage{suffix}.png', s, **TILE, radius=ROUND)
    # The web app.
    want('app/web/favicon.png', 32, bg=MAIN, fg=WHITE, scale=0.68, radius=0.22)
    want('app/web/icons/mark.png', 192, **TILE, radius=ROUND)
    want('app/web/icons/Icon-192.png', 192, **TILE, radius=0.22)
    want('app/web/icons/Icon-512.png', 512, **TILE, radius=0.22)
    want('app/web/icons/Icon-maskable-192.png', 192, bg=MAIN, fg=WHITE, scale=0.48)
    want('app/web/icons/Icon-maskable-512.png', 512, bg=MAIN, fg=WHITE, scale=0.48)
    want('app/web/icons/apple-touch-icon.png', 180, **TILE)
    # The site.
    want('web/assets/brand/icon-64.png', 64, **TILE, radius=ROUND)
    want('web/assets/brand/icon-128.png', 128, **TILE, radius=ROUND)
    want('web/assets/brand/touch-180.png', 180, **TILE)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()

        def render(size, **kw):
            page.set_viewport_size({'width': size, 'height': size})
            page.set_content(f'<html><body style="margin:0;background:transparent">{svg(shapes, size, **kw)}</body></html>')
            png = page.screenshot(omit_background=True, clip={'x': 0, 'y': 0, 'width': size, 'height': size})
            im = Image.open(io.BytesIO(png))
            # Store icons must be opaque where they have a full square tile.
            return im.convert('RGB') if kw.get('bg') and not kw.get('radius') else im.convert('RGBA')

        for path, (size, kw) in out.items():
            os.makedirs(os.path.dirname(path), exist_ok=True)
            render(size, **kw).save(path, optimize=True)
            print(os.path.relpath(path, ROOT), size)
        ico = {s: render(s, bg=MAIN, fg=WHITE, scale=0.68, radius=0.22) for s in (16, 32, 48)}
        share_card(page, shapes)
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
    print('web/favicon.ico, web/assets/brand/dairee-mark.svg, app/lib/ui/brand_mark.dart')


if __name__ == '__main__':
    main()
