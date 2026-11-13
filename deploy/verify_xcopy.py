"""What does the installer's XCOPY actually do?

The installed folder ended up with every file but none of the
directories -- no data\\, no drivers\\ -- so Flutter could not find
data\\app.so and the runner exited with code 1.

The installer copies the extracted payload with:

    XCOPY "<payload dir>" "<install dir>" /Y /E /H /C /I /K /R /Z

Two things are checked here:

  1. what happens when the destination does not exist yet (a first
     install)
  2. what happens when it already exists (a second install, or an
     upgrade) -- the installer is run again whenever the user clicks
     the button twice
"""
import os
import shutil
import subprocess
import tempfile

XCOPY = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'),
                      'System32', 'xcopy.exe')

CMD = r'XCOPY "{src}" "{dst}" /Y /E /H /C /I /K /R /Z'


def build_payload(root):
    src = os.path.join(root, 'payload')
    os.makedirs(os.path.join(src, 'data'))
    os.makedirs(os.path.join(src, 'drivers'))
    with open(os.path.join(src, 'rustdesk.exe'), 'wb') as f:
        f.write(b'MZ')
    with open(os.path.join(src, 'data', 'app.so'), 'wb') as f:
        f.write(b'ELF')
    with open(os.path.join(src, 'drivers', 'x.dll'), 'wb') as f:
        f.write(b'DLL')
    return src


def show(dst, label):
    print(f'  {label}:')
    for root, dirs, files in os.walk(dst):
        rel = os.path.relpath(root, dst)
        rel = '.' if rel == '.' else rel
        print(f'    目录 {rel}/  文件 {sorted(files)}')


def run_xcopy(src, dst):
    """Call xcopy with a real argument list (no shell, no re-quoting)."""
    p = subprocess.run(
        [XCOPY, src, dst, '/Y', '/E', '/H', '/C', '/I', '/K', '/R', '/Z'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode('gbk', 'replace')
    return p.returncode, out


def run_case(dst_exists, dst_has_content):
    root = tempfile.mkdtemp(prefix='xcopy_case_')
    src = build_payload(root)
    dst = os.path.join(root, 'RustDesk')
    if dst_exists:
        os.makedirs(dst)
        if dst_has_content:
            with open(os.path.join(dst, 'old.dll'), 'wb') as f:
                f.write(b'OLD')
    code, out = run_xcopy(src, dst)
    print(f'  xcopy 退出码 {code}')
    for l in out.strip().splitlines()[-4:]:
        print(f'    | {l}')
    show(dst, '目标内容')
    print(f'  源目录是否完好: data={os.path.isdir(os.path.join(src,"data"))} '
          f'drivers={os.path.isdir(os.path.join(src,"drivers"))}')
    shutil.rmtree(root, ignore_errors=True)


def main():
    print('=== 场景 1：目标不存在（首次安装）===')
    run_case(dst_exists=False, dst_has_content=False)

    print()
    print('=== 场景 2：目标已存在且为空（第二次点击安装）===')
    run_case(dst_exists=True, dst_has_content=False)

    print()
    print('=== 场景 3：目标已存在且有文件（覆盖安装）===')
    run_case(dst_exists=True, dst_has_content=True)

    print()
    print('=== 场景 4：对照 —— 源写成 "dir\\*" （复制内容而非目录本身）===')
    root = tempfile.mkdtemp(prefix='xcopy_star_')
    src = build_payload(root)
    dst = os.path.join(root, 'RustDesk')
    os.makedirs(dst)
    code, out = run_xcopy(os.path.join(src, '*'), dst)
    print(f'  xcopy 退出码 {code}')
    show(dst, '目标内容')
    shutil.rmtree(root, ignore_errors=True)

    print()
    print('=== 场景 5：对照 —— 源写成 "dir\\*" 且目标不存在 ===')
    root = tempfile.mkdtemp(prefix='xcopy_star2_')
    src = build_payload(root)
    dst = os.path.join(root, 'RustDesk')
    code, out = run_xcopy(os.path.join(src, '*'), dst)
    print(f'  xcopy 退出码 {code}')
    show(dst, '目标内容')
    shutil.rmtree(root, ignore_errors=True)

    print()
    print('=== 场景 6：目标路径带空格（真实的 "Program Files" 情形）===')
    root = tempfile.mkdtemp(prefix='xcopy_space_')
    src = build_payload(root)
    parent = os.path.join(root, 'Program Files')
    os.makedirs(parent)
    dst = os.path.join(parent, 'RustDesk')
    code, out = run_xcopy(src, dst)
    print(f'  xcopy 退出码 {code}')
    for l in out.strip().splitlines()[-3:]:
        print(f'    | {l}')
    show(dst, '目标内容')
    shutil.rmtree(root, ignore_errors=True)

    print()
    print('=== 场景 7：目标带空格且已存在（覆盖安装）===')
    root = tempfile.mkdtemp(prefix='xcopy_space2_')
    src = build_payload(root)
    parent = os.path.join(root, 'Program Files')
    os.makedirs(parent)
    dst = os.path.join(parent, 'RustDesk')
    os.makedirs(dst)
    with open(os.path.join(dst, 'old.dll'), 'wb') as f:
        f.write(b'OLD')
    code, out = run_xcopy(src, dst)
    print(f'  xcopy 退出码 {code}')
    show(dst, '目标内容')
    shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    main()
