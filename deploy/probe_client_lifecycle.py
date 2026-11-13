"""Watch what the installed client actually does when it is started.

Starting the installed program produced a client log of only one line
and the process was gone again a few seconds later -- so it exits
somewhere after "Preload peers". This samples the process table every
200 ms to find out how long it lives and whether a window ever appears.
"""
import ctypes
import subprocess
import sys
import time

kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
user32 = ctypes.WinDLL('user32', use_last_error=True)

EXE = r'C:\Program Files\RustDesk\RustDesk.exe'


def list_rustdesk():
    out = subprocess.run(
        ['tasklist', '/FI', 'IMAGENAME eq RustDesk.exe', '/FO', 'CSV', '/NH'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    pids = []
    for line in out.stdout.decode('utf-8', 'replace').splitlines():
        parts = [p.strip('" ') for p in line.split('","')]
        if len(parts) >= 2 and parts[1].isdigit():
            pids.append(int(parts[1]))
    return pids


def windows_of(pid):
    """Count visible top level windows owned by the pid."""
    found = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    def cb(hwnd, _):
        owner = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd):
            n = ctypes.create_unicode_buffer(256)
            user32.GetWindowTextW(hwnd, n, 256)
            found.append(n.value)
        return True

    user32.EnumWindows(cb, 0)
    return found


def main():
    before = set(list_rustdesk())
    print(f'启动前的进程: {sorted(before)}')

    p = subprocess.Popen([EXE])
    print(f'已启动 PID {p.pid}')

    seen_alive = False
    samples = 0
    t0 = time.time()
    while time.time() - t0 < 12:
        time.sleep(0.2)
        samples += 1
        alive = p.poll() is None
        now = set(list_rustdesk())
        new = now - before
        if new:
            seen_alive = True
            wins = []
            for pid in new:
                wins.extend(windows_of(pid))
            print(f'  [{time.time()-t0:5.1f}s] 新进程 {sorted(new)}  可见窗口 {wins}')
        if not alive:
            print(f'  [{time.time()-t0:5.1f}s] 主进程已退出，退出码 {p.returncode}')
            break

    if seen_alive:
        # give it a moment, then look again
        time.sleep(1)
        now = set(list_rustdesk())
        new = now - before
        wins = []
        for pid in new:
            wins.extend(windows_of(pid))
        print(f'结束时的进程 {sorted(new)}  可见窗口 {wins}')

    print()
    print(f'采样 {samples} 次；进程曾存活: {seen_alive}')


if __name__ == '__main__':
    main()
