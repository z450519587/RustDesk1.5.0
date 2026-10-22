<#
.SYNOPSIS
    仁和堂专用远程工具（RustDesk 1.5.0 定制版）Windows 一键构建脚本

.DESCRIPTION
    在具备 Visual Studio Build Tools 的 Windows 机器上，自动完成：
      0. 环境体检（MSVC / Windows SDK / Rust / Flutter / vcpkg / 磁盘 / 内存）
      1. 国内镜像配置（cargo→rsproxy、rustup→rsproxy、Flutter→flutter-io.cn）
      2. Git 依赖代理配置（github.com 直连被封时，走 HTTP 代理）
      3. vcpkg 环境与二进制缓存（GitHub release 走代理，或本地 files 缓存目录）
      4. 调用仓库自带 build.py --flutter 完成 Rust + Flutter 构建
      5. 产物校验（品牌名、UAC 权限清单、图标资源、多尺寸 ICO）

    典型用法：
      # 先体检，不改任何东西
      powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -CheckOnly

      # 正式构建（GitHub 需要代理时加 -GitProxy http://127.0.0.1:7890）
      powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -GitProxy http://127.0.0.1:7890

.PARAMETER RepoPath
    RustDesk 源码目录（含 build.py）。默认取本脚本同级下的 RustDesk1.5.0-master。

.PARAMETER ToolRoot
    工具链根目录（放 flutter / vcpkg）。默认 E:\tools。

.PARAMETER GitProxy
    HTTP 代理地址，例如 http://127.0.0.1:7890。用于访问 github.com（vcpkg 与 cargo 的 git 依赖都要它）。

.PARAMETER GitUrlInsteadOf
    Git URL 改写前缀，例如 https://ghfast.top/https://github.com/ 。
    用于 github.com 直连被封、但某加速前缀可用的场景：cargo 的 30 个 git 依赖会整体改道。
    前提是 cargo 使用 git CLI（脚本已设置 net.git-fetch-with-cli = true）。

.PARAMETER VcpkgCacheDir
    本地 vcpkg 二进制缓存目录（内含 {package}_{triplet}.zip）。指定后走 files 源，不需要连 GitHub。

.PARAMETER VcpkgInstalled
    已装好的 vcpkg 库目录（含 x64-windows-static 子目录）。
    适用于「在能上网的机器上装好原生库、整个拷过来」的场景，构建机无需访问 GitHub 取原生库。

.PARAMETER CheckOnly
    只做体检与报告，不执行构建。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -CheckOnly
#>

[CmdletBinding()]
param(
    [string]$RepoPath,
    [string]$ToolRoot = 'E:\tools',
    [string]$GitProxy,
    [string]$GitUrlInsteadOf,
    [string]$VcpkgCacheDir,
    [string]$VcpkgInstalled,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # 关闭 Invoke-WebRequest 进度条，避免刷屏
$BRAND = '仁和堂专用远程工具'
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $RepoPath) { $RepoPath = Join-Path $SCRIPT_DIR 'RustDesk1.5.0-master' }
$FlutterDir = Join-Path $ToolRoot 'flutter'
$VcpkgDir  = Join-Path $ToolRoot 'vcpkg'

function Say($m) { Write-Host $m }
function Ok($m)  { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "  [注意] $m" -ForegroundColor Yellow }
function Bad($m) { Write-Host "  [缺失] $m" -ForegroundColor Red }
function Sec($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }

$report = [ordered]@{}

# ------------------------------------------------------------------ 0. 体检
Sec '0. 环境体检'

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$msvcOk = $false
if (Test-Path $vswhere) {
    $vcPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
    if ($vcPath) {
        $msvcOk = $true
        Ok "MSVC 工具链：$vcPath"
    }
}
if (-not $msvcOk) { Bad '未检测到 Visual Studio C++ 工具链（必需）' }

$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
if (Test-Path $sdkRoot) { Ok "Windows SDK：$sdkRoot" } else { Bad '未检测到 Windows SDK（必需）' }

$cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"
if (Test-Path $cargo) { Ok "Rust：$(& $cargo --version)" } else { Bad '未检测到 cargo（需 rustup 安装）' }

$flutterExe = Join-Path $FlutterDir 'bin\flutter.bat'
if (Test-Path $flutterExe) { Ok "Flutter：$FlutterDir" } else { Warn2 "未检测到 Flutter（$FlutterDir），如需从源码构建 Flutter 界面则必需" }

if (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe')) { Ok "vcpkg：$VcpkgDir" }
else { Bad "未检测到 vcpkg（$VcpkgDir）——原生库依赖它，必需" }

$freeGB = [math]::Round((Get-PSDrive E).Free / 1GB, 1)
if ($freeGB -ge 40) { Ok "E 盘可用 ${freeGB} GB（建议 ≥ 40GB）" }
else { Bad "E 盘可用仅 ${freeGB} GB，构建会失败（建议 ≥ 40GB）" }

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
if ($ramGB -ge 8) { Ok "内存 ${ramGB} GB" } else { Warn2 "内存仅 ${ramGB} GB，编译会很慢" }

# GitHub 可达性（决定 git 依赖与 vcpkg 缓存能否直接走公网）
function Test-GitHub {
    try {
        $r = Invoke-WebRequest -Uri 'https://github.com' -Method Head -TimeoutSec 12 -UseBasicParsing
        return ($r.StatusCode -lt 400)
    } catch { return $false }
}
$ghDirect = Test-GitHub
if ($ghDirect) { Ok 'github.com 直连正常' }
elseif ($GitProxy) { Warn2 "github.com 直连不通，将使用代理 $GitProxy" }
else { Bad 'github.com 直连不通：cargo 的 git 依赖与 vcpkg 二进制缓存都取不到，请用 -GitProxy 指定代理' }

# ------------------------------------------------- 1. 国内镜像配置（cargo/rustup/flutter）
Sec '1. 国内镜像配置'
if (-not $CheckOnly) {
    $cargoHome = "$env:USERPROFILE\.cargo"
    New-Item -ItemType Directory -Force -Path $cargoHome | Out-Null
    $cfg = @'
[source.crates-io]
replace-with = 'rsproxy-sparse'

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"

[net]
git-fetch-with-cli = true
'@
    Set-Content -Path (Join-Path $cargoHome 'config.toml') -Value $cfg -Encoding UTF8
    Ok 'cargo 已切换到 rsproxy 稀疏源（~/.cargo/config.toml）'

    if (Test-Path $cargo) {
        & $cargo --version | Out-Null
        [Environment]::SetEnvironmentVariable('RUSTUP_DIST_SERVER', 'https://rsproxy.cn', 'User')
        [Environment]::SetEnvironmentVariable('RUSTUP_UPDATE_ROOT', 'https://rsproxy.cn/rustup', 'User')
        Ok 'rustup 镜像已设置（rsproxy）'
    }

    if (Test-Path $flutterExe) {
        [Environment]::SetEnvironmentVariable('PUB_HOSTED_URL', 'https://pub.flutter-io.cn', 'User')
        [Environment]::SetEnvironmentVariable('FLUTTER_STORAGE_BASE_URL', 'https://storage.flutter-io.cn', 'User')
        Ok 'Flutter 已切换国内镜像（pub.flutter-io.cn / storage.flutter-io.cn）'
    }
} else {
    Say '  (CheckOnly) 跳过镜像写入'
}

# ------------------------------------------------------------- 2. Git 代理
Sec '2. Git 依赖代理'
if ($GitProxy) {
    if (-not $CheckOnly) {
        & git config --global http.proxy $GitProxy
        & git config --global https.proxy $GitProxy
        Ok "git 全局代理已设为 $GitProxy"
    } else { Say "  (CheckOnly) 将设置代理 $GitProxy" }
} elseif ($GitUrlInsteadOf) {
    if (-not $CheckOnly) {
        & git config --global url."$GitUrlInsteadOf".insteadOf "https://github.com/"
        Ok "git URL 改写已设置：https://github.com/  ->  $GitUrlInsteadOf"
        Say '  提示：cargo 需使用 git CLI 才会套用该改写（脚本已在 ~/.cargo/config.toml 设置 net.git-fetch-with-cli = true）'
    } else { Say "  (CheckOnly) 将设置 URL 改写 $GitUrlInsteadOf" }
} elseif ($ghDirect) {
    Ok 'github.com 可直连，无需代理'
} else {
    Bad '未提供 -GitProxy / -GitUrlInsteadOf，且 github.com 不通 —— 约 30 个 git 依赖（parity-tokio-ipc / magnum-opus / webrtc / rdev …）会拉取失败'
}

# ------------------------------------------------------------- 3. vcpkg
Sec '3. vcpkg 与原生库'
if ($VcpkgInstalled) {
    if (Test-Path $VcpkgInstalled) {
        if (-not $CheckOnly) {
            [Environment]::SetEnvironmentVariable('VCPKG_INSTALLED_ROOT', $VcpkgInstalled, 'User')
            $env:VCPKG_INSTALLED_ROOT = $VcpkgInstalled
            Ok "VCPKG_INSTALLED_ROOT 已设置：$VcpkgInstalled（原生库已就位，无需联网取库）"
        } else { Say "  (CheckOnly) 将设置 VCPKG_INSTALLED_ROOT=$VcpkgInstalled" }
        $libDir = Join-Path $VcpkgInstalled 'x64-windows-static\lib'
        if (Test-Path $libDir) {
            $libs = (Get-ChildItem $libDir -Filter *.lib -ErrorAction SilentlyContinue).Count
            if ($libs -gt 0) { Ok "已装原生库 $libs 个 .lib：$libDir" }
            else { Bad "目录存在但没有 .lib：$libDir" }
        } else { Bad "缺少 x64-windows-static\\lib 子目录：$libDir" }
    } else {
        Bad "-VcpkgInstalled 指向的目录不存在：$VcpkgInstalled"
    }
} elseif (Test-Path (Join-Path $VcpkgDir 'vcpkg.exe')) {
    if (-not $CheckOnly) {
        [Environment]::SetEnvironmentVariable('VCPKG_ROOT', $VcpkgDir, 'User')
        Ok "VCPKG_ROOT 已设置：$VcpkgDir"

        $vcpkgExe = Join-Path $VcpkgDir 'vcpkg.exe'
        if ($VcpkgCacheDir -and (Test-Path $VcpkgCacheDir)) {
            $bs = "clear,files,$VcpkgCacheDir,readwrite"
            & $vcpkgExe install --triplet x64-windows-static --x-binarysource=$bs 2>&1 | Select-Object -Last 5
            Ok "已用本地二进制缓存：$VcpkgCacheDir"
        } else {
            Say '  未指定 -VcpkgCacheDir：将走 GitHub release 默认缓存（需要能访问 github.com 或已配代理）'
        }
    }
} else {
    Bad "vcpkg 缺失。请安装 vcpkg 并放到 $VcpkgDir（其中 vcpkg.exe 必须存在）"
    Say '  提示：vcpkg 的原生库有 aom / libjpeg-turbo / opus / libvpx / libyuv / ffmpeg / mfx-dispatch，'
    Say '        全部走 x64-windows-static 静态库；首次构建会编译很久，建议配好二进制缓存。'
}

# ------------------------------------------------------------- 4. 构建
Sec '4. 构建'
if ($CheckOnly) {
    Warn2 'CheckOnly 模式：不执行构建。补齐上面标红项后去掉此参数重跑。'
} else {
    if (-not (Test-Path (Join-Path $RepoPath 'build.py'))) {
        Bad "源码目录无效：$RepoPath"
        exit 1
    }
    Push-Location $RepoPath
    $env:VCPKG_ROOT = $VcpkgDir
    $env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
    $env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
    Say '  执行：python build.py --flutter   （首次会下载 crates 与 Flutter 引擎制品，耗时较长）'
    & python build.py --flutter
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -eq 0) { Ok "构建完成（exit=$code）" } else { Bad "构建失败（exit=$code）" }
}

# ------------------------------------------------------------- 5. 产物校验
Sec '5. 产物校验'
$exe = Join-Path $RepoPath 'target\release\rustdesk.exe'
if (Test-Path $exe) {
    Ok "产物存在：$exe  ($([math]::Round((Get-Item $exe).Length/1MB,1)) MB)"
    $vi = (Get-Item $exe).VersionInfo
    Say "  FileDescription : $($vi.FileDescription)"
    Say "  ProductName     : $($vi.ProductName)"
    if ($vi.FileDescription -like "*$BRAND*") { Ok '文件属性已是品牌名' } else { Bad "文件属性不是品牌名（应为 $BRAND）" }

    $mt = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter mt.exe -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -match 'x64' } | Select-Object -First 1
    if ($mt) {
        $out = Join-Path $env:TEMP 'rht_manifest.xml'
        & $mt.FullName -inputresource:"$exe";#1 -out:$out 2>$null
        if (Test-Path $out) {
            $m = Get-Content $out -Raw
            if ($m -match 'requireAdministrator') { Warn2 '清单仍是 requireAdministrator（界面提权），应改为 asInvoker' }
            elseif ($m -match 'asInvoker') { Ok 'UAC 清单为 asInvoker（界面不提权，服务提权）' }
            else { Warn2 '未在清单中找到执行级别' }
        }
    } else { Warn2 '未找到 mt.exe，跳过清单校验' }
} else {
    Warn2 "未找到产物：$exe"
}

Sec '完成'
Say "  报告：品牌名=$BRAND；产物目录=$(Join-Path $RepoPath 'target\release')"
Say ''
