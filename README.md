# RIMES

**[中文](README.md)** · **[English](README.en.md)**

从零做的现代 macOS 输入法：**librime** 引擎 + 自绘候选窗 + 常驻缓冲区（buffer）。内置雾凇全拼、自然码双拼、小鹤双拼、五笔 86 与英文核心方案；默认关闭的“并击”扩展提供飞耀预设和自定义键位，统一支持同拍组合与左右分开击键。**自包含**打包 librime 与词库，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`）；安装后的应用是 `RIMES.app`（输入法 id `com.scholay.inputmethod.isaac`，数据目录 `~/Library/RIMES`）；早期版本留下的 `ETInput.app` 会在安装新 pkg 时自动移除，设置与词库一次性复制到新目录。对外产品名统一为 **RIMES**（rime-scholay）。

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

安装完成并进入图形登录会话后，一次性后台任务会用 `open -g` 启动同一个 RIMES 进程，因此 Buffer、Clipboard History、Mailbox 与 Capsule 的全局快捷键可跨输入法使用。开发安装原子发布当前用户任务；发布包在替换系统 payload 前会审计全部本机普通账户，除可由 postinstall 退休的当前 GUI 用户开发版外，发现同 ID 开发版 App/任务或无法安全核验的 home 就直接失败。postinstall 退休开发版、再次审计后，才以可回滚事务更新系统任务；登录 guard 对后来出现的开发版痕迹只作防御性短路。两种任务都不设 `KeepAlive`，也不会启动第二个 UI/IME 服务。Mailbox 与 Capsule 是正常取得键盘焦点的管理窗口；这些周边功能在其他输入法下不会访问 IMK 客户端、主动切换输入源、注入粘贴或其他按键、调用 Accessibility/Post Event，也不会读取、提交或取消外部输入法的组字。设置窗口仍只在当前输入源为 RIMES 时打开，其中 Mailbox 与 Capsule 页面只展示配置和状态，实际会话与内容管理留在各自独立窗口。

| 能力 | 说明 |
|---|---|
| 输入方案 | 雾凇全拼、自然码双拼、小鹤双拼、五笔 86、英文；可选并击扩展 |
| 缓冲工作台 | `⌘⇧B` 开关；RIMES 输入源下可捕获并分块投递，其他输入源下只允许显式从系统剪贴板导入或把结果复制到剪贴板，不访问 IMK 投递通道 |
| Capsule 底栏 | 原 Clipboard History，与 Buffer 同级；`⌘⇧V` 跨输入法打开屏幕底部独立窗口。头部标签在「最近」（剪贴板历史）与只读的笔记、图片、PDF、技能、密码之间切换，`⌘S` 把「最近」中所选卡片收入 Capsule，齿轮与卡片悬停画笔打开 Capsule 管理。收录开启且无安全保护时在后台保存文本、链接、图片、文件与颜色，原始表示只落本机私有数据库。单击只选择，双击、Return 或 `⌘1`–`⌘9` 激活；使用其他输入法时，所有类型都只无损恢复到系统剪贴板、提升到历史首位并静默关闭，由用户自行按 `⌘V`。RIMES 不会自动 Paste、右键或发送 `⌘V`，也不请求 Accessibility/Post Event；`⌘C` 仍只复制所选内容 |
| Mailbox | 与 Buffer 同级；`⌘⇧M` 跨输入法打开/关闭正常 key window，独立保存 AI 会话、备注与待审核外部推送。窗口内可“新建对话”并选择已配置的连接器/模型；CLI 只使用各自默认模型，OpenAI 使用本机配置模型，选择只绑定新会话且不改全局设置。草稿不创建空会话，首次 Return 才创建会话并发起生成 |
| Capsule 管理 | 从底栏齿轮或卡片画笔打开，外观是底栏向上长高，齿轮或 Esc 返回底栏；逐条维护五类内容并预览、复制图片/PDF/文件。查看 Password 明文前须按顺序完成四组原生物理键并击；默认 `RH / WO / CVN / QU`，四个槽位显示进度，成功后最多展示 15 秒。更换或恢复口令都先验证当前口令；自定义原码不落盘、不进 iCloud，只保存单个本机加盐摘要凭据。可选择 iCloud Drive 文件夹自动双向同步六类普通条目与媒体资产，Password、Skill 路径、查看口令及主密钥保持本机 |
| 设置 | `⌘⇧S` 仅在当前输入源属于 RIMES 时打开；Mailbox/Capsule 页面只提供快捷键、本机状态、同步与安全配置，不嵌入实际操作窗口 |
| 实时翻译 | 默认 Apple 本地翻译（macOS 15+），也可走 AI 渠道 |
| AI 生成 | Codex CLI / Claude Code CLI / OpenAI 兼容 API；结果只留在 Buffer 内，可选 Plain / Markdown / JSON，再由用户上屏 |
| 意识流输入 | 拼音/并击 → 本地 Rime + Octagram 低延迟解码，复杂输入回退 AI → 最多 5 个互斥猜测 → 选定后投递 |

<!-- BEGIN PRESET BUFFER PLUGINS -->
## 预置缓冲插件

下表由 [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json) 自动生成。更新插件时必须同步更新其版本，并运行 `python3 scripts/sync-buffer-plugin-catalog.py --check`。

| 插件 | ID | 版本 | 默认安装 | 默认状态 |
|---|---|---:|---|---|
| AI 生成 | `builtin.ai-text` | 2.1 | 随 RIMES 预装 | 启用 |
| 实时翻译 | `builtin.apple-translation` | 2.1 | 随 RIMES 预装 | 启用 |
| 意识流输入 | `builtin.stream-input` | 1.4 | 随 RIMES 预装 | 启用 |
| 电音演奏 | `builtin.music` | 0.2.3 | 随 RIMES 预装 | 启用 |

表中插件均随 RIMES 预装，并在全新安装后默认启用。
<!-- END PRESET BUFFER PLUGINS -->

## 内置扩展

| 扩展 | 稳定 ID | 版本 | 默认状态 |
|---|---|---:|---|
| 统计 | `builtin.statistics` | 2.0 | 启用 |
| 打字测速 | `builtin.typing-speed` | 2.0 | 启用 |
| 并击 | `builtin.fly-chord-learning` | 2.0 | 关闭 |

“并击”保留旧 ID 与学习进度，只提供一种支持同拍组合及左右分开击键的输入行为，不再区分模式。扩展管理键位方案、组键间隔、课程、练习与进度，飞耀是可复制修改的内置预设；关闭后普通输入退回普通方案，意识流输入自动回到逐字连续全拼。自定义方案可把输出编码设为自然码双拼：映射表仍按全拼填写，应用时每个完整音节编成两个键，音节边界由位置决定，不再依赖隔音符；输入区照常显示全拼。另内置麓鸣「呦呦音形」的折梅、寒梅两种原生并击方案，按键全部松开时由 Rime 结算。详见[键位方案与迁移说明](CHORD-KEYMAPS.md)。

## 安装

### 未签名公开预览版（`vX.Y.Z-preview.N`）

在取得 Apple Developer Program 资格前，社区可以从官方仓库
[GitHub Releases](https://github.com/scholay/rimes/releases) 中最新的 **Pre-release**
下载 `RIMES-X.Y.Z-preview.N.pkg`。这个包**没有 Developer ID 签名、没有经过 Apple 公证，Apple
无法验证它**；它不是正式版。只从 `scholay/rimes` 下载，并在安装前把本机计算的 SHA-256
与该 Release 公布的值逐字核对。

先双击 `.pkg` 触发 macOS 的拦截，再到“系统设置 → 隐私与安全性”点“仍要打开”，确认后继续
Installer；输入源没有立即显示时请注销并重新登录。不要全局关闭 Gatekeeper，也不要用 `xattr`
移除隔离属性。若系统提示“已损坏”或“将损坏你的电脑”，立即停止，不要绕过。公司/学校管理的
Mac 可能由 MDM 禁止这个例外。完整步骤与风险边界见
[《未签名预览版安装说明》](UNSIGNED-PREVIEW.md)，以及
[Apple 官方说明](https://support.apple.com/zh-cn/102445)。

预览版不进入应用内自动更新通道：新预览版需要手动下载安装，每个 Release 页面都列出了变更。
将来发布 Developer ID 签名并经 Apple 公证的正式版后，预览版用户需要从官方 Release 手动安装一次。

### 正式版

取得 Developer ID 后，正式版仍只通过 [GitHub Releases](https://github.com/scholay/rimes/releases)
提供经 Developer ID 签名和 Apple 公证的 `RIMES-版本号.pkg`。安装器会把
`RIMES.app` 固定放进 `/Library/Input Methods`（同时移除早期版本的 `ETInput.app`），并在当前 GUI 用户会话中按 parent → child
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
上述实验性 Windows TSF 或 Linux Fcitx5/IBus 前端。并击中的跨批分离击键配对是当前 macOS 前端能力，不能
由数据包单独提供。请从 Releases 中标记为 **Pre-release** 的
`RIMES-Windows-Data-Preview-*` / `RIMES-Linux-Data-Preview-*` 资产安装；完整边界、
安全策略和验证方式见 [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 当前权威全局架构（接手开发请先读） |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 历史契约与踩坑 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | 插件声明式配置 |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | 未签名预览版的下载、校验与安全安装步骤 |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux 输入方案预览边界与验证 |
| [RELEASE.md](RELEASE.md) | 发布流程：渠道、一条命令发布、节奏与版本号规则 |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | 发布技术参考：签名、安装器、应用内更新、CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | 已关闭的发布通道、旧仓库迁移与改名记录 |
| [CHANGELOG.md](CHANGELOG.md) | 由 tag 与提交信息生成的逐版本变更 |

## 自动更新

已安装的正式签名版 RIMES 会检查 [`scholay/rimes`](https://github.com/scholay/rimes) 的
GitHub Release；未签名的 `vX.Y.Z-preview.N` 不会进入该通道。

发布只有一个入口，版本号只来自 tag（流程见 [RELEASE.md](RELEASE.md)，变更见 [CHANGELOG.md](CHANGELOG.md)）：

```bash
./scripts/release.sh --dry-run preview  # 预览计划、CI 门禁与发布说明
./scripts/release.sh preview            # macOS 未签名预览版 vX.Y.Z-preview.N
./scripts/release.sh stable             # 预览线转正为 vX.Y.Z（需 Developer ID）
./scripts/release.sh platform minor     # Windows/Linux 数据预览版
```

所有 Release 都发布在 `scholay/rimes`：macOS `vX.Y.Z` 是正式版；`vX.Y.Z-preview.N` 是未签名
Pre-release，不进入自动更新。Windows/Linux `platform-preview-vX.Y.Z` 始终是 Pre-release。

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
