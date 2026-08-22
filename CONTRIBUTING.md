# Contributing to RIMES

感谢你帮助改进 RIMES。提交代码前，请先在最新 `main` 上复现问题，并确认没有把用户输入正文、
API 密钥、剪贴板内容或本机路径放进 Issue、日志和测试夹具。

## 报告问题

- Bug 请使用 GitHub 的 Bug 表单，写清 macOS、RIMES 版本/commit、宿主应用、输入方案、
  Buffer/剪贴板状态、Spaces/显示器环境和最短复现步骤。
- 输入法行为必须区分“源码 smoke 通过”和“安装后的真实宿主验证”。候选窗、焦点、secure input、
  输入源切换和跨 Space 问题不能只凭单元测试宣布解决。
- 附日志前先脱敏。RIMES 的日志不得包含输入正文、候选正文、剪贴板内容、token 或密钥。

## 开发与验证

```bash
swift build -c debug
python3 -B scripts/sync-buffer-plugin-catalog.py --check
python3 scripts/lint-log-privacy.py
```

按改动范围运行对应 smoke；Buffer 与焦点改动至少运行：

```bash
BIN="$(swift build --show-bin-path)/RimeBuffer"
"$BIN" schema-smoke
"$BIN" buffer-smoke
"$BIN" buffer-window-smoke
"$BIN" clipboard-history-smoke
"$BIN" settings-routing-smoke
```

设计系统改动在 `DesignSystem/` 运行 `npm run check`。Windows/Linux 数据预览改动运行：

```bash
python3 -m unittest discover -s scripts/platform-preview -p 'test_*.py'
```

## Pull Request

- 一个 PR 聚焦一个可审查的目标；说明风险、验证证据和仍未验证的真实宿主场景。
- 不要修改冻结的输入源身份、`ETInput.app` 安装路径或 `Delivery.insert` 投递边界，除非同时提供
  明确迁移方案和回归矩阵。
- 新增/更新预置 Buffer 插件时，同步 `Catalog/buffer-plugins.json`、生成文件和 README 版本表。
- 不要从 fork、旧 tag 或本地重打包直接发布 Release。

## 贡献归属

人类维护者负责最终审查、合并和发布。AI 编码智能体实质参与设计、实现、测试或审查时，按
[`CONTRIBUTORS.md`](CONTRIBUTORS.md) 的规则使用已验证的公开身份添加 `Co-authored-by` trailer；
不要虚构身份，也不要仅为补署名改写已发布历史。
