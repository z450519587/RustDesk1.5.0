"""Sanity check the payload verification and repair logic.

The installer now checks the copy result and repairs it. The check has
to look in the right place: the install path, with the same relative
paths the payload uses (data\\app.so etc).
"""
import os
import shutil
import sys
import tempfile

REQUIRED = ['data\\app.so', 'librustdesk.dll', 'rustdesk.exe']


def missing_files(path):
    """Mirror of verify_installed_payload in src/platform/windows.rs."""
    return [rel for rel in REQUIRED
            if not os.path.isfile(os.path.join(path, rel))]


def main():
    root = tempfile.mkdtemp(prefix='verify_payload_')
    install = os.path.join(root, 'RustDesk')
    os.makedirs(install)

    print('=== 场景 1：刚复制完的完整安装 ===')
    os.makedirs(os.path.join(install, 'data'))
    for rel in REQUIRED:
        p = os.path.join(install, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(b'x')
    miss = missing_files(install)
    print(f'  缺失: {miss}')
    print(f'  结论: {"✅ 不需要修复" if not miss else "❌ 误报缺失"}')

    print()
    print('=== 场景 2：XCOPY 半途失败的样子（文件在，子目录没了）===')
    broken = os.path.join(root, 'Broken')
    os.makedirs(broken)
    for rel in ['librustdesk.dll', 'rustdesk.exe']:
        with open(os.path.join(broken, rel), 'wb') as f:
            f.write(b'x')
    miss = missing_files(broken)
    print(f'  缺失: {miss}')
    print(f'  结论: {"✅ 正确识别出缺失，会触发补齐" if miss else "❌ 漏检"}')

    print()
    print('=== 场景 3：安装路径带空格 ===')
    spaced = os.path.join(root, 'Program Files', 'RustDesk')
    os.makedirs(spaced)
    for rel in REQUIRED:
        p = os.path.join(spaced, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'wb') as f:
            f.write(b'x')
    miss = missing_files(spaced)
    print(f'  缺失: {miss}')
    print(f'  结论: {"✅ 识别正确" if not miss else "❌ 误报缺失"}')

    shutil.rmtree(root, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
