# 发布与自动更新

RIMES 通过 **GitHub Actions + GitHub Releases + 应用内自动更新** 分发。
终端用户优先使用 Release 里的 `.pkg` 安装器；产物是**自包含** app，librime 引擎与 Rime
词库都打包在 `ETInput.app` 内，无需单独安装 Squirrel。

预置缓冲插件名称、版本与默认安装策略统一维护在
`Catalog/buffer-plugins.json`。每次插件更新先运行
`python3 -B scripts/sync-buffer-plugin-catalog.py`，它会同步运行时 Swift catalog 与中英文
README 表；CI 和 `scripts/release.sh` 都会用 `--check` 阻止版本或文档漂移。当前维护的三个
Buffer 插件随已签名应用一起交付，不再生成或上传独立 manifest/插件资产。历史 Release 中的
旧插件资产按不可变发布政策保留，但不代表当前产品仍维护或安装它们。

唯一发布中心是 [`scholay/rimes`](https://github.com/scholay/rimes/releases)：

- `vX.Y.Z`：macOS 正式版，进入 `/releases/latest` 和应用内更新通道；
- `vX.Y.Z-preview.N`：macOS 未签名公开预览版，始终是 Pre-release，不进入 latest 或自动更新；
- `platform-preview-vX.Y.Z`：Windows/Linux 数据与输入方案预览版，始终标记为 Pre-release。

这些通道使用互不混淆的 tag 规则；正式版与跨平台预览由 tag 触发，macOS 未签名预览则由
当前 `main` 的显式手动工作流创建不可变 tag。旧仓库
`young-bo-i/rime-buffer` 只保留历史版本和一次性升级桥，不再发布新功能版本。

> 仓库/内部代号是 RimeBuffer（SPM target、源码目录、控制器类）；`ETInput.app` / `MacOS/ETInput`
> 是冻结的升级兼容路径；对外产品名是 RIMES。三者刻意分离，品牌变化不迁移 TIS 身份。

## 一、发布新版本

```bash
./scripts/release.sh --dry-run 0.5.0  # 当前功能线先做只读发布检查
./scripts/release.sh 0.5.0            # 门禁、凭据与真机验收齐备后才执行
./scripts/release.sh patch            # 已发布功能线的后续维护版；也支持 minor / major
gh workflow run release.yml --ref main -f version=0.5.0-preview.1 -f publish_unsigned_preview=true
```

脚本只允许 `origin` 的 fetch/push URL 同时指向 `scholay/rimes`。它会从远端正式 tag 与
`Info.plist` 的较新者计算版本基线，拒绝脏工作区、分叉的 `main`、已有/回退 tag 和错误仓库；
需要更新版本时只提交 `Info.plist`，最后原子推送 `main` 与 `vX.Y.Z`。它不会
`git add -A`，也不会删除或重建远端 tag。

推送 tag 会触发 [`.github/workflows/release.yml`](.github/workflows/release.yml)：

workflow 使用两台彼此隔离的 runner。第一台 `build_and_smoke` 不绑定受保护 Environment、也不
读取任何发布 Secret：它构建并实际执行 ad-hoc app 的 runtime smoke，再把 app、构建上下文和
校验和作为短期 handoff Artifact 传出。第二台全新的 `sign_and_publish` runner 才进入
受保护的 `macos-release` Environment；它先按严格成员/路径/权限/大小规则解包 app，并只做
结构、架构和 ad-hoc 签名等被动校验。只有正式 tag 通过这些校验后才导入签名与公证凭据，且
凭据所在 runner 不执行 handoff 中的 ETInput。

1. `swift build -c release --arch arm64 --arch x86_64`（**通用二进制**，Intel/Apple Silicon 通用）
2. `scripts/fetch-rime.sh` 下载 librime 运行时（从 Squirrel 官方 pkg 提取，见下）
3. 组装 `ETInput.app`：二进制 → `MacOS/ETInput`，`Info.plist`，并把 librime + 插件 + Rime
   词库拷进 `Contents/Frameworks` 与 `Contents/SharedSupport`；用 ad-hoc 签名执行 runtime smoke，
   再通过上述受校验的 handoff 交给 fresh signing runner
4. 被动校验通过后，用同一张 Developer ID Application 证书逐个重签所有 bundled Mach-O，
   再以 hardened runtime 签 app；凭据所在 runner 不执行该 app
5. 把 app 提交 Apple 公证、等待 `Accepted` 并 staple；随后才创建仅供
   v0.4.2 及更早客户端迁移的 `ETInput-X.Y.Z.zip`
6. 以 Developer ID Installer 签署 `RIMES-X.Y.Z.pkg`，再次提交公证并 staple
7. 对最终资产执行 `codesign`、`pkgutil`、`stapler` 与 `spctl` 校验，通过后才创建
   GitHub Release 并计算/发布 SHA256；发布前先销毁临时 keychain/P8，发布使用受控的
   `gh` CLI，所有外部 Actions 都固定到完整 commit SHA

也可在 GitHub Actions 手动运行 `Release macOS` 做发布前演练。普通手动运行只上传短期
Artifact，不创建 Release；显式勾选 `publish_unsigned_preview` 且版本严格使用
`X.Y.Z-preview.N` 时，才会从当前 `main` 创建同名 GitHub Pre-release。正式 Release 仍必须
来自严格的 `vX.Y.Z` tag，且签名或公证凭据缺失时 fail-closed，绝不回退为未签名产物。

### 受控未签名预览通道

未取得 Developer ID 时，可用 `vX.Y.Z-preview.N` 向明确接受风险的社区用户发布测试版本：

1. 只能手动从当前 `origin/main` 触发；workflow 会再次核对远端 SHA，并拒绝已经存在的 tag 或 Release。
2. 无 secrets 的构建机生成 ad-hoc app 与 unsigned PKG，执行 runtime smoke，并通过真实
   `sudo installer` 验证 PackageKit、固定路径、输入法 metadata、通用架构和安装回执。
3. 独立的无 secrets 发布机只做被动成员集、权限、版本、架构、签名状态与 SHA-256 复核，
   不执行 handoff 中的 ETInput。
4. Release 只包含 `RIMES-X.Y.Z-preview.N.pkg` 与 `SHA256SUMS`，必须标记为 Pre-release、
   `latest=false`，正文明确写明 unsigned / not notarized，并链接 `UNSIGNED-PREVIEW.md`。
5. 预览版不进入应用内更新；后续预览递增 `N`，正式版仍使用不带后缀的 `vX.Y.Z`，任何既有
   tag 和资产都不得删除、移动或覆盖。

### 已关闭的一次性未签名预览通道（历史：v0.4.3）

`v0.4.3` 曾作为一次性 GitHub **Pre-release**，让明确接受风险的社区用户验证安装修复。
该通道已经完成并永久关闭；以下内容仅记录当时的发布契约，不是可再次执行的操作手册：

1. 当时从已审核、已合并的 `main` commit 手动运行 `Release macOS`，版本固定为 `0.4.3`，并由
   workflow 确认事件 commit 等于当时的 `origin/main`。
2. 无 secrets 的临时构建机先生成 ad-hoc app 与 unsigned PKG，真实执行一次
   `sudo installer -pkg RIMES-0.4.3.pkg -target /`，并验证安装回执、固定路径、输入法 metadata、
   universal 架构和 ad-hoc 签名。任何安装失败（包括 Code 112）都必须中止发布。
3. 独立的无 secrets 发布机下载不可变 handoff，只做被动结构、签名状态、版本、成员集、大小和
   SHA-256 复核，不执行 ETInput。验证通过后由工作流创建 `v0.4.3` GitHub Pre-release；不得手工
   上传或替换资产。
4. 公开资产固定包含 `RIMES-0.4.3.pkg`、`SHA256SUMS` 以及当时同次构建的旧插件/manifest
   资产，不包含内部 `ETInput-handoff.zip`。这些历史资产不删除、不替换，也不会在新版本继续
   生成；`SHA256SUMS` 仍是该历史发布的字节基线。
5. GitHub Release 的版本固定为 `v0.4.3`，必须是 **Pre-release** 且不得设为 `latest`；标题和
   首段必须写明“unsigned / not notarized / Apple 未验证”，并链接
   [`UNSIGNED-PREVIEW.md`](UNSIGNED-PREVIEW.md) 和
   [Apple 官方安全说明](https://support.apple.com/zh-cn/102445)。只允许从
   `https://github.com/scholay/rimes/releases/tag/v0.4.3` 下载，不授权任何镜像或二次打包。
6. 发布后把 tag、PKG、校验文件及 Release 正文中的摘要视为不可变。不得删除后重传同名资产、
   移动/重建 tag，或把另一份字节覆盖成 `v0.4.3`。发现问题时撤下预览并发布新的更高版本号。
7. `v0.4.3` 不得进入 `/releases/latest`，不得提供或宣称应用内自动更新。用户安装未来正式版时
   必须手动下载新的 PKG。

未来首个 Developer ID 签名并经 Apple 公证的正式版必须使用**高于 `0.4.3` 的新版本号**
（当前功能线按 `v0.5.0` 演练），并完整经过原有 protected Environment、双证书签名、两次公证和
fail-closed 校验。绝不能在 `v0.4.3` 上补签后覆盖原字节。

> 当前 GitHub 仓库尚未配置 `macos-release` Environment、发布 Secrets 与 tag ruleset，开发机
> 也没有 Developer ID Application/Installer 身份。因此当前只能发布明确标注、不可自动更新的
> `v0.5.0-preview.N`；在这些门禁补齐前不得创建 `v0.5.0` 正式 tag 或把预览产物标记为正式 Release。

### 正式发布环境与 Secrets

先创建受保护的 GitHub Environment `macos-release`：开启 required reviewers，并把 deployment
branch/tag rule 限制到受保护的 `vX.Y.Z` tag；仓库 ruleset 同时禁止非发布维护者创建或移动
这类 tag。workflow 还会在导入凭据前要求 tag 精确指向当时的 `origin/main`，手动
`workflow_dispatch` 即使选择 tag 也只能生成未签名 Artifact，不能进入正式发布分支。

在该 Environment 的 secrets 中配置以下 8 项；P12 必须分别包含
有效的 Developer ID Application / Developer ID Installer 证书及其私钥：

| Secret | 内容 |
|---|---|
| `RIMES_DEVELOPER_ID_APPLICATION_P12_BASE64` | Application `.p12` 文件的单行 Base64 |
| `RIMES_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | 上述 P12 的导出密码 |
| `RIMES_DEVELOPER_ID_INSTALLER_P12_BASE64` | Installer `.p12` 文件的单行 Base64 |
| `RIMES_DEVELOPER_ID_INSTALLER_P12_PASSWORD` | 上述 P12 的导出密码 |
| `RIMES_DEVELOPER_TEAM_ID` | 两张证书所属的 10 位 Apple Team ID |
| `RIMES_NOTARY_KEY_P8_BASE64` | App Store Connect API 私钥 `.p8` 的单行 Base64 |
| `RIMES_NOTARY_KEY_ID` | App Store Connect API Key ID |
| `RIMES_NOTARY_ISSUER_ID` | App Store Connect Issuer ID（UUID） |

> 可用 `base64 -i certificate.p12 | tr -d '\n'` 生成适合粘贴的单行内容；P8 同理。
> 不要把证书、私钥或密码提交到仓库。

正式 workflow 只在上述 fresh signing runner 把两张证书导入一次性 keychain，只把证书
common name、Team ID 和临时路径传给后续步骤；P12 导入后立即删除，公证结束、Release 上传
前删除临时 keychain 与 P8；失败路径也会无条件清理。导入脚本还会
拒绝多张同类型 identity、Team ID 不一致或缺少任一凭据的配置。

## 二、自包含 librime（[`scripts/fetch-rime.sh`](scripts/fetch-rime.sh)）

librime 是**静态链接**的（依赖只有系统 libSystem/libc++），所以自包含只需三样：
`librime.1.dylib` + 3 个插件 + `SharedSupport`（默认方案/词库）。fetch-rime 从 Squirrel
官方 `.pkg` 提取这些到 `Vendor/rime/`。1.1.2 的 URL、字节长度、SHA-256、Developer ID
Installer 身份/Team、公证票据，以及四个 universal dylib 的独立 SHA-256 都固定在脚本中；
任何一项漂移都会在展开和 RIMES 重签之前 fail-closed。正式 workflow 总是 `--force` 下载，
不信任 runner 上已有的 `Vendor/` 缓存。升级 Squirrel 必须在 PR 中重新审计并更新 allowlist。

- **`Vendor/` 是 gitignore 的**——二进制不进 git，构建时按锁定版本拉取，可复现。
- 运行时 `CRimeBridge` 优先 `dlopen` app bundle 内的 librime（找不到才回退系统 Squirrel），
  `shared_data_dir` 指向 bundle 的 `SharedSupport`；首启自动 `start_maintenance` 部署词库到
  `~/Library/RimeBuffer`。因此 CI 与终端用户机器都无需预装 Squirrel。

## 三、持续集成（CI）

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在每次 push / PR 到 `main` 时：
`swift build` + 运行 `schema-smoke`、`buffer-smoke`、`stats-smoke` 等纯 Swift 自检（不依赖 librime）。

## 四、新用户安装器（[`scripts/make-pkg.sh`](scripts/make-pkg.sh)）

`.pkg` 会把 `ETInput.app` 固定安装到 `/Library/Input Methods`，且显式禁用 Installer
relocation。`BundleHasStrictIdentifier=false` 是刻意的一次性兼容策略：该固定路径还存在
v0.4.1 的 legacy id `com.isaac.inputmethod.ETInput`；preinstall 会先拒绝任何非
RIMES 占用者，再允许 legacy/current 两个 id 原地迁移。

替换 payload 前，preinstall 使用包内随新版本构建、签名的最小 universal TIS helper 切到
ASCII fallback，不再要求 v0.4.1 等旧 binary 理解新参数。所有可能碰到 DirectoryService、
网络 home、Aqua bootstrap 或 TIS 的命令都由独立进程组 watchdog 约束；TERM/KILL 会覆盖整棵
命令树，preinstall/postinstall 另有 30/240 秒总预算。payload 落盘后，postinstall 在当前
GUI 用户的 Aqua 会话中按独立子进程分阶段执行 `register → enable parent →
enable child → best-effort select`。注册/启用在 90 秒总预算内未收敛时，pkg 仍成功，
并为当前用户安排一个仅在下次 Aqua 登录执行的 one-shot repair LaunchAgent；
成功后 marker 与 LaunchAgent 会自删除。无 GUI 用户的安装只安装 payload，下次登录
后由用户在系统设置中激活。任何路径都不结束 `imklaunchagent`/`TextInputMenuAgent`。

输入法 bundle id 刻意保留 `com.isaac.inputmethod.RimeBuffer`，即使对外产品名已经是 RIMES；
可选择的输入模式使用独立 id `com.isaac.inputmethod.RimeBuffer.Hans`。父输入法与
子 mode 不能共用同一个 TIS id，否则父项无法启用、`TISSelectInputSource` 会返回 `paramErr`。
macOS 会把这些 id 写入受保护的 TIS 偏好，因此后续不要随意改动。

## 五、应用内自动更新（[`UpdateManager.swift`](Sources/RimeBuffer/UpdateManager.swift)）

从本次修复版本开始，已安装并运行的正式签名 RIMES：

- **启动时 + 每小时** 静默查询 `scholay/rimes` 的最新 Release；
- 只接受严格 `vX.Y.Z` 下唯一的 `RIMES-X.Y.Z.pkg`，并在后台下载；
- 下载完成后，输入法菜单中的更新项变为「安装 RIMES vX…」；
- 下载后和用户确认后各验证一次：GitHub HTTPS/精确资产路径、普通文件/大小上限、
  `pkgutil --check-signature`、`spctl --assess --type install`，以及 Installer 证书与当前 app
  的 10 位 Team ID 一致；每个系统校验工具都有硬超时，且包内 product/component identifier
  与版本必须精确等于 Release 的 `X.Y.Z`，不能把历史同-Team pkg 改名重放；
- 用户确认后只把已验证 `.pkg` 交给 macOS Installer。应用自身不修改
  `/Library/Input Methods`，不解压任意 app，不清 quarantine，也不结束进程；
- 也可从菜单「检查更新…」手动触发。

旧的 `ETInput-X.Y.Z.zip` 只为已经发布、无法追溯修改的旧客户端保留迁移兼容；
新更新器不再消费 ZIP。自动检查默认开启（`UserDefaults` 键
`updateAutoCheckEnabled`）。

## 版本号约定

- `Info.plist` 的 `CFBundleShortVersionString` 用 `x.y.z`；tag 为 `vX.Y.Z`。
- CI 会用 tag 覆盖 plist 版本，用 `github.run_number` 作为 `CFBundleVersion`。
- 只有 tag 版本 **严格大于** 当前运行版本时，客户端才会提示更新。

## 六、Windows / Linux 输入方案预览

跨平台 Data / Input-Schemes Preview 使用独立的 `platform-preview-vX.Y.Z` 标签和
`.github/workflows/platform-preview-release.yml`。日常数据验证另由只读的
`.github/workflows/platform-preview.yml` 负责。该标签不会匹配 macOS 正式发布所用的 `v*`
规则；生成的 GitHub Release 必须标记为 **Pre-release**，因此也不会进入 macOS 客户端
查询的 `/releases/latest` 自动更新通道。

预览工作流在 Windows、Linux 与 macOS runner 上共同校验审核过的 Rime 数据闭包，并在
原生 Windows/Linux runner 上执行安装、校验、卸载文件事务。发布资产只是面向
Weasel、Fcitx5 Rime 与 IBus Rime 的数据/脚本包，不得描述为完整原生 RIMES 应用。

发布预览版：

```bash
./scripts/release.sh preview 0.2.0
```

精确能力边界、被排除的数据和本地验证命令见
[CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)。

## 七、旧仓库客户端迁移

`v0.4.1` 及更早的已安装包把更新地址编译为 `young-bo-i/rime-buffer`，因此仅在新仓创建
Release 无法主动触达这些客户端。迁仓版本需按下面顺序做一次桥接：

1. 先在 `scholay/rimes` 完成正式 Release，并验证其中精确存在 `ETInput-X.Y.Z.zip`；
2. 下载该 ZIP 并核对 SHA256；
3. 由旧仓库写权限持有者创建同版本 `vX.Y.Z` Release，只镜像这一份 ZIP，并在说明中指向
   新仓库源码与正式下载页；
4. 从旧版本升级后，新 bundle 内的更新地址已经是 `scholay/rimes`，后续版本只需发布到新仓。

桥接资产必须与新仓字节完全一致，不能在旧仓重新构建。没有旧仓写权限时，主发布可以继续，
但无法让旧安装自动发现迁仓版本，只能请用户从新仓手动安装一次。
