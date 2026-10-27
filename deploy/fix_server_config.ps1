#Requires -Version 5.1
<#
.SYNOPSIS
    修复门店客户端的 ID 服务器 / 中继服务器配置

.DESCRIPTION
    背景：
    早期测试时有人在客户端「设置 → 网络 → ID 服务器」里填了**内网 IP**
    （如 192.168.100.190），该值被写进本机配置 `RustDesk2.toml` 的
    `custom-rendezvous-server` / `relay-server` 选项。

    运行时服务器地址的优先级是：
        EXE_RENDEZVOUS_SERVER (编译期注入)
          -> custom-rendezvous-server 选项   ← 被污染的就是这一项
          -> PROD_RENDEZVOUS_SERVER
          -> RENDEZVOUS_SERVERS 常量 = ['rd.renhetang.cn']

    所以只要本机配置里存着内网 IP，客户端就会一直连内网，
    **在公司外网就连不上了**（日志表现：
      `rendezvous server: 192.168.100.190:21116`
      `Failed to secure tcp: deadline has elapsed`）。

    本脚本把这两个选项清空，客户端即回落到编译期常量
    `rd.renhetang.cn`，并保留 API 服务器设置不动。

    注意：只改 ID 服务器与中继服务器，**不动** API 服务器
    （API 服务器是门店名同步用的，与远程连接无关）。

.PARAMETER IdServer
    期望的 ID 服务器地址，默认 rd.renhetang.cn（留空则回落到客户端内置常量）

.PARAMETER RelayServer
    期望的中继服务器地址，默认与 IdServer 相同

.PARAMETER ConfigPath
    配置文件路径，默认 %APPDATA%\RustDesk\config\RustDesk2.toml

.PARAMETER CheckOnly
    只检查不修改

.EXAMPLE
    .\fix_server_config.ps1

.EXAMPLE
    .\fix_server_config.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [string]$IdServer = 'rd.renhetang.cn',
    [string]$RelayServer = '',
    [string]$ConfigPath = '',
    [switch]$CheckOnly
)

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info($m) { Write-Host "[信息] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[错误] $m" -ForegroundColor Red }

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'
}
if (-not $RelayServer) { $RelayServer = $IdServer }

Write-Host ""
Write-Host "=== 门店客户端服务器配置修复 ===" -ForegroundColor White
Write-Info "配置文件：$ConfigPath"
Write-Host ""

if (-not (Test-Path $ConfigPath)) {
    Write-Warn "配置文件不存在，说明该机器可能还没运行过客户端。"
    Write-Info "首次运行时会自动使用内置默认值 rd.renhetang.cn，无需修复。"
    exit 0
}

# --- 读取现状 ---
$content = Get-Content $ConfigPath -Raw -Encoding UTF8

function Get-Option([string]$text, [string]$key) {
    $m = [regex]::Match($text, "(?m)^\s*$([regex]::Escape($key))\s*=\s*'([^']*)'")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

$curId    = Get-Option $content 'custom-rendezvous-server'
$curRelay = Get-Option $content 'relay-server'
$curApi   = Get-Option $content 'api-server'

Write-Host "当前配置：" -ForegroundColor White
Write-Host ("  ID 服务器   (custom-rendezvous-server) : " + $(if ($null -eq $curId) { "<未设置>" } else { $curId }))
Write-Host ("  中继服务器 (relay-server)              : " + $(if ($null -eq $curRelay) { "<未设置>" } else { $curRelay }))
Write-Host ("  API 服务器 (api-server)                : " + $(if ($null -eq $curApi) { "<未设置>" } else { $curApi }))
Write-Host ""

$needFix = $false
if ($null -ne $curId    -and $curId    -ne $IdServer)    { $needFix = $true }
if ($null -ne $curRelay -and $curRelay -ne $RelayServer) { $needFix = $true }

if (-not $needFix) {
    Write-Ok "ID 服务器与中继服务器配置正确，无需修改。"
    if ($null -ne $curApi) { Write-Info "API 服务器：$curApi （不受本脚本影响）" }
    exit 0
}

Write-Warn "检测到服务器配置被指向了非预期地址，这会导致在公司外网无法远程连接。"
if ($CheckOnly) {
    Write-Info "CheckOnly 模式，未做修改。去掉 -CheckOnly 即可执行修复。"
    exit 0
}

# --- 备份 ---
$backup = "$ConfigPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item $ConfigPath $backup -Force
Write-Ok "已备份原配置：$backup"

# --- 修改 ---
$new = $content
if ($null -ne $curId -and $curId -ne $IdServer) {
    $new = $new -replace "(?m)^(\s*)custom-rendezvous-server\s*=\s*'[^']*'", "`$1custom-rendezvous-server = '$IdServer'"
    Write-Ok "ID 服务器已改为：$IdServer"
}
if ($null -ne $curRelay -and $curRelay -ne $RelayServer) {
    $new = $new -replace "(?m)^(\s*)relay-server\s*=\s*'[^']*'", "`$1relay-server = '$RelayServer'"
    Write-Ok "中继服务器已改为：$RelayServer"
}

# 保持原有的换行风格，避免 CRLF/LF 混用
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($ConfigPath, $new, $enc)
Write-Ok "配置已写回"

# --- 校验 ---
Write-Host ""
Write-Info "复核修改结果："
$check = Get-Content $ConfigPath -Raw -Encoding UTF8
$nowId    = Get-Option $check 'custom-rendezvous-server'
$nowRelay = Get-Option $check 'relay-server'
$nowApi   = Get-Option $check 'api-server'
Write-Host ("  ID 服务器   : " + $nowId)
Write-Host ("  中继服务器 : " + $nowRelay)
Write-Host ("  API 服务器 : " + $(if ($null -eq $nowApi) { "<未设置>" } else { $nowApi }))

Write-Host ""
Write-Ok "修复完成。请**完全退出客户端后重新启动**（托盘图标右键 → 退出），配置才会生效。"
Write-Info "门店名称等本地配置（%APPDATA%\RustDesk\config\store_user_config.json）未受影响。"
