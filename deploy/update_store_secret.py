"""Refresh the GitHub Action secret that carries the store admin token.

GitHub requires the secret value to be encrypted with the repository public key
using libsodium sealed box, which is what nacl.public.SealedBox does here.

Design notes
------------
* The secret carries **only the admin token** (plain hex text). Everything else
  (api server, address book user/collection id) lives in the versioned
  ``deploy/store_settings.json`` so a change there takes effect on the next CI
  build instead of silently drifting from the secret.
* The token is stored as plain hex, not base64. A base64 payload was mangled
  on its way through the CI environment once ("Only base64 data is allowed"),
  while plain hex passes through unchanged.
"""
import base64
import json
import os
import subprocess
import sys

from nacl.encoding import Base64Encoder
from nacl.public import PublicKey, SealedBox

REPO = 'z450519587/RustDesk1.5.0'
API = f'https://api.github.com/repos/{REPO}'
SECRET = 'STORE_ADMIN_TOKEN'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get_token():
    out = subprocess.run(
        ['git', 'credential', 'fill'],
        input=b'protocol=https\nhost=github.com\n\n',
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ).stdout.decode()
    for line in out.splitlines():
        if line.startswith('password='):
            return line.split('=', 1)[1]
    raise SystemExit('no github token from git credential manager')


TOKEN = get_token()


def api(method, path, payload=None):
    cmd = [
        'curl', '-s', '--max-time', '60', '-X', method,
        '-H', f'Authorization: Bearer {TOKEN}',
        '-H', 'Accept: application/vnd.github+json',
        '-H', 'Content-Type: application/json',
    ]
    if payload is not None:
        cmd += ['--data-binary', payload]
    cmd += [f'{API}{path}']
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    body = proc.stdout.decode('utf-8', 'replace')
    try:
        return proc.returncode, json.loads(body)
    except Exception:
        return proc.returncode, body[:600]


def read_admin_token():
    for name in ('store_config.json', 'store_sync.json'):
        path = os.path.join(ROOT, 'deploy', name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding='utf-8') as fh:
            token = (json.load(fh).get('adminToken') or '').strip()
        if token:
            print('admin token taken from deploy/%s' % name)
            return token
    raise SystemExit('no adminToken found in deploy/store_config.json or store_sync.json')


def main():
    rc, pk = api('GET', '/actions/secrets/public-key')
    if rc or not isinstance(pk, dict) or 'key' not in pk:
        raise SystemExit(f'public key failed: rc={rc} {pk}')
    print('key_id:', pk['key_id'])

    token = read_admin_token()
    print('token length:', len(token), 'charset:', ''.join(sorted(set(token))))

    enc = SealedBox(PublicKey(pk['key'], encoder=Base64Encoder)).encrypt(token.encode('utf-8'))
    payload = {
        'encrypted_value': base64.b64encode(enc).decode(),
        'key_id': pk['key_id'],
    }
    rc, res = api('PUT', f'/actions/secrets/{SECRET}', json.dumps(payload))
    print('update status:', rc, res.get('message', 'ok') if isinstance(res, dict) else res)

    rc, listing = api('GET', '/actions/secrets')
    if isinstance(listing, dict):
        for s in listing.get('secrets') or []:
            print('secret:', s['name'], 'updated_at:', s['updated_at'])
    else:
        print('listing failed:', listing)


if __name__ == '__main__':
    main()
