"""Model the extraction-directory cleanup that runs after installation.

After the installer finishes, the portable packer's extraction directory
(%LOCALAPPDATA%\\rustdesk) still holds a complete runnable copy of the
client. That copy is a portable version of the program: copy it
elsewhere and it runs without installing, and the uninstall entry never
touches it.

The cleanup runs in a background thread and retries, because the files
are still locked while the installer itself is running from that
directory. This models the retry loop and checks the properties that
matter:

  1. the directory is gone once the installer exits
  2. a directory that cannot be removed does not break the installation
  3. the installed copy under Program Files is never touched
"""
import os
import shutil
import sys
import tempfile
import threading
import time

INSTALL_DIR_NAME = 'rustdesk'
PROGRAM_FILES = 'Program Files'


def model_cleanup(local_appdata, installed_root, lock_holds=0, fail_forever=False):
    """Model the cleanup thread.

    lock_holds: how many more attempts will fail because the installer
                still holds the files.
    fail_forever: the directory can never be removed.
    Returns (removed: bool, attempts: int).

    On Windows a running process keeps its executables locked, so the
    directory cannot be deleted while the installer is still running
    from it. That is modelled here with an explicit failure count --
    shutil.rmtree on Linux would happily delete the files, which is not
    what happens on Windows.
    """
    target = os.path.join(local_appdata, INSTALL_DIR_NAME)
    if not os.path.isdir(target):
        return False, 0

    attempts = 0
    for _ in range(60):
        attempts += 1
        if fail_forever:
            time.sleep(0.01)
            continue
        if lock_holds > 0:
            lock_holds -= 1
            time.sleep(0.02)
            continue
        try:
            shutil.rmtree(target)
            return True, attempts
        except OSError:
            time.sleep(0.02)
    return False, attempts


def build_fixture(root):
    """Create a fake extraction dir and an installed copy."""
    local = os.path.join(root, 'AppData', 'Local')
    extraction = os.path.join(local, INSTALL_DIR_NAME)
    os.makedirs(os.path.join(extraction, 'data'))
    with open(os.path.join(extraction, 'rustdesk.exe'), 'wb') as f:
        f.write(b'MZ' + b'\x00' * 100)
    with open(os.path.join(extraction, 'data', 'app.so'), 'wb') as f:
        f.write(b'\x7fELF' + b'\x00' * 100)

    installed = os.path.join(root, PROGRAM_FILES, 'RustDesk')
    os.makedirs(installed)
    with open(os.path.join(installed, 'RustDesk.exe'), 'wb') as f:
        f.write(b'MZ' + b'\x00' * 100)
    return local, installed


fails = []


def check(desc, cond):
    print(f'  [{"OK " if cond else "!! "}] {desc}')
    if not cond:
        fails.append(desc)


print('=== 1. 安装完成后解压目录被清掉，程序安装目录不受影响 ===')
root = tempfile.mkdtemp(prefix='cleanup_model_')
local, installed = build_fixture(root)
extraction = os.path.join(local, INSTALL_DIR_NAME)
check('清理前解压目录存在', os.path.isdir(extraction))

removed, attempts = model_cleanup(local, installed, lock_holds=3)
check('解压目录已被删除', not os.path.isdir(extraction))
check(f'重试了 {attempts} 次后成功（安装进程占用时先失败几次）', removed and attempts >= 4)
check('Program Files 里的安装副本仍在',
      os.path.isfile(os.path.join(installed, 'RustDesk.exe')))
shutil.rmtree(root, ignore_errors=True)

print('\n=== 2. 删不掉也不影响使用 ===')
root = tempfile.mkdtemp(prefix='cleanup_model_')
local, installed = build_fixture(root)
removed, attempts = model_cleanup(local, installed, fail_forever=True)
check('删不掉时返回未删除（安装本身已成功，不报错）', removed is False)
check('Program Files 里的安装副本仍在',
      os.path.isfile(os.path.join(installed, 'RustDesk.exe')))
check('重试次数有上限（不会无限循环）', attempts == 60)
shutil.rmtree(root, ignore_errors=True)

print('\n=== 3. 没有解压目录时（已装好的机器再跑一次）不报错 ===')
root = tempfile.mkdtemp(prefix='cleanup_model_')
local = os.path.join(root, 'AppData', 'Local')
os.makedirs(local)
removed, attempts = model_cleanup(local, None)
check('直接返回，不做任何删除', removed is False and attempts == 0)
shutil.rmtree(root, ignore_errors=True)

print('\n=== 4. 只删自己那个目录，不碰别的 ===')
root = tempfile.mkdtemp(prefix='cleanup_model_')
local, installed = build_fixture(root)
# 同目录下另一个应用的数据，不能被误删
other = os.path.join(local, 'SomeOtherApp')
os.makedirs(other)
with open(os.path.join(other, 'data.txt'), 'wb') as f:
    f.write(b'keep me')
model_cleanup(local, installed)
check('同级其他应用目录未被删除', os.path.isfile(os.path.join(other, 'data.txt')))
shutil.rmtree(root, ignore_errors=True)

print()
if fails:
    print(f'{len(fails)} 项未通过:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('全部检查通过')
