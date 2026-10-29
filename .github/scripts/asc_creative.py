#!/usr/bin/env python3
"""Upload the App Store creative assets (product page header, search results)
to the app's Asset Library, ready to place and submit.

  asc_creative.py <file> [<file> ...]

Each file goes up as a CREATIVE_ASSETS image named after the file (for example
"Dairee header" for header.png). A file whose name is already in the library,
and not failed, is skipped, so running it twice is safe. Nothing is placed on
a version and nothing is sent for review: that happens in App Store Connect
(Asset Library, or Header and Search Results on a version being prepared).

Results go to the log and to ::notice:: annotations, which show on the run's
page even when the log can't be opened.

Needs: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID,
APP_STORE_CONNECT_KEY_P8 (the .p8 file, however it was pasted).
Python packages: pyjwt, cryptography.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

sys.path.insert(0, os.path.dirname(__file__))
from p8 import pem  # noqa: E402

API = 'https://api.appstoreconnect.apple.com/v1'
BUNDLE_ID = 'co.skifi.dairee'


def env(name):
    v = os.environ.get(name, '').strip()
    if not v:
        sys.exit(f'::error::{name} is not set.')
    return v


def token():
    now = int(time.time())
    return jwt.encode(
        {'iss': env('APP_STORE_CONNECT_ISSUER_ID'), 'iat': now, 'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
        pem(env('APP_STORE_CONNECT_KEY_P8')).encode(), algorithm='ES256', headers={'kid': env('APP_STORE_CONNECT_KEY_ID'), 'typ': 'JWT'})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header('Authorization', 'Bearer ' + token())
    req.add_header('Content-Type', 'application/json')
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            text = r.read().decode()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors='replace')
        try:
            errs = json.loads(detail).get('errors', [])
            detail = '; '.join(f"{x.get('code', '')} {x.get('title', '')}: {x.get('detail', '')}" for x in errs) or detail
        except ValueError:
            pass
        raise RuntimeError(f'{method} {path} failed ({e.code}): {detail}') from None


def note(msg):
    print(msg)
    print(f'::notice::{msg}')


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(26)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f'::error::{path} is not a PNG.')
    color_type = head[25]
    return int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big'), color_type in (4, 6)


def main():
    files = sys.argv[1:]
    if not files:
        sys.exit(__doc__)
    for f in files:
        w, h, alpha = png_size(f)
        if alpha:
            sys.exit(f'::error::{f} has an alpha channel; Apple refuses that.')
        print(f'{f}: {w} x {h}')

    apps = call('GET', f'/apps?filter[bundleId]={BUNDLE_ID}')['data']
    if not apps:
        sys.exit(f'::error::No app with bundle ID {BUNDLE_ID}.')
    app_id = apps[0]['id']
    lib = call('GET', f'/apps/{app_id}/assetLibrary')['data']
    lib_id = lib['id']

    specs = {}
    try:
        ref = call('GET', '/appAssetLibraryRefData?fields[appAssetLibraryRefData]=imageSpecs')
        for d in ref.get('data', []):
            for s in d['attributes'].get('imageSpecs') or []:
                specs[s['specId']] = s
    except RuntimeError as e:
        print(f'Could not read the image specs: {e}')

    existing = {}
    q = urllib.parse.urlencode({'filter[category]': 'CREATIVE_ASSETS', 'limit': 200})
    for img in call('GET', f'/appAssetLibraries/{lib_id}/images?{q}').get('data', []):
        a = img['attributes']
        if a.get('state') not in ('FAILED',):
            existing[a.get('referenceName')] = (img['id'], a.get('state'))

    for f in files:
        base = os.path.splitext(os.path.basename(f))[0]
        name = f'Dairee {base}'
        if name in existing:
            note(f'{name}: already in the Asset Library ({existing[name][1]}), skipped')
            continue
        data = open(f, 'rb').read()
        made = call('POST', '/appAssetLibraryImages', {'data': {
            'type': 'appAssetLibraryImages',
            'attributes': {'fileName': os.path.basename(f), 'fileSize': len(data),
                           'category': 'CREATIVE_ASSETS', 'referenceName': name},
            'relationships': {'assetLibrary': {'data': {'type': 'appAssetLibraries', 'id': lib_id}}}}})['data']
        for op in made['attributes']['uploadOperations']:
            part = data[op['offset']:op['offset'] + op['length']]
            req = urllib.request.Request(op['url'], method=op['method'], data=part)
            for hd in op.get('requestHeaders') or []:
                req.add_header(hd['name'], hd['value'])
            with urllib.request.urlopen(req, timeout=180):
                pass
        call('PATCH', f"/appAssetLibraryImages/{made['id']}", {'data': {
            'type': 'appAssetLibraryImages', 'id': made['id'], 'attributes': {'uploaded': True}}})
        state, a = 'UPLOAD_COMPLETE', {}
        for _ in range(90):
            a = call('GET', f"/appAssetLibraryImages/{made['id']}")['data']['attributes']
            state = a.get('state')
            if state not in ('AWAITING_UPLOAD', 'UPLOAD_COMPLETE'):
                break
            time.sleep(4)
        spec = specs.get(a.get('specId') or '', {})
        works = ', '.join(spec.get('compatiblePlacementTypes') or []) or 'unknown'
        if state == 'PREPARE_FOR_SUBMISSION':
            note(f"{name}: uploaded, ready ({spec.get('shortName', a.get('specId'))}; works with {works})")
        else:
            print(f"::error::{name}: {state} {json.dumps(a.get('stateDetails'))}")
            sys.exit(1)


if __name__ == '__main__':
    main()
