# 主线与多平台维护

## 原则

- 一个仓库、一条应用集成主线 `main`；macOS、iOS、Android、Windows、Linux 不维持长期分叉的产品主线。
- 新工作从最新主线开短分支，一件事一个可审查提交/PR；合入后不再沿旧分支叠加功能。
- 每个平台独立构建、验收和发布。2026-10-04 的跨平台版本基线为 **1.1.0**，构建编号独立递增；Windows 可在同一 major.minor 基线内独立发布向前的补丁版本，其他平台版本保持各自已验收状态；Linux 保留现状。合入主线不等于可用或已发布。
- 本地维护可以领先 `origin/main`。未获授权时，不 push、不创建发布 tag、不触发远端 workflow，
  不安装输入法、不提交 App Store、不修改远端 PR 或保护规则。
- 获准同步远端时，从已验证的本地主线提交创建交付分支，经 PR 回到 `origin/main`；不 force-push
  或绕过保护。再按届时的远端主线和 CI 状态处理本地对齐，不直接重置包含未发布工作的分支。
- 用户词库、凭据、运行时数据不参与分支整理；保留原始提交与备份引用，不自动清理旧分支。

## 2026-10-05 主线归一化

- 将 iOS 本地 41–48 号构建改动、macOS Glass/权限/关于页及共享犀牛图标汇总到 `main`，保留原提交历史。
- Android、Windows 的旧开发分支内容已在主线历史中。历史备份引用仅用于追溯，不作为开发起点；继续开发须基于最新 `origin/main`。
- App Store 支持/隐私网页源码迁入 `docs/`。GitHub Pages 在合并后改为从 `main:/docs` 发布，原 `/rimes/ios/`、支持页与隐私页 URL 保持不变。旧站点分支保留到新部署验证通过。
- `rimes-plugins` 仍是独立仓库，以自己的 `main` 维护；本体继续使用已审查的子模块/锁文件提交，不自动追逐插件 HEAD。
- 本轮仅汇总源码和维护分支，不创建发布 tag。iOS 48 的首次闪动、宿主高度同步与实际宿主验收边界见 [验证记录](platforms/ios/validation/build48/README.md)。上线前从确切的主线提交构建并完成这些验收。

## 2026-10-07 移动端反馈整合

- 集成提交 `97e3c31` 保留 Android 社区反馈分支的原始提交，并纳入 iOS TestFlight 修复、共享中文标点行为和固定版本的输入方案目录工具。
- 官方插件固定到 `c276dce6cf19a62fa055affc8e274036d8ffcf1d`，包含 Android 并击工具键取消和受限高度适配；本体不自动跟随插件仓库 HEAD。
- 此次集成本机检查：Shared 82 项、Android JVM 70 项、方案工具 35 项均通过；iOS 模拟器 212 项中 1 项跳过、0 失败。Android Debug APK、两套 instrumentation APK 编译和 Lint 通过；iOS 静态检查、插件目录与日志隐私检查通过。
- Android 原生库和预编译词库复用已验收工作区产物，其全部 34 项输入摘要与集成源码相符，并重新通过资源完整性及双 ABI 16 KB 对齐检查。本次没有重新安装或验收集成后的手机包，既有设备记录仅代表各自记录的产物。
- Windows [PR #73](https://github.com/scholay/rimes/pull/73) 保持草稿，等待真实桌面验收；不把 CI 通过当成桌面验收完成。
- `platforms/ios/AppStore/submission-1.1.0/` 的本地提交材料保留在工作区，不纳入源码提交。此次分支维护不创建发布标签、不上传商店版本。

## 2026-10-07 后续反馈收敛

- Windows [PR #73](https://github.com/scholay/rimes/pull/73) 已在补齐桌面验收后合入；修复 Shift 字符、设置与托盘入口、系统卸载入口以及打开设置时保留 Buffer。验收覆盖及仍待验证的登录启动、长期日用范围见 [Windows 记录](platforms/windows/native/validation/2026-10-07-feedback.md)。
- Android 纳入截至 `68552cc` 的 code14 修复与验收记录，保留原提交；官方插件固定 `aecf9c1f505ac83934b01c28c59a29f99707d199`。集成时撤去旧的字母页语言归一化，确保中英上滑标点正确，并保留主线数字页首个句末标点自动返回行为。
- 集成本机 Android 70 项核心测试、Debug APK、app/testhost instrumentation 编译、两模块 Lint、原生资源完整性及双 ABI 16 KB 对齐检查通过。原 code14 真机/30 分钟记录对应其确切源提交；本次主线整合没有重装手机或发布安装包。
- 外部 [PR #77](https://github.com/scholay/rimes/pull/77) 暂留待审：丢失 state.json 时按目录名选择恢复版本，尚需验证与实际注册路径的一致性，以及同现有卸载入口和回滚逻辑的兼容性。

## 代码边界

2026-09-29 起按 [平台路线图](PLATFORM-ROADMAP.md) 开发：Windows 对标 macOS、Android 对标
iOS，Linux 收敛到现有功能维护。构建与实机验收分别记录。

| 范围 | 维护入口 | 验证责任 |
|---|---|---|
| macOS | `Sources/`、`Package.swift` | IMK 焦点/投递/保护态、原生 UI、升级安装 |
| iOS | `platforms/ios/` | App 与键盘扩展、Full Access、设备与 App Store |
| 共享 Swift 逻辑 | `Shared/` | 共享单测 + macOS/iOS 受影响路径 |
| Windows | `platforms/windows/native/` | TSF/Broker、x64/x86、真实 Windows 宿主 |
| Android | `platforms/android/` | App/IME、InputConnection、JVM 测试、APK 与真机 |
| Linux | `platforms/linux/` | Fcitx5、Buffer/Capsule、X11/Wayland 真实桌面 |
| 共享词库/配置 | `rime-data/`、`chord-keymaps/`、`Catalog/` | 目录生成检查、数据闭包及受影响平台 |
| 设计 | `DesignSystem/` | 单独提交；界面原型不冒充产品验收。宣传视频的工程、素材与成片不进本仓库 |

Windows/Linux 的 C++ 与 Android 的 Java 适配层不直接共享 Swift 实现；用行为规范、数据格式和测试样例对齐。
平台安全边界仍由各自宿主负责；macOS 的 `Delivery.insert`、用户词库隔离等约束不因整合改变。

## 官方插件依赖

官方实现逐步迁入 `scholay/rimes-plugins`。本体的 `OfficialPlugins` 子模块与 `plugins.lock.json` 固定同一个已审查提交；原生源码随本体编译和签名。下载包只提供宿主支持的声明、提示词和资源。

首次检出以及切换依赖提交后运行：

```bash
git submodule update --init OfficialPlugins
python3 scripts/prepare-official-plugins.py
```

生成文件不在本体重复维护。修改插件源码须在插件仓提交，再更新本体子模块及锁文件；导入器会拒绝覆盖本地改动。完整的迁移与验收顺序见 [1.1.0 发布计划](docs/releases/1.1.0-plan.md)。

## 版本与构建

| 平台/渠道 | 版本来源 | 构建/发布入口 | 当前边界 |
|---|---|---|---|
| macOS | `VERSION` 与 `Info.plist`；正式 tag 匹配，本地开发版附提交身份 | `CI` / `Release macOS`，`scripts/release.sh` | 正式包需签名、公证、同包真机验收与批准 |
| iOS | 公开版 `ios-vX.Y.Z`；本地默认 `project.yml`，CI 独立 build number | `iOS checks` / `ios-release.yml` | tag 必须位于 main 历史；上传、审核、上架分开记录 |
| Android | `platforms/android/VERSION` 与 Gradle versionCode | `Android checks` / `scripts/build-release.sh` | 正式 APK/AAB 需长期签名与独立验收 |
| Windows 原生 | `native/VERSION` 生成工程、PE 和运行时版本；Artifact 加架构和源码快照 | `Windows IME` / `Windows Native Foundation` 与 `New-RimesNativePackage.ps1` | Windows 11 x64；经独立验收和授权，手工发布未签名 EXE 到 `windows-v*` |
| Linux 原生 | `ime/VERSION` 的包版本及 CMake 项目版本；Artifact 加 commit SHA | `Linux IME` / `ime/scripts/package-deb.sh` | 实验性 Artifact / `.deb`，需真实桌面验证 |
| 旧 Windows/Linux 数据预览 | `platform-preview-vX.Y.Z` | `platform-preview-release.yml` | 词库与脚本数据包，不是原生 IME 产品版本 |

四个目标平台保留 1.1.0 基线，后续构建编号独立递增；Windows 1.1.1 是独立补丁发布。版本检查要求 Windows 的 major.minor 与基线一致、patch 不回退，并核验 CMake 消费其 VERSION。Linux 不跟随此次版本锚定。Windows 原生产品使用 `windows-v*`，从冻结源码构建、校验安装包后，经维护者授权手工创建 GitHub Release；该标签不会自动运行 macOS 发布流程。Linux 原生通道仍未接入公开发布，不复用 macOS 的 `v*` 或数据预览标签。

本地独立构建（在对应操作系统运行；均不是发布命令）：

```bash
# macOS：只编译，不调用 build_install.sh
swift build -c debug
swift test --package-path Shared

# iOS：在装有 Xcode 的 Mac 构建模拟器与未签名设备目标；不装真机、不上传
platforms/ios/scripts/build.sh

# Linux：只构建/测试；package-deb.sh 打包到 staging，不安装当前系统
platforms/linux/ime/scripts/build.sh
ctest --test-dir platforms/linux/ime/build --output-on-failure
platforms/linux/ime/scripts/package-deb.sh
```

```powershell
# Windows：构建并测试，不调用 Register-RimesWindows.ps1
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x64 -Configuration Release
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x86 -Configuration Release
```

Windows/Linux 的日志版本、CMake 项目版本、包版本升级时需一起核对；不以“CI Artifact 存在”
替代安装包、真实桌面或签名验证。Mac 上的静态检查也不算 Windows/Linux 原生构建成功。

## 本地整合记录：2026-09-29

- 原 iOS 分支提交 `9aea6f3` 和原有 `ios-v0.1.0` 标签保留，不移动旧 tag。
- 现有未提交应用工作拆成共享核心、macOS、iOS、设计系统、宣传源码五个本地 checkpoint。
- `codex/backup/pre-main-20260929` 保存整合前完整应用工作快照；旧 iOS 分支在本地归档为
  `codex/archive/ios-review-20260929`，仍指向原提交。远端旧分支不改动。
- 纳入远端主线 `e9098d7`、Windows IME `8653bef`、Linux Capsule `d0077fb`，保留原提交历史。
- 远端 PR #40 / #45 不因本地整合而改变状态；Windows 实机验收、Linux Capsule 最新双击修复
  的真实桌面复测仍需单独完成。
- `e9098d7` 的 Linux CI 曾在拖拽 800ms 尾窗测试失败；Capsule 分支已带入增加定时余量的测试
  调整。仅合入这项调整不证明 Linux CI 已恢复，仍需在 Linux 重新运行。
- 当时 `codex/ios-appstore-site` 是 GitHub Pages 的支持/隐私页部署源；2026-10-05 的迁移安排见上方主线归一化记录。
- 本地 `daipaibu-site/` 属于另一网站，保持原样、未纳入应用提交；宣传项目被忽略的依赖与输出也
  保持原样。不用 `git clean`、强制 checkout 或删除工作区来获得表面“干净”。

每次验收记录至少包含平台、完整 commit、构建配置、检查结果和未验证项。发布时只使用确切
提交的构建结果，不把旧设备安装、旧 CI 绿灯或历史审核状态沿用到新整合提交。

### 本次本地验证

在整合提交 `313d5d9` 的应用源码上验证（后续维护提交只调整文档、workflow 和其测试）：

- macOS Debug 编译通过；15 组隔离 smoke 通过，覆盖 Buffer、Capsule 结构/模块、Morse、学术
  插件、AI、翻译、插件配置与设置/菜单。不安装、不重启正在使用的输入法。
- 共享 Swift 核心 49 项测试通过；DesignSystem 49 项交互测试、4 项 Sites 测试、类型检查、
  四主题对比度检查和构建通过。
- iOS 通用设备目标在 `CODE_SIGNING_ALLOWED=NO` 下编译通过；资源/权限/隐私清单检查通过。
  没有运行本次 iOS 模拟器测试或真机验收，也没有生成商店签名 IPA。
- 发布工具 64 项测试、跨平台数据工具 25 项测试、iOS 发布配置 3 项测试通过；4 个变更的
  workflow 通过 YAML 语法检查，目录生成检查、日志隐私检查与 `git diff --check` 通过。
- 编译仍有现有 Swift 并发警告，iOS 旧 DerivedData 路径及第三方头文件有警告；本次不顺带
  改写这些运行时代码或删除旧缓存。smoke 中也有 AppKit 色彩空间警告，测试结果为通过。
- Windows/Linux 原生构建及真实桌面检查未在本次 Mac 环境重跑；未触发 GitHub CI。
