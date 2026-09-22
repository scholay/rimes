# Capsule

## 2026-09-22：轻量详情与卡片操作（当前）

- 底栏的每张卡片改用右上角 `⋯` 菜单，集中放置编辑、按类型迁移和删除，不再显示画笔。无合法目标的迁移项明确禁用，不把图片、PDF 或密码强行转换为文字。
- 「最近」的文字/链接迁移为笔记，图片为图片，PDF 文件为 PDF，视频文件为视频；多个文件逐个校验，全部保存成功（或已经存在）后才移除原历史卡片，部分失败保留来源。普通 `⌘S` 仍是收藏，不删除历史。
- 笔记可以显式迁移为 Password：先加密写入，再按原 revision 移除笔记；并发修改时拒绝覆盖并回滚新条目。操作前说明标题仍可检索，既有同步/备份中的明文副本无法收回。Password 不提供降级成明文笔记的迁移。
- 底栏 Password 卡片双击或回车即可原地输入现有四组物理并击口令；完成后只在卡片内显示正文，不打开管理页、不复制、不投递。错误口令不解密，口令槽位只显示进度。明文最多停留 15 秒，切卡片/分类、滚动、搜索、失焦、关闭、保护态、条目或口令变化立即遮蔽。
- 单条编辑/新建使用 460 × 400 pt 的紧凑详情窗，最小 360 × 300 pt，隐藏重复的分类、列表、搜索与同步控件。完整管理页仍由齿轮进入。分类旁的 `＋` 可直接新建当前类型。
- 新建密码直接填写标题和加密正文，不要求先验证一个尚不存在的密码；草稿只在内存中，失焦仍遮蔽。已有密码在详情表单内验证，不再叠加口令弹窗。现有查看口令、加密文件格式和 iCloud 排除规则不变。
- `capsule-interaction-smoke` 使用隔离存储和假剪贴板，覆盖卡片原地验证、错误口令零解密、保护/口令变更清理、创建与紧凑布局、菜单派发以及迁移的加密和并发边界；不读取真实密码。

Capsule 是与 Buffer、Mailbox 同级的 RIMES 本机内容库。当前支持 `Password`、`Skill`、`Note`、`Image` 与 `PDF` 五类条目（`Prompt`、`Memory`、`URL` 已下线，旧文件留在磁盘但不再列出），并在独立 Capsule 管理窗口中提供搜索和增删改查。Capsule 不属于 Buffer 插件目录，也不受 Buffer 插件启停、工作台生命周期或当前输入源控制。

## 本机数据

默认目录：

```text
~/Library/RIMES/
├── capsule/
│   ├── content-seed-v1
│   ├── content-library-v1.json
│   ├── entries/
│   │   └── <uuid>.md
│   ├── assets/
│   │   └── <sha256>.<ext>
│   ├── conflicts/
│   │   └── <uuid>/<timestamp>-<origin>-<uuid>.md
│   ├── master-key
│   └── passwords/
│       └── <uuid>.md
└── capsule-sync/
    ├── config-v1.json
    └── state-<library-id>.json
```

- `entries/*.md` 是 Obsidian 可直接读取和编辑的普通 Markdown，front matter 保存 `capsule` 类型、版本、UUID、标题和更新时间。正文保存 Prompt/Memory/Note 内容、HTTP(S) URL，或 Skill/Image/PDF 的绝对路径。
- 用户新建 Image/PDF 条目时，原始二进制仍位于用户管理的本机目录；从 iCloud 下载的媒体经 SHA-256 校验后按内容寻址 materialize 到 `capsule/assets/`。两者都不复制到仓库或应用包。编辑器只在选中条目后读取：图片通过 ImageIO 在后台生成最长边不超过 1600 px 的缩略图；PDF 通过 Core Graphics 在全局串行队列中只渲染第 1 页缩略图，并显示总页数，避免把整本大 PDF 交给输入法进程持续布局。迟到结果必须通过 generation、类型和路径复验后才能显示。
- 首次初始化会加入一条 Note：标题 `RIMES 默认词条`，正文 `RIMES`。`content-seed-v1` 保证只预设一次；用户删除后不会自动复活。
- `content-library-v1.json` 保存本机 Capsule 库 UUID。选择 iCloud 文件夹后，`capsule-sync/config-v1.json` 保存该文件夹的本机书签与库 UUID，`state-<library-id>.json` 保存逐条 revision、tombstone 与本机媒体 fingerprint；这些文件不保存 Password 明文、密文或 `master-key`。未设置同步时，相应文件或目录可以不存在。
- `passwords/*.md` 只暴露标题、UUID 和更新时间。网址、App、用户名、当前密码与曾用密码都位于 ChaCha20-Poly1305 密文块中。
- `capsule/`、`capsule-sync/` 及其子目录权限为 `0700`，主密钥、marker、配置、状态、资产与 Markdown 文档为 `0600`。这些数据都位于用户资料目录，不进入仓库。
- 当前开发版以同一 macOS 用户为信任边界；同用户权限下的恶意进程不在防护范围内。

## iCloud Drive 自动同步

Capsule 的本机目录始终是权威副本。用户在 Capsule 顶部选择一个真实的
iCloud Drive 文件夹后，RIMES 会在后台维护独立的 `v1` 镜像；不会移动或
软链接 `~/Library/RIMES/capsule`，也不会把整个目录直接复制到云端。
启动、窗口打开、本机条目变更、系统唤醒与低频定时检查都会触发一次逐条
reconcile，用户也可以手动点击「立即同步」。关闭同步只停止自动任务并保留
两端数据。

云端镜像按 UUID 保存普通 Markdown，并为删除写 tombstone；同时编辑产生的
败者版本进入 `conflicts/`，不会被静默覆盖。Image/PDF 会复制到按 SHA-256
寻址的 `assets/`，另一台设备下载并校验后落入本机 Capsule 资产缓存，再把
本机条目正文恢复为可预览的绝对路径。Skill 的正文是设备本地绝对路径；为
避免把本机目录结构泄露到 iCloud，同时避免在另一台 Mac 制造不可用绑定，
Skill 与 Password 一样只保留在本机，不进入镜像或同步状态。
`v1` 的 tombstone 是永久删除事实；已经消费删除的设备发现云端 tombstone
丢失或同步根被重建时会恢复它，避免长期离线设备把旧副本重新上传复活。

本机 Image/PDF 路径暂时离线、未挂载或不可读，而该条本轮需要上传时，只有
这个 UUID 进入 `deferred`；状态会显示等待本机媒体，其他条目继续同步。同步器
不会把暂时不可用当作删除，不会为它写 tombstone，也不会用空内容覆盖云端。
文件重新可读后，后续自动或手动同步会继续处理。

如果离线媒体的本机版本在并发或 tombstone 收敛中成为败者，同步器会先把
完整原始 Markdown 保存到私有 `capsule/conflicts/<uuid>/`，再覆盖或删除正式
entry；云端冲突区只保存不含绝对路径的脱敏摘要。若 iCloud 媒体本身仍是未
下载占位，这一个 UUID 会 deferred，其他文本与删除仍继续。已下载到
`capsule/assets/` 的托管缓存若意外丢失，则会从仍有效的云端 asset 自动恢复；
外部磁盘上的用户原文件离线时不会被擅自改写为缓存路径。

删除 Image/PDF 条目时，同步层只删除对应 entry 并写 tombstone；不会删除用户
管理的原始文件。为保证跨设备并发编辑、迟到设备和 `conflicts/` 的恢复安全，
本版本也不会自动回收已经上传的内容寻址 asset，或 `capsule/assets/` 中已经
materialize 的本机缓存，因此这些文件会继续留存。不要手工删除仍被有效 entry
或冲突副本引用的 asset；自动垃圾回收需要先具备跨设备可证明的全局引用信息，
不属于当前 `v1` 协议。

Password 与 Skill 当前明确不参加 iCloud 同步。`passwords/`、裸 `master-key`
和 Skill 的绝对路径均不进入同步扫描、状态文件、日志或云端目录；把前两者
一起上传会失去现有密文边界，而上传 Skill 会暴露本机目录结构。
未来只有在提供用户恢复短语包装密钥或正式签名的 iCloud Keychain 密钥传递后，
才能安全开启跨设备密码解锁。Note、Image 与 PDF 三类普通条目可以同步；
已退役的 Prompt、Memory、URL 条目留在盘上，不再列出也不参与同步。

当前本地开发签名没有 iCloud container entitlement，因此实现采用用户选择的
iCloud Drive 文件夹，不硬编码隐藏的 CloudDocs 路径。所选目录必须是普通、
非符号链接、可写且被 macOS 标记为 ubiquitous 的目录；未登录或未启用 iCloud
Drive 时，界面保持「iCloud Drive 不可用/未设置」，本机 CRUD 不受影响。

## 独立窗口

**2026-09-22 交互与口令隐私更新**：底栏密码卡片单击选择，双击、Return 或 `⌘1`–`⌘9` 在卡片内验证并查看，不复制、不上屏。单条编辑从 `⋯ → 编辑` 打开紧凑详情，现有密码在表单内验证，新密码直接填写。后台设置仅显示默认／自定义状态，不展示口令内容；验证、设置和二次确认期间，正在按下与已完成的槽位都只显示圆点，包含辅助功能信息。现有口令与加盐摘要不变，修改或恢复默认仍须先验证当前口令。物理并击验证、成功查看和再次隐藏均使用临时密码库回归。

- 安装后的 one-shot Aqua 登录任务会在后台启动同一个 RIMES 进程，因此 Capsule 底栏的全局快捷键可在任意当前输入法下使用；管理窗口从底栏齿轮或卡片画笔打开，外观是底栏向上长高，齿轮、Esc 或「最近」标签返回底栏。在「设置 → Capsule」配置收录、自动粘贴、查看口令、iCloud、目录与底栏快捷键。设置页只显示配置和状态，不嵌入搜索、条目列表或编辑器。开发安装原子发布当前用户的登录任务；系统包在替换 payload **之前**审计全部本机普通账户，只有当前 GUI 用户可留下经验证且能由 postinstall 退休的开发版 App/任务，其他账户存在冲突或 home 无法安全核验时直接 fail-closed。postinstall 退休当前用户开发版并再次全量审计后，才事务发布系统登录任务；登录时发现后来出现的开发版痕迹只作为防御性短路。两种任务都不设 `KeepAlive`，也不启动第二份 UI/IME 服务。
- 窗口按八类内容搜索，并提供新增、查看、修改和删除。它是正常取得键盘焦点的 AppKit key window，不是 Buffer，也不是上屏目标。
- Prompt、Memory 与 Note 编辑 Markdown 正文；URL 保存完整 HTTP(S) 地址；Skill 保存本机文件或文件夹的绝对路径；Image/PDF 保存普通、非符号链接文件的绝对路径并提供内嵌预览；Password 编辑网址、App、用户名、当前密码与曾用密码。
- Image 的「复制图片」会把原格式图像表示、至少一种最长边不超过 4096 px 的 PNG/TIFF 兼容表示与原文件 URL 写入同一个系统剪贴板条目；复制前先限制源文件大小、像素数和单边尺寸，避免恶意或异常图片耗尽输入法进程内存。PDF 的「复制文件」与 Skill 的「复制文件/文件夹」写入本机 file URL。复制只更新剪贴板，不合成 `Command+V`、Paste、右键菜单或 Accessibility 事件。左侧列表、媒体预览和底部操作区使用弹性宽高，在窄窗口和较小高度下仍保留滚动与操作按钮；紧凑宽度隐藏的 iCloud 状态仍可从同步按钮的提示与辅助功能帮助读取。
- Password 列表只显示标题与固定长度掩码；网址、App、用户名始终使用安全文本控件。点击「查看明文」后必须先按顺序完成四组原生物理字母键并击，四个槽位逐组显示输入进度；每组以原生 `keyDown`/`keyUp` 的物理键码集合匹配，整组按键全部松开才结算，既不经过文字输入或当前输入法组字，也不接受 Command/Control/Option/Function 等修饰键。默认四组口令为 `RH / WO / CVN / QU`。设置自定义口令时要先验证当前口令，再连续输入并确认新的四组；恢复默认也要先验证当前口令。自定义原码不会落盘、记录日志或同步，只在一个本机 UserDefaults 凭据中保存版本、随机盐和 SHA-256 摘要；iCloud 镜像不包含该凭据。验证成功后当前密码与曾用密码最多显示 15 秒，随后自动恢复掩码；窗口失焦、应用失活、锁屏/睡眠/会话退出，以及切换条目或类型、新建、保存、删除、重载和关闭都会立即隐藏。明文视图不可选择、不可复制，也不会写入日志、tooltip、辅助功能标签或 UserDefaults。
- 未保存草稿在切换条目、类型、页面或关闭窗口前会要求确认；保存与删除携带已加载文件的 SHA-256 revision，并在 Store 文件锁内比较，另一窗口或 CLI 已更新时拒绝覆盖。直接在 Obsidian 修改普通 Markdown 后，旧窗口也必须重新载入才能保存。
- 当前独立管理窗口只负责内容管理，不直接向外部输入框上屏。它不会主动切换当前输入源，不注入按键或 Accessibility 事件，也不读取、提交或取消外部输入法的组字。原先依附 Buffer workspace 的 Capsule 搜索、保护投递和并击拦截已经移除，因此 Capsule 不参与普通输入按键路径。后续若增加独立上屏，应采用 Capsule 自己的非激活快速面板和外部焦点授权协议，不能重新依附 Buffer，也不能退化为剪贴板或 Accessibility 注入。

## 底栏

`⌘⇧V` 的 Capsule 底栏在「最近」（本机剪贴板历史）之外，为每类条目提供一个标签。条目按更新时间倒序显示；Return、双击或 `⌘1`–`⌘9` 把笔记正文直接放入目标输入框，图片、PDF、视频与技能以文件表示写入剪贴板后自动粘贴，`⌘C` 只复制。密码卡片默认只显示标题与固定掩码，验证后短暂原地查看，始终不能从底栏上屏或复制。每张卡片右上角 `⋯` 提供编辑、合法的类型迁移和删除；头部齿轮打开完整管理窗口，`＋` 新建当前分类条目。在「最近」中按 `⌘S` 仍是收藏并保留来源；菜单「迁移」则在整张卡片全部保存成功后移除历史来源。文本与链接成为笔记，图片、PDF、视频按文件类型归类；没有文件的图片数据按 SHA-256 写入 `capsule/assets/`。相同正文或路径不会重复收藏。底栏保持一排卡片和一行提示，高度 208 pt；预览与回归使用相同尺寸，提示下方不留空白行。

## CLI 管理

CLI 在 AppKit/IMK 启动前运行。普通条目示例：

```bash
printf '%s' '{
  "type": "note",
  "title": "项目事实",
  "content": "Capsule 条目使用 Markdown 管理。"
}' | RimeBuffer capsule entry put

RimeBuffer capsule entry list
RimeBuffer capsule entry path
RimeBuffer capsule entry seed
RimeBuffer capsule entry remove <uuid>
```

`entry list` 只输出 UUID、类型、标题和更新时间，不输出正文。`Skill` 的 `content` 必须是文件或文件夹的绝对路径。

密码从标准输入读取 JSON，避免出现在进程参数中；CLI 没有输出明文密码的命令：

```bash
printf '%s' '{
  "title": "示例站点",
  "url": "https://example.invalid/login",
  "app": "Browser",
  "username": "example-user",
  "password": "replace-with-local-secret",
  "previousPasswords": []
}' | RimeBuffer capsule password put

RimeBuffer capsule password list
RimeBuffer capsule password audit
RimeBuffer capsule password path
RimeBuffer capsule password remove <uuid>
```

批量导入从标准输入读取 JSON 数组，并按完整记录在内存去重。读取已有记录、去重和写入处于 Store 的同一次跨进程文件锁内，因此两个导入进程同时运行也不会写出相同记录。输出只包含 aggregate 计数，不包含标题、正文或密码；中断后可安全重跑：

```bash
trusted-content-emitter | RimeBuffer capsule entry import
trusted-password-emitter | RimeBuffer capsule password import
RimeBuffer capsule entry audit-media
```

更新条目时，在对应 `put` JSON 中加入已有 `id`。

## 验证

```bash
.build/debug/RimeBuffer capsule-smoke
.build/debug/RimeBuffer capsule-window-smoke
.build/debug/RimeBuffer capsule-sync-smoke
```

Smoke 使用临时目录、具名临时剪贴板和测试凭据，覆盖默认词条的一次性预设、八类 Markdown/密文往返、独立窗口 CRUD、窄宽/较小高度布局、真实 PNG/PDF 解码、Image 原格式与有界兼容表示复制、PDF/Skill 文件与文件夹的 file URL 复制、复制失败不清空既有剪贴板、缺失/符号链接媒体拒绝、URL 列表脱敏、并发 revision 规则、目录/文件权限、四槽物理键码映射、默认/自定义口令匹配、单凭据摘要存储、当前口令先验门禁、密码明文 15 秒边界、加解密、标题篡改拒绝和固定脱敏。同步 smoke 以两个隔离的本机目录和一个 fake cloud root 模拟跨设备，验证媒体资产、离线媒体 deferred/recovery、共享与最终引用删除后的保守 asset/cache 留存、冲突、tombstone、幂等同步，以及 `master-key`/Password/查看口令凭据永不进入镜像。测试不会读写用户真实 Capsule、通用系统剪贴板或 iCloud 目录。
