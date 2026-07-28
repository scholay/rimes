# RIMES · 缓冲工作台（Workbench）产品方案与架构设计

版本：v0.3 决策更新 · 2026-07-19
状态：长期路线图；缓冲窗口部分已实现

> **2026-07-19 缓冲插件决策（覆盖本文旧 Processor/MarineBridge 描述）**：外部缓冲插件由通用 HTTP Action Plugin 宿主从 `~/Library/RimeBuffer/plugins/*/manifest.json` 动态加载；Marine 是首个实现。苹果本地翻译不伪装成 HTTP 插件，而是内置 `.bufferAction`，但与 Marine 在同一缓冲插件列表和唯一 owner 下互斥。用户调用外部动作时冻结 request/context/focus，匹配结果直接进缓冲，失效结果进收件箱，两者都不自动上屏。旧 `MarineBridge` 源码暂留但已从 focus 主路径解除。
上游输入：`new-rime.pen` 七张探索稿（wBwdM/XKzFo/e9aJFL/FBS3A/rulod/BMbRV/S0d7w）+ 产品负责人 2026-07-16 口头需求收敛
关系：本文档记录工作台路线与历史裁决；`new-rime.pen` 是视觉参考；`ARCHITECTURE.md` 是 P1 时代交接文档。运行时事实与本文冲突时以 `SYSTEM-ARCHITECTURE.md` 为准。

> 2026-07-17 早期决策（已被下一条覆盖）：缓冲区从候选 panel 拆成独立工作台，曾采用内嵌候选投影、全文预览与发送后留块方案。
>
> **2026-07-28 工作台工具栏覆盖决策（当前）**：顶部功能栏永久展开；主条只保留缓冲轨与右侧主操作，不再显示左侧拖拽手柄或展开/收起按钮。功能栏空白、间距与弹性留白可拖动窗口，按钮、下拉框、状态控件和正文轨保持原有交互且不能拖窗。普通工作台固定为 78pt，1/2/3 个 target rows 固定为 112/143/174pt；旧折叠偏好静默忽略，frame、pin 和候选锚点继续持久化。本文后续所有 44pt 折叠、drag handle、disclosure 和展开态持久化描述均为历史方案。
>
> **2026-07-22 简化工作台覆盖决策（被 2026-07-28 工具栏决策部分覆盖）**：刷新/重置始终保留缓冲正文：对外部插件取消过时任务并重新探测上下文，对内置派生工作区保留源文并重启 generation。工作台不再提供块编辑器或面板内缓冲开关；底层缓冲启停、pin 和移屏仍从设置或输入法菜单进入。手动遮蔽、历史/恢复、清空/撤销已移除。缓冲模式继续复用常规 `CandidateWindow` 作为唯一 Rime 组字候选面板；意识流 target rows 不是 Rime 候选投影。普通/Shift+Return 与 Backspace 保持宿主隔离，Return 轻按逐块、长按批量，纸飞机每次只发送下一块。单独且小于 500 ms 的 Shift 轻点才切换中英；与字母/标点组合或长按后保持按下前模式。成功发送的 block 立即从 live buffer 消失且不保留明文历史，失败和未发送 block 原位保留。本文后续若仍描述“Rime 候选投影 / 全文预览 / 已发送对号留块”，均视为历史方案。

> **2026-07-19 本地翻译覆盖决策（UI 部分由 2026-07-28 覆盖）**：苹果翻译已作为只出现在缓冲插件列表的内置 `.bufferAction` 落地，与 Marine 共用唯一 owner。源文复用 `BufferModel`，在上方连续轨合并显示且不分 block；译文位于下方独立 `AppleTranslationWorkspace` 分块轨，两轨分别横向滚动。当前翻译态固定为 112pt，顶部功能栏常显并提供空白拖动，发送按钮对齐下方目标语言行。仅完成且 generation 匹配的译文可由统一投递协调器手动发送。框架保持 macOS 13 最低版本，macOS 15+ 通过工作台内的 SwiftUI `translationTask` 弱链接桥接本地语言模型。本文后续将 Translation 标记为“计划”或描述无头 initializer 的内容均已被此决策覆盖。
>
> **2026-07-23 AI 插件/连接器覆盖决策（当前）**：内置 `.bufferAction` 已收敛为唯一「AI 生成」插件；Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 是“连接器 › AI 模型”中的三个独立可切换模型源。当外部 owner 的整个动作面只有一个 prepared presentation 时，它与内置 AI 共用主生成控件，展开层不再放独立“生成”按钮；主条右侧控件以 AI 图标/转圈/纸飞机表达不可请求、可请求、生成中和可投递。Return 与它共用同一状态：无结果时请求 AI，ready 后的新一次轻按逐块发送、长按全部发送。Marine 仍以 `presentationId` 合并直评/回复并按 `status.actionId` 选择真实动作；若还存在任意第二个 presentation，则全部保留为显式按钮而不让 Return 猜测。内置生成冻结当前缓冲全文，在下方 target rail 以稳定 block 原位更新；只有目标块全部成功发送后才消费上方对应 source blocks。两轨角色使用图标，不再显示“原/答”文字。

> **2026-07-22 全量捕获与强制分块决策（当前）**：缓冲持久开启后，ASCII/英文模式下 librime 未处理的可打印字母、数字、空格和普通标点也必须进入缓冲，只有快捷键、自有输入框、失效焦点与 secure input 例外；逐键英文在同一焦点内合并为短词组块并保留逐字退格。AI、苹果翻译、意识流所选候选、Action/Marine 的流式快照与最终结果统一由宿主细分，英文按完整单词/短词组，中文按句、分句和有界长度；不得把单个粗糙上游块当成一次性大段投递。上游 block 仍是硬边界，Action 子块完整继承原插件权限；轻按 Return/纸飞机逐块，长按 Return 才发送全部。

> **2026-07-26 意识流配置隔离、并击/互击与候选交互（当前）**：选择意识流输入不得修改 `InputConfigurationStore` 或重部署 Rime schema。串击与双拼把物理 `a-z` 逐字写成连续全拼 raw；显式 `.chord`/`.mutual` 都按 `ChordSettings.duration` 聚合物理批次并使用当前有效部署的 `my_combo` 映射为全拼。并击只结算当前批；互击还允许紧邻的左侧声母批与右侧韵母批在 exact raw/soft-offset 快照仍一致且至少一侧为多键时回滚重组。只有完整音节映射自动追加真实 ASCII Space；`dv→n`、`km→ong` 等尚未配对的单侧映射先转成拼音片段但不追加，以便后续补全。单键字母不追加，两个单键批不重组，单独 `,`/`.` 不写 raw，无映射多键批保留确定性字母原码且不追加。自动 Space 是 sidecar 标记的 soft syllable boundary：上轨显示普通空格、参与拼音提示，但不立即推断、不显示 `·`、不增加候选的最小投递块数；物理 Space 是 hard phrase boundary，会立即推断并显示 `·`，紧跟自动 Space 时原位提升而不重复插入。第一枚待结算键即撤销旧候选的投递权；非和弦边界、焦点、secure input、插件或配置变化会取消批次与互击配对。模型的 1–3 个完整候选逐行显示，对应工作台 1/2/3 target rows 的动态高度，每行内部再由宿主细分为可投递 block；新增 target row 前先扩展 panel/rail，移除旧 row 后再缩小，普通 Rime 三行候选矩阵也先准备最终 viewport/document 几何再挂行。只有 hard Space 子句数建立最小分块目标，宿主只在不会切断英文单词、URL、代码、数字或引文时补拆。无修饰 ↑/↓ 或数字切换，Return/纸飞机在首个实际投递前确认当前项并淘汰其他项，同一次 Return 轻按继续发送下一块、长按发送所选答案的全部剩余块。raw 不在确认或首块投递时自动清除，而在最后一块成功后清除；若已发一块后继续输入字母或 Space，则丢弃未发尾部并开启全新 raw，已发送前缀不能在下一轮重新出现。

> **2026-07-22 全选/粘贴覆盖决策（当前）**：缓冲开启时，精确 `Control+A`/`Command+A` 与 `Control+V`/`Command+V` 作为工作台 source 编辑命令，适用于普通缓冲与所有插件。非意识流模式全选 `BufferModel` 全部 source blocks，粘贴在块光标插入或替换全选，保留精确连接文本并用共享宿主分块器建立 chips。意识流只编辑 raw 上轨：粘贴只允许 ASCII 字母与空白，字母转小写、空白归一为 Space，非法字符或归一化后总 raw 超 16 KiB 时原子保留原状态。普通粘贴只接受非空、无 NUL、至多 1 MiB 的纯文本。只有单一 Control 或 Command 修饰才接管；额外 Shift/Option、Control+Command 和自有窗口保留原生语义。secure input 下 RIMES 在读取剪贴板前就放行宿主；焦点不可信时则只吞键且不读取。粘贴在读取前和延迟 pasteboard provider 返回后均重验同一 `FocusToken`。

---

## 0. 一句话定位

把 RIMES 从「Rime 提交的暂存队列」升级为**上屏前的文本工作台与插件宿主**：当前本地打字、已接受的 MCP/HTTP 内容、用户主动请求的 Action Plugin 结果、苹果本地翻译与唯一「AI 生成」插件可进入工作台，经人工确认后投递；AI 插件使用三个可切换模型连接器之一。SSE/SSH 和工作台内传入轨是后续路线图。配对设备保留既有加密直通，是不进入工作台的明确例外。

产品负责人拍定的六条需求（本方案的边界即由此划定）：

1. 缓冲区模式新定义：**中间是缓冲区，下方是本地打字候选词区，上方是外部数据源**
2. 本地智能体用 **MCP** 把文字传给输入法
3. 输入法**内置翻译**
4. 输入法可通过 **SSE / SSH / HTTP** 从外部获取文字
5. 输入法**内置 AI 能力**
6. 设备间传字（隔空传字）保留；后续产品决策将其定为**加密直通例外**，不统一进工作台（见 §12.1）

### 0.1 明确不做（v1 边界）

| 砍掉 | 理由 |
|---|---|
| 自动/隐式剪贴板捕获 | 仍明确不做；只有用户显式按精确 Ctrl/Cmd+V 才允许工作台在非 secure、精确外部租约下读取一次，secure input 下绝不读取 |
| AirDrop 投递目标 | 不在需求清单里；延后 |
| Turn/Artifact 完整版本模型（revision/derivedFrom/分叉） | 探索稿里最贵的部分；v1 用「结果块」轻量替代，版本化留给需求被验证之后 |
| 投递撤回（revoke） | 依赖版本模型与协议大改；延后 |
| 工作台内块编辑 / 无边界自由编辑面 / diff reconcile | 不恢复旧 TextView 的自动切块与差分；chip 只被动呈现，不再提供单块编辑器 |
| 「实时镜像」预设 | 探索稿自己标注"高级预设；默认关闭"；v1 由投递目标开关覆盖此语义 |

---

## 1. 产品定义

### 1.1 独立缓冲工作台（缓冲模式主交互面）

下图是三轨产品路线的历史结构参考；当前顶部功能栏常显，普通运行时固定为 78pt，派生模式按 1–3 个 target rows 使用 112/143/174pt 并向上增高。Rime 组字候选使用工作台底边下方的常规候选窗，传入轨仍由独立收件箱承载。

```
┌────────────────────────────────────────────────┐
│ ① 传入轨  MCP·Claude ⋯ HTTP脚本  待接收 3         │  ← 外部数据源（后续嵌入）
├────────────────────────────────────────────────┤
│ ② 缓冲轨  [朋友][晚点][shij|] 翻译1.2s ⏹ ➤ ⤢    │  ← 缓冲区（升级）
├────────────────────────────────────────────────┤
│ ③ 候选区  1.时间 2.实践 3.事件 …                 │  ← 本地打字（现状保留）
└────────────────────────────────────────────────┘
```

实现载体：`BufferWindowController` 拥有独立 `nonactivatingPanel`。顶部功能栏常显，内容是状态 → 带小图标的缓冲插件选择器与当前动作 → 弹性空白 → 刷新/重置 → 关闭；空白、间距与弹性留白通过 `performDrag` 移动窗口，所有 `NSControl` 保持首击。主条只保留 `BufferInlineView` → 右侧主操作。普通布局固定 78pt；苹果翻译、AI 生成与单候选意识流固定为 112pt 的 source + target 布局；意识流出现 2/3 个候选时增加 1/2 条 target row，高度为 143/174pt。设置页可独立开启多个缓冲插件；选择器只枚举已开启集合，以 `Default` 表示无插件，并直接切换唯一 owner。刷新/重置不清除缓冲正文，只重置当前插件的请求、失败与 generation。切换 owner/target row 数时保持窗口底边不动，因此条下方 Rime 候选锚点稳定。`Command+Shift+B` 通过全局 Carbon hot key 调用 `toggleVisibility()`：关闭时显示并恢复捕获，打开时复用普通关闭语义，收束当前组字、保留内容并暂停捕获。窗口仍可调整宽度、关闭、固定到所有桌面/全屏空间，frame 持久化并在多屏变化后校正。`CandidateWindow` 继续独占 Rime 组字候选状态；意识流互斥解释在 target rows 内呈现。发送对齐最下方 target 行。

各层职责：

- **① 传入轨（后续）**：当前外部待决项仍在 `InboundTrayWindow` 接受/拒绝，异步来源不得自行拉起工作台。未来可作为工作台内固定高度区域加入。
- **② 缓冲轨（已实现基础）**：主条显示待发送块 chips、来源徽标、插入点、Enter 长按进度和右侧纸飞机；轻按 Enter 或点击纸飞机发送下一块，按住 Enter 约 1.2 秒发送全部。成功发送后 block 从 live rail 消失且不保存历史；失败和未发送 block 保留。
- **③ 候选区（已实现常规面板复用）**：候选、preedit、矩阵/单字选择始终由同一个 `CandidateWindow` 呈现；缓冲模式只把锚点移到细条下方，任何点击仍必须携带当前 `FocusToken`，过期动作无效。
- **块交互与隐私（已实现）**：缓冲 chip 是被动呈现单元，不可点选后编辑；被动工作台不抢外部焦点。工作台没有手动遮蔽，保留 secure-input 自动遮蔽与会话锁定隐藏。

### 1.2 用户故事（验收场景）

1. **打字暂存**（现状不回归）：缓冲模式下打字 → 常规候选窗显示在细条下方 → commit 成块。有未决组字时，本次普通/Shift+Return 只收束为块；没有组字时，Return keyDown 建立隔离，轻按发送下一块、按住约 1.2 秒发送全部。Backspace 只编辑 Rime/缓冲；两个键在任何引擎/焦点状态下都绝不影响宿主文本框。焦点不可信时只吞不投递；引擎故障但没有未决组字时，已有块仍可发送。发送目标只认 Return keyDown 绑定且当前仍有效的精确焦点；成功块立即离开 live rail。
2. **智能体推稿**：Claude Code / Codex 通过 MCP 调 `buffer_push` → 当前由专用 toast/`InboundTrayWindow` 显示「MCP · <来源名>」待决项 → 用户点接受 → 成为带来源徽标的块 → 轻按 Enter 或点击主条纸飞机逐块发送，长按 Enter 才发送全部。传入轨嵌入工作台是后续 UI 路线图。
3. **翻译**：打开「苹果本地翻译」唯一 owner → 上方原文轨连续展示当前缓冲全文 → 输入节流后译文以下方独立 blocks 更新 → 仅 generation 完全匹配时，用户才能用 Enter 手势或对齐目标语言行的纸飞机手动发送译文。
4. **AI 生成**：在工作台选择「AI 生成」插件，并选定连接器 → 有源文时右侧 AI 图标亮起 → 点它或按 Return 冻结当前缓冲全文 → 主按钮转圈，下轨显示安全活动摘要和流式 block → final 就绪后主按钮变为纸飞机。新一次轻按 Return/点击纸飞机发送下一块，长按 Return 发送全部；只有最后一个 target 成功后才消费对应 source blocks。
5. **全选/粘贴 source**：在任一普通或插件 owner 下按精确 Ctrl/Cmd+A 全选当前 source，Ctrl/Cmd+V 替换全选或在块光标插入。翻译、AI、Action/Marine 与普通缓冲都操作 `BufferModel`；意识流只操作 raw 上轨，候选行不被选中。含中文/数字/标点的意识流粘贴整次拒绝而不丢前后文；secure input 下保留宿主粘贴且 RIMES 不读剪贴板。
6. **隔空传字（收）**：配对 Mac 发来文字 → 沿既有加密直通路径上屏；若当前没有可用目标则累积到剪贴板。该产品例外不进入缓冲或传入轨（§12.1）。
7. **安全底线**：焦点在密码框（系统 secure input 生效）时，工作台遮蔽且发送被 `Delivery.insert` 拒绝，缓冲区任何内容不会被投递，输入法也不读剪贴板。当前收件箱的「接受」只把条目放进缓冲，因此不禁用也不显示锁标。

### 1.3 交互不变量（安全叙事，恒真，不做成开关）

- **非配对外部文字按当前固定门控进入收件箱或缓冲**：MCP/HTTP/SSE/SSH 为「询问」，Marine 为「信任」；无论哪一种都**永不**自动上屏。按来源自定义信任是后续能力；配对设备维持直通例外。
- **一切处理器结果先回缓冲区成为结果块**，绝不直接上屏。
- **缓冲内容、非配对外部文字与未来处理器结果只由用户明确触发上屏**：没有未决组字时，普通/Shift+Return 轻按发送下一块、按住约 1.2 秒发送全部；主条右侧纸飞机每次只发送下一块。有未决组字的 Return 只收束为块，同一物理按键绝不顺带投递。缓冲关闭时的普通 Rime commit，以及配对设备的既有直通收字，是明确例外。
- **secure input 激活时投递路径整体禁用**。

---

## 2. 领域模型

拆掉「Block 既是位置又是内容」的混合体，但只拆到 v1 需要的粒度：

```swift
/// 文字从哪来。既驱动 UI 徽标，也驱动 echo 防回环与门控。
enum Origin: Equatable, Codable {
    case rime                          // 本地打字（无徽标）
    case mcp(client: String)           // MCP 客户端自报名；不可验证，仅展示
    case http(source: String)
    case sse(feed: String)
    case ssh(host: String)
    case remotePeer(deviceID: String)  // 配对 Mac
    case marine                        // 旧兼容来源
    case plugin(id: String)             // 用户主动调用的 Action Plugin
    case processor(id: String, allowsRemoteMirror: Bool) // 可信内置翻译/AI 派生块
}

/// 缓冲区的一个块。position 由数组顺序表达，内容与来源在块内。
struct Chunk: Identifiable {
    let id: UUID
    var text: String
    let origin: Origin
    let createdAt: Date
    var pluginMetadata: PluginMetadata? // Action Plugin 目标绑定与 review 状态
}

/// 传入轨上的待决条目。
struct InboundItem: Identifiable {
    let id: UUID
    let origin: Origin
    var title: String?                 // 来源可自带标题（如 Marine 的 kind）
    var text: String
    var streaming: Bool                // SSE/MCP 流式条目：text 原位更新
    var state: State = .pending
    enum State { case pending, accepted, rejected }
}

/// 一次显式 AI 生成；target blocks 留在独立 workspace。
struct AITextGeneration {
    let generation: UInt64
    let requestID: UUID
    let sourceText: String              // 当前缓冲全文冻结
    let sourceBlockIDs: [UUID]
}

/// 当前实现不定义 DeliveryRecord：IMK 接受 insertText 后，成功块立即从
/// live buffer 消费，不保留可恢复的明文发送快照。

// [M5 路线图，当前不存在]
// messageID / DeliveryTarget / inserted|acked|failed / 远端 ACK / 持久账本
```

设计要点：

- **`Origin` 是这次重构的第一等公民**。它同时解决三件事：UI 来源徽标、echo 防回环（§6.3）、来源门控（§4.4）。探索稿里 Marine `Draft.kind` 在入口被丢弃的 bug 由 `InboundItem.title` 承接。
- **Action Plugin 结果是 Chunk/Block**；翻译/AI 结果先留在独立 target workspace，由统一投递源接口暴露，不需要 ArtifactStore。
- **`sourceText + sourceBlockIDs` 即轻量版「Turn 冻结」**：任一边发生变化都作废旧 generation，不引入显式 Turn 实体。

---

## 3. 总体架构

```
                       ┌────────────────────────────────────────────────┐
 外部世界               │          RIMES 进程（内部 ETInput）               │
                       │                                                │
 Claude/Codex ──MCP──▶ LocalGateway ─┐                                  │
 curl/脚本 ──HTTP────▶ (127.0.0.1)   ├─▶ InboundBus ─▶ 收件箱 UI         │
 [计划]服务器 ─SSE────▶ SSEProvider ──┤                    │ 接受         │
 [计划]远程主机 ─SSH──▶ SSHProvider ──┘                    ▼              │
 Action Plugin manifest ─▶ ActionPluginHost ─本机 Bearer HTTP─▶ BufferModel │
                                                    └失效────▶ InboundBus   │
                       │                           │ Enter手势/主条纸飞机 │
                       │                                  ▼               │
                       │                       BufferDeliveryCoordinator  │
                       │                                  │               │
                       │                           Delivery.insert         │
                       │                                  ▼               │
                       │                              当前输入框            │
 配对Mac ◀─AES-GCM───▶ RemoteTypingService ─▶ 直通 Delivery.insert        │
                       │                     └─无目标→剪贴板累积            │
 Apple 翻译 ──────────▶ AppleTranslationWorkspace ──独立 target rail─┐ │
 Codex/Claude/OpenAI 兼容 API ─▶ AITextPluginWorkspace ──独立 target rail──┘ │
 [计划] 多目标/ACK─────▶ DeliveryRouter（M5；当前不存在）                   │
                       └────────────────────────────────────────────────┘
```

### 3.1 模块与文件规划

| 模块 | 新/改 | 文件 | 职责 |
|---|---|---|---|
| BufferModel | 已实现 | `BufferModel.swift` | live blocks、插入点、成功消费、transient 状态；不留发送历史 |
| InboundBus | 已实现 | `Inbound/InboundBus.swift` | 汇聚当前 MCP/HTTP，执行固定门控，产出 InboundItem |
| SourceProvider 协议 | [计划] | `Inbound/SourceProvider.swift` | 未来 provider 的 `start()/stop()`、事件回调、健康状态 |
| LocalGateway + MCP | 已实现 | `Inbound/LocalGateway.swift` | 本地 HTTP 服务器；stateless MCP POST + HTTP push + health |
| Action Plugin Host | 已实现 | `ActionPlugins.swift` | manifest/runtime config、动态动作、本机 Bearer HTTP、请求冻结及结果安全分流 |
| Action Plugin Manager | 已实现 | `ActionPluginManager.swift` | 事务化本地安装、HTTPS 清单下载、启用/禁用、卸载、fail-closed 状态与宿主热重载 |
| Unified Plugin Registry | 已实现 | `PluginPlatform.swift` | 以 domain 隔离外部缓冲插件与编译期内置扩展；统一发现/启停，不接管 Action Plugin 执行 authority |
| Built-in Extensions | 已实现 | `BuiltInPlugins.swift` | 统计、打字测速、飞耀互击学习；可贡献动态设置页和脱敏本地能力 |
| SSEClientProvider | [计划] | `Inbound/SSEClient.swift` | 订阅外部 SSE URL |
| SSHProvider | [计划] | `Inbound/SSHProvider.swift` | `/usr/bin/ssh` 子进程流式读取 |
| RemoteTypingService | 已实现、保持直通 | `Remote/RemoteTypingService.swift` | 配对设备加密直通；不进入 InboundBus |
| MarineBridge | 仅留源码 | `MarineBridge.swift` | 旧轮询兼容实现；focus 主路径不再调用，新插件链路不依赖它 |
| Apple Translation Workspace | 已实现 | `AppleTranslationPlugin.swift` | macOS 15+ 本地翻译、上原文/下译文双缓冲与 SwiftUI session 桥 |
| AI Text Workspace + Providers | 已实现 | `AITextPlugins.swift` | Codex/Claude CLI、OpenAI 兼容 API、显式生成、稳定流式 block、source/target 投递与 0600 配置 |
| Global Workbench Hot Key | 已实现 | `GlobalHotKeyController.swift` | Carbon `Command+Shift+B` 切换工作台显隐与捕获状态 |
| FocusCoordinator | 新（已实现） | `InputFocusCoordinator.swift` | FocusToken、client 租约、前台与对象身份校验 |
| BufferDeliveryCoordinator | 新（已实现） | `BufferDeliveryCoordinator.swift` | 逐块复核目标、成功块无历史消费、失败后缀保留 |
| DeliveryRouter | 后续 | `Delivery.swift` → `Delivery/DeliveryRouter.swift` | 多目标、远端 ACK、持久账本 |
| 独立工作台 | 新（已实现） | `BufferWindowController.swift` + `BufferInlineView.swift` | 常显工具栏空白拖动；普通78pt；1–3 target rows为112/143/174pt；source全选、多行target、插件动作/刷新/关闭/多屏/安全遮蔽 |
| 候选状态机 | 改（已实现） | `CandidateWindow.swift` | 同一个常规 panel 锚定 caret 或缓冲条下方 |
| 设置窗 | 新 IA 已实现 | `SettingsWindow.swift` + `SettingsRouting.swift` | 左侧一级导航、右侧横向子页、动态内置扩展页；含真实插件管理 |

### 3.2 并发模型（现有代码最硬的墙，正面拆）

现状：IMKit client 始终留在主线程；`BufferDeliveryCoordinator` 同步逐块投递，并在每块前复核 `FocusToken`、组字和 secure-input 状态。`BufferModel` 不再持有 deliver 闭包。

拆法（三条规则，不引入第四条）：

1. **UI 与 IMK 全部 `@MainActor`**。BufferCore、InboundBus 的对外表面是 main-actor 的——IMKit 回调、NSPanel 渲染本来就在主线程，维持现状最省事也最不容易错。
2. **Provider 不持有 IMK 对象**。Apple Translation task、CLI `Process` 与 OpenAI 兼容 API `URLSession` 只接收冻结的值类型 source snapshot；回调切回主线程，再用 workspace generation/source block IDs 拒绝迟到结果。每个 AI workspace 同时只有一个任务，取消会终止子进程或网络请求。
3. **投递保持串行化**。派生结果先留在独立 target workspace；`BufferDeliveryCoordinator` 逐块重验 workspace/generation/id、FocusToken 与 secure input，成功后消费该 target block。只有 target 全部送完时才一次性消费对应 source blocks。

Provider 侧：当前 LocalGateway 持有独立 NW 队列并切回主线程调用 `InboundBus`；未来 SSE/SSH provider 也必须遵守同一边界。

---

## 4. 来源层（需求 2、4、6）

### 4.1 LocalGateway：当前 stateless MCP + HTTP push

当前一个监听器绑定 `127.0.0.1:47700`（可配置），基于 Network.framework `NWListener` 手写极简 HTTP/1.1。响应使用 `Content-Length` 并保持 keep-alive；**没有 chunked 响应、MCP SSE 下行流或可删除的 MCP session**。MCP 采用 stateless Streamable HTTP：每次 `POST /mcp` 返回一个 JSON 响应。SSE 订阅是后续独立 provider，不是当前 LocalGateway 的第三种协议。

除公开健康检查外，端点要求 `Authorization: Bearer <token>`。token 生成后写入 `~/Library/RimeBuffer/gateway-token`（0600，与 RemoteIdentity 的既有决策一致——**不用 Keychain**，因为 ad-hoc 签名下 Keychain ACL 每次重装都会弹窗；拿到 Developer ID 正式签名后再评估迁移）。当前设置页可复制 token、MCP 配置和 curl 命令，但**没有重新生成 token 的 UI**。

端点：

```
POST /mcp                    MCP streamable HTTP（初始化/工具调用/通知）
POST /v1/inbound             裸 HTTP push：{text, title?, source?}
GET  /v1/health              健康检查（无鉴权，当前返回 {"ok":true}）
GET/DELETE /mcp              当前明确返回 405，Allow: POST
```

### 4.2 MCP tools（面向 Claude Code / Codex 等本地智能体）

```
buffer_push(text, title?)               → 确认文本      推一条待决条目到收件箱
buffer_stream_begin(title?)             → {stream_id} 开一个流式条目（占位卡片）
buffer_stream_append(stream_id, delta)  → 确认文本      原位追加文字（不产生新条目）
buffer_stream_end(stream_id)            → 确认文本      标记完成，条目变为可接受
```

刻意**不提供**：读取用户缓冲区内容、读取当前输入框上下文、触发投递的任何工具。智能体只能「给」，不能「看」不能「发」——这是隐私边界，写死，不做开关。

客户端接入（写进 README）：

```bash
claude mcp add --transport http etinput http://127.0.0.1:47700/mcp \
  --header "Authorization: Bearer $(cat ~/Library/RimeBuffer/gateway-token)"
```

### 4.3 其余 provider

| Provider | 形态 | v1 范围 |
|---|---|---|
| **HTTPProvider** | 被动收 `POST /v1/inbound`（脚本/curl 场景） | 与 MCP 共用 LocalGateway 与门控 |
| **SSEClientProvider** | [计划] 主动订阅用户配置的 URL 列表；流式进入 InboundBus | 当前只有设置页未来标签，尚无实现 |
| **SSHProvider** | [计划] `Process` 跑 `/usr/bin/ssh <host> <command>`，stdout 流式进条目 | 当前只有设置页未来标签；未来认证依赖用户 `~/.ssh` 与 ssh-agent |
| **RemoteTypingService** | 现有 X25519+AES-GCM 通道，入站继续直接 `insertRemoteText` | 不进 InboundBus；无安全目标时由 main.swift 累积到剪贴板；协议 v2 推迟 |
| **Action Plugin** | 用户主动点动作；有效结果进 Buffer，失效结果进 InboundBus | ✅ 通用宿主已实现；具体插件独立安装 |
| **MarineBridge** | 旧轮询源码仍在但已解除 focus 调用 | 仅兼容存档，新链路不得依赖 |

### 4.4 来源门控（传入轨的准入策略）

`SourceTrust` 类型包含三档，但**当前没有按来源配置或 UserDefaults 覆盖**。`InboundBus.trust(for:)` 的固定规则是：Marine=`trusted`；MCP/HTTP/SSE/SSH=`ask`；Rime/RemotePeer 若误入总线也按 `ask` 处理。

| 等级 | 行为 |
|---|---|
| **询问**（默认） | 条目进传入轨待决，用户逐条接受/拒绝 |
| **信任** | 条目直接进缓冲区成为块（仍绝不自动上屏，§1.3 不变量兜底） |
| **拦截** | 丢弃；当前没有设置入口，也没有“计数器闪一下”的 UI |

无有效 token 的请求在 HTTP 层直接 401，不进任何 UI。MCP 客户端名只存在于当前连接内，是未经验证的自报展示名；它不与全局 token 建立身份绑定。

**[后续路线图]** 若加入来源设置页，再把三档选择持久化到 UserDefaults，并为 blocked 提示设计明确 UI；在此之前不得把它们写成现有保证。

---

## 5. 处理器层（需求 3、5）

### 5.1 派生 source/target workspace 契约

- 用户显式点击“生成”时，`AITextPluginWorkspace` 冻结当前 `BufferModel.stagedText` 与 source block IDs。源文仍属于 `BufferModel`，上方 source rail 只是连续投影；结果存在 workspace 的下方 target rail，不会悄悄改写原 block。
- 流式边界是“逻辑 block 快照”，不是 token。provider 可重复更新同一 index；workspace 对每个 `(providerIndex, childIndex)` 宿主子块保留稳定 UUID，最终结构化 blocks 替换未完成快照而不产生逐字碎块。英文 transport token 不直接成为 block；宿主只在完整单词/短词组或语义标点处封口。
- 每个 workspace 同时一个 job。源文/block IDs 变化、切 owner、secure input、关闭或刷新会取消任务并提升 generation，迟到回调不能恢复旧结果。失败只更新 workspace 状态，原文不受损。
- 只有完成且仍匹配 source/generation 的 target blocks 可经 `BufferDeliveryCoordinator` 发送。部分投递时已成功 target 从下轨消失，失败与未发后缀保留；上轨 source blocks 在最后一个 target 成功后才一次性消费。
- 未 review 的 Action Plugin 目标绑定 block 不允许作为翻译/AI 源，避免把原 runtime/context/focus 权限洗成普通 `.processor` 块。

### 5.2 Apple Translation Workspace（内置翻译）

- **Apple Translation framework**（macOS 15+）已通过工作台内 1×1 `NSHostingView` 的 SwiftUI `translationTask` 桥接；`TranslationSession` 只在该视图生命周期内使用。`LSMinimumSystemVersion` 仍为 13.0，13/14 只呈现不可用状态。
- `AppleTranslationWorkspace` 读取当前 `BufferModel.stagedText`：原文在上方连续轨合并显示，译文在下方独立分块轨显示，两轨各自横向滚动。
- 输入停顿 300ms 后启动翻译，持续输入最长等待 900ms；运行中只排队最新快照。只有原文、语言与 generation 全部匹配的完整译文可发送。
- 顶部功能栏的刷新/重置保留原文，作废当前译文 generation 并重启当前语言组合；功能栏空白可拖动窗口，发送对齐目标语言行。

### 5.3 单一 AI 文本缓冲插件与三个连接器（已实现）

- **统一插件**：`AITextInternalPlugin` 是唯一占用缓冲插件 owner 的「AI 生成」入口，`AITextConnectorSelectionStore` 单独持久化当前模型源；切换连接器不会变成另一个插件，也不会改写其他缓冲插件的 owner。
- **Codex CLI 连接器**：显式 `RIMEBUFFER_CODEX_PATH` 仍是最高优先级；普通自动探测则优先 ChatGPT app bundled Codex，再查找 Homebrew、用户 PATH、常见版本管理器、nvm/fnm 与 Cursor/VS Code 扩展内置安装。它用一次性 app-server 的双向 stdio JSON-RPC 接收 answer delta。专用 ChatGPT 登录持久化在 `~/Library/RimeBuffer/ai/codex-home`，不读取 `~/.codex` 中的订阅登录或 MCP/Hook/插件/技能；设置页把登录凭据与 CLI 能力分开呈现，可直接发起、取消或重新授权结构化浏览器登录，并在完成事件后复核账户。每次请求创建私有临时工作目录，并在发送正文前用 `mcpServerStatus/list` 再次断言零 MCP。严格 permission profile 将文件读取限制到临时目录并关闭工具网络、shell/连接器等能力；完整隔离握手不成立时在正文出进程前失败关闭。
- **Claude Code CLI 连接器**：设置页用固定 `claude auth login --claudeai` 发起官方浏览器授权，可取消或重新授权；后台探测用 `claude auth status --json` 的 `loggedIn` 布尔值缓存就绪状态，定期复核时不阻塞输入法主线程。生成以 `claude -p --output-format stream-json --include-partial-messages` 运行，禁用 tools、slash commands、会话持久化与交互式授权，只经 stdin 传源正文。RimeBuffer 不读取凭据文件、不展示账户元数据，也不把 `CLAUDE_CODE_OAUTH_TOKEN`、`CLAUDE_CONFIG_DIR` 或 ambient API key 传给子进程；官方 CLI 只从经过滤的进程环境中的 `HOME` 解析它自己管理的 CLI 授权。
- 上述两个 CLI 都由 `Process` 直接启动，不调 shell，不显示 stderr/reasoning/tool 输出，且在 0700 临时目录内受 120s/1MiB 上限约束。准入不依赖版本号：Codex 必须以完整隔离参数完成无提示词的 app-server initialize 与空 MCP 握手，Claude 必须提供实际生成所需的工具关闭和流式参数；能力契约不成立时在正文出进程前 fail-closed。**这不是本地推理**：点击生成后，缓冲全文会通过各自 CLI 的已登录服务发送。
- **OpenAI 兼容 API 连接器**：用户可在“设置 › 连接器 › AI 模型”配置 Base URL、model 和 API key。请求为 `POST {baseURL}/chat/completions`，`stream: true`，要求标准 SSE `choices[].delta.content`/`[DONE]`；2xx 非 SSE 响应失败关闭。远程地址必须 HTTPS，HTTP 仅允许 `localhost`/`127.0.0.1`/`::1`；拒绝 userinfo、query、fragment 和 redirect，避免 Authorization 泄露。
- Base URL/model/key 保存于 **0600 文件** `~/Library/RimeBuffer/ai/openai-compatible.json`，不进 UserDefaults、Keychain 或日志。继续沿用 ad-hoc 签名下避免 Keychain ACL 重复弹窗的决策，Developer ID 后再评估迁移。
- 「AI 生成」插件只在用户显式点击右侧 AI 主按钮或按 Return 时把当前缓冲全文交给所选连接器，永不附带输入历史、preedit、剪贴板或屏幕上下文。预置/自定义提示词模板仍属后续，不写成当前能力。

---

## 6. 投递层（需求 6）

### 6.1 目标模型

| 目标 | 级别 | 默认 | 行为 |
|---|---|---|---|
| 当前实时输入框 | 主要 | 开，不可关 | 只有当前 FocusToken 租约通过对象身份、bundle 与前台 app 校验后才 `insertText` |
| 配对设备镜像 | 既有独立通路 | 用户既有设置 | 经现有加密通道发送；`.remotePeer` 来源不镜像回原设备 |

探索稿的 AirDrop 目标已砍（§0.1）。

### 6.2 当前本地投递基线与后续 Router

- 当前本地投递由 `BufferDeliveryCoordinator` 负责：普通块发送前重验同一 token；仍绑定目标的插件块还必须用生成时的同一 runtime binding 异步重取 fresh status，并同时匹配 action/context/原 token。切换工作台 owner 只取消在途请求，**不清除已完成 Marine block 的 runtime binding 与投递 authority**；这些 block 在切到其他插件后仍按原 action/context/focus 复核。只有对应外部插件被禁用、卸载、升级，或原 runtime/上下文失效时才撤销。焦点变化或实例失效立即停止，旧插件块标记为 stale，不能一键投到新目标。用户只能在收件箱显式选择“作为普通文本加入”来解除旧绑定；该动作保留插件来源/原目标供核对，但之后只按当前焦点走普通块投递。
- 翻译/AI 的 target rail 也由同一协调器路由。协调器按 workspace/generation/id 重取每个 target block；已送 target 立即消费，但 source blocks 只在当前 generation 的 target 全部送完后才消费。
- `Delivery.insert` 调用成功只表示 IMKit 接受调用，不是宿主 ACK；当前产品在成功返回后立即把该 block 从 live buffer 消费，且不保留明文历史。局部失败立即停止，失败 block 和尚未发送后缀原位保留。
- 工作台不提供历史恢复或清空撤销。跨 app 隐私清理仍是不可恢复的安全操作。
- 多目标、远端 ACK、失败状态与持久账本仍属于后续 M5，不把未来能力写成当前保证。

### 6.3 Echo 防回环

配对收字维持直通，不进入缓冲；若已有 `.remotePeer` 来源块通过兼容路径进入缓冲，`origin.allowsRemoteMirror` 仍保证它不会回镜。输入法自身设置等窗口也永不参与远端镜像。

### 6.4 远端协议 v2（推迟）

当前配对直通协议不因缓冲窗口改造而升级。messageID/ACK 只在未来多目标投递确有需求时另行设计。

### 6.5 当前行为

1. 配对设备收字继续直通；当前没有安全目标或投递被拒绝时，不报告假成功。
2. 缓冲工作台发送只认当前实时外部文本框；不会使用 recent/last client 兜底。

---

## 7. 安全模型

| 措施 | 机制 | 备注 |
|---|---|---|
| 密码框保护 | `Delivery.insert` 在投递时同步检查 `IsSecureEventInputEnabled()` 并拒发；工作台遮蔽。当前收件箱「接受」只暂存到缓冲，不禁用也无锁标 | macOS secure input 本身已让第三方 IME 收不到密码键入；核心保证是已有缓冲内容不能被投进密码框 |
| 切换应用时重置 | 显式设置，默认关；开启后仅当缓冲中没有任何外部来源块时不可撤销地丢弃 live blocks 并收束瞬态状态 | 常驻工作台默认跨 app 保留；外部待投递内容绝不因切目标而自动丢弃 |
| 焦点与自有窗口 | FocusToken 精确租约；自有设置等文本框既不进缓冲，也不远端镜像 | 迟到 deactivate/command/candidate click 不能影响新目标 |
| 本地端口鉴权 | 仅绑 127.0.0.1 + Bearer token（0600 文件）+ 常数时间比较 | 无 token 401，不产生任何 UI 痕迹 |
| 来源门控 | §4.4 三档类型 + 当前硬编码规则；无按来源设置 | 可配置覆盖属后续路线图 |
| 网络出站清单 | Codex/Claude/OpenAI 兼容 API / [计划] SSE / [计划] SSH / 隔空传字 / GitHub 更新检查 | AI 只在用户显式生成时出站；SSE/SSH 尚未实现；其余按现有设置运行 |
| 日志脱敏 | `IMELog` 全面改为「事件+长度」，不记 text 本体；文件 0600 + 10MB 轮转 | 连带修掉审计确认的「rimebuffer.log 明文记录所有上屏文本」高危项，随 M0 出 |
| 隐私红线 | MCP 无读取工具（§4.2）；AI 只在点击生成时读当前缓冲全文，不带历史/preedit/剪贴板/屏幕上下文（§5.3） | 写死，不做开关 |

---

## 8. 设置窗信息架构

当前实现是 **6 个固定一级页 + 动态扩展页**：

```
输入法（输入编码 / 键入模式 / 词库）
外观（候选窗 / 主题）
缓冲区（常规 / 工作台）
连接器（隔空传字 / 本地网关 / AI 模型）
插件（全部 / 缓冲插件 / 内置扩展）
维护（更新与重启 / 日志与数据）
扩展：统计、打字测速、飞耀互击学习……
```

固定一级页在左侧竖排，每页子页在右侧顶部横排；内置扩展通过统一 Registry 动态贡献左侧页面。“连接器 › AI 模型”管理 OpenAI 兼容 API 的 Base URL/model/key，并明示 Codex/Claude CLI 虽在本机启动，正文仍会经已登录服务发送。缓冲页明确展示：关闭窗口会收束组字、暂停捕获、结束未完成的瞬态状态并保留已有块。候选默认使用常规面板锚定在细条下方，可切回跟随 caret；菜单也提供显隐、pin 与移到当前屏幕。「安全」不单设页，安全项就近放在语义所属页。

**[后续路线图]** 等按来源信任和多目标投递真正实现后，可把「连接」拆成独立「来源」与「投递」页，形成原方案中的 8 页 IA；当前不得把该拆分写成已完成。

---

## 9. 迁移路径与分期

每期独立可发版、可回退（不动身份三元组，CI 冻结断言继续护航）。下表已按当前决策重写；完成状态以 §12.2 为准，未实现项保留为路线图。

| 里程碑 | 内容 | 依赖 | 状态 / 原粗估 |
|---|---|---|---|
| **M0 安全底线** | secure input 短路、切换应用重置开关、日志脱敏 | 无 | ✅ 已完成 |
| **M1 领域改造** | Origin、来源徽标与 echo 守卫已落地；工作台内传入轨后续；Remote 入站改道/协议 v2 已取消或推迟 | M0 | 部分完成 |
| **M2 网关** | LocalGateway、stateless MCP tools、HTTP push、token 与收件箱已完成；按来源信任设置尚未实现 | M1 | ✅ 主干完成 |
| **Action Plugin v1** | manifest/runtime config、本机 Bearer HTTP、动态动作 UI、插件管理、request/context/focus 安全分流 | M1 | ✅ 已完成 |
| **M3 本地翻译** | 苹果本地翻译、双缓冲轨、SwiftUI session 桥、互斥 owner | 缓冲插件平台 | ✅ 已实现 |
| **M4 AI 缓冲插件** | Codex CLI、Claude Code CLI、OpenAI 兼容 API、双轨 workspace、0600 凭据 | M3 | ✅ 已实现；提示词模板后续 |
| **M5 投递路由** | [计划] DeliveryRouter、多目标、远端 ack、失败状态与持久账本；当前仅有本地精确焦点投递且不保存发送历史 | M1 | ~500 行 |
| **M6 收尾** | [计划] SSEClientProvider、SSHProvider、工作台内传入轨、设置窗 IA 再拆分与视觉对齐 | M2 | ~700 行 |

原始未实现部分曾粗估约 4800 行；工程当前约 14000 行，该估算不再代表剩余工作量。后续每期验收仍对应 §1.2 用户故事，并为新增纯逻辑补 smoke；协议 v2 已推迟，不属于当前 CI 契约。

### 9.1 历史技术 spike（已完成，不等于下列产品能力均已实现）

1. **Translation framework 无 SwiftUI 上下文可用性**（§5.2）——已落地为工作台内 1×1 `NSHostingView` + `translationTask`；真实语言包下载仍需安装后验收。
2. **NWListener 手写 HTTP/1.1 + SSE 长连接**的稳定性——spike 已通过；当前产品只落地 stateless MCP/HTTP 子集，SSE client 仍属 M6。
3. **MCP streamable HTTP 与 Claude Code / Codex 的实际握手**——最小握手已通过；当前正式契约以 §4.1 的 stateless POST 实现为准。

---

## 10. 对探索稿 17 个悬置问题的裁决记录

| # | 问题 | 裁决 |
|---|---|---|
| 1 | MCP 是否 Marine 化名 | 否，真 MCP（需求 2）；Marine 走兼容 provider 至迁移完成 |
| 2 | echo loop | Origin 规则，§6.3 |
| 3 | 处理器时机 | 入缓冲区侧跑，不在投递路径（§3.2 规则 3） |
| 4 | AI 谁来调 | 输入法内置（需求 5 推翻此前"外包给本地智能体"的建议） |
| 5 | 钥匙串 | 0600 文件，Dev ID 后迁移（§4.1/§5.3） |
| 6 | 剪贴板捕获 | 自动/隐式捕获仍砍；显式精确 Ctrl/Cmd+V 已实现，且 secure input 下不读取（§0.1） |
| 7 | 安全字段/切换重置 | M0 先行 |
| 8 | 块编辑分叉 | 工作台不提供块编辑器，也不做无边界自由编辑与自动 diff/reconcile |
| 9 | 候选窗/维护页去向 | 保留，归「输入法」组（§8） |
| 10 | 隔空传字页去向 | [路线图] 来源/投递能力成熟后再拆页；当前仍在「连接」页（§8） |
| 11 | 无条件镜像 | v1 保持既有隔空传字设置；自身窗口永不镜像，`.remotePeer` 来源永不回镜（§6.3） |
| 12 | Return 轻按/长按发送 | 已实现；无未决组字时 keyDown 建立隔离，轻按发下一块、按住约 1.2 秒发全部。有未决 Rime/并击或未 ready raw 时本次只收束/强制生成；ready 意识流在 keyDown 确认候选后使用同一次手势发送（§1.1） |
| 13 | 清空按钮 | 2026-07-18 覆盖裁决：移除按钮、清空与撤销功能；只保留不可恢复的自动安全清理 |
| 14 | 紧凑面板两轨还是三轨 | 三层仍是历史路线目标；当前顶部功能栏常显，普通模式为 78pt，派生模式为 source + 1–3 target rows 的 112/143/174pt 动态高度，工作台底边下方仍是常规 Rime 候选窗，传入轨仍待嵌入 |
| 15 | 「远端」语义 | 本方案中远端=配对设备（出入站同一对端）；「远端算力」概念废弃，算力即处理器 |
| 16 | 分期 | §9 |
| 17 | 路线图还是草稿 | 草稿；本文档为收敛后的路线图 |

## 11. 开放风险

- Apple Translation 已集成系统版本门控与 AppKit/SwiftUI 生命周期，但首次真实语言包下载仍需安装后验证。
- Codex/Claude CLI 受用户本机安装版本、登录状态与上游 JSON 事件形式影响；smoke 只用假 runner，真服务仍需手工验收。
- 焦点竞态：同一 app 多文本框可能复用 IMK client proxy；必须依靠每次 activation 新 epoch、事件顺序与迟到 callback 拒绝，真机覆盖 Safari/Electron/微信。
- 常显隐私：工作台跨桌面/全屏可见，必须保持 secure-input 低频检测、自动隐私清理与锁屏隐藏；产品不再提供手动遮蔽状态。
- 刷新/重置不得清除或改写缓冲正文；它只能取消/重启当前插件状态，且所有旧请求仍须通过原焦点/上下文 generation 校验。
- MCP 规范演进快，streamable HTTP transport 细节可能随客户端版本变动——spike 3 锁版本，README 注明测试过的客户端版本。
- [未来条件风险] 若 M5 重新启动配对协议 v2/ACK 设计，必须先确定版本协商与兼容策略；当前版本未实现 v2，也不要求两台 Mac 同步升级。

---

## 12. 实施进度与决策更新

### 12.1 产品负责人已拍板的决策（覆盖 §10 的对应条目）

- **隔空传字 = 「直通上屏」档**（覆盖 §10 #10/#15 的早期设想）：配对设备收到的文字**直接上屏**，保留现状的无人值守实时传字。它**不进传入轨、不进缓冲区**。因此原 §6.5「远端收字改道缓冲区」与「协议 v2」在 v1 **作废/推迟**——没有改道就不存在缓冲内 echo 死循环，也不需要 ack 账本。§1.3 的「外部文字先待确认」不变量只对**非配对来源**（MCP/HTTP，以及未来 SSE/SSH）生效。
- **起步 = M0 安全底线**（已完成，见下）。

### 12.2 里程碑实际状态

- **M0 安全底线** — ✅ 已发 v0.4.4：secure-input 护栏（Delivery.insert 唯一咽喉）、可选切换应用清理、日志脱敏（IMELog.redact + 0600 + CI 断言）。当前常驻工作台默认不清理。
- **M1 领域改造** — 部分完成：
  - ✅ **M1-A 来源溯源 + echo 规则**：`Origin.swift` 枚举、`Block.origin`、`Origin.allowsRemoteMirror` echo 守卫（远端来源不回镜）、`origin-smoke`（已入 CI）。Action Plugin 结果按插件 id 标记 `.plugin(id)`。
  - ✅ **来源徽标**：BufferInlineView 给非 rime 块画彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持无徽标。
  - ⏸ **传入轨 UI**：M2 网关前置条件已经满足；当前仍使用 `InboundToast` + `InboundTrayWindow`，嵌入独立工作台的传入轨尚未实现。配对设备继续直通不入轨；Action Plugin 的有效结果进入 buffer，失效或迟到结果进入收件箱。
  - ⏹ **远端改道 + 协议 v2**：按 §12.1 决策**作废**。
- **M2 网关+MCP** — ✅ 主干已实现：`LocalGateway`、MCP tools、`InboundBus`、token 与收件箱可用；传入轨嵌入工作台仍后续。
- **稳定缓冲窗口** — ✅ 2026-07-28：FocusToken、Return 轻按逐块/长按全部、纸飞机逐块发送、Return/Backspace 宿主隔离、常显且空白可拖的顶部功能栏、普通78pt与1–3 target rows的112/143/174pt动态高度、状态/插件动作/刷新/关闭契约、派生多行控件对齐、条下方常规 Rime 候选窗、普通/插件/意识流 source 全选粘贴、成功块无历史消费、多屏/常显与 secure-input 保护（包括不读剪贴板）已实现；待重新安装后的真实宿主输入交互验收。
- **AI 生成插件 + 三连接器 + 工作台快捷入口** — ✅ 2026-07-20：唯一「AI 生成」插件、Codex CLI/Claude Code CLI/OpenAI 兼容 API 三连接器、source/target 双轨、工作台插件选择器、`Command+Shift+B` 全局打开/关闭、OpenAI 0600 配置与 owner 切换后 Marine 权限保留已落地；待安装后的真 CLI/API 和快捷键验收。

### 12.3 下一步真实工作量

M2 已能向收件箱与 BufferModel 喂真实数据，Action Plugin v1 也已能把用户主动请求的有效结果送入 Buffer、把失效结果退回收件箱。苹果本地翻译与唯一「AI 生成」插件的 source/target 双轨也已落地；该插件可独立切换三个模型连接器。下一步是安装后完成 Marine、真 CLI/API、OpenAI 兼容端点和全局快捷键闭环，再考虑把 `InboundBus.pending` 投影为工作台内固定高度的传入轨；多目标/远端 ACK 仍按 M5 独立推进。
