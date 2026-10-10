# RIMES

[![中文](.github/readme/labels/zh.svg)](README.md) [![English](.github/readme/labels/en.svg)](README.en.md) [![日本語](.github/readme/labels/ja.svg)](README.ja.md) [![한국어](.github/readme/labels/ko.svg)](README.ko.md) [![Español](.github/readme/labels/es.svg)](README.es.md)

致敬伟大的开源精神，本项目中文编码逻辑基于 [RIME 输入法引擎](https://rime.im/)。
这是一个支持多操作系统的输入法项目，用三个首创的插槽式平台来承接用户的个性化需求: 1. 输入法显式缓冲区（buffer） 2. 管理剪切板历史、截屏、个人知识库的记忆胶囊(capsule) 3. 接收外部信息的对话窗口(mailbox)。

支持全拼、双拼、声笔、五笔、英文方案；支持速录行业的并击式键入方案、支持自定义导入。面向新手用户，本项目安装包**自包含** librime 与词库，开箱即用。

> **RIMES** 是本项目的架构名称。对外产品名为 **灵犀输入法**（简体中文）、**靈犀輸入法**（繁体中文）和 **Lingxi IME**（英文）；iOS App Store 已采用这些产品名。

## 联系与交流

邮箱：[pm@scholay.com](mailto:pm@scholay.com) · 微信 ID：`scholar_hi` · QQ 群：`567629445`，诚邀进群交流。

~~前 1000 位为本项目点亮 Star 的用户，可免费预约永久云同步会员。~~

**前 5000 位为本项目点亮 Star 的用户，可免费预约半年会员。** 欢迎添加微信或加入 QQ 群预约。

## 演示视频

- [哔哩哔哩 · 完整介绍](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [抖音 · 产品演示](https://www.douyin.com/video/7671078195197742355)

## 它解决什么问题

让你通过一个输入法，实现智能时代的翻译、生成、润色等日常需求，且无需离开当前操作的应用程序，全程由输入法及插件来解决:

- **Buffer**（`⌘⇧B`）：上屏前的文本工作台。中文 / 英文先进入缓冲，可实时翻译，或使用选定的 AI 连接器生成和改写；你确认后， **显式投递**到当前输入框。
- **Capsule**（`⌘⇧V`）：屏幕底部的底栏。刚复制的文本、链接、图片、文件和颜色先出现在「最近」；要长期留下的，收进笔记、图片、PDF、技能或密码。
- **Mailbox**（`⌘⇧M`）：AI 会话、备注和待审核的外部推送都留在这个窗口里。可以新建对话并选择已配置的连接器。

## 主要能力须知

> 安装完成并进入图形登录会话后，一次性后台任务会用 `open -g` 启动同一个 RIMES 进程，因此 Buffer、Clipboard History、Mailbox 与 Capsule 的全局快捷键可跨输入法使用。
>
> 发布包在替换系统 payload 前会审计全部本机普通账户，除可由 postinstall 退休的当前 GUI 用户开发版外，发现同 ID 开发版 App/任务或无法安全核验的 home 就直接失败。postinstall 退休开发版、再次审计后，才以可回滚事务更新系统任务；登录 guard 对后来出现的开发版痕迹只作防御性短路。两种任务都不设 `KeepAlive`，也不会启动第二个 UI/IME 服务。
>
> Mailbox 与 Capsule 是正常取得键盘焦点的管理窗口。在其他输入法下用快捷键（或 Mailbox 通知）唤出时，RIMES 会先把自己切换为当前输入法再打开它，保证功能完整；关闭时不会切回，你之后自行切到其他输入法也不会被撤销，此时按下文描述降级。
>
> 这些功能不会访问其他输入法的 IMK 客户端，也不会读取、提交或取消外部输入法的组字。唯一的按键注入是 Capsule 激活时可选的一次 `⌘V`（见下方 Capsule 底栏）。设置的快捷键同样跨输入法可用，其中 Mailbox 与 Capsule 页面只展示配置和状态，实际会话与内容管理留在各自独立窗口。

| 能力 | 快捷键 | 内容 | 操作 | 存放 | 边界 |
|---|---|---|---|---|---|
| 输入方案 | — | 雾凇全拼、自然码、小鹤、五笔 86、英文 | — | — | — |
| 缓冲工作台 | `⌘⇧B` | 上屏前的文本 | 先切到 RIMES，再捕获、分块投递 | — | 切走后只走系统剪贴板，不走 IMK |
| Capsule 底栏 | `⌘⇧V` | 最近复制；笔记、图片、PDF、技能、密码 | 单击选择，双击或 Return 粘贴。`⌘S` 收录 | 只在本机 | 粘贴需辅助功能；未授权则只进剪贴板 |
| Mailbox | `⌘⇧M` | AI 会话、备注、待审核推送 | 新建对话；首次 Return 才生成 | 模型只绑定该会话 | CLI 用默认模型 |
| Capsule 管理 | 齿轮或画笔 | 五类条目，可预览和复制 | 四组并击后查看密码，最多 15 秒 | 可选 iCloud；密码与密钥留本机 | 口令只存本机摘要 |
| 设置 | `⌘⇧S` | 快捷键、状态、同步与安全 | 仅 RIMES 为当前输入法时打开 | — | 不嵌入 Mailbox / Capsule 窗口 |

实时翻译、AI 生成、意识流输入是缓冲插件，并击是内置扩展。版本与 ID 见下方清单。

| 名称 | 种类 | 说明 | 默认 |
|---|---|---|---|
| 实时翻译 | 缓冲插件 | Apple 本地翻译，也可走 AI | 启用，macOS 15+ |
| AI 生成 | 缓冲插件 | Codex、Claude Code 或 OpenAI 兼容 API。Plain / Markdown / JSON，结果留在 Buffer，由你上屏 | 启用 |
| 意识流输入 | 缓冲插件 | 拼音或并击交给所选 AI，最多 5 个互斥猜测 | 启用，选定后才投递 |
| 并击 | 内置扩展 | 同拍组合与左右分开击键，也可自定义键位 | 关闭 |

<!-- BEGIN PRESET BUFFER PLUGINS -->
## macOS 官方插件

下表由 [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json) 自动生成。更新插件时必须同步更新其版本，并运行 `python3 scripts/sync-buffer-plugin-catalog.py --check`。

| 插件 | ID | 版本 | 默认安装 | 默认状态 |
|---|---|---:|---|---|
| 实时翻译 | `builtin.apple-translation` | 2.2.0 | 随 RIMES 预装 | 启用 |
| 捕获 | `builtin.capsule.capture` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 笔记 | `builtin.capsule.notes` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 密码 | `builtin.capsule.passwords` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 资源 | `builtin.capsule.resources` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 临时 | `builtin.capsule.temporary` | 1.1.0 | 随 RIMES 预装 | 启用 |
| Claude | `builtin.claude-code-cli` | 1.1.0 | 设置中按需下载 | 禁用 |
| ChatGPT | `builtin.codex-cli` | 1.1.1 | 设置中按需下载 | 禁用 |
| 并击 | `builtin.fly-chord-learning` | 2.0.0 | 随 RIMES 预装 | 禁用 |
| LaTeX | `builtin.latex` | 1.1.0 | 设置中按需下载 | 禁用 |
| 对话 | `builtin.mailbox.chat` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 收件 | `builtin.mailbox.inbox` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 终端 | `builtin.mailbox.terminal` | 1.1.0 | 随 RIMES 预装 | 启用 |
| 摩斯电码 | `builtin.morse` | 0.1.0 | 设置中按需下载 | 禁用 |
| 电音演奏 | `builtin.music` | 0.2.3 | 设置中按需下载 | 禁用 |
| AI API | `builtin.openai-compatible` | 1.0.0 | 设置中按需下载 | 禁用 |
| Polisher | `builtin.polisher` | 1.1.0 | 设置中按需下载 | 禁用 |
| Reference | `builtin.scholay` | 0.1.0 | 设置中按需下载 | 禁用 |
| 统计 | `builtin.statistics` | 2.0.0 | 随 RIMES 预装 | 启用 |
| 意识流输入 | `builtin.stream-input` | 1.4.0 | 随 RIMES 预装 | 启用 |
| 打字测速 | `builtin.typing-speed` | 2.0.0 | 随 RIMES 预装 | 启用 |

预装插件在全新安装后按默认状态启用；选装插件下载后需手动启用。升级时保留已有插件状态。
<!-- END PRESET BUFFER PLUGINS -->

## 内置扩展

| 扩展 | 稳定 ID | 版本 | 默认状态 |
|---|---|---:|---|
| 统计 | `builtin.statistics` | 2.0 | 启用 |
| 打字测速 | `builtin.typing-speed` | 2.0 | 启用 |
| 并击 | `builtin.fly-chord-learning` | 2.0 | 关闭 |

## 安装

当前公开版本：[macOS 1.1.1](https://github.com/scholay/rimes/releases/tag/v1.1.1)、[Android 1.1.1](https://github.com/scholay/rimes/releases/tag/android-v1.1.1)、[Windows 1.1.1](https://github.com/scholay/rimes/releases/tag/windows-v1.1.1)、[iOS App Store 1.1.0](https://apps.apple.com/us/app/lingxi-ime/id6814620242)。macOS 包已签名和公证，Android 使用长期签名，Windows EXE 未签名。iOS 也提供 [TestFlight 公开邀请](https://testflight.apple.com/join/Kdj9RB4q)，可安装构建以 TestFlight 为准。Linux 目前公开提供方案数据预览包。最新源码与公开安装包的差异见[全平台包审计](validation/release-refresh-20261007.md)，各平台可用版本以发布页或商店为准。

macOS 27 有用户报告：安装后在 App Store 沙盒版微信、QQ 中切换到 RIMES，宿主应用可能闪退。若遇到这一情况，先切回其他输入法，参考[按应用备份输入源缓存的恢复指引](docs/macos/input-source-cache-recovery.md)。安装器不会清理其他应用的缓存；重启应用或退出登录并不保证解决此问题。调查进度见 [#90](https://github.com/scholay/rimes/issues/90)。

也可以拉取源码和固定版本的官方插件，在本机构建：

```bash
git clone --recurse-submodules https://github.com/scholay/rimes.git
cd rimes
```

| 平台 | 进度 | 构建 |
|---|---|---|
| macOS | 输入法，以及 Buffer、Capsule、Mailbox | `./build_install.sh` |
| iOS | 键盘与主 App（iOS 17+）：离线拼音、自然码、五笔、英文，以及 Buffer | 用 Xcode 打开 [`platforms/ios/RIMES.xcodeproj`](platforms/ios/README.md) |
| Windows | 原生 TSF 输入法、Buffer、并击及官方插件设置；支持 x64 / x86 | 见 [`platforms/windows/native/README.md`](platforms/windows/native/README.md) |
| Android | 原生输入法（InputConnection）、Buffer、六个官方插件和可配置 AI 服务 | 见 [`platforms/android/README.md`](platforms/android/README.md) |
| Linux | Fcitx5 输入法、Buffer、Capsule。还没有 Mailbox | 见 [`platforms/linux/ime/README.md`](platforms/linux/ime/README.md) |

## 文档

| 文档 | 内容 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 当前权威全局架构（接手开发请先读） |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 历史契约与踩坑 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | 插件声明式配置 |
| [UNSIGNED-PREVIEW.md](UNSIGNED-PREVIEW.md) | 未签名预览版的下载、校验与安全安装步骤 |
| [CROSS-PLATFORM-PREVIEW.md](CROSS-PLATFORM-PREVIEW.md) | Windows / Linux 输入方案预览边界与验证 |
| [platforms/ios/README.md](platforms/ios/README.md) | iOS 键盘与主 App |
| [platforms/windows/native/README.md](platforms/windows/native/README.md) | Windows 原生 TSF 输入法 |
| [platforms/linux/ime/README.md](platforms/linux/ime/README.md) | Linux Fcitx5 输入法、Buffer 与 Capsule |
| [PLATFORM-ROADMAP.md](PLATFORM-ROADMAP.md) | Windows / Android 对齐路线与当前验收边界 |
| [platforms/android/README.md](platforms/android/README.md) | Android 原生工程、开发 APK 与验收 |
| [RELEASE.md](RELEASE.md) | 发布流程：渠道、一条命令发布、节奏与版本号规则 |
| [RELEASE-REFERENCE.md](RELEASE-REFERENCE.md) | 发布技术参考：签名、安装器、应用内更新、CI |
| [RELEASE-HISTORY.md](RELEASE-HISTORY.md) | 已关闭的发布通道、旧仓库迁移与改名记录 |
| [CHANGELOG.md](CHANGELOG.md) | 由公开 GitHub Release 与提交信息生成的逐版本变更 |

## 自动更新

已安装的正式签名版 RIMES 会检查 [`scholay/rimes`](https://github.com/scholay/rimes) 的
GitHub Release；未签名的 `vX.Y.Z-preview.N` 不会进入该通道。

macOS 自动发布工作流的入口如下（各平台流程见 [RELEASE.md](RELEASE.md)，变更见 [CHANGELOG.md](CHANGELOG.md)）：

```bash
./scripts/release.sh --dry-run preview  # 预览计划、CI 门禁与发布说明
./scripts/release.sh preview            # macOS 未签名预览版 vX.Y.Z-preview.N
./scripts/release.sh stable             # 预览线转正为 vX.Y.Z（需 Developer ID）
./scripts/release.sh platform minor     # 显式维护用 Windows/Linux 数据预览（不阻断 macOS）
```

所有 Release 都发布在 `scholay/rimes`：macOS `vX.Y.Z` 是正式版；`vX.Y.Z-preview.N` 是未签名
Pre-release，不进入自动更新。Android 正式包使用 `android-vX.Y.Z`，Windows 正式包使用 `windows-vX.Y.Z`；旧 Windows/Linux 数据包 `platform-preview-vX.Y.Z` 始终是 Pre-release。

## 友链

- [RIME 输入法引擎](https://rime.im/) — 本项目的中文编码基于 RIME。
- [Linux.do](https://linux.do/u/leowangling/preferences/account) - 感谢真诚、友善、团结、专业之社区L站及一众佬友。
- [iRime](https://github.com/jimmy54/iRime) — 感谢 iRime 作者对 RIMES 的指导与宣传支持。

## 贡献者

完整名单见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

本项目核心维护者为C端产品经理，非专业程序员出身，感恩伟大的vibe coding时代。

**AI 编程助手**：Claude、Cursor、Codex、Grok 参与了设计、实现与审阅。

## 已知问题

- **Linux：部署还没结束就退出 Fcitx5，进程可能要几分钟才退出。** 首次或后台的 librime 部署无法中途取消，词库较大时更明显。见 [#43](https://github.com/scholay/rimes/issues/43)。
- **Linux：拖完 Buffer 工具条后立刻点另一个输入框，捕获可能还开着。** 目前只在 X11 的 Firefox 里复现，松开后约 10 毫秒内点到同一窗口的另一个输入框就会碰上。再点一次或按 Esc 即可恢复。见 [#44](https://github.com/scholay/rimes/issues/44)。

## 许可证与第三方

RIMES 自有代码采用 [Apache License 2.0](LICENSE)，具体范围及历史 MIT 授权见 [LICENSING.md](LICENSING.md)。核心维护者为[学术海](https://pm.scholay.com)。

中文输入基于 [Rime 输入法引擎（librime）](https://github.com/rime/librime)。来源声明见 [NOTICE](NOTICE)；我们倡议衍生版本说明 Rime、RIMES 及修改者的关系，示例见[来源与署名](ATTRIBUTION.md)。该展示倡议不增加许可证之外的限制。

第三方组件、方案、词库和 Lua/OpenCC 数据保留各自的许可与署名，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[LICENSES](LICENSES/) 和 `rime-data/licenses/`。官方免费插件在 [rimes-plugins](https://github.com/scholay/rimes-plugins) 仓库维护。
