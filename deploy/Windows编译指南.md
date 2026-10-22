# RustDesk 1.5.0 定制版 —— Windows 编译指南（仁和堂专用远程工具）

> 编写日期：2026-10-22
> 目标产物：`target\release\rustdesk.exe`（已含品牌化 + 新权限策略 + 禁用更新提示）

---

## 一、先说结论：为什么没能在这台机器上直接出包

我把整条构建链在本机实跑了一遍，结论是**本机不具备出包条件**，硬证据如下（都可复现）：

| # | 障碍 | 实测证据 | 能否绕过 |
|---|---|---|---|
| 1 | **没有 MSVC 编译器** | `vswhere` 查不到 Visual Studio C++ 工具链；`Program Files` 下无 VS、无 Windows SDK | 需装 VS Build Tools（**要管理员 + UAC 交互**，本机为非管理员，无法静默安装） |
| 2 | **vcpkg 拿不到** | `vcpkg.exe` 托管在 GitHub Releases，本机代理对 `github.com/releases/download` 一律 404；华为云镜像 `/vcpkg/` 返回的是 HTML 门户页而非真实 zip；vcpkg 源码 tarball 里 `src/` 是子模块（0 个文件） | 只能换一台能访问 GitHub 的机器，或手工准备 6 个 C 库（aom/libjpeg-turbo/opus/libvpx/libyuv/ffmpeg）——后者工作量以天计 |
| 3 | **磁盘不够** | E 盘仅剩 **19.3 GB**（VS Build Tools ≈10GB + Flutter ≈3GB + vcpkg 依赖 ≈5GB + 产物 ≈10GB） | 清理磁盘或换机器 |
| 4 | **GitHub 主站被封** | `github.com` → CONNECT 502；但 `codeload.github.com`（源码 tarball）→ 200 | 有 HTTP 代理即可（cargo 的 30 个 git 依赖 + vcpkg 缓存都要它） |

**好消息**：以下"国内可跑"的方案已被我实测验证有效，已固化进构建脚本：

| 项 | 验证结果 |
|---|---|
| Rust 1.99.1 工具链 | ✅ 已装（rustup 走 `rsproxy.cn` 镜像，官方源在本机被挡） |
| crates 依赖源 | ✅ `rsproxy.cn` 稀疏索引 200（官方 `static.crates.io` 502） |
| Flutter 国内镜像 | ✅ `pub.flutter-io.cn` 与 `storage.flutter-io.cn` 均 200 |
| 源码 tarball 通道 | ✅ `codeload.github.com` 200（`raw.githubusercontent.com` 200） |
| 中文批处理兼容性 | ✅ `chcp 65001` 下中文文件名 copy/创建实测通过 |

---

## 二、你需要准备的一台机器

**要求**（一台普通的 Windows 10/11 开发机即可，不必是服务器）：

| 项 | 规格 | 说明 |
|---|---|---|
| 操作系统 | Windows 10/11 x64 | 需要能装 VS Build Tools |
| 磁盘 | 剩余 **≥ 60 GB** | E 盘不够的话清一下，或装到 C 盘 |
| 内存 | ≥ 8 GB | 16 GB 更舒服（本机 15.2 GB 够用） |
| 编译器 | **Visual Studio Build Tools 2022**，勾选「使用 C++ 的桌面开发」+ Windows 10/11 SDK | 必需，Flutter 的 Windows 构建硬性要求 MSVC |
| Rust | rustup（脚本会自动配 rsproxy 镜像） | — |
| Flutter | 3.24.x 稳定版 | 建议 3.24.5（仓库的补丁脚本按 3.24.4 写的） |
| vcpkg | 官方发行版 | 必需 |
| **网络** | 能访问 `github.com`（直连或 HTTP 代理） | cargo 的 30 个 git 依赖、vcpkg 二进制缓存都要它 |

**最快装法**：

1. VS Build Tools：<https://aka.ms/vs/17/release/vs_BuildTools.exe> → 静默安装：
   ```powershell
   .\vs_BuildTools.exe --quiet --wait --norestart --nocache `
     --add Microsoft.VisualStudio.Workload.VCTools `
     --add Microsoft.VisualStudio.Component.Windows11SDK.22621 `
     --includeRecommended
   ```
2. Rust：<https://rsproxy.cn/rustup> 镜像安装（脚本已自动配置环境变量）
3. Flutter：<https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/> 下载 3.24.5，解压到 `E:\tools\flutter`
4. vcpkg：见下一节（**必须在能访问 GitHub 的机器上准备**）

---

## 二之二、vcpkg 怎么准备（关键卡点，单独说明）

RustDesk 的 Windows 构建依赖 7 个原生库（`aom`、`libjpeg-turbo`、`opus`、`libvpx`、`libyuv`、`ffmpeg`、`mfx-dispatch`），全部要 **x64-windows-static 静态库**，由 vcpkg 提供。而 vcpkg 的**工具本体与预编译缓存都托管在 GitHub Releases**——本机代理对该路径一律 404（`releases/latest/download/vcpkg.exe` 也是 404）。

所以：**vcpkg 相关的东西必须在"能访问 GitHub 的机器"上准备**，有两条路：

### 路线 A（推荐）：在能上网的机器上预编译好，整个目录拷过去

在一台能访问 GitHub 的 Windows 机器上：

```bash
git clone https://github.com/microsoft/vcpkg
cd vcpkg
bootstrap-vcpkg.bat -disableMetrics
vcpkg install --triplet x64-windows-static
```

（仓库根目录有 `vcpkg.json` + `res/vcpkg` overlay ports，**必须在 RustDesk 源码根目录**执行这条命令，vcpkg 会按 manifest 模式装齐所有库。）

装完后，把整个 `vcpkg/installed/x64-windows-static` 目录（以及 `vcpkg/installed/vcpkg` 信息目录）压缩拷到构建机，然后在构建脚本里指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -VcpkgInstalled "D:\vcpkg\installed"
```

> 这样构建机**完全不需要连 GitHub 拿原生库**，只拉 crates 与 git 依赖（走代理或镜像）。

### 路线 B：直接用 vcpkg 的二进制缓存 zip

在能上网的机器上，把需要的 `{package}_{triplet}.zip`（如 `opus_x64-windows-static.zip`）放进一个目录，拷到构建机后：

```powershell
powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -VcpkgCacheDir "D:\vcpkg-cache"
```

vcpkg 会用 `files` 源命中本地缓存。

### 路线 C：构建机本身能访问 GitHub

最省事：直接 `git clone https://github.com/microsoft/vcpkg` + `bootstrap-vcpkg.bat`，然后跑 `build_rht.ps1`（脚本会自动配 `VCPKG_ROOT`）。此时请确保 `github.com` 直连或已设 `-GitProxy`。

---

把本目录下的 `build_rht.ps1` 与 `RustDesk1.5.0-master` 一起拷到那台机器，然后：

```powershell
# ① 先体检，只报告不改动
powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -CheckOnly

# ② 正式构建（github 需要代理时加 -GitProxy）
powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -GitProxy http://127.0.0.1:7890

# ③ 如果你事先把 vcpkg 的 {package}_{triplet}.zip 放在本地目录里
powershell -ExecutionPolicy Bypass -File .\build_rht.ps1 -VcpkgCacheDir D:\vcpkg-cache
```

脚本自动完成：

1. **体检**：MSVC / Windows SDK / cargo / Flutter / vcpkg / 磁盘 / 内存 / GitHub 可达性
2. **国内镜像**：cargo→rsproxy 稀疏源、rustup→rsproxy、Flutter→pub.flutter-io.cn + storage.flutter-io.cn
3. **Git 代理**：`git config --global http.proxy`（解决 30 个 git 依赖）
4. **vcpkg**：`VCPKG_ROOT` + 二进制缓存（GitHub release 走代理，或本地 files 源）
5. **构建**：`python build.py --flutter`
6. **产物校验**：文件属性是否为品牌名、UAC 清单是否为 `asInvoker`、图标资源是否就位

> 首次构建耗时：crates 首次下载 + vcpkg 首次编译原生库（ffmpeg/aom/libvpx 等）+ Flutter 引擎制品下载，**顺利的话 40–90 分钟**；有 vcpkg 二进制缓存会快很多。

---

## 四、常见坑（都是我在本机踩过的）

| 现象 | 原因 | 对策 |
|---|---|---|
| `component download failed for rustc` | `static.rust-lang.org` 被挡 | 设 `RUSTUP_DIST_SERVER=https://rsproxy.cn`（脚本已做） |
| `error sending request ... tunnel error` | `static.crates.io` 被挡 | cargo 换 rsproxy 稀疏源（脚本已做） |
| `pub get` 失败 / 拉 `dash_chat_2` 超时 | `github.com` 被挡 | 设 `PUB_HOSTED_URL=https://pub.flutter-io.cn`；`dash_chat_2` 在 pub.dev 上有同名包，可改用 pub.dev 版本 |
| cargo 卡在 `Fetching git repository` | 30 个 git 依赖走 github | `-GitProxy`，或先 `git config --global http.proxy` |
| vcpkg 报 `Failed to download` / 缓存 miss | GitHub release 不通 | 用 `-VcpkgCacheDir` 本地缓存；或确保代理可用 |
| `link.exe not found` | 缺 MSVC / SDK | 装 VS Build Tools 的「使用 C++ 的桌面开发」工作负载 |
| `git clone` 报 `RPC failed` | 网络抖动 | `git config --global http.postBuffer 524288000` |
| 中文快捷方式名变乱码 | 批处理代码页 | 安装脚本已内置 `chcp 65001`；我已实测中文路径 copy 正常 |

---

## 五、构建完成后的验收（14 条，与品牌化交付说明一致）

1. 双击 `rustdesk.exe` → **不弹 UAC**，普通权限启动
2. 任务管理器「提升」列：界面=否；`rustdesk.exe --service`=是（SYSTEM）
3. 窗口标题 = 仁和堂专用远程工具
4. 界面左上角显示品牌横幅（深色主题自动换白字版）
5. 任务栏/资源管理器图标 = 新蓝色菱形
6. 托盘图标 + 悬停气泡 = 新图标 + 品牌名
7. 桌面/开始菜单快捷方式名 = 品牌名
8. 控制面板「程序和功能」= 品牌名
9. exe 属性 → 文件说明/产品名称 = 品牌名
10. services.msc：服务显示名 = 品牌名 Service；登录为 LocalSystem；启动类型 自动
11. 服务属性 → 恢复：失败自动重启已生效
12. 首次安装弹**一次** UAC（安装动作需要），之后不再弹
13. 注销重登：约 30 秒后出现托盘图标，全程无弹窗
14. 启动后等 1 分钟：**不出现**任何"发现新版本/可升级"提示

快速命令行校验：

```powershell
mt.exe -inputresource:rustdesk.exe;#1 -out:$env:TEMP\m.xml
Select-String -Path $env:TEMP\m.xml -Pattern "asInvoker"
(Get-Item rustdesk.exe).VersionInfo | Select-Object FileDescription,ProductName
sc.exe qc rustdesk
```

---

## 六、如果暂时拿不到编译环境（应急方案）

门店的远程功能**不依赖品牌化 exe**——这个仓库已经把自建服务器写死为 `rd.renhetang.cn`（`libs/hbb_common/src/config.rs` 的 `RENDEZVOUS_SERVERS`），所以：

1. 先用 **RustDesk 官方 1.5.x 客户端**（官方包已内置该自建服务器配置，或手动在设置里填 `rd.renhetang.cn`），门店即刻可用；
2. 等有编译环境后，用上面的脚本出品牌化版本替换即可，**服务端不用动**；
3. 品牌化只是"外壳"（名称/图标/提权策略/升级提示），不影响远程能力。

---

## 七、文件清单

| 文件 | 说明 |
|---|---|
| `build_rht.ps1` | Windows 一键构建脚本（体检 + 镜像 + 代理 + vcpkg + 构建 + 产物校验） |
| `renhetang_brand_admin_FULL.patch` | 相对原始仓库的完整补丁（禁用更新 + 品牌化 + 权限策略） |
| `renhetang_brand_admin_ONLY.patch` | 在「禁用更新」补丁之上的增量补丁 |
| `update_disabled.patch` | 「禁用版本检查/更新提示」补丁 |
| `deploy_silent_autostart.ps1` | 部署后：服务权限 + 静默自启（任务计划）配置脚本 |
| `RustDesk1.5.0-master/` | 已改好的完整源码 |
| `仁和堂专用远程工具_品牌化与提权_交付说明.md` | 品牌化与权限策略的改动说明 |
| `Windows编译指南.md` | 本文档 |
