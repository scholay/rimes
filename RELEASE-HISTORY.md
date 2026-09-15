# 发布历史记录

这里记录已经关闭的发布通道和一次性迁移，只供追溯，不是可再次执行的操作手册。当前流程见
[RELEASE.md](RELEASE.md)，逐版本变更见 [CHANGELOG.md](CHANGELOG.md)。

## 仓库与名称

- `v0.1.0` – `v0.4.1` 发布在旧仓库 `young-bo-i/rime-buffer`，之后迁到 `scholay/rimes`。旧仓库只保留历史
  版本，不再发布新版本。
- 仓库 / 内部代号仍是 RimeBuffer（SPM target、源码目录、控制器类）；安装产物是 `RIMES.app` /
  `MacOS/RIMES`，输入法 id 为 `com.scholay.inputmethod.isaac`；对外产品名是 RIMES。
- `v0.5.0-preview.1` 及更早版本安装的是 `ETInput.app`（`com.isaac.inputmethod.RimeBuffer`，v0.4.1 及更早为
  `com.isaac.inputmethod.ETInput`）。改名后的 pkg 安装时退役这些旧 bundle，应用首启把 `~/Library/RimeBuffer`
  一次性复制到 `~/Library/RIMES`（见 [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md#六安装器scriptsmake-pkgsh)）。
  这些版本的更新器要求包 id `com.isaac.inputmethod.RimeBuffer` 与 `./ETInput.app`，会拒绝改名后的 pkg；
  它们也从未进入自动更新通道（当时所有 Release 都是 Pre-release），因此用户需要手动安装一次新 pkg。

## 手动触发的未签名预览（`v0.5.0-preview.1`，已关闭）

`v0.5.0-preview.1` 由 `gh workflow run release.yml --ref main -f version=0.5.0-preview.1
-f publish_unsigned_preview=true` 发布：工作流在当前 `main` 上构建，再由发布 job 创建 tag 与 Pre-release。
这个入口不在 `release.sh` 里，版本号也与 `Info.plist`（当时仍是 `0.4.2`）脱节，因此被 tag 触发的
`./scripts/release.sh preview` 取代；`publish_unsigned_preview` 输入已从工作流移除。

## 一次性未签名预览通道（`v0.4.3`，已关闭）

`v0.4.3` 曾作为一次性 GitHub **Pre-release**，让明确接受风险的社区用户验证安装修复。
当时的发布契约：

1. 从已审核、已合并的 `main` commit 手动运行 `Release macOS`，版本固定为 `0.4.3`，并由
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
   首段必须写明“unsigned / not notarized / Apple 未验证”，并链接 `UNSIGNED-PREVIEW.md` 和
   [Apple 官方安全说明](https://support.apple.com/zh-cn/102445)。只允许从
   `https://github.com/scholay/rimes/releases/tag/v0.4.3` 下载，不授权任何镜像或二次打包。
6. 发布后把 tag、PKG、校验文件及 Release 正文中的摘要视为不可变。发现问题时撤下预览并发布新的
   更高版本号。
7. `v0.4.3` 不得进入 `/releases/latest`，不得提供或宣称应用内自动更新。

未来首个 Developer ID 签名并经 Apple 公证的正式版必须使用高于所有既有版本的新版本号，绝不能在
`v0.4.3` 上补签后覆盖原字节。

## 旧仓库客户端迁移

`v0.4.1` 及更早的已安装包把更新地址编译为 `young-bo-i/rime-buffer`，并消费
`ETInput-X.Y.Z.zip`。改名后的 release workflow 不再生成这份 ZIP，旧仓桥接因此不再可行：
这些用户需从 `scholay/rimes` 手动安装一次新 pkg，postinstall 会退役旧的 `ETInput.app`。
`young-bo-i/rime-buffer` 中的历史 Release 保持不变。
