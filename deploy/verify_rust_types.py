"""Type-check the Rust snippets that the store build relies on.

The full crate cannot be compiled on this machine (no MSVC linker, and the
git dependencies cannot be fetched because the proxy blocks github.com for
git traffic). `rustc --emit=metadata` does not link, so it can still
verify types -- but only for self-contained snippets.

This mirrors the exact expressions used in the changed code, with the
surrounding types stubbed out, so a type error in them shows up here
before CI has to catch it.
"""
import json
import os
import subprocess
import sys
import tempfile

RUSTC = r'C:\Users\Windows\.cargo\bin\rustc.exe'

# The snippets under test, each a standalone item.
SNIPPETS = {
    # src/platform/windows.rs -- cleanup_portable_extraction_dir
    'cleanup_dir_lookup': r'''
use std::path::PathBuf;
use std::os::windows::process::CommandExt;

pub fn cleanup_portable_extraction_dir() {
    let Ok(current_exe) = std::env::current_exe() else {
        return;
    };
    let Some(dir) = current_exe.parent().map(|p| p.to_path_buf()) else {
        return;
    };
    if !dir.join("meta.toml").is_file() {
        return;
    }
    let target = dir.to_string_lossy().to_string();
    if let Err(e) = validate_install_value(&target) {
        log_warn(&format!("skip: {}", e));
        return;
    }
    let script = format!(
        "for /l %i in (1,1,60) do (ping -n 2 127.0.0.1 >nul & rmdir /s /q \"{}\" 2>nul & if not exist \"{}\" exit /b 0)",
        target, target
    );
    let _ = std::process::Command::new("cmd")
        .args(["/c", &script])
        .current_dir(std::env::temp_dir())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

fn validate_install_value(value: &str) -> Result<(), String> {
    if value.contains(['\0', '"', '%', '\r', '\n', '|', '<', '>']) {
        return Err("unsafe".to_string());
    }
    Ok(())
}

fn log_warn(s: &str) { let _ = s; }

const CREATE_NO_WINDOW: u32 = 0x08000000;
''',

    # src/core_main.rs -- the --noinstall handling
    'noinstall_handling': r'''
pub fn handle(args: &mut Vec<String>, flutter_args: &mut Vec<String>) {
    if args.contains(&"--noinstall".to_string()) {
        let is_elevate_handoff = args.iter().any(|a| {
            a == "--elevate" || a == "--run-as-system"
        });
        if is_elevate_handoff {
            args.clear();
        } else if APP_BRAND_NAME != "RustDesk" {
            args.retain(|arg| arg != "--noinstall");
            if !args.contains(&"--install".to_string()) {
                args.push("--install".to_owned());
                flutter_args.push("--install".to_string());
            }
        } else {
            args.clear();
        }
    }
}

const APP_BRAND_NAME: &str = "仁和堂专用远程工具";
''',

    # src/common.rs -- is_setup
    'is_setup': r'''
pub fn is_setup(name: &str, disable_installation: bool) -> bool {
    if disable_installation {
        return false;
    }
    if name.to_lowercase().ends_with("install.exe") {
        return true;
    }
    if APP_BRAND_NAME == "RustDesk" {
        return false;
    }
    is_running_from_extraction_dir()
}

fn is_running_from_extraction_dir() -> bool {
    let Ok(current_exe) = std::env::current_exe() else {
        return false;
    };
    match current_exe.parent() {
        Some(dir) => dir.join("meta.toml").is_file(),
        None => false,
    }
}

const APP_BRAND_NAME: &str = "仁和堂专用远程工具";
''',

    # src/platform/windows.rs -- the install guard, the payload check and
    # the post-install launch
    'install_flow': r'''
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};

fn install_me(options: &str, path: String, silent: bool, debug: bool) -> Result<(), String> {
    static INSTALL_RUNNING: AtomicBool = AtomicBool::new(false);
    if INSTALL_RUNNING.swap(true, Ordering::SeqCst) {
        return Err("Another installation is already running".to_string());
    }
    struct InstallGuard;
    impl Drop for InstallGuard {
        fn drop(&mut self) {
            INSTALL_RUNNING.store(false, Ordering::SeqCst);
        }
    }
    let _install_guard = InstallGuard;
    let _ = (options, path, silent, debug);
    Ok(())
}

fn verify_installed_payload(path: &str) {
    let required = ["data\\app.so", "librustdesk.dll", "rustdesk.exe"];
    let missing: Vec<&str> = required
        .iter()
        .copied()
        .filter(|rel| !Path::new(path).join(rel).is_file())
        .collect();
    if missing.is_empty() {
        return;
    }
    let Ok(current_exe) = std::env::current_exe() else { return; };
    let Some(src) = current_exe.parent() else { return; };
    if !src.join("data\\app.so").is_file() {
        return;
    }
    let script = format!(
        "robocopy \"{}\" \"{}\" /E /IS /IT /NFL /NDL /NJH /NJS /NP /R:1 /W:1",
        src.to_string_lossy(),
        path
    );
    let _ = std::process::Command::new("cmd")
        .args(["/c", &script])
        .status();
}

fn run_after_run_cmds(silent: bool) {
    let exe = "C:\\Program Files\\RustDesk\\RustDesk.exe".to_owned();
    if !silent {
        let main_exe = exe.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(2));
            if !std::path::Path::new(&main_exe).is_file() {
                return;
            }
            match std::process::Command::new(&main_exe).spawn() {
                Ok(_) => {}
                Err(e) => { let _ = e; }
            }
        });
    }
    let _ = std::process::Command::new(&exe).arg("--tray").spawn();
}
''',

    # libs/portable/src/main.rs -- do not wipe the extraction directory
    # while an installation is reading from it
    'extraction_busy_check': r'''
use std::path::Path;

fn extraction_dir_is_busy(dir: &Path) -> bool {
    if !dir.is_dir() {
        return false;
    }
    for attempt in 0..3 {
        let probe = dir.with_extension(format!("busycheck{attempt}"));
        let _ = std::fs::remove_dir_all(&probe);
        match std::fs::rename(dir, &probe) {
            Ok(()) => {
                let _ = std::fs::rename(&probe, dir);
                return false;
            }
            Err(_) => {
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
        }
    }
    true
}
''',

    # libs/portable/src/main.rs -- custom package detection
    'packer_detection': r'''
struct BinaryData { path: String }

fn normalize_path(path: &str) -> String {
    path.replace('\\', "/").trim_start_matches("./").to_lowercase()
}

fn is_custom_package(files: &[BinaryData]) -> bool {
    files
        .iter()
        .any(|f| normalize_path(&f.path).ends_with(CUSTOM_PACKAGE_MARKER))
}

fn click_setup(arg_exe: &str, files: &[BinaryData], args: &[String]) -> bool {
    let is_custom_package = is_custom_package(files);
    args.is_empty()
        && (is_custom_package || arg_exe.to_lowercase().ends_with("install.exe"))
}

fn quick_support(arg_exe: &str, files: &[BinaryData], args: &[String]) -> bool {
    let is_custom_package = is_custom_package(files);
    !is_custom_package && args.is_empty() && is_quick_support_exe(arg_exe)
}

fn is_quick_support_exe(exe: &str) -> bool {
    let exe = exe.to_lowercase();
    exe.contains("-qs-") || exe.contains("-qs.exe") || exe.contains("_qs.exe")
}

const CUSTOM_PACKAGE_MARKER: &str = "store_config.json";
''',
}


def check(name, source):
    with tempfile.TemporaryDirectory(prefix='rusttype_') as tmp:
        src = os.path.join(tmp, 'snippet.rs')
        with open(src, 'w', encoding='utf-8') as f:
            f.write(source)
        out = os.path.join(tmp, 'snippet.rmeta')
        proc = subprocess.run(
            [RUSTC, '--edition', '2021', '--crate-type', 'lib',
             '--emit=metadata', '-o', out, src],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = proc.stdout.decode('utf-8', 'replace')
        errors = [l for l in text.splitlines() if l.startswith('error')]
        if errors:
            print(f'  [!! ] {name}')
            for l in errors[:6]:
                print('        ' + l)
            return False
        print(f'  [OK ] {name}')
        return True


if __name__ == '__main__':
    print('=== rustc --emit=metadata type check (no linking needed) ===')
    ok = True
    for name, src in SNIPPETS.items():
        ok &= check(name, src)
    print()
    if not ok:
        print('type errors found')
        sys.exit(1)
    print('all snippets type-check cleanly')
