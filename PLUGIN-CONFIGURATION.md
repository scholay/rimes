# RIMES 插件配置规范

本规范适用于新的内置缓冲插件、内置扩展，以及由宿主为外部 Action
Plugin 提供的可信配置。插件设置必须通过
`PluginConfigurationSchema` 声明，并由 RIMES 渲染；不得为单个插件在
`SettingsWindow` 中继续增加一次性的输入框或持久化分支。

## 1. 声明与身份

- `pluginID` 使用稳定插件 ID；发布后不可复用给另一个插件。
- 字段 `id` 使用稳定的 ASCII 小写标识。改标题不改 ID；删除或改类型时
  必须提供迁移策略。
- 可用字段类型仅为 `text`、`secureText`、`toggle`、`choice` 与
  `number`。每个字段都必须声明默认值、边界和面向用户的说明。
- 交叉字段约束放进 schema validator。错误信息只描述修复方法，不回显
  被拒绝的值。
- 内置插件通过 `PluginConfigurationProviding` 返回
  `PluginConfigurationModel`。外部插件不能注入 AppKit 视图；宿主可以
  为已知 wire ID 提供同样的声明式配置。

## 2. 存储边界

- 普通偏好使用 `PluginConfigurationUserDefaultsStore`，每个插件一个
  namespace，并以完整字典原子替换。
- 只要 schema 含 `secureText`，必须使用私有存储。默认路径是
  `~/Library/RimeBuffer/plugin-config/<plugin-id>/configuration.json`，
  `plugin-config` 与 `<plugin-id>` 目录权限为 `0700`、文件权限为
  `0600`。共享的 `~/Library/RimeBuffer` 根目录必须是当前用户所有且
  不可由 group/world 写入；兼容 Rime 数据导入留下的安全 `0755`，
  不得因此拒绝读取内部的私有配置。
- 已有专用凭据文件的插件通过 `PluginConfigurationStoring` adapter
  复用通用表单，不能再生成第二份密钥副本。
- 密码、token、API key 不得进入 UserDefaults、argv、URL、通知、
  `description`、日志、崩溃诊断或测试输出。
- 保存必须先验证、写入同目录临时文件、`fsync`、设为 `0600`，再原子
  `rename`；读取拒绝符号链接、非普通文件、非当前用户所有者、错误权限
  与超限文档。
- 当前开发构建使用 ad-hoc 签名，因此敏感项采用上述私有文件。切换到
  稳定 Developer ID 后，可在提供无损迁移和回滚方案的前提下迁往
  Keychain。

## 3. 运行时语义

- 保存成功后发送 `.pluginConfigurationDidChange`。通知只带 plugin ID
  与 changed field IDs，绝不携带值。
- 插件在真正发起一次任务时读取并冻结配置快照；进行中的 SSH、翻译或
  模型请求不因设置窗口再次保存而半途变更。
- 配置变化可以取消尚未获得结果的旧 generation，但迟到回调仍必须通过
  原有 generation、焦点与 owner 校验，不能恢复投递权。
- 默认值必须保持升级前的行为，除非产品明确要求迁移。损坏或不安全的
  敏感配置必须 fail closed，并给出不含敏感值的状态。
- 连接器与缓冲插件 owner 是两个维度。选择 AI 渠道不能暗中切换当前
  缓冲插件；切换插件也不能覆盖连接器凭据。

## 4. UI 与可访问性

- “设置 › 插件”中所有具有配置 schema 的插件统一显示“设置…”按钮。
- 表单由宿主生成，密码使用 `NSSecureTextField`；普通文本和安全文本
  都在显式点击“保存”后才持久化。
- “恢复默认值”必须明确说明会删除已保存的敏感项，并在执行前二次确认。
- 字段标题、帮助文字、选项标题和错误提示必须可读；不能只靠 placeholder
  传达含义。

## 5. 合入检查

新增或修改插件配置时至少验证：

1. schema 默认值、类型、范围与迁移；
2. 保存后运行时确实读取新值；
3. 共享根目录所有者/不可写边界、私有子目录与敏感文件的
   `0700/0600` 权限，以及 symlink 拒绝；
4. argv、环境值、通知和日志不含敏感值；
5. reset 恢复既定默认行为；
6. secure input、owner 切换、取消和迟到结果仍 fail closed；
7. `swift build`、相关 smoke、`git diff --check` 与隐私日志 lint 通过。
