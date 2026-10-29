"""The App Store Connect API key (.p8) as a clean PEM, however it was pasted.

A key pasted into a GitHub secret can lose its line breaks, keep literal \\n,
or arrive as base64 of the whole file. Apple's key is the same either way, so
this rebuilds the PEM from the key's own characters.

  python3 .github/scripts/p8.py > AuthKey.p8      (reads APP_STORE_CONNECT_KEY_P8 or KEY_P8)
"""
import base64
import os
import re
import sys


def pem(raw):
    raw = raw.strip().replace('\\n', '\n')
    if 'PRIVATE KEY' not in raw:
        try:
            decoded = base64.b64decode(re.sub(r'\s', '', raw), validate=True).decode()
            if 'PRIVATE KEY' in decoded:
                raw = decoded
        except Exception:
            pass
    body = re.sub(r'-----(BEGIN|END)[A-Z ]*PRIVATE KEY-----', '', raw)
    body = re.sub(r'[^A-Za-z0-9+/=]', '', body)
    if not body:
        sys.exit('::error::APP_STORE_CONNECT_KEY_P8 holds no key.')
    lines = [body[i:i + 64] for i in range(0, len(body), 64)]
    return '-----BEGIN PRIVATE KEY-----\n' + '\n'.join(lines) + '\n-----END PRIVATE KEY-----\n'


if __name__ == '__main__':
    sys.stdout.write(pem(os.environ.get('APP_STORE_CONNECT_KEY_P8') or os.environ.get('KEY_P8', '')))
