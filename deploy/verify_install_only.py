"""Verify the install-only enforcement logic.

The Rust side decides whether a launch counts as an installation. That
decision is made in three places, and each one can be modelled here:

  1. libs/portable/src/main.rs  -- the packer: does this launch install?
  2. src/common.rs               -- is_setup(): the same question, asked
                                   by the installed program
  3. src/core_main.rs            -- what happens to a --noinstall argument

The rule the store build follows: a custom package (one that ships
store_config.json) must always install, no matter what the file is named.
"""

import sys

APP_BRAND_NAME = "仁和堂专用远程工具"   # hbb_common::config::APP_BRAND_NAME
CUSTOM_PACKAGE_MARKER = "store_config.json"
APP_PREFIX = "rustdesk"


def normalize_path(path):
    """libs/portable/src/bin_reader.rs::normalize_path"""
    return path.replace('\\', "/").lstrip("./").lower()


def is_custom_package(files):
    """libs/portable/src/main.rs -- marker file inside the payload."""
    return any(normalize_path(p).endswith(CUSTOM_PACKAGE_MARKER) for p in files)


def packer_click_setup(arg_exe, files, args):
    """libs/portable/src/main.rs -- click_setup."""
    if args:
        return False
    return is_custom_package(files) or arg_exe.lower().endswith("install.exe")


def packer_quick_support(arg_exe, files, args):
    """libs/portable/src/main.rs -- quick_support.

    A 'quick support' launch skips the installation too (it starts with
    --quick_support instead of --install), so it is closed for custom
    packages.
    """
    if args or is_custom_package(files):
        return False
    exe = arg_exe.lower()
    return "-qs-" in exe or "-qs.exe" in exe or "_qs.exe" in exe


def is_setup(name, disable_installation=False, in_extraction_dir=False,
             brand=APP_BRAND_NAME):
    """src/common.rs -- is_setup().

    `in_extraction_dir` means the process runs from the packer's
    extraction directory (the one holding meta.toml), which is how the
    installer tells "I am the installer" apart from "I am the installed
    program". Without it the installed program would look like an
    installer on every start and pop the wizard again.

    `brand` is the compile-time APP_BRAND_NAME: the meta.toml check is
    only enabled for the custom build, so upstream keeps its original
    filename-only behaviour.
    """
    if disable_installation:
        return False
    if name.lower().endswith("install.exe"):
        return True
    if brand == "RustDesk":
        return False
    return in_extraction_dir


def resolve_noinstall(args, is_custom):
    """src/core_main.rs -- what happens to a --noinstall argument.

    Returns the argument list that survives.
    """
    if "--noinstall" not in args:
        return list(args)
    # The elevation handoff inside the installer passes --noinstall together
    # with --elevate / --run-as-system. That one must survive untouched.
    if any(a in ("--elevate", "--run-as-system") for a in args):
        return []
    if is_custom:
        # A custom package refuses to skip the installation.
        out = [a for a in args if a != "--noinstall"]
        if "--install" not in out:
            out.append("--install")
        return out
    return []


CUSTOM_FILES = [".\\rustdesk.exe", ".\\data\\app.so", ".\\store_config.json"]
STOCK_FILES = [".\\rustdesk.exe", ".\\data\\app.so"]

fails = []


def check(desc, got, want):
    ok = got == want
    print(f'  [{"OK " if ok else "!! "}] {desc}')
    if not ok:
        print(f'        got={got!r} want={want!r}')
        fails.append(desc)


print('=== 1. 打包器：定制包无论改名都走安装流程 ===')
check('原名 rustdesk-1.5.1-install.exe',
      packer_click_setup('rustdesk-1.5.1-install.exe', CUSTOM_FILES, []), True)
check('改名 rustdesk.exe（漏洞1）',
      packer_click_setup('rustdesk.exe', CUSTOM_FILES, []), True)
check('改名 setup.exe',
      packer_click_setup('setup.exe', CUSTOM_FILES, []), True)
check('改名 随便什么.exe',
      packer_click_setup('随便什么.exe', CUSTOM_FILES, []), True)
check('上游包（无标记文件）仍按文件名判定',
      packer_click_setup('rustdesk.exe', STOCK_FILES, []), False)
check('上游包 install.exe 走安装',
      packer_click_setup('rustdesk-install.exe', STOCK_FILES, []), True)

print('\n=== 2. is_setup()：区分「安装向导」与「已安装的程序」===')
check('定制包：从解压目录启动（安装向导）认安装',
      is_setup('rustdesk.exe', in_extraction_dir=True), True)
check('定制包：已安装的程序（Program Files，无 meta.toml）不认安装',
      is_setup('RustDesk.exe'), False)
check('定制包：文件名带 install.exe 也认安装',
      is_setup('rustdesk-1.5.1-install.exe'), True)
check('上游包 普通名不认安装',
      is_setup('rustdesk.exe'), False)
check('上游包 install.exe 走安装',
      is_setup('rustdesk-install.exe'), True)
check('上游包 从解压目录启动也不认安装（保持上游原行为）',
      is_setup('rustdesk.exe', in_extraction_dir=True, brand='RustDesk'), False)
check('显式禁用安装时不认（上游开关仍生效）',
      is_setup('rustdesk.exe', disable_installation=True), False)
check('显式禁用安装时 解压目录也不认',
      is_setup('rustdesk.exe', disable_installation=True, in_extraction_dir=True), False)

print('\n=== 3. --noinstall 参数处理 ===')
check('定制包：单独 --noinstall 被改写成 --install',
      resolve_noinstall(['--noinstall'], True), ['--install'])
check('定制包：--noinstall 与 --install 同时给出时保持 --install',
      resolve_noinstall(['--noinstall', '--install'], True), ['--install'])
check('定制包：提权重启 --noinstall --elevate 原样放行（清参数）',
      resolve_noinstall(['--noinstall', '--elevate'], True), [])
check('定制包：提权重启 --noinstall --run-as-system 放行',
      resolve_noinstall(['--noinstall', '--run-as-system'], True), [])
check('上游包：--noinstall 仍清参数（保持原行为）',
      resolve_noinstall(['--noinstall'], False), [])
check('无关参数不受影响',
      resolve_noinstall(['--tray'], True), ['--tray'])

print('\n=== 4. 快速支持模式（quick_support）也是一条免安装路径 ===')
check('定制包 改名 xxx-qs.exe 不走 quick_support',
      packer_quick_support('xxx-qs.exe', CUSTOM_FILES, []), False)
check('定制包 改名 rustdesk_qs.exe 不走 quick_support',
      packer_quick_support('rustdesk_qs.exe', CUSTOM_FILES, []), False)
check('上游包 -qs- 仍走 quick_support（保持原行为）',
      packer_quick_support('xxx-qs.exe', STOCK_FILES, []), True)

print('\n=== 5. 端到端：改名后的安装包仍会安装 ===')
# 改名 -> 打包器判定安装 -> 传入 --install -> 主程序认安装 -> 执行安装
for name in ['rustdesk-1.5.1-install.exe', 'rustdesk.exe', '仁和堂远程工具.exe',
             'xxx-qs.exe', 'setup_qs.exe']:
    installed = packer_click_setup(name, CUSTOM_FILES, [])
    qs = packer_quick_support(name, CUSTOM_FILES, [])
    passes_install = is_setup('rustdesk.exe', in_extraction_dir=True) if installed else False
    check(f'{name} -> 走安装流程（非 quick_support）',
          installed and passes_install and not qs, True)

print('\n=== 6. 回归：装完之后启动程序，不该再弹安装向导 ===')
# 装完后 run_after_run_cmds 会无参数启动 Program Files 里的 exe。
# 那次启动的 exe 位于 Program Files，没有 meta.toml ->
# is_setup 必须为 false，否则又会自动带上 --install 反复弹向导。
INSTALLED_EXE = r'C:\Program Files\RustDesk\RustDesk.exe'
check('已安装的程序（无参数启动）不认安装',
      is_setup(INSTALLED_EXE, in_extraction_dir=False), False)

# 主程序里的 click_setup = args.is_empty() && is_setup(arg_exe)
def click_setup_in_main(exe_path, args, in_extraction_dir):
    if args:
        return False
    return is_setup(exe_path, in_extraction_dir=in_extraction_dir)


check('装完启动（无参数）-> 不加 --install -> 不再弹向导',
      click_setup_in_main(INSTALLED_EXE, [], False), False)
check('安装向导进程（--install 参数）-> 正常走安装',
      click_setup_in_main(r'%LOCALAPPDATA%\rustdesk\rustdesk.exe', ['--install'], True), False)
check('双击安装包解压后启动（无参数但在解压目录）-> 加 --install',
      click_setup_in_main(r'%LOCALAPPDATA%\rustdesk\rustdesk.exe', [], True), True)
check('托盘启动（--tray 参数）-> 不加 --install',
      click_setup_in_main(INSTALLED_EXE, ['--tray'], False), False)

print()
if fails:
    print(f'{len(fails)} 项未通过:')
    for f in fails:
        print('  -', f)
    sys.exit(1)
print('全部检查通过')
