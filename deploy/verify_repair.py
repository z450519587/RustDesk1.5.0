"""Does the repair step fix a broken installation?

The installer copies the payload with XCOPY /C, which can end up with a
half-copied directory (files present, subdirectories missing). The fix
adds a check after the copy and repairs it with robocopy.

This applies the same robocopy command the installer now uses, to a
directory that mimics a broken installation, and checks that the
missing pieces come back.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROBOCOPY = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'),
                        'System32', 'robocopy.exe')

REQUIRED = ['data\\app.so', 'librustdesk.dll', 'rustdesk.exe',
            'drivers\\x.dll', 'data\\icudtl.dat']


def make_payload(root):
    src = os.path.join(root, 'payload')
    os.makedirs(os.path.join(src, 'data'))
    os.makedirs(os.path.join(src, 'drivers'))
    files = {
        'rustdesk.exe': b'MZ',
        'librustdesk.dll': b'DLL' * 100,
        'data/app.so': b'ELF' * 100,
        'data/icudtl.dat': b'ICU' * 50,
        'drivers/x.dll': b'DRV' * 20,
    }
    for rel, content in files.items():
        with open(os.path.join(src, rel.replace('/', os.sep)), 'wb') as f:
            f.write(content)
    return src


def check(dst):
    missing = [r for r in REQUIRED
               if not os.path.isfile(os.path.join(dst, r.replace('/', os.sep)))]
    return missing


def main():
    root = tempfile.mkdtemp(prefix='repair_')
    src = make_payload(root)
    dst = os.path.join(root, 'RustDesk')

    # Simulate the broken installation: root files copied, subdirectories
    # missing (what happens when XCOPY loses its source halfway).
    os.makedirs(dst)
    for name in os.listdir(src):
        p = os.path.join(src, name)
        if os.path.isfile(p):
            shutil.copy2(p, os.path.join(dst, name))

    print('=== 损坏状态 ===')
    print(f'  目录: {sorted(n for n in os.listdir(dst) if os.path.isdir(os.path.join(dst, n)))}')
    print(f'  缺失的关键文件: {check(dst)}')

    print()
    print('=== 修复（与安装器现在用的 robocopy 一致）===')
    cmd = [ROBOCOPY, src, dst, '/E', '/IS', '/IT', '/NFL', '/NDL',
           '/NJH', '/NJS', '/NP', '/R:1', '/W:1']
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode('gbk', 'replace')
    print(f'  robocopy 退出码 {p.returncode}  (0-7 都算成功)')
    for l in out.strip().splitlines()[-3:]:
        print(f'    | {l}')

    missing = check(dst)
    print()
    print('=== 修复后 ===')
    print(f'  目录: {sorted(n for n in os.listdir(dst) if os.path.isdir(os.path.join(dst, n)))}')
    print(f'  缺失的关键文件: {missing}')
    ok = not missing
    print(f'  结论: {"✅ 修复成功，关键文件全部到位" if ok else "❌ 仍有缺失"}')

    shutil.rmtree(root, ignore_errors=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
