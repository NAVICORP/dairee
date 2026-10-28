#!/usr/bin/env python3
"""Signing for the TestFlight build, made fresh on each run with the App Store
Connect API key, so no certificate or profile has to be kept anywhere.

  setup   <dir>  makes an Apple Distribution certificate and an App Store
                 profile for co.skifi.dairee, writes cert.p12, the profile,
                 ExportOptions.plist and state.json into <dir>, and points the
                 Runner target at them (manual signing, Release and Profile)
  cleanup <dir>  revokes that certificate and deletes the profile

Needs: APPLE_TEAM_ID, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID,
APP_STORE_CONNECT_KEY_P8 (the .p8 file, base64), P12_PASSWORD.
Python packages: pyjwt, cryptography.

Revoking the certificate after the upload does not affect builds already sent
to App Store Connect or apps on the App Store.
"""
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID

API = 'https://api.appstoreconnect.apple.com/v1'
BUNDLE_ID = 'co.skifi.dairee'
PROJECT = 'app/ios/Runner.xcodeproj/project.pbxproj'


def env(name):
    v = os.environ.get(name, '').strip()
    if not v:
        sys.exit(f'::error::{name} is not set.')
    return v


def p8():
    raw = env('APP_STORE_CONNECT_KEY_P8')
    if 'BEGIN PRIVATE KEY' in raw:
        return raw.encode()
    return base64.b64decode(raw)


def token():
    now = int(time.time())
    return jwt.encode(
        {'iss': env('APP_STORE_CONNECT_ISSUER_ID'), 'iat': now, 'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
        p8(), algorithm='ES256', headers={'kid': env('APP_STORE_CONNECT_KEY_ID'), 'typ': 'JWT'})


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


def bundle_id():
    found = call('GET', f'/bundleIds?filter[identifier]={BUNDLE_ID}&filter[platform]=IOS&limit=50')
    for b in found.get('data', []):
        if b['attributes']['identifier'] == BUNDLE_ID:
            return b['id']
    made = call('POST', '/bundleIds', {'data': {'type': 'bundleIds', 'attributes': {
        'identifier': BUNDLE_ID, 'name': 'Dairee', 'platform': 'IOS'}}})
    print(f'Registered the bundle id {BUNDLE_ID}.')
    return made['data']['id']


def app_id():
    found = call('GET', f'/apps?filter[bundleId]={BUNDLE_ID}&limit=10')
    for a in found.get('data', []):
        if a['attributes']['bundleId'] == BUNDLE_ID:
            return a['id']
    return ''


def set_signing(team, profile_name):
    """Manual signing on the Runner target's Release and Profile configurations only
    (setting it on the command line would also hit the plugin targets)."""
    s = open(PROJECT).read()
    want = {
        'CODE_SIGN_STYLE': 'Manual',
        'DEVELOPMENT_TEAM': team,
        'CODE_SIGN_IDENTITY': '"Apple Distribution"',
        '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"': '"Apple Distribution"',
        'PROVISIONING_PROFILE_SPECIFIER': f'"{profile_name}"',
    }
    count = 0

    def fix(m):
        nonlocal count
        block = m.group(0)
        if f'PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};' not in block or not re.search(r'name = (Release|Profile);', block):
            return block
        for k in want:
            block = re.sub(r'\n\s*' + re.escape(k) + r' = [^;]*;', '', block)
        add = ''.join(f'\n\t\t\t\t{k} = {v};' for k, v in want.items())
        count += 1
        return block.replace('buildSettings = {', 'buildSettings = {' + add, 1)

    s = re.sub(r'\w+ /\* \w+ \*/ = \{\s*isa = XCBuildConfiguration;.*?\n\t\t\};', fix, s, flags=re.S)
    if count < 2:
        sys.exit(f'::error::Expected the Runner Release and Profile configurations, found {count}.')
    open(PROJECT, 'w').write(s)


def setup(out):
    os.makedirs(out, exist_ok=True)
    team = env('APPLE_TEAM_ID')
    password = env('P12_PASSWORD').encode()
    state = {}

    app = app_id()
    if not app:
        sys.exit(f'::error::No app with the bundle id {BUNDLE_ID} in App Store Connect yet. '
                 'Create it first: App Store Connect > Apps > + > New App.')
    state['app_id'] = app
    bid = bundle_id()

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Dairee CI')]))
           .sign(key, hashes.SHA256()))
    try:
        made = call('POST', '/certificates', {'data': {'type': 'certificates', 'attributes': {
            'certificateType': 'DISTRIBUTION',
            'csrContent': csr.public_bytes(serialization.Encoding.PEM).decode()}}})
    except RuntimeError as e:
        sys.exit(f'::error::Could not make a distribution certificate: {e}. If the account already has the most '
                 'Apple Distribution certificates allowed, revoke an old one in developer.apple.com > '
                 'Certificates, IDs & Profiles, then run this again.')
    state['certificate_id'] = made['data']['id']
    json.dump(state, open(os.path.join(out, 'state.json'), 'w'))
    cert = x509.load_der_x509_certificate(base64.b64decode(made['data']['attributes']['certificateContent']))

    enc = (serialization.PrivateFormat.PKCS12.encryption_builder()
           .kdf_rounds(50000)
           .key_cert_algorithm(pkcs12.PBES.PBESv1SHA1And3KeyTripleDESCBC)
           .hmac_hash(hashes.SHA1())
           .build(password))
    open(os.path.join(out, 'cert.p12'), 'wb').write(
        pkcs12.serialize_key_and_certificates(b'Dairee CI', key, cert, None, enc))

    name = f"Dairee CI {os.environ.get('GITHUB_RUN_NUMBER', int(time.time()))}"
    prof = call('POST', '/profiles', {'data': {
        'type': 'profiles',
        'attributes': {'name': name, 'profileType': 'IOS_APP_STORE'},
        'relationships': {
            'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
            'certificates': {'data': [{'type': 'certificates', 'id': state['certificate_id']}]},
        }}})
    state['profile_id'] = prof['data']['id']
    state['profile_name'] = name
    state['profile_uuid'] = prof['data']['attributes']['uuid']
    json.dump(state, open(os.path.join(out, 'state.json'), 'w'))
    open(os.path.join(out, 'profile.mobileprovision'), 'wb').write(
        base64.b64decode(prof['data']['attributes']['profileContent']))

    open(os.path.join(out, 'ExportOptions.plist'), 'w').write(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>export</string>
	<key>teamID</key><string>{team}</string>
	<key>signingStyle</key><string>manual</string>
	<key>signingCertificate</key><string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict><key>{BUNDLE_ID}</key><string>{name}</string></dict>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
''')
    set_signing(team, name)
    print(f"Certificate and profile ready ({name}); App Store Connect app {app}.")


def cleanup(out):
    path = os.path.join(out, 'state.json')
    if not os.path.exists(path):
        print('Nothing to clean up.')
        return
    state = json.load(open(path))
    for kind, key in (('profiles', 'profile_id'), ('certificates', 'certificate_id')):
        if state.get(key):
            try:
                call('DELETE', f'/{kind}/{state[key]}')
                print(f'Removed the CI {kind[:-1]}.')
            except RuntimeError as e:
                print(f'::warning::Could not remove the CI {kind[:-1]}: {e}')


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('setup', 'cleanup'):
        sys.exit(__doc__)
    try:
        (setup if sys.argv[1] == 'setup' else cleanup)(sys.argv[2])
    except RuntimeError as e:
        sys.exit(f'::error::{e}')
