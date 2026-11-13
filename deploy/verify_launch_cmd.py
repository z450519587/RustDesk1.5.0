"""Reproduce the launch of the installed program, byte for byte.

The installer starts the program it just installed with:

    Command::new("cmd")
        .args(["/c", "timeout", "/t", "2", "&", &format!("{exe}")])

Rust builds the command line itself (no shell is involved), so the
argument list is escaped by Rust's own rules and handed to
CreateProcessW. This script does exactly the same thing through
ctypes, so the command line that reaches cmd.exe is identical.

Why it matters: the installed path contains a space
("C:\\Program Files\\RustDesk\\RustDesk.exe"). If cmd.exe mis-parses
the command line, the program never starts -- and since the tray
process is spawned directly (not through cmd), the symptom is
"background process is there, but no window".
"""
import ctypes
import os
import subprocess
import sys
import tempfile
from ctypes import wintypes

kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

CREATE_NO_WINDOW = 0x08000000


class STARTUPINFO(ctypes.Structure):
    _fields_ = [
        ('cb', wintypes.DWORD),
        ('lpReserved', wintypes.LPWSTR),
        ('lpDesktop', wintypes.LPWSTR),
        ('lpTitle', wintypes.LPWSTR),
        ('dwX', wintypes.DWORD),
        ('dwY', wintypes.DWORD),
        ('dwXSize', wintypes.DWORD),
        ('dwYSize', wintypes.DWORD),
        ('dwXCountChars', wintypes.DWORD),
        ('dwYCountChars', wintypes.DWORD),
        ('dwFillAttribute', wintypes.DWORD),
        ('dwFlags', wintypes.DWORD),
        ('wShowWindow', wintypes.WORD),
        ('cbReserved2', wintypes.WORD),
        ('lpReserved2', ctypes.POINTER(ctypes.c_byte)),
        ('hStdInput', wintypes.HANDLE),
        ('hStdOutput', wintypes.HANDLE),
        ('hStdError', wintypes.HANDLE),
    ]


class PROCESS_INFORMATION(ctypes.Structure):
    _fields_ = [
        ('hProcess', wintypes.HANDLE),
        ('hThread', wintypes.HANDLE),
        ('dwProcessId', wintypes.DWORD),
        ('dwThreadId', wintypes.DWORD),
    ]


kernel32.CreateProcessW.restype = wintypes.BOOL


def rust_quote(args):
    """Reproduce Rust's std::process::Command argument escaping.

    Rust quotes an argument only when it contains a space, a tab or a
    quote; everything else is passed through untouched. That is what
    makes `&` a command separator for cmd.exe.
    """
    out = []
    for a in args:
        if a == '':
            out.append('""')
        elif ' ' not in a and '\t' not in a and '"' not in a:
            out.append(a)
        else:
            out.append('"' + a.replace('\\', '\\\\').replace('"', '\\"') + '"')
    return ' '.join(out)


def run_exact(args, cwd=None):
    """Run a command line exactly as Rust would build it.

    Python's subprocess hands a string command line to CreateProcessW
    unchanged, so passing the already-escaped string together with
    executable= reproduces Rust's Command::new(prog).args(list).
    """
    cmdline = rust_quote(args)
    print(f'  命令行: {cmdline}')
    # CreateProcess does not search PATH for lpApplicationName, so cmd.exe
    # has to be given by its absolute path.
    exe = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'),
                       'System32', 'cmd.exe') if args[0] == 'cmd' else args[0]
    try:
        p = subprocess.Popen(cmdline, executable=exe, cwd=cwd,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        code = p.wait(timeout=20)
    except Exception as e:
        print(f'  -> 启动异常: {e}')
        return None
    print(f'  -> 退出码 {code}')
    return code


def make_probe(directory):
    """A tiny program that records that it ran."""
    path = os.path.join(directory, 'probe_ran.txt')
    if os.path.exists(path):
        os.remove(path)
    return path


def main():
    # A directory whose name contains a space, like Program Files.
    base = tempfile.gettempdir()
    spaced = os.path.join(base, 'RustDesk probe dir')
    os.makedirs(spaced, exist_ok=True)
    marker = make_probe(spaced)

    # A .cmd that writes the marker file when it runs.
    script = os.path.join(spaced, 'probe.cmd')
    with open(script, 'w', encoding='ascii') as f:
        f.write('@echo off\r\n')
        f.write('echo RAN>"%s"\r\n' % marker.replace('\\', '\\'))

    print('=== 场景 A：安装后自动启动主界面的写法（经 cmd，路径带空格）===')
    code = run_exact(['cmd', '/c', 'timeout', '/t', '2', '&', script])
    ran = os.path.exists(marker)
    print(f'  -> 退出码 {code}，探针被写入: {ran}')
    print(f'  结论: {"成功启动" if ran else "❌ 启动失败 —— 这就是没有界面的原因"}')

    print()
    print('=== 场景 B：托盘进程的写法（直接 spawn，不经 cmd）===')
    make_probe(spaced)
    code = run_exact([script, '--tray'])
    ran = os.path.exists(marker)
    print(f'  -> 退出码 {code}，探针被写入: {ran}')
    print(f'  结论: {"成功启动" if ran else "❌ 启动失败"}')

    print()
    print('=== 场景 C：对照 —— cmd /c 但路径不带空格 ===')
    plain = os.path.join(base, 'RustDeskProbePlain')
    os.makedirs(plain, exist_ok=True)
    script2 = os.path.join(plain, 'probe.cmd')
    with open(script2, 'w', encoding='ascii') as f:
        f.write('@echo off\r\n')
        f.write('echo RAN>"%s"\r\n' % marker.replace('\\', '\\'))
    make_probe(spaced)
    code = run_exact(['cmd', '/c', 'timeout', '/t', '2', '&', script2])
    ran = os.path.exists(marker)
    print(f'  -> 退出码 {code}，探针被写入: {ran}')
    print(f'  结论: {"成功启动" if ran else "❌ 启动失败"}')

    print()
    print('=== 场景 D：修好的写法 —— 绕开 cmd，直接 spawn，延迟由自己控制 ===')
    make_probe(spaced)
    code = run_exact([script])
    ran = os.path.exists(marker)
    print(f'  -> 退出码 {code}，探针被写入: {ran}')
    print(f'  结论: {"成功启动" if ran else "❌ 启动失败"}')

    import shutil
    shutil.rmtree(spaced, ignore_errors=True)
    shutil.rmtree(plain, ignore_errors=True)


if __name__ == '__main__':
    main()
