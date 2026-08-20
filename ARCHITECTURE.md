# RimeBuffer P1/P2 历史架构（交接版 v2）

> 本文保留 P1/P2 的设计动因、marked-text 契约与踩坑记录。当前系统结构、缓冲工作台与里程碑
> 以 `SYSTEM-ARCHITECTURE.md` 为准；本文与其冲突时以后者为准。
> v2 与 v1 设计（11-agent 工作流产物）的**最大差异**：真机实测证伪了
> "永不 setMarkedText" 的假设，组字协议全面改为 **marked-text 会话常驻**（§4）。
> 修改本文档时保持"先说做什么、再说为什么"的写法。
>
> **2026-08-20 React BufferSurface 原生移植覆盖（覆盖下文 174pt/多 target row 描述）**：缓冲工作台默认采用 760pt React 母版宽度，继续是 nonactivating 原生 `NSPanel`，不改 `FocusToken`、secure/session protection、跨 Space 恢复或 `BufferDeliveryCoordinator -> Delivery.insert` 投递契约。普通、source-only 与 target-only single-exchange 都是 78pt；live source+target 固定 112pt，最大方向预判也降为 112pt。派生 workspace 可呈现 1–5 个互斥 alternative，但 `BufferInlineView` 只维护一个稳定 target viewport，以 pager 切换活动项，不再堆叠 2/3 条 target row 或因候选数改变窗口高度。实时翻译、My Prompt、意识流沿用 live-expand；内置 AI 生成与 Marine Chrome 采用 single-exchange，idle 显示 source/context，生成/结果显示 target，而源与未投递结果仍由 workspace 同时持有，直至宿主明确投递成功。返回编辑是用户明确放弃当前结果；现有 single-exchange refresh 在替换请求成功前会清空旧结果，因此结果态不暴露该非事务性入口。React 同样把 Remarkable 画成 exchange，但其原生实现是经过 SSH 当前页复验和本地 OCR 后直接写入普通 `BufferModel` 的 importer，没有第二份 derived source/result authority，因此 `BufferNativePresentationContract` 明确把它保留为 `standardBufferImport`。工具栏的 88pt 状态列仅在 active、保护、焦点阻塞和失败等可操作状态出现，普通 idle/ready 时完全脱离布局；22pt 返回编辑/刷新槽保持固定。主操作恢复为 22×22 纯图标按钮（投递用纸飞机、生成用 sparkles、生成中用 spinner），可见文字由 tooltip 与无障碍标签承载。`buffer-window-smoke` 钉住 AI/Marine/Remarkable 映射、single-exchange/live-expand、1–5 pager、单/双轨 78/112pt 几何、secure scrub 与固定工具栏槽。
>
> **2026-08-20 Clipboard rail 覆盖**：剪贴板历史是默认关闭的独立工作台开关，不等同于 Control/Command+V。只有开关开启、工作台真实位于当前 Space 且可见、secure input/锁屏/睡眠/会话保护均关闭时才读取系统 pasteboard；隐藏或保护期间不读正文，恢复只建立新的 `changeCount` baseline，不补抓期间内容。历史最多 30 项、单项 64 KiB、总计 512 KiB，只存在输入法进程，不写 UserDefaults、文件或正文日志。40pt rail 与 1pt divider 令单轨/双轨运行时高度从 78/112pt 变为 119/153pt，但持久 frame 仍保存 canonical 78pt。双击加入只调用 `BufferModel.insertPastedText`，不会开启 Buffer 捕获、写回系统剪贴板、保存历史或绕过 `BufferDeliveryCoordinator -> Delivery.insert`。
>
> **2026-08-13 工作台跨屏恢复覆盖（覆盖下一条“只在显式 hidden→visible 定位”）**：缓冲捕获开启时，新建立或重新确认的可信外部文本焦点会检查工作台是否仍在当前 macOS Space、以及合法 caret 是否落在另一物理显示器。只有发生这两类可见性断裂时，才把 nonactivating 工作台一次性带到当前 Space/目标显示器；同屏字段切换、输入与流式刷新仍不追踪 caret。自动恢复继续以精确 `FocusToken`、前台身份、secure input 与会话保护作前后门控，真正置前前再次复验；无合法 caret 时只在当前 Space 重排并保留已有 frame，禁止借鼠标屏 fallback 猜测显示器。未固定窗口使用 `.moveToActiveSpace + .fullScreenAuxiliary`，固定窗口使用 `.canJoinAllSpaces + .fullScreenAuxiliary`。关闭工作台仍会暂停捕获，因此 `BufferModel.enabled` 是恢复可见性的权威意图；自动位置保持 transient，不覆盖用户保存的 origin。
>
> **2026-08-06 工作台焦点定位覆盖**：用户显式从隐藏态唤出缓冲工作台时，先为当前精确外部 `FocusToken` 同步恢复 marked-text guard，再以 `liveTarget` 的 controller/client、前台 PID 和 secure-input 门控前后夹住一次 caret 查询。`attributes(forCharacterIndex:)` 的下标按 InputMethodKit 契约相对于 inline session，必须沿用稳定的相对下标 `0`；宿主的 `selectedRange`/`markedRange` 是文档级坐标，禁止直接混入，否则普通候选与工作台会一起漂移。合法零宽 caret 所在屏幕有空间时工作台优先位于输入框下方，否则翻到上方；174pt 最大布局只用于预判稳定方向，真实 78/112/143/174pt frame 均贴输入行 10pt。高度变化沿远离输入框的方向展开，候选窗贴真实外沿继续向外，不能用虚拟最大高度制造空隙。无精确目标、矩形非法或离屏时，才在鼠标所在屏幕居中靠下。定位只发生在显式 hidden→visible 转换，显示期间不会跟随焦点或流式刷新跳动；被动启动/锁屏恢复仍保留持久化 frame，自动开窗位置不覆盖用户保存的 origin。
>
> **2026-08-06 Marine Chrome 0.2.3 覆盖**：`builtin.marine-chrome` 是内置派生 workspace，配套 MV3 扩展使用固定 ID、RIMES 原生允许 + 扩展页确认的双确认流程自动领取内部凭据，日常不复制、不显示 token。没有网页上下文或用户备注时工作台隐藏空 source rail，以 78pt 单 target rail 显示“等待网页上下文”；真实 source 到达后恢复 112pt 双轨。工具栏右侧分别显示“Chrome 已配对/未配对”“上下文 在线/未挂载”“字幕来源”和“AI 就绪/未就绪”，其中“已配对”只表达本机信任关系，不能冒充扩展在线。抓取复用旧 Marine 的宿主标签绑定语义：popup 独立窗口造成的 `WINDOW_ID_NONE` 与父窗口 `focused=false` 不撤销同一 selected tab；worker 仍要求 main frame/document、tab/window/URL/epoch 与 `lastFocusedWindow` 的 active tab 全部一致，并在 PUT 前后重验。可恢复的前台 409、回环网络中断、正文未就绪和 503 必须保留不含正文的 suspended 读取意图；手动读取与无精确目标的 B 站直评可用只含 protocolVersion/URL 的前台探针恢复，精确回复仍要求真实 deep active editor 并重新解析评论 ID。Bilibili 的标题/URL 只是未就绪元数据，只有字幕、已捕获评论或明确视频简介可发布；空字幕按 2/5/10/30 秒退避重试，成功按 BV/分 P 缓存，隐藏页停发，导航 generation 拒绝迟到结果。popup 占焦期间到达的数据必须保留 dirty 标记并在页面恢复后用新 revision 重建；心跳必须单飞，不能在慢回环上排队。`dom` 权限只用于穿透 Bilibili 开放/闭合 Shadow DOM。状态轮询必须与 PUT/心跳串行，并且只把当前标签与 content identity 同时匹配的租约报为在线。切标签、跳转、关闭、Escape 或评论框失焦立即取消。AI capability/auth 探测完成后必须刷新被缓存的 unavailable phase；生成日志只记录 request ID、provider、来源枚举、结果分类与 block 数，不记录 URL、标题、网页正文、提示词、结果或凭据。
>
> **2026-08-20 当前缓冲 UI/按键覆盖**：顶部功能栏永久展开，固定显示无去向信息的状态文字、插件动作、刷新/重置和关闭；其空白、间距与弹性留白可拖动窗口，所有控件继续接收首击，正文轨不能拖窗。主条只保留缓冲块轨和右侧主按钮，不再显示拖拽手柄或展开/收起按钮。单轨工作台固定为 78pt，live source+target 双轨固定为 112pt；1–5 个 alternatives 共用一个 target viewport，以 pager 切换而不改变高度。手动/无目标布局保持底边，焦点锚定布局保持靠输入框的一侧并向外增高。刷新/重置保留缓冲正文，只取消过时插件任务、重新检测上下文或重启当前派生操作。工作台不再提供块编辑器或面板内缓冲开关，缓冲启停仍由设置/输入法菜单管理。精确外部缓冲租约下，`Command+Shift+↑/↓` 按选择器同一顺序循环切换 `Default + 已启用缓冲插件`，首尾相接；额外修饰键、自有窗口与 secure input 不接管。缓冲模式复用常规 `CandidateWindow` 呈现 Rime 组字候选，手动/无目标布局默认显示在工作台下方，焦点锚定布局沿远离输入框的一侧显示；意识流的互斥解释是工作台 alternative pager，不是第二份 Rime 候选。普通/Shift+Return 与 Backspace 在缓冲模式下永不落到宿主文本框：若有未决 Rime/并击组字，本次 Return 只收束为块；否则 keyDown 定点重建 IME guard，轻按发送下一块，按住约 1.2 秒发送全部，并显示底部进度。右侧纸飞机每次只发送下一块。成功发送的 block 立即从 live buffer 消失且不保留发送历史；失败和未发送 block 保留。本文若有更早的折叠、投影或留块描述，以本条和 `SYSTEM-ARCHITECTURE.md` 为准。
>
> **2026-07-20 输入配置/翻译覆盖**：设置层已把输入编码（自然码双拼/全拼/英文）与键入模式（串击/并击/互击）拆开，再映射到经过验证的固定 schema。飞耀互击复用 `my_combo`：并击结算同一计时批内的全部按键，多键的左侧、右侧或跨区组合均可映射但不跨批重组；互击在此基础上允许相邻的左侧声母与右侧韵母跨批配对。单独敲下的物理字母保留为英文原码，不自动插入分词符，也不与另一个单键批次重组。「实时翻译」作为内置缓冲插件只出现在缓冲插件列表，与 Marine 共用唯一 owner；默认用 Apple 本地翻译，也可改用当前 AI 渠道。源文在上方连续缓冲轨显示，译文在下方独立分块轨显示，顶部功能栏常显且空白可拖，发送与目标语言行对齐，只能经 `BufferDeliveryCoordinator -> Delivery.insert` 手动发送。
>
> **2026-07-27 Remarkable 覆盖**：`builtin.remarkable` 是用户显式调用、只读的普通缓冲 importer，不是派生 workspace 或通用 SSH provider，也不依赖官方 Convert to text。设备须开启 USB Web interface 并通过 USB 连接；点击“识别当前页”后，RIMES 用系统 `/usr/bin/ssh`、严格 known_hosts 与固定只读命令定位最近打开文档的当前页，双读 `.rm` 得到稳定页面快照，再以固定初始 URL `http://10.11.99.1/download/<文档 UUID>/pdf` 把整本 PDF 导入内存。PDF 导出后，插件立即重新读取文档、当前页与 `.rm`，只有身份、页序和字节快照前后一致才把冻结的 PDF 交给 PDFKit，以 300 dpi 为目标只渲染当前页（最长边 4096 px、总计 1200 万像素封顶），并用 Apple Vision 在 Mac 本地 OCR；识别结果随后以 `.ssh` provenance 调用 `stageExternalSemantic`。PDF 拉取显式禁用代理且初始 URL 不接受配置扩展；PDF、位图与识别正文不落盘、不进入正文日志。插件不调用官方或其他云端转写、不上传页面、不停止 Xochitl、不写设备、不自动投递。SSH 可配置 host、用户名与密码，也可沿用 key/agent；后台插件页和缓冲工作台共用同一个“首选识别语言”，默认简体中文优先（`zh-Hans` 后备 `en-US`），也可选繁体中文、英文或繁简混排自动识别；运行中切换会取消旧 OCR 并按新语言重启。密码只在 0700 私有子目录中的 0600 文件保存，共享数据根目录则要求当前用户所有且 group/world 不可写（兼容安全的 0755），经受限 `SSH_ASKPASS` 读取时不进入 argv、环境值或日志。未知主机必须先由用户从可信渠道核对指纹并加入 `known_hosts`；配置变化、owner/secure/锁屏/关闭/禁用均取消并墓碑化在途请求。
>
> **2026-07-27 My Prompt 覆盖**：`builtin.my-prompt` 是 `BufferModel` 查询源 + 独立目标结果的派生 workspace。索引格式以 Fabric `patterns/<name>/system.md` 为主，兼容可选 `user.md`、描述/标签 JSON、递归 Obsidian front matter 与“标题 + fenced code”合集 Markdown；根 README 的每个 fenced prompt 也是独立记录。来源统一导入私有 SQLite FTS；中文优先索引分词、CJK unigram/bigram 及标题/标签的音节边界拼音与首字母。无凭据 HTTPS Git 仓库在启动、远程配置变更或显式刷新时同步到私有 checkout，查询热路径完全本地。结果严格先裁为可见的 1–3 行；普通 Rime candidate 优先，组字收束后 ↑/↓ 或首击行只切换选择，数字不被候选路由吞掉。`prepareForDelivery` 冻结唯一选中正文，查询永不进入投递集合，结果继承全部查询 blocks 的 remote-mirror 权限；只有正文成功插入才消费捕获的查询 blocks。查询/配置 revision、owner、pause、secure input 或保护态任一变化都会墓碑迟到搜索。`my-prompt` 是开发重播种必须保留的产品数据根。
>
> **2026-08-20 插件配置覆盖**：所有有 schema 的插件都经统一“设置…”入口和 `PluginConfigurationModel` 表单；普通字段以每插件单字典保存，敏感字段进入 0700/0600 私有文件，通知只携带插件与字段 ID。完整规范见 [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md)。「AI 生成」可选择共享 AI 渠道；意识流保留独立渠道，另有 1–5（默认 5）候选上限和灵敏/平衡/稳定三档响应节奏，平衡档仍对应 220/800 ms；v1.1 的自由数值时序读取时迁移到最近档位，原 connector 不变。实时翻译默认 Apple 本地，也可选当前 AI 渠道；Marine 可配置并在调用开始时冻结 60–600 秒超时。

> **2026-08-13 预置插件分发覆盖**：`Catalog/buffer-plugins.json` 是六个预置 Buffer 插件名称、版本、默认安装/启用状态和下载 pin 的唯一手工来源；修改后运行 `python3 -B scripts/sync-buffer-plugin-catalog.py`，CI 会校验生成的 Swift catalog、可选 manifest 的精确字节/SHA-256 与中英文 README 表。第一方同进程 Swift 插件保留在 monorepo 与签名宿主一起发布；网络只从当前宿主版本对应的不可变 GitHub Release 资产下载声明式安装凭据，绝不加载远程可执行代码。全新 profile 默认安装并启用 AI 生成、My Prompt、实时翻译、意识流输入；Remarkable 与 Marine Chrome 不自动下载，receipt 的启用授权绑定 SHA-256 与安装实例，下载、重装或升级成功后也保持禁用；旧 profile 的选择只迁移一次并原样保留。
>
> **2026-07-23 AI 插件/连接器覆盖**：「AI 生成」是唯一内置 `.bufferAction`；Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 是“连接器 › AI 模型”中独立单选的三个模型源，也可从插件配置选择。内置 AI，以及整个 resolved action surface 只有一个 prepared presentation 的外部 owner，不再在展开层提供独立生成按钮；主条右侧同一控件按 disabled AI 图标 → 可请求 AI 图标 → 转圈 → 纸飞机变化，Return 与它共用这个状态机。内置生成把 source 冻结在上轨、以稳定 block 更新下轨，只有目标块全部成功投递后才消费对应源块；两轨角色用图标而非“原/答”文字。Marine 继续由 Action Plugin `preparePath` 冻结上下文，直评/回复由 `status.actionId` 动态解析后通过同一主控件触发，并只投递匹配该 prepared action group 的最终块；插件 owner 与连接器选择互不改写。

> **2026-07-22 全量捕获/宿主分块覆盖**：缓冲持久开启且精确外部焦点可信时，健康 librime 在 ASCII 模式返回 unhandled 的字母、数字、空格和普通标点由控制器收回并写入 `BufferModel`，不再交给宿主原生插入；逐键尾块以焦点 token 为 owner 合并成短英文词组并支持逐字退格，快捷键、自有输入框与 secure input 仍放行/隔离。AI、实时翻译、意识流所选答案、Action/Marine 流式及最终结果统一经过确定性宿主分段：上游 block 是硬边界，中文按句/分句与长度、英文按完整单词或短词组细分；Action 流的子块以 `(providerIndex, childIndex)` 保持稳定身份，任何子块仍完整继承原插件 authority/provenance。轻按 Return/纸飞机继续只发下一宿主块，长按才发送全部。

> **2026-07-26 意识流并击/互击覆盖（覆盖下一条中的“始终连续全拼”与 Space 描述）**：意识流仍不修改或持久化输入配置，但会读取完整 `InputConfiguration` 做运行时路由。显式 `.chord` 与 `.mutual` 都在 Rime 前按 `ChordSettings.duration` 聚合物理批次，并通过当前有效部署的 `my_combo` schema 映射为全拼；并击只结算当前批，互击还可把紧邻的左侧声母批与右侧韵母批按精确 raw/soft-offset 快照回滚重组（至少一侧为多键）。左右两侧共同构成且映射成功的完整音节在全拼后自动写入一个真实 ASCII Space。`dv→n`、`km→ong` 等尚未配对的单侧映射是可继续补全的拼音片段，故先映射但不补 Space；单键字母仍按原字母写入且不补 Space，两个单键批不互相重组，单独 `,`/`.` 只消费，无映射多键批保留确定性的字母原码且不补 Space。自动 Space 以 sidecar 标记为“软音节边界”：上轨显示普通空格，参与全拼提示但不显示 `·`、不增加短句最小分块数、也不立即请求；物理 Space 仍是“硬短句边界”，若紧跟自动 Space 则原位把它提升为硬边界而不重复插入。第一枚待结算键立即撤销旧投递权，非和弦边界、失焦、secure input、插件或配置切换均清除待配对状态并作废定时器。

> **2026-08-20 意识流输入基线（并击与 Space 语义以 2026-07-26 覆盖为准）**：内置 `builtin.stream-input` 只在缓冲持久开启、插件为唯一 owner、secure input 关闭且外部 `FocusToken` 精确存活时于 Rime 前捕获。raw 拼音与目标块只存在 `StreamInputWorkspace`，不写入 Rime/CompositionSession/BufferModel。配置页提供灵敏 140/500、平衡 220/800 与稳定 350/1200 ms 三档 debounce/max-wait，默认平衡；普通 raw 变更只重置所选 debounce，本次 burst 的 max-wait 不重置。最多允许旧视觉 producer 与新 challenger 两路短暂重叠，跨 revision 旧结果、partial 与 baseline 都不可进入新 prompt 或获得投递权，墓碑后的迟到回调作废。workspace 默认用 OpenAI 兼容连接器，但可单独选择三个 AI 渠道；OpenAI 专用请求仍关闭 thinking、要求 JSON object、限制 1024 output tokens。每次实际请求冻结完整设置快照；配置的 1–5（默认 5）候选上限贯穿 prompt、provider schema/decoder、一次有界排重重试、partial 与 final 校验。每轮用完整 raw 和最多三条本地 lossless 提示全局重算；旧合法结果优先合并、精确去重且不超过本轮冻结上限，partial 永不可投递。所有 alternatives 共享一个稳定 target viewport，以 pager、↑/↓ 或数字 1–5 切换；Return/纸飞机在首个实际投递前确认所选项并淘汰其余项。raw 贯穿部分投递保留，只在最后一块成功后清除；首块后继续输入则主动丢弃未发尾部，已发送前缀不得复活。

> **2026-07-22 工作台全选/粘贴覆盖**：精确 `Control+A`/`Command+A` 与 `Control+V`/`Command+V` 在缓冲开启、外部 `FocusToken` 存活且 secure input 关闭时由工作台接管；额外 Shift/Option、Control+Command 组合及自有窗口均不改写。普通缓冲及翻译、AI、Action/Marine 插件的源文统一是 `BufferModel`：全选所有 source blocks，粘贴在块光标插入或替换全选，保留连接后的精确文本并再做宿主语义分块。意识流只编辑 raw 上轨：粘贴只允许 ASCII 字母与空白，字母转小写、空白归一为真实 Space，任一其他字符或总 raw 超过 16 KiB 就原子拒绝整次粘贴。普通剪贴板文本还必须非空、无 NUL 且不超过 1 MiB。控制器先安全收束 Rime/并击组字，再在读取剪贴板前与延迟 provider 返回后各重验一次同一焦点租约。secure input 下快捷键保留宿主原生处理，RIMES 绝不读取 pasteboard；外部焦点不可信时则只消费按键、不读取、不修改 source。

---

## 0. 一页速览

| 项 | 内容 |
|---|---|
| 定位 | 从零做的现代 macOS 输入法：**librime 引擎 + 自绘 UI + 常驻缓冲区(buffer)**，终点是替代 Squirrel 成为用户日常主力 |
| 仓库 | `~/Documents/05-dev/apps/rime-buffer`（SwiftPM：C++ 桥 target + Swift executable） |
| 进程模型 | **内部单进程**。IMK、librime、候选窗、buffer、网关、菜单都在同一进程；禁止把内部 UI/状态拆成依赖轮询或 IPC 的伴随进程。MCP/HTTP 与配对传字是明确的外部接口，不在此禁令内 |
| 引擎 | 优先 dlopen app 自带的 `librime.1.dylib` + lua/octagram/predict 插件；开发态才回退 Squirrel 路径；用户数据独立在 `~/Library/RimeBuffer` |
| 上屏 | 只经 `client.insertText`（IMK 一等公民通道，网页/Electron/原生通吃） |
| 已验证 | 引擎 smoke 覆盖四方案列表、F4、雾凇拼音上屏，以及英文补全/空格/生词兜底；.app 可安装可注册可输入 |
| 当前状态 | §4 的 3 个现场 bug 对应修复已落地；§9 P1' 保留为历史验收记录，当前仍需安装后真机回归 |
| 兜底 | Squirrel 保持安装不动，用户随时切回；引擎宕机时输入法自动退化为原生 latin 直通 |

---

## 1. 产品定位与目标

### 1.1 为什么做（动因链）

1. 用户原型 BufferBar（`~/Documents/05-dev/apps/buffer-bar`）用辅助功能(AX)/模拟粘贴向任意输入框注入文字 → **网页/Electron 输入框千奇百怪，AX 写入假成功、粘贴抢焦点失败**，逐 App 调试不可持续。
2. 用户使用 Rime **并击（chord，my_combo 方案）**，在"有钩子的输入框"（Electron/终端等）里组字会被打断——根因指向 Squirrel `inline_preedit: true` 依赖目标框的 marked-text 会话，而这些框处理 marked text 不可靠。
3. 结论：**要可靠地把字送进任意焦点框，必须自己就是输入法**（`insertText` 是唯一一等公民通道）；要保住 Rime 体验，就内嵌 librime + 用户既有配置。
4. 顺势升级：参照微信/豆包输入法的形态 = 引擎 + 富 UI + 服务。用户手里已有深度定制的顶级引擎（librime + 30+ Lua），缺的只是现代前端。**buffer（缓冲区）是本产品的差异化杀手锏**：输入法内部的一等暂存平台，未来挂 AI 改写/翻译、语音、模板、多目标投递。

### 1.2 目标（按优先级）

1. **P1 日常可打**：并击、自然码双拼、雾凇拼音、英文四方案在 Safari、Electron、终端全部正常；候选窗自绘；insertText 上屏；引擎宕机不砸打字。
2. **P2 buffer 平台**：提交文字可先落缓冲面板，分块暂存后再冲刷到目标框。
3. **P3 语音 + AI**：在 buffer 上做听写和 AI 变换。
4. **P4 转正**：学习词同步/迁移、per-app 精调、签名公证、设为默认。进程内 maintenance/deploy 与自包含 runtime 已提前完成。

### 1.3 非目标

- 不覆盖 Rime 全生态——只需服务**这个用户的**方案与习惯（§2）。
- 不做旧 ai_box 方案（Rime Lua/Python 内候选行缓冲，用户已放弃；`my_combo` 已移除相关 mode、processor、translator、filter、快捷键与 Python 配置，本项目的 AI 只走原生工作台和连接器）。
- 不修改用户的 `~/Library/Rime`（只读复制）。

---

## 2. 用户环境画像（实现时的"合同"）

来源：`~/Library/Rime`（git 管理）。**以下每一条都是实测/实读得出，直接决定实现细节。**

| 项 | 值 | 对实现的约束 |
|---|---|---|
| 用户可见方案 | `my_combo`（并击）/ `double_pinyin`（自然码）/ `rime_ice`（雾凇拼音）/ `english`（英文） | 只有这四项进入 schema_list 与 F4；melt_eng/radical_pinyin 只作隐藏依赖 |
| 默认方案 | my_combo | 系统输入法菜单需能进入设置并切换 |
| `page_size` | **9**（default.custom.yaml patch；default.yaml 原值 5） | 候选窗渲染 `menu.page_size` 行，**不许硬编码** |
| 并击间隔 | 当前 UserDefaults `chord.duration`，默认 **0.10s**，范围 0.02–0.50s | `ChordSettings` 是唯一运行时来源；设置修改会通知所有活跃 controller，旧 `squirrel.yaml chord_duration` 不再驱动运行时 |
| 方案切换热键 | **F4 / Control+grave / Control+Shift+grave**（default.yaml switcher） | 键位表必须映射 F 键与 grave；切换器以**候选形式**渲染（就是一页候选），候选窗必须能正确显示它 |
| 标点切换 | Control+Shift+3 / Control+Shift+numbersign 绑定 ascii_punct | **修饰键组合必须先喂 Rime**，不许一刀切丢弃 |
| ascii 开关 | Shift_L=commit_code、good_old_caps_lock: true | controller 延迟 Shift 切换事件；仅独立且小于 500 ms 的轻点在抬起时向 Rime 补发同侧 press/release，组合键、长按或失焦手势不进入 `ascii_composer` |
| 外观 | stacked 竖排、font_point 20、label_font_point 14、purity_of_form_custom 配色、inline_preedit: true | 候选窗视觉对齐目标；组字默认**内联**（marked text 显示 preedit） |
| Lua | 30+ 脚本（含 mode_switch、autocap、长词过滤等） | 引擎必须带 lua 模块；Lua 卡死是已知"打不出字"向量（→watchdog） |
| Squirrel | 可继续安装作用户手动兜底和开发构建的 runtime fallback | 正式 app 已自带 librime 与 Rime 数据，不再把 Squirrel 视为运行依赖 |

---

## 3. 三条铁律（违反即架构事故）

1. **内部单进程，零轮询式组件 IPC。** 候选窗、buffer、菜单、网关全部在 IME 进程内。前身项目把候选 UI 拆到另一进程、经 `~/Library/Rime/tmp/.../state.json` 轮询同步，造成"UI 进程没起来→打不出字"的脆弱链——**此模式永久禁止**。对本地智能体与配对设备开放的 MCP/HTTP/加密网络接口不改变这条内部拓扑约束。
2. **C 桥是 ground truth，逐字复用。** `Sources/CRimeBridge/CRimeBridge.cpp` 的 RimeApi vtable 是对着用户机器上 librime 1.16.0 实测通过的，**字段顺序 load-bearing**（声明顺序=内存布局，动一行就静默错位）。改桥只允许"追加包装函数"，不允许重排/删减 vtable。
3. **上屏唯一出口 + 永活兜底。** 所有文字（普通提交/chord 提交/裸兜底）只经 `Delivery.insert`（`client.insertText`）。缓冲关闭时，任何按键路径在"引擎不健康或 session==0"时必须落到裸 insertText（可打印字符直通、Return→`\n`），**不存在"返回 false 且丢掉一个可打印字符"的路径**。缓冲开启时有一条刻意的隔离例外：普通/Shift+Return 与 Backspace 必须吞键，绝不进入宿主文本框，即使引擎故障或焦点租约不可信也一样。

---

## 4. ⚠️ 实测修正（v2 核心，接手者必读）

2026-07-04 真机实测（用户在微信等 App 实打）发现 3 个问题；结合 Squirrel 源码
（`sources/SquirrelInputController.swift`）取证，v1 的一个核心假设被推翻。

### 4.1 三个现场 bug 与根因

| # | 现象 | 根因 |
|---|---|---|
| 1 | 候选窗死在屏幕下方，"几乎不计算位置" | 无 marked-text 会话时，`attributes(forCharacterIndex:lineHeightRectangle:)` 在多数 App 返回零矩形 → 永远走兜底锚点 |
| 2 | 微信里 "zuoye作业"——**原始字母残留** + 提交文字一起上屏 | 我们从不 `setMarkedText`，客户端不知道"正在组字"，自行回显了原始按键。Squirrel 源码注释明确此坑："用全角空格占位，防止 iTerm2 回显原始编码" |
| 3 | 切不到并击方案 | 键位表没映射 F4（keyCode 118）和 grave（keyCode 50）→ 切换热键根本没进 Rime；即使进了，方案选单以候选渲染，又被 bug#1 藏在屏幕角落 |

### 4.2 结论：组字协议 v2

**marked-text 会话必须常驻（composing 期间始终存在），内容可以极简。** 这是 Squirrel 的实证做法：

- `inline` 模式（默认，匹配用户 `inline_preedit: true`）：`setMarkedText(带下划线的 preedit, selectionRange: caret 位置)`——客户端内联显示组字串。
- `placeholder` 模式（per-app 备选，对付 marked text 处理糟糕的 App）：组字期间 `setMarkedText("　")`（**全角空格**，Squirrel 同款；半角会导致中文基线跳动）——会话存在（不回显、不丢事件、光标矩形可用），但目标框只见一个占位符，preedit 全在我们候选窗里。
- 提交：`client.insertText(text, replacementRange: NSRange(NSNotFound,0))`——有活动 marked 会话时按协议**原子替换** marked 区。
- 取消/失焦：`setMarkedText("")` 清会话（或先提交再清，见 §5.8 策略）。

这同时治好 #1（有会话后光标矩形 API 恢复工作）与 #2（客户端不再回显）。
**原"永不 setMarkedText 以保并击"的担忧**由 per-app `placeholder` 模式 + chord 组字期极短（~50ms 即提交）来覆盖；若某 App 仍坏，加入 per-app 表（§5.4）单独处置，而不是全局裸奔。

---

## 5. 分层架构与模块规格

```
┌─ ETInput.app (IMK 输入法进程, LSUIElement=true, LSBackgroundOnly=false, .accessory) ┐
│                                                                              │
│  main.swift ── IMKServer 引导 · 引擎预热 · 系统输入法菜单状态                  │
│                                                                              │
│  RimeBufferController (IMKInputController, 每个客户端一个实例)                │
│    │  键路由: keysym 映射 → processRimeKey → commit drain → UI 更新           │
│    ├─ CompositionSession   ★v2 组字协议(marked text 常驻, inline/placeholder) │
│    ├─ ChordController      并击重放(仅 my_combo; duration=ChordSettings)     │
│    ├─ CandidateWindow      唯一候选 panel：锚定 caret / 工作台真实外沿       │
│    ├─ InputFocusCoordinator FocusToken + 当前 IMK client 租约                │
│    ├─ StatusMenu           IMK menu() 构建器(设置/健康/更新/重载)             │
│    ├─ FocusObserver        失焦强制 flush chord + 提交/清组字                 │
│    └─ Delivery             唯一上屏出口 insertText                            │
│                                                                              │
│  RimeEngine (可实例化封装, 每控制器独立 session) ── CRimeBridge (C++, dlopen) │
│    └─ app 自带 librime.1.dylib + lua/octagram/predict；开发态回退 Squirrel   │
│    └─ 用户目录: ~/Library/RimeBuffer (自 ~/Library/Rime 播种的独立副本)        │
│                                                                              │
│  BufferWindowController + BufferModel + BufferDeliveryCoordinator             │
│  AITextPlugins(已实现)  [P3] 语音  [P4] 学习词同步/签名公证             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 5.1 CRimeBridge（C++，`Sources/CRimeBridge/`）— 状态：✅ 已改造并验证

- 职责：优先从 app Frameworks dlopen 4 个 dylib（RTLD_NOW|RTLD_GLOBAL；开发态回退 Squirrel）→ `rime_get_api` → `setup()+initialize()` → `start_maintenance`/`deploy_config_file` 在独立用户目录生成 build → smoke session 健康门控。
- 已提供：`BBRimeStart/IsHealthy/CreateSession/DestroySession/ProcessKey/CommitComposition/ClearComposition/SelectCandidateOnCurrentPage/GetOption/SetOption/SelectSchema/Deploy/GetContext/GetStatus/CopyCommit/CopySchema/CopyLastError/FreeString`。
- `BBRimeGetContext` 语义：填**当前页**（librime 的 menu.candidates 本来就是按页数组）——preedit/光标、page_size/page_no/is_last_page、高亮下标、候选 text/comment/label（label 优先 select_labels，退 select_keys，再退序号）。字符串指针由桥的静态后备存储持有，**仅在下一次调用前有效**，Swift 侧立即拷贝。
- 所有权契约：C 侧 malloc → Swift `String(cString:)` → `BBRimeFreeString`。全部入口锁 `gMutex`。
- `BBRimeConfigGetDouble(configId, key, out)` 已实现，仍可读取部署配置；并击时长已经迁到 `ChordSettings`，不再调用它作为运行时来源。

### 5.2 RimeEngine（Swift）— 状态：✅ 已写

可实例化（**无单例、无共享 session**——前身的共享 session 会让组字状态跨输入框串扰）。`start()` 失败时保持可重试。用户目录默认 `~/Library/RimeBuffer`，环境变量 `RIMEBUFFER_USER_DIR` 可覆盖（CLI smoke 用）。

### 5.3 RimeBufferController — 状态：✅ 已实现并持续演进

- **每控制器一个 session**：`activateServer` 建（懒）、`deactivateServer` flush+提交、`deinit` 先停 chord 定时器再销毁 session。
- **焦点进入时镜像全局开关**：读/写 ascii_mode、simplification、ascii_punct（等 UserDefaults 记忆值），让"简繁/中英"体感全局（Squirrel 是单 session 天然全局，我们要显式镜像）。
- **键路由规则**（顺序敏感）：
  1. `recognizedEvents` = keyDown | keyUp | flagsChanged。`keyUp` 继续用于完整的修饰键/并击生命周期；缓冲区 Return 在 keyDown 绑定焦点租约并重建 IME guard，keyUp 或物理轮询检测到抬起时判定轻按发送一块，持续物理按住达到 1.2 秒时发送全部。
  2. keysym 映射表 = 原型 `RimeKey` 全表 **+ 增补**：F1–F12（X11 keysym `0xffbe + n`，F4 = `0xffc1`；Mac keyCode F4=118 等），grave（keyCode 50 → `0x60`），数字行/符号经 `event.characters` 直通已可用。
  3. **修饰键组合先喂 Rime**（带完整 mask 调 processKey）；Rime 未处理且 mask 含 command/control 时才 return false 放行给 App（Cmd-C 等正常）。**禁止**一刀切 `guard modifiers.isEmpty`。
  4. caps 的 `mask ^ lockMask` 逻辑保持原样。Shift 的 mode-switch press/release 延迟到物理抬起后判定：只有同一 session/schema、未参与任何按键且小于 500 ms 的轻点，才把保存的左/右 Shift keysym 成对补发给 Rime；组合键、长按、双 Shift 或失焦手势整对丢弃。这样 `commit_code` 不会先提交组字、再由前端事后回滚模式。
  5. 非 chord 键按下先 `flushChordRelease()` 再处理。
  6. 每次 processKey 后：drain commit → CompositionSession 更新 marked text → CandidateWindow 更新。
  7. 兜底不变式见 §3-3。
  8. **缓冲按键隔离**：普通/Shift+Return 与 Backspace 在最外层被无条件消费。有未决 Rime/并击组字或尚未 ready 的意识流 raw 时，本次 Return 只收束/强制生成并吞掉同一物理按键的 repeat/keyUp；意识流 final 已 ready 时，keyDown 先原子确认高亮候选并删除其他候选，同一次按键继续进入轻按/长按投递手势。其他无未决组字的内容也在 keyDown 定点重建不可见 marked-text guard，轻按请求 `sendNext`、按住 1.2 秒请求 `sendAll`。被接管的 keyDown 独立持有 sticky keyUp / `didCommand(insertNewline:)` suppression；发送最后一个 transient block、失焦或动作 reset 都不能撤销它们，迟到或重复回调也不消耗当前代的保护，直到下一次确认的新物理按压才退休。`handle(_:client:)` 是 Return 唯一动作入口，`didCommand` 只做防御性消费，不得形成第二条发送路径。Backspace 仅在精确焦点下编辑 Rime/并击状态或删除缓冲块。焦点不可信时始终吞键且不投递；引擎不可用时，无法安全收束的未决组字只吞不发，但没有未决组字的已有块仍可发送。任何分支都不得把换行/删除交给宿主。
  9. **工作台全选/粘贴**：精确 Control/Command+A/V 在 Rime 处理之前分流，但只有单一 Control 或 Command 修饰才是工作台命令。普通与插件模式会先安全收束未决 Rime/并击组字，使全选覆盖完整 `BufferModel` source；意识流只选中 raw source，不选中派生候选。选择本身只改变展示态，不使已 ready 的派生 generation 失效；粘贴才是一次 source 变更。读取 pasteboard 前后必须各重验 secure input 与同一精确租约；secure input 下直接放行宿主命令且绝不读取，失效外部焦点则只吞键。NSEvent 和 `didCommand(selectAll:/paste:)` 只能共同表示一次动作，repeat/keyUp/迟到 command 不得重复编辑。
- `commitComposition(_:)`（IMK 回调）：flush chord → `commit_composition` → drain → 清 marked。
- **焦点所有权**：每次 `activateServer` 建立新的单调 `FocusToken`；键事件只复用当前精确租约。controller/client 对象身份、`controller.client()` 当前身份、bundle、前台 app PID 与事件顺序共同拒绝迟到回调；生命周期回调不得用 `lastClient` 兜底。已验证的非激活例外只有精确 bundle/path allowlist 中的 Spotlight 与 Paste：前者必须来自系统路径，后者必须来自 `/Applications/Paste.app`。两者都要求唯一 live PID、自有可见窗口、新鲜有序的 keyDown，并同时绑定下层前台 app 的 bundle/PID 锚点；activation 只建立不可投递的预热租约。keyUp/flagsChanged 不能解锁或复活租约；窗口隐藏、进程/锚点变化或任一新的 workspace activation 都 fail-closed，未知 accessory app 仍拒绝。explicit、nil 或 non-client sender 都必须与当前隐式 client 一致；同一 proxy（包括跨 controller）被新 epoch 复用后，生命周期回调保持锁闭，直到一枚通过全部身份、前台与顺序门控的 keyDown 证明新字段所有权。旧 session 只在 Rime 内回收到缓冲或丢弃。异步和弦回放、弱 client 过期、锁屏/睡眠也走同一 no-client 清理，不靠超时猜测归属。

### 5.4 CompositionSession ★v2 核心— 状态：✅ 已实现

- 状态机：语义上仍是 `idle ⇄ composing`，但精确外部缓冲租约存在时，宿主侧会在 idle 阶段常驻一个不可见 U+200B marked guard，防止 Chromium 类输入框越过 IMK 消费 raw Return。这个 guard 不等于组字：idle 时 `composition.composing` 与 lease `compositionActive` 都为 false，marked range 也不参与字段切换判断；失焦、关闭缓冲、安全输入或进入自有窗口时清除。composing 期间**每次上下文变化都刷新 marked text**；普通模式离开 composing 时结束会话。
- 内容策略（per-app 查表，默认 `inline`）：
  - `inline`：`NSAttributedString(preedit, 下划线)`，`selectionRange` 置于 `cursorPos`；
  - `placeholder`：全角空格 `"　"`。
- per-app 表：`bundleId → .inline | .placeholder`，UserDefaults 持久化；初始为空表（全 inline）。当前没有 StatusMenu/设置页编辑入口，需直接写偏好或后续补 UI。
- 提交路径：`Delivery.insert`（insertText 自动替换 marked 区）→ 若 Rime 仍在组字（长句剩余部分）→ 立刻 setMarkedText(新 preedit)；否则清会话。
- **切勿**在同一客户端同时"设 marked text"又"把 preedit 画在自己面板里重复显示"——inline 模式候选窗只画候选，placeholder 模式候选窗才画 preedit 行。

### 5.5 CandidateWindow — 状态：✅ 单一候选面板与双锚点已实现

- NSPanel（borderless + nonactivating；普通宿主使用 `.popUpMenu`，只有精确验证的 iShot 非激活标注租约临时使用 `CGShieldingWindowLevel()`，隐藏或换宿主时立即恢复普通层级；canJoinAllSpaces + fullScreenAuxiliary + stationary，orderFrontRegardless）。这个条件升层用于兼容截图遮罩，仍需目标版本 iShot 真机验证；最终排序前再次检查 secure input，焦点租约、非空组字和锁屏门控仍然 fail closed。宿主进程必须 `NSApp.setActivationPolicy(.accessory)`（纯 LSBackgroundOnly 应用不能可靠置窗，已在 main.swift 落实）。
- 渲染：`page_size` 行（用户=9）· label 用 librime select_labels · 高亮行 `highlightedIndex` 以墨竹/翡翠主题高亮色作实底，并在黑/白文字中自动选择 WCAG 对比度更高者 · comment 淡色 · 翻页指示（page_no/is_last_page）· stacked 竖排 · 字号对齐用户（候选 20pt/标签 14pt）· 配色向 purity_of_form_custom 靠（P4 精调）。
- **定位链**（每次更新执行）：
  1. `client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)`——该下标相对于 inline session；没有 inline session 时 `0` 按 IMK 契约定位 current selection。它不能替换成文档级 `selectedRange`/`markedRange`。有 marked 会话后这是可靠主路径（Squirrel 同款）；窗放 rect 下沿、必要时翻到上方防出屏。
  2. rect 为零/明显非法 → 该 client（bundleId）**最近一次合法 rect** 缓存。
  3. 仍无 → 前台窗口底部居中（P4 再精化）。**禁止**默认屏幕角落。
- 交互：鼠标点候选 → `select_candidate_on_current_page` → 正常 commit drain（**不许**直接 insertText 绕过控制器）。数字/减号/等号/空格/回车**一律进 Rime**，让用户 has_menu 翻页与选重绑定生效。
- 方案选单（switcher）就是一页候选——本窗即渲染载体，无需特殊逻辑。
- 缓冲模式把同一个带 `FocusToken` 的 Rime 候选 panel 锚定在工作台外沿；单轨工作台固定 78pt，source+target 双轨固定 112pt，意识流的 1–5 个 alternatives 只在单一 target viewport 内分页，不再随数量增高。手动或无目标布局保持底边并默认把候选放在下方；焦点锚定布局保持靠输入框的一边，匹配原 `FocusToken` 的候选也严格贴真实外沿，外侧空间不足则暂时隐藏而不穿过输入行。用户可在设置中切回 caret。两种位置共享完全相同的 Rime 候选视觉、矩阵翻页、单字选择与提交状态，过期点击无效；工作台不再维护 Rime 候选投影，意识流 pager 是独立派生结果。
- `isVisible` 同时要求逻辑 owner/context、仍可投递的 `interactionTarget`、非空内容、`panel.isVisible` 与 `panel.isOnActiveSpace`；所有 show/hide 经过统一状态机。焦点权限失效会物理隐藏并清空逻辑 presentation，避免 panel 已 `orderOut` 但控制器仍误判“可见”而不再重建。候选专属的鼠标、方向键、Return/Space、分页和 Option 单字选择还必须满足同一真实可见/active-Space 门控；临时隐藏时可保留组字语义，但不得在不可见 UI 上隐式选择或劫持宿主按键。

### 5.6 ChordController（并击）— 状态：✅ 已实现

- 机制（Squirrel 同款，原型验证过）：chording 键（a–z , .）按下且 Rime 已 handled → 入重放缓冲 + 重置定时器；到期把缓冲键全部以 `mask | releaseMask(1<<30)` 重放 → chord_composer 判定成 chord → drain commit。
- **门控**：仅 `schemaId == "my_combo"`。串击/双拼绝不注入合成 release（会扰乱 speller 时序）。
- **并击/互击区别**：两者都结算当前计时批，多键单侧批次不丢弃；单个物理字母保持英文原码且不添加 `'`。只有互击会在至少一侧为多键和弦时，把相邻的左侧声母批与右侧韵母批回滚重组为同一音节。无映射批保留可由 Return 提交的原码；`,`/`.` 保留为和弦双角色键，单键结算后落到 Rime punctuator。
- **候选能力**：`my_combo` 只维护物理和弦到规范拼音的映射，speller、主/英文翻译器和候选过滤链直接继承 `rime_ice`；多音节输入必须同时保留整词、前缀单字和后续候选页。
- **字面 `v`**：`v` 继续参与多键飞耀映射，但单键批次必须保留普通英文原码；`my_combo` 显式覆盖 `rime_ice` 的 lowercase-`v` 符号 recognizer 并移除 `v_filter`，因此以 `v` 开头的英文不再进入符号模式。
- **duration 的唯一来源**：`ChordSettings.duration`（UserDefaults `chord.duration`），默认 0.10s、范围 0.02–0.50s；设置变化通过通知实时更新所有 controller。
- flush 时机：非 chord 键按下前 / `deactivateServer` / `commitComposition` 前 / FocusObserver 触发。flush 期间**强持有** client 引用。

### 5.7 StatusMenu — 状态：✅ 系统输入法菜单单入口

只使用 macOS 已有的输入法专属位置，不再创建独立 `NSStatusItem`。`RimeBufferController.menu()`
每次打开系统输入法菜单时返回最新 `NSMenu`；设置、更新检查、日志、重新部署、重新安装与重启
均放在这里，引擎异常则在菜单顶部显示禁用的警告行。

InputMethodKit 会把菜单命令经 `doCommandBySelector:commandDictionary:` 发回当前
`IMKInputController`，因此每个条目的 target/action 必须落在当前 `RimeBufferController`，再转发给
`StatusMenu` 的共享操作。不要把 action 只挂到菜单单例上——旧实现曾因此出现菜单可见但动作在部分
macOS 版本不可靠。`Info.plist` 的 `etinput-menu.pdf` 继续负责系统输入法位置的图标。

方案切换只经 F4。Rime 内切换成功后把 schema id 记为 `preferredSchema`，各控制器激活时恢复该选择；设置页复选框只管理 F4 的 `schema_list`。

### 5.8 InputFocusCoordinator — 状态：✅ 已实现

为当前 controller/client 建立单调 `FocusToken` 租约，并同时校验租约 client 与 `controller.client()` 的对象身份、bundle id、前台应用 PID 与事件顺序。普通 App 必须与 `NSWorkspace.frontmostApplication` 精确一致；只有精确 bundle/path allowlist 中的 Spotlight、Paste 与 AppKit `openAndSavePanelService` 可进入瞬态界面策略。Spotlight/Paste 冻结唯一进程 PID、其自有可见窗口及下层前台 bundle/PID。打开/保存面板允许系统保留多个 genuine ViewService，但要求所有同 bundle 活进程都来自固定 AppKit XPC 路径，不猜测 service PID，而是冻结发起 App bundle/PID 与首个新鲜 keyDown 时最前的 layer-0 面板窗口 ID。后续交互和异步上屏持续重验同一权限组合，窗口消失后底层文档窗不能替代它。两类界面的 lifecycle activation 都只建立 suspended 预热租约，keyUp/flagsChanged 不得建立或恢复，任一 workspace activation 一律撤销。迟到的 deactivate、command、hide、候选点击或和弦 timer 只操作自己的 token；缓冲投递不存在 recent/last client 回退。NSWorkspace、锁屏/会话与输入源通知负责缺失生命周期回调时的最终撤销。同 proxy 切字段（跨 controller 也算）或旧 marked range 消失时建立新 epoch；临时只有前台 PID 而没有 bundle 时可处理当前首键，但不得把推测 PID 写进 proxy 缓存，后续经过 bundle/path 验证的身份必须刷新 epoch。复用 proxy 由可信 keyDown 确认后仍保留短期 lifecycle grace，覆盖已观测到的迟到旧字段 deactivate。旧 session 只在缓冲开启时回收到工作台，否则丢弃，绝不经已经指向新字段的 proxy 提交。弱 client 自然释放时也先清理仍存活 controller 的 chord/session，再移除租约。

### 5.9 Delivery — 状态：✅ 已实现

`Delivery.insert` 仍是唯一上屏咽喉。Return 轻按请求 `sendNext`、长按请求 `sendAll`；主条右侧纸飞机每次只请求 `sendNext`。键盘路径固定使用 keyDown 时捕获的 `FocusToken`；协调器在每个块投递前重新校验 token、组字状态和 secure input。焦点变化立即停止，既不会改送新目标，也不会回送旧目标；未发送块保留。输入法自身窗口不是投递目标，也不参与远端镜像。

### 5.10 BufferWindowController + BufferModel（P2）— 状态：✅ 已实现

- 工作台是独立、nonactivating、可调整宽度的 `NSPanel`。顶部功能栏永久展开；它的空白、间距和弹性留白调用 `performDrag`，按钮、弹窗和其他 `NSControl` 保持首击，整个窗口背景与正文轨均不可拖。主条只保留缓冲轨和右侧主控件，不再显示专用拖拽手柄或 disclosure。普通、source-only 与 target-only single-exchange 固定为 78pt；实时翻译、Marine Chrome、My Prompt 与意识流的 live source+target 固定为 112pt。派生 workspace 可提供 1–5 个 alternatives，但只维护一个稳定 target viewport，以 pager 切换而不改变窗口高度；活动项内部的横向 document row 关闭 autoresizing-mask constraints 并将高度绑定到 scroll viewport。内置 AI，或整个 resolved action surface 只有一个 prepared presentation 的外部 owner 被选中时，右侧主控件在禁用 AI 图标/可请求 AI 图标/转圈/纸飞机间原位切换，顶部功能栏不再放第二个生成按钮；只要还有第二项 presentation，就全部保留为显式插件动作。顶部功能栏固定为状态、带小图标的缓冲插件选择器及其他插件的当前动作、选中 workspace 提供的隐私安全右侧状态、刷新/重置与关闭。设置页可多选启用缓冲插件，选择器只显示该集合并用 `Default` 表示无插件；选择器直接改写唯一 owner，刷新/重置保留缓冲正文并只重置当前插件运行状态。显式从隐藏态唤出时，工作台只读取当前精确外部 IMK 租约的一次新鲜 caret 行矩形：最大 112pt 布局只用于选择稳定的一侧，真实当前高度仍与输入行保持 10pt；通常位于下方，空间不足则连同候选展开方向一起翻到上方。焦点锚定布局切 owner 或单/双轨高度时保持靠输入框的一侧并向外增减，候选紧贴真实外沿；手动/无目标布局仍固定底边。没有可信目标时才在鼠标所在屏幕居中靠下，显示后不追踪光标。圆角表面使用墨竹/翡翠固定 palette，内缩到透明窗口边距，并按 backing scale 在路径内绘制 hairline。显隐、frame、pin 与候选位置持久化，多屏变化时恢复到可见区域；自动开窗 origin 不覆盖用户保存位置，旧展开态偏好被忽略。普通关闭会收束组字、暂停捕获、结束 transient 加载/错误状态并保留已有块。`Command+Shift+B` 通过全局 Carbon hot key 调用 `toggleVisibility()`；工作台不提供块编辑器、面板内缓冲开关、手动遮蔽、历史恢复或清空撤销。
- Rime commit 只在捕获开启时进入 `BufferModel`；preedit 永不存入模型。成功调用 `Delivery.insert` 后，该 block 立即从 live buffer 消失且不保留明文发送历史；失败 block 和未发送后缀保留。
- 缓冲块在工作台中是被动展示单元，不再支持点选后单块编辑；Backspace 删除和显式投递仍由模型/协调器保持身份与顺序不变。输入法自身所有文本框都绕过缓冲捕获与远端镜像。
- Rime 组字候选默认使用常规 `CandidateWindow` 跟随工作台真实外沿：焦点锚定布局沿远离输入框的一侧显示，手动或无目标布局默认显示在下方；用户也可切回跟随 caret。工作台自身不包含 Rime 候选投影或全文预览；意识流的 1–5 个互斥解释在同一派生 target viewport 中分页。缓冲启停、常显与移屏入口保留在设置/输入法菜单；secure-input 检测与锁屏隐藏由 `BufferWindowController` 管理。锁屏、睡眠或会话切出会撤销租约、在 Rime 内收束组字并隐藏窗口，恢复后仍必须等新 activation/event。

### 5.11 AI 文本插件与连接器（P3）— 状态：✅ 单插件、三连接器已实现

- `AITextPluginWorkspace` 只对应一个 `builtin.ai-text`「AI 生成」缓冲插件，对当前 `BufferModel` 全文做显式生成快照；继续打字、切插件、关闭、secure input、刷新或切连接器都会取消/作废旧 generation。`WorkbenchManualGenerationPrimaryAction` 统一决定窗口主按钮与 Return：无源文为 disabled，有源文为 requestGeneration，running 为转圈，ready 为 deliver；请求和等待状态在 keyDown 就拥有整次物理 Return，防止同步/快速结果被同一次 keyUp 立即发送。请求前还在动作边界同步重查 secure input，命中时只吞键并立即保护全部派生 workspace、取消外部 prepared 调用，不依赖窗口轮询。首字前显示安全活动摘要和单调等待秒数；正文按 provider delta 真流式进入，并细分为短句/分句、列表项或步骤 block，URL、数字、引文与代码不被切断。block index 原位更新并保持 UUID；只有完成且仍匹配源快照的 target blocks 可投递。目标块全部成功发送后才一次性消费捕获的源 block，部分失败保留剩余目标与全部源文。
- `AITextConnectorRegistry` 把 Codex CLI、Claude Code CLI 与 OpenAI 兼容 API 作为独立于 `.bufferAction` owner 的三个模型源；旧 provider-specific plugin 选择会迁移为「AI 生成」owner + 原连接器偏好。AI 生成配置写回同一共享选择。实时翻译与 Marine 选择“当前 AI 渠道”时也复用它；Marine 另外允许 60–600 秒调用超时，并在每次请求开始时冻结。带 `preparePath` 的 Action Plugin 只返回通过五字段身份校验的 `blocks-v1` prompt，RimeBuffer 保留模型选择、凭据、执行、工具策略和结果校验。
- `MarineChromeWorkspace` 直接消费扩展提供的 6 秒网页上下文租约和当前 Stable Chrome `FocusToken`，不经过旧 Action Plugin 的 `preparePath`。生成时冻结 context、focus、source block IDs 和所选 AI provider；上下文、焦点、owner、secure input 或 source 任一变化都会取消/墓碑旧结果。CLI/API 可用性通知会刷新 idle/unavailable phase，但不得打断 running、撤销 ready 投递权或自动清除可见 failure。生命周期日志只能记录脱敏枚举和计数。
- `StreamInputWorkspace` 是第三种派生 source，不读取 `BufferModel`：它把 `a-z` 与归一化 ASCII Space 组成的 raw 全拼绑定到创建它的精确外部焦点，按灵敏 140/500、平衡 220/800（默认）或稳定 350/1200 ms 的 debounce/max-wait 自动请求意识流自己选择的 AI provider（默认 OpenAI 兼容）。捕获不以当前 Rime 配置为门槛，选择插件也绝不调用 `InputConfigurationStore.set` 或重部署 schema；Space 在 raw 中写入一个真实硬边界、上轨仅将其显示为 `·` 并立即请求，前导/连续 Space no-op，其他标点只消费，数字 1–5 与无修饰 ↑/↓ 控制候选。精确 Control/Command+A 只全选 raw source，Control/Command+V 在尾部追加或替换选中 raw；粘贴只接受 ASCII 字母与空白，任一其他字符或归一化后总 raw 超过 16 KiB 都原子拒绝。workspace 最多允许两个 provider 请求短暂重叠：旧路仅维持视觉连续，新 challenger 的首个合法非空 snapshot 或终态到达后才取消/墓碑旧路；两路都占用时只保留一个 latest-only pending。
- `MyPromptWorkspace` 是第四种派生 source，但继续读取普通 `BufferModel`：上轨是精确查询快照，下轨是本地索引返回且先裁为 1–3 条的互斥候选。候选展示文本只含标题/摘要，投递始终读取内部保存的完整 prompt；选择变化增加 delivery generation，协调器冻结前确认唯一结果。SQLite 使用 WAL 与 FTS5；导入器拒绝 symlink、非普通文件、NUL、越界文件和越界正文，并把 Fabric/Obsidian/aggregate Markdown 归一为稳定 source/record identity。远程 synchronizer 只接受无凭据 HTTPS URL，以固定 `/usr/bin/git` argv、禁用交互和 file/ext protocol，同步完成后才更新本地 source。数据库、library 与 checkout 位于 `RIMEBUFFER_LOCAL_DATA_ROOT`/`RIMEBUFFER_USER_DIR` 下的 `my-prompt`，后备为 `~/Library/RimeBuffer/my-prompt`，目录/数据库分别收紧为 `0700/0600`。
- 2026-07-26 飞耀扩展：串击/双拼仍逐字写连续全拼；显式 `.chord` 与 `.mutual` 都读取 `my_combo` 的有效映射并使用独立、焦点绑定的批次状态。并击只映射同批；互击额外允许相邻左/右半区批次在精确快照仍一致时重组。只有完整音节映射追加 soft ASCII syllable Space，单侧拼音片段映射不追加，二者都走普通 220/800 ms 调度请求。只有用户物理 Space（包括把末尾 soft Space 原位提升）是显示 `·`、立即请求并增加宿主最小分块数的 hard boundary。
- 每次意识流请求的 source 都是触发边界时的完整 raw 拼音，模型必须从全局重新解释，不能只处理新增后缀或把输入分段拼接。请求同时冻结本轮的候选上限与响应节奏，后续设置变化不能改变其 prompt、provider schema/decoder、partial/final 校验或 retry merge。旧显示、partial、baseline 与跨 revision 的旧响应不得进入 prompt；唯一例外是同 revision 的一次补候选请求可把前一个严格合法 final 作为有界、JSON 编码且不可信的排重数据。本地 `StreamInputPinyinHints` 生成最多三条全覆盖、lossless 边界提示，明确以 ` | ` 保留 Space；无法识别的 English/错键片段原样保留，超过 512 bytes 时省略提示。本地提示多于一种时 payload 设置 `minimumGuessCount=2`，但会被本轮候选上限封顶。waiting/running 时临时结果不显示选中态，也不能建立 result/delivery lease。补候选 partial 从已有候选之后的槽位开始且仍不可投递；final 必须逐槽精确覆盖 partial，旧 baseline 尾部不得进入正文。模型产出 1–5 个完整、互斥猜测，且永不超过本轮冻结上限；所有候选共享一个分页 target viewport，活动项内部再经 `SemanticBlockSegmenter` 细分为短句、中文分句或英文短词组。Space 子句数建立最小分块目标，宿主只在不切断英文单词、URL、代码、数字或引文时补拆。Return/纸飞机在协调器冻结 generation 前确认当前候选并删除其余状态，防止任一路径绕过选择；同一次 Return 轻按发送下一块、长按发送全部。raw 在部分投递期间保留，只在所选答案最后一块成功后清除；首块后继续输入字母或 Space 才会撤销未发送尾部与旧 raw，已发送前缀不能重复出现。
- `CodexCLITextProvider` 通过双向 stdio JSON-RPC 运行一次性 Codex app-server，消费 `item/agentMessage/delta`；除显式 `RIMEBUFFER_CODEX_PATH` 覆盖外，可执行文件探测优先 ChatGPT.app bundled Codex，再按顺序选择第一个通过能力检查的 Homebrew、用户 PATH、常见版本管理器或编辑器内置安装。它使用 `~/Library/RimeBuffer/ai/codex-home` 中独立、可持续刷新的 ChatGPT 登录，不读取 `~/.codex`。设置页把本地凭据状态与 CLI 能力状态分开呈现；account/login app-server 流程打开 HTTPS 授权页，按 loginId 绑定完成通知，再以 account/read 验证 ChatGPT 账户。取消、超时、进程退出与迟到回调均 fail-closed，生成前还要求 `mcpServerStatus/list` 为空。`ClaudeCodeCLITextProvider` 使用 `stream-json` partial；它在后台以官方 `claude auth status --json` 的 `loggedIn` 布尔值校验 CLI 授权，设置页通过固定 `claude auth login --claudeai` 流程发起、取消或重新授权。RimeBuffer 不读取 Claude 凭据文件，不传透 `CLAUDE_CODE_OAUTH_TOKEN`、`CLAUDE_CONFIG_DIR` 或 ambient API key。两个 CLI 都按实际能力而非版本号准入：Codex 候选必须以完整隔离 argv 完成无提示词 initialize 与空 MCP 握手，Claude 候选必须公开实际生成所需的工具关闭和流式参数；新旧版本只要满足契约即可使用。能力/授权探测在后台缓存并周期复核，hot path 只读缓存；生成前用 stat 指纹确认已验证可执行文件未被替换。两者均用 `Process`、固定 argv/stdin 和 0700 临时工作目录，不经 shell，不把正文放入进程参数或日志，并限制时间与输出大小、关闭工具及会话持久化。“本地 CLI”只表示进程在本机启动，**不代表本地推理**。
- `OpenAICompatibleTextProvider` 调用 `POST {baseURL}/chat/completions` 并要求 `text/event-stream`，消费 SSE delta 和 `[DONE]`；2xx 非 SSE 响应 fail-closed。Base URL、model 与 API key 在“连接器 › AI 模型”管理；远程端点必须 HTTPS，HTTP 仅允许精确 loopback。意识流选用该渠道时，`.alternativeGuesses` 显式发送 `thinking: {type: disabled}`、`response_format: {type: json_object}`、`max_tokens: 1024` 与低 temperature；普通 AI 生成不继承这些专用字段。请求阶段日志仅记录 request UUID、HTTP 状态、首 transport/content/snapshot 耗时、字节/块数及枚举结果，写入进程级异步串行日志器，永不记录 URL、model、raw、prompt、正文或 key。配置与密钥存于 `~/Library/RimeBuffer/ai/openai-compatible.json` 的 0600 文件，不进 UserDefaults 或日志；文件位于 app bundle 外，开发安装脚本重播种 Rime 数据时必须排除 `ai`，pkg/应用内更新也只替换 app，不能清除已有配置。
- 未经 review 的 Action Plugin 目标绑定块不能被 AI 插件当作源文，避免洗掉原 runtime/context/focus 权限。语音输入仍属后续能力。

### 5.12 Deploy / userdb（P4）— 状态：✅ 自包含部署已实现；学习词同步仍是路线图

- **现状**：app 自带 librime、插件和 Rime shared data，启动时在独立的 `~/Library/RimeBuffer` 执行 maintenance/deploy；正式安装不依赖 Squirrel。`build_install.sh` 默认可从 `~/Library/Rime` 重新播种用户配置与 userdb，也可在没有 Squirrel 用户目录时从 bundled schemas 独立部署。
- 激活热路径只对 `build/default.yaml`、已部署 schema 与 `squirrel.yaml` 做轻量文件指纹检查；schema 列表和键盘布局解析按文件内容/原子替换自动失效，进程内部署成功后显式清缓存。任何 standalone smoke/preview 都在初始化 librime 前强制改用临时 userdir；engine smoke 在该目录中复刻正式包的 `Vendor + rime-data` SharedSupport，不打开 live LevelDB。
- **隔离不变量**：两个活跃 Rime 实例不能共享同一 userdb LevelDB，因此运行时继续使用 `~/Library/RimeBuffer`，不直接打开 Squirrel 的 `~/Library/Rime`。
- **[P4 路线图]** 决定使用 librime sync 还是显式迁移来同步学习词；Developer ID/hardened runtime/双重公证的 fail-closed workflow 已落地，首次正式 tag 仍需在仓库配置 8 项受保护凭据并通过 Apple 在线验收。不得为了同步而恢复两个进程直接共用一个 userdb。

---

## 6. 关键契约备忘（实现时对照）

- **vtable 顺序 load-bearing**；`RIME_STRUCT_INIT` 每个 Rime 结构体必做（data_size 版本协商）。
- keysym：X11/ibus 体系。修饰 mask：shift 1<<0 / lock 1<<1 / ctrl 1<<2 / alt 1<<3 / super 1<<6 / **release 1<<30**。特殊键 0xff08(BS) 0xff09(Tab) 0xff0d(CR) 0xff1b(Esc) 0xff51–54(箭头) 0xff55/56(翻页) 0xffe1–ec(修饰) **0xffbe+n(Fn)**；可打印 0x20–0x7e 原码直传。
- 线程：IMK 键回调在主线程；P1 全部 librime 调用留主线程 + **watchdog**（单次 process_key/get_context >250ms 记日志定 Lua 嫌疑）。gMutex 不可重入。
- IMK 注册：bundle id=`com.isaac.inputmethod.RimeBuffer`，可选择 mode id=`com.isaac.inputmethod.RimeBuffer.Hans`（父/子 TIS id 必须不同），`InputMethodConnectionName=RimeBuffer_1_Connection`，`InputMethodServerControllerClass=RimeBufferController`（对应 `@objc(RimeBufferController)`）。父输入法不声明 repertoire，使 TIS 保持标准的 ASCII-capable parent；只有中文 child mode 声明 `Hans/Hant`，且不可含 `Latn`。底层键盘布局遵循 `squirrel.yaml`：`last`/空值不 override，`default` 才映射 ABC。安装不复用旧 TIS ref，而是以短命子进程按 `register → verify installed → enable parent → verify parent → enable child → verify enabled roster → best-effort select` 分阶段收敛；每阶段都用 bundle/source id 精确过滤的新快照，拒绝重复 ref，并把 presence/type/enabled/select/ASCII 分开诊断，ASCII 不再作为启用成功条件。每个子进程有 3 秒硬超时，整个激活有 90 秒总预算；selection 不进入持久重试条件。Installer 不结束 `imklaunchagent`/`TextInputMenuAgent`；当前 GUI 会话未收敛时，写入用户 marker 与 one-shot Aqua LaunchAgent，下次登录重试并在成功后自清理。无 GUI 用户时只安装 payload，下次登录由用户激活。两者都不把已成功落盘的 payload 转成 PackageKit Code 112。只有缺少 executable、bundle id/输入 mode metadata 错误或签名完整性失败才使 pkg 失败。重装/更新的 fallback/deactivate 必须在 preinstall、即 payload 替换前，由包内当前版本的签名最小 helper 在 5 秒边界内执行，不能依赖旧 app 理解新参数。IMKServer 引用存顶层变量保活；为 nil 时大声记日志退出，不留僵尸输入源。
- 日志 `~/rimebuffer.log`（IMELog）。**每个修复都要先能在日志里看见**（哪个键、哪个 client、走了哪条路径）——这是无 GUI 调试的生命线。

---

## 7. 仓库地图

```
rime-buffer/
├── ARCHITECTURE.md            ← 本文
├── Package.swift              ✅ CRimeBridge(C++17) + RimeBuffer(链 InputMethodKit/Cocoa)
├── Info.plist                 ✅ IMK 注册(连接名/控制器类/输入源 vending)
├── build_install.sh           ✅ 构建→ad-hoc 签名→装 ~/Library/Input Methods→lsregister→播种 userdb
├── Sources/CRimeBridge/
│   ├── include/CRimeBridge.h  ✅ C 接口 + BBRimeContext/BBRimeStatus 结构
│   └── CRimeBridge.cpp        ✅ vtable/dlopen/maintenance/deploy/健康门控/ConfigGetDouble
└── Sources/RimeBuffer/
    ├── main.swift             ✅ smoke 分支 + IMK 引导（不创建独立 StatusItem）
    ├── RimeEngine.swift       ✅ 可实例化封装
    ├── RimeKey.swift          ✅ keysym/mask 表（含 F1-F12、grave）
    ├── RimeModels.swift       ✅ RimeContextModel/RimeStatusModel
    ├── RimeBufferController.swift ✅ 总装完成(键路由/chord 门控/菜单/兜底/watchdog/forceCommit)
    ├── CandidateWindow.swift  ✅ 唯一候选面板+caret/缓冲条双锚点
    ├── InputFocusCoordinator.swift ✅ FocusToken+当前client租约
    ├── Delivery.swift         ✅
    ├── Log.swift              ✅
    ├── CompositionSession.swift  ✅ v2 组字协议(inline/placeholder)
    ├── ChordController.swift     ✅ duration 读 ChordSettings（默认 0.10s）
    ├── StatusMenu.swift          ✅ IMK menu() 单入口 + 菜单操作协调
    ├── (FocusObserver)           ✅ 以 main.swift 的 NSWorkspace 观察器实现(forceCommit+藏窗)
    ├── BufferModel.swift          ✅ P2 缓冲模型(live块/成功消费/无历史/transient)
    ├── BufferDeliveryCoordinator.swift ✅ 精确焦点逐块投递/失败后缀保留
    ├── BufferWindowController.swift ✅ 常显工具栏空白拖动、单轨78pt/双轨112pt、1–5 alternative分页/插件刷新/多屏/隐私
    ├── BufferInlineView.swift     ✅ 工作台块轨、来源徽标、source全选与多行target
    ├── GlobalHotKeyController.swift ✅ Command+Shift+B 全局打开/关闭工作台
    ├── AppleTranslationPlugin.swift ✅ 实时翻译双轨工作区（Apple 本地默认 / 当前 AI）
    ├── AITextPlugins.swift       ✅ 单一 AI 双轨工作区 + Codex/Claude/OpenAI 三源连接器
    ├── StreamInputPlugin.swift   ✅ 焦点绑定连续全拼 + 独立 AI 路由 + 1–5候选/三档节奏请求冻结
    ├── MyPromptPlugin.swift      ✅ 本地优先提示词检索 + 1–3 结果选择与目标投递
    ├── MyPromptStore.swift       ✅ SQLite FTS5 / 中文 bigram 与拼音索引
    ├── MyPromptImporter.swift    ✅ Fabric / Obsidian / aggregate Markdown 安全导入
    ├── PluginConfiguration.swift ✅ 声明式 schema / 通用表单 / 普通与私有存储
    ├── RemarkablePlugin.swift    ✅ SSH 当前页稳定校验 / USB PDF 导出 / 前后复验 / 取消墓碑
    ├── RemarkableLocalOCR.swift  ✅ PDFKit 目标 300dpi 有界渲染 + Apple Vision 本地 OCR
    ├── SettingsWindow.swift       ✅ 四方案/F4/部署/候选窗/缓冲与通用插件配置
    ├── InputSchemaCatalog.swift   ✅ 四方案产品目录 + schema_list 安全读写
    └── [P3+] 语音/CaretLocator/精细 Deploy

**键路由铁则补充(实测 bug 修正)**：Cmd 按住的 keyDown 一律直通 App(先 forceCommit 再放行)——
my_combo 里字母全是 chording key,不早退会被 chord_composer 吃掉 Cmd+C/V;
chord 缓冲排除一切带 Ctrl/Opt/Cmd 的键。
```

前身仓库（只读参考，不再开发）：`bufferbar-ime/`（IMK+桥原型，chord/flags 时序的行为规格）；`buffer-bar/`（独立 AX 注入 App，buffer UI 素材库）。

---

## 8. 构建 · 安装 · 调试手册

```bash
cd ~/Documents/05-dev/apps/rime-buffer
./build_install.sh                 # 构建+签名+安装+注册（幂等）
# 启用（一次性）：系统设置→键盘→输入法→编辑→＋→简体中文→RimeBuffer→添加
tail -f ~/rimebuffer.log           # 行为日志
.build/release/RimeBuffer smoke    # 四方案/F4/中文/英文引擎自检
.build/release/RimeBuffer schema-smoke  # 设置页 schema_list 读写自检
.build/release/RimeBuffer buffer-smoke # 成功消费/未发顺序/隐私丢弃/暂停保留
.build/release/RimeBuffer buffer-window-smoke # Focus/目标/生命周期门控/多屏frame
.build/release/RimeBuffer ai-text-smoke # CLI/API 解析、0600 配置与 source/target 投递自检
.build/release/RimeBuffer plugin-configuration-smoke # 配置 schema、迁移、0600 与脱敏边界
.build/release/RimeBuffer remarkable-plugin-smoke # Remarkable PDF/本地 OCR、SSH 状态机与凭据边界
# 需要 reseed 时直接重跑上面的 build_install.sh；脚本会保留 ai/、plugins/ 等产品状态
pkill -x RimeBuffer                # 系统会按需重新拉起
# 卸载：rm -rf ~/Library/Input\ Methods/RimeBuffer.app && 输入源列表移除
```

已踩坑速查：本地 `build_install.sh` 仍用 ad-hoc；正式 tag 由一次性 keychain 完成 Developer ID + hardened runtime + app/pkg 公证，不可降级回未签名 · 我方 Bash 沙盒里 `open` GUI app 会假失败，装完由系统拉起或用户双击 · smoke 若 0 候选先查四方案是否已部署以及 userdb LOCK。

不要用 `rm -rf ~/Library/RimeBuffer` 触发 reseed：该目录还包含 `ai/openai-compatible.json` 等用户凭据和产品持久状态。`build_install.sh` 自带安全重播种逻辑，会保留这些目录；若只想替换应用且完全跳过 userdb 重播种，使用 `RB_KEEP_USERDB=1 ./build_install.sh`。

---

## 9. 路线图与验收闸

### P1'（状态：**已全部实现并过三视角对抗审查（14 项修复已并入），等用户实测验收**）——"三个现场 bug 清零"

> 审查并入的关键修复：activateServer 用真实硬件修饰键状态播种 lastModifiers（Caps 常开不再乱流）；
> grave 按修饰键分派（Shift+`=波浪号 0x7e，Ctrl+grave=切换器）；deactivate/commit 只作用于当前
> `FocusToken`：显式 sender 必须精确匹配；nil/non-client sender 仅在 `self.client()` 仍指向同一对象且通过年龄/抑制规则时接受，绝不作为投递目标兜底；App 切换观察器升级为 forceCommit；候选点击加
> acceptsFirstMouse（非激活窗首击生效）；多屏定位改点包含（零宽 caret rect 与 intersects 不兼容）；
> 引擎恢复路径走 ensureSessionReady（chord 时长/方案门控不再半初始化）；F4 在 Rime 内切方案会
> 持久化为 preferred（与菜单切换同权）；chord flush 时序逐字节对齐原型（press 前 flush、release 不预 flush）。

| # | 任务 | 验收（用户实测） |
|---|---|---|
| 1 | CompositionSession：marked text 常驻（inline 默认 + placeholder per-app） | 微信打 zuoye→空格：**只出现「作业」，无字母残留**；组字串内联可见带下划线 |
| 2 | 候选窗定位链接入 marked 会话 caret rect | 候选窗贴在光标正下方，Safari/微信/终端一致；不再沉底 |
| 3 | RimeKey 补 F1–F12 + grave；确认 Ctrl+Shift+3 通路 | **F4 弹出方案选单**（候选窗渲染），可选到并击；Ctrl+Shift+3 切标点生效 |
| 4 | ChordController 抽出 + `ChordSettings` 可调 duration + my_combo 实测 | 并击单击不被吞、连击成词；其他方案无合成 release（日志验证） |
| 5 | StatusMenu（仅 IMK menu） | 无重复状态栏图标；系统输入法菜单可见且操作可用 |
| 6 | 兜底收口 + watchdog | kill -STOP 模拟引擎挂：打字退化英文不丢键；日志出现 watchdog 行 |

**P1 总闸**：用户以 RimeBuffer 为唯一输入法工作一整天（Squirrel 不卸载仅待命），四方案/F4/翻页/简繁/标点全程无需切回。

### P2 buffer / P3 语音+AI / P4 转正

闸口见 §5.10–§5.12。P2/P3 自动验收已覆盖成功消费且不留历史、未发顺序、迟到 focus epoch、多屏 frame、工作台插件单选、派生 1–5 alternative 单轨分页、AI 流式 block 稳定性，以及普通/插件/意识流 source 的 Ctrl/Cmd+A/V、粘贴语义分块和意识流原子拒绝。真机还需覆盖 Safari/Electron/微信跨文本框切换、常显/全屏、`Command+Shift+B` 全局唤起、关闭保留、插件刷新不丢正文、派生分页对齐、真实 CLI/API 登录，以及 secure input 下快捷键原生直通且输入法不读剪贴板。P4 核心验收：连用一周零"打不出字"事件；改 schema 后进程内重部署生效；password 框优雅直通。

---

## 10. 风险登记簿（活文档，解决即划掉）

| 风险 | 缓解 |
|---|---|
| IME 进程崩/卡 = 系统级打不出字 | 兜底不变式(§3-3) + watchdog + Squirrel 待命 + 状态提示 |
| chord 时序被改坏 | 逐字节移植 + schema 门控 + duration 读配置 + 日志每键可追 |
| marked text 在个别敌意 App 仍坏 | per-app placeholder 模式表，逐个登记而非全局裸奔 |
| 每控制器 session 割裂全局开关体感 | activateServer 镜像 + UserDefaults 记忆 |
| userdb 双实例锁冲突 | 独立 ~/Library/RimeBuffer；转正后统一（§5.12） |
| Squirrel 升级/卸载破坏 dylib 依赖 | 启动路径校验 + 明示错误；P4 考虑自带 librime |
| Lua 脚本卡死输入线程 | watchdog 记录定位；用户改 Lua 先过 smoke |

## 11. 未决问题（留给用户/后续拍板）

1. 候选窗要不要横排模式跟随 `candidate_list_layout`？（用户现用 stacked 竖排，P1 只做竖排）
2. 学习词同步策略：P4 用 librime sync 还是直接回切 `~/Library/Rime`？
3. 转正时签名走 Developer ID 公证还是维持本地 trusted 自签？
