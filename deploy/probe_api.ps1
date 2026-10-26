<#
.SYNOPSIS  探测 lejianwen/rustdesk-api 的登录路径前缀
.DESCRIPTION
  对 GET=200 的候选端口，尝试多种登录路径前缀，返回非 404 的那条就是正确路径。
.EXAMPLE
  .\probe_api.ps1 -HostIp "192.168.100.190"
#>
param(
  [Parameter(Mandatory=$true)][string]$HostIp
)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { param($a, $b, $c, $d) $true }
$ErrorActionPreference = 'SilentlyContinue'

$bases = @(
  ("http://" + $HostIp + ":21114"),
  ("http://" + $HostIp + ":8080"),
  ("https://" + $HostIp),
  ("http://" + $HostIp + ":443"),
  ("https://" + $HostIp + ":21114")
)
$loginPaths = @("/admin/login", "/api/admin/login", "/api/login", "/login")

foreach ($base in $bases) {
  foreach ($p in $loginPaths) {
    $uri = $base + $p
    try {
      $r = Invoke-WebRequest -Uri $uri -Method Post -TimeoutSec 6 -UseBasicParsing -ContentType 'application/json' -Body '{"username":"probe","password":"probe"}'
      $code = $r.StatusCode
    } catch {
      $resp = $_.Exception.Response
      if ($resp -ne $null) { $code = [int]$resp.StatusCode } else { $code = "NO-ROUTE" }
    }
    $tag = ""
    if ($code -ne 404 -and $code -ne "NO-ROUTE") { $tag = "  <== 命中，正确路径" }
    Write-Host ("POST {0,-46} -> {1,-6}{2}" -f $uri, $code, $tag)
  }
}
Write-Host ""
Write-Host "说明：标 '命中' 的那一行，其开头地址 + 路径 就是 apiServer 基址 + 登录路径。"

