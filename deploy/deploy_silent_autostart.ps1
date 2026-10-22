<#
.SYNOPSIS
    仁和堂专用远程工具 —— 静默自启与权限配置脚本

.DESCRIPTION
    对应新版权限策略：
      · 界面 / 托盘：普通用户权限运行（不弹 UAC，可拖拽文件，开机登录后静默出现托盘图标）
      · 后台服务   ：Windows 服务管理器以 LocalSystem（最高权限）启动，开机自动、失败自动重启
      · 托盘自启   ：用「任务计划程序」实现（仅当用户登录时运行 + 延迟启动），开机不弹任何窗口

    注意：托盘程序**不能**用 SYSTEM 账户运行 —— SYSTEM 位于会话 0，桌面上看不到托盘图标。
          需要最高权限的活儿由服务承担，用户未登录时服务也照常工作。

.PARAMETER CheckOnly
    只检查现状并输出结论，不做任何修改。

.PARAMETER RemoveStartupShortcut
    迁移到计划任务时，删除「启动」文件夹里原有的托盘快捷方式（避免双托盘图标）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy_silent_autostart.ps1
    powershell -ExecutionPolicy Bypass -File .\deploy_silent_autostart.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$RemoveStartupShortcut
)

$ErrorActionPreference = 'Stop'
$ServiceName = 'rustdesk'                       # 服务键名（内部标识，勿改）
$TaskName    = '仁和堂专用远程工具 托盘自启'
$TrashArgs   = '--tray'

function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($m)     { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Warn2($m)  { Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Write-Bad($m)    { Write-Host "  [异常] $m" -ForegroundColor Red }

# ---------- 0. 管理员检查 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $CheckOnly) {
    Write-Bad '修改服务配置需要管理员权限，请右键以管理员身份运行本脚本。'
    exit 1
}

# ---------- 1. 定位安装目录 ----------
function Get-InstallDir {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk'
    )
    foreach ($p in $paths) {
        if (Test-Path $p) {
            $item = Get-ItemProperty $p -ErrorAction SilentlyContinue
            if ($item.InstallLocation -and (Test-Path $item.InstallLocation)) {
                return $item.InstallLocation
            }
        }
    }
    foreach ($c in @("$env:ProgramFiles\RustDesk", "${env:ProgramFiles(x86)}\RustDesk")) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$installDir = Get-InstallDir
$exe = if ($installDir) { Join-Path $installDir 'rustdesk.exe' } else { $null }

Write-Section '一、程序位置'
if ($exe -and (Test-Path $exe)) {
    Write-Ok "可执行文件：$exe"
} else {
    Write-Warn2 '未找到 rustdesk.exe（未安装或安装目录自定义）。服务/计划任务部分将按现有注册信息处理。'
}

# ---------- 2. 服务层：最高权限 + 开机自启 + 失败重启 ----------
Write-Section '二、后台服务（最高权限 LocalSystem）'
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Warn2 "未找到服务 $ServiceName。安装软件时会自动创建该服务（默认 LocalSystem + 开机自动）。"
} else {
    $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue
    $start = if ($reg -and $reg.Start -eq 0) { '自动' } else { "当前值=$($reg.Start)" }
    $obj   = if ($reg -and $reg.ObjectName) { $reg.ObjectName } else { '(默认 LocalSystem)' }
    Write-Host "  服务显示名：$($svc.DisplayName)"
    Write-Host "  启动类型  ：$start"
    Write-Host "  运行账户  ：$obj"
    Write-Host "  当前状态  ：$($svc.Status)"

    if (-not $CheckOnly) {
        if ($reg -and $reg.Start -ne 0) {
            & sc.exe config $ServiceName start= auto | Out-Null
            Write-Ok '已把启动类型改为「自动」'
        }
        if ($obj -notmatch 'LocalSystem') {
            & sc.exe config $ServiceName obj= LocalSystem | Out-Null
            Write-Ok '已把运行账户改为 LocalSystem（最高权限）'
        }
        & sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
        Write-Ok '已设置失败自动重启（5 秒 / 15 秒 / 60 秒，每日重置）'
        if ($svc.Status -ne 'Running') {
            & sc.exe start $ServiceName | Out-Null
            Write-Ok '已启动服务'
        }
    }
}

# ---------- 3. 托盘自启：任务计划（普通权限、静默） ----------
Write-Section '三、托盘静默自启（任务计划程序）'
$startupLink = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\仁和堂专用远程工具 Tray.lnk'
$oldLink     = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup\RustDesk Tray.lnk'

if ($exe -and (Test-Path $exe)) {
    if (-not $CheckOnly) {
        $action = New-ScheduledTaskAction -Execute $exe -Argument $TrashArgs
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $trigger.Delay = 'PT30S'   # 登录后延迟 30 秒，避免拖慢开机
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
                    -Hidden
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Ok "已创建计划任务：$TaskName（登录后延迟 30 秒启动托盘，普通用户权限，无 UAC 弹窗）"

        if ($RemoveStartupShortcut) {
            foreach ($l in @($startupLink, $oldLink)) {
                if (Test-Path $l) { Remove-Item $l -Force; Write-Ok "已删除启动项快捷方式：$l" }
            }
        } else {
            Write-Warn2 '「启动」文件夹里仍有托盘快捷方式。托盘有单实例互斥，不会出两个图标；' +
                        '想彻底交给计划任务管理，请加参数 -RemoveStartupShortcut 重跑本脚本。'
        }
    } else {
        $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($t) {
            Write-Ok "计划任务已存在：$TaskName（状态 $($t.State)）"
        } else {
            Write-Warn2 "计划任务不存在：$TaskName"
        }
    }
} else {
    Write-Warn2 '未定位到 rustdesk.exe，跳过计划任务配置。'
}

# ---------- 4. 结论 ----------
Write-Section '四、结论'
Write-Host '  界面 / 托盘 : 普通用户权限，双击不弹 UAC，可从资源管理器拖拽文件到远程窗口' -ForegroundColor Gray
Write-Host '  后台服务   : LocalSystem 最高权限，开机自动启动，用户未登录也在工作' -ForegroundColor Gray
Write-Host '  开机自启   : 计划任务在登录后静默拉起托盘，全程无弹窗' -ForegroundColor Gray
Write-Host '  需要提权时 : 安装服务、写 Program Files 等动作由程序自身 runas 提权（会弹一次 UAC）' -ForegroundColor Gray
Write-Host ''
