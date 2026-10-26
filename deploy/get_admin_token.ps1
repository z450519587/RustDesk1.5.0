<#
.SYNOPSIS  获取 lejianwen/rustdesk-api 的临时管理员令牌（7天有效）
.DESCRIPTION
  用管理员账号密码调 /admin/login，打印 data.token。
  拿到后需进 MySQL 跑 store_sync_token.sql 把它改成永久。
.EXAMPLE
  .\get_admin_token.ps1 -ApiServer "https://你的域名" -Username "admin" -Password "密码"
#>
param(
  [Parameter(Mandatory=$true)][string]$ApiServer,
  [Parameter(Mandatory=$true)][string]$Username,
  [Parameter(Mandatory=$true)][string]$Password
)
$ErrorActionPreference = 'Stop'
# 内网自签证书放行（内部工具，仅用于取令牌）
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) $true }
$base = $ApiServer.TrimEnd('/')
$url = $base + '/api/admin/login'
$body = (@{ username = $Username; password = $Password } | ConvertTo-Json -Compress)
# PS 5.1 传字符串 body 且 ContentType 无 charset 时按 ASCII 编码，中文/密码会变 "?"
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
try {
  $resp = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body $bodyBytes
  $token = $null
  if ($resp.PSObject.Properties['data'] -and $resp.data.PSObject.Properties['token']) {
    $token = $resp.data.token
  } elseif ($resp.PSObject.Properties['token']) {
    $token = $resp.token
  }
  if ($token) {
    Write-Host '========================================'
    Write-Host ('临时管理员令牌（7天有效）：')
    Write-Host $token
    Write-Host '========================================'
    Write-Host '下一步：进 MySQL 跑下面这行把它改成永久：'
    Write-Host ("UPDATE user_tokens SET expired_at = 253402300799 WHERE token = '{0}';" -f $token)
  } else {
    Write-Host '未拿到 token，接口返回：'
    Write-Host ($resp | ConvertTo-Json -Compress -Depth 5)
  }
} catch {
  Write-Host ('登录失败: {0}' -f $_.Exception.Message)
  Write-Host '提示：若提示需要验证码，请先在网页控制台登录一次再试。'
}



