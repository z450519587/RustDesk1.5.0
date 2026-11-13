"""Does renaming a directory that holds a running program fail on Windows?

The packer uses a rename probe to tell whether the extraction directory
is still in use by a running installation. That only works if Windows
refuses to rename a directory whose files are open.

This starts a real process out of a directory and then tries to rename
the directory, rename it back, and delete it -- the three things the
packer does.
"""
import ctypes
import os
import shutil
import subprocess
import sys
import tempfile
import time

kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)


def start_program_in(dirpath):
    """Start a long running program from inside dirpath."""
    # A batch that waits keeps the directory "in use" the same way a
    # running exe does.
    script = os.path.join(dirpath, 'holder.cmd')
    with open(script, 'w', encoding='ascii') as f:
        f.write('@echo off\r\n')
        f.write('ping -n 30 127.0.0.1 > nul\r\n')
    p = subprocess.Popen(['cmd', '/c', script], cwd=dirpath,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return p


def main():
    root = tempfile.mkdtemp(prefix='busycheck_')
    d = os.path.join(root, 'extracted')
    os.makedirs(d)
    with open(os.path.join(d, 'app.so'), 'wb') as f:
        f.write(b'X' * 1024)

    print('=== 场景 1：目录里没有程序运行 ===')
    probe = d + '.busycheck'
    try:
        os.rename(d, probe)
        print('  重命名: 成功')
        os.rename(probe, d)
        busy = False
    except OSError as e:
        print(f'  重命名: 失败 ({e.winerror if hasattr(e,"winerror") else e})')
        busy = True
    print(f'  -> 判定为"占用": {busy}  (期望 False)')

    print()
    print('=== 场景 2：目录里有程序正在运行 ===')
    p = start_program_in(d)
    time.sleep(1.5)
    try:
        os.rename(d, probe)
        print('  重命名: 成功  <-- 说明改名试探法在这个场景下不可靠')
        os.rename(probe, d)
        busy = False
    except OSError as e:
        print(f'  重命名: 失败 ({e.winerror if hasattr(e,"winerror") else e})')
        busy = True
    print(f'  -> 判定为"占用": {busy}  (期望 True)')

    print()
    print('=== 场景 3：目录被占用时能否删除 ===')
    try:
        shutil.rmtree(d)
        print('  删除: 成功（目录树被清掉了！）')
        deleted = True
    except OSError as e:
        print(f'  删除: 失败 ({e.winerror if hasattr(e,"winerror") else e})')
        deleted = False
    print(f'  剩余文件: {sorted(os.listdir(d)) if os.path.isdir(d) else "(目录已消失)"}')
    print(f'  -> 会被删掉: {deleted}')

    p.terminate()
    try:
        p.wait(timeout=5)
    except Exception:
        p.kill()
    shutil.rmtree(root, ignore_errors=True)

    print()
    if busy:
        print('结论：改名试探法可用 —— 占用时重命名确实失败')
    else:
        print('结论：改名试探法不可靠 —— 占用时重命名照样成功，防护会失效')


if __name__ == '__main__':
    main()
