# RIMES Design System

RIMES Design System 是 `design/react-system` 分支中的交互式 React 设计母版。它把原生输入法中最需要反复调整的五类界面放在同一个可操作画布里：

- 设置后台
- 菜单与扩展配置
- 输入法候选框
- Buffer 工作台
- 剪贴板历史

这个项目用于共同讨论、试验并冻结视觉与交互规范。它不会替换 ETInput 中的 AppKit / InputMethodKit 运行时，也不会在输入法进程里引入 WebView。

## 本地运行

```bash
cd DesignSystem
npm install
npm run dev
```

常用检查：

```bash
npm run typecheck
npm run tokens:swift
npm run check
```

生产构建同时保留 Sites 托管契约：

- `dist/client/index.html`
- `dist/server/index.js`
- `dist/.openai/hosting.json`

## 使用方式

左侧切换五个产品界面，中间画布执行交互，右侧 Inspector 实时调整颜色和圆角。顶部按主题切换：经典主题包含墨竹、翡翠、静谧三种配色，拉斯塔是独立主题；当前 token JSON 仍可复制或导出。

场景和主题写入 URL，便于把某个讨论状态直接发给协作者：

```text
?surface=settings&theme=night
?surface=candidate&theme=day
?surface=buffer&theme=quiet
?surface=buffer&theme=rasta
```

主要交互均为本地模拟：候选选择、Buffer 派生模式、翻译语言交换、插件下载与启停、剪贴板选择和安全遮蔽都不会读取真实输入焦点、网络或系统剪贴板。

## 本分支已确认的产品决策

- 输入源菜单保留「设置」「Buffer」「Clipboard History」「Mailbox」「Capsule」「维护」六个入口；Buffer、Clipboard History、Mailbox、Capsule 是四个同级独立窗口模块。
- Capsule 底栏（原 Clipboard History）不是 Buffer rail。`⌘⇧V` 打开屏幕底部的 nonactivating 独立窗口，头部标签在「最近」与只读的 Capsule 条目之间切换，管理窗口只从齿轮或所选卡片的画笔打开；切到其他输入法会立即撤销窗口权限。收录开启且无 Secure Input、锁屏、睡眠或会话失活保护时，同一 RIMES 进程将文本、链接、图片、文件及其他原始 representation 持久保存在本机私有 SQLite。图片记录与可解码的图片文件异步加载有界缩略图，卡片显示真实来源 App 图标，图片类别别名也参与搜索。交互借鉴 Paste 的横向卡片时间流：直接输入搜索、左右选择，Shift 加纵向滚轮按反向映射横向移动；单击卡片只改变选择，双击、Return 或 `⌘1`–`⌘9` 才激活。文本/链接经 exact-focus IMK 直接上屏并提升到历史首位；图片、RTF、HTML、文件等富内容只无损恢复到系统剪贴板、提升到首位并静默关闭，由用户自行按 `⌘V`。`⌘C` 复制所选原始表示并提升历史，但保持窗口；Delete 删除，Esc 先清搜索再关闭。历史、原始负载和预览不进仓库，也不做云端或跨设备同步。
- 输入法核心设置只保留「输入方案」「词库」，不再显示「键入模式」。普通方案包括雾凇全拼、自然码双拼、小鹤双拼、五笔86和英文。`builtin.fly-chord-learning` 保留为兼容用内部 ID，对外显示为「并击」2.0 扩展，并提供设置、课程、练习、进度四页；扩展开关统一控制普通输入与意识流输入的并击能力。扩展启用时，意识流输入可把并击键序转换为连续全拼；停用时仍可使用顺序全拼。
- Buffer 当前只展示 AI 生成 2.1、实时翻译 2.1 和意识流输入 1.3。Capsule 不再属于 Buffer 插件目录；Mailbox 也不属于 Buffer 生命周期，只有用户明确触发时才通过桥接把内容送到 Buffer。My Prompt、Remarkable 与 Marine Chrome 不再进入当前目录、配置或模式列表。
- Buffer 结果数量契约为 1–5 项，当前设计默认 5 项，并使用轨道内 pager 切换。
- Buffer 设计母版固定为 760pt 宽，当前不要求响应式缩放。
- AI 等模式可以采用 single-exchange：输入轨在视觉上切换为结果轨。但宿主确认发送成功前，必须同时保留源内容与结果状态；请求或投递失败不得丢失它们。
- Buffer 工具栏常显，不可折叠：普通/source-only/target-only 为 78pt，live source + target 为 112pt。源轨只保留一个插件图标，不再作为展开/收起开关。回传框的复制按钮在结果文字左侧。工具栏承载插件选择、当前插件配置、返回编辑、状态与关闭。目标轨不显示角色图标。
- 工具栏空白 chrome、状态、间距和弹性留白是拖窗区；下拉、配置、返回、关闭等控件保持首击交互。正文轨、窗口背景和尾部动作不可拖，右侧不保留 24pt 专用拖动条。进度、安全输入、失败或投递反馈只显示一次：活动轨优先，工具栏状态仅作后备。
- Buffer 主操作固定为 22×22 纯图标按钮，不显示“发送/生成”等可见文字；完整动作和进度文案保留在无障碍标签与 tooltip 中，图标随状态切换。
- 每条当前生成结果固定提供复制按钮。它只把当前选中的生成结果写入本机剪贴板，成功后关闭 Buffer；不会复制保留的源正文，也不会放行过期结果。
- 主题采用两级模型：经典包含墨竹、翡翠、静谧三配色；拉斯塔为独立主题，并以完整语义 token 同时使用红、黄、绿三种品牌色。

受控宿主接入 `BufferSurface` 时，生成结果必须原样回传 `onGenerate` 给出的 `requestID` 与 `contextKey`，并让 `activeRequestID` 指向当前结果；宿主还应响应生成和发送回调中的 `AbortSignal`。发送回调只有明确返回 `true` 才表示投递成功，其余返回值或异常都保留结果供重试。

以上是 `design/react-system` 分支的 React 设计契约。后续调整必须让 React 设计源与 AppKit 实现同时遵守 1–5 项 pager、常显工具栏 78/112pt 几何、工具栏拖动边界、状态单一承载、回传框左侧固定复制动作和 22×22 主操作；Clipboard 母版也必须呈现真实图片预览与来源 App 图标。

## 代码结构

```text
src/
  App.tsx                         设计工作台与 Inspector
  design-system/
    Icon.tsx                      Phosphor 语义图标适配器
    data.ts                       场景与插件 fixture
    primitives.tsx               共享基础控件
    tokens/
      themes.json                 主题与几何单一来源
      index.ts                    CSS 变量与导出工具
  surfaces/
    SettingsSurface.tsx
    ExtensionsSurface.tsx
    CandidateSurface.tsx
    BufferSurface.tsx
    ClipboardSurface.tsx
  styles.css                      工作台与基础控件
  surface-styles.css              五个产品界面
generated/
  RimeDesignTokens.generated.swift
```

`themes.json` 保留原生 `RimeUI.swift` 的主题语义，并增加 `themeFamilies` 与 `brandRed / brandYellow / brandGreen`。经典主题下，墨竹、翡翠延续产品绿，静谧使用中性强调色；拉斯塔在同一套完整语义角色上同时组织红、黄、绿。填充（`accent`）与可读状态文字（`accentText`）仍是两个独立 token；设置页背景、Buffer 轨道/块、剪贴板选中态以及 warning/danger 也不能互相借色。`1 CSS px = 1 macOS logical pt`，候选框、Buffer 和设置窗口的基准尺寸与原生实现保持一致。

## Token 迁移到 Swift

修改 `src/design-system/tokens/themes.json` 后运行：

```bash
npm run tokens:swift
```

它会更新 `generated/RimeDesignTokens.generated.swift`。生成文件只是设计评审产物；合入原生目标前仍应人工核对对比度、AppKit 动态外观、窗口行为及现有 `RimeUI` 兼容性。

## 设计边界

- React 负责视觉语言、组件状态和交互提案。
- AppKit / InputMethodKit 继续负责输入焦点、候选窗口、文本投递、跨 Space 行为和安全边界。
- Buffer 与 Clipboard 是两个独立窗口。Clipboard 的 React 母版只模拟交互；原生端仍以 nonactivating panel 保存宿主焦点，并在激活文本/链接前重验 exact `FocusToken`，再通过 IMK `Delivery.insert` 上屏。图片、RTF、HTML、文件等富内容只恢复原始 pasteboard、提升历史并关闭窗口，等待用户自行按 `⌘V`。Clipboard 绝不自动调用 Paste、右键或合成 `⌘V`，也不使用 Accessibility/Post Event。
- 右上角输入源菜单在原生端由 macOS `NSMenu` 绘制；这里的实现用于内容结构与交互讨论，不承诺像素级替换系统菜单。
