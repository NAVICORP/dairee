"""Dairee's mark: the letter D whose counter is a drop of milk. Flat, two
colours, exact geometry. This script draws it and writes every icon the app,
the stores and the site use, so a change here reaches all of them at once.

    python3 tools/brand.py

Needs Playwright for Python with Chromium (it renders the SVG).
"""
import math
import os
import io
import struct

from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BLUE = '#1F5FD6'
WHITE = '#FFFFFF'

# ---------------------------------------------------------------- the geometry (a 1024 box)

H = 540                      # height of the D
A = 200                      # straight run of the top and bottom before the bowl
R = H / 2                    # radius of the bowl
W = A + R                    # width of the D
STEM = 150                   # the upright, heavier than the curves as in a drawn D
CORNER = 36                  # the softened corners of the upright
DROP_R = 124                 # the round of the drop
DROP_TOP = 100               # from the top of the D to the tip of the drop
DROP_BOTTOM = 110            # from the bottom of the drop to the bottom of the D


def d_outline(x0, y0):
    return (f"M{x0 + CORNER:.2f},{y0:.2f} H{x0 + A:.2f} A{R:.2f},{R:.2f} 0 0 1 {x0 + A:.2f},{y0 + H:.2f} "
            f"H{x0 + CORNER:.2f} Q{x0:.2f},{y0 + H:.2f} {x0:.2f},{y0 + H - CORNER:.2f} "
            f"V{y0 + CORNER:.2f} Q{x0:.2f},{y0:.2f} {x0 + CORNER:.2f},{y0:.2f} Z")


def drop(cx, tip, cy, r, fullness=0.03):
    """A drop: straight sides from the tip, tangent to a circle; very slightly full."""
    d = cy - tip
    L = math.sqrt(d * d - r * r)
    px = cx + r * L / d
    py = cy - r * r / d
    mx, my = (cx + px) / 2, (tip + py) / 2
    vx, vy = px - cx, py - tip
    n = math.hypot(vx, vy)
    qx, qy = mx + (vy / n) * L * fullness, my - (vx / n) * L * fullness
    return (f"M{cx:.2f},{tip:.2f} Q{qx:.2f},{qy:.2f} {px:.2f},{py:.2f} "
            f"A{r:.2f},{r:.2f} 0 1 1 {2 * cx - px:.2f},{py:.2f} "
            f"Q{2 * cx - qx:.2f},{qy:.2f} {cx:.2f},{tip:.2f} Z")


def mark_path():
    """The D with its drop counter, centred in a 1024 box."""
    x0 = (1024 - W) / 2
    y0 = (1024 - H) / 2
    cx = x0 + STEM + (W - STEM) / 2 - 16
    cy = y0 + H - DROP_BOTTOM - DROP_R
    return f"{d_outline(x0, y0)} {drop(cx, y0 + DROP_TOP, cy, DROP_R)}"


def svg(size, bg=None, scale=1.0, colour=WHITE, radius=0.0):
    """The mark at `size` px: on a tile of `bg` (or transparent), the mark at
    `scale` of its normal size, the tile's corners rounded by `radius` (0..0.5)."""
    tile = f'<rect width="1024" height="1024" rx="{radius * 1024:.1f}" fill="{bg}"/>' if bg else ''
    t = f'translate({512 - 512 * scale:.2f},{512 - 512 * scale:.2f}) scale({scale})'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="{size}" height="{size}">'
            f'{tile}<path transform="{t}" fill-rule="evenodd" fill="{colour}" d="{mark_path()}"/></svg>')


# ---------------------------------------------------------------- writing the files

def main():
    out = {}

    def want(path, size, **kw):
        out[os.path.join(ROOT, path)] = (size, kw)

    # The app's own copy (welcome screen, side bar) and the vector.
    want('app/assets/brand/icon.png', 1024, bg=BLUE)
    want('app/assets/brand/icon-foreground.png', 1024, scale=0.8)
    # Android: the full icon for old launchers, the foreground for adaptive ones
    # (inside the 66 of 108 safe circle), also used as the themed icon.
    for d, s in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher.png', s, bg=BLUE, radius=0.22)
        want(f'app/android/app/src/main/res/mipmap-{d}/ic_launcher_foreground.png', int(s * 108 / 48), scale=0.8)
    # iPhone: square and opaque; iOS rounds the corners itself.
    for name, s in {'20x20@1x': 20, '20x20@2x': 40, '20x20@3x': 60, '29x29@1x': 29, '29x29@2x': 58, '29x29@3x': 87,
                    '40x40@1x': 40, '40x40@2x': 80, '40x40@3x': 120, '60x60@2x': 120, '60x60@3x': 180,
                    '76x76@1x': 76, '76x76@2x': 152, '83.5x83.5@2x': 167, '1024x1024@1x': 1024}.items():
        want(f'app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-{name}.png', s, bg=BLUE)
    # iPhone launch screen: the white mark on the blue background.
    for suffix, s in {'': 120, '@2x': 240, '@3x': 360}.items():
        want(f'app/ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage{suffix}.png', s, scale=1.4)
    # The web app.
    want('app/web/favicon.png', 32, bg=BLUE, radius=0.22)
    want('app/web/icons/Icon-192.png', 192, bg=BLUE)
    want('app/web/icons/Icon-512.png', 512, bg=BLUE)
    want('app/web/icons/Icon-maskable-192.png', 192, bg=BLUE, scale=0.8)
    want('app/web/icons/Icon-maskable-512.png', 512, bg=BLUE, scale=0.8)
    want('app/web/icons/apple-touch-icon.png', 180, bg=BLUE)
    # The site.
    want('web/assets/brand/icon-64.png', 64, bg=BLUE, radius=0.22)
    want('web/assets/brand/icon-128.png', 128, bg=BLUE, radius=0.22)
    want('web/assets/brand/touch-180.png', 180, bg=BLUE)
    ico = {s: None for s in (16, 32, 48)}

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()

        def render(size, **kw):
            page.set_viewport_size({'width': size, 'height': size})
            page.set_content(f'<html><body style="margin:0;background:transparent">{svg(size, **kw)}</body></html>')
            png = page.screenshot(omit_background=True, clip={'x': 0, 'y': 0, 'width': size, 'height': size})
            im = Image.open(io.BytesIO(png))
            # Store icons must be opaque where they have a tile.
            return im.convert('RGB') if kw.get('bg') and not kw.get('radius') else im.convert('RGBA')

        for path, (size, kw) in out.items():
            render(size, **kw).save(path, optimize=True)
            print(os.path.relpath(path, ROOT), size)
        for s in ico:
            ico[s] = render(s, bg=BLUE, radius=0.22)
        browser.close()

    # favicon.ico with three sizes, each stored as PNG.
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
    print('web/favicon.ico 16 32 48')

    # The vector, for print and for anyone who needs the mark itself.
    with open(os.path.join(ROOT, 'web/assets/brand/dairee.svg'), 'w') as f:
        f.write(svg(1024, bg=BLUE, radius=0.22).replace(' width="1024" height="1024"', ''))
    with open(os.path.join(ROOT, 'web/assets/brand/dairee-mark.svg'), 'w') as f:
        f.write(svg(1024, colour=BLUE).replace(' width="1024" height="1024"', ''))
    print('web/assets/brand/dairee.svg, dairee-mark.svg')


if __name__ == '__main__':
    main()
