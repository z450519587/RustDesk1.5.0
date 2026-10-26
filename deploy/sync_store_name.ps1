# 门店名称同步验证脚本（lejianwen/rustdesk-api）
# 在任意已装 RustDesk 的门店机器上运行，验证"永久令牌 + 写设备管理 + 写共享通讯簿"整条链路。
# 用法: .\sync_store_name.ps1 -StoreName "仁和堂XX店"
#   -StoreName  必填，要写入的门店名称
#   -RustDeskId 可选，本机 RustDesk ID（省略时自动获取）
#   -ApiServer  可选，API 服务器地址（省略时读 store_sync.json）

param(
  [Parameter(Mandatory = $true)] [string] $StoreName,
  [string] $RustDeskId,
  [string] $ApiServer
)

$ErrorActionPreference = 'Stop'
# 内网自签证书放行（内部工具，仅用于同步门店名称）
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) $true }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---- 读取 store_sync.json 配置 ----
$cfgPath = Join-Path $ScriptDir 'store_sync.json'
$cfg = New-Object PSObject
if (Test-Path $cfgPath) {
  # 必须显式 UTF8：PS5.1 默认按 ANSI(GBK) 读文件，会把中文配置读成乱码
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

$adminToken = ''
if ($cfg.PSObject.Properties['adminToken']) { $adminToken = $cfg.adminToken.ToString().Trim() }
$abUserId = 0
if ($cfg.PSObject.Properties['addressBookUserId']) { $abUserId = [int]$cfg.addressBookUserId }
$abCollection = 0
if ($cfg.PSObject.Properties['addressBookCollectionId']) { $abCollection = [int]$cfg.addressBookCollectionId }
if (-not $ApiServer) {
  if ($cfg.PSObject.Properties['apiServer']) { $ApiServer = $cfg.apiServer.ToString().Trim() }
}

if (-not $adminToken) { Write-Host 'X 未配置 adminToken（请先在 store_sync.json 填写）' -ForegroundColor Red; exit 1 }
if (-not $ApiServer)  { Write-Host 'X 未提供 ApiServer（用 -ApiServer 或 store_sync.json 的 apiServer）' -ForegroundColor Red; exit 1 }
$base = $ApiServer.TrimEnd('/')

# ---- 获取本机 RustDesk ID ----
function Find-RustDeskId {
  # 1) 命令行（需在 PATH 中）
  try { $id = (rustdesk --get-id 2>$null).Trim(); if ($id) { return $id } } catch { }
  # 2) 常见安装路径（含 32 位机上的 x86 目录）
  $exeCandidates = @(
    (Join-Path $env:ProgramFiles 'RustDesk\RustDesk.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'RustDesk\RustDesk.exe'),
    'rustdesk.exe'
  )
  foreach ($exe in $exeCandidates) {
    if ($exe -and (Test-Path $exe -ErrorAction SilentlyContinue)) {
      try { $id = (& $exe --get-id 2>$null).Trim(); if ($id) { return $id } } catch { }
    }
  }
  # 3) 直接读取本机配置文件（最稳，无需 rustdesk 在 PATH）
  $cfgCandidates = @(
    (Join-Path $env:APPDATA 'RustDesk\config\RustDesk2.toml'),
    (Join-Path $env:APPDATA 'RustDesk\config\RustDesk.toml'),
    (Join-Path $env:LOCALAPPDATA 'RustDesk\config\RustDesk2.toml'),
    (Join-Path $env:LOCALAPPDATA 'RustDesk\config\RustDesk.toml')
  )
  foreach ($cc in $cfgCandidates) {
    if (Test-Path $cc) {
      $txt = Get-Content $cc -Raw
      # 匹配 [id] 小节里的 id = "...."
      if ($txt -match '(?s)\[id\][^\[]*?id\s*=\s*"([^"]+)"') {
        return $Matches[1].Trim()
      }
    }
  }
  return $null
}

if (-not $RustDeskId) {
  Write-Host '>> 获取本机 RustDesk ID ...' -ForegroundColor Cyan
  $RustDeskId = Find-RustDeskId
  if (-not $RustDeskId) {
    Write-Host 'X 无法自动获取 RustDesk ID。两种办法：' -ForegroundColor Red
    Write-Host '   (1) 在已装本定制 RustDesk 的门店机器上运行本脚本；' -ForegroundColor Yellow
    Write-Host '   (2) 手动传入： .\sync_store_name.ps1 -StoreName "仁和堂XX店" -RustDeskId "该机器的RustDesk ID"' -ForegroundColor Yellow
    Write-Host '       RustDesk ID 在客户端主界面/设置里可见（一串数字）。' -ForegroundColor Yellow
    exit 1
  }
}
Write-Host ('>> 本机 RustDesk ID = ' + $RustDeskId) -ForegroundColor Cyan

$headers = @{ 'api-token' = $adminToken; 'Accept' = 'application/json' }

# ---- 统一的 JSON POST ----
# 关键：PowerShell 5.1 传"字符串"body 时，若 ContentType 未带 charset，
# 会按 ASCII 编码发送，中文全部变成 "?"（服务端存入 ???XX?）。
# 因此这里一律把 JSON 转成 UTF-8 字节数组再发送。
function Invoke-JsonPost($uri, $obj) {
  $json = $obj | ConvertTo-Json -Compress -Depth 5
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Invoke-RestMethod -Uri $uri -Headers $headers -Method Post `
    -ContentType 'application/json; charset=utf-8' -Body $bytes
}

# 读回接口，把服务端真正存的值取出来（用于校验中文是否正确落库）
function Get-JsonGet($uri) {
  Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
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

# ---- 1) 设备管理别名 ----
Write-Host '' 
Write-Host '>> [1/2] 设备管理(peer)别名' -ForegroundColor Cyan
$peerRowId = $null
try {
  $listUrl = $base + '/api/admin/peer/list?id=' + $RustDeskId
  $resp = Invoke-RestMethod -Uri $listUrl -Headers $headers -Method Get
  $list = Get-ListItems $resp
  foreach ($e in $list) {
    if ([string]$e.id -eq $RustDeskId) { $peerRowId = [int]$e.row_id; break }
  }
} catch {
  Write-Host ('   peer/list 请求失败: ' + $_) -ForegroundColor Yellow
}

$peerOk = $false
if ($peerRowId -and $peerRowId -gt 0) {
  try {
    Invoke-JsonPost ($base + '/api/admin/peer/update') @{ row_id = $peerRowId; id = $RustDeskId; alias = $StoreName }
    Write-Host '   OK 设备管理别名已更新' -ForegroundColor Green
    $peerOk = $true
  } catch {
    Write-Host ('   X peer/update 失败: ' + $_) -ForegroundColor Red
  }
} else {
  Write-Host '   X 设备管理找不到本机 ID（确认客户端已连上 API 服务器）' -ForegroundColor Red
}

# ---- 2) 共享通讯簿别名 ----
Write-Host '' 
Write-Host '>> [2/2] 共享通讯簿(address_book)别名' -ForegroundColor Cyan
$abRowId = $null
try {
  $abListUrl = $base + '/api/admin/address_book/list?user_id=' + $abUserId + '&collection_id=' + $abCollection + '&id=' + $RustDeskId
  $resp2 = Invoke-RestMethod -Uri $abListUrl -Headers $headers -Method Get
  $list2 = Get-ListItems $resp2
  foreach ($e in $list2) {
    if ([string]$e.id -eq $RustDeskId) { $abRowId = [int]$e.row_id; break }
  }
} catch {
  Write-Host ('   address_book/list 请求失败: ' + $_) -ForegroundColor Yellow
}

$abOk = $false
$mode = 'create'
$abPayload = @{ id = $RustDeskId; alias = $StoreName; user_id = $abUserId; collection_id = $abCollection }
if ($abRowId -and $abRowId -gt 0) {
  $mode = 'update'
  $abPayload['row_id'] = $abRowId
}
try {
  Invoke-JsonPost ($base + '/api/admin/address_book/' + $mode) $abPayload
  Write-Host ('   OK 通讯簿别名已写入 (' + $mode + ')') -ForegroundColor Green
  $abOk = $true
} catch {
  Write-Host ('   X address_book 写入失败: ' + $_) -ForegroundColor Red
}

# ---- 3) 读回校验：确认服务端存下来的中文不是乱码 ----
Write-Host ''
Write-Host '>> [3/3] 读回校验（检查落库中文是否正确）' -ForegroundColor Cyan
$peerAlias = ''
try {
  $r = Get-JsonGet ($base + '/api/admin/peer/list?id=' + $RustDeskId)
  foreach ($e in (Get-ListItems $r)) {
    if ([string]$e.id -eq $RustDeskId) { $peerAlias = [string]$e.alias; break }
  }
} catch { Write-Host ('   读取 peer 失败: ' + $_) -ForegroundColor Yellow }

$abAlias = ''
try {
  $r2 = Get-JsonGet ($base + '/api/admin/address_book/list?user_id=' + $abUserId + '&collection_id=' + $abCollection + '&id=' + $RustDeskId)
  foreach ($e in (Get-ListItems $r2)) {
    if ([string]$e.id -eq $RustDeskId) { $abAlias = [string]$e.alias; break }
  }
} catch { Write-Host ('   读取 address_book 失败: ' + $_) -ForegroundColor Yellow }

function Test-AliasOk($saved) {
  if (-not $saved) { return $false }
  if ($saved -eq $StoreName) { return $true }
  # 出现替换字符/问号即视为乱码
  if ($saved -match '[\?\uFFFD]') { return $false }
  return $false
}

$peerSaved = (Test-AliasOk $peerAlias)
$abSaved = (Test-AliasOk $abAlias)

Write-Host ('   设备管理实际值: ' + $(if ($peerAlias) { $peerAlias } else { '(读不到)' })) -ForegroundColor $(if ($peerSaved) { 'Green' } else { 'Yellow' })
Write-Host ('   通讯簿实际值  : ' + $(if ($abAlias) { $abAlias } else { '(读不到)' })) -ForegroundColor $(if ($abSaved) { 'Green' } else { 'Yellow' })

if ($peerSaved -and $abSaved) {
  Write-Host '   OK 中文校验通过，落库内容与输入一致' -ForegroundColor Green
} else {
  Write-Host '   X 中文校验不通过（落库值与输入不一致，可能是编码或数据库字符集问题）' -ForegroundColor Red
}

# ---- 汇总 ----
Write-Host ''
Write-Host '========== 结果 ==========' -ForegroundColor White
$peerText = '失败'
if ($peerOk) { $peerText = '成功' }
$abText = '失败'
if ($abOk) { $abText = '成功' }
$encText = '未校验'
if ($peerSaved -and $abSaved) { $encText = '通过' } elseif ($peerAlias -or $abAlias) { $encText = '乱码' }
Write-Host ('设备管理 : ' + $peerText)
Write-Host ('共享通讯录 : ' + $abText)
Write-Host ('中文编码 : ' + $encText)
if ($peerOk -and $abOk -and $peerSaved -and $abSaved) {
  Write-Host '整条链路验证通过（写入 + 中文编码均正确），可放心把逻辑编译进客户端。' -ForegroundColor Green
} else {
  Write-Host '存在问题，请根据上面错误信息排查。' -ForegroundColor Yellow
}

