# XSIME Capsule（Linux）

Capsule 与 Buffer 共用 Fcitx 输入宿主。五个模块（临时、捕获、笔记、资源、密码）的稳定身份、顺序和过滤项由 macOS `CapsuleModules.swift` 提取，分别在插件管理中启停。管理页、底栏与快捷入口共用这份导航状态。

`ui/` 是 GTK 3 管理页和不抢焦点的底栏；`core/` 提供 Markdown、原子附件、过滤、快照和授权边界。单条文本插入只使用原输入框的 Fcitx `commitString`，复制只改剪贴板。管理页编辑不会获得输入目标；返回底栏后需显式重新唤起以绑定目标。

当前宿主已支持普通笔记编辑及多种内容记录。结构化笔记/富文本、剪贴板收录、资源预览、屏幕捕获及密码库分别由 #163–#167 实现，注册模块不代表这些后端已经完成。像素对齐仍在验收，见 [验证记录](HOST-VALIDATION.md) 和 [行为合同](SPEC.md)。

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
| 底栏 Return / 双击 | 向仍绑定且聚焦的输入框插入笔记正文，成功后关闭 |
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
