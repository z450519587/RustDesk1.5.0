#Requires -Version 5.1
<#
.SYNOPSIS
    仁和堂专用远程工具 —— 门店批量部署脚本（安装包方案）

.DESCRIPTION
    对一台门店电脑执行：
      1) 运行安装包（标准安装，弹安装向导）或静默安装
      2) 校验出厂配置 store_config.json 是否已随安装落位
      3) 校验用户配置目录是否可写
      4) 启动客户端，首次启动会自动弹出「门店信息配置」窗口

    出厂配置（store_config.json）已随安装包分发，**不需要手工拷贝**。

.PARAMETER Installer
    安装包路径，默认取脚本同级目录下的 rustdesk-*-install.exe

.PARAMETER Silent
    静默安装（不弹安装向导），适合 IT 批量下发

.PARAMETER StoreName
    门店名称。若提供，可在启动前直接写入用户配置，免去人工填写

.EXAMPLE
    .\deploy_store_client.ps1 -StoreName '仁和堂沂蒙路店'

.EXAMPLE
    .\deploy_store_client.ps1 -Silent -StoreName '仁和堂沂蒙路店'
#>

[CmdletBinding()]
param(
    [string]$Installer,
    [switch]$Silent,
    [string]$StoreName
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info($msg)  { Write-Host "[信息] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[完成] $msg" -ForegroundColor Green }
function Write-Warn($msg)  { Write-Host "[注意] $msg" -ForegroundColor Yellow }
function Write-Err($msg)   { Write-Host "[错误] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. 定位安装包
# ---------------------------------------------------------------------------
if (-not $Installer) {
    $Installer = Get-ChildItem -Path $PSScriptRoot -Filter 'rustdesk-*-install.exe' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Installer) { $Installer = $Installer.FullName }
}

if (-not $Installer -or -not (Test-Path $Installer)) {
    Write-Err "找不到安装包。请用 -Installer 指定路径，或把安装包放到脚本同级目录。"
    exit 1
}
Write-Info "安装包：$Installer"

# ---------------------------------------------------------------------------
# 2. 执行安装
# ---------------------------------------------------------------------------
$installDir = Join-Path $env:ProgramFiles 'RustDesk'
$targetExe = Join-Path $installDir 'rustdesk.exe'

if (Test-Path $targetExe) {
    Write-Warn "检测到已安装版本：$targetExe"
    Write-Info "如需覆盖安装请先在控制面板卸载；如需重装请使用 -Reinstall"
} else {
    Write-Info "开始安装（$(if ($Silent) { '静默' } else { '交互式安装向导' })）…"
    if ($Silent) {
        # 静默安装：安装包自身支持 --silent-install 需重启自身，
        # 这里用其内置的静默参数。交互安装则直接双击语义。
        & $Installer '--silent-install'
    } else {
        Start-Process -FilePath $Installer -Wait
    }
    Write-Ok "安装程序已执行完毕"
}

# ---------------------------------------------------------------------------
# 3. 校验出厂配置是否随安装落位
# ---------------------------------------------------------------------------
Start-Sleep -Seconds 3
$factoryConfig = Join-Path $installDir 'store_config.json'

if (Test-Path $factoryConfig) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($factoryConfig)
        $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
        $cfg   = $text | ConvertFrom-Json
        $hasToken = -not [string]::IsNullOrWhiteSpace($cfg.adminToken)
        Write-Ok "出厂配置已就位：$factoryConfig"
        Write-Info ("  字段：" + (($cfg.PSObject.Properties.Name | Sort-Object) -join ', '))
        Write-Info ("  令牌：已包含" + $(if ($hasToken) { "（不在日志中显示）" } else { "缺失 → 门店名只能保存在本机，无法同步到服务器" }))
    } catch {
        Write-Warn "出厂配置存在但解析失败：$($_.Exception.Message)"
    }
} else {
    Write-Warn "未找到出厂配置：$factoryConfig"
    Write-Info "  说明：安装包分发不完整，或程序尚未安装完成。"
    Write-Info "  影响：门店名仍可保存到本机，但无法同步到公司服务器。"
}

# ---------------------------------------------------------------------------
# 4. 校验用户配置目录可写（安装目录无写权限时靠它兜底）
# ---------------------------------------------------------------------------
$userConfigDir = Join-Path $env:APPDATA 'RustDesk\config'
$userConfigFile = Join-Path $userConfigDir 'store_user_config.json'

try {
    if (-not (Test-Path $userConfigDir)) {
        New-Item -ItemType Directory -Path $userConfigDir -Force | Out-Null
    }
    # 试写再删除，验证可写性
    $probe = Join-Path $userConfigDir '_write_probe.tmp'
    [System.IO.File]::WriteAllText($probe, 'probe')
    Remove-Item $probe -Force
    Write-Ok "用户配置目录可写：$userConfigDir"
} catch {
    Write-Warn "用户配置目录不可写：$($_.Exception.Message)"
    Write-Info "  客户端会自动退到 %LOCALAPPDATA% 与 exe 同目录；建议检查 $userConfigDir 的权限。"
}

# ---------------------------------------------------------------------------
# 5. 预填门店名（可选）
# ---------------------------------------------------------------------------
if ($StoreName) {
    try {
        $user = [ordered]@{}
        if (Test-Path $userConfigFile) {
            $existing = Get-Content $userConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { $user[$p.Name] = $p.Value }
        }
        $user['storeName']    = $StoreName
        $user['configured']   = $true
        $json = $user | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($userConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "门店名称已预填：$StoreName"
        Write-Info "  文件：$userConfigFile"
    } catch {
        Write-Warn "预填门店名失败（不影响安装，客户端首启仍会弹窗）：$($_.Exception.Message)"
    }
} else {
    Write-Info "未指定 -StoreName，门店名称由门店技术员在首次启动的弹窗中填写。"
}

# ---------------------------------------------------------------------------
# 6. 启动客户端
# ---------------------------------------------------------------------------
if (Test-Path $targetExe) {
    Write-Info "启动客户端…"
    Start-Process -FilePath $targetExe
    Write-Ok "客户端已启动。"
    if (-not $StoreName) {
        Write-Info "首次启动会自动弹出「门店信息配置」窗口，填写门店名称后点「保存并同步」。"
    }
} else {
    Write-Warn "未找到 $targetExe，无法启动客户端。请手动运行安装包。"
}

Write-Host ""
Write-Ok "部署流程结束。"
