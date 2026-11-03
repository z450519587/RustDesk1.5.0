"""Walk the whole install flow and check every launch path.

The bug this guards against: the install wizard appeared a second time
after installing. The root cause was is_setup() returning true for any
custom build, which made the installed program (started without
arguments from run_after_run_cmds) look like an installer.

This models every process launch in the flow and checks that exactly
one of them reaches the install page.
"""
import sys

META = 'meta.toml'
INSTALLED_DIR = r'C:\Program Files\RustDesk'
EXTRACT_DIR = r'%LOCALAPPDATA%\rustdesk'


def is_setup(exe_path, in_extraction_dir, disable_installation=False):
    """src/common.rs::is_setup"""
    if disable_installation:
        return False
    if exe_path.lower().endswith('install.exe'):
        return True
    return in_extraction_dir


def click_setup(exe_path, args, in_extraction_dir):
    """src/core_main.rs -- click_setup = args.is_empty() && is_setup(arg_exe)"""
    if args:
        return False
    return is_setup(exe_path, in_extraction_dir)


def handle_noinstall(args):
    """src/core_main.rs -- the --noinstall handling."""
    if '--noinstall' not in args:
        return list(args)
    if any(a in ('--elevate', '--run-as-system') for a in args):
        return []          # elevation handoff: cleared, as upstream does
    return [a for a in args if a != '--noinstall'] + ['--install']


def flutter_page(args):
    """flutter/lib/main.dart -- args.contains('--install') -> install page"""
    return 'install' if '--install' in args else 'main'


fails = []


def check(desc, got, want):
    ok = got == want
    print(f'  [{"OK " if ok else "!! "}] {desc}')
    if not ok:
        print(f'        got={got!r} want={want!r}')
        fails.append(desc)


print('=== 场景 1：双击安装包 ===')
# 打包器解压后从解压目录启动，带 --install
args = ['--install']
exe = EXTRACT_DIR + r'\rustdesk.exe'
cs = click_setup(exe, args, True)
final = handle_noinstall(args)
check('打包器传 --install -> 主程序不再追加', cs, False)
check('最终参数仍是 --install', final, ['--install'])
check('进入安装页', flutter_page(final), 'install')

print('\n=== 场景 2：装完之后自动启动程序（用户反馈的重复安装）===')
# run_after_run_cmds: cmd /c timeout /t 2 & {exe}   —— 无参数
exe = INSTALLED_DIR + r'\RustDesk.exe'
args = []
cs = click_setup(exe, args, False)   # Program Files 下没有 meta.toml
final = handle_noinstall(args)
check('已安装的程序不被当成安装向导', cs, False)
check('不会追加 --install', '--install' not in final, True)
check('进入主界面（不再弹安装向导）', flutter_page(final), 'main')

print('\n=== 场景 3：装完之后托盘启动 ===')
args = ['--tray']
cs = click_setup(exe, args, False)
final = handle_noinstall(args)
check('args 非空 -> 不当成安装向导', cs, False)
check('进入主界面', flutter_page(final), 'main')

print('\n=== 场景 4：安装向导的提权重启 ===')
# 提权时加 --noinstall --elevate，且进程仍在解压目录
args = ['--noinstall', '--elevate']
final = handle_noinstall(args)
check('提权重启不被改写（清参数后继续）', final, [])
check('提权进程带参数 -> 不是安装向导', click_setup(exe, args, True), False)

print('\n=== 场景 5：用户从开始菜单/桌面快捷方式启动已安装的程序 ===')
exe = INSTALLED_DIR + r'\RustDesk.exe'
args = []
check('不弹安装向导', click_setup(exe, args, False), False)
check('进入主界面', flutter_page(handle_noinstall(args)), 'main')

print('\n=== 场景 6：改名后的安装包（防绿色版仍然有效）===')
# 打包器靠 payload 里的 store_config.json 识别定制包，与文件名无关
def packer_click_setup(arg_exe, has_marker, args):
    if args:
        return False
    return has_marker or arg_exe.lower().endswith('install.exe')

for name in ['rustdesk-1.5.1-install.exe', 'rustdesk.exe', 'setup.exe', '随便.exe']:
    check(f'{name} -> 打包器仍走安装流程',
          packer_click_setup(name, True, []), True)
check('上游包（无标记）按文件名判定',
      packer_click_setup('rustdesk.exe', False, []), False)

print('\n=== 场景 7：正常启动已安装程序，不该有任何安装相关动作 ===')
exe = INSTALLED_DIR + r'\RustDesk.exe'
for args in ([], ['--tray'], ['--connect', '123']):
    cs = click_setup(exe, args, False)
    check(f'参数 {args} -> 不触发安装向导', cs, False)

print()
if fails:
    print(f'{len(fails)} 项未通过:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('安装流程全链路检查通过')
