# RIMES

从零做的现代 macOS 输入法：librime 引擎 + 自绘候选窗 + 常驻缓冲区（buffer），提供飞耀互击、自然码双拼、全拼和英文方案。**自包含**——librime 与 Rime 词库打包在 app 内，装一个就能用，无需单独安装 Squirrel。

> 仓库/内部代号仍是 **RimeBuffer**（SPM target、`Sources/RimeBuffer/`、控制器类）；`ETInput.app` 也是为兼容旧安装和自动更新保留的内部路径。对外产品名统一为 **RIMES**。

**接手开发者：先读 [SYSTEM-ARCHITECTURE.md](SYSTEM-ARCHITECTURE.md)**——这是当前权威全局架构；[ARCHITECTURE.md](ARCHITECTURE.md) 保留 P1/P2 的历史契约与踩坑记录。

## 缓冲工作台

开启缓冲模式后，提交内容进入独立工作台。普通模式折叠时是 44pt 高的单行细条，依次为拖拽图标、展开箭头、缓冲块轨和右侧发送；向上展开后总高 78pt，上层依次显示状态、缓冲插件选择器与当前插件动作、刷新/重置和关闭。翻译、AI 生成与意识流使用 source/target 派生布局：单个 target row 的折叠/展开高度为 78/112pt，意识流出现 2/3 个候选时高度增为 109/143pt 与 140/174pt；所有模式都只向上增高，底边与候选锚点保持不动。设置页可同时开启多个 `.bufferAction` 插件；工作台选择器只列出这些已开启插件，并以带图标的 `Default` 表示不使用插件。选择器切换时只替换唯一 owner，不改其他插件的启用状态。刷新/重置不清除缓冲正文：外部插件会取消过时任务并重新检测上下文，内置派生插件会保留源文并重启当前生成。插件可用 `presentationId` 把多个场景动作收敛成一个稳定呈现：例如 Marine 的直评与回复继续由当前 `status.actionId` 动态选择；当它是 owner 唯一的 presentation 且属于 prepared generation 时，会提升到主条右侧 AI 控件，展开层不再重复显示“生成评论/回复”按钮。没有有效评论框时 AI 控件保留但禁用；只要还有第二项动作，全部动作都保留在展开层，Return 不猜测。只有拖拽图标能移动窗口；缓冲启停、常显与移到当前屏幕仍由设置或输入法菜单管理，工作台本身不再提供缓冲开关或块编辑器。按 `Command+Shift+B` 可在任意应用中切换工作台：关闭时打开并恢复捕获，打开时收束组字、保留内容并关闭暂停。Rime 组字候选仍只由常规 `CandidateWindow` 呈现在缓冲条下方；意识流的互斥解释是工作台 target rows，不是 Rime 候选投影。

缓冲开启后，librime 在英文/ASCII 模式主动放行的可打印字母、数字、空格与普通标点也由工作台接住，不再流入宿主；逐键英文会合并为短词组 block，连续输入的尾块可逐字退格。Command/Control/Option/Fn 快捷键、工作台自己的输入框与 secure input 不进入这条捕获路径。中文 Rime commit、直接英文和插件结果因此都遵守同一个“先入缓冲、再显式投递”边界。

缓冲模式下，普通或 Shift+Return 与 Backspace 都由输入法吞下，永不落到宿主文本框：若仍在组字/并击，本次 Return 只把它收束为缓冲块；没有未决组字时，Return keyDown 会先重建不可见的 IME guard，轻按抬起发送下一块，持续按住约 1.2 秒发送全部。Backspace 只在精确焦点下编辑 Rime 组字或删除缓冲块。引擎故障但没有未决组字时，已有块仍可安全发送；若未决组字无法收束，或焦点不可信，本次按键只吞下、不投递。主条右侧纸飞机每次只发送下一块。Return 手势只认 keyDown 时绑定且当前仍有效的外部文本框；纸飞机只认点击时的当前实时焦点。切换应用或文本框后不会使用旧目标。成功发送的块会立即从缓冲条消失且不保存发送历史；发送失败或尚未发送的块继续保留。关闭工作台会暂停捕获、结束未完成的加载状态，但保留已有块；可选的跨应用隐私清理不可撤销，只在真实外部应用 A→B 时触发。

工作台对普通缓冲与所有插件统一接管精确的 `Control+A` / `Command+A` 和 `Control+V` / `Command+V`：前者全选当前可编辑 source，后者在块光标处插入，或替换已全选的 source。普通、翻译、AI 生成与 Action/Marine 都编辑 `BufferModel` 源块；意识流只全选/粘贴 raw 上轨，生成的候选行不可编辑。普通粘贴保留精确连接文本（包括纯空白），再用共享语义分块器生成 chips；非空纯文本上限为 1 MiB，含 NUL 或超限时整次不变更 source。仅有单一 Control 或 Command 修饰时才识别这两组快捷键；额外 Shift/Option、Control+Command 组合、本应用窗口或 secure input 均保留宿主原生语义。secure input 下 RIMES 不读取剪贴板；非精确外部焦点则 fail-closed 消费按键且同样不读取。每次粘贴都在读取前后重验同一 `FocusToken`，以防延迟 pasteboard provider 把文本放进已切换的字段。

窗口位置和显示偏好会保存；缓冲内容只在本次输入法进程内保留。工作台不提供手动遮蔽、发送历史、恢复或清空撤销。

设置采用左侧一级导航、右侧横向子页：输入法（输入编码 / 键入模式 / 词库）、外观、缓冲区、连接器、插件和维护。词库页能通过 librime 官方用户词典接口导入/导出中文 `rime_ice` 与英文 `english` 的学习记录，不复制正在使用的 LevelDB；统计、打字测速和飞耀互击学习则作为可停用的内置扩展动态出现在左侧。

输入编码、键入模式和词库在设置中分层呈现，但运行时仍由经过验证的 Rime 方案组合承载，避免产生不能部署的任意交叉组合。当前包含全拼串击、自然码双拼串击、英文串击，以及复用同一飞耀码表的并击/互击：并击只组合当前时间窗内的按键，多键单侧击也正常结算但不跨击重组；互击还允许相邻的左侧声母、右侧韵母跨击配对。单独敲下的物理字母始终保持原样，不自动插入分词符；至少一侧为多键和弦时才允许跨击重组。真正无映射的组合保留可由 Return 提交的原码，单按 `,`、`.` 仍由 Rime 标点规则输出。单独轻点 Shift 保留原有中英切换；Shift 一旦与字母/标点组合使用，或持续按住达 500 ms，松开后会回到按下前的中英状态。

插件平台分为两类：外部缓冲插件与编译进应用的内置扩展。前者继续由 Action Plugin v1 宿主执行，可从本地目录、`manifest.json` 或 HTTPS 声明文件安装；安装、卸载和管理收进设置页顶部的独立弹窗。每个插件以小图标、说明和独立 Switch 呈现，多个缓冲插件可以同时开启，开启集合决定工作台选择器的内容。具有声明式配置的插件统一显示“设置…”按钮；字段、校验、普通偏好和敏感存储都遵循 [PLUGIN-CONFIGURATION.md](PLUGIN-CONFIGURATION.md)，不再为单个插件追加一次性设置界面。Marine 是首个使用 `preparePath` 的兼容插件：它只冻结页面上下文、整理话术提示词并维护自己的记录与界面信息，真正的模型授权和执行由 RIMES 当前选中的 AI 连接器完成；设置页可选择这个共享渠道，并把新请求的生成超时设为 60–600 秒，每次调用在启动时冻结自己的超时。后者可以贡献设置页和只读、脱敏的本地输入观测能力，但不能被外部包注入 AppKit 视图。两类插件使用带 domain 的身份隔离；仍匹配原上下文和焦点的外部结果进入缓冲区，失效或迟到结果进入收件箱待确认，两条路径都不会直接上屏。

「实时翻译」是内置缓冲插件，与 Marine 等外部缓冲插件进入同一个列表、使用同一种带图标卡片和独立 Switch；它们可同时开启，但工作台仍只选择一个当前 owner。它默认使用 macOS 15+ 的 Apple 本地翻译，原文不离开本机；也可在插件设置中改为当前 AI 渠道，并配置源语言和目标语言。翻译工作台上方是合并为连续文本、不分 block 的原文缓冲，下方是独立且可分 block 的译文缓冲，两条轨道各自横向滚动。翻译态下，左侧拖拽与展开按钮直接对齐上方原文行，右侧发送按钮直接对齐下方目标语言行。输入停顿 300 ms 后发起刷新；持续输入时至多等待 900 ms 就启动一轮，翻译在途期间只排队最新快照，不反复取消。保存新配置会取消旧请求，并按未改动的源缓冲重新翻译；发送键只投递与当前原文和当前配置完全匹配的已完成译文，永不自动上屏。

「Remarkable」是一个显式、只读的内置缓冲动作。用户先在 reMarkable 上对页面执行官方 “Convert to text”，再在展开的工作台点击“拉取转写”；RIMES 通过系统 `/usr/bin/ssh` 找到最近打开文档的当前页，读取 software 3 的 v6 `.rm` 原生 typed text，并以 `.ssh` 来源加入普通缓冲区。它不会从 SSH 触发设备的云端转写、不会轮询、不会停止 Xochitl、不会修改设备文件。默认目标是 USB 连接的 `10.11.99.1`；“设置 › 插件 › Remarkable › 设置…”可保存主机、SSH 用户名和密码，也仍支持 SSH key/agent。密码只保存于 `~/Library/RimeBuffer/plugin-config/builtin.remarkable/credentials.json`：目录权限为 `0700`、文件为 `0600`，调用时经受限的 `SSH_ASKPASS` 读取，不进入命令参数、环境值或日志；SSH 始终严格校验现有 `known_hosts`，未知主机安全失败。同一页必须连续读取两次且字节完全一致才会解析，修改配置、owner 切换、关闭、锁屏或 secure input 都会取消并作废在途拉取；拉取成功仍需用户用纸飞机或 Return 明确投递。设备官方转写本身仍要求联网和 reMarkable 账户，且 2026 年官方语言列表不含中文；本插件不会把外部 OCR 冒充成设备原生转写。

「AI 生成」现在是唯一的内置 AI 缓冲插件；原来的「Codex CLI」「Claude Code CLI」「通用 Open API（OpenAI 兼容）」不再分别占用三个插件位，而是三个可切换的模型源。既可在“设置 › 连接器 › AI 模型”管理授权与私有连接信息，也可从“设置 › 插件 › AI 生成 › 设置…”选择当前渠道；插件 owner 与连接器选择彼此独立。实时翻译和 Marine 选择“当前 AI 渠道”时复用同一选择。内置 AI，以及整个动作面只有一个 prepared presentation 的外部 owner，共用主生成控件且不在展开层显示独立“生成”按钮：可以请求时右侧显示 AI 图标，生成中显示转圈，结果就绪后变为纸飞机；不可请求时 AI 图标禁用并通过提示说明原因。没有未决组字时，Return 与这个主按钮共用同一状态：先请求 AI，结果就绪后的新一次轻按才发送下一块，长按仍发送全部；Marine 的页面模式仍在请求瞬间决定直评或回复。Marine 投递态只选择匹配其 prepared action group 的最终结果，较早的普通缓冲块、其他动作结果和失效结果会原样保留而不会被这次纸飞机误发。内置 AI 的请求会保留上方源文，首字返回前持续展示连接、思考摘要、重试或校验状态与已等待秒数；正文到达后在下轨按增量真正流式更新，并由宿主细分为短句、分句、列表项或步骤 block（URL、数字、引文与代码保持完整）。完成后才可手动发送；只有下方所有目标 block 都成功发送后，生成时捕获的源 block 才会一次性消费，部分发送失败不会丢失源文。

「意识流输入」是另一个独立的内置缓冲插件。缓冲开启且它被选中时，会按用户当前的完整输入配置解释无修饰物理按键，但不持久化、不切换输入方案，也不重部署 Rime：串击/双拼的 `a-z` 逐字写成连续全拼；飞耀并击与互击都按同一组键时长读取有效 `my_combo` 映射，并分别保留“只结算当前批”和“相邻左声母批 + 右韵母批跨批重组”的语义。完整音节后自动写入一个 sidecar 标记的 soft ASCII Space；尚未配对的单侧拼音片段与单键不加 Space，两个单键批不重组。raw 由小写字母和归一化的 ASCII Space 组成，绑定在独立 workspace，不进入 Rime preedit、候选、`BufferModel` 或宿主文本框；用户物理 Space 保留为 hard 短句边界并立即触发一次完整 raw 推断，紧跟 soft Space 时原位提升而不重复写入，前导/连续 hard Space 不重复造边界，上轨以 `·` 给出可见反馈。其他标点仍由该轨消费但不写入 raw，数字 `1`–`3` 与无修饰 ↑/↓ 可切换候选，带修饰方向键继续交给宿主。普通 raw 变更默认停顿 220 ms 后自动全局猜测，持续输入最长默认等待 800 ms；“设置 › 插件 › 意识流输入 › 设置…”可为它单独选择 Codex CLI、Claude Code CLI 或 OpenAI 兼容渠道，并调整这两个节流参数，不会改动普通 AI 生成的渠道。Space 的立即请求不会妨碍之后字母建立新的 trailing debounce。意识流粘贴仅接受 ASCII `A-Z`/`a-z` 与空白：字母转小写，空白连续段归一为一个真实 hard ASCII Space，并对新完整 raw 立即发起一次推断；任一中文、数字、标点、NUL 或归一化后总 raw 超过 16 KiB，整次粘贴原子拒绝，选择、raw、候选、generation 与在途请求均不变。

意识流采用最多两路的有界 make-before-break：旧请求只负责维持可见 baseline，新请求首个合法 partial 或终态到达后才取消旧路；如果两路都在等待，更多按键只更新一个 latest-only pending，不会继续扩散请求。每一轮都重新发送当时包含 Space 边界的完整 raw 拼音，不把新增后缀分区推断、把旧结果放进 prompt，或与旧结果拼接。本地音节提示器会给同一次全局请求附上最多三条 lossless 边界读法，以 ` | ` 保留 Space，保留 English 与错键片段，但不生成中文。存在多种本地切音时 prompt 会明确要求至少两个实质不同的完整猜测。新的流式 partial 按公共前缀和稳定候选槽位原位续写；final 精确覆盖本轮槽位，任何旧尾都不能混进可投递正文。每个完整候选独占下轨一行，候选行内再由宿主按短句、中文分句、英文单词/短词组细分为可逐块投递的 chip；1–3 行会让面板向上增高而保持底边不动。↑/↓ 选择后，Return keyDown 或纸飞机在实际投递前原子确认当前版本并淘汰其余候选，同一次轻按继续发送下一块，长按 Return 发送该版本全部剩余块。已经发送一块后再输入字母或 Space 会丢弃未发尾部并建立全新 raw，已发送前缀不会复活。waiting/running 阶段不授予投递资格；墓碑后的迟到回调会被作废。

上轨显示带可见 Space 分界的连续拼音，下轨显示 1–3 个按可能性排序的完整、互斥猜测；多候选逐行而不是横向藏在一条长轨中。按 ↑/↓ 或数字 `1`–`3` 切换选中项；结果尚未 ready 时 Return 只强制当前完整 raw 的猜测并吞掉同一次物理按键，结果 ready 后 Return 或纸飞机确认当前版本、删除其他版本并开始逐块投递。换字段、切插件、关闭缓冲或进入 secure input 会取消任务并清除 raw 与结果。

Codex/Claude 连接器在本机直接启动 CLI，使用各自的 CLI 授权状态，而不是由 Marine 保存 API Key；“本机启动”也不等于本地推理，正文或 Marine 准备好的话术仍会经所选 CLI 的服务发送。Codex 使用 app-server 的 answer delta；除显式 `RIMEBUFFER_CODEX_PATH` 覆盖外，自动探测优先使用 ChatGPT.app 自带的 Codex，继续按顺序查找并选择第一个已验证的 Homebrew/用户 PATH 版本。它把专用 ChatGPT 登录保存在 `~/Library/RimeBuffer/ai/codex-home`，不读取用户 `~/.codex` 里的登录、MCP、Hook、插件或技能；未授权时可直接在“设置 › 连接器 › AI 模型”的 Codex 卡片打开浏览器登录，等待、取消与重新授权都有明确状态。发送正文前还会再次断言 MCP 列表为空。Claude 可在同页调起官方 `claude auth login --claudeai` 浏览器授权，并在后台以 `claude auth status --json` 的 `loggedIn` 结果作为就绪门控；RIMES 不读取 Claude 凭据文件，不传透 `CLAUDE_CODE_OAUTH_TOKEN`、`CLAUDE_CONFIG_DIR` 或 ambient API key，生成使用 `stream-json` partial。两个 CLI 的版本与授权探测都在后台缓存并周期复核，不阻塞输入法主线程；真正生成前还会校验已验证可执行文件未被替换。RIMES 固定命令参数、关闭工具调用与会话持久化、隔离临时工作目录并对 CLI 版本做 fail-closed 兼容检查；当前已验证白名单为 Codex `0.144.1`/`0.145.0-alpha.18` 与 Claude Code `2.1.211`/`2.1.215`。OpenAI 兼容连接器要求服务提供 SSE，在同一设置页配置 Base URL、model 和 API key；意识流专用请求会显式关闭 DeepSeek thinking、要求 JSON object、限制为 1024 output tokens，普通「AI 生成」不继承这些字段。密钥与配置保存到 `~/Library/RimeBuffer/ai/openai-compatible.json`，文件权限为 0600，不写入 UserDefaults 或日志。该文件位于 app bundle 之外，开发重装、pkg 覆盖安装和应用内更新都必须保留 `~/Library/RimeBuffer/ai`，因此升级后无需重新填写。

`my_combo` 方案中的旧 Lua/Python AI 链路已经下线：不再加载 `ai_box`、剪贴板 AI、状态候选、AI translator/filter 或 `ai_mode`，也不再由 Rime schema 启动 Python。AI 生成只走原生工作台插件与上述连接器链路；普通输入所需的其他 librime Lua 能力不受影响。

## 安装

普通用户优先下载 GitHub Release 里的 `RIMES-版本号.pkg`，双击按向导安装。安装器会把内部兼容路径
`ETInput.app` 放进 `/Library/Input Methods`，并在当前登录用户会话里自动注册、启用、尝试切换到
「RIMES」。

开发者本机调试再用脚本：

```bash
./build_install.sh                # 构建+安装到当前用户+注册
.build/release/RimeBuffer smoke   # 免安装引擎自检
.build/release/RimeBuffer schema-smoke  # 设置页方案列表读写自检
.build/release/RimeBuffer buffer-window-smoke # 焦点/生命周期门控与多屏恢复自检
.build/release/RimeBuffer ai-text-smoke # 单插件/三连接器、prepared prompt 与双轨投递自检
.build/release/RimeBuffer stream-input-smoke # 意识流按键门、全量重算、连续渲染、OpenAI 路由与 1–3 猜测自检
.build/release/RimeBuffer plugin-configuration-smoke # 声明式配置、迁移、私有存储与脱敏边界自检
.build/release/RimeBuffer remarkable-plugin-smoke # Remarkable 场景解析、SSH 状态机与凭据边界自检
tail -f ~/rimebuffer.log          # 行为日志
```

如果安装后输入菜单暂时没刷新，先运行 `killall TextInputMenuAgent SystemUIServer`，仍看不到再注销重登一次。

## 发布 / 自动更新

已装的 RIMES 会自动检查 GitHub Release；相关控制入口位于系统输入法菜单。发布新版本：

```bash
./scripts/release.sh minor        # 打 tag 触发 CI 构建并发布 Release
```

细节见 [RELEASE.md](RELEASE.md)（CI、通用二进制、应用内更新流程）。

## 隔空传字（Mac ↔ Mac）

从系统输入法菜单打开「设置…」并启用「隔空传字」，两台 Mac 即可把你打的字即时发到对方的输入框——加密的局域网
点对点直连（Network.framework + Bonjour + AWDL，无需同一 Wi-Fi、无需 Apple ID）。

配对是「请求 → 同意」，**没有配对码**：A 菜单点「配对新设备 → B」→ 两台各显示同一个 4 位验证码
→ A 核对后点「配对」、B 点「同意」→ 之后自动静默连接。基于 X25519 身份 + TOFU 信任，只有已
互相同意的设备能传字/收字（`RemoteTypingService`）。首次两台各弹一次「本地网络」授权。

## 已知问题

- **macOS 26 上，在微信窗口聚焦时切换输入法可能让微信崩溃**（崩在 Apple 的
  `TextInputUIMacHelper`／输入法切换 HUD，`*** CFRelease() called with NULL ***`）。
  这是 macOS／微信侧的上游问题，同样影响原生 Rime/Squirrel
  （[rime/squirrel#951](https://github.com/rime/squirrel/issues/951)）；RIMES 在其他 App 均正常。
  **规避**：不要在微信窗口聚焦时切换输入法——先在别处切好输入法，再点进微信打字。
