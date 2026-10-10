# Windows 开发接手（2026-10-09）

产品名为灵犀输入法 / Lingxi IME，技术架构及现有文件名保留 RIMES。
这是原生 TSF + Broker 的开发入口；日用验收优先保证关闭 Buffer 时正常打字，再验证 Buffer、设置和安装卸载。

## 当前源码与安装包

| 内容 | 状态 |
| --- | --- |
| `main` | 已合入 PR #107：候选定位、设置窗口遮挡和 TSF 运行库兼容修复，包含原贡献者提交 |
| `codex/windows-standard-user-install` | 已跟上 `main`，增加 #93 跨账户安装的系统阶段与原用户阶段分离；真实双账号 UAC 验收待完成 |
| 公开 Windows 安装包 | [1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1) |
| Windows 1.1.2 | 草稿发布；源码合并不会自动替换其安装包，也不代表草稿包包含 #107 或 #93 |

此表是本次交接快照。下载时以 Release 是否公开及其 `BUILD-INFO.json`、`PACKAGE.json` 中的确切提交和校验和为准。

## 新电脑检出

安装 Git、Python 3、Visual Studio 2022 的桌面 C++ 工作负载与 Windows SDK、CMake 3.27 或更新版本。
在 VS 2022 Developer PowerShell 中构建，确保 `git`、`python`、`cmake`、`ctest` 可用。
安装器测试使用 Windows 自带的 64 位 Windows PowerShell 5.1 和 .NET Framework 编译器。

```powershell
# 路径可替换为自己的开发目录；目标目录应尚不存在。
git clone --recurse-submodules https://github.com/scholay/rimes.git D:\Dev\rimes
if ($LASTEXITCODE) { throw 'Clone failed' }
Set-Location D:\Dev\rimes
git switch main
if ($LASTEXITCODE) { throw 'Cannot select main' }
git submodule update --init OfficialPlugins
if ($LASTEXITCODE) { throw 'Plugin checkout failed' }
python scripts/prepare-official-plugins.py
if ($LASTEXITCODE) { throw 'Plugin preparation failed' }
git status --short --branch
```

官方插件由 `OfficialPlugins` 和 `plugins.lock.json` 固定版本。需要修改插件时按 [维护说明](../../MAINTENANCE.md#官方插件依赖) 单独提交，不直接追逐插件仓库的最新提交。

接着做 #93 时，建议保留主线检出，另开工作区：

```powershell
git fetch origin
if ($LASTEXITCODE) { throw 'Fetch failed' }
git worktree add -b codex/windows-standard-user-install ..\rimes-install93 origin/codex/windows-standard-user-install
if ($LASTEXITCODE) { throw 'Worktree creation failed; inspect existing branches before retrying' }
```

## 构建与回归

在仓库根目录运行；这两条命令只构建和测试，不注册或安装正在日用的输入法：

```powershell
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x64 -Configuration Release
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x86 -Configuration Release
```

生成目录分别为 `platforms/windows/native/out/build/windows-x64/Release` 和 `windows-x86/Release`。
继续按 [原生开发说明](native/README.md) 运行 librime 与 TSF 输入测试。两种架构都需要，x86 对应 32 位宿主。

安装器回归在管理员 **Windows PowerShell 5.1** 中运行，每次使用新测试目录：

```powershell
$testRoot = Join-Path $env:TEMP ('rimes-installer-' + [guid]::NewGuid().ToString('N'))
./platforms/windows/tests/Test-SetupPayload.ps1 -OutputDirectory (Join-Path $testRoot 'payload')
./platforms/windows/tests/Test-SetupResult.ps1 -OutputDirectory (Join-Path $testRoot 'result')
./platforms/windows/tests/Test-InstalledAppsLifecycle.ps1 -OutputDirectory (Join-Path $testRoot 'lifecycle')
```

生命周期回归使用隔离注册表键和假 TSF/Broker；它不能代替真实安装和宿主打字。
打包入口是 `scripts/New-RimesNativePackage.ps1`（本目录下）：需要同一提交的两架构产物、校验过的完整 shared-data、固定版本 `rime.dll` 和微软签名的 x64/x86 VC++ 运行库。详见 [安装器说明](installer/README.md)。不要把 CI 的单架构二进制压缩包当成最终 EXE。

## 接下来的验收顺序

1. #93：标准用户登录，运行完整 EXE，在 UAC 中使用另一管理员凭据；确认词库、启动项、开始菜单归属于原用户，管理员配置保持原样。覆盖全新安装、保留数据升级、修复重试、取消卸载和完整卸载后重装。
2. 普通输入：关闭 Buffer，在记事本、浏览器、Codex、QQ 的实际输入框验证中英文、数字选词、轻按 Shift、标点、删除、失焦、候选定位及 32 位宿主。自动化通过不能替代这些结果。
3. Buffer：默认 Ctrl+Shift+B 及已有快捷键配置，绑定宿主、输入、生成/翻译、取消、投递、打开设置、关闭后保留待发内容。
4. 从冻结提交构建完整 EXE，安装同一产物并记录 SHA-256、注销/重启是否完成，再更新公开 Release。对应 Issue 在证据满足后关闭。

已有 #93 证据见 [安装回归记录](../../validation/issue93-cross-account-install-20261007/report.md)，#107 边界见 [原生回归记录](native/validation/2026-10-07-round2.md)。

## 用户数据与其他平台

- Windows 词库在 `%APPDATA%\RIMES`；设置在 `%LOCALAPPDATA%\RIMES\settings.json`；API 密钥在 Windows 凭据管理器 `RIMES.Windows.OpenAI`。换电脑时私下备份数据并重新录入密钥，不通过 GitHub 传输凭据或个人词库。
- macOS 的 `~/Library/RIMES` 含平台专用设置和 Capsule 等资料，不能整目录覆盖 Windows。先独立备份，仅在确认格式兼容后迁移自定义方案/词库。
- Git 检出包含各平台源码与公开验证记录；本地商店提交材料、签名密钥和证书另行保管。iOS/macOS 原生构建与 Apple 签名仍需要 Mac/Xcode，Windows 上的源码同步不替代 Apple 构建环境。
