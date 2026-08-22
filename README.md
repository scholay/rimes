# RIMES

**[中文](README.md)** · **[English](README.en.md)**

从零做的现代 macOS 输入法：**librime** 引擎 + 自绘候选窗 + 常驻缓冲区（buffer）。内置雾凇全拼、自然码双拼、小鹤双拼、五笔 86 与英文核心方案；飞耀并击 / 互击由默认关闭的“并击”扩展提供。**自包含**打包 librime 与词库，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`）；`ETInput.app` 为兼容旧安装与自动更新保留的内部路径。对外产品名统一为 **RIMES**（rime-scholay）。

## 演示视频

- [哔哩哔哩 · 完整介绍](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [抖音 · 产品演示](https://www.douyin.com/video/7671078195197742355)

另有分集快剪：实时翻译、AI 生成、意识流等，见 B 站合集。

## 它解决什么问题

普通输入法打完就直接上屏；RIMES 在中间加了一层**上屏前的文本工作台**：

1. 中文 / 英文先进入缓冲
2. 可实时翻译，或使用选定的 AI 连接器生成和改写
3. 你确认后，才用纸飞机或 Return **显式投递**到当前输入框

结果不会自动发帖、不会静默改网页。适合写作、评论、双语与 AI 工作流。

## 主要能力

| 能力 | 说明 |
|---|---|
| 输入方案 | 雾凇全拼、自然码双拼、小鹤双拼、五笔 86、英文；可选并击扩展 |
| 缓冲工作台 | `⌘⇧B` 开关；先暂存、再分块投递 |
| 剪贴板历史 | `⌘⇧P` 显示 / 隐藏；仅在工作台可见且安全时读取 |
| 设置 | `⌘⇧S` 随时打开设置页面 |
| 实时翻译 | 默认 Apple 本地翻译（macOS 15+），也可走 AI 渠道 |
| AI 生成 | Codex CLI / Claude Code CLI / OpenAI 兼容 API |
| 意识流输入 | 拼音/并击 → 按配置给出最多 5 个互斥猜测 → 选定后投递 |
| 隔空传字 | Mac ↔ Mac 加密直连，无需同一 Wi‑Fi / Apple ID |

<!-- BEGIN PRESET BUFFER PLUGINS -->
## 预置缓冲插件

下表由 [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json) 自动生成。更新插件时必须同步更新其版本，并运行 `python3 scripts/sync-buffer-plugin-catalog.py --check`。

| 插件 | ID | 版本 | 默认安装 | 默认状态 |
|---|---|---:|---|---|
| AI 生成 | `builtin.ai-text` | 2.1 | 随 RIMES 预装 | 启用 |
| 实时翻译 | `builtin.apple-translation` | 2.1 | 随 RIMES 预装 | 启用 |
| 意识流输入 | `builtin.stream-input` | 1.3 | 随 RIMES 预装 | 启用 |

表中插件均随 RIMES 预装，并在全新安装后默认启用。
<!-- END PRESET BUFFER PLUGINS -->

## 内置扩展

| 扩展 | 稳定 ID | 版本 | 默认状态 |
|---|---|---:|---|
| 统计 | `builtin.statistics` | 1.0 | 启用 |
| 打字测速 | `builtin.typing-speed` | 1.0 | 启用 |
| 并击 | `builtin.fly-chord-learning` | 2.0 | 关闭 |

“并击”2.0 保留旧 ID 与学习进度，但现在统一拥有飞耀并击 / 互击输入、组键间隔、课程、练习与进度；关闭后普通输入不再进入飞耀方案，意识流输入自动回到逐字连续全拼。

## 安装

### 临时免费预览版（v0.4.3）

在取得 Apple Developer Program 资格前，社区可以从官方仓库的
[GitHub Pre-release v0.4.3](https://github.com/scholay/rimes/releases/tag/v0.4.3)
下载 `RIMES-0.4.3.pkg`。这个包**没有 Developer ID 签名、没有经过 Apple 公证，Apple
无法验证它**；它不是正式版。只从 `scholay/rimes` 下载，并在安装前把本机计算的 SHA-256
与该 Release 公布的值逐字核对。

先双击 `.pkg` 触发 macOS 的拦截，再到“系统设置 → 隐私与安全性”点“仍要打开”，确认后继续
Installer；输入源没有立即显示时请注销并重新登录。不要全局关闭 Gatekeeper，也不要用 `xattr`
移除隔离属性。若系统提示“已损坏”或“将损坏你的电脑”，立即停止，不要绕过。公司/学校管理的
Mac 可能由 MDM 禁止这个例外。完整步骤与风险边界见
[《v0.4.3 未签名预览版安装说明》](UNSIGNED-PREVIEW.md)，以及
[Apple 官方说明](https://support.apple.com/zh-cn/102445)。

v0.4.3 不进入应用内自动更新通道。将来发布 Developer ID 签名并经 Apple 公证的更高版本后，
预览版用户需要从官方 Release 手动下载安装一次。

### 正式版

取得 Developer ID 后，正式版仍只通过 [GitHub Releases](https://github.com/scholay/rimes/releases)
提供经 Developer ID 签名和 Apple 公证的 `RIMES-版本号.pkg`。安装器会把内部兼容路径
`ETInput.app` 固定放进 `/Library/Input Methods`，并在当前 GUI 用户会话中按 parent → child
的顺序注册、启用和尝试切换。若新版 macOS 的输入法菜单未立即刷新，安装本身仍会正常完成；
注销并重新登录后再在系统设置中确认「RIMES」即可。不要手动结束 `TextInputMenuAgent` 或
`imklaunchagent`。

开发者本机：

```bash
./build_install.sh                # 构建 + 安装到当前用户 + 注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
tail -f ~/rimebuffer.log          # 行为日志
```

更多 smoke 命令与发布流程见 [RELEASE.md](RELEASE.md)。

### Windows / Linux 输入方案预览

Windows 与 Linux 目前提供独立的 **Data / Input-Schemes Preview**。它复用 RIMES 的五套
核心 Rime 方案、词库、Lua，以及随包保留的可选并击方案数据，但需要用户先安装 Windows
[小狼毫 Weasel](https://github.com/rime/weasel)、Linux
[Fcitx5 Rime](https://github.com/fcitx/fcitx5-rime) 或
[IBus Rime](https://github.com/rime/ibus-rime)。

仓库内另有一套正在开发的 [Windows 原生基础层](platforms/windows/native/README.md)：
x64/Win32 TSF 注册、受限 Broker 协议、真实 `librime` 会话与提交上屏链路已经通过
Windows 11 实机验证。它目前仍是 commit-only 开发里程碑，尚无预编辑/候选窗、Broker
登录启动、签名安装包，以及 macOS 缓冲区和工作台能力，因此没有进入公开 Release。

公开的数据预览包不包含 macOS 版的缓冲工作台、AI/翻译/OCR、原生设置窗口，也不包含
上述实验性 Windows TSF 或 Linux Fcitx5/IBus 前端。跨批互击是当前 macOS 前端能力，不能
由数据包单独提供。请从 Releases 中标记为 **Pre-release** 的
`RIMES-Windows-Data-Preview-*` / `RIMES-Linux-Data-Preview-*` 资产安装；完整边界、
安全策略和验证方式见 [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 当前权威全局架构（接手开发请先读） |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 历史契约与踩坑 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | 插件声明式配置 |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | v0.4.3 未签名预览版的下载、校验与安全安装步骤 |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux 输入方案预览边界与验证 |
| [RELEASE.md](RELEASE.md) | CI、通用二进制、应用内更新 |

## 自动更新

已安装的正式签名版 RIMES 会检查 [`scholay/rimes`](https://github.com/scholay/rimes) 的
GitHub Release；未签名的 v0.4.3 预览版不会进入该通道。发布：

```bash
./scripts/release.sh patch         # macOS 正式版
./scripts/release.sh preview 0.2.0 # Windows/Linux 数据预览版
```

两类 Release 都发布在新仓库：macOS `vX.Y.Z` 通常是稳定版；`v0.4.3` 是一次性的未签名
Pre-release 例外，不进入自动更新。Windows/Linux `platform-preview-vX.Y.Z` 始终是
Pre-release。

## 友链

- [本项目已在L站发布开源推广](https://linux.do/u/leowangling/preferences/account)

## 贡献者

完整名单见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

**AI 编程助手**：Claude、Cursor、Codex、Grok 参与了设计、实现与审阅；合并与发布仍由人工负责。

## 已知问题

- **macOS 26 上，在微信窗口聚焦时切换输入法可能导致微信崩溃**（崩在 Apple `TextInputUIMacHelper`）。这是上游问题，同样影响原生 Rime/Squirrel（[rime/squirrel#951](https://github.com/rime/squirrel/issues/951)）。**规避**：先在别处切好输入法，再进入微信打字。

## 许可证与第三方

RIMES 自有代码采用 [MIT License](LICENSE)。随包 Rime 方案、词库和 Lua/OpenCC 数据
保留各自的 GPL/LGPL/CC 许可与署名；完整边界见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `rime-data/licenses/`。
