"""Sync the local working tree to the remote branch through the REST API.

Needed when the git transport is blocked by the proxy (502) but the REST API
is reachable. It compares the local git tree with the remote tree and pushes
only what differs: new/changed files via the contents API, removed files via
a delete, then moves the branch pointer.

Run: python deploy/sync_tree_via_api.py [--dry-run]
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = 'z450519587/RustDesk1.5.0'
API = f'https://api.github.com/repos/{REPO}'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def get_token():
    out = subprocess.run(
        ['git', 'credential', 'fill'],
        input=b'protocol=https\nhost=github.com\n\n',
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode()
    for line in out.splitlines():
        if line.startswith('password='):
            return line.split('=', 1)[1]
    raise SystemExit('no github token from git credential manager')


TOKEN = get_token()


def api(method, path, payload=None):
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(
        f'{API}{path}', data=data, method=method,
        headers={'Authorization': f'Bearer {TOKEN}',
                 'Accept': 'application/vnd.github+json',
                 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read().decode('utf-8', 'replace')
            try:
                return resp.status, json.loads(body)
            except Exception:
                return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')[:400]


def git(*args):
    return subprocess.run(['git'] + list(args), cwd=ROOT,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT).stdout.decode('utf-8', 'replace')


def local_tree():
    """{path: (sha, size)} for every tracked file in the local tree."""
    out = git('ls-tree', '-r', '-z', '--long', 'HEAD')
    result = {}
    for entry in out.split('\0'):
        if not entry:
            continue
        meta, path = entry.split('\t', 1)
        # mode type sha size<TAB>path  (size may be '-' for trees)
        parts = meta.split()
        sha = parts[2] if len(parts) > 2 else ''
        result[path] = sha
    return result


def remote_tree():
    status, body = api('GET', '/git/trees/master?recursive=1')
    if status != 200 or not isinstance(body, dict):
        raise SystemExit(f'cannot read remote tree: {status} {body}')
    return {t['path']: t.get('sha') for t in body.get('tree', []) if t['type'] == 'blob'}


def blob_sha_of(path, ref='master'):
    quoted = urllib.parse.quote(path)
    status, body = api('GET', f'/contents/{quoted}?ref={ref}')
    if status == 200 and isinstance(body, dict):
        return body.get('sha')
    return None


def main():
    dry = '--dry-run' in sys.argv
    lt = local_tree()
    rt = remote_tree()

    to_add = [p for p in lt if p not in rt]
    to_del = [p for p in rt if p not in lt]
    to_chg = []
    for p in lt:
        if p in rt and lt[p] != rt[p]:
            # the remote sha is a blob sha, the local one is a tree blob sha --
            # compare by content instead
            full = os.path.join(ROOT, p)
            try:
                with open(full, 'rb') as fh:
                    data = fh.read()
            except OSError:
                continue
            import hashlib
            local_blob = hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()
            if local_blob != rt[p]:
                to_chg.append(p)

    print(f'新增 {len(to_add)} / 修改 {len(to_chg)} / 删除 {len(to_del)}')
    for p in to_add:
        print(f'  + {p}')
    for p in to_chg:
        print(f'  M {p}')
    for p in to_del:
        print(f'  - {p}')
    if dry:
        return 0

    msg = 'chore: sync the local tree (pushed through the REST API)'
    parent = None

    # deletions first: the contents API needs the blob sha of the existing file
    for p in to_del:
        sha = blob_sha_of(p)
        if not sha:
            continue
        status, body = api('DELETE', f'/contents/{urllib.parse.quote(p)}',
                           {'message': msg, 'branch': 'master', 'sha': sha})
        print(f'  删除 {p} -> {status}')
        if status not in (200, 204):
            print('    ', body)
            return 1
        if isinstance(body, dict):
            parent = body['commit']['sha']

    # then writes
    for p in to_add + to_chg:
        full = os.path.join(ROOT, p)
        with open(full, 'rb') as fh:
            data = fh.read()
        payload = {
            'message': msg,
            'branch': 'master',
            'content': base64.b64encode(data).decode(),
        }
        existing = blob_sha_of(p)
        if existing:
            payload['sha'] = existing
        status, body = api('PUT', f'/contents/{urllib.parse.quote(p)}', payload)
        print(f'  写入 {p} -> {status}')
        if status not in (200, 201):
            print('    ', body)
            return 1
        if isinstance(body, dict):
            parent = body['commit']['sha']
            time.sleep(0.4)   # contents API has a rate limit on concurrent writes

    time.sleep(2)
    status, body = api('GET', '/commits/master')
    print('\n远程 master 现在是:', body.get('sha', '')[:12] if isinstance(body, dict) else body)
    print('本地 master 是:    ', git('rev-parse', 'HEAD').strip()[:12])
    return 0


if __name__ == '__main__':
    sys.exit(main())
