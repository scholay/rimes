# RIMES

**[中文](README.md)** · **[English](README.en.md)**

从零做的现代 macOS 输入法：**librime** 引擎 + 自绘候选窗 + 常驻缓冲区（buffer）。内置飞耀互击、自然码双拼、全拼与英文方案；**自包含**打包 librime 与词库，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`）；`ETInput.app` 为兼容旧安装与自动更新保留的内部路径。对外产品名统一为 **RIMES**（rime-scholay）。

## 演示视频

- [哔哩哔哩 · 完整介绍](https://www.bilibili.com/video/BV17XuH6SEDg/)
- [抖音 · 产品演示](https://www.douyin.com/video/7671078195197742355)

另有分集快剪：实时翻译、AI 生成、意识流、My Prompt、Remarkable、Marine 等，见 B 站合集。

## 它解决什么问题

普通输入法打完就直接上屏；RIMES 在中间加了一层**上屏前的文本工作台**：

1. 中文 / 英文先进入缓冲
2. 可翻译、AI 改写、检索提示词，或带上浏览器页面上下文再生成
3. 你确认后，才用纸飞机或 Return **显式投递**到当前输入框

结果不会自动发帖、不会静默改网页。适合写作、评论、双语与 AI 工作流。

## 主要能力

| 能力 | 说明 |
|---|---|
| 输入方案 | 全拼、自然码双拼、英文；飞耀并击 / 互击 |
| 缓冲工作台 | `⌘⇧B` 开关；先暂存、再分块投递 |
| 实时翻译 | 默认 Apple 本地翻译（macOS 15+），也可走 AI 渠道 |
| AI 生成 | Codex CLI / Claude Code CLI / OpenAI 兼容 API |
| 意识流输入 | 拼音/并击 → 最多 3 个互斥猜测 → 选定后投递 |
| My Prompt | 本地优先检索 Fabric / Obsidian 等提示词库 |
| Marine Chrome | Chrome 扩展提供页面上下文（如 B 站评论/回复），本地确认后生成 |
| Remarkable | USB + 本地 OCR，把当前页识别进缓冲 |
| 隔空传字 | Mac ↔ Mac 加密直连，无需同一 Wi‑Fi / Apple ID |

## 安装

普通用户：从 [GitHub Releases](https://github.com/scholay/rimes/releases) 下载 `RIMES-版本号.pkg`，双击安装。安装器会把内部兼容路径 `ETInput.app` 放进 `/Library/Input Methods`，并尝试注册、启用并切换到「RIMES」。

开发者本机：

```bash
./build_install.sh                # 构建 + 安装到当前用户 + 注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
tail -f ~/rimebuffer.log          # 行为日志
```

更多 smoke 命令与发布流程见 [RELEASE.md](RELEASE.md)。

### Marine Chrome（可选）

当前仅支持 Stable Chrome。扩展源码在 [`Extensions/marine-chrome`](Extensions/marine-chrome)：

1. 打开 `chrome://extensions`，启用开发者模式，加载已解压的 `Extensions/marine-chrome`
2. 按页面完成与 RIMES 的双确认配对（无需粘贴密钥）
3. 在 RIMES 中开启缓冲与 Marine Chrome，并把工作台 owner 切过去

扩展只做网页传感器，不运行模型，也不会自动填入或发布内容。

## 文档

| 文档 | 内容 |
|---|---|
| [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md) | 当前权威全局架构（接手开发请先读） |
| [ARCHITECTURE.md](ARCHITECTURE.md) | P1/P2 历史契约与踩坑 |
| [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md) | 插件声明式配置 |
| [RELEASE.md](RELEASE.md) | CI、通用二进制、应用内更新 |

## 自动更新

已安装的 RIMES 会检查 [`scholay/rimes`](https://github.com/scholay/rimes) 的 GitHub Release。发布：

```bash
./scripts/release.sh minor
```

## 友链

- [本项目已在L站发布开源推广](https://linux.do/u/leowangling/preferences/account)

## 已知问题

- **macOS 26 上，在微信窗口聚焦时切换输入法可能导致微信崩溃**（崩在 Apple `TextInputUIMacHelper`）。这是上游问题，同样影响原生 Rime/Squirrel（[rime/squirrel#951](https://github.com/rime/squirrel/issues/951)）。**规避**：先在别处切好输入法，再进入微信打字。

## 许可证与第三方

本项目采用 [MIT License](LICENSE)。第三方依赖见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
