"""Simulate the CI 'Prepare store config' step locally.

Verifies that the merged factory config ends up with:
  - the admin token from the GitHub Secret
  - apiServer / userId / collectionId from the versioned repo file
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN = json.load(open(os.path.join(ROOT, 'deploy', 'store_config.json'), encoding='utf-8'))['adminToken']

env = dict(os.environ)
env['STORE_ADMIN_TOKEN'] = TOKEN

script = r'''
import json, os, sys

out_path = './rustdesk/store_config.json'

base = {}
for cand in ('./deploy/store_settings.json', './deploy/store_config.example.json'):
    if os.path.isfile(cand):
        with open(cand, 'rb') as f:
            base = json.loads(f.read().decode('utf-8'))
        print('store config base from %s' % cand)
        break

if not base:
    print('::warning::no store_config.json available; client will prompt on first run')
    sys.exit(0)

token = (os.environ.get('STORE_ADMIN_TOKEN') or '').strip()
if token:
    base['adminToken'] = token
    print('admin token injected from secret (%d chars)' % len(token))
else:
    base['adminToken'] = ''
    print('::warning::STORE_ADMIN_TOKEN secret not set; token will be empty')

print('keys:', sorted(base.keys()))
print('has_token:', bool(base.get('adminToken')))
print('collection_id:', base.get('addressBookCollectionId'))
'''

proc = subprocess.run([sys.executable, '-c', script], cwd=ROOT, env=env,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(proc.stdout.decode('utf-8', 'replace'))
sys.exit(proc.returncode)
