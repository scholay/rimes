# 日常统计与文章测速

## 两种时间，两个数据集

「统计」接收不含正文的日常输入计数：键盘分布、Rime 成文字数、并击批次与活跃时长。
旧 `stats/typing_speed.json` 和键频文件保持原格式、原历史；活跃时间仍按不超过 10 秒的
连续合格事件间隔累计。日常 CPM 不是考试成绩，也没有文章正确率。
原「统计」「打字测速」各自的记录开关迁移为「按键分布」「输入趋势」，不扩大旧采集选择。

「打字测速」是明确开始的原生文章输入区。第一枚有效输入动作启动单调时钟，末次提交
或手动结束冻结结果；组字、思考、纠错时间均包含。切换焦点、输入源或配置会标记为练习，
不参与有效成绩比较。重复同篇与首次尝试分开标记；重练本身不使成绩失效。
练习输入不进入日常统计，前后日常活跃会话也不跨越练习时间。

## 计分口径

- 字符按 Swift `Character` 计数，保留标点和英文空格；仅统一 CRLF/CR 为 LF。
- 有效速度 = 最终正确字符数 × 60 / 总秒数。中文显示字/分，英文以有效速度 / 5 显示 WPM。
- 原始速度 = 当前保留的成文字符数 × 60 / 总秒数，不等于所有历史击键或重打次数。
- 过程正确率 = 新提交字符中的正确尝试 / 全部字符尝试。删除旧错字不抹去该次错误。
- 最终字准 = 正确字符 / (正确字符 + 替换错误 + 漏字 + 多字)。结束前尚未到达的题文尾部
  不作为实时漏字；提前结束时计入漏字，并将成绩标为未完成。
- 文本采用有界编辑距离对齐，漏一字不导致后续全部错位。相同编辑距离优先保留更多精确匹配。
- 物理键数仅计实际 keyDown，不把长按自动重复当新按压；重复事件另记。纯修饰键、导航和
  Command/Control/Option 快捷键不计入击键。击键速度单位为键/秒。
- Backspace 操作分组字退格与成文退格；另记成文删除字符数及删除/替换操作数，不以退格推算字准。
- 并击拍数只接收 RIMES 已实际结算的批次，三键同拍是三键一拍。其他输入法没有可靠批次来源时
  显示不可用，不从下游文字或按键间隔猜测。码长 = 物理键数 / 当前成文字数。

无样本的正确率、不可得的拍数显示「—」，缺失日常速度在趋势中断线，不能冒充零速度。
曲线表达累计有效速度；中文批量上屏具有天然突发性，第一版不把它转成“稳定性”排名。
比较使用题目 ID/版本、语言、输入源、方案及键位快照，不混排不同文章或单位。

## 文库与隐私

内置六篇约 400–600 字的原创中文文章、两篇约 150–200 词的原创英文文章。
原文只读，支持选篇、随机和同篇重练。本轮不提供在线题库或正文上传。
练习正文、逐字符对齐和组字仅在本页内存中存在；持久化只包含题目 ID/版本、输入配置身份、
结果计数及有界聚合速度样本，不包含用户输入正文或逐键时间线。
输入使用原生 NSTextView/IME，marked text 不进入判分；粘贴、拖入和自动文本替换不能冒充手打。
键观察只绑定已开始测试的本进程首响应输入框，不安装全局键盘钩子、不读取外部应用文本。
每次输入上限为 2,048 个 `Character` / 16 KiB，计时上限 24 小时，曲线最多保留 120 个
聚合样本。历史受 500 条与 4 MiB 双重上限约束，容量不足时从最旧的成绩开始淘汰。

## 参考实现

数学口径独立实现，不复制第三方项目的键盘钩子或输入路由：

- [Monkeytype 输入统计](https://github.com/monkeytypegame/monkeytype/blob/91bd24bb8513785c7364cbea29296ff7adafac41/frontend/src/ts/test/events/stats.ts)：区分有效产出与过程准确率。其主 WPM 通常以完整正确词计分，本项目中文不照搬整词扣分。
- [Monkeytype IME 事件](https://github.com/monkeytypegame/monkeytype/blob/91bd24bb8513785c7364cbea29296ff7adafac41/frontend/src/ts/input/listeners/composition.ts)：开始组字计时，提交后判字。
- [keybr 步骤统计](https://github.com/aradzie/keybr.com/blob/541eb0a5f010ead7ce4c580c0bb0d5bb2519185c/packages/keybr-textinput/lib/stats.ts)：字符步骤速度与错误标记分离。
- [TypeType 计分属性](https://github.com/whynusn/typetype/blob/509ecd5dd7067f3628664c2cc51c97bd44a6a738/src/backend/models/entity/session_stat.py)：原始/有效速度、击键和码长。
- [州州成绩计算](https://github.com/lwl4613615/zhouzhou-typing/blob/e43bde9dc6c96a38db5a2d08a5b02bafbfd74f37/newgdq/Models/TypingSession.cs)：中文有效字速；“错一罚五”属特定规则，本轮不采用。

## 验证

Debug/Release 构建后运行 `typing-test-smoke`、`typing-test-ui-smoke`、
`typing-practice-telemetry-smoke`、`statistics-dashboard-smoke`、
`daily-metrics-migration-smoke`，并回归 `typing-speed-smoke`、`stats-smoke`、
`input-telemetry-smoke`、`plugin-platform-smoke` 与 `settings-routing-smoke`。
真实安装验收需要覆盖中文组字/候选选择、并击同拍/分拍、组字内退格、上屏回改、输入源与焦点切换。
