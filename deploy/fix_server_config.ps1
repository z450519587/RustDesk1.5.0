#Requires -Version 5.1
<#
.SYNOPSIS
    修复门店客户端的 ID 服务器 / 中继服务器配置

.DESCRIPTION
    背景：
    早期测试时有人在客户端「设置 → 网络 → ID 服务器」填了**内网 IP**
    （如 192.168.100.190），该值被写进本机配置 `%APPDATA%\RustDesk\config\RustDesk2.toml`。

    RustDesk 运行时取 ID 服务器的优先级是：
        1. EXE_RENDEZVOUS_SERVER   (编译期注入，本定制版为空)
        2. 选项 custom-rendezvous-server
        3. PROD_RENDEZVOUS_SERVER  (本定制版为空)
        4. **字段 rendezvous_server**   ← 客户端连上哪个就缓存哪个
        5. 常量 RENDEZVOUS_SERVERS = ['rd.renhetang.cn']

    只要第 2 或第 4 项里存着内网 IP，客户端就会一直连内网，
    **在公司外网就连不上了**。日志表现：
        INFO  [src\client.rs:842] rendezvous server: 192.168.100.190:21116
        ERROR [src\client.rs:4954] Failed to secure tcp: deadline has elapsed

    本脚本把第 2、4 项以及中继服务器 `relay-server` 全部纠正为
    rd.renhetang.cn，并**保留 API 服务器设置不动**
    （API 服务器是门店名同步用的，与远程连接无关）。

    修改前自动备份原文件。

.PARAMETER IdServer
    期望的 ID 服务器地址，默认 rd.renhetang.cn

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

# 内网地址特征：私有网段。用于识别"被污染"的配置
# 注意：值可能是完整 URL（http://192.168.x.x:21114），要先剥掉 scheme 再取 host
function Test-PrivateHost([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $false }
    $s = $v -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''   # 去 scheme
    $s = ($s -split '/')[0]                                # 去路径
    $h = ($s -split ':')[0]                                # 去端口
    return ($h -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)')
}

function Repair-UserConfig([string]$cfgPath) {
    $userConfig = Join-Path (Split-Path $cfgPath -Parent) 'store_user_config.json'
    if (-not (Test-Path $userConfig)) {
        Write-Info "未找到用户配置文件，跳过。"
        return
    }
    Write-Host ""
    Write-Info "检查用户配置：$userConfig"
    try {
        $uj = Get-Content $userConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $dirty = @()
        foreach ($k in @('apiServer','adminToken','addressBookUserId','addressBookCollectionId')) {
            if ($uj.PSObject.Properties.Name -contains $k) {
                $v = "$($uj.$k)"
                # 注意：apiServer 是完整 URL（http://192.168.x.x:21114），
                # 不能用 ^192.168 开头匹配，要从 host 部分判断。
                $hostPart = ($v -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', '') -split '/' | Select-Object -First 1
                $hostPart = ($hostPart -split ':')[0]
                $isPrivate = ($hostPart -match '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)')
                if ($k -eq 'apiServer' -and $isPrivate) { $dirty += $k }
            }
        }
        if ($dirty.Count -gt 0) {
            if ($CheckOnly) {
                Write-Warn "用户配置里存在内网地址：$($dirty -join ', ')（CheckOnly 模式未修改）"
            } else {
                Copy-Item $userConfig "$userConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force
                foreach ($k in $dirty) {
                    $uj.PSObject.Properties.Remove($k)
                }
                [System.IO.File]::WriteAllText($userConfig,
                    ($uj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
                Write-Ok "已清除用户配置里的内网地址：$($dirty -join ', ')"
                Write-Info "  门店名已保留：$($uj.storeName)"
            }
        } else {
            Write-Ok "用户配置干净，无需清理。"
        }
    } catch {
        Write-Warn "检查用户配置时出错（不影响本次修复）：$($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "=== 门店客户端服务器配置修复 ===" -ForegroundColor White
Write-Info "配置文件：$ConfigPath"
Write-Host ""

if (-not (Test-Path $ConfigPath)) {
    Write-Warn "配置文件不存在，说明该机器可能还没运行过客户端。"
    Write-Info "首次运行会自动使用内置默认值 rd.renhetang.cn，无需修复。"
    exit 0
}

$content = Get-Content $ConfigPath -Raw -Encoding UTF8

function Get-Opt([string]$text, [string]$key) {
    $m = [regex]::Match($text, "(?m)^\s*$([regex]::Escape($key))\s*=\s*'([^']*)'")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Show-Or($v) { if ($null -eq $v) { '<未设置>' } else { $v } }

# 三个可能被污染的位置
$curIdOpt = Get-Opt $content 'custom-rendezvous-server'  # 选项（优先级2）
$curIdFld = Get-Opt $content 'rendezvous_server'         # 字段缓存（优先级4）
$curRelay = Get-Opt $content 'relay-server'               # 中继服务器
$curApi   = Get-Opt $content 'api-server'                 # API 服务器（不动）

Write-Host "当前配置：" -ForegroundColor White
Write-Host ("  (1) ID 服务器选项 (custom-rendezvous-server) : " + (Show-Or $curIdOpt))
Write-Host ("  (2) ID 服务器缓存 (rendezvous_server)         : " + (Show-Or $curIdFld))
Write-Host ("  (3) 中继服务器     (relay-server)              : " + (Show-Or $curRelay))
Write-Host ("  (4) API 服务器     (api-server)                : " + (Show-Or $curApi) + "   <- 本脚本不修改")
Write-Host ""

# --- 判定哪些需要改 ---
$fixIdOpt = ($null -ne $curIdOpt) -and ($curIdOpt -ne $IdServer)
$fixIdFld = ($null -ne $curIdFld) -and ($curIdFld -ne $IdServer) -and ($curIdFld -ne ($IdServer + ':21116'))
$fixRelay = ($null -ne $curRelay) -and ($curRelay -ne $RelayServer)

# 即使值看着"对"，只要指向内网也要改（内网优先被读取）
if ($null -ne $curIdOpt -and (Test-PrivateHost $curIdOpt) -and $curIdOpt -ne $IdServer) { $fixIdOpt = $true }
if ($null -ne $curIdFld -and (Test-PrivateHost $curIdFld)) { $fixIdFld = $true }
if ($null -ne $curRelay -and (Test-PrivateHost $curRelay) -and $curRelay -ne $RelayServer) { $fixRelay = $true }

if (-not ($fixIdOpt -or $fixIdFld -or $fixRelay)) {
    Write-Ok "ID 服务器与中继服务器配置正确，无需修改。"
    if ($null -ne $curApi) { Write-Info "API 服务器：$curApi （不受本脚本影响）" }
    # 用户配置里可能仍有旧版写入的内网 apiServer，仍需检查
    Repair-UserConfig $ConfigPath
    exit 0
}

Write-Warn "检测到服务器配置异常，这会导致在公司外网无法远程连接。"
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
if ($fixIdOpt) {
    if ($null -eq $curIdOpt) {
        # 选项不存在：在 [options] 段里插入
        if ($new -match '(?m)^\[options\]\s*$') {
            $new = [regex]::Replace($new, '(?m)^\[options\]\s*$',
                "[options]`r`ncustom-rendezvous-server = '$IdServer'")
        }
    } else {
        $new = [regex]::Replace($new, "(?m)^(\s*)custom-rendezvous-server\s*=\s*'[^']*'",
            "`$1custom-rendezvous-server = '$IdServer'")
    }
    Write-Ok "(1) ID 服务器选项 -> $IdServer"
}
if ($fixIdFld) {
    # 字段缓存：置空即可，客户端下次连上会自动回写正确的值
    $new = [regex]::Replace($new, "(?m)^(\s*)rendezvous_server\s*=\s*'[^']*'",
        "`$1rendezvous_server = ''")
    Write-Ok "(2) ID 服务器缓存字段已清空（客户端会自动回写正确值）"
}
if ($fixRelay) {
    $new = [regex]::Replace($new, "(?m)^(\s*)relay-server\s*=\s*'[^']*'",
        "`$1relay-server = '$RelayServer'")
    Write-Ok "(3) 中继服务器 -> $RelayServer"
}

[System.IO.File]::WriteAllText($ConfigPath, $new, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "配置已写回"

# --- 校验 ---
Write-Host ""
Write-Info "复核修改结果："
$check = Get-Content $ConfigPath -Raw -Encoding UTF8
Write-Host ("  (1) ID 服务器选项 : " + (Show-Or (Get-Opt $check 'custom-rendezvous-server')))
Write-Host ("  (2) ID 服务器缓存 : " + (Show-Or (Get-Opt $check 'rendezvous_server')))
Write-Host ("  (3) 中继服务器     : " + (Show-Or (Get-Opt $check 'relay-server')))
Write-Host ("  (4) API 服务器     : " + (Show-Or (Get-Opt $check 'api-server')))
Write-Host ""
Write-Ok "修复完成。请**完全退出客户端后重新启动**（托盘图标右键 -> 退出），配置才会生效。"

# ---------------------------------------------------------------------------
# 顺带清理用户配置里被旧版本写入的内网 API 地址
# ---------------------------------------------------------------------------
# 旧版本客户端会把 apiServer 写进 store_user_config.json，而且写的是内网地址。
# 它会**覆盖**随安装包分发的出厂配置，导致门店名同步不到服务器。
# 这里把用户配置里这些「出厂配置管理」的字段删掉，门店名保留。

# 调用（无论 ID/中继配置是否需要修，用户配置都要检查）
Repair-UserConfig $ConfigPath