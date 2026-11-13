# 修复当前这台机器的安装（双击运行，会弹 UAC，点「是」即可）
#
# 背景：11-13 08:12 那次安装没装完 —— C:\Program Files\RustDesk 里只有 16 个文件，
# data\ 等子目录缺失，Flutter 找不到 data\app.so，客户端启动即退出（退出码 1），
# 所以只看到后台服务进程、没有界面。
#
# 这个脚本把缺失的文件从解压目录补拷过去，不需要重新安装、不需要重新下载包。

$ErrorActionPreference = 'Stop'
$scriptPath = $PSCommandPath

$src = "C:\Users\Windows\AppData\Local\rustdesk"
$dst = "C:\Program Files\RustDesk"

# 需要管理员权限：以管理员身份重新启动自己（UAC 弹窗点「是」即可）。
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "需要管理员权限，即将弹出 UAC 提示，请点「是」。" -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$scriptPath`"" `
            -Verb RunAs
    } catch {
        Write-Host "提权失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "请改为右键本文件 -> 使用 PowerShell 运行 -> 以管理员身份运行。" -ForegroundColor Yellow
    }
    exit 0
}

Write-Host "=== 修复安装 ===" -ForegroundColor Cyan

if (-not (Test-Path $src)) {
    Write-Host "找不到解压目录 $src —— 请重新运行安装包。" -ForegroundColor Red
    Read-Host "按回车关闭"
    exit 1
}

# 用 robocopy 补齐（XCOPY 半途失败时会静默漏掉子目录，robocopy 不会）
& robocopy $src $dst /E /IS /IT /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    Write-Host "robocopy 失败（退出码 $rc）" -ForegroundColor Red
    Read-Host "按回车关闭"
    exit 1
}

# 校验
$required = @("data\app.so", "librustdesk.dll", "rustdesk.exe")
$missing = $required | Where-Object { -not (Test-Path (Join-Path $dst $_)) }
$dirs = (Get-ChildItem $dst -Directory -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
$files = (Get-ChildItem $dst -File -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count

Write-Host ""
Write-Host "安装目录: $dst"
Write-Host "  目录数: $dirs"
Write-Host "  文件数: $files"
if ($missing) {
    Write-Host "  仍然缺失: $($missing -join ', ')" -ForegroundColor Red
} else {
    Write-Host "  关键文件齐全 [OK]" -ForegroundColor Green
}

# 重启客户端
Write-Host ""
Write-Host "=== 重启客户端 ===" -ForegroundColor Cyan
Get-Process -Name "RustDesk" -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -like "$dst*" -or $_.MainWindowHandle -ne 0
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Start-Process "$dst\RustDesk.exe"

Write-Host ""
Write-Host "已启动，应该能看到主界面窗口。" -ForegroundColor Green
Write-Host "（如果还是没有界面，把这个日志文件发给我）" -ForegroundColor Gray
Write-Host "  $env:APPDATA\RustDesk\log\RustDesk_rCURRENT.log" -ForegroundColor Gray
Read-Host "按回车关闭"
