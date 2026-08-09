# 发布与自动更新

RIMES 通过 **GitHub Actions + GitHub Releases + 应用内自动更新** 分发。
终端用户优先使用 Release 里的 `.pkg` 安装器；产物是**自包含** app，librime 引擎与 Rime
词库都打包在 `ETInput.app` 内，无需单独安装 Squirrel。

> 仓库/内部代号是 RimeBuffer（SPM target、源码目录、控制器类）；`ETInput.app` / `MacOS/ETInput`
> 是冻结的升级兼容路径；对外产品名是 RIMES。三者刻意分离，品牌变化不迁移 TIS 身份。

## 一、发布新版本

```bash
./scripts/release.sh minor     # 0.1.0 -> 0.2.0，或 patch / major / 指定 x.y.z
```

脚本会：同步/提交改动 → 更新 `Info.plist` 版本号 → 打 `vX.Y.Z` tag → 推到 GitHub（`origin`）。

推送 tag 会触发 [`.github/workflows/release.yml`](.github/workflows/release.yml)：

1. `swift build -c release --arch arm64 --arch x86_64`（**通用二进制**，Intel/Apple Silicon 通用）
2. `scripts/fetch-rime.sh` 下载 librime 运行时（从 Squirrel 官方 pkg 提取，见下）
3. 组装 `ETInput.app`：二进制 → `MacOS/ETInput`，`Info.plist`，并把 librime + 插件 + Rime
   词库拷进 `Contents/Frameworks` 与 `Contents/SharedSupport`；`--deep` ad-hoc 签名
4. 同时产出 `RIMES-X.Y.Z.pkg`（新用户安装器）和兼容旧客户端的 `ETInput-X.Y.Z.zip`（应用内更新），创建
   GitHub Release，附带 SHA256

## 二、自包含 librime（[`scripts/fetch-rime.sh`](scripts/fetch-rime.sh)）

librime 是**静态链接**的（依赖只有系统 libSystem/libc++），所以自包含只需三样：
`librime.1.dylib` + 3 个插件 + `SharedSupport`（默认方案/词库）。fetch-rime 从 Squirrel
官方 `.pkg`（锁定 `SQUIRREL_VERSION`）提取这些到 `Vendor/rime/`。

- **`Vendor/` 是 gitignore 的**——二进制不进 git，构建时按锁定版本拉取，可复现。
- 运行时 `CRimeBridge` 优先 `dlopen` app bundle 内的 librime（找不到才回退系统 Squirrel），
  `shared_data_dir` 指向 bundle 的 `SharedSupport`；首启自动 `start_maintenance` 部署词库到
  `~/Library/RimeBuffer`。因此 CI 与终端用户机器都无需预装 Squirrel。

## 三、持续集成（CI）

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) 在每次 push / PR 到 `main` 时：
`swift build` + 运行 `schema-smoke`、`buffer-smoke`、`stats-smoke` 等纯 Swift 自检（不依赖 librime）。

## 四、新用户安装器（[`scripts/make-pkg.sh`](scripts/make-pkg.sh)）

`.pkg` 会把 `ETInput.app` 安装到 `/Library/Input Methods`，清理同 id 的旧用户级副本，并在当前
登录用户的 Aqua 会话中运行 `ETInput --install`：注册、启用、选择输入源，然后启动 ETInput。

输入法 bundle id 刻意保留 `com.isaac.inputmethod.RimeBuffer`，即使对外产品名已经是 RIMES；
可选择的输入模式使用独立 id `com.isaac.inputmethod.RimeBuffer.Hans`。父输入法与
子 mode 不能共用同一个 TIS id，否则父项无法启用、`TISSelectInputSource` 会返回 `paramErr`。
macOS 会把这些 id 写入受保护的 TIS 偏好，因此后续不要随意改动。

## 五、应用内自动更新（[`UpdateManager.swift`](Sources/RimeBuffer/UpdateManager.swift)）

已安装并运行的 RIMES：

- **启动时 + 每小时** 静默查询 `scholay/rimes` 的最新 Release；
- 版本更新（按 semver 逐段比较 `CFBundleShortVersionString`）时**后台静默下载** zip；
- 下载完成后，状态栏图标变色，菜单顶部出现「🎉 有新版本 vX — 立即更新」；
- 用户确认后：等待旧进程退出 → `pkill -x ETInput` 兜底 → 暂存新 bundle → 原子交换
  `~/Library/Input Methods/ETInput.app`（失败回滚）→ `xattr` 清除隔离 →
  **`lsregister -f` 重新注册** → `open` 重启。
- 也可从菜单「检查更新…」手动触发。

安装过程日志：`~/rimebuffer-update.log`。自动检查默认开启（`UserDefaults` 键
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

发布首个预览版：

```bash
git tag platform-preview-v0.1.0
git push origin platform-preview-v0.1.0
```

精确能力边界、被排除的数据和本地验证命令见
[CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)。
