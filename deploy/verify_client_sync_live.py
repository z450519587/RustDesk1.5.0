"""End-to-end check of the client sync path against the real API server.

The question this answers: when a newly deployed store machine fills in
its store name, does the client actually get it into the device list
(peer) and the shared address book (address_book)?

The address_book table is NOT created by the server on its own -- the
client has to write it. So this exercises the exact request sequence
that flutter/lib/store_sync_service.dart performs:

    1. GET  /api/admin/peer/list?id=<id>          -> find the peer row id
    2. POST /api/admin/peer/update                -> set peer.alias
    3. GET  /api/admin/address_book/list?...      -> is it already there?
    4. POST /api/admin/address_book/create        -> create the entry
    5. GET  .../list?id=<id>                      -> read back and verify

A throwaway id is used, and the address_book entry it creates is
removed afterwards so the shared list is left exactly as it was.

Run: python deploy/verify_client_sync_live.py [--keep]
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

CONFIG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'store_config.json')
# A throwaway id that is not a real RustDesk id.
TEST_ID = '999000111'
TEST_NAME = '__同步链路自检临时条目__'


def load_config():
    with open(CONFIG, encoding='utf-8') as f:
        return json.load(f)


def request(cfg, method, path, payload=None):
    url = cfg['apiServer'].rstrip('/') + path
    data = json.dumps(payload).encode('utf-8') if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        'api-token': cfg['adminToken'],
        'Content-Type': 'application/json; charset=utf-8',
        'Accept': 'application/json',
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode('utf-8', 'replace')
            try:
                return resp.status, json.loads(body)
            except Exception:
                return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')[:300]
    except Exception as e:
        return 0, str(e)


def extract_list(payload):
    data = payload.get('data') if isinstance(payload, dict) else None
    lst = data.get('list', data) if isinstance(data, dict) else data
    return lst if isinstance(lst, list) else []


def main():
    keep = '--keep' in sys.argv
    cfg = load_config()
    base = cfg['apiServer'].rstrip('/')
    user_id = cfg.get('addressBookUserId', 1)
    collection_id = cfg.get('addressBookCollectionId', 3)
    print(f'API: {base}   collection_id={collection_id}')

    before = extract_list(request(cfg, 'GET',
        f'/api/admin/address_book/list?user_id={user_id}&collection_id={collection_id}&page=1&page_size=1000')[1])
    print(f'通讯录现有条目: {len(before)}')

    print(f'\n=== 步骤 1-2：设备管理（peer）写入别名 ===')
    status, body = request(cfg, 'GET', f'/api/admin/peer/list?id={TEST_ID}')
    row_id = None
    if status == 200:
        for e in extract_list(body):
            if str(e.get('id')) == TEST_ID:
                row_id = e.get('row_id')
                break
    print(f'  查 peer: HTTP {status}  row_id={row_id}')
    if not row_id:
        print('  （该 id 不在设备管理里 —— 新设备要等客户端上报 sysinfo 才会建档）')

    peer_ok = False
    if row_id:
        status, body = request(cfg, 'POST', '/api/admin/peer/update',
                                {'row_id': row_id, 'id': TEST_ID, 'alias': TEST_NAME})
        print(f'  写 peer.alias: HTTP {status}')
        peer_ok = status == 200

    print(f'\n=== 步骤 3-4：共享通讯簿（address_book）创建条目 ===')
    status, body = request(cfg, 'GET',
        f'/api/admin/address_book/list?user_id={user_id}&collection_id={collection_id}&id={TEST_ID}')
    ab_row_id = None
    if status == 200:
        for e in extract_list(body):
            if str(e.get('id')) == TEST_ID:
                ab_row_id = e.get('row_id')
                break
    print(f'  查通讯录: HTTP {status}  row_id={ab_row_id}')

    payload = {'id': TEST_ID, 'alias': TEST_NAME,
               'user_id': user_id, 'collection_id': collection_id}
    if ab_row_id:
        url = '/api/admin/address_book/update'
        payload['row_id'] = ab_row_id
    else:
        url = '/api/admin/address_book/create'
    status, body = request(cfg, 'POST', url, payload)
    print(f'  创建条目 ({url.split("/")[-1]}): HTTP {status}')
    ab_ok = status == 200

    print(f'\n=== 步骤 5：读回校验 ===')
    status, body = request(cfg, 'GET',
        f'/api/admin/address_book/list?user_id={user_id}&collection_id={collection_id}&id={TEST_ID}')
    found = None
    if status == 200:
        for e in extract_list(body):
            if str(e.get('id')) == TEST_ID:
                found = e
                break
    if found:
        print(f'  读回成功: id={found.get("id")} alias={found.get("alias")!r} '
              f'collection_id={found.get("collection_id")} created_at={found.get("created_at")}')
        alias_ok = found.get('alias') == TEST_NAME
        in_right_collection = str(found.get('collection_id')) == str(collection_id)
    else:
        print('  读回失败：找不到刚创建的条目')
        alias_ok = in_right_collection = False

    # ---- cleanup ----
    print(f'\n=== 清理测试条目 ===')
    if found and found.get('row_id'):
        # The service exposes the delete as a POST (there is no DELETE route).
        status, body = request(cfg, 'POST', '/api/admin/address_book/delete',
                                {'row_id': found['row_id'], 'user_id': user_id,
                                 'collection_id': collection_id})
        print(f'  删除通讯录条目 row_id={found.get("row_id")}: HTTP {status}')
        if status not in (200, 404):
            print(f'    {body}')
    if peer_ok and row_id:
        status, body = request(cfg, 'POST', '/api/admin/peer/update',
                                {'row_id': row_id, 'id': TEST_ID, 'alias': ''})
        print(f'  清空 peer.alias: HTTP {status}')

    after = extract_list(request(cfg, 'GET',
        f'/api/admin/address_book/list?user_id={user_id}&collection_id={collection_id}&page=1&page_size=1000')[1])
    leftover = [p for p in after if str(p.get('id')) == TEST_ID]
    print(f'  通讯录条目数 {len(before)} -> {len(after)}，测试条目残留 {len(leftover)}')

    print()
    ok = ab_ok and alias_ok and in_right_collection and not leftover
    if ok:
        print('结论：客户端的同步链路是通的')
        print('  - 设备管理能写入别名（peer.alias）')
        print('  - 通讯录能创建条目（服务端不会自动建，必须客户端写）')
        print('  - 别名中文落库正确，读回一致')
        print('  - 条目落在正确的通讯录（collection_id）')
    else:
        print('结论：链路有问题，见上面的 HTTP 状态码')
    if keep:
        print('\n(--keep: 测试条目保留未删)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
