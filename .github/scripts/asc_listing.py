#!/usr/bin/env python3
"""Fill in Dairee's App Store page for a version that is still being prepared.

  asc_listing.py <screenshot folder> [version]

From docs/STORE.md: the description, keywords, promotional text, support and
marketing links, the subtitle and privacy policy link, the categories, the
copyright and the review notes and contact. From the folder: 1.png, 2.png, ...
as the iPhone screenshots, in order (replacing any there). Then the newest
processed build of that version is attached.

The review account's password is never written here: it is typed in App
Store Connect (App Review Information) by the owner.

Needs: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID,
APP_STORE_CONNECT_KEY_P8. Python packages: pyjwt, cryptography.
"""
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt

sys.path.insert(0, os.path.dirname(__file__))
from p8 import pem  # noqa: E402

API = 'https://api.appstoreconnect.apple.com/v1'
BUNDLE_ID = 'co.skifi.dairee'
LOCALE = 'en-US'
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'}
SITE = 'https://dairee.skifi.co'
SHOT_TYPES = {(1290, 2796): 'APP_IPHONE_67', (1320, 2868): 'APP_IPHONE_67', (1284, 2778): 'APP_IPHONE_65', (1242, 2688): 'APP_IPHONE_65'}


def env(name):
    v = os.environ.get(name, '').strip()
    if not v:
        sys.exit(f'::error::{name} is not set.')
    return v


def token():
    now = int(time.time())
    return jwt.encode(
        {'iss': env('APP_STORE_CONNECT_ISSUER_ID'), 'iat': now, 'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
        pem(env('APP_STORE_CONNECT_KEY_P8')).encode(), algorithm='ES256',
        headers={'kid': env('APP_STORE_CONNECT_KEY_ID'), 'typ': 'JWT'})


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
            detail = '; '.join(f"{x.get('title', '')}: {x.get('detail', '')}" for x in errs) or detail
        except ValueError:
            pass
        raise RuntimeError(f'{method} {path} failed ({e.code}): {detail}') from None


def block(doc, title):
    m = re.search(r'\*\*' + re.escape(title) + r'\*\*[^\n]*\n\n```\n([\s\S]*?)\n```', doc)
    if not m:
        sys.exit(f'::error::docs/STORE.md has no "{title}" block.')
    return m.group(1).strip()


def review_notes(doc):
    m = re.search(r'Review notes \(both stores\):\n\n```\n([\s\S]*?)\n```', doc)
    if not m:
        sys.exit('::error::docs/STORE.md has no review notes block.')
    return m.group(1).strip()


def png_size(path):
    with open(path, 'rb') as f:
        head = f.read(24)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        sys.exit(f'::error::{path} is not a PNG.')
    return int.from_bytes(head[16:20], 'big'), int.from_bytes(head[20:24], 'big')


def upload(set_id, path):
    data = open(path, 'rb').read()
    made = call('POST', '/appScreenshots', {'data': {
        'type': 'appScreenshots',
        'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})['data']
    for op in made['attributes']['uploadOperations']:
        req = urllib.request.Request(op['url'], method=op['method'], data=data[op['offset']:op['offset'] + op['length']])
        for h in op.get('requestHeaders') or []:
            req.add_header(h['name'], h['value'])
        with urllib.request.urlopen(req, timeout=120):
            pass
    call('PATCH', f"/appScreenshots/{made['id']}", {'data': {
        'type': 'appScreenshots', 'id': made['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    return made['id']


def wait(shot_id, name):
    for _ in range(240):
        a = call('GET', f'/appScreenshots/{shot_id}')['data']['attributes']
        state = (a.get('assetDeliveryState') or {}).get('state')
        if state == 'COMPLETE':
            print(f'  {name}: ready')
            return True
        if state == 'FAILED':
            errs = (a.get('assetDeliveryState') or {}).get('errors') or []
            print(f"::error::{name} was not accepted: {'; '.join(e.get('description', e.get('code', '')) for e in errs)}")
            return False
        time.sleep(5)
    print(f'::error::{name} is still processing after 20 minutes.')
    return False


def screenshots(loc_id, folder):
    files = []
    n = 1
    while os.path.exists(os.path.join(folder, f'{n}.png')):
        files.append(os.path.join(folder, f'{n}.png'))
        n += 1
    if not files:
        sys.exit(f'::error::No 1.png in {folder}.')
    sizes = {png_size(f) for f in files}
    if len(sizes) != 1:
        sys.exit(f'::error::The pictures are not all one size: {sorted(sizes)}')
    size = sizes.pop()
    kind = SHOT_TYPES.get(size)
    if not kind:
        sys.exit(f'::error::{size} is not an iPhone screenshot size this script knows.')
    sets = call('GET', f'/appStoreVersionLocalizations/{loc_id}/appScreenshotSets?include=appScreenshots&limit=50')
    found = next((s for s in sets['data'] if s['attributes']['screenshotDisplayType'] == kind), None)
    if found:
        set_id = found['id']
        old = [r['id'] for r in (found.get('relationships', {}).get('appScreenshots', {}).get('data') or [])]
        for sid in old:
            call('DELETE', f'/appScreenshots/{sid}')
        print(f'Screenshots: removed {len(old)} old ones from {kind}')
    else:
        set_id = call('POST', '/appScreenshotSets', {'data': {
            'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': kind},
            'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc_id}}}}})['data']['id']
        print(f'Screenshots: made the {kind} set')
    # All up first, then wait: Apple works on them side by side.
    new = [upload(set_id, f) for f in files]
    if not all([wait(sid, os.path.basename(f)) for sid, f in zip(new, files)]):
        sys.exit(1)
    call('PATCH', f'/appScreenshotSets/{set_id}/relationships/appScreenshots',
         {'data': [{'type': 'appScreenshots', 'id': i} for i in new]})
    print(f'Screenshots: {len(new)} in {kind}, in order')


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    folder = sys.argv[1]
    version = sys.argv[2] if len(sys.argv) > 2 else '1.0.0'
    doc = open(os.path.join(os.path.dirname(__file__), '..', '..', 'docs', 'STORE.md')).read()

    app = call('GET', f'/apps?filter[bundleId]={BUNDLE_ID}')['data']
    if not app:
        sys.exit(f'::error::No app with bundle ID {BUNDLE_ID}.')
    app_id = app[0]['id']
    vs = call('GET', f'/apps/{app_id}/appStoreVersions?filter[platform]=IOS&filter[versionString]={version}')['data']
    if not vs:
        sys.exit(f'::error::No iOS version {version}.')
    v = vs[0]
    if v['attributes'].get('appVersionState') not in EDITABLE and v['attributes'].get('appStoreState') not in EDITABLE:
        sys.exit(f"::error::Version {version} is {v['attributes'].get('appVersionState')}; it cannot be changed now.")

    # The version: copyright, released by itself once approved.
    call('PATCH', f"/appStoreVersions/{v['id']}", {'data': {'type': 'appStoreVersions', 'id': v['id'], 'attributes': {
        'copyright': '2026 SKIFI GROUP LLC', 'releaseType': 'AFTER_APPROVAL'}}})
    print('Version: copyright, release after approval')

    # The version's page in English.
    locs = call('GET', f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=50")['data']
    loc = next((x for x in locs if x['attributes']['locale'] == LOCALE), None)
    attrs = {'description': block(doc, 'Full description'), 'keywords': block(doc, 'Keywords'),
             'promotionalText': block(doc, 'Promotional text'), 'supportUrl': f'{SITE}/support', 'marketingUrl': SITE}
    if loc:
        call('PATCH', f"/appStoreVersionLocalizations/{loc['id']}", {'data': {
            'type': 'appStoreVersionLocalizations', 'id': loc['id'], 'attributes': attrs}})
    else:
        loc = call('POST', '/appStoreVersionLocalizations', {'data': {
            'type': 'appStoreVersionLocalizations', 'attributes': {'locale': LOCALE, **attrs},
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})['data']
    print('Page: description, keywords, promotional text, support and marketing links')

    # The app's information: subtitle, privacy policy, categories.
    infos = call('GET', f'/apps/{app_id}/appInfos')['data']
    info = next((i for i in infos if i['attributes'].get('appStoreState') in EDITABLE or i['attributes'].get('state') in
                 {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED'}), infos[0])
    ilocs = call('GET', f"/appInfos/{info['id']}/appInfoLocalizations?limit=50")['data']
    iloc = next((x for x in ilocs if x['attributes']['locale'] == LOCALE), None)
    if iloc:
        call('PATCH', f"/appInfoLocalizations/{iloc['id']}", {'data': {'type': 'appInfoLocalizations', 'id': iloc['id'], 'attributes': {
            'subtitle': block(doc, 'Subtitle'), 'privacyPolicyUrl': f'{SITE}/privacy'}}})
    call('PATCH', f"/appInfos/{info['id']}", {'data': {'type': 'appInfos', 'id': info['id'], 'relationships': {
        'primaryCategory': {'data': {'type': 'appCategories', 'id': 'BUSINESS'}},
        'secondaryCategory': {'data': {'type': 'appCategories', 'id': 'PRODUCTIVITY'}}}}})
    print('App information: subtitle, privacy policy, Business and Productivity')

    # App Review: contact and notes. The demo account's password is typed in App Store Connect.
    detail = call('GET', f"/appStoreVersions/{v['id']}/appStoreReviewDetail")
    review = {'contactFirstName': 'Ishaque', 'contactLastName': 'NV', 'contactPhone': '+917827087878',
              'contactEmail': 'contact@skifi.co', 'demoAccountName': 'contact@skifi.co',
              'demoAccountRequired': True, 'notes': review_notes(doc)}
    if detail.get('data'):
        call('PATCH', f"/appStoreReviewDetails/{detail['data']['id']}", {'data': {
            'type': 'appStoreReviewDetails', 'id': detail['data']['id'], 'attributes': review}})
    else:
        call('POST', '/appStoreReviewDetails', {'data': {'type': 'appStoreReviewDetails', 'attributes': review,
            'relationships': {'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': v['id']}}}}})
    print('App Review: contact, notes, demo account name (password: type it in App Store Connect)')

    screenshots(loc['id'], folder)

    # The newest processed build of this version.
    builds = call('GET', f'/builds?filter[app]={app_id}&filter[preReleaseVersion.version]={version}'
                         f'&filter[processingState]=VALID&sort=-uploadedDate&limit=1')['data']
    if builds:
        b = builds[0]
        call('PATCH', f"/appStoreVersions/{v['id']}/relationships/build", {'data': {'type': 'builds', 'id': b['id']}})
        print(f"Build: {b['attributes']['version']} attached")
    else:
        print('::warning::No processed build of this version yet; attach it in App Store Connect once TestFlight shows it.')

    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as fh:
            fh.write(f'Filled in the App Store page of Dairee {version}. Type the review account password under App Review in App Store Connect.\n')


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        sys.exit(f'::error::{e}')
