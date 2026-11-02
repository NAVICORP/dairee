#!/usr/bin/env python3
"""Where Dairee stands on the App Store, read only: each version and its
state, the build on it, the newest builds and any review submissions.

  asc_status.py

Results go to the log and to ::notice:: annotations, which show on the run's
page even when the log can't be opened.

Needs: APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID,
APP_STORE_CONNECT_KEY_P8. Python packages: pyjwt, cryptography.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from asc_listing import BUNDLE_ID, call  # noqa: E402


def note(msg):
    print(msg)
    print(f'::notice::{msg}')


def main():
    app = call('GET', f'/apps?filter[bundleId]={BUNDLE_ID}')['data'][0]
    app_id = app['id']
    for v in call('GET', f'/apps/{app_id}/appStoreVersions?limit=10')['data']:
        a = v['attributes']
        b = call('GET', f"/appStoreVersions/{v['id']}/build").get('data')
        built = f"build {b['attributes']['version']}" if b else 'no build'
        note(f"Version {a.get('versionString')}: {a.get('appVersionState') or a.get('appStoreState')}, {built}, "
             f"release {a.get('releaseType')}, made {str(a.get('createdDate'))[:10]}")
    for b in call('GET', f'/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5&include=preReleaseVersion')['data']:
        a = b['attributes']
        note(f"Build {a.get('version')}: {a.get('processingState')}, uploaded {str(a.get('uploadedDate'))[:16]}, "
             f"expires {str(a.get('expirationDate'))[:10]}")
    try:
        for s in call('GET', f'/reviewSubmissions?filter[app]={app_id}&limit=5')['data']:
            a = s['attributes']
            note(f"Review submission: {a.get('state')}, submitted {str(a.get('submittedDate'))[:16]}")
    except RuntimeError as e:
        print(f'Review submissions: {e}')


if __name__ == '__main__':
    try:
        main()
    except RuntimeError as e:
        sys.exit(f'::error::{e}')
