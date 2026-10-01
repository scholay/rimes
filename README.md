# RIMES

**[中文](README.md)** · **[English](README.en.md)**

RIMES 是一款面向 macOS 的中文输入法。它以 Rime 为输入引擎，在候选词上方显示逐词翻译，让你在确认上屏前同时看到每个候选词的含义。

## 界面预览

候选栏将译文与中文候选逐项对齐；选中的候选以蓝底白字突出显示。

![RIMES 双层候选栏与 Liquid Glass 效果](images/rimes-candidate-liquid-glass.png)

设置界面也使用半透明 Liquid Glass 材质：

![RIMES Liquid Glass 设置界面](images/rimes-settings-liquid-glass.png)

## 功能

- **多种中文输入方案**：支持雾凇全拼、自然码双拼、小鹤双拼、五笔 86 和英文输入。
- **逐候选翻译**：每个中文候选词都对应自己的译文，便于区分同音词和不同语义。可在设置中选择 Apple 支持的目标语言。
- **Apple 翻译**：候选翻译使用 Apple Translation 框架。macOS 15 及以上版本可使用；部分语言需要先准备语言包，实际选项以系统支持为准。
- **Liquid Glass 外观**：这是 RIMES 的默认视觉风格，候选栏、设置窗口和主要界面统一使用半透明玻璃层、柔和边缘与系统强调色。macOS 26 及以上使用原生 Liquid Glass 材质；较早版本使用兼容的系统材质，并遵循系统的降低透明度设置。
- **输入工作台**：Buffer 可暂存、整理和确认文本，再投递到当前输入框。
- **Capsule**：集中查看和管理剪贴板历史、笔记、图片、PDF 等内容。

## 系统要求

- macOS 13 或更高版本
- Apple Silicon 或 Intel Mac
- 支持 macOS 13 Ventura、14 Sonoma、15 Sequoia、26 Tahoe 和 27 Golden Gate；项目最低部署版本为 macOS 13。版本名称与当前系统版本可参阅 [Apple macOS 版本列表](https://support.apple.com/zh-cn/109033)。
- 候选翻译需要 macOS 15 或更高版本
- macOS 26 及以上提供原生 Liquid Glass 材质；macOS 13–15 使用兼容的系统材质

## 安装

查看 [GitHub Releases](https://github.com/Kindred5210/rimes/releases) 获取公开安装包。若 Releases 页面尚无安装资产，说明当前版本暂未发布预编译安装包。

从源码进行开发安装：

```bash
git clone --branch feat/bilingual-candidate-translation --single-branch https://github.com/Kindred5210/rimes.git
cd rimes
./build_install.sh
```

安装脚本会把开发版安装到当前用户的输入法目录，并尝试注册和启用 RIMES。系统可能会要求你在“系统设置 → 键盘 → 输入法”中确认启用。

## 使用

1. 在 macOS 的输入法菜单中切换到 **RIMES**。
2. 输入拼音并浏览候选词；每个候选词上方会显示对应的译文。
3. 打开 **RIMES 设置 → 输入法 → 候选翻译**，选择目标语言并按需准备语言包。
4. 在 **RIMES 设置 → 外观**查看候选窗和界面尺寸选项。

设置快捷键：`⌘⇧Z`。快捷键仅在 RIMES 输入源激活时打开设置。

## 开发

开发版使用 Swift Package Manager 构建。完成安装、注册输入源和准备 Rime 运行时：

```bash
./build_install.sh
```

首次构建需要网络下载 Swift 与 Rime 依赖。应用使用 macOS 原生 InputMethodKit 与 AppKit 界面，Rime 负责候选生成；词库和方案随项目维护。更多实现文档见 [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md)。

## 许可与致谢

RIMES 自有代码使用 [MIT License](LICENSE)。内置 Rime 方案、词库和第三方库分别遵循其原有许可；详细信息及署名见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 `rime-data/licenses/`。

RIMES 建立在 [Rime](https://github.com/rime) 与 [librime](https://github.com/rime/librime) 生态之上，感谢相关项目和词库维护者。
