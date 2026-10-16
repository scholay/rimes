# XSIME 命名与兼容规范

2026-10-15 确认。本规范区分目标品牌、已发布状态与下一轮迁移，不声称商店或备案已经更名。

| 用途 | 名称 |
| --- | --- |
| 简体中文显示名 | 犀术IME |
| 繁体中文显示名 | 犀術IME |
| 英文及其他语言默认显示名 | XSIME |
| 项目、架构名称 | XSIME |
| 目标仓库路径 | `scholay/xsime` |
| 官方网站 | `https://xsime.com` |
| 当前运营主体 | 个人；公司运营迁移另行办理 |

IME 表示 Input Method Editor。Rime / librime 是上游输入引擎名称，保持原名、版权及来源说明。RIMES、灵犀输入法、靈犀輸入法、Lingxi IME 仅用于历史和迁移说明，不再作为新增产品的品牌。

## 品牌标语

- 简体：**心有灵犀，落笔见术**
- 繁体：**心有靈犀，落筆見術**

标语中的“灵犀”保留原文，不作为旧产品名替换；对外产品名仍为犀术IME / 犀術IME / XSIME。英文标语尚未确定，不将临时译文当作正式品牌文案。

## 兼容标识不改

- macOS Bundle ID、输入源 ID、IMK 控制器类名、现有 `RIMES.app` / `RIMES` 可执行文件名。
- iOS Bundle ID、App Groups、Keychain Groups；Android applicationId、签名。
- Windows CLSID、注册表键、协议、安装所有权标记；Linux 包名、addon ID。
- 所有用户数据路径、偏好键、凭据、词库、输入方案 ID（包括 `lingxi_wubi`）、插件 ID。
- 既有发布资产文件名、版本号、校验和、历史 Release、提交记录、备案证据。

2026-10-16 输入法连接修复：`InputMethodConnectionName` 从旧的 `RIMES_1_Connection` 校正为 `com.scholay.inputmethod.isaac_Connection`，与现有 Bundle ID 加 `_Connection` 的运行时约定一致。Info.plist、IMKServer 后备值、安装诊断和 CI／发布校验同步采用此值；Bundle ID、父／子输入源 ID、控制器类、签名和用户数据保持原值。这是输入法连接故障修复，不是品牌替换。

显示名必须与上述身份分离，不能全仓库无差别替换 `rimes` / `RIMES` / `lingxi`。历史截图、词典里的自然语言词条不属于品牌替换。

官网迁移只调整产品入口，不替换维护者主页、上游版权地址或仍在使用的帮助/隐私页面。iOS 1.1.5（59）已送审，其二进制与配套材料保持冻结；应用内旧官网入口随下一次 iOS 构建更新，不以这轮四端打包冒充已更新的 iOS 构建。

## 仓库切换与更新兼容

2026-10-15 已正式将同一仓库改名为 `scholay/xsime`，仓库 ID 保持 `1327328463`。本地 origin 已更新。旧仓库 API、Git 读取、PR 和现有 PKG 下载重定向已验证，旧 `/rimes/ios/privacy/` 返回 HTTP 200。源代码合并状态以 PR #143 为准，仓库改名不代表新安装包已经发布。

已发布旧版 `Sources/RimeBuffer/UpdateManager.swift` 的 `githubRepo` 固定为 `rimes`，更新响应最终 API URL 和资产 URL 都要求精确匹配。GitHub 重定向并不能让已安装旧二进制接受新地址。本次源码改用固定仓库 ID 查询，并仅允许同一官方仓库的两个明确名称。

- [x] 新版更新器仅允许同一官方 owner 下明确列出的新旧仓库 URL，并保留签名、包身份、版本和资产唯一性校验。
- [x] 增加新旧 URL、非官方 owner、相似仓库、异常 URL 的正反向测试。
- [x] 2026-10-15 正式改名；旧版用户手动安装说明见下，即使先发布过渡版，未升级用户仍可能需要手动安装。
- [x] 源码中的 release workflow 仓库门禁、发布脚本、README 与下载地址已改用 `scholay/xsime`；origin 已同步。
- [ ] 实测旧仓库页面、Issue、PR、Release 下载、Git 操作与应用内更新。不得重建 `scholay/rimes` 占用旧地址。

### 旧版 macOS 用户必读

仓库更名后，旧版内置更新检查可能因严格 URL 校验而失败。这不会改变已安装输入法、词库或设置。请从 [官方 Releases](https://github.com/scholay/xsime/releases) 手动下载**包含本次兼容更新的新版**并安装一次；不要删除 `~/Library/RIMES`。旧的 1.1.4 等现有发布资产不会因仓库改名自动变成新版本，新版发布以前重复安装旧包不能解决旧更新器的问题。

GitHub 网页、Git 和 Release 下载使用平台重定向兼容；不会新建占用 `scholay/rimes` 的仓库。包文件名继续使用 `RIMES-*`，不因此更改身份或签名。

## 五端源码与外部系统

- [x] 五端主入口、键盘列表、设置和关于等宿主显示名称完成源码迁移；既有文件名（如 `RIMES.app`、Windows 快捷方式）仍保留兼容，不假装已发布客户端自动变化。
- [x] iOS 增加繁体名称资源；五端提供简体、繁体和英文品牌，不代表整套界面已翻译。
- [x] 衍生功能“犀术五笔”只改展示，不改 `lingxi_wubi` schema ID、词库和学习数据。
- [ ] Wiki、Roadmap、插件宿主介绍和图文素材统一；固定版本依赖与其校验和不盲目重写。
- [ ] App Store / TestFlight 与其他分发渠道按新版本流程更新；不新建 App、不改包身份。
- [ ] APP 工信部备案名称变更、公安联网备案及隐私说明按实际个人运营主体处理；不将网站「带派不」无关更名。
- [ ] 后续转公司运营时，另行核对商标授权/归属、备案主体、开发者账户及隐私主体。

固定版本的 `OfficialPlugins` 及其生成源不直接篡改；其中少量历史品牌文案需要在插件源仓库更新、重新锁定和验收后再同步。历史验证记录与截图保持原样。

## 本次验证（2026-10-15）

- macOS：Xcode Swift 构建通过；更新地址/安装包校验、状态菜单、设置路由 smoke 通过。本机开发安装因已有系统级 `/Library/Input Methods/RIMES.app` 被安全门禁拒绝，未删除或覆盖现有安装，不宣称本机已换新版。
- iOS：重新生成引擎资源后，模拟器 272 项测试零失败、3 项跳过；不是 App Store / TestFlight 上传或真机验收。
- Android：debug APK 构建与 core 单元测试通过，不是正式签名发布。
- 共享核心 82 项、发布工具 95 项、品牌/兼容标识 6 项测试通过。
- Linux 本地生命周期/打包 17 项测试通过；Windows 与 Linux 原生构建、安装验证以 PR 的远端 CI 结果为准。Young Windows 主机当时不可连接。

## 旧 Pages 链接

用户已授权创建 `scholay/scholay.github.io`，在组织站点的 `/rimes/` 路径保存静态帮助/隐私页面兼容副本。这样无需重新创建 `rimes` 仓库；源仓库仍为 `rimes` 时项目站点优先，正式更名后由组织站点承接旧路径。部署成功和切换后的公网可达性须分别验证。
