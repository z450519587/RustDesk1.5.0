#Requires -Version 5.1
<#
.SYNOPSIS
    把设备管理（peer）里的门店设备批量导入共享通讯录，并修正通讯录里的别名。

.DESCRIPTION
    解决「新部署的设备不会自动出现在通讯录里」的问题。

    背景：
    客户端登录 API 后会定时上报 sysinfo，服务端收到后自动在「设备管理」
    （peer 表）建档 —— 所以新设备**不需要任何人工操作**就会出现在设备管理里。
    但「共享通讯录」（address_book 表）是另一张表，**服务端不会自动建**，
    必须显式创建。

    本脚本用服务端现成的批量接口完成这件事：
        POST /api/admin/address_book/batchCreateFromPeers
    该接口以 peer 表为数据源，自带去重（同一 user_id/collection_id/id 已存在
    则跳过），因此**可以反复执行**，是幂等的。

    由于该接口生成的条目不带 alias（门店名）——服务端的 FromPeer 只复制
    id/username/hostname/platform ——脚本随后再做一步：把 peer 表里的 alias
    （门店名）同步到通讯录条目的 alias。

    ★ 这同时实现了「服务端别名被改错时自动纠正回来」：
      门店机本地保存的门店名会写进 peer.alias，本脚本以 peer.alias 为准
      修正通讯录 —— 服务端被误改的别名会被纠正，门店端的名字不会被抹掉。

    ★ 不在通讯录里、且 alias 为空的设备（例如尚未填写门店名的机器）会被跳过：
      不创建空条目，也不覆盖任何已有条目。

.PARAMETER ApiServer
    API 服务器地址。省略时取配置文件里的 apiServer。

.PARAMETER ConfigPath
    配置文件路径，默认取脚本同目录的 store_config.json。

.PARAMETER CollectionId
    共享通讯录（地址簿名称）的 ID。省略时取配置文件里的
    addressBookCollectionId。

.PARAMETER DryRun
    只报告将要做什么，不实际写入。首次运行建议先带这个参数。

.EXAMPLE
    .\sync_devices_to_addressbook.ps1 -DryRun

.EXAMPLE
    .\sync_devices_to_addressbook.ps1
#>
[CmdletBinding()]
param(
    [string]$ApiServer,
    [string]$ConfigPath,
    [int]$CollectionId = -1,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info($m) { Write-Host "[信息] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[完成] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[注意] $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[错误] $m" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. 读配置
# ---------------------------------------------------------------------------
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot 'store_config.json'
}
if (-not (Test-Path $ConfigPath)) {
    Write-Err "找不到配置文件：$ConfigPath"
    exit 1
}
try {
    # 显式 UTF8：PS5.1 默认按 ANSI(GBK) 读文件，会把中文配置读成乱码
    $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Err "配置文件解析失败：$($_.Exception.Message)"
    exit 1
}

if (-not $ApiServer) {
    if ($cfg.PSObject.Properties['apiServer']) { $ApiServer = $cfg.apiServer.ToString().Trim() }
}
$adminToken = ''
if ($cfg.PSObject.Properties['adminToken']) { $adminToken = $cfg.adminToken.ToString().Trim() }
$abUserId = 0
if ($cfg.PSObject.Properties['addressBookUserId']) { $abUserId = [int]$cfg.addressBookUserId }
$abCollection = 0
if ($cfg.PSObject.Properties['addressBookCollectionId']) { $abCollection = [int]$cfg.addressBookCollectionId }
if ($CollectionId -ge 0) { $abCollection = $CollectionId }

if (-not $ApiServer)  { Write-Err '未配置 apiServer'; exit 1 }
if (-not $adminToken) { Write-Err '未配置 adminToken'; exit 1 }

$base = $ApiServer.TrimEnd('/')
Write-Info "API 服务器  : $base"
Write-Info "共享通讯录  : user_id=$abUserId  collection_id=$abCollection"

$headers = @{ 'api-token' = $adminToken; 'Accept' = 'application/json' }

# ---------------------------------------------------------------------------
# 2. 通用请求helper
# ---------------------------------------------------------------------------
function Get-JsonGet($uri) {
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
}

# 统一的 JSON POST。
# 关键：PowerShell 5.1 传"字符串"body 时，若 ContentType 未带 charset，
# 会按 ASCII 编码发送，中文全部变成 "?"（服务端存入 ???XX?）。
# 因此这里一律把 JSON 转成 UTF-8 字节数组再发送。
function Invoke-JsonPost($uri, $obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 5
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body $bytes
}

function Get-ListItems($body) {
    if ($body -eq $null) { return @() }
    $data = $null
    if ($body.PSObject.Properties['data']) { $data = $body.data }
    if ($data -is [System.Collections.IList]) { return $data }
    if ($data -ne $null) {
        # lejianwen 返回结构为 { data: { list: [...] } }
        foreach ($key in @('list', 'data')) {
            if ($data.PSObject.Properties[$key]) {
                $inner = $data.$key
                if ($inner -is [System.Collections.IList]) { return $inner }
            }
        }
    }
    return @()
}

Write-Host ''
Write-Host '=== 门店设备批量导入共享通讯录 ===' -ForegroundColor White

# ---------------------------------------------------------------------------
# 3. 读全部设备
# ---------------------------------------------------------------------------
Write-Info '读取设备列表…'
$peers = @()
$page = 1
while ($true) {
    try {
        $r = Get-JsonGet ($base + '/api/admin/peer/list?page=' + $page + '&page_size=1000')
    } catch {
        Write-Err ('读取设备列表失败: ' + $_)
        exit 1
    }
    $items = Get-ListItems $r
    if (-not $items -or $items.Count -eq 0) { break }
    $peers += $items
    if ($items.Count -lt 1000) { break }
    $page++
}
Write-Ok ('共读取到 ' + $peers.Count + ' 台设备')

# ---------------------------------------------------------------------------
# 4. 挑出「填过门店名」的设备
# ---------------------------------------------------------------------------
# alias 非空即可视为填过 —— 客户端写进 peer 的是门店名，不是机器名。
$storePeers = @($peers | Where-Object {
    $a = "$($_.alias)"
    -not [string]::IsNullOrWhiteSpace($a)
})
Write-Info ('其中已填写门店名的：' + $storePeers.Count + ' 台')

if ($storePeers.Count -eq 0) {
    Write-Host ''
    Write-Ok '没有需要处理的设备（所有设备都还没填过门店名）。'
    exit 0
}

# ---------------------------------------------------------------------------
# 5. 批量导入通讯录
# ---------------------------------------------------------------------------
# 服务端自带去重（已存在则跳过），所以这里可以对全量调用，反复跑安全。
$peerIds = @($storePeers | ForEach-Object { [int]$_.row_id } | Where-Object { $_ -gt 0 })
Write-Info ('批量导入通讯录：' + $peerIds.Count + ' 台')

if ($DryRun) {
    Write-Warn 'DryRun：跳过批量导入'
} elseif ($peerIds.Count -gt 0) {
    try {
        Invoke-JsonPost ($base + '/api/admin/address_book/batchCreateFromPeers') @{
            user_id      = $abUserId
            collection_id = $abCollection
            peer_ids    = $peerIds
            tags        = @()
        } | Out-Null
        Write-Ok '批量导入完成'
    } catch {
        Write-Warn ('批量导入失败: ' + $_)
        Write-Info '  常见原因：共享通讯录（collection_id）不存在，或当前用户没有管理员权限。'
        Write-Info '  请在 API 后台确认「地址簿名称」已存在，且配置里的 collection_id 与之对应。'
    }
}

# ---------------------------------------------------------------------------
# 6. 修正通讯录别名（以 peer.alias 为准）
# ---------------------------------------------------------------------------
# 这一步同时实现了「服务端别名被改错时自动纠正回来」：
# peer.alias 是门店端写上去的门店名，服务端被误改的别名以它为准纠正回来。
Write-Host ''
Write-Info '核对并修正通讯录别名…'
$fixed = 0
$checked = 0
$missing = 0

foreach ($p in $storePeers) {
    $rid = "$($p.id)"
    $peerAlias = "$($p.alias)"
    if ([string]::IsNullOrWhiteSpace($peerAlias)) { continue }

    $listUrl = $base + '/api/admin/address_book/list?user_id=' + $abUserId +
               '&collection_id=' + $abCollection + '&id=' + $rid
    try {
        $r = Get-JsonGet $listUrl
    } catch {
        continue
    }
    $abRowId = $null
    $abAlias = ''
    foreach ($e in (Get-ListItems $r)) {
        if ("$($e.id)" -eq $rid) {
            $abRowId = [int]$e.row_id
            $abAlias = "$($e.alias)"
            break
        }
    }
    if ($abRowId -eq $null -or $abRowId -le 0) {
        # 不在通讯录里：批量导入应该已经补上了；仍缺则跳过（不单独建，
        # 避免与批量导入产生两条记录）。
        $missing++
        continue
    }
    $checked++
    if ($abAlias -eq $peerAlias) { continue }   # 已一致

    if ($DryRun) {
        Write-Host ("   将修正：" + $rid + "  '" + $abAlias + "' -> '" + $peerAlias + "'") -ForegroundColor Yellow
        $fixed++
        continue
    }
    try {
        Invoke-JsonPost ($base + '/api/admin/address_book/update') @{
            row_id       = $abRowId
            id           = $rid
            alias        = $peerAlias
            user_id      = $abUserId
            collection_id = $abCollection
        } | Out-Null
        Write-Host ("   已修正：" + $rid + "  '" + $abAlias + "' -> '" + $peerAlias + "'") -ForegroundColor Green
        $fixed++
    } catch {
        Write-Warn ('   修正失败 ' + $rid + ': ' + $_)
    }
}

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '========== 结果 ==========' -ForegroundColor White
Write-Host ('设备总数        : ' + $peers.Count)
Write-Host ('已填门店名      : ' + $storePeers.Count)
Write-Host ('通讯录条目核对  : ' + $checked)
Write-Host ('修正别名数量    : ' + $fixed)
if ($missing -gt 0) {
    Write-Host ('未在通讯录中    : ' + $missing + '（批量导入未生效，请检查 collection_id）') -ForegroundColor Yellow
}
if ($DryRun) {
    Write-Host '（DryRun 模式，未实际写入）' -ForegroundColor Yellow
} else {
    Write-Host ''
    Write-Ok '完成。新部署的设备只要填过门店名，就会出现在共享通讯录里。'
}
