"""Dry run of the installer's repair path.

Reproduces what the installer now does on a machine whose copy came out
incomplete:

  1. detect the missing pieces
  2. repair them with the same robocopy command the installer uses
  3. confirm they are back

The payload directory stands in for %LOCALAPPDATA%\\rustdesk and the
install directory for Program Files\\RustDesk.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROBOCOPY = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'),
                        'System32', 'robocopy.exe')

# The three files the installer checks.
REQUIRED = ['data\\app.so', 'librustdesk.dll', 'rustdesk.exe']

# The full payload, including the parts that end up missing.
PAYLOAD = {
    'rustdesk.exe': b'MZ' * 100,
    'librustdesk.dll': b'DLL' * 1000,
    'flutter_windows.dll': b'FLUTTER' * 500,
    'data/app.so': b'ELF' * 1000,
    'data/icudtl.dat': b'ICU' * 100,
    'data/flutter_assets/AssetManifest.json': b'{}',
    'drivers/x.dll': b'DRV' * 20,
    'usbmmidd_v2/y.dll': b'USB' * 20,
}


def build_payload(root):
    src = os.path.join(root, 'payload')
    for rel in PAYLOAD:
        p = os.path.join(src, rel.replace('/', os.sep))
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(PAYLOAD[rel])
    return src


def missing_files(install):
    """Same check as verify_installed_payload."""
    return [rel for rel in REQUIRED
            if not os.path.isfile(os.path.join(install, rel.replace('/', os.sep)))]


def main():
    root = tempfile.mkdtemp(prefix='repair_dry_')
    src = build_payload(root)
    install = os.path.join(root, 'RustDesk')

    # A broken install: the root files landed, the subdirectories did not.
    os.makedirs(install)
    for name in os.listdir(src):
        p = os.path.join(src, name)
        if os.path.isfile(p):
            shutil.copy2(p, os.path.join(install, name))

    print('=== 1. 检测 ===')
    miss = missing_files(install)
    print(f'  缺失: {miss}')
    if not miss:
        print('  没有缺失，不需要修复')
        shutil.rmtree(root, ignore_errors=True)
        return 0

    print()
    print('=== 2. 修复（安装器用的 robocopy 命令）===')
    rc = subprocess.run(
        [ROBOCOPY, src, install, '/E', '/IS', '/IT', '/NFL', '/NDL',
         '/NJH', '/NJS', '/NP', '/R:1', '/W:1'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
    print(f'  robocopy 退出码 {rc}（0-7 都算成功）')

    print()
    print('=== 3. 复查 ===')
    miss = missing_files(install)
    dirs = sorted(n for n in os.listdir(install) if os.path.isdir(os.path.join(install, n)))
    files = sum(len(f) for _, _, f in os.walk(install))
    print(f'  目录: {dirs}')
    print(f'  文件数: {files}')
    print(f'  仍然缺失: {miss}')

    # Everything the payload has must be in the install afterwards.
    not_copied = []
    for rel in PAYLOAD:
        if not os.path.isfile(os.path.join(install, rel.replace('/', os.sep))):
            not_copied.append(rel)
    print(f'  payload 里没复制过去的: {not_copied}')

    shutil.rmtree(root, ignore_errors=True)
    ok = not miss and not not_copied
    print()
    print('结论:', '✅ 修复完整，安装目录与 payload 一致' if ok else '❌ 仍有缺失')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
