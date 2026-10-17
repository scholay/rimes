# XSIME Capsule（Linux）

Capsule 与 Buffer 共用 Fcitx 输入宿主。五个模块（临时、捕获、笔记、资源、密码）的稳定身份、顺序和过滤项由 macOS `CapsuleModules.swift` 提取，分别在插件管理中启停。管理页、底栏与快捷入口共用这份导航状态。

`ui/` 是 GTK 3 管理页和不抢焦点的底栏；`core/` 提供 Markdown、原子附件、过滤、快照和授权边界。单条文本插入只使用原输入框的 Fcitx `commitString`，复制只改剪贴板。管理页编辑不会获得输入目标；返回底栏后需显式重新唤起以绑定目标。

当前已支持普通、Bullet、富文本笔记，以及带分组的逐行详情。笔记标题、摘要、外部 Markdown 和富文本资产均可保存；剪贴板收录、资源预览、屏幕捕获及密码库继续由 #164–#167 实现。像素对齐仍在验收，见 [验证记录](HOST-VALIDATION.md) 和 [行为合同](SPEC.md)。

## 构建与使用

```sh
platforms/linux/ime/scripts/deps.sh --install
platforms/linux/ime/scripts/build.sh
ctest --test-dir platforms/linux/ime/build --output-on-failure
platforms/linux/ime/tests/e2e/e2e.sh --build-dir platforms/linux/ime/build
```

推荐安装随项目 `v*` Release 发布的 `fcitx5-rimes` deb。Capsule 随完整版安装；普通升级、停用模块、卸载程序均保留用户词库、学习记录和 Capsule 数据。

| 操作 | 行为 |
|---|---|
| Ctrl+Shift+V | 默认全局 Capsule 快捷键（可在设置调整）；X11/Wayland 支持条件见 runtime/SHORTCUTS-VALIDATION.md |
| 底栏齿轮 | 打开 940×660 管理页，最小 620×430；撤销原输入目标 |
| 管理页 Ctrl+S / Esc | 保存 / 确认未保存修改后返回底栏 |
| 底栏 Return | 向仍绑定且聚焦的输入框插入整条笔记正文，成功后关闭 |
| 双击笔记卡片 | 打开分组详情，默认选中第一行；↑/↓ 选择、Return/双击插入值，Ctrl+C 复制值，Esc 返回 |
| Ctrl+C | 显式复制；快照、重启或搜索不会重放复制 |
| Tab / Shift+Tab | 按 macOS 顺序切换已启用模块 |
| 停用模块 | 清除可见投递数据并撤权，磁盘内容保留 |

数据默认为 `$XDG_DATA_HOME/rimes/capsule`（或 `~/.local/share/rimes/capsule`）；测试可用 `RIMES_USER_DIR`/`RIMES_CAPSULE_ROOT` 隔离。IPC 默认为 `$XDG_RUNTIME_DIR/rimes-capsule.sock`。

```sh
rimes-capsule-ctl manage
rimes-capsule-ctl module notes
rimes-capsule-ctl filter bullet
rimes-capsule-ctl search '项目'
rimes-capsule-ctl rail
```

## 笔记编辑

管理页选择「其他」「Bullet」或「富文本」。Bullet 支持复选框、添加条目、Tab 缩进和 Shift+Tab 反缩进；富文本支持粗体、斜体、链接、插入图片以及 Ctrl+Z / Ctrl+Shift+Z 撤销重做。图片保留原始字节，编辑器只缩放预览；单张图片上限 3 MiB / 1600 万像素，富文本资产上限 4 MiB。

正文中 `## 标题` 分组，`- 标签：值` 显示为字段。详情复制和插入只使用值；代码块作为一整行操作。未知 front matter 会保留。外部修改或同时编辑造成修订冲突时，保存不会覆盖磁盘内容。

富文本同时保存 macOS 兼容 RTFD 资产和可读 Markdown 副本。外部改动 Markdown 后，要在管理页明确选择「导入 Markdown 修改」才会替换富文本；未选择前保留原资产。复杂表格或不支持的 RTF 格式以只读正文保留，仍可编辑标题和摘要。单条文件格式损坏时显示原文和整理提示，其他笔记照常使用。

测试与限制见 [结构化笔记验证](NOTES-VALIDATION.md)。
