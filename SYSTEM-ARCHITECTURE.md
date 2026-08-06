# RIMES · 系统架构

版本：2026-08-04 · 权威全局架构文档
关系：本文档描述**整个系统**（既有输入核心 + 缓冲工作台）。`WORKBENCH-DESIGN.md` 是工作台的产品方案与决策记录；`ARCHITECTURE.md` 是 P1 时代的交接文档（已滞后，仅存档）。三者冲突时以本文档为准。

代码规模：约 31000 行（Swift + 一层 C++ librime 桥）。单进程、后台 agent（`LSUIElement`）。

---

## 0. 一句话

RIMES 是一个 **macOS 中文输入法**（IMKit + 自包含 librime），并在其上叠加了一个**独立、常驻、上屏前的文本工作台**：中文 commit、ASCII/英文/标点、已接受的外部文字与用户主动请求的插件结果都先进入缓冲，再由用户逐块或长按全部投递到实时校验的输入框。AI、翻译、Marine Chrome、My Prompt、意识流和旧 Action/Marine 兼容插件的上游逻辑块统一经过同一投递边界；My Prompt 把上轨作为查询，从本地 SQLite 索引显示最多三个互斥提示词结果，查询本身永不投递。意识流在串击与双拼模式下把焦点绑定的物理 `a-z` 当作连续全拼；飞耀并击/互击都使用当前有效 `my_combo` 映射物理批次，并分别保留同批结算与相邻左/右半区跨批重组语义。完整音节自动加入 soft ASCII syllable Space，尚未配对的单侧拼音片段只映射、不切割。它不修改或持久化用户输入方案。用户物理 Space 才是立即请求、以 `·` 可视化并参与短句强分块的 hard boundary；自动 Space 显示为普通空格，只参与全拼音节提示。普通 AI 和 Marine Chrome 只在 Return 或主按钮明确请求时运行；My Prompt 本地实时检索，意识流按停顿自动猜测最多三个互斥版本；二者的多结果逐行显示并由 ↑/↓ 选择，Return/纸飞机先原子确认当前版本再发送，任何结果都不能自动上屏。`Command+Shift+B` 可全局开关工作台；secure input、失效焦点与工作台自有输入框始终隔离。

---

## 1. 分层总览

```
                          ┌──────────────────────────────────────────────────────────┐
   外部世界                │              RIMES 进程（内部 ETInput，单进程）               │
                          │                                                           │
 Claude Code / Codex ─MCP─┤─▶ LocalGateway ─┐                                         │
 curl / 脚本  ────HTTP────┤─▶ (127.0.0.1)   ├─▶ InboundBus ─待决─▶ InboundTrayWindow  │
 [计划]服务器推送 ─SSE─────┤─▶ SSEProvider ──┤                         │ 接受            │
 [计划]远程主机 ───SSH─────┤─▶ SSHProvider ──┘                         ▼                 │
 已安装旧 Action Plugin manifest ─▶ ActionPluginHost ─Bearer HTTP─▶ 本机插件服务       │
                          │          │ legacy invoke 或 prepare prompt       │失效结果     │
                          │          ├─prepare─▶ 当前 AI 连接器 ─有效结果─▶ BufferModel │
                          │          └─legacy invoke──────────────▶ BufferModel ◀─ Rime │
                          │                                      (blocks)  └▶InboundBus│
                          │                                      (blocks)     commit  │
                          │                                Return 手势 / 主条纸飞机       │
                          │                                         ▼                  │
                          │                              BufferDeliveryCoordinator     │
                          │                                         │                  │
                          │                                  Delivery.insert           │
                          │                                         ▼                  │
                          │                                    当前输入框               │
                          │                                                           │
 配对 Mac  ─AES-GCM双向───┤─▶ RemoteTypingService ─▶ insertRemoteText ─▶ Delivery.insert│
                          │                                  └─无安全目标→剪贴板累积    │
                          │                                                           │
 实时翻译（Apple 本地/当前 AI）▶ TranslationWorkspace ─▶ 独立译文缓冲     │
 My Prompt 查询 ───────▶ MyPromptWorkspace ─▶ SQLite FTS ─▶ 1–3 个提示词结果 │
 reMarkable（SSH 定位 + USB Web PDF）▶ PDFKit 目标 300dpi 有界渲染 ─▶ Vision 本地 OCR ─▶ BufferModel │
 唯一「AI 生成」插件────▶ AITextPluginWorkspace ──────▶ 独立生成缓冲     │
 Stable Chrome MV3 sensor ─专用 6s context lease─▶ MarineChromeWorkspace │
 旧 Marine prepare prompt ─▶ ActionPluginHost ─┐                            │
                                            └─▶ AITextConnectorRegistry    │
                                                ├─ Codex CLI（ChatGPT 登录态） │
                                                ├─ Claude Code（CLI 授权态）   │
                                                └─ OpenAI 兼容 API           │
 意识流 raw ───────────▶ StreamInputWorkspace ─▶ 独立可配置 AI 渠道 ──▶ 1–3 个完整猜测 │
 [计划] 多目标/远端 ACK────┤◀▶ DeliveryRouter（M5；当前不存在）                          │
                          └──────────────────────────────────────────────────────────┘
                                    │ 底座
                              ┌─────┴──────┐
                              │  librime   │  (dlopen，自带；Squirrel 为回退)
                              └────────────┘
```

当前网页主路径不经过 `ActionPluginHost` 或旧 Marine 服务：**Chrome MV3 sensor → 专用 loopback context lease → `builtin.marine-chrome` → 当前 AI connector → `BufferDeliveryCoordinator` → `Delivery.insert`**。

五个横切层，文本从上（来源）流到下（投递），中间是缓冲区枢纽：

| 层 | 职责 | 关键模块 |
|---|---|---|
| **来源层** Sources | 把外部文字收进来，门控后产出待决条目；Marine Chrome 以专用、短时 context lease 收取网页上下文 | InboundBus, LocalGateway, MarineChromeContextStore, 各 Provider |
| **缓冲层** Buffer | 所有文本的暂存枢纽；块携带来源 | BufferModel, Origin |
| **动作插件层** Action Plugins | 兼容已安装的旧 Marine 等外部动作；冻结上下文，必要时接收 prepared prompt，再把 Rime 本地连接器结果安全地路由回缓冲/收件箱 | ActionPluginHost, manifest, loopback HTTP |
| **加工层** Transforms | Marine Chrome、「实时翻译」、唯一「AI 生成」、My Prompt 与意识流输入使用独立 source/target 双缓冲；Marine Chrome 与普通 AI 使用当前连接器，My Prompt 从本地 SQLite 返回 1–3 条提示词，翻译默认 Apple 本地且可选当前 AI，意识流使用自己的渠道与节流配置并给出 1–3 个完整猜测 | MarineChromeWorkspace, AppleTranslationWorkspace, AITextPluginWorkspace, MyPromptWorkspace, MyPromptStore, StreamInputWorkspace, AITextConnectorRegistry |
| **投递层** Delivery | 把确认后的块送到目标；防过期焦点、防回环、防误投 | InputFocusCoordinator, BufferDeliveryCoordinator, Delivery（唯一插入咽喉） |

下面是底座：**输入核心**（Rime 引擎 + IMKit 事件 + 候选窗），它既独立工作（普通打字），又是缓冲层的一个来源（Rime commit）。

---

## 2. 数据流：一段文字的一生

```

Marine Chrome 的上下文不进 `InboundBus`，也不进外部 Action Plugin runtime。Stable Chrome 的 MV3 传感器把当前页面/精确回复目标发到专用回环路由，`MarineChromeContextStore` 在 6 秒心跳租约中保持上下文；`MarineChromeWorkspace` 只在该内置插件为当前 owner、缓冲开启且非 secure input 时接收它，之后由当前 AI 连接器生成 target blocks。
① 本地打字         ② 外部来源                    ③ Action Plugin
   键盘事件           MCP/HTTP；[计划] SSE/SSH       用户点动作 → 本机服务准备话术
     │                   │                         │
     ▼                   ▼                         ▼
  RimeEngine          LocalGateway              ActionPluginHost
  processKey          → InboundBus.submit        prepare → 当前 AI 连接器执行
     │ commit            │ 门控                     │ requestId/contextId/FocusToken 校验
     ▼                   ▼                         ▼
  ┌──────────────────────────────────────────────────────┐
  │            BufferModel  (blocks: [Block])             │  ← 枢纽：每个块带 Origin
  │   缓冲模式 OFF → 直接上屏；ON → 暂存为块，等确认        │
  └──────────────────────────────┬───────────────────────┘
                                 │ Return 轻按/长按或点击主条右侧纸飞机
                                 ▼
                     BufferDeliveryCoordinator
                    ┌──── 普通 App：FocusToken/client 与前台 bundle/PID 精确匹配
                    │     Spotlight：系统 PID + 可见窗口 + 下层前台 bundle/PID 锚点
                    ├──── 组字未决 / secure input → 拒绝或先显式收束
                    ├──── 每个块投递前再次校验，焦点变化立即停
                    ▼
                Delivery.insert  ──▶ 当前输入框 (client.insertText)
```

关键不变量（安全叙事，恒真）：
1. **非配对外部文字永不自动上屏**——MCP/HTTP 先进收件箱待决；用户主动调用且仍匹配原 request/context/focus 的插件结果可直接进缓冲，失效或迟到结果退回收件箱。
2. **插件/处理器结果永不直接上屏**——无论直接进缓冲还是退回收件箱，都只能由用户随后明确投递。
3. **secure input（密码框）激活时，Return 在动作边界同步 fail-closed**：只吞下按键，不收束组字、不重建 U+200B guard、不请求 AI，也不投递；工作台正文与派生 workspace 同步进入保护态。
4. **缓冲投递不保存“最近输入框”兜底**：只有当前 `FocusToken` 的外部文本框能接收。普通 App 的 bundle/PID 必须同时匹配当前前台应用；系统 Spotlight 因不成为 frontmost，改为同时匹配其绑定 PID、真实可见窗口与下层前台 bundle/PID 锚点。切 app、切文本框、窗口隐藏或进程重启都会令旧目标失效。
5. **手动投递不等于目标已确认收到**：当前产品在 `Delivery.insert` 成功返回后立即消费 live block，不保留明文发送历史；失败的块和后续尚未发送的块原位保留。
6. **配对设备是来源侧唯一直通例外**：收到的文字沿既有实时传字路径直接上屏，不进入缓冲工作台。
7. **缓冲按键与宿主隔离**：缓冲模式下普通/Shift+Return 与 Backspace 总是被输入法消费。有未决 Rime/并击组字或尚未 ready 的意识流 raw 时，本次 Return 只收束/强制生成并抑制同一物理按键余下事件；意识流 final 已 ready 时，keyDown 先确认所选候选并淘汰其余项，同一次按键继续进入轻按/长按投递。其他没有未决组字的内容也在 Return keyDown 中定点重建不可见 marked-text guard。普通/ready 内容仍是轻按发送下一块、按住约 1.2 秒发送全部；AI request 状态则在 keyDown 就吞下整次物理按键并请求生成，running/disabled 只吞键，不进入长按计时。`didCommand` 与 repeat 只有消费权。Backspace 只在精确焦点下编辑 Rime/并击状态或删除缓冲块。焦点不可信时始终吞键且不投递；宿主绝不会收到换行或删除。
8. **派生 source/target 按生成快照交易**：翻译、普通 AI 与 My Prompt 只有已完成且仍匹配 source text/block ids/generation 的 target blocks 可投递；目标未成功送完时源块原样保留，最后一个目标成功消费后才一次性消费对应源块。My Prompt 与意识流的 1–3 个 target rows 是互斥备选而非待发送队列；`prepareForDelivery()` 在冻结投递 generation 之前原子确认所选项并立即淘汰其余候选，不等待首次 `Delivery.insert`。My Prompt 的查询永不进入 delivery blocks；意识流 raw 与所选结果在部分投递期间保留，只在最后一个所选 block 成功后清除。
9. **插件和连接器是两条独立选择轴**：`.bufferAction` owner 只决定当前工作台动作；Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 只决定谁执行 AI。切 Marine Chrome/「AI 生成」不会暗中切换模型源，切模型源也不会改写插件 owner。精确外部缓冲租约下，`Command+Shift+↑/↓` 按工作台选择器的同一顺序在 `Default + 已启用缓冲插件` 间首尾循环；额外修饰键、自有窗口或 secure input 不触发切换。
10. **意识流 raw 不是输入法 preedit**：只有缓冲开启 + 唯一 owner + 非 secure + 精确外部焦点同时成立时，意识流按键才在 Rime 前进入 `StreamInputWorkspace`。串击与双拼沿用物理 `a-z` 的逐字连续全拼；完整配置为 `.chord` 或 `.mutual` 时，workspace 按 `ChordSettings.duration` 聚合物理批次，并用有效部署的 `my_combo` 映射为全拼。并击只映射当前批；互击可在至少一侧为多键、schema/focus/raw/soft-offset 快照完全一致时，把紧邻的左侧声母批与右侧韵母批回滚重组。它只读取配置做路由，不切换、修改或持久化配置。左右半区共同构成且映射成功的完整音节追加一个 sidecar 标记的 soft ASCII syllable Space；`dv→n`、`km→ong` 等尚未配对的单侧映射只写入可继续补全的拼音片段，不追加 Space。单键字母保持原码且不追加，两个单键批不重组，单独 `,`/`.` 只消费，无映射多键批保留确定性字母原码且不追加。soft Space 显示普通空格、参与音节提示，但不立即请求、不增加短句最小分块数；物理 Space 是显示 `·` 并立即请求的 hard phrase boundary，紧跟 soft Space 时原位提升而不重复写入。第一枚待结算键立即撤销旧结果的投递权；非和弦边界、焦点、secure input、owner 或配置变化都会清除互击配对并作废定时器与批次。raw 与边界 sidecar 不进入 BufferModel、Rime 候选、遥测正文或宿主。字母或已结算 FlyYao 批次只重置 220 ms debounce，800 ms burst 上限不重置；最多两路 make-before-break，跨 revision 的旧结果、partial 与 baseline 都不进入新 prompt，迟到回调按 job/generation 作废。唯一例外是同 revision 的一次补候选重试：只有此前严格校验通过的 terminal guesses 才能作为有界、JSON 编码且明确不可信的 `excludedGuesses`。每轮 prompt 冻结完整 raw、soft-space offsets 与最多三条 lossless 本地音节提示；提示只把 hard Space 写成 ` | `，soft Space 保留为音节边界，多于一种提示时 `minimumGuessCount=2`。不足时两个合法 final 按旧结果优先合并、去重并最多保留三条；重试仍重复或失败时只保留此前合法候选 ready，retry partial 永不可投递，首轮或没有合法 fallback 的畸形、空、超限 final 仍 fail-closed。partial 使用稳定候选槽位，final 精确覆盖且旧尾不能进入 ready/交付。输出是 1–3 个完整互斥猜测，每个候选独占目标行且在行内细分投递 block；只有 hard Space 子句数作为最小分块目标。投递前确认选择并删除其他候选，首块成功后继续输入会撤销未发尾部并建立全新 raw，已经发送的前缀不得复活。
11. **Shift 只在独立轻点时切换中英**：controller 先保留物理 Shift 手势，不立即启动 Rime 的 standalone-Shift 状态；小于 500 ms、未与其他键/修饰键组合且 session/schema 未变化时，才在抬起阶段向 Rime 补发同侧 Shift press/release，保留 schema 原有切换语义。组合使用、长按、左右 Shift 重叠或失焦手势整对丢弃，因此后续输入维持原模式，也不会触发 `commit_code` 的组字副作用。
12. **全选/粘贴只编辑工作台 source**：精确 Control/Command+A/V 在所有普通与插件模式共享一条控制器路径。非意识流时全选 `BufferModel` 全部 source blocks，粘贴在块光标插入或替换全选，连接后原文完全不变再语义分块；意识流只全选/替换 raw 上轨，候选 target rows 不可编辑。意识流粘贴只接受 ASCII 字母与空白，字母转小写、空白归一为 Space；任一非法字符或 16 KiB 上限失败都原子保留 raw、选择、候选、generation 与请求。普通 pasteboard 文本必须非空、无 NUL 且至多 1 MiB。读剪贴板前后都重验 secure input 和同一精确租约；secure input 下保留宿主命令且输入法绝不读取 pasteboard，失效外部焦点只吞键。
13. **Marine Chrome 是租约，不是浏览器自动化**：只有当前 owner + 缓冲 active + 非 protected session + 非 secure input 同时成立时才接收上下文；心跳必须在 6 秒内续约同一 source/revision/context/URL/target，且生成和投递需同一 Stable Chrome 焦点租约。浏览器上下文不进 `BufferModel`；用户可在上轨输入可编辑的补充要求，并与上下文一起冻结到本轮 generation。扩展只感知页面，不填入输入框、不点发布；所有结果仍要用户经 `BufferDeliveryCoordinator` 明确发送。

---

## 3. 领域模型（核心类型）

```
Origin ──────── 文本从哪来。驱动三件事：UI 来源徽标 / echo 防回环 / 来源门控
  case rime                         本地打字（无徽标）
  case marine                       旧 Marine 草稿（仅兼容）
  case plugin(id)                   用户主动调用的进程外 Action Plugin
  case mcp(client)                  MCP 客户端（自报名，不可验，仅展示）
  case http(source) / sse(feed) / ssh(host)
  case remotePeer(deviceID)         配对 Mac
  case processor(id, allowsRemoteMirror) 本地派生结果

Block (BufferModel 内) ── 缓冲区的一个块；live blocks 均为待发送
  id / text / origin / createdAt
  pluginMetadata? = pluginId/actionId/requestId/contextId/focusToken/runtimeIdentity/title?/targetSummary?/stale/reviewedAsPlainText

InboundItem (InboundBus 内) ── 传入轨上的待决条目
  id / origin / title? / text / streaming / state(pending|accepted|rejected) / pluginMetadata?

AITextPluginWorkspace.Job ── 一次显式 AI 生成
  generation / requestID / sourceText(冻结快照) / sourceBlockIDs
AITextWorkspaceOutputBlock ── 独立 target rail 的逻辑块
  id(按 index 稳定) / index / text / title? / incomplete

MarineChromeWorkspace.Job ── 一次显式网页评论/回复生成
  generation / requestID / context(短时快照) / Stable Chrome FocusToken

```

设计要点：
- **Origin 是这次工作台重构的第一等公民**。一个枚举同时解决徽标、防回环、门控三件事。
- **旧 Action Plugin 结果是带 metadata 的 `BufferModel.Block`**；Marine Chrome、翻译/AI 结果则先留在独立 target workspace，投递时才经 `BufferDeliveryContentSource` 暴露为 `.processor` Block。
- **source snapshot = 轻量版「Turn 冻结」**：任务启动时拷贝全文与 block IDs，之后任一边发生变化都作废旧 generation，不引入显式 Turn 实体。

---

## 4. 子系统详解

### 4.1 输入核心（底座）

```
键盘事件 ─▶ RimeBufferController (IMKInputController 子类)
             │  · flagsChanged 逐字节时序、F1–F12/grave 映射、Cmd 直通
             │  · 并击门控 (仅 my_combo)、raw passthrough 兜底
             ├─▶ RimeEngine ──▶ CRimeBridge (C++) ──dlopen──▶ librime.dylib
             │      每 controller 一个 session；引擎全局单例             (自带，Squirrel 回退)
             ├─▶ CompositionSession   marked text / preedit（只在本地）
             ├─▶ InputFocusCoordinator  FocusToken + client 身份 + 前台/系统浮层双模式租约
             └─▶ CandidateWindow      唯一候选面板；锚定 caret 或缓冲条下方
```

- **RimeEngine / CRimeBridge**：手写声明整个 `RimeApi` 结构体，`dlopen` 优先加载自带 librime，失败回退系统 Squirrel。首启 `start_maintenance` 自部署，自包含无需装 Squirrel。
- **`my_combo` AI 去耦**：旧 `ai_mode`、`ai_box`/剪贴板 processor、状态 translator、AI translator/filter、快捷键与 `python_bin` 配置已从 schema 下线；Rime schema 不再启动 Lua/Python AI 链路。普通输入依赖的 librime Lua 模块继续保留，AI 只由原生工作台插件和 Rime 侧连接器执行。
- **RimeBufferController 按键隔离与 Return 手势**：缓冲模式在最外层吞掉普通/Shift+Return 与 Backspace。精确外部租约持有缓冲控制期间，`CompositionSession` 会常驻一次不可见 U+200B marked-text guard（包括 Rime 空闲和引擎不可用阶段），防止 Chromium/ProseMirror 在 IMK handled 结果之外观察 raw Return 并提交；guard 生命周期与真实组字状态分离，空闲 guard 不会把 `composition.composing` / lease `compositionActive` 置真，且 marked range 标为不可靠。Return keyDown 绑定当时的 `FocusToken`；有未决 Rime/并击组字或未 ready 意识流 raw 时只收束/强制生成并抑制到物理抬起。ready 意识流则在该 keyDown 先执行同一个 `prepareForDelivery()` 确认，删除其他候选后继续当前轻按/长按手势；其他可投递内容也在 keyDown 定点重建 guard，再由 keyUp/物理轮询判定轻按 `sendNext` 或持续 1.2 秒的长按 `sendAll`。每次被接管的物理按键持有 sticky keyUp / `didCommand(insertNewline:)` suppression，发送最后一个 transient block 令 buffer inactive、动作 reset 或失焦都不能把迟到/重复回调放给宿主；旧字段的 stale callback 不改变当前按压状态，下一次确认的 non-repeat keyDown 才退休旧代并立即按新状态路由。`didCommand` 只防御性消费，不形成第二条发送路径。Backspace 仅在精确租约下改 Rime/缓冲。隔离分支先于 raw fallback，故引擎失败和不可信焦点也不会把这两个键交给宿主。
- **RimeBufferController 全选/粘贴路由**：`BufferClipboardShortcutRules` 只识别单一 Control 或 Command 修饰的 A/V；额外 Shift/Option 或 Control+Command 保持宿主快捷键。精确外部租约下，普通/插件 source 先收束 Rime 或 chord 组字再对 `BufferModel` 全选/粘贴，意识流则只操作 raw source。NSEvent 主路与 `didCommand(selectAll:/paste:)` 共用防重和物理 keyDown 所有权；对 Notes 等先套用 Cocoa 标准键位的宿主，只有在对应物理 Control+A/V 仍按下时，才把 `moveToBeginningOfParagraph:` / `pageDown:` command-only 回调还原为工作台动作，并从严格 live lease 恢复缺失的 callback client。真实 preedit 收束后，每次精确 A/V 都重装 U+200B host guard，避免 Chromium/Electron 在 IMK handled 周边再次执行宿主快捷键；`setMarkedText` 同步返回后必须重验同一租约。正在计时的 Return 发送会在 source 编辑前取消，但仍吞掉它的迟到 keyUp，防止新文本被误发。`NSPasteboard.general` 只在 secure input 为 false 且精确租约校验之间读取；延迟 pasteboard provider 返回后再重验，任一门控失配都不修改 source。
- **ShiftModifierGesture**：在所有 keyDown 早退之前记录 Shift 已被作为修饰键，并保存起始左/右 Shift keysym、session 与 schema。物理 press 不立即进入 `ascii_composer`；release 只为同 session/schema 的独立短按补发匹配的一对事件，其余手势不发。候选 Option 选择、预先按住的 Option/Control/Command、双 Shift 和失焦因此都不会留下 Rime modifier 债务，也不会先执行 `commit_code` 再尝试回滚。
- **CandidateWindow**：Rime 组字候选交互与显示的唯一状态机。普通模式锚定 caret；缓冲模式默认把同一个 `nonactivatingPanel` 锚定在工作台底边下方，因此主题、尺寸、翻页、单字选择和 token 化点击行为与常规候选完全一致。三行矩阵先把 panel、scroll viewport 与 frame-driven document stack 准备到最终 78pt，再挂 3×24pt row（3pt 间隔）；document stack 禁止生成旧 compact frame 的 autoresizing-mask 约束。工作台不再维护 Rime `CandidateProjection` 或第二份 Rime 候选视图；意识流的 1–3 个 target rows 是派生文本解释，不使用 Rime 候选状态机。
- **InputFocusCoordinator**：把 controller、租约 `IMKTextInput`、`controller.client()` 当前对象身份、bundle id、宿主进程/前台锚点与单调 token 绑定；普通 App 的 `liveTarget` 重验全部身份及 frontmost bundle/PID。唯一浮层例外是系统路径下唯一运行的 `com.apple.Spotlight`：activation 只创建 suspended 预热租约，真实可见 Spotlight 窗口中的新鲜 keyDown 才建立可投递 epoch；租约分别冻结 Spotlight PID 与下层前台 bundle/PID，后续 target/event 全部重验，keyUp/flagsChanged 不能建立或解锁它，任一 workspace activation 都撤销它。事件时间戳必须晚于 activation floor/最近已接受事件；先于 activate 的首键只建立短期 provisional 租约。explicit/implicit lifecycle callback 都必须与当前 client 一致；同一 proxy 跨字段或跨 controller 复用、异步 chord 回放失配、弱 client 过期时，旧 session 只在 Rime 内回收/丢弃，不调用已移动或释放的 proxy。
- **ChordController + ChordSettings**：常规 Rime 路径负责 FlyYao release-replay；时长是 UI 可配置项（`ChordSettings`，默认 0.10s，UserDefaults + 通知）。意识流 `.chord`/`.mutual` 路径不把批次送入 Rime，而是复用同一时长、`FlyChordBatchState` 和有效 schema parser，在焦点绑定的 workspace 内分别执行同批映射或跨左右批精确重组。
- **StatusMenu**：不建独立 NSStatusItem，命令挂在系统输入法菜单里（设置 / 收件箱 / 显示或关闭工作台 / 常显 / 移到当前屏幕 / 更新 / 部署 / 重装 / 重启）。

### 4.2 缓冲层

```
BufferModel (单例)
  blocks: [Block]          插入点 insertionIndex
  enabled                  缓冲模式开关 (UserDefaults)
  resetOnAppSwitch         切换应用清空（显式隐私选项，默认关）
  transient 三件套         异步产出→加载态→落缓冲→可失败（旧 Marine/未来处理器复用）
  append(text, origin)     每次进块记来源
  insert/remove            显式插入与删除；身份、来源和顺序受模型统一维护
  consumeDelivered         成功块原子离开 live blocks，不留明文历史
  clear/discardForPrivacy  仅供内部重置与不可恢复安全清理

BufferDeliveryCoordinator (单例)
  availability             当前精确目标 / 组字 / secure input / 待发送状态
  sendNext / sendAll       Return 轻按/长按分别触发；纸飞机只触发 sendNext。每块重验 FocusToken、client 身份、前台 bundle/PID，经 Delivery.insert 投递
```

- **枢纽地位**：Rime commit、外部来源接受、处理器结果，三路最终都进 `blocks`。
- **来源徽标**：非 rime 块在 BufferInlineView 里带彩色点（远端紫/agent 琥珀/网络蓝），rime 块保持干净。
- **消费语义**：`Delivery.insert` 成功返回后，成功块会原子地从 live `blocks` 删除且不保留明文发送历史；失败时立即停止，失败块和未发送后缀保持原顺序。
- **块交互语义**：工作台中的 chip 只被动展示已确立的 Rime commit 边界，不进入选中态、不打开单块编辑器。Backspace 删除、插入点与成功投递仍经 `BufferModel` 的显式方法维护身份和顺序。

### 4.3 来源层

```
各 Provider ──▶ InboundBus.submit(origin, text, title) ──門控──▶
                     │
      trust(origin): │  trusted → 直接进缓冲 (旧 Marine 兼容来源)
                     │  ask     → 进 pending 待决 (MCP/HTTP/SSE/SSH，默认)
                     │  blocked → 丢弃
                     ▼
              pending: [InboundItem]  ──▶ 收件箱/传入轨 UI ──接受──▶ BufferModel.append
                                                        └──拒绝──▶ 丢弃
              背压：pending 上限 50、单条 20000 字上限（防本机 DoS）
              流式：beginStream/appendStream/endStream（SSE/MCP 原位更新一个条目）
```

**LocalGateway**（回环 HTTP 服务器，M2 已建）：
- `NWListener` 手写 HTTP/1.1，**只绑 127.0.0.1**，端口默认 47700。
- 端点：`GET /v1/health`（免鉴权）、`POST /v1/inbound`（HTTP push）、`POST /mcp`（MCP streamable HTTP）。
- 鉴权：除 health 外全部要 `Bearer <token>`，常数时间比较。Token 存 `~/Library/RimeBuffer/gateway-token`（0600，不用 Keychain——ad-hoc 签名下会反复弹密码，沿用 RemoteIdentity 已论证的决策）。
- **MCP 工具（只给不看不发）**：`buffer_push` + `buffer_stream_{begin,append,end}`。刻意不提供读缓冲、读上下文、触发投递的工具——隐私边界写死。
- 已实测：真 Claude Code `✓ Connected`，curl HTTP push / MCP tools/call 均进 InboundBus。

**Provider 清单**：

| Provider | 形态 | 状态 |
|---|---|---|
| MCP（经 LocalGateway） | Claude Code / Codex 推草稿 | ✅ M2 |
| HTTP push（经 LocalGateway） | 脚本 POST | ✅ M2 |
| SSE 订阅 | 订阅外部事件流 | 计划 M6 |
| SSH | `/usr/bin/ssh` 子进程流式读 stdout；密钥全交 ssh-agent，输入法不碰；用 argv 数组防参数注入 | 计划 M6 |
| Remarkable（显式只读动作） | SSH 稳定定位当前页；固定初始 USB Web URL 导出 PDF；PDFKit 目标 300 dpi 有界渲染 + Apple Vision 在 Mac 本地 OCR | ✅ 内置缓冲插件；不等同于通用 SSH provider |
| RemotePeer | 现有 X25519+AES-GCM 通道 | 现状=直通上屏档（不改道，产品决策） |
| Action Plugin | `~/Library/RimeBuffer/plugins/*/manifest.json` 声明动作；按 runtime config 走本机 Bearer HTTP | ✅ 通用宿主；具体插件独立安装 |
| MarineBridge | 旧 `/buffer-state/latest` 轮询实现仍保留源码，但 focus 主路径已解除调用 | 仅兼容存档，不是新链路依赖 |

### 4.4 Action Plugin 宿主、实时翻译与 Remarkable 本地 OCR 导入

每个插件目录包含 schemaVersion=1 的 `manifest.json`，声明插件 id/name、runtime config 候选路径和动作 `id/title/symbol/statusPath/invokePath/modes`；需要由 Rime 执行模型的动作可增量声明 `preparePath`，互斥场景动作还可声明成对的 `presentationId/presentationTitle`。同一插件内共享 presentation id 的动作必须共享标题和 status/prepare/invoke/stream 契约；请求、流事件、结果元数据与发送复核始终保留 status 当前选中的真实 action id。当前 owner 解析后的整个动作面只有一个 presentation 且它是 prepared 时，工作台把它提升到右侧 AI 主控件并从展开层隐藏；只要存在任意第二个 presentation，就全部保留为显式按钮，Return 不猜测。runtime config 只接受 `localhost/127.0.0.1/::1`，必须包含与 manifest 精确相同的 `pluginId` 以及 `apiBase/token/updatedAt`（可附 `instanceId/processId`）；宿主拒绝符号链接、非普通文件、相对路径逃逸和超过 1 MiB 的配置，按更新时间从新到旧探测，跳过已失效的残留配置。一次 status 成功后，prepare/invoke、生成后的复核与发送前复核都锁定该精确 runtime binding，期间出现更新的配置也不能把请求切到另一实例。工作台可见时每秒轻量刷新状态，因此“先开缓冲、后选浏览器目标”和“先选目标、后开缓冲”都成立，设置/菜单中的底层缓冲启停本身不参与目标发现。展开区的刷新/重置会取消当前及过时调用、清掉本次失败状态并强制重新获取当前上下文，但不修改 `BufferModel` 正文。

`ActionPluginManager` 管理 `~/Library/RimeBuffer/plugins`：本地安装可复制完整插件目录或单一清单，网络安装只接受 HTTPS `manifest.json`，不解压归档、也不执行安装脚本；安装过程使用同目录暂存与替换，并拒绝异 ID、大小写碰撞及符号链接重定向。底层启用状态仍单独持久化并在损坏时 fail-closed；设置页把安装、卸载、刷新和打开目录收进三个操作弹窗，插件行不再暴露底层启用与当前 owner 两套状态。管理读写串行化，远端下载绑定 mutation generation，后发的启停/卸载可让迟到下载失效，不能复活插件。管理变更通过通知让 `ActionPluginHost` 立即重载；插件被禁用、卸载或升级时，旧动作、在途调用、发送复核和 bearer 绑定同时失效。

用户点击显式动作，或对唯一 prepared presentation 点击右侧 AI 主控件/按 Return 时，宿主冻结 `actionId + requestId + contextId + FocusToken + runtime binding`，但绝不把 IMK client、FocusToken 或 bearer token 交给插件。带 `preparePath` 的动作先返回 `protocolVersion=1 + resultFormat=blocks-v1 + pluginId/runtimeInstanceId/requestId/actionId/contextId + prompt`；宿主逐项校验插件、实例、请求、动作、上下文和 256 KiB 上限后，才把 prompt 交给当前 Rime AI 连接器。模型选择、订阅/API 凭据、CLI 参数、工具开关与结果 schema 全部留在 RimeBuffer，插件不能覆盖。没有 `preparePath` 的旧插件仍走 legacy invoke/stream，保持 Action Plugin v1 向后兼容。

模型完成后或 legacy invoke 完成后，宿主都用同一 binding 再读取一次 status：响应 id、当前 context 和原焦点租约全部匹配时，结果作为 `.plugin(id)` Block 进入缓冲；任一项失效时，带 `stale=true` 元数据进入 `InboundBus` 等人工接受。用户随后发送仍绑定目标的插件块时，唯一投递协调器还会异步重取同一实例的 fresh status，并在回调后再次核对原 `FocusToken/context/action`；切到另一评论后，迟到的“允许”回调也只能把旧块标记过期，绝不进入 `Delivery.insert`。若用户在收件箱明确选择“作为普通文本加入”，元数据会转为 `reviewedAsPlainText=true`：保留来源和原目标仅供核对，但永久解除旧浏览器绑定，之后像普通块一样只投递到用户当时明确聚焦的输入框。两条路径本身都不调用 `Delivery.insert`，因此不会自动上屏。

设置中的缓冲插件 Switch 独立管理一个可多选的启用集合；Marine、实时翻译与唯一「AI 生成」插件都以带 SF Symbol 的同类卡片呈现。具有声明式 schema 的内置或宿主已知插件统一显示“设置…”按钮，由 `PluginConfigurationViewController` 渲染，不允许外部包注入 AppKit 视图。`PluginConfigurationUserDefaultsStore` 以每插件单字典保存普通偏好；含 `secureText` 的配置必须进入 0700 目录中的 0600 私有文件，保存通知只携带插件 ID 和字段 ID。完整约束见 [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md)。外部 Action Plugin v1 无需升级 manifest：身份图标继承首个 action 的 `symbol`，未知符号回退为通用拼图。展开工作台中的紧凑选择器只枚举已启用集合，并以 `Default` 表示显式不使用插件；`BufferPluginSelectionStore` 再把集合中的选择收敛为一个当前 owner。选择器与 `Command+Shift+↑/↓` 共用这一有序目录，键盘在两端循环，并在提示文字中公开快捷键。两条入口都只原子替换 owner，不改其他插件的启用状态；关闭当前 owner 的后台 Switch 会同时回到 `Default`。缓冲插件不会贡献动态“扩展”路由。旧版本中三个 provider-specific plugin id 会迁移到「AI 生成」owner，并把原选择保留为连接器偏好。owner 切换会取消旧 owner 的在途请求、停止其工作台状态并作废旧翻译/AI generation，但**不撤销已完成 Action Plugin block 生成时的投递 authority**：例如切到「AI 生成」后，已完成的 Marine 块仍可用原 runtime binding/action/context/focus 复核。只有该外部插件被禁用、卸载、升级或原 runtime 失效时，才撤销对应已完成结果的权限。

实时翻译不伪装成 HTTP Action Plugin。`AppleTranslationWorkspace` 读取 `BufferModel.stagedText`；界面上方源轨合并显示全文且不分 block，下方目标轨独立显示译文 block，两条轨道分别横向滚动。顶部功能栏永久显示且空白区域可拖动，发送按钮对齐下方目标语言行。默认 provider 是 Apple 本地翻译：AppKit 工作台挂载 1×1 的 `NSHostingView`，通过 SwiftUI `translationTask` 获得只在视图生命周期内有效的 `TranslationSession`，原文不交给网络服务。用户也可选择当前 AI 渠道；宿主用严格 JSON 边界构造翻译请求，再由共享 `AITextConnectorRegistry` 执行。自动刷新采用 single-in-flight + latest-queued；只有与当前原文、语言和 provider 配置完全匹配的 generation 才进入可发送态。保存配置或点击顶部功能栏的刷新/重置时，保留原文 `BufferModel`，作废旧 generation 并按新快照重启。未 review 的 Action Plugin 目标绑定块禁止作为翻译源，避免加工后绕过原焦点/上下文校验。`BufferDeliveryCoordinator` 通过 `BufferDeliveryContentSource` 选择普通缓冲或译文缓冲，并在每个 block 投递前按 workspace/generation/id 重取实时内容。译文 `.processor` 来源继承所有源 block 中最严格的 remote-mirror 策略。

Remarkable 同样不伪装成 HTTP Action Plugin，也不成为派生 delivery source。它实现通用的内置货架动作接口；设备必须先开启 USB Web interface 并通过 USB 连接，只有用户点击“识别当前页”才开始读取。插件通过 `/usr/bin/ssh` 按 `.metadata.lastOpened` 选择最近打开文档，从 `.content.cPages.lastOpened.value` 定位当前页及其 PDF 页序，连续读取两次 `<document UUID>/<page UUID>.rm` 并要求字节完全一致，以此冻结识别前的页面身份与内容快照。

生产文字路径不再读取 software 3 / v6 root text。插件以固定初始 URL `http://10.11.99.1/download/<document UUID>/pdf` 请求文档 PDF，通过禁用代理的固定 `wget` 命令接收有界数据；初始 URL 不随 SSH host 配置扩展。真机 USB Web interface 没有带可靠页面身份的高分辨率单页导出路由，384×512 文档缩略图也不足以替代正式 OCR，因此生产路径保留整本 PDF 以保证中文手写准确率。PDF 导出后，插件重新读取最近文档、`.content` 当前页和 `.rm`，只有 document UUID、page UUID、页序及页面字节与导出前全部一致时，才把冻结的 PDF 交给 `RemarkableLocalOCR`。后者在内存中用 PDFKit 再次校验文档和目标页，以 300 dpi 为目标渲染该页，并以最长边 4096 px、总像素 1200 万作为安全上限，再交给 Apple Vision accurate recognition 在 Mac 本地生成正文。后台插件页和缓冲工作台动作旁共用一个 OCR 语言配置；默认简体中文以 `zh-Hans` 优先、`en-US` 后备，也可选繁体中文、英文或繁简混排自动识别。运行中切换语言会墓碑化旧请求并立即按新语言重启；去重身份包含来源、页面和语言。成功正文经 `BufferModel.stageExternalSemantic(..., origin: .ssh)` 一次性加入普通缓冲。PDF 数据、渲染位图和 OCR 正文全程只在进程内存中存在，不写临时文件或正文日志；Return 与纸飞机仍只走既有 `BufferDeliveryCoordinator`，绝不自动发送。

SSH 用户可配置 host、用户名和密码，也可不填密码而使用 key/agent；USB Web PDF 目标不随 SSH host 配置扩展为任意 HTTP 主机。密码保存在 `~/Library/RimeBuffer/plugin-config/builtin.remarkable/credentials.json`（目录 0700、文件 0600）；密码模式以 `BatchMode=no`、禁用公钥回退和受限 `SSH_ASKPASS` 读取该文件，密码不进入 argv、环境值、日志或通知。无密码模式使用 `BatchMode=yes`。两种模式都严格校验 known_hosts、固定只读远端命令、UUID/host 与有界 stdout；未知主机必须由用户从可信渠道核对指纹后显式加入 `known_hosts`。插件不调用 reMarkable 官方或其他云端转写、不上传 PDF/页面、不停止 Xochitl，也不修改设备。配置变化、owner 切换、禁用、关闭、secure input、锁屏、睡眠与会话切出都会取消并墓碑化在途识别。

```
当前 BufferModel 全文 ─Return/右侧 AI 主按钮─▶ AITextPluginWorkspace 冻结 source text + block IDs
Marine 页面上下文 ─Return/右侧 AI 主按钮─▶ Marine prepare prompt ─▶ ActionPluginHost 冻结目标 authority
                                                          │
                                                          ▼
                                                AITextConnectorRegistry
                                     （与 buffer plugin owner 独立的单选）
                         ┌─ CodexCLITextProvider ───────── app-server + stdio JSON-RPC delta
                         ├─ ClaudeCodeCLITextProvider ───── Process + stdin + stream-json partial
                         └─ OpenAICompatibleTextProvider ── URLSession + chat/completions SSE
                                                          │ 活动/秒数先行；delta 真流式；细粒度 block 原位更新
                                                          ▼
                              AI target rail / Action Plugin blocks（完成后才可发）

当前完整意识流 raw ─可配置、默认 220/800 ms 自动刷新/全局重算─▶ StreamInputWorkspace
                                  └─▶ 意识流独立选择的 AITextProvider（默认 OpenAI 兼容）
                                      └─▶ 1–3 个完整互斥猜测 ─稳定槽位连续渲染─▶ 仅 final 所选项可发
```

- **翻译（已实现）**：当前 macOS 15.1 SDK 下使用 SwiftUI `translationTask(configuration)` 桥接；Translation 与 `_Translation_SwiftUI` 弱链接，最低系统仍是 macOS 13，13/14 只显示不可用状态。`prepareTranslation()` 由系统在首次使用语言组合时准备本地模型。
- **Codex/Claude CLI**：Codex 用一次性 app-server 的双向 stdio JSON-RPC 接收 `item/agentMessage/delta`；除显式 `RIMEBUFFER_CODEX_PATH` 覆盖外，自动探测优先 ChatGPT.app bundled Codex，再按顺序选择第一个通过能力检查的 Homebrew、用户 PATH、常见版本管理器或编辑器内置安装。专用 ChatGPT 登录持久化在 `~/Library/RimeBuffer/ai/codex-home`，它不读取 `~/.codex`，设置页也把凭据状态与 CLI 能力状态分开呈现。结构化 account/login 流程只打开受限 HTTPS 授权 URL，以 loginId 匹配完成事件并经 account/read 复核 ChatGPT 账户；生成前再断言 MCP 列表为空。Claude 在后台以 `claude auth status --json` 的 `loggedIn` 布尔值检查 CLI 授权，设置页通过固定 `claude auth login --claudeai` 浏览器流程授权，生成则用 `stream-json` partial。RimeBuffer 不读取 Claude 凭据文件，不传透 `CLAUDE_CODE_OAUTH_TOKEN`、`CLAUDE_CONFIG_DIR` 或 ambient API key。兼容性不依赖版本号：Codex 以完整隔离 argv 的无提示词 initialize + 空 MCP 握手为准，Claude 以实际生成所需的工具关闭与流式参数为准；满足能力契约的新旧版本均可使用。能力/授权结果在后台缓存并周期复核，hot path 不启动子进程；生成前以 stat 指纹确认已验证可执行文件未被替换。两者都由 `Process` 直接启动，参数固定，工作目录临时且为 0700，不启用 shell、工具、网络工具或会话持久化；能力或隔离参数不成立时 fail-closed。这是“本地启动 CLI”而不是“本地推理”。
- **OpenAI 兼容 API**：在“设置 › 连接器 › AI 模型”配置 Base URL、model 和 API key；端点为 `POST {baseURL}/chat/completions`，必须返回 SSE，按 `choices[].delta.content`/`[DONE]` 收口，2xx 非 SSE 响应 fail-closed。远程地址必须 HTTPS，HTTP 仅允许 loopback，且拒绝 userinfo/query/fragment 与 redirect。意识流 `.alternativeGuesses` 专用请求显式关闭 `thinking`、要求 JSON object、设置 `max_tokens=1024` 与低 temperature；普通「AI 生成」不带这些字段。阶段诊断只记录 UUID、状态码、耗时、字节/块数和枚举结果，并通过进程级异步串行 writer 写入，不含 URL/model/raw/prompt/正文/key。配置与密钥存于 0600 文件 `~/Library/RimeBuffer/ai/openai-compatible.json`，不写 UserDefaults 或日志。意识流不读取普通连接器的当前单选，始终直接使用这份配置（当前模型 `deepseek-v4-flash`）。`ai` 是 app bundle 外的产品持久状态：开发重播种、pkg 覆盖安装和应用内更新都必须保留，用户无需在版本更新后重新填写。
- **意识流调度与连续渲染**：连续字母或已结算 FlyYao 批次只重置 220 ms debounce；本次 burst 首次 raw 变更建立的 800 ms max-wait 不重置，因此不停输入也会按上限刷新。显式 `.chord`/`.mutual` 的第一枚键先撤销旧投递权，再按 `ChordSettings.duration` 等待当前物理批次；并击只映射同批，互击还能把有效的相邻左/右半区批次重组。所有精确映射都一次性写入全拼，但只有完整音节同时追加一个 soft ASCII Space，尚未配对的单侧拼音片段与单键不加 Space，无映射批则保留字母原码且不伪造分隔。soft Space 走普通 debounce。用户物理 Space 写入 hard boundary；若 raw 已以 soft Space 结尾则只移除 sidecar 标记、原位提升同一字节。hard Space 上轨显示 `·`，立即触发完整快照请求；前导/连续 hard Space no-op。数字 `1`–`3` 与普通 ↑/↓ 只切换尚未确认的候选；修饰方向键仍放行。精确 Control/Command+A 选中 raw 上轨，Control/Command+V 将 ASCII 字母小写化、把空白段归一为 hard Space 并立即触发一次完整 raw 请求；非法字符或 16 KiB 越界时整次粘贴原子不改状态。workspace 采用有界 make-before-break，最多允许旧视觉 producer + 新 challenger 两路；跨 revision 的旧响应、所有 partial 和 baseline 只服务于显示，绝不进入下一轮 prompt。唯一例外是同 revision 的一次 minimum-candidate retry 可携带此前严格验证的 final 作为有界 JSON 排重数据；墓碑回调仍按 job/generation 丢弃。
- **意识流全局推断边界**：请求边界始终冻结并发送当前包含 ASCII Space 的完整 raw 拼音以及 soft-space offsets，任何响应都是对全文的替代解释。`StreamInputPinyinHints` 产生最多三条 lossless 边界提示，不跨 hard Space 组音节并以 ` | ` 显式保留 hard boundary；soft Space 作为普通拼音音节边界保留，未知 English/错键不丢失，超过 512 bytes 时省略提示。本地提示数大于一时 `minimumGuessCount=2`。首个严格合法 final 不足下限时只重试一次，已验证候选作为有字节上限、JSON 编码且明确不可信的 `excludedGuesses` 送入重试；新旧 final 以旧候选优先顺序合并、精确去重并截到三条。重试仍重复或失败时，此前合法 final 仍可 ready；retry partial 与 baseline 永不成为 fallback，首轮没有合法 terminal fallback 的 schema/非空/大小失败仍拒绝。retry partial 从旧候选之后的稳定槽位开始，final 逐槽精确替换；多候选按行呈现，行内再做确定性宿主分块。每个非空 hard-Space 子句提出一个最小投递块目标，soft Space 不增加该目标；若补拆会切断英文单词、URL、代码、数字或引文，受保护片段保持原子。协调器在冻结 delivery generation 前确认当前候选并清除其余候选，Return keyDown 也执行同一确认，因此同一次轻按可从 keyUp 开始发送。raw 贯穿所选答案的部分投递保留，最后一块成功才连同结果清除；首块投递后主动继续输入才会建立全新 raw 并撤销未发送尾部，已投递前缀不得复活。
- **共同隐私/体验边界**：普通「AI 生成」与当前唯一的 prepared Action Plugin 都只在用户用 Return 或右侧 AI 主按钮明确请求时运行；多个 prepared 动作不会被 Return 自动选择，仍要求点击各自的显式动作。意识流是唯一按输入停顿自动请求的 AI 例外，且只发送当前焦点绑定的 raw 全拼。普通「AI 生成」只发送当前 `BufferModel.stagedText`，不附带历史、preedit、剪贴板或屏幕上下文；prepared Action Plugin 只发送插件明确返回且通过身份校验的 prompt。首字前仅展示安全的连接/思考摘要/重试/校验状态与等待秒数，不展示 raw chain-of-thought。普通生成正文可细分为受保护的语义 block；意识流的每个结果则必须是可独立投递的完整猜测，不得在候选间拆句。未 review 的 Action Plugin 目标绑定块不能被作为普通 AI 源文。
- **Marine 边界**：Marine 继续负责浏览器上下文、话术规则、记录和界面信息，并通过 `preparePath` 产出 prompt；它不保存模型凭据、启动 Codex/Claude 或直接调用 OpenAI。插件设置中的 AI 渠道写回 RimeBuffer 的共享连接器选择；60–600 秒调用超时只影响新请求，并在调用边界冻结。连接器执行与 `blocks-v1` 结果校验都在 RimeBuffer 内完成，最终块仍绑定 Marine 原来的 runtime/context/focus authority。

### 4.5 投递层

```
InputFocusCoordinator.liveTarget(expected: token)
  · controller + client 对象身份 + bundle id + 前台 app 四重一致
  · 自身设置等窗口不是外部投递目标
                         │
                         ▼
BufferDeliveryCoordinator.sendNext/sendAll
  · Return 轻按调用 sendNext、长按调用 sendAll，主条纸飞机只调用 sendNext；键盘路径固定使用 keyDown token，每个块前重验 token 与 secure input
  · 调用成功后从 live buffer 消费块，不保留明文发送历史
  · 调用失败即停止，失败块与尚未发送块原位保留
                         │
                         ▼
Delivery.insert(_ text, into: client)
```

- **Delivery.insert 是所有上屏路径的唯一咽喉**——直接 commit、缓冲发送、raw、单字、远端收字，全走它。密码框护栏放在这一处；缓冲路径在上游再做一次可解释的可用性检查。
- **不存在 last/recent client 回退**。目标丢失时发送按钮禁用；发送过程中目标变化则停止在下一块之前，之前成功的块已从 live buffer 消失，失败块与剩余块继续待发送。

---

## 5. UI 架构

### 5.1 输入候选面与独立缓冲工作台

```
普通输入                         缓冲模式（普通 / 派生多行）
┌──────────────────────┐       ┌─────────────────────────────────────┐
│ CandidateWindow       │       │ ↑ 工具层                              │
│ 跟随 caret 的候选面板   │       │ 常显工具栏：普通 78pt / 派生 112–174pt  │
└──────────────────────┘       └─────────────────────────────────────┘
                                      │ 候选锚点
                               ┌──────▼──────────────────────────────┐
                               │ 同一个 CandidateWindow 常规候选面板  │
                               └─────────────────────────────────────┘
```

- **缓冲工作台是独立 `NSPanel`**：默认 nonactivating，不抢目标输入框焦点；顶部功能栏永久展开，普通高度固定 78pt。实时翻译、AI 生成与单候选意识流的 source rail 在上、target rail 在下，固定为 112pt；Marine Chrome 的空上下文态折叠 source rail，以单 target rail 保持 78pt，真实上下文摘要或用户备注出现后才恢复 112pt；意识流出现 2/3 个候选时 target 增为 2/3 条独立滚动行，对应高度为 143/174pt。每条 target row 行内再以 chips 显示宿主分块。增长时必须先扩展 panel/rail 并完成 layout 再挂新 row；缩小时先移除 row 再收窄高度。每个横向 document stack 禁用 autoresizing-mask constraints，高度绑定 scroll viewport，并在 host geometry 变化后重算 document size。主条只保留正文轨与右侧主操作，发送与最下方目标行对齐。顶部功能栏固定显示状态、紧凑插件选择器与当前动作、右侧上下文诊断、刷新/重置与关闭，不再含 disclosure、专用拖拽手柄、块编辑器或面板内缓冲开关；其空白、间距与弹性留白可拖动窗口，`NSControl` 与正文轨不可拖。切 owner 与 target row 数变化都只向上调整并固定底边，所以条下方 Rime 候选锚点不跳。窗口仍可调整宽度，frame 持久化并在屏幕拓扑变化后夹回可见区域，旧展开态偏好不再参与布局。原来的标题/字数、手动遮蔽、历史、清空和工具层发送入口均已移除。
- **全局切换快捷键**：`GlobalHotKeyController` 用 Carbon 注册精确 `Command+Shift+B`，不需 Accessibility 权限，按下后调用 `BufferWindowController.toggleVisibility()`。关闭时它把非 pin 面板带到当前 Space、显示窗口并恢复 `BufferModel.enabled`；打开时复用 `closeAndPause()`，安全收束当前组字、保留块、暂停捕获并隐藏。该注册快捷键被消费，B 不继续传给前台应用。
- **边缘绘制**：圆角层内缩到透明窗口边距，并覆盖固定的日/夜工作台背景 token，避免 HUD 背景采样破坏对比度；边框按 backing scale 以路径内 hairline 绘制，避免把居中 border 压在窗口 bounds 上造成圆角或边缘裁剪毛边。
- **关闭不会删除已有块**：先显式收束当前组字，暂停捕获，结束 transient 加载/错误状态并保留已有模型块，再隐藏。从设置/输入法菜单显示工作台时会恢复底层捕获。工作台没有手动清空或撤销入口；隐私选项触发的跨 app 清理仍是不可恢复的安全操作。
- **常显与多屏**：pin 开启时加入所有桌面与全屏辅助空间；关闭时只属于一个 Space。工作台位于当前 Space 时，常规候选面板使用细条下沿作为锚点；需要时仍可跟随 caret。菜单“显示”会把仍留在旧 Space 的面板重新带到当前 Space，菜单和设置都能把窗口移到鼠标所在屏幕。
- **隐私**：工作台不再维护手动遮蔽状态；secure input 会隐藏正文并禁用发送与插件动作。此时 Ctrl/Cmd+A/V 保留宿主原生处理，RIMES 在任何 pasteboard API 调用之前就返回。锁屏、睡眠或会话切出会撤销 FocusToken，只在 Rime 内回收/丢弃组字并隐藏窗口；恢复后等待新焦点租约。可选的切 app 清理只认真实外部 A→B，A→本应用窗口→A 不清理；混有任一外部来源块时则整体保留。
- **Rime 候选呈现可配置**：默认把常规 `CandidateWindow` 放在工作台底边下方；用户可切回跟随 caret。两种位置只改变锚点，始终是同一个面板与 token 化选择动作，不存在 Rime 投影视图或第二份 Rime 候选状态；意识流 target rows 是另一类派生交互。
- **外部待决项**：当前仍由 `InboundTrayWindow` 接受/拒绝；异步来源只更新数据，不会自行拉起工作台。`WorkbenchBarView` 仅保留为历史三层方案素材；`panel-render` 已直接渲染真实 `BufferWindowController`，避免预览与运行时再次漂移。

### 5.2 设置窗（垂直一级导航 + 横向子页）

```
左侧一级导航
├─ 输入法：输入编码 / 键入模式 / 词库
├─ 外观：候选窗 / 主题
├─ 缓冲区：常规 / 工作台
├─ 连接器：隔空传字 / 本地网关 / AI 模型
├─ 插件：全部 / 缓冲插件 / 内置扩展
├─ 维护：更新与重启 / 日志与数据
└─ 扩展（动态）：打字测速、统计、飞耀互击学习……
```

- 每个一级页的子页固定显示在右侧顶部；route/subpage 使用稳定字符串身份，不依赖 sidebar 行号。启停内置扩展后目录会重建；若当前扩展被停用，安全回退到「插件 ▸ 内置扩展」。
- 输入法页明确分开三层：输入编码、键入模式和词库。运行时只暴露经过验证的 Rime 组合方案，不允许三层任意交叉，以免生成不可部署配置。`my_combo` 的产品名是「飞耀互击」；同一 schema 由完整的 `InputConfiguration.keyingMode` 区分“只结算当前批的并击”与“可跨批配对左右半区的互击”，两者都保留多键单侧批次，不能从 schema ID 反推。单个物理字母保持英文原码且不自动添加分词符；互击只在至少一侧为多键和弦时跨批配对。`my_combo` 仅覆盖物理和弦映射，候选拼写、中文/英文翻译及过滤链继承 `rime_ice`，因此多音节组字仍能选择前缀单字并正常翻页。无映射批保留可由 Return 提交的原码；`,`/`.` 只在 chord alphabet 中充当双角色键，单键结算继续落到 punctuator。词库页通过 librime `levers` API 维护真实的 `rime_ice` / `english` 用户学习库，导入是合并，导出是可移植 TSV，不复制 live LevelDB。
- 缓冲区、连接器和外部插件管理仍接真实运行时；“AI 模型”子页用单选控件在 Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 三个模型源间切换，展示两个 CLI 的可用性与授权/远程服务隐私说明，并管理 OpenAI 兼容 API 的 Base URL、model 与 API key。该单选独立于缓冲插件 owner；AI 生成、实时翻译和 Marine 的配置页可写回这个共享选择，意识流则维护自己的渠道选择（仍复用连接器授权/凭据）。插件列表中凡 registry 能解析配置 schema 的项目都显示同一个“设置…”入口。通用 SSE/SSH provider 尚未实现；Remarkable 只是用户显式调用、目标与命令固定的专用只读 SSH 动作。当前没有按来源编辑信任等级或重新生成 token 的 UI。

### 5.3 统一插件平台

- `PluginRegistry` 是发现、命名空间、内置扩展生命周期和统一启停 facade；`PluginKey(domain, rawID)` 防止内置与外部包同名遮蔽。
- **外部缓冲插件**仍完全沿用 Action Plugin v1：`ActionPluginHost + ActionPluginManager` 是执行、runtime binding、授权与撤权的唯一 authority。Registry 不重建 wire metadata，也不能让外部包贡献原生 AppKit 设置页，因此 Marine 兼容路径不变。
- **内置扩展/缓冲插件**是随应用编译的可信模块。统计、打字测速和飞耀互击学习贡献动态设置页；实时翻译、My Prompt、Remarkable、唯一「AI 生成」与「意识流输入」贡献 `.bufferAction`，在唯一 owner 下与 Marine 等插件互斥运行且不出现为左侧动态扩展页。My Prompt 是本地优先的派生检索 workspace；Remarkable 是普通缓冲的显式 importer，不建立 source/target 派生轨；二者都不会自动上屏。Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 是 `AITextConnectorRegistry` 下的三个普通连接器，不再是三个插件；意识流用自己的 provider 字段选择其中一个，默认 OpenAI 兼容，不跟随共享 AI 单选。
- `InputTelemetryBus` 是非消费型、脱敏的主线程观测通道：不携带正文、候选、IMK client、FocusToken、应用或焦点身份。secure input、RIMES 自身窗口和不可信/失焦目标不发事件；字符计数只在真正进入缓冲或 `Delivery.insert` 成功后发布。

### 5.4 其它 UI
- **StatusMenu**：系统输入法菜单里的命令入口。
- **InboundTrayWindow**：外部来源收件箱（过渡态，将并入传入轨）。
- **KeyboardHeatmapView / YearHistoryHeatmapView**：统计内置扩展中的每日键盘热力图与全部历史日历热力图。
- **开发预览模式**：`settings-preview/render`、`panel-render`、`gateway-serve` 子命令，无头渲染/验证，不接进正式菜单。

---

## 6. 并发模型

现有代码的最硬约束：IMKit client 只能留在主线程，而翻译/LLM 必然异步。三条规则拆解：

```
① UI 与 IMK 全部主线程       IMK 回调、NSPanel 渲染本来就在主线程，维持现状
② Provider 在工作队列运行  Apple Translation task / CLI Process / URLSession SSE 不持有 IMK client；
                             它们只携带值类型 source snapshot，回调切回主线程并按 generation 写 workspace
③ 投递仍由协调器串行化   派生 target blocks 先留在独立 workspace；BufferDeliveryCoordinator 为每块
                             重验 workspace/generation/id 与 FocusToken，全部成功后再消费 source
```

- **Provider 侧**：LocalGateway 在独立 NW 队列，产出统一 `DispatchQueue.main.async` 进 InboundBus（主线程）。
- **IMKit 边界（Swift 并发注意）**：`IMKTextInput` 非 Sendable，client 引用永不离开主线程，跨进 actor 的只传值类型快照。

---

## 7. 安全与隐私模型

```
威胁模型：token/0600 只防「跨用户 + 网络」；同用户进程在信任域内（能读 0600、能走 Accessibility）
```

| 措施 | 机制 | 状态 |
|---|---|---|
| 密码框保护 | `IsSecureEventInputEnabled()` 在投递动作时刻同步查；命中拒发 | ✅ M0（Delivery 唯一咽喉） |
| 切换应用重置 | 默认跨应用保留；启用后，仅当整个缓冲不含外部来源块时不可撤销地丢弃 blocks；只要含外部块就全部保留 | ✅ |
| 焦点租约 | 单调 FocusToken + controller/client 对象身份 + client bundle + 前台 bundle/PID + 事件/生命周期归因；Spotlight 另需唯一系统 PID、可见窗口、前台锚点及 keyDown 建权；无 recent/last client 回退 | ✅ |
| 工作台隐私 | secure-input 自动遮蔽正文并禁用发送/插件动作；锁屏/睡眠/会话切出撤销租约且不回写旧 client；自身设置窗口不成为缓冲捕获源 | ✅ |
| 日志脱敏 | 用户文本走 `IMELog.redact()` 只记长度；日志 0600；CI 断言禁 `'\(…)'` 明文 | ✅ M0 |
| 本地端口鉴权 | 只绑 127.0.0.1 + Bearer token（0600）+ 常数时间比较 + 严格解析上限 | ✅ M2 |
| Marine Chrome 配对 | 固定 manifest ID 仅收窄 Origin；首次连接需 RIMES 原生确认，并以 60 秒随机 claim 领取专用 Bearer；拒绝/超时不覆盖旧凭据 | ✅ |
| 来源门控 | `SourceTrust` 有询问/信任/拦截三种类型；当前规则固定：Marine 信任，MCP/HTTP/SSE/SSH 询问，无按来源覆盖 UI | ✅ 固定规则；可配置化属后续 |
| echo 防回环 | remotePeer 来源不回镜；规则在 `Origin.allowsRemoteMirror` 与镜像调用点，不依赖尚未实现的 Router | ✅ 规则就位 |
| MCP 隐私边界 | 工具只给不看不发；无读缓冲/读上下文/触发投递工具 | ✅ 写死 |
| 网络出站清单 | 隔空传字、更新检查与用户显式调用的 Codex/Claude/OpenAI 连接器已存在；SSE 订阅/SSH 仍属后续 | ✅ 已实现项按用户动作或现有设置运行 |
| AI 连接器隐私红线 | 只在点击生成时发当前缓冲全文或通过身份校验的 prepared prompt；CLI 非本地推理；工具/会话关闭，能力与隔离契约不成立时 fail-closed | ✅ |
| CLI 授权边界 | Codex 只用应用专属 `codex-home`；Claude 只调官方 CLI 登录/状态命令，不读凭据文件或传送 OAuth token/替代配置目录；Marine 不接触凭据 | ✅ |
| OpenAI 凭据 | Base URL/model/API key 保存到 0600 私有 JSON；拒绝非 HTTPS 远程端点与 redirect | ✅ |

**明确不做**（v1 边界）：剪贴板捕获、AirDrop 目标、Turn/Artifact 完整版本模型、宿主文本撤回，以及工作台内的块级/无边界自由编辑面。

---

## 8. 进程、生命周期、持久化

- **进程**：单进程后台 agent（`LSUIElement`，`.accessory`）。IMKServer 连接名必须与 Info.plist 一致。持进程生命周期。
- **身份三元组冻结**：bundle id `com.isaac.inputmethod.RimeBuffer` + mode `.Hans` + 目录 `ETInput.app`，CI 断言钉死字面值（防重复注册鬼影）。
- **持久化**：
  - UserDefaults：缓冲开关、工作台显隐/frame/常显/候选锚点、跨 app 清理选项、并击时长、候选窗尺寸、网关开关/端口、外观。按来源信任覆盖尚未实现，因此当前不在持久化项中。
  - 仅进程内：缓冲 blocks；输入法进程重启后不恢复，发送历史与清空撤销不再保留。
  - 0600 文件：gateway-token、marine-chrome 专用 token/origin、remote 身份私钥、`ai/openai-compatible.json`（Base URL/model/API key）。
  - 0600 JSON：按键统计（按日 + 全历史）、打字测速聚合、飞耀互击学习进度；测速中的“成文字符”按 Rime commit 计数（直输或进入缓冲均计入），只保存数量、不保存正文；损坏、超限或非普通文件均 fail-closed，不覆盖原数据。
  - Rime 用户数据：`~/Library/RimeBuffer`；词库维护只经官方 `levers` 导入/导出 portable TSV 或恢复官方快照，不直接复制/修改 LevelDB。
  - 日志：`~/rimebuffer.log`（0600，脱敏）。
- **自更新**：UpdateManager 每小时查 GitHub Releases（这是隐私清单要计入的第 5 处出站）。
- **发布链**：build_install.sh（dev→~/Library）/ scripts/make-pkg.sh（pkg→/Library）/ CI（编译 + plist 断言 + 日志断言 + smoke 组）/ release.yml（通用二进制）。签名为 ad-hoc（Dev ID 未申请，是钥匙串决策的根因）。

---

## 9. 模块地图（现有源码，约 31000 行）

```
Sources/CRimeBridge/            librime C API 桥（手写 RimeApi + dlopen）
Sources/RimeBuffer/
  main.swift                    IMK 引导、全局接线、dev 子命令、系统观察者
  RimeBufferController.swift    IMKInputController 子类，事件主路径（最大文件）
  RimeEngine.swift              librime 封装（session 生命周期）
  CompositionSession.swift      marked text / preedit
  CandidateWindow.swift         唯一 Rime 候选状态机/NSPanel + caret/工作台底边锚点
  InputFocusCoordinator.swift   FocusToken / client+前台PID租约 / target-event-lifecycle 规则
  BufferWindowController.swift  永久展开：普通/Marine空态78pt、1–3 target rows的112/143/174pt + 空白拖动工具栏/状态/插件动作/右侧诊断/刷新/关闭
  BufferInlineView.swift        工作台 source选中、待发送 chips、来源徽标与多行 target
  BufferModel.swift             缓冲枢纽（blocks / 全选粘贴 / 成功消费 / transient；无发送历史）
  BufferDeliveryCoordinator.swift 精确目标上的逐块投递与成功块消费
  GlobalHotKeyController.swift    Command+Shift+B 进程级全局打开/关闭
  ActionPlugins.swift            manifest/runtime config/Bearer HTTP/prepare→本地连接器/动作生命周期与安全分流
  ActionPluginManager.swift      插件安装/下载/启停/卸载与原子文件事务
  Origin.swift                  来源溯源 + echo 守卫              [工作台新增]
  Delivery.swift                唯一上屏咽喉 + 密码框护栏
  ChordController.swift         并击 + ChordSettings
  RimeKey/RimeModels/InputSchemaCatalog   键映射/模型/方案目录
  RimeUI.swift                  配色/主题
  StatusMenu.swift              系统输入法菜单命令
  SettingsWindow.swift          垂直一级导航 + 横向子页设置壳
  SettingsRouting.swift         稳定 route/subpage + 动态扩展目录与回退
  PluginPlatform/BuiltInPlugins 统一 Registry、能力模型与内置扩展生命周期
  PluginConfiguration.swift     声明式 schema / 通用表单 / 普通与私有存储
  PluginConfigurationCatalog.swift AI/意识流/实时翻译/Marine 的配置与运行时桥
  AppleTranslationPlugin.swift  实时翻译双缓冲 / Apple 本地 session / AI provider
  RemarkablePlugin.swift        SSH 当前页稳定校验 / 固定初始 USB Web URL 拉取 / 前后复验 / 普通缓冲导入
  RemarkableCredentialStore.swift 0700/0600 SSH 配置 / 受限 askpass
  RemarkableLocalOCR.swift      PDFKit 目标 300dpi 有界渲染 / Apple Vision 本地 OCR / 纯内存边界
  RemarkableSceneTextExtractor.swift 旧 software 3 / v6 typed-text 兼容回归解析器（非生产拉取路径）
  AITextPlugins.swift           唯一 AI workspace、三源 ConnectorRegistry、CLI/API provider 与 0600 配置
  InputTelemetry.swift          无正文/无 IMK 对象的本地输入观测总线
  UserLexiconService.swift      官方 user_dict 导入/导出/快照恢复
  WorkbenchBarView.swift        历史三层面板视觉素材（未接运行时）
  KeyFrequencyStore/KeyboardHeatmapView/YearHistoryHeatmapView 按日与全历史热力图
  TypingSpeedStore/TypingSpeedSettingsViewController 本地聚合测速
  FlyChordLearning*             方案派生课程、专项练习与本地进度
  UpdateManager.swift           自更新
  MarineBridge.swift            旧 Marine 轮询源码（主路径未引用）
  Log.swift                     IMELog + redact
  Remote/                       隔空传字（X25519+AES-GCM 双向 + 配对）
    RemoteTypingService / RemoteConfig / RemoteIdentity / RemoteProtocol
  Inbound/                      来源层                          [工作台新增]
    InboundBus.swift            汇聚 + 门控 + 背压 + 流式
    LocalGateway.swift          回环 HTTP/MCP 服务器
    GatewayToken.swift          0600 token
    InboundTrayWindow.swift     外部来源收件箱（过渡 UI）
  MarineChromeGatewayAuth.swift 专用 token / Chrome origin 配对
  MarineChromePairingPrompt.swift 本机双确认与确认码弹窗
  MarineChromePlugin.swift      短时网页租约 / AI workspace / 安全投递源
  MarineChromeSmoke.swift       协议、租约、origin 与 prompt 边界 smoke
  Extensions/marine-chrome/     MV3 网页传感器、popup、设置与 Node smoke
  AppleTranslationPlugin.swift  实时翻译双缓冲 / SwiftUI session 桥 / AI provider
  AITextPlugins.swift          唯一 AI workspace、三源 ConnectorRegistry、CLI/API provider 与 0600 配置
  [计划] Delivery/DeliveryRouter 多目标投递 + 远端 ACK + 持久账本
```

**测试**：无 XCTest target；CI 运行编进二进制的 smoke 子命令。`plugin-configuration-smoke` 覆盖四插件默认值与运行时桥、每插件普通存储、私有文件 0700/0600、弱权限与 symlink 拒绝、值/通知脱敏，以及 AI 翻译 prompt 的 JSON 边界。`stream-input-smoke` 覆盖 `.chord`/`.mutual` 双路由、同批与跨左右批映射、单键不重组、非和弦边界清配对、自动 soft Space/物理 hard Space 原位提升、提示与宿主分块差异、普通 debounce、首键撤销旧投递权、Backspace 先结算再逐字删除，以及原有焦点/secure/modifier 门、有界双路、迟到回调 tombstone、1–3 个互斥候选、选择/投递和 raw 全选粘贴契约。`fly-chord-learning-smoke` 另验证 fixture 与真实部署 schema 都能被同一 mapper 消费。`buffer-window-smoke` 覆盖普通候选矩阵与意识流 target rail 的真实三行 AppKit 几何、全选显示和动态高度；`matrix-smoke` 覆盖 1–3 行及三行 viewport 上限。`buffer-smoke` 覆盖 Control/Command+A/V 精确组合规则、普通/插件 source 的全选替换、块光标粘贴、语义分块、精确连接文本与纯空白保留；secure input 不读 pasteboard 与延迟读取后租约重验仍需安装后的真实 IMK 交互回归。`ai-text-smoke` 覆盖 provider 逻辑块到工作台的唯一分段、超 20 KB 粗结果、后续上游块 UUID 稳定和 CLI/API 流式收口；`translation-smoke` 与 `plugin-stream-smoke` 覆盖实时翻译、Action/Marine 的分段、权限继承和 partial/final 一致性。这些 smoke 不调用真实模型或用户配置的真实 API；真实 librime 词库桥另有强制隔离 `RIMEBUFFER_USER_DIR` 的 `user-lexicon-bridge-smoke`。

`remarkable-plugin-smoke` 用假 SSH、PDF 导出和 OCR 依赖验证 current-page 定位、双读稳定、PDF 页序、PDF 导出后的文档/页面/字节复验、取消/迟到墓碑、按来源/页面/语言去重和 `.ssh` provenance；固定初始 USB Web URL、禁代理、数据边界和凭据脱敏也由测试钉住。程序化 v6 fixture 继续覆盖旧 root-text 解析器的 CRDT 顺序、删除/格式码与边界拒绝，但该解析器不再进入生产 Remarkable 拉取路径。所有 smoke 都不连接真实 reMarkable、不调用云端，也不打印识别正文。

`marine-chrome-smoke` 覆盖 Swift wire schema、大小/时间/URL 限制、revision tombstone、6 秒过期、Chrome origin/host gate 与 prompt JSON 信任边界；`Extensions/marine-chrome/tests/smoke.mjs` 另覆盖 MV3 权限、协议镜像、精确评论 ID、歧义拒绝、前台 document lease、503 新 revision 重试和通用页面按需注入。两者都不启动真实 Chrome、Bilibili 或模型，真实网页 DOM/API 仍需安装后回归。

- `plugin-smoke` 覆盖 manifest 发现与 schema、可选 `preparePath` 契约、唯一 prepared presentation 提升到主操作及多动作歧义回退、request/generating/deliver 四态、普通块/其他 action/stale 结果不误亮纸飞机、上下文动作聚合及 `status.actionId` 动态切换、`~`/相对 runtime path、runtime 从新到旧回退与 status→prepare/invoke 精确绑定、只允许 loopback、prepared 五字段身份与 `blocks-v1` 格式校验、流式 1 MiB 响应上限、Bearer request、request/context/action/focus 路由规则、切 owner 后已完成 Marine block 仍保留原投递 authority、切换评论后迟到校验不得上屏、收件箱满载显式失败，以及 stale 结果经人工接受后保留来源但安全降级为普通文本。

- `buffer-window-smoke` 覆盖 focus epoch/弱 lease 清理、target 的 current/expected token 与双 client 身份、普通前台 bundle/PID、事件顺序、provisional 与 nil-bundle activation、lifecycle/chord 隔离、own-PID 排除；Spotlight 矩阵另覆盖系统路径/唯一进程、双 PID/锚点匹配、nil anchor bundle 延续、进程重启/窗口隐藏拒绝、activation/keyDown/keyUp 建权差异及 workspace fail-closed；同时覆盖只在真实外部 A→B 触发的隐私清理。
- 同一 smoke 还覆盖工作台布局契约（主条 rail/send、常显工具栏 status/plugin-selector+actions/refresh/close、工具栏空白拖窗而控件与正文轨不拖、状态不泄露应用去向）、`Command+Shift+B` 精确全局路由、缓冲 Return 的轻按/长按轮询判定、Return/Backspace 路由与 callback ownership；另覆盖长按进度在 secure-input 遮蔽时清除、派生 source/target 分行对齐、意识流 1–3 条 target row、全部 target rows 在遮蔽时擦除、active-Space 可见性和窗口 geometry：完全离屏时回到 fallback screen、超宽 frame 收进相交 screen、永久展开的普通 78pt 与 1/2/3 target rows 的 112/143/174pt 高度归一化和底边固定，以及可见区域窄于常规最小宽度时仍能完整放入。`plugin-stream-smoke` 另以 Marine 双 block 结果验证重复的单块主操作每次只消费一个 block。真实 IMK 回调顺序、宿主隔离与实际投递仍需安装后的交互回归。
- `buffer-smoke` 覆盖成功块即时消费且不留历史、未发送块顺序、插入点、暂停保留、transient 状态清理与不可恢复的隐私丢弃。真实窗口关闭/锁屏和 IMK 交互仍需安装后的真机验证。

---

## 10. 里程碑状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0** 安全底线 | 密码框护栏 / 可选切app清理 / 日志脱敏 | ✅ 发布 0.4.4；当前清理默认关 |
| **M1-A** 来源溯源 | Origin / echo 守卫 / 来源徽标 / Marine 正名 | ✅ 发布 0.4.5 |
| **前端** | 垂直一级导航+横向子页+动态扩展 / 44pt 单行条+稳定插件区 / 真实运行时预览入口 | ✅ 2026-07-19 已实现；待真实宿主验收 |
| **spike** | NWListener HTTP/SSE ✓ · MCP 真 Claude Code ✓ · Apple Translation 弱链接/SwiftUI 桥 ✓ | ✅ 全过 |
| **M2** 网关+MCP | LocalGateway / MCP tools / InboundBus / token / 收件箱 | ✅ 主干+收件箱（0.4.7），传入轨嵌入独立工作台待做 |
| **缓冲窗口** | FocusToken / Return+Backspace 隔离 / 44pt 简化主条+78pt 上展 / 常规候选窗下挂 / 成功块无历史消费 / 多屏与隐私 | ✅ 2026-07-18 已实现并通过源码 smoke；待安装后真实宿主输入交互验收 |
| **Action Plugin v1** | manifest/runtime config/loopback Bearer HTTP/可选 preparePath/动态动作 UI/插件管理/FocusToken+context 安全分流 | ✅ 基础宿主 2026-07-18；prepare 2026-07-20 |
| **M3** 实时翻译 | 独立双缓冲 / Apple 本地默认 / 当前 AI 渠道 / 语言选择 / 互斥撤权 | ✅ 已实现；待安装后真语言包验收 |
| **M4** AI 插件与连接器 | 唯一「AI 生成」插件 / Codex、Claude Code、OpenAI 三源切换 / CLI/API 授权 / Marine prepare / 双轨 workspace / 0600 凭据 | ✅ 2026-07-20 已实现；待真实宿主端到端验收 |
| **Marine Chrome** | MV3 前台网页传感器 / 固定扩展 ID / Bilibili 精确回复 / 双确认专用凭据 / 6 秒租约 / 当前 AI 连接器 / 单行空态与状态区 / 显式投递 | ✅ 2026-08-06 0.2 已实现；待真实生成与发布前投递验收 |
| **插件配置** | 统一 schema 与“设置…”表单 / 每插件普通存储 / 0700+0600 敏感存储 / 运行时快照 | ✅ 2026-07-26 已实现 |
| **M5** 投递路由 | 本地精确焦点已完成；多目标 / 远端 ACK / 持久账本仍属后续，当前明确不保存发送历史 | 部分完成 |
| **Remarkable** | 显式只读动作 / SSH 当前页稳定校验 / 固定初始 USB Web URL / PDFKit 目标 300 dpi 有界渲染 + Vision 本地 OCR / 前后复验 / 普通缓冲导入 | ✅ 2026-07-27 已切换本地 OCR，并通过安装后真机当前页验收 |
| **M6** SSE/SSH + 收尾 | SSE/SSH provider / 传入轨嵌入独立工作台 / 视觉对齐 | 计划 |

**作废/推迟**（产品决策）：远端改道 + 协议 v2（配对走直通上屏）；剪贴板捕获；AirDrop。

---

## 11. 关键约束与已踩的坑（给未来的自己）

1. **身份三元组永不再改**——10 天换 5 代身份造成过 10+ 重复注册鬼影，CI 断言已钉死。
2. **Delivery.insert 是唯一上屏咽喉**——任何新上屏路径都必须走它，安全护栏才生效。
3. **FocusToken 是候选与缓冲投递的共同所有权**——迟到回调只能处理自己的 token；普通 App 的前台 bundle/PID 必须匹配；Spotlight 只能走精确系统 allowlist + 绑定 PID + 可见窗口 + 前台锚点的专用路径，禁止把 accessory app 泛化放行；禁止恢复 `active ?? recent`、`lastClient` 或 bundle-only 投递兜底。
4. **NWListener 连接对象必须持有**——不持有会立刻释放，`weak self` 变 nil，连接静默失效（spike 抓到过）。
5. **异步事件不许拉起候选面板或工作台**——外部待决项可更新专用 nonactivating toast/收件箱提示；工作台显隐只由用户与持久化偏好决定。
6. **处理器必须在入缓冲侧跑**——结果先落块，投递路径保持同步、可逐块重验目标。
7. **翻译 session 不得离开 SwiftUI 视图生命周期**——工作台内 1×1 `NSHostingView` 承载 `translationTask`；切插件、安全输入、锁屏和关闭时作废 generation。首次语言组合仍可由 macOS 请求下载本地模型。
8. **钥匙串 vs ad-hoc 签名**——ad-hoc 下钥匙串每次重装弹密码，所有密钥用 0600 文件；拿 Dev ID 后再迁。
9. **owner 不等于已完成块的 authority**——工作台切插件只取消在途工作；已完成 Marine 块必须继续用生成时 runtime/context/focus 校验，不得因 owner 变更而永久失去或绕过权限。
10. **插件不等于连接器**——`.bufferAction` owner 决定工作台能力，`AITextConnectorSelectionStore` 决定模型源；两者不得再次耦合。Marine 只能 prepare 话术与上下文，模型凭据、CLI 隔离、执行及 `blocks-v1` 校验必须留在 RimeBuffer。
