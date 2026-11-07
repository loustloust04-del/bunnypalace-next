# plan · 记忆 ABC（第三版 · 10-15 拍板后）

⚠️ DON'T IMPLEMENT YET —— 等粟粟批注（⧫）和 go。

> 规格 = `~/Desktop/cc-rp/记忆系统/记忆系统v5.md`，冲突按它。另据：粟粟 10-15 的回答（第〇节，原话照录）、她拖好的小样顺序、易用性审查（scratchpad `memory-ux-review.md`）。app 里不做拖动排序。行号 = backend-2 当前文件。`{助手}` 代码里取楼层变量。

## 一句话

框架（记什么 / 怎么管 / 注入 / 检索）留着；顶上放总开关、起始日、提取模型、写入预算、复杂度；「写入 · 记什么」按编号一行一个，点进去是这一项的全部设置；注入里【开窗口】按编号勾；新加一个记忆日志页。画像（做梦聚合）下线。另：C2 严格 JSON、待续三态（v5「先12」）。挪走的东西老地方不留。**默认设置下请求体一字不变**，例外：待续工具多一个；她自己开着画像注入的话画像段没了。

## 〇、粟粟 10-15 拍板

原话：
> 预算直接复用全局预算好不，现在我都不能输入一个数字！｜1，按推荐但是改为12小时，现在半小时就算结束太短了。2现在不做3勾4不算，「用户画像 · 做梦聚合」这玩意现在没用，可以死了，b3先不做。5按v5设置剩下都按推荐，本机模型让用户下啊。｜10能用

| # | 定了 |
|---|---|
| 1 | A3 每次收尾都重压。「静默多久算这个窗口聊完」从 30 分钟改成 **12 小时**（第六节） |
| 2 | B4 图数据库现在不做；现有 remember 挂 B4 |
| 3 | 「勾」= 【开窗口】按设置里的勾走、每一轮都生效。追问后原话：「到时候也可以开窗口带一个sheet（纸条），自己选吧」→ 设置里的勾是默认；以后新开窗口可以弹一张「纸条」，这个窗口带什么当场选。**纸条不进本单**：要加新窗口弹层 + 每个对话存自己那份（SwiftData 新字段）+ 注入读它，不算小活，记为以后 |
| 4 | 「用户画像 · 做梦聚合」不是 B3，整个下线（第十节）；B3 先不做，标「还没做」 |
| 5 | 写入十行按 v5 单开一节「写入 · 记什么」 |
| 6–9 | 按推荐：滑条只动写入开关；A3 不进【开窗口】；C2 本机没装时这一轮退到提取模型，**并让用户下本机模型**（C2 页下载入口 + 一次性提示）；状态卡见第二节（她的小样里状态卡还在，Q9「删」作废） |
| 10 | 写入预算超了，手动「现在写」照样能写 |
| 预算 | 追问后原话：「控件一样，单独」→ 单独一份、只管后台写手；控件和全局预算一样（直接输美元数、已用、进度条、重置已用），另加周期 关闭 / 周 / 日（第四节） |

## 一、先做的两个小修（可以先合）

**1. 红字**（`MemorySettingsPage.swift:20-29`、记忆 app 首屏 `MemoryPanelView.swift:1095-1103`）
- 病因：红只看 `failStreak ≥ 3`（`MemoryService.swift:1391`），不看总开关。关着就没有写成功，计数不清零，一直红。
- 漏洞：`compress` 不查开关，补跑闭包（`SessionCloseout.swift:136-139`）关了以后还会跑、还会记失败。
- 修：总开关关 / 这一项关 → 灰字「关着，没在写」，不红，计数不清；`compress` 开头查开关；红的那行可点，展开原因（`lastErrorMessage`）/ 连续几次 / 模型 / 时间（早就存了，`MemoryService.swift:1384-1392`）。日志页做好后（F 组）改成点了跳日志。

**2. 总开关两份不同步**
- 开关读 `PermissionCenter.level(.memory)`（`MemoryPageContent.swift:98`），`setLevel` 顺手写 `mem_master`（`PermissionCenter.swift:258-262`）。
- 设置导入把 `mem_master`、`perm.memory` 各写各的（`ConfigImporter.swift:88-103`、`ConfigSchema.swift:71`、`:162`）→ 可能显示开、实际关。
- 修：导入完以 `perm.memory` 为准再 `setLevel`；只有 `mem_master` 时按它。

## 二、设置 → 记忆 主页（她拖好的顺序）

图例：**不动** / **新** / **挪**（从哪来）/ **删**。副标题 ≤12 字。390 宽右边只放开关，模型写在副标题后面。

**状态卡**（最上面，iOS 原样：几行平铺，不加分隔线、不加 ›）
- 行：记新东西（C2）/ 写上下文摘要（A2）/ 写窗口总结（A3）/ 写时间轴（A4）。「写画像」那行删（画像下线）。
- 右上角 ⓘ → 记忆日志页（第十一节）。每一行点了 → 日志里这一项最近那条。
- 位置：iOS 设置页 `MemorySettingsPage.swift:352`、记忆 app「设置」格 `MemoryPanelView.swift:476-479`；「记忆系统说明」卡不动。

**顶上（不带节标题）**

| 行 | 副标题 | 控件 | |
|---|---|---|---|
| 记忆系统总开关 | 原文 | 开关 | 不动 `:97-111` |
| 记忆从哪天开始 / 从这天开始 | 原文 | 开关 / 日期 | 不动 `:113-129` |
| 提取模型 | 各项没单选就用它 | 菜单 | 挪：原「提取」节 `:149-189`，副文案改短 |
| 写入预算 | 后台写记忆的钱 | 「$0.42 / $5 · 每周 ›」 | 新（第四节） |
| 复杂度 | 动态：「中 · 开 5 项」 | 滑条 0 / 轻 / 中 / 重；改过单项显示「自定义」 | 新（第五节） |

**写入 · 记什么**（一个编号一行，整行点进二级页；总开关关着整组灰）

| 行 | 副标题 | 控件 | 从哪来 |
|---|---|---|---|
| A2 上下文摘要 | 挤出视野的一段段记 | 开关 | 挪：注入节 `:317`（拆开，见第十二节） |
| A3 窗口总结 | 一个窗口压成300字 | 开关 | 同上拆出 |
| A4 时间轴 | 每窗每天一条 | 开关 | 挪：注入节 `:319` |
| B1 心声 | {助手}的独白 | 开关 | 挪：感知节 `:132` |
| B2 {助手}日记 | 还没做 | 无（灰） | 新 |
| B3 {助手}做梦 | 还没做 | 无（灰） | 新（不是原画像那个） |
| B4 {助手}的记忆 | {助手}自己记的 | 开关 | 新开关（今天跟总开关走） |
| C 档案 | 「412 条」 | 无开关 › | 挪：整理节统计 `:304-308` |
| C2 碎片池 | 后台记下关于你的事 | 开关 | 挪：感知节「从聊天里记住的」`:130` |
| C3 整理编目 | 还没做 | 无（灰） | 新 |

**整理 · 怎么管**：待续 ›（新，第八节）/ 整理记忆…（不动 `:265-279`）/ 已删除（不动 `:283-302`）。画像入口 `:245-263`、做梦开关 `:233` **删**。

**注入 · 塞什么进 prompt**：开窗口带什么 ›（新，二级页，第三节）/ 目录式注入 / 想起来了 / 召回反馈 / 注入预算（不动 `:321-340`）。画像注入 `:316` **删**。

**检索 · 怎么挑记忆**：整节不动（`:353-387`）。

**删掉的节**：「感知」标题（行都挪走了）、「提取 · 怎么记」（模型挪顶上，提示词 / 间隔进 C2 页）、两节「高级」（`:394-414`，行进 B4 页和【开窗口】）。

### 编号二级页（同一个模板）

从上到下：开关（和列表行同一个键）→ 状态（上次写成 · 时间；红时原因 / 连续几次 / 模型，点了跳日志）→ 模型（跟提取模型 / 单选）→ 各自的行 → 本期花费。

| 页 | 各自的行 |
|---|---|
| A2 | 什么时候写：每 N 回合（默认 5，= 今天 `ctx_compress_interval`）/ 停 N 分钟 / 只手动；CC 一行说明「满 60 条或跨过 05:00」；尾段一行说明「每次收尾整段重写」 |
| A3 | 什么时候写：停 N 分钟（**默认 720 = 12 小时**，≥60 显示成小时）/ 每 N 回合 / 只手动；新建对话时先写掉最近聊过的（第六节 Q-b）；约多少字（默认 300） |
| A4 | 同 A3（各管各的，默认也是 12 小时） |
| B1 | 模型只读「跟对话的模型」；心声进聊天流（挪自 `:134-136`）；花费写「不算写入预算」 |
| B4 | N 条 ›；自己主动记的每日上限、每条正文上限（挪自 `:396`、`:398`）；灰行「图数据库 · 联想召回 · 还没做」 |
| C | 只有「N 条 ›」（看 / 搜） |
| C2 | 提取间隔、提示词 ›（挪自 `:191-221`）；本周拒收 N 次 ›；模型默认「本机」；**本机模型没下：一行「下载本机模型（x GB）」**，复用 `LocalModelsSections.swift:66-101` 那一行（下载 / 暂停 / 继续 / 用流量） |
| 写入预算 | 第四节 |

页脚（A2 / A3 / A4）：「对话 ⋯ 里的『现在写』立刻写这个窗口」。

## 三、【开窗口】（注入节的二级页「开窗口带什么 ›」）

按编号一行一勾，数量在这一行下面（勾开着才出现），编号页里不再放一份。按勾走，**对所有窗口每一轮生效**（Q3 已定）。以后：新开窗口弹「纸条」当场选，不在本单。

| 行 | 默认 | 数量 | 代码 | 键 |
|---|---|---|---|---|
| A2 上下文摘要 | 开 | 带全文的最近几段 2（挪自 `:407`） | `ConversationViewModel.swift:2384-2393`；历史窗口锚定 `:2802` 也跟它 | 新 `mem_open_a2`，没写过 = 读 `mem_content_summary` |
| A4 时间轴 | 开 | 最多几条 8 / 往回几天 7（挪自 `:408-409`）；待续只带「没做完」（规则） | `CalendarInjection.swift:71-81`、`TimelineStore.swift:157-207` | 新 `mem_open_a4`，没写过 = 读 `mem_content_timeline` |
| B4 {助手}的记忆 | 开 | 带全文的最近几条 5、最多占注入预算 100%（挪自 `:395`、`:397`） | `MemoryService.swift:697-704` | 新 `mem_open_b4` |
| C 档案 | 开 | 「按『检索』挑」 | `MemoryService.swift:692-696`、`PromptAssembler.swift:670-690` | 新 `mem_open_c` |
| 目录 | — | 灰「还没做」（v4-2 做好再开） | — | — |

- 带不带 = 总开关 && 这一勾 && 对话记忆开关（照今天）；写不写只看写入那一行。
- 新键没写过时取今天的值 → 默认下各段逐字和今天一样。A3 不注入、B1 是工具，都不列。

## 四、写入预算

- 管谁：后台写手 A2 A3 A4 C2，以后 C3。B1 / B4 是{助手}本人调工具，不算。本机模型记 $0。
- 控件：复用全局预算那套（`APISettingsTab.swift:601-` `BudgetSection`：开关 + **直接输数字** + 已用 + 进度条 + 重置已用 + 保存），加周期 **关闭 / 周 / 日**（关闭 = 不限，默认 = 今天的行为）。
- 全局总闸今天**没有周期**，是「从上次重置已用起累计」（`GlobalBudgetStore.swift:37-38`）。所以要把 `BudgetSection` 改成能接不同的账（全局一份、写入一份），写入这份另加周期。
- 已花 = 账本里本期这几类用途相加（照 `GlobalBudgetStore.ledgerSpentUSD`，`:120-133`），不另记。
- 超了：**停**。后台写手跳过，不算失败、不变红；状态卡对应行灰字「写入预算用完，下周一再写」。手动「现在写」不看写入预算（Q10），全局总闸照查。
- 查的位置：`SessionSegmentWriter` 预算闸那一步（`:178-190`）；先查写入预算，再查全局。
- 分得出谁花的：A2/A3/A4 今天都记 `.summary`（`UsageLedger.swift:5`、`SessionSegmentWriter.swift:191`）→ 加 `windowSummary`；A4 用 `.timeline`（标签「日记」改「时间轴」）；C2 用 `.memory`（标签改「碎片池」）。

## 五、复杂度滑条

不存值：位置由写入开关算出来；拖一档 = 改一组开关；对不上显示「自定义」。只动写入开关。

| 档 | 开着 |
|---|---|
| 0 | A2（长窗口不丢前文） |
| 轻 | A2 A4 |
| **中（= 今天新装的默认）** | A2 A3 A4 B4 C2 |
| 重 | 写入全开：+ B1（B2 / B3 / C3 / 图数据库做好后也进这一档） |

## 六、A 线（Q1 已定）

- **12 小时**：`SessionCloseout.idleInterval`（`SessionCloseout.swift:11`，30 分钟）是「静默多久算聊完」，用在 `queueState`（`:373-376`）和巡检（`:398`）。**A3、A4 共用这个钟**（同一次收尾两个调用）；**A2 不共用**（API 按回合、CC 按 60 条 / 05:00）。A7 触发拆开后它变成 A3 / A4 各自「停 N 分钟」的默认值 720。
- 连带：`recentInterval`（`:13`，2 小时）是「新建对话时先写掉多久内聊过的」。静默改成 12 小时后，2–12 小时前聊过的窗口要等满 12 小时，新窗口里时间轴就缺它。推荐一起改成 12 小时（Q-b）。
- **D1 A2 收下尾段**：尾段存进 A2，每次收尾整段重写，被正式压缩后换成正式段。注入仍只带压缩段和第 0 段（`ConversationViewModel.swift:2385`）→ 请求体不变。
- **D2 A3 真·再压**：每次收尾都读这个窗口的 A2 全部段 + 尾段，重压约 300 字（`SessionCloseout.swift:490-511` 换提示词）。A3 只给 recall → 请求体不变。

## 七、C2：小小模型填严格 JSON（v5 §3-1）

- 只看称呼 + 这一截消息（`[3]` 编号），**不带主提示词**。
- 只交 `{"fragments":[…]}`：`msg`（第几条，程序换成出处 + 发生日）/ `content`（≤120 字）/ `tags`（≤5）/ `importance`（1–5）/ `emotion`（-2…2）/ `resolved`（可 null）= Scarlett 脱水各字段；另留 `category`（常驻层靠它）。
- 严格：`Decodable`；整包正好一个 JSON 对象，只容一层 ```json 围栏。不合格重来一次，再不合格整包拒收、不落库、记日志；单张不合格只扔那张，记拒收数。只加不改不删，一字不差的不加。
- 落库：`Memory` 表新行（`Memory.swift:16-51`），加可选字段 `occurredDay / importance / emotion / resolved`。
- 换掉今天的提取（`ConversationViewModel.swift:4642-4790`、`MemoryService.swift:1077-1376`），同一提交删旧代码和只测它的单测。
- 模型：默认本机，走 `LocalLLMService` 不走 `ProviderRouter`（`ChatService.swift:2245-2249`）。本机没装 / 在后台 → 这一轮用提取模型，日志写清用了谁；第一次碰到没装时弹一次提示「C2 默认用本机模型，去下载 ›」（跳 C2 页下载那行，只弹一次）。半成品 `scratchpad/v42-parked/FactModelRoute.swift` 能用；`FactPoolExtractor.swift` 解析要重写。
- 触发：API 每 N 轮（`mem_extract_interval` 默认 3）；CC 每满 6 条新消息。

## 八、待续三态（v5 §3-2）

- 单独存 `memory/pending/待续.md`，一条一行（`id / state / conv / day / anchor`），状态 没做完 / 淡了 / 做完了。今天是时间轴条目里的一段字（`TimelineStore.swift:11`、`:264-285`）。
- A4 写手只**加**新的，不再「做完的删掉」（`TimelineWriter.swift:18-46`、`SessionCloseout.swift:611-620`）。
- {助手}的工具 `pending_notes`：`list` / `done` / `faded`；门 = 总开关 && A4 开；工具抽屉加一行（`ToolDrawerCatalog.swift:72` 一带）。
- 注入只带「没做完」，格式不变 `（待续：a；b）`（`TimelineStore.swift:184-207` 换来源）；没迁移的楼层照读老字段（金样走这条）。
- 能看能改：设置「整理 · 怎么管 › 待续」列表（左滑改三态、能改字），记忆 app 时间轴格顶上同一份（`MemoryTimelineView.swift:300`、`:335`、`:456`）；recall 换来源（`RecallTool.swift:201-210`）。
- 迁移：每个窗口只拆最新一条条目里的待续 → 没做完；条目文件不动；只跑一次。

## 九、对话 ⋯「现在写」

加在 ⋯ 菜单「窗口总结」「上下文摘要」旁边（`ContentView.swift:1200-1208`）：这个窗口开着的 A2 / A3 / A4 立刻写一遍（A2 = 已有手动压缩 `ConversationViewModel.swift:4824-4855`；A3 / A4 = 跑一次收尾，不等静默、不看冷却）。不看写入预算（Q10）。写完提示「写好了：A2 1 段 · A4 1 条」。只有总开关关时灰掉。

## 十、画像下线（Q4）

数据不动（画像文件、`mem_*_profile` 键都留着），只停写、停注入、藏界面：
- 停写：`dreamIfNeeded` 调用和函数（`ConversationViewModel.swift:4043`、`:4927-4960`）、`DreamConsolidator`（`DreamConsolidator.swift:49-60`、`:159`）。做梦顺带的「毕业」（消费碎片标失效）一起停。
- 停注入：`[用户画像]`（`ConversationViewModel.swift:2395`、`MemoryService.swift:358-366`、`PromptAssembler.swift:399`、`:570`）。
- 藏界面：设置页做梦开关 / 画像入口 / 画像注入（`MemoryPageContent.swift:233`、`:245-263`、`:316`、`:73-75`）；记忆 app 首屏画像卡（`MemoryPanelView.swift:269`、`:1029`）；`MemoryOrganizeSheet.swift:56-59` 的「顺手开画像」；`LiteMemoryPage.swift:100`；状态卡「写画像」行和首屏提醒 `.dream`（`MemorySettingsPage.swift:19`、`MemoryPanelView.swift:1098`）；做梦提示词路由（`SettingsRoute.swift:6`、`MacSettingsPage.swift:36`、`:57`）。
- 旧提取的提示词今天读画像（`ConversationViewModel.swift:4679`），C2 上线后跟着没了。

## 十一、记忆日志（新）

- 一次后台写一条：时间 / 编号 / 成了 · 没成 / 原因 / 模型 / 花了多少。按时间倒序；顶上能按编号筛。
- 入口：状态卡右上 ⓘ；状态卡每一行点了跳到这一项最近一条；编号页的状态行同样。
- 记在哪：`MemoryHealthStore.recordOK / recordError`（`MemoryService.swift:1398-1411`）是 A2 / A3 / A4 / C2 成败的唯一出口，在这里顺手追加一条；钱从这次调用记账的那笔取。
- 存：楼层下 `memory/log/写入日志.jsonl`，只追加，保留 30 天或 1000 条（先到先删）。不放 UserDefaults（3.8MB 卡顿的教训）。读盘只在打开日志页时。

## 十二、编号 ↔ 代码

| 编号 | 写手 / 触发 | 写的开关：今天 → 改成 | 状态 |
|---|---|---|---|
| A2 | `compress`（API 窗外满 N 轮，`ConversationViewModel.swift:4802-4821`）/ `compressCC`（`SessionCloseout.swift:238-278`）→ `memory/sessions/` | `mem_content_summary` 管 A2+A3 写、注入、锚定（`MemoryService.swift:387-389`）→ 只管 A2 写 | 有；尾段要改（D1） |
| A3 | 收尾（静默 → 12 小时 / 新建对话，`SessionCloseout.swift:11-13`、`:490-511`）→ `memory/windows/` | 新 `mem_write_a3`（没写过 = 读老键） | 有；今天是抄本（D2） |
| A4 | 收尾第二个调用 `TimelineWriter`（`:513-525`）→ `memory/timeline/` | `mem_content_timeline` 管写 + 注入 → 只管写 | 有 |
| B1 | `inner_voice` 工具，主模型（`ConversationViewModel.swift:4298-4330`） | `mem_content_heartvoice` 原键 | 有 |
| B2 / B3 | — | — | **还没做**（原画像不算 B3，下线） |
| B4 | remember / edit / forget（`ToolRegistry.swift:44`、`ToolDrawerCatalog.swift:72-74`）→ `memory/self/` | 跟总开关 → 新 `mem_write_b4` 默认开，关 = 不给这三个工具 | 有；图数据库**还没做** |
| C | 今天的提取写进 SwiftData `Memory` | 无 | 有 |
| C2 | — | `mem_content_facts` 原键（`MemoryService.swift:404-405`） | **还没做**（第七节） |
| C3 | — | — | **还没做**（v5：以后） |

## 十三、还要粟粟确认（推荐在前，一句一个）

- ~~a. 写入预算单独还是全局~~ 已定：「控件一样，单独」（第〇节）
- b. 新建对话时「先写掉多久内聊过的」：**改 12 小时**（粟粟 10-15「12」）
- ~~c. Q3「勾」~~ 已定：勾是默认，以后加「纸条」（第〇节）

## 十四、请求体 / 金样

| 改动 | 请求体 | 金样 |
|---|---|---|
| 小修、页面、编号页、滑条、预算、触发、现在写、日志、12 小时 | 不变 | G1–G6、G8 原样过 |
| 【开窗口】拆键 | 默认 = 今天，逐字不变 | 原样过 + `OpenWindowInjectionTests` |
| B4 开关、C2 换掉提取、A2 尾段、A3 再压、待续存法 | 默认不变 | 原样过 |
| 画像下线 | 默认关，不变；**她开着的话 `[用户画像]` 段没了** | 金样没开画像，原样过；`MainThreadIOBudgetTests`（`:24`、`:106`）要改 |
| **`pending_notes` 工具** | **tools 多一个** | **重录 G1–G6、G8 tools 段 + 工具 schema 金样；diff 只许多这一个** |

## 十五、测试

scheme `MemoryPalaceTests`，grep 到对应 Test Suite passed；内存库 + 测试楼层；模型一律假 caller。
- 补：`MemoryHealthWarningTests`（关着不红）、`SessionCloseoutQueueTests`（关着 compress 不跑；静默 12 小时才到点）、导入同步总开关
- 新：`SettingsSkeletonTests`（节标题和顺序；挪走的行老位置没有）、`OpenWindowInjectionTests`、`MemoryComplexityTests`、`WriteBudgetTests`（输数字、周 / 日、超了停、现在写不受限）、`WriterTriggerTests`、`WriterModelRouteTests`、`FragmentPoolTests`、`PendingStoreTests`、`PendingInjectionTests`、`PendingToolTests`、`TimelineWriterPendingTests`、`WindowSummaryRecompressTests`、`MemoryWriteLogTests`（成败都记、30 天 / 1000 条、跳转）、`ProfileRetiredTests`（不写、不注、文件还在）
- 改 / 删：旧提取那几套、`ProfileInjectionFlagTests`、`SettingsSearchTests`、`TimelineWriterTests`、`MainThreadIOBudgetTests`
- 必须原样绿：记忆核心套件、`PromptRealPathGoldenTests`（除工具重录）、`InspectorRealPathTests`

## 十六、执行清单（一项一个 commit，可单独撤回；不 push）

**0 · 小修（先合）**
- [x] ✅ 0.1 红字：关着灰字、`compress` 查开关、红时可点看原因
- [x] ✅ 0.2 导入后总开关两份对齐

**A · 页面（不改请求体）**
- [x] ✅ A1 `SettingsSkeletonTests` 先写，按她的顺序锁节
- [x] ✅ A2 改排：状态卡 → 顶上六行（提取模型挪上来）→ 写入 · 记什么 → 整理 → 注入 → 检索；「感知」「提取」标题删
- [x] ✅ A3 写入十行（只显示 + 开关；老位置的开关同提交删）
- [x] ✅ A4 A2 / A3 开关拆开（`mem_write_a3`）
- [x] ✅ A5 B4 开关（`mem_write_b4`）
- [x] ✅ A6 编号二级页（`SettingsRoute` 加 case，mac `MacSettingsPage` 补）+ 状态；高级两节的行挪进来，老节删
- [x] ✅ A7 每项单选模型
- [x] ✅ A8 触发三选一（A2 / A3 / A4 各一套）+ 静默默认 12 小时（`idleInterval` 与 `recentInterval` 都改 12 小时）
- [x] ✅ A9 对话 ⋯「现在写」（不看写入预算）
- [x] ✅ A10 【开窗口】二级页：新键 + 数量挪过来；锚定跟 `mem_open_a2`
- [x] ✅ A11 用途拆分（`windowSummary`、标签改字）
- [x] ✅ A12 `BudgetSection` 改成能接不同的账（全局界面不变）
- [x] ✅ A13 写入预算：输数字 + 关闭 / 周 / 日 + 超了停
- [x] ✅ A14 复杂度滑条
- [x] ✅ A15 设置搜索 + `ConfigSchema` 登记新键

**F · 日志**
- [x] ✅ F1 日志存储 + 在 `recordOK / recordError` 追加（带花费）
- [x] ✅ F2 日志页 + 状态卡 ⓘ + 每行跳到这一项最近一条（替掉 0.1 的展开）

**G · 画像下线**
- [x] ✅ G1 停写（做梦调用、毕业）
- [x] ✅ G2 停注入（`[用户画像]`）+ 改 `MainThreadIOBudgetTests`
- [x] ✅ G3 藏界面（设置三处、记忆 app 首屏卡、整理弹层、Lite 页、状态卡行、做梦提示词路由）

**B · C2**
- [x] ✅ B1 `Memory` 加可选字段
- [x] ✅ B2 C2 模型路线（默认本机，没装退提取模型）
- [x] ✅ B3 C2 页本机模型下载行 + 一次性提示
- [x] ✅ B4 C2 写手 + 换掉旧提取 + 删旧代码和单测；「记忆系统说明」提取那句改字
- [x] ✅ B5 CC 窗口触发
- [x] ✅ B6 C2 页拒收数

**C · 待续**
- [x] ✅ C1 `PendingStore` + 迁移（只跑一次）
- [x] ✅ C2 A4 只加
- [x] ✅ C3 注入 / recall / 记忆 app 换来源（带兜底）
- [x] ✅ C4 `pending_notes` 工具 + 金样重录
- [x] ✅ C5 设置「整理 › 待续」列表 + 记忆 app 同一份：三态、改字

**D · A 线**
- [x] ✅ D1 A2 收下尾段
- [x] ✅ D2 A3 每次收尾真·再压 300 字

**E · 收尾**
- [x] ✅ E1 全部测试 + 双端 build-for-testing（只认 `TEST BUILD SUCCEEDED`）交集成区
- [x] ✅ E2 复盘 `docs/review-memory-abc.md`、`docs/now/backend-2.md`、说明书同步（画像那页改「已下线」）
- [x] ✅ E3 验收单（人话、只用编号；第一步：先把总开关打开）

## 十七、未查证

- 本机 4B / 1.7B 守不守得住这张 JSON 表（没跑过）；`LocalLLMService` 能不能按 JSON 约束解码（没查）。
- 日志里「花了多少」：`modelCaller` 记账后能不能把这一笔交回给写手（C2 那条路更没看）。
- 静默改 12 小时后，跨过 05:00 的窗口时间轴记到哪一天：没核 `TimelineWriter` 的日界。
- 设置搜索能不能直接推进二级页：没查。
- `GlobalBackup` / `SyncEngine` 导出 `Memory` 是否逐字段列：没查。
- 她设备上各开关现在的值（画像注入开没开、滑条落哪档）：没看她数据。
- `mem_master` 没标 `aiWritable: false`，有没有 AI 改设置的入口能单改它：没核。
