"""Simulate the CI 'Prepare store config' step locally.

Verifies that the merged factory config ends up with:
  - the admin token from the GitHub Secret
  - apiServer / userId / collectionId from the versioned repo file
"""
import base64
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SECRET_CFG = {
    'adminToken': json.load(open(os.path.join(ROOT, 'deploy', 'store_config.json'), encoding='utf-8'))['adminToken'],
}
b64 = base64.b64encode(json.dumps(SECRET_CFG, ensure_ascii=False).encode('utf-8')).decode()

env = dict(os.environ)
env['STORE_SYNC_CONFIG_B64'] = b64

script = r'''
import base64, json, os, sys

base = {}
for cand in ('./deploy/store_settings.json', './deploy/store_config.example.json'):
    if os.path.isfile(cand):
        with open(cand, 'rb') as f:
            base = json.loads(f.read().decode('utf-8'))
        print('store config base from %s' % cand)
        break

b64 = ''.join(os.environ.get('STORE_SYNC_CONFIG_B64', '').split())
if b64:
    try:
        raw = base64.b64decode(b64, validate=True)
    except Exception as e:
        print('::error::failed to decode STORE_SYNC_CONFIG_B64: %s' % e)
        sys.exit(1)
    secret_cfg = json.loads(raw.decode('utf-8'))
    merged = dict(base)
    merged.update(secret_cfg)
    base = merged
    print('store config secret merged (%d bytes decoded)' % len(raw))
else:
    print('::warning::STORE_SYNC_CONFIG_B64 secret not set; token will be empty')

if not base:
    print('::warning::no store_config.json available; client will prompt on first run')
    sys.exit(0)

print('keys:', sorted(base.keys()))
print('has_token:', bool(base.get('adminToken')))
print('collection_id:', base.get('addressBookCollectionId'))
'''

proc = subprocess.run([sys.executable, '-c', script], cwd=ROOT, env=env,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(proc.stdout.decode('utf-8', 'replace'))
sys.exit(proc.returncode)
