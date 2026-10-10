# Windows Bug 复测清单（验收完成后删除）

复测人：Isaac，在自己的 Windows 机器操作。维护侧负责源码修复和自动化；本表的桌面结果由复测人填写。每单通过后，将版本、操作和结果补到对应 GitHub issue，再关闭该单；八单均通过且结果已留在 issue 后，删除本文件并提交删除记录。

截至 2026-10-10，以下八单均有修复实现，但没有完整的当前版本真机通过反馈。`needs validation` 表示等待复测，不表示已经验收。

| Issue | 实现进度 | 本次桌面结果 |
| --- | --- | --- |
| [#79 卸载残留及重装失败](https://github.com/scholay/rimes/issues/79) | 注册路径恢复、双架构注销及重装保护已实现；1.1.1 已含修复 | 待测 |
| [#83 state.json / DLL 丢失后无法卸载](https://github.com/scholay/rimes/issues/83) | 缺失或损坏状态文件、悬空 DLL 注册恢复已实现；1.1.1 已含修复 | 待测 |
| [#87 设置页面闪烁](https://github.com/scholay/rimes/issues/87) | 整帧离屏绘制和局部 hover 重绘已实现 | 待测 |
| [#93 标准用户跨账号 UAC 安装失败](https://github.com/scholay/rimes/issues/93) | #114 分离机器安装与原用户配置；9ba4f21 补安装期间的 Broker 预留及签名诊断 | 待测 |
| [#102 设置置顶及无法拖到副屏](https://github.com/scholay/rimes/issues/102) | #107 已解除设置窗的置顶/owner 链；修复 Buffer 层级恢复 | 待测 |
| [#103 数字丢失及 Shift 失效](https://github.com/scholay/rimes/issues/103) | #114 已修复空闲数字、ASCII 路由和无用写锁；本轮补小键盘 Shift、decimal 和运算符直通 | 待测 |
| [#104 QQ 旧 MSVCP140 冲突](https://github.com/scholay/rimes/issues/104) | #107 已将完整 TSF 私有闭包编为 /MT，保留线程通知和 COM 生命周期保护 | 待测 |
| [#106 候选跳到左上角](https://github.com/scholay/rimes/issues/106) | #107 已移除不可信原生 caret 回退，仅在同一上下文保留已验证位置 | 待测 |

## 版本和环境记录

不要只记录“1.1.2”：相同版本号的不同提交、已安装 DLL 和仍在运行的旧宿主必须区分。

```text
测试日期 / 复测人：
Windows 版本、Build、x64：
登录账号：管理员 / 标准用户（无需填写账号名）
源码提交（git rev-parse HEAD）：
OfficialPlugins 提交（git -C OfficialPlugins rev-parse HEAD）：
安装包文件名 / SHA-256：
PACKAGE.json 的 version / commit / sourceSnapshot：
Verify.ps1 返回的版本、提交和目录：
安装后是否注销或重启：
显示器位置和缩放（如主屏 150%，左侧副屏 100%）：
输入方案、是否启用并击、Buffer 状态：
宿主名称及版本：
```

本轮基线包含主线 #107 / #114，以及 Windows 分支的 c11876c、9ba4f21。公开 1.1.1 包不包含本轮全部修复，需要使用本分支新构建的包。Windows IME CI 的 unsigned foundation artifact 用于自动化，缺少完整产品安装包和词库，不能直接当作日用安装包验收。

开发机在仓库根目录准备并构建（VS 2022、Windows SDK、CMake、Python）：

```powershell
git submodule update --init OfficialPlugins
python scripts/prepare-official-plugins.py
if ($LASTEXITCODE) { throw '插件准备失败' }
python scripts/sync-buffer-plugin-catalog.py --check
if ($LASTEXITCODE) { throw '插件目录检查失败' }
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x64 -Configuration Release
./platforms/windows/scripts/Build-RimesWindows.ps1 -Architecture x86 -Configuration Release
```

完整词库按 [README 的产品数据流程](README.md#product-shared-data) 准备；EXE/ZIP 使用 [New-RimesNativePackage.ps1](../scripts/New-RimesNativePackage.ps1)，必须提供当前 `git rev-parse HEAD` 作为 `Commit`，以及完整 `SharedData`、锁定的 x64 `RimeDll`、Microsoft 签名的 `VCRedistX64` / `VCRedistX86` 和新的 `OutputDirectory`。双架构 `build-identity.json` 必须匹配；该脚本会同时调用 `New-RimesSetupExe.ps1` 生成 EXE 和校验和。保存好 Buffer 内容并从托盘退出，然后由日常登录用户正常双击 EXE；若安装器提示注销或重启，完成后再测。

在安装包目录用 `powershell -NoProfile -File .\Verify.ps1` 核对已安装版本。此脚本返回 `HostInputAcceptance='Requires desktop testing'`，注册和文件检查通过仍需下面的操作验收。

## 先测普通输入和设置

每单记录“通过 / 失败 / 不具备环境”。不具备环境保持待验收。测试用虚构 API 地址、模型和正文，不用真实密钥。

### #103 数字、独立 Shift、选词

- [ ] Buffer 关闭。选择 RIMES，在设置 → 连接器的 API 地址和模型框，分别输入并核对 `0123456789`，不丢字符、不重复；换另一个普通软件设置输入框再测。
- [ ] NumLock 开启，使用小键盘输入数字、小数点、`+ - * /`，内容准确。按住 Shift 操作小键盘，再放开 Shift，宿主仍可正常编辑。
- [ ] 保持同一输入框焦点，轻按独立左 Shift：下一次英文输入直达编辑框；再轻按切回中文，可以正常组字和上屏。标准方案默认右 Shift 为 noop；isaac2026 按其方案配置验收。
- [ ] 中文正在组字时，数字仍能选中相应候选；Shift+数字行仍按方案输出标点。
- [ ] Shift+字母、Ctrl/Alt/Win 快捷键、长按 Shift 和切换焦点不误切换模式。Backspace、Return、Space 和 Ctrl+A/C/V 在空闲时保留宿主行为。
- [ ] 打开并绑定 Buffer，英文、数字和小键盘输入进入原文轨；关闭后继续普通输入正常。失败时记录是按键消失、上屏重复、模式未切换还是目标未绑定。

### #87 设置 hover 闪烁

- [ ] 在“输入 → 外观”和“Buffer → 连接器”左栏之间反复移动鼠标，停留、点击、移出再移入；导航和页面没有整帧闪烁、短暂变白或模糊。
- [ ] 切换浅色/深色，调整候选外观、滚动长页面，再重复 hover；设置输入框仍能正常输入。
- [ ] 在自己的显示器上记录实际缩放。若没有报告者的荣耀设备，填写本机结果，不写“原机通过”。

### #102 窗口层级及双屏

- [ ] Buffer 关闭时打开设置，把记事本/浏览器切到前台并覆盖设置；设置不会持续压在其上。
- [ ] 拖动设置标题栏到副屏、负坐标副屏，以及不同缩放屏幕；窗口留在用户拖到的位置，控件可点击，文字清晰，不被强制拉回主屏。
- [ ] 打开 Buffer 再打开设置，Buffer 不盖住设置；关闭设置后，Buffer 恢复正常层级。快速关闭/重开设置三次后再次检查。
- [ ] 将“100% / 150% / 200%”和实际双屏组合分别标为通过、失败或未测；只有单屏时本单不能完成双屏验收。

### #106 候选定位

- [ ] 使用小鹤，在 Codex 桌面文本框中连续输入、退格、翻页和提交；候选始终在当前输入位置附近，没有随机闪到窗口/屏幕左上角。
- [ ] 组字时移动宿主窗口、滚动、缩放或移到另一显示器；恢复布局后候选跟随当前输入框。
- [ ] 在两个输入框和两个应用间切换；新输入框短暂没有 caret 时，不显示旧输入框的候选位置，也不向旧目标上屏。
- [ ] 记事本和 Edge 的 input / contenteditable 再测；密码框不显示候选。记录发生闪跳的宿主、版本和操作，必要时附脱敏录屏。

### #104 QQ 运行库兼容

- [ ] 完成新包安装和注销/重新登录后，启动 QQ NT 并使用 RIMES 输入、选词、切换中英文；切换聊天草稿窗口和其他输入法后，QQ 不闪退。
- [ ] 完全退出并重开 QQ，重复操作；其他 x64/x86 宿主仍可输入。
- [ ] 记录 QQ 完整版本，以及其实际加载的 MSVCP140 路径/版本（报告环境为 QQ 9.9.31.49738 / 14.29.30154）。如果未覆盖会触发冲突的旧运行库环境，保持此场景待验收。

## 再测安装、损坏恢复和卸载

这些流程会改变被测试安装。先备份 `%APPDATA%\RIMES` 并记录现有词库/设置，使用可恢复的测试安装或系统快照分别完成每个场景，不手工批量删除注册表。

### #93 标准用户 + 另一管理员凭据

- [ ] 以标准用户正常登录并双击 EXE，UAC 输入另一管理员的凭据；机器阶段和原用户配置阶段都完成，不再出现“必须同一用户安装”。
- [ ] 原用户可选择 RIMES 输入；词库仍在原用户 `%APPDATA%\RIMES`，开始菜单设置入口和 HKCU 的 `RimesBroker` 自启动属于原用户，管理员账号没有被代写这些用户配置。
- [ ] 在相同账号边界升级，原有词库/设置保留；开始菜单和自启动指向新版本。关闭自启动再升级/重新运行安装器，选择与结果一致。
- [ ] 取消 UAC 后，不开始用户配置、不报告成功，旧输入法仍可用；机器阶段或用户阶段失败时给出对应失败和恢复提示。
- [ ] 从标准用户的 Windows“已安装的应用”发起卸载，用另一管理员批准；注销原用户安装，保留原用户数据，其他输入法仍可用。
- [ ] 若机器策略要求受信任签名，记录 8235 / 证书信任结果。未签名预览只能明确失败，不能把跳过策略当成验收通过；签名场景单独记录。

### #83 状态文件和 DLL 缺失

从相同、可恢复的安装状态分别测试以下三种损坏。每次核对完整包的 `PACKAGE.json` 和实际安装路径，然后从完整新包的卸载/修复入口操作。

- [ ] 将 `state.json` 改名后卸载：没有未经处理的 `Get-Content` 异常，按实际注册路径恢复，两套 TSF/COM 注册均注销。
- [ ] 将 `state.json` 改为非法 JSON 后卸载：结果同上，不通过目录时间猜测安装身份。
- [ ] 先改名 `state.json`，再在已退出宿主的测试安装中改名 x86 `RimesTsf.dll`，形成悬空注册：仍可注销缺失 DLL 的那一架构。若宿主占用导致无法改名，记录并在注销后重新执行此场景。
- [ ] 上述每种场景都验证用户词库和设置保留，注销/重新登录后 RIMES 输入法条目不残留；重新安装当前 EXE 后两架构可用。
- [ ] 非 RIMES 的注册/路径不被移除；所有权无法核验时提供修复提示并保留现场，不能把拒绝清理判为“已卸载成功”。

### #79 第三方卸载残留、重装

- [ ] 在可恢复的测试安装中复现第三方卸载器留下的注册、缺失状态或 DLL；运行当前 EXE 修复/升级，不被残留注册卡死。
- [ ] 使用 Windows“已安装的应用”的 RIMES 卸载入口完成卸载；注销/重新登录后图标消失，其他输入法继续可用，用户数据保留。
- [ ] 再运行当前 EXE 安装：无需手工删注册表，即可选择 RIMES 输入。x64 和 x86 测试宿主分别可用。
- [ ] 若出现占用提示，完成提示要求的注销/重新登录后再确认；不强行覆盖旧 DLL，也不把仅退出 Broker 当成 DLL 已释放。

## 自动化结果及回报

维护侧本地已通过：完整数据打包单元测试 11 项、官方插件导入测试 5 项、插件目录一致性；使用 Clang 执行 Buffer placement/layout、候选 layout、Workbench model、SSE/control 和 Broker protocol 共六组可移植测试。这些是在 macOS 执行的逻辑检查。

本分支需以 Windows IME CI 的新提交结果为准：MSVC x64/x86 构建、CTest、真实 TSF 代码 + FakeTSF 文档的输入回归、安装器 payload/结果/签名和账号生命周期隔离测试。测试已覆盖空闲写锁拒绝、数字和小键盘预判、Shift 取消/重复、候选上下文切换、DLL 静态 CRT 导入及 COM 生命周期。它们不代替上面的 QQ、设置输入框、双屏、跨账号 UAC 和实际卸载复测。

向每个 issue 贴以下简表即可；失败项保留打开并继续修复，通过项按已覆盖的原问题范围关闭：

```text
Issue：#
源码 commit / 安装包 SHA-256：
已安装 commit（Verify.ps1）：
Windows / 宿主版本 / 方案 / 缩放和显示器：
完成的步骤：
结果：通过 / 失败 / 未测
失败时实际表现及脱敏证据：
```

八个 issue 的桌面结果全部通过、必要的不同环境场景补齐、结果已发布到对应 issue 后，再删除此文档。CI 通过或仅源码已推送时保留文档。
