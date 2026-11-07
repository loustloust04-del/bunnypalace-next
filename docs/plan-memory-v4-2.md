# plan · 记忆修复 v4-2：事实池 → 整理 → 点 md + 分层索引

✅ 粟粟 10-14 批 Q1–Q12「都按推荐」；10-15 批 Q13–Q16「都按推荐」——可以实现（排在 thinking 回传之后，同在 backend-2）。

> 第二版（10-14）。粟粟 10-14 批第一版：「都按推荐｜这个也放一个进度条，还有额度分配（btw 总记忆也要放一个额度分配）。｜每个档案本身有自己的编号和 100 字摘要」。Q1–Q12 已定，本版加了：整理进度条（四.5）、点 md 编号 + 100 字摘要（三）、v4-2 自己的额度分配 + 总记忆额度分配（七½）。新的拍板项是 Q13–Q16。
> 依据：`~/Desktop/cc-rp/记忆系统/派单/prompt-记忆修复v4-2.md`、`花园记忆改造计划-v4-1011.md`（二原则 / 三术语 / 四写手 W1 W7 / 五 v4-2 / 七拍板 / 七½改名）、[v4-1 plan](plan-memory-v4-1.md) / [复盘](review-memory-v4-1.md) §2、kimi-core / Scarlett 研究笔记。
> 代码证据按本工位（backend-2）当前文件的行号；master 上行号可能差几行。
> 名字只用 v4 的：**事实池**、**点 md**、**索引**（根索引 / 分组索引）、**整理**、**时间轴**、**上下文摘要**、**窗口总结**、**小克的记忆**、**心声**、**旧档**、**模型2号** / **模型3号**。
> 批注用 ⧫，每节下面都可以写。

## 一句话目标

W1 只往事实池里丢干的事实（带发生日期 + 出处，不带口吻，模型3号，可选本机）；W7（模型2号）每天整理一次：先读索引和相关点 md，再把池里没整理的事实追加进点 md / 新建点 / 补 [[链接]] / 改这个点的摘要，池里原条目标「已整理」不删；每个点有永不复用的编号和 ≤100 字摘要；索引分两层（根索引 + 每组一个），根索引常驻 prompt；第一批点 md 从 CC memory 搬（私密文件结构上挡掉）；整理有进度条，每次整理有一页「本次整理」可逐行撤回；记忆注入的额度在一条分段条上看得见、调得动。

## 不在本单

- Mac 下沉、清洗导入老聊天记录（粟粟 10-11 暂缓）。
- 10 月以前的事实池条目不整理（以后再说）。
- 记忆 app 和 prompt 标签一字不差、本轮注入打标记、删「目录式注入」开关、事实池整池注入换写法（v4-3）。
- 文件库「记忆」文件夹改中文物理名 / 合并旧档（v4-4；本单只把 v4-4 的文件夹清单改好，见 Q3）。
- 点 md 里 [[链接]] 点了能跳、粟粟直接在文件库里改点 md（v4-4；本单的修剪入口是「本次整理」逐行撤回）。
- recall 认点 md 编号（v4-3，Q16）。本单里编号能用 fs_search / fs_read 找到。
- 做梦 / 画像（v4-6）。

---

## 零、现状（带证据）

| 事 | 现在是什么样 | 证据 |
|---|---|---|
| 事实池 = 现在的 `Memory` 表 | 字段已有：内容、分类、出处对话 `sourceConversationId`、出处消息 `sourceNodeId`、逐字出处 `sourceQuote`、软删除 `supersededAt`、`createdAt`。**没有**「发生在哪天」「已整理」 | `MemoryPalace/Models/Memory.swift:16-39` |
| W1 触发 | 只在 API 回复的 onComplete 里调；每 3 轮一次（首轮必跑），看最近 7 条 | `ConversationViewModel.swift:3983`、`:2266`、`:4589-4600`；间隔 `MemoryService.swift:410-413` |
| W1 看到什么 | 人设全文 + 画像 + 现有热 / 温档案全量 JSON + 最近 7 条 | `ConversationViewModel.swift:4581-4618`、`MemoryService.swift:1136-1161` |
| W1 写法 | AUDN：add / update / delete；**第二刀「人设本人口吻、原话占 30–50%」**，示例就是「……我得记着，到时候问问」；add 没有逐字 quote 整条扔 | `MemoryService.swift:1079-1131`（规则 5、6、示例）、`:1179`、`:1303-1376` |
| W1 用哪个模型 | 和 W2 / W3 / 做梦同一个「提取模型」（`memoryExtractModelId`，自动 = 主对话那家的便宜款）。代码里只有这一个副模型 = 路线图的**模型2号**；**模型3号不存在** | `ConversationViewModel.swift:2638-2671`、设置 `MemoryPageContent.swift:150-175`、W2/W3 用它 `SessionCloseout.swift:705`、`:721` |
| 本机模型 | 有 `localMLX`（Qwen3 1.7B「轻巧款」/ 4B「聪明款」，**没有 3B**）；模拟器不支持 | `AssistantModelStore.swift:26-38`、`LocalLLMService.swift:21-27` |
| 后台任务不准跑本机模型 | `ProviderRouter.sendNonStreaming` 遇到 `localMLX` 直接抛「本机模型只在聊天里用，后台任务不跑」（小芽 v3 D1：和聊天抢 GPU）。进后台 / 内存警告时本机模型全停 | `ChatService.swift:2098-2102`、`:2133-2134`；`LocalLLMService.swift:47-55` |
| 本机模型能吃多少 | system 截 3000 字、总共 6000 字（字符，不是 token） | `LocalLLMService.swift:275-276` |
| 「提取模型」选了本机 = 所有记忆写手都会抛错 | 设置里可选的是全部启用卡（含本机） | `MemoryPageContent.swift:492-494` + 上面那条（现有隐患，本单顺手挡） |
| CC 回复不跑 W1 | CC 回复落地只喊 W2（`requestCC`），不提取事实 | `ConversationViewModel.swift:402-405` |
| 一轮记忆原料从哪来 | `MemoryInjector.roundInputs`：实发 `composePrompt` 和记忆 app「下一轮会想起什么」同一个函数；`[我的记忆]` 先装、事实池用剩下的预算 | `MemoryService.swift:692-709`、`ConversationViewModel.swift:2337-2342`、`MemoryPanelView.swift:1212-1218` |
| 记忆树 | `floors/<楼层>/memory/`，永远本地；fs 工具对 `memory/` 只读；记忆树浏览按第一层子文件夹分组（显示名表里没有「档案」） | `FileLibraryStore.swift:665-692`、`MemoryTreeBrowserSheet.swift:104-109` |
| 小克的记忆格式 | `memory/self/<slug>.md`：顶层 name / description + 缩进 metadata，旁边程序重建 `INDEX.md`，照 CC memory 的样子 | `SelfMemoryStore.swift:42-53`、`:160-174` |
| CC memory 同步 | 只同步到一个选定楼层的 `memory/cc/`；hub 已滤、手机再滤一遍：`private_` 开头、文件名 / frontmatter name / description 提到「日记 / diary」；MEMORY.md 里指向被排除文件的行由 hub 删 | `CCMemorySync.swift:7-33`、`:82-104`、`:133-142`；hub `cc-bridge/cc-memory-sync.ts:13`、`:50`、`:176-177` |
| CC memory 长什么样 | 一行一个点的 MEMORY.md + 一点一份 md；文件名前缀：feedback 104、project 42、user 15、reference 3、private 1；131 份带 `metadata.modified`，其中 10 月改过的 8 份（只数了文件名和日期，没读正文） | `~/.claude/projects/-Users-susu-Desktop-cc-rp/memory/` |
| 05:00 日界 | `MemoryDay.key / month / split`；「记忆从哪天开始」`MemoryStartDay`（她设的 10-01） | `MemoryDay.swift:6-61`、`MemoryStartDay.swift:6-41` |
| 定时 | **没有 BGTask**（`UIBackgroundModes` 只有 audio / voip）。收尾巡检靠事件：回前台、进后台、每次回复、切窗口、新建对话 | `project.yml:343-345`；`MemoryPalaceApp.swift:1308-1309`、`:1369`、`:1377`；`ConversationViewModel.swift:751`、`:3996`、`:5137`、`:5213` |
| 记忆写手调模型 | `SessionSegmentWriter.modelCaller`：预算闸 → `ProviderRouter.sendNonStreaming` → 记花费；空输出 = nil。格式错 `MemoryWriterError.format` | `SessionSegmentWriter.swift:178-205`、`:209-217` |
| 非流式不走 ParamCompat | `sendNonStreaming` 不带采样参数：OpenAI 兼容 body 只有 model / messages / stream；Anthropic 多一个 `max_tokens = min(8192, 模型上限)` + system；没有 `ParamCompat.resolve`，也没有 400 自适配重试 | `ChatService.swift:2079-2160`、`:886-944`、`:1421-1470` |
| 已有「整理记忆…」 | 记忆 app ⋯ 和设置里的「整理」= 重写画像 + 意思几乎一样的两条合并（合并掉的进「已删除」） | `MemoryOrganizeSheet.swift:4-20`、`MemoryHygiene.swift:5-12` |
| 主线程读盘预算 | `composePrompt` 每个调用点有上限、没列的 = 0，只许降 | `MainThreadIOBudgetTests.swift:14-31` |
| 金样夹具 | 测试楼层有两条事实、时间轴、上下文摘要；**没有 `memory/` 下别的文件夹** | `PromptRealPathHarness.swift:201-206`、`:290-321` |

### 记忆注入现在各段的额度（七½ 的底）

| 注入段 | 现在怎么卡 | 默认 | 证据 |
|---|---|---|---|
| 记忆总预算 | 一个数，只管下面两段（`[我的记忆]` + `[关于她]`）。**默认是 10000 token，不是 2000**（CLAUDE.md 里写的 2000 是老数） | `mem_inject_budget` = 10000 | `MemoryService.swift:620-623`；设置 `MemoryPageContent.swift:38` |
| `[我的记忆]`（remember 写的） | 占总预算的百分比；五级的全文 + 最近 5 条全文，其余一行目录，装到预算为止 | 100%（先装、不设上限） | `MemoryService.swift:415-422`、`:697-704`；`SelfMemoryInjection.swift:13-40` |
| `[关于{她}]`（事实池） | 用总预算减掉 `[我的记忆]` 实占的剩下部分；目录模式另有最多 30 行 | 剩下的 | `MemoryService.swift:707-708`、`:637`、`:725-735` |
| `[时间轴]` | 只按条数 / 天数，**没有 token 上限** | 最近 8 条、7 天内 | `TimelineStore.swift:33-40`、`:157-180`；`CalendarInjection.swift:71-82` |
| `[上下文摘要]` | 最近 N 段全文、更早的每段一行标题，**没有 token 上限** | 2 段（最多 4） | `SessionCloseout.swift:78-81`；`SessionSummaryStore.swift:180-195`；`ConversationViewModel.swift:2374-2379` |
| `[用户画像]` | 整份照注，**没有上限** | — | `ConversationViewModel.swift:2382` |
| 窗口总结 | 不注入（只给 recall） | — | v4-1 Q12 |
| 心声 | 不注入（是工具） | — | `ConversationViewModel.swift:4233-4249` |
| `[档案索引]`（本单新） | Q4：1500 | 1500 | 本单七 |

v4-1 复盘 §2 留给本单的三条：读「发生过什么」走时间轴不读窗口总结；归日一律 `MemoryDay`；`SessionCloseout` 加写手前先拆。本单 **W1、W7 都不进 `SessionCloseout` 这个 actor**（W7 自己一个 actor，CC 的 W1 只在 `SessionCloseoutTrigger` 里多喊一声），所以不拆它；W7 也不读窗口总结。

⧫

## 一、东西和名字

| 名字 | 是什么 | 谁写 | 存哪 | 本单新增 / 改 |
|---|---|---|---|---|
| 事实池 | 一条一个干的事实 + 发生日期 + 出处 | W1（模型3号） | 数据库 `Memory` 表（不变） | 加 3 个可选字段；记忆 app、设置里叫「事实池」 |
| 点 md | 一个点一份 md：编号、名字、≤100 字摘要、事实一行一条（日期 + 出处）、[[链接]] | W7 只追加 + 改摘要；种子一次性 | **新** `memory/档案/<分组>/<编号>-<点名>.md` | 新 |
| 编号簿 | 下一个编号是几、用过的编号（含删掉的），保证永不复用 | 程序 | **新** `memory/档案/编号.md` | 新 |
| 分组索引 | 一组一个，一行一个点：编号 · 名字 — 100 字摘要 | 程序按点 md 文件头重建 | **新** `memory/档案/<分组>/INDEX.md` | 新 |
| 根索引 | 每组一段，一行一个点：编号 · 名字 — 摘要第一句；超额度按组压缩 | 同上 | **新** `memory/档案/INDEX.md` | 新；常驻 prompt |
| 整理记录 | 每次整理的进度、改了哪些 md、加了哪些行，供进度条、审和撤回 | W7 / 撤回 | **新** `floors/<楼层>/记忆备份/整理记录/<时间>.json`（`memory/` 外，小克的 fs 工具和文件库「记忆」都看不到，和 v4-1 备份同一个地方） | 新 |
| 额度设置 | 记忆注入各段的额度 | 她在设置里调 | UserDefaults（每段一个整数键；见七½） | 新键；老键 `mem_inject_budget` / `mem_self_budget_percent` 沿用 |

已有路径、已有文件格式**都不改**：`timeline/`、`sessions/`、`windows/`、`self/`、`cc/`、`heartvoice/`、`summaries/`、`daily/`、画像都原样。新东西只在 `memory/档案/` 和 `记忆备份/整理记录/`、`记忆备份/试抽-*`、`记忆备份/事实池水位.json`。

⧫

## 二、W1：事实池（模型3号）

### 1. 存什么（数据库，`Memory` 加 3 个可选字段，轻量迁移，先例 `321ef4240`）

| 字段 | 新 / 旧 | 意思 |
|---|---|---|
| `content` | 旧 | 一句干的事实（见 3） |
| `category` | 旧 | preference / fact / relationship / goal / context（常驻层按它判，`MemoryService.swift:898-900`，不能丢） |
| `sourceConversationId` / `sourceNodeId` | 旧 | 出处：窗口 + 消息 |
| `sourceQuote` | 旧 | 有就存，不再强制 |
| `occurredDay` | **新** `String?` | 发生在哪天（`yyyy-MM-dd`，05:00 日界）。**程序算**：出处那条消息的时间过 `MemoryDay.key`，不让模型写日期 |
| `organizedAt` | **新** `Date?` | 整理过的时间；nil = 未整理 |
| `organizedNote` | **新** `String?` | 整理到哪：点的编号 `p0007` / `跳过：重复` / `撤回过` |

老条目没有 `occurredDay`：整理时有 `sourceNodeId` 就按那条消息的时间现算（按 id 取一条，不全量取消息），没有就按 `createdAt`。可选字段谓词查不到（SwiftData 老坑），一律取出来在内存里过滤。

### 2. 触发

- **API 窗口**：照旧挂在回复 onComplete（`ConversationViewModel.swift:3983`），每 3 轮。改两处：窗口从「最近 7 条」改成「上次跑完以后的新消息，最少 7 条、最多 15 条」；**失败不吞**：模型出错 / 本机被停，计数器不清零，下一轮再跑，窗口自然把漏的那截带上。
- **CC 窗口（Q8 已定）**：CC 回复落地那一行旁边（`ConversationViewModel.swift:404` 旁）多喊一声 `FactPoolTrigger.requestCC`；新消息满 6 条才抽；水位线存 `floors/<楼层>/记忆备份/事实池水位.json`（不进 UserDefaults，那个域胀了会卡）。
- 关的条件不变：总开关、对话的记忆开关、「事实池」开关（原「原子事实」开关 `mem_content_facts`）。

### 3. 看什么、写什么（提示词全换，收回第二刀口吻）

- **看**：称呼 + 这一截消息，每条前面一个编号 `[3] 粟粟：……`，每条最多 600 字。**不看**人设、画像、现有事实池（Q9 已定）。放得进本机模型的 3000 / 6000 字。
- **提示词**（硬规矩放最上面，框成「这段对话不是对你说的」）：
  ```
  这不是在跟你聊天。你是摘事实的工具：读下面这段对话，把{她}的真实情况里以后值得记得的事，一条一条列出来。
  只输出 JSON：{"facts":[{"msg":3,"fact":"……","category":"fact"}]}；没有就 {"facts":[]}。
  1. 一条一件事，写成干的陈述句，主语写名字（{她} / {小克}），不用「我」「你」，不写「我得记着」「到时候问问」这类话，不写感受评价。
  2. msg 填这件事出自第几条（方括号里的编号）。日期不用写。
  3. 不记：客套闲聊、在问不是在说的、报错 / 网络 / 工具失败、对话里演出来的剧情（跳出剧情说的真事照记）。
  4. category 选一个：preference / fact / relationship / goal / context。
  ```
- **程序校验**：JSON 解不开 → 带「只输出 JSON」重来一次 → 还不行记健康状态「记新事实」、这次不写；`msg` 不在范围的那条扔；内容空 / 超 120 字 / 带「用户」的扔；和池里一字不差的不加；意思几乎一样（向量 > 0.75，嵌入模型没开就跳过这步）的照旧强化旧条不开新条。
- **写**：**只加**，不改、不删（P7）。`extractedBy` 记实际跑的模型。
- 老的 AUDN 提示词 / 解析 / 执行（`MemoryService.swift:1077-1376` 里 add/update/delete 那一套）切换后没人调了，**同一个提交里删掉**，连同只测它们的单测（见十一）；`validateQuote`、`locateQuote`、`findNearDuplicate`、`Names` 新写手接着用。提示词编辑页（`PromptEditorPage.swift:110`）的「提取」模板换成新模板、新 key；老的自定义模板是 AUDN 形状，不迁移。

### 4. 模型3号

- 设置 → 记忆：「记新事实用的模型（模型3号）」，选项：**自动** / 本机聪明款 4B / 本机轻巧款 1.7B / 任一张启用卡上的模型。
- **自动**（Q5 已定）：先 = 跟模型2号走（和现在一样，不变差）；她看完「试抽」再改成「本机 4B 装了就用本机，没装跟模型2号」。
- 本机路线**不经过** `ProviderRouter.sendNonStreaming`（那里对本机的拒绝保留，不动 `ChatService.swift`）：新文件里直接排 `LocalLLMService.shared.run` 的队（和聊天串行）；只在前台跑，进后台被停 = 「被打断」，不记失败、下一轮重来；模拟器 / 没下载 → 退模型2号，健康状态那行写「用的是 X（本机模型没装）」。
- 原来那个「提取模型」改名「记忆模型（模型2号）」，副文案「写上下文摘要、窗口总结、时间轴、整理档案、做梦用这个」；**它的选项里去掉本机模型**。

### 5. 试抽（Q5 已定，只在 DEBUG、只在 Mac）

设置 → 记忆 → 高级 →「试抽事实（调试）」：她勾几个 10 月的窗口，本机 4B 和模型2号各抽一遍，结果写成对照 md `floors/<楼层>/记忆备份/试抽-<时间>.md`（两列，每条带出处），**不进事实池**。开发时不跑真数据，只给她点。跑的时候用和整理同一个进度条组件（「第 2 / 5 个窗口 · 本机」）。

⧫

## 三、点 md、编号、摘要、分层索引

### 1. 目录（Q3 已定）

```
memory/档案/
  INDEX.md              ← 根索引（常驻 prompt）
  编号.md               ← 编号簿
  分组.md               ← 分组顺序，一行一个组名
  人/ INDEX.md  p0001-小雾.md  p0004-团子.md …
  事/  物/  地点/  时间/  项目/
```

- 分组 = `档案/` 下第一层子文件夹，默认六个：人 / 事 / 物 / 地点 / 时间 / 项目。**分组用户可改**：记忆 app 设置格「档案分组」里加组、改名（挪文件夹 + 重建索引）、删空组。
- 点名全档案唯一。

### 2. 编号（新）

- **格式**：`p` + 4 位数字，`p0001`、`p0002` …（满 9999 自动变 5 位）。ASCII，fs_search / 文件名 / 整理记录里都好搜。
- **谁发**：只有程序发（新建点、种子），模型不准自己写编号。发号读 `编号.md` 的「下一个：38」，原子写回 +1。
- **永不复用**：撤回删掉的点，编号记进 `编号.md` 的「已作废：p0012 p0030」，下一个照样往后数。编号簿坏了 / 丢了 → 扫一遍所有点 md 和整理记录里出现过的最大编号 +1 重建。
- **改名、换组不变**：编号写在文件头 `id:`，文件名是 `<编号>-<点名>.md`；改名 / 换组只改文件名后半段和所在文件夹，编号不动。找点一律先按编号找（文件名前缀），找不到再按名字。
- **链接**：`[[p0001|小雾]]`（Obsidian 的「文件|显示名」写法），程序按编号解析；改名时程序顺手把各处 `|` 后面的显示名换新（只动链接显示名，不动事实行）。种子和模型写的 `[[小雾]]` 由程序落盘时换成带编号的写法。
- **谁能用编号**：事实池条目的 `organizedNote`、整理记录、撤回、进度条都按编号指点；小克用 `fs_search p0001` 或 `fs_read memory/档案/人/p0001-小雾.md` 找得到（编号在文件名和文件头里）。recall 认编号放 v4-3（Q16）。

### 3. 点 md

```markdown
---
id: p0001
name: 小雾
group: 人
summary: 粟粟的爱人。10 月在准备搬家，想要朝南的房子；周末常和粟粟去看展。
summary_by: 整理 2026-10-18
created: 2026-10-15
updated: 2026-10-18
---
# 小雾

- 2026-10-12 小雾周末和粟粟去看展 〔conv 1a2b3c4d · 池 3f2a9c01〕
- 2026-10-14 小雾在找新房子，想要朝南的 〔conv 9e8f7a6b · 池 77c1d0aa〕

相关：[[p0009|看展]] [[p0004|团子]]
```

- **摘要（新）**：`summary` ≤ 100 字，**模型2号写**，说清这个点是什么、现在最要紧的是什么。新建点必须带；W7 每次往一个点里加了行，**必须给这个点交一句新摘要或明说「不变」**（程序检查，漏了算格式错）。`summary_by` 记谁、哪天写的（「整理 10-18」/「种子」）。改摘要是整理记录里的一项，能撤回（回到旧摘要）。
- 原来设想的 30 字「钩子」不要了：根索引用摘要的第一句（到第一个句号 / 分号，最多 30 字），由程序截，不另存。
- 事实行：`- {发生日} {事实句} 〔conv {对话前 8 位} · 池 {事实池条目前 8 位}〕`。**日期和出处由程序拼**，模型只写中间那句。`池 xxx` 也是幂等标记（见十）。
- 「相关：」一行放链接，程序去重排序；指向不存在的编号就先留着。
- 种子搬来的点多一段：`## 来自 CC 笔记（2026-09-12）`，下面原文照抄。

### 4. 索引（照 CC 的 MEMORY.md：一行一个点）

- **分组索引** `档案/人/INDEX.md`：`# 人` + 每点一行，按 `updated` 新的在前：
  `- p0001 · [小雾](p0001-小雾.md) — 粟粟的爱人。10 月在准备搬家，想要朝南的房子；周末常和粟粟去看展。`（完整 100 字摘要）
- **根索引** `档案/INDEX.md`：每组一段 `## 人（12）`，每点一行：`- p0001 小雾 — 粟粟的爱人`（编号 + 名字 + 摘要第一句）。**放完整 100 字摘要还是第一句见 Q15**（推荐第一句：100 字一行按 app 的粗算约 200 token，1500 的额度只够 7 个点）。
- 根索引按「档案索引」的额度（七½）装：每组先分到一份（默认按点数比例、每组至少 1 行，她可以给某组单独定），组内按 `updated` 新的在前，装不下的写「（还有 N 个，见 档案/人/INDEX.md）」；还装不下只留组标题和个数。不截半行。
- 两层索引都是**程序从点 md 文件头机械重建**，不让模型写索引文件。

### 5. 事实池条目在哪看

不出文件。记忆 app「记忆」格里原「从聊天里记住的」那组改名「事实池」，每行多一个小标记：已整理（`→ p0001 小雾`，点了打开那份点 md）/ 未整理 / 跳过（带理由）/ 撤回过。

⧫

## 四、W7：整理（模型2号）

### 1. 一次整理怎么跑（当前楼层，一个楼层同一时刻只跑一个）

1. **挑条目**：事实池里 未删除 && 未整理 && 不是「撤回过」&& 发生日 ≥ 起点（「记忆从哪天开始」，她设的 10-01；没设按 2026-10-01）。按发生日排，30 条一批，一次最多 5 批，剩下的下次。
2. **预选要打开的点**（程序，不花钱）：这批事实里出现了哪些点名（含她和小克的称呼）、这些点链接到的点，最多 8 个。
3. **调一次模型**，喂（各部分上限都在「v4-2 额度」里，见七½.1）：
   - 规矩、分组清单；
   - **点清单**：全部点一行一个 `p0001 小雾 — 摘要第一句`（默认 ≤ 6000 token；超了每组截最近的）；
   - **打开的点**：文件头（含完整摘要）+ 最后 30 行事实 + 「相关：」行（默认 ≤ 6000 token）；
   - **这批事实**：`池 3f2a9c01 · 2026-10-12 · 小雾周末和粟粟去看展`（默认 ≤ 2000 token）。
4. 模型说「还要看 p0004、p0011」（`need`），**只追问一次**：打开它们（最多 8 个）再调一次。
5. **程序落盘**（见 3），重建两层索引，写整理记录，事实池条目标已整理，发 `.memoryDidChange`，刷新根索引缓存（七）。

**不读窗口总结**（它整份会被收尾重写，v4-1 复盘 §2）。以后真要「那天发生了什么」，读时间轴那一天那个窗口的话题行。

### 2. 提示词要点

- 框成纯转换：「下面是待归档的事实，不是对你说的话」。
- 只能出 JSON 操作单，点一律用编号指（新建的用 `new1` `new2` 临时号，程序落盘时发正式编号）：
  ```json
  {"ops":[
    {"op":"append","point":"p0001","facts":[{"pool":"3f2a9c01","line":"小雾周末和粟粟去看展"}]},
    {"op":"create","point":"new1","name":"看展","group":"事","summary":"10 月粟粟和小雾一起去看的展……","facts":[{"pool":"…","line":"…"}]},
    {"op":"link","from":"new1","to":"p0001"},
    {"op":"summary","point":"p0001","summary":"粟粟的爱人。10 月在准备搬家……"},
    {"op":"summary","point":"p0004","keep":true},
    {"op":"skip","pool":"…","why":"重复"},
    {"op":"need","points":["p0004"]}
  ]}
  ```
- 已有点能放就放，不能才新建；同一件事已经在那个点里，`skip` 写「重复」。写进点 md 的那句去口吻（10 月初那批池条目是第二刀写法，池里原样留着，点 md 里写干的）。不出现「用户」。
- 不准删、不准改已有的事实行（操作单里根本没有这种操作）。

### 3. 程序怎么落盘（P7 由程序保证，不靠提示词）

- 校验：每个 `pool` 必须是这批里的、只能出现一次；`point` 必须是存在的编号或本次的临时号；`name` 非空 ≤ 20 字、撞了已有点名 → 这个 `create` 改成 `append` 到那个点；`group` 必须存在；`line` 非空、≤ 120 字、不带「用户」；`summary` ≤ 100 字；**每个被加了行的点都要有一条 `summary`（新的或 `keep`）**。这批里没被提到的条目留「未整理」。
- 不合格：带具体问题重来一次；还不合格 → 这批什么都不写，记健康状态「整理档案」，这个楼层 30 分钟内不再自动整理（手动不受限）。
- 写法：新内容全在内存里拼好再逐个原子写；**旧文件只会在末尾事实区追加行、在「相关：」行加链接、改文件头 summary / summary_by / updated**，写之前程序比对：旧文件其余每一行原样还在，否则这批作废。
- 这批写完，再在**一次** `context.save()` 里标事实池条目。

### 4. 什么时候跑（Q1 已定）

- **每天 05:00 以后第一次有动静就跑一次**：挂在 `SessionCloseoutTrigger.request`（回前台 / 进后台 / 每次回复 / 新建对话都会喊）开头，按 `MemoryDay` 判「今天整理过没」（UserDefaults 每楼层一个日期字符串）。iOS 没有 BGTask，做不到半夜准点。
- **手动**：记忆 app ⋯「整理」、事实池组头「整理（未整理 N）」。
- 未整理攒到 100 条，事实池组头冒一句「该整理了」。

### 5. 进度条（新）

**状态**（一次整理从头到尾）：

| 状态 | 条上写什么 | 进度怎么算 |
|---|---|---|
| 排队 | 「等前一件写完」（同楼层正在种子 / 另一次整理） | 不走 |
| 读取 | 「读出未整理的 N 条 · 打开相关的点」 | 0 |
| 整理 | 「整理第 2 / 5 批 · 已放好 37 / 142 条」；追问时「第 2 批 · 再看 3 个点」 | 已处理条目 / 本次总条目 |
| 写索引 | 「写索引 · 6 个组」 | 组数 |
| 完成 | 「新点 3 · 追加 11 行 · 跳过 4」+「看本次整理 ›」 | 满 |
| 失败可重试 | 「第 3 批没整理好：<一句原因>。前 2 批已写好」+「重试」 | 停在当时的位置 |
| 中断可继续 | 「上次整理到第 2 / 5 批时 App 被关了」+「继续」 | 同上 |

- **在哪出现**：记忆 app「记忆」格事实池组头（手动按钮按下后原地变成进度条）；「本次整理」页顶上一张卡（正在跑的那次永远在最上面）；设置 → 记忆 →「档案」小节（自动整理开着时显示今天那次的状态）。三处读同一个 `@Observable` 进度对象，只给界面看，不参与整理逻辑（同 `SessionCloseoutStatus` 的做法，`SessionCloseout.swift:733-740`）。
- **配色**：进度填充薄荷色、底槽浅灰、字用主题正文色；失败行用主题里的红色系文字 + 「重试」按钮用 `MemoryPrimaryButtonStyle`（薄荷实心白字）。**不用蓝、不用黄**（也不用系统默认 `ProgressView` 的强调色）。
- **切后台**：iOS 进后台时申请一小段后台时间（`beginBackgroundTask`），够就把当前这一批写完；不够就在这一批之前停下。进度每批写进整理记录（`进行中`，已完成第几批）。回来时：进程还在 → 接着跑；进程被杀 → 「本次整理」页和组头显示「中断可继续」，点「继续」接着整理剩下的未整理条目（已写的批不会重做，见十的幂等）。自动整理被打断的，下次有动静时自己继续，不用点。
- 种子（几十份文件，很快）也用同一个进度条：「搬第 12 / 60 份」。

⧫

## 五、「本次整理」：审和撤回（Q2 已定：先写进去、可撤回）

- **记录**：`floors/<楼层>/记忆备份/整理记录/2026-10-15-0512.json`，一次整理一份：时间、模型、状态（进行中 / 完成 / 失败 / 中断）、进度、每个操作（编号、文件、加了哪几行原文、新建与否、摘要改前 / 改后、加的链接、对应池条目）。只留最近 60 份。
- **页面**（记忆 app ⋯「本次整理」，最近一次在上）：
  - 顶上进度卡（四.5），跑完是一行「10-15 05:12 · 模型 X · 新点 3 · 追加 11 行 · 跳过 4」。
  - 按点分组：「p0001 小雾（人）+2 行」「p0009 看展（事 · 新）」，下面是加的那几行，每行右边「撤回」；摘要改动显示「旧 → 新」带「撤回」；跳过的列理由，可「重新整理这条」。
- **撤回一行**：在那份 md 里找这一行原文，找到就删掉、重建索引；找不到（那行被改过）就不动，提示「这一行已经改过，没撤」。对应池条目标「撤回过」（Q11 已定），自动整理不再碰；事实池里点「重新整理这条」才回到未整理。
- **撤回新建的点**：这个点里只剩这次加的行 → 删文件、编号记作废、去掉别人指向它的链接、重建索引；后来又追加过 → 只撤这次的行。
- **撤回摘要**：换回旧摘要；之后这个点又被改过摘要 → 不动，提示。
- 撤回是她手动做的修剪（P7「人来修剪」），程序自己从不删行。

⧫

## 六、种子：CC memory（Q6、Q12 已定）

- **入口**：设置 → 记忆 → 档案 →「从 CC 笔记搬第一批」，只在 CC 同步开着、同步楼层 = 当前楼层时出现（Release 也有）。只能在 `档案/` 还没有点的时候点；点了先弹确认：**列出要搬的全部点名、组和摘要**，她看过再点。
- **来源**：本机 `memory/cc/`（已经被 hub 和手机滤过一遍），**不连 Mac、不读 CC 原目录**。
- **结构上挡私密**（不靠排序、不靠模型）：一个纯函数 `SeedSource.eligible(name:content:)` 决定能不能搬：
  1. 文件名 `private_` 开头 → 不搬；
  2. `CCMemorySync.isExcluded`（文件名 / name / description 提到日记 / diary）→ 不搬；
  3. `MEMORY.md` 本身不当点（只用来取名字和摘要）。
  搬过来的正文里，指向「不能搬的文件」的链接所在那一行整行删掉（链接文字可能就是钥匙名）；`MEMORY.md` 里指向不能搬的文件的行不读。单测用装着私密文件 / 日记描述文件 / 链接指过去的普通文件的夹具，跑完把整棵 `档案/` 搜几个哨兵字符串，一个都不能出现。
- **搬哪些**：`user_` → 人、`project_` → 项目、`reference_` → 物，约 60 份；`feedback_`（104 份，CC 小克的相处规矩）不搬，照旧在 `memory/cc/`。不按 10 月筛（10 月只管事实池）。
- **怎么搬**：机械搬，**不调模型**。按文件名排序依次发编号；点名 = MEMORY.md 那一行的链接文字（没有就用 frontmatter 的 name）；**摘要** = 那一行「—」后面的字（没有就用 description），截到 100 字，`summary_by: 种子`，以后 W7 第一次往这个点加行时会重写；正文原样抄进 `## 来自 CC 笔记（{modified 日期}）`，去掉同步头注释；指向别的已搬文件的链接改成 `[[编号|点名]]`。
- 搬完是一次性快照：CC 那边之后再改，`档案/` 不跟着变（W7 只吃事实池）。

⧫

## 七、注入：根索引常驻

- **放哪**：记忆插槽里，`[我的记忆]` 后面、`[关于{她}]` 前面，进常驻层（缓存前缀）。一天最多变一次（整理那次）。
- **写法**：
  ```
  [档案索引]（一行一个点：编号 名字 — 一句话。细节在 memory/档案/ 下以编号开头的 md 里，事实带日期和出处）
  ## 人（12）
  - p0001 小雾 — 粟粟的爱人
  …
  ```
  头一行**不写工具名**（#093 工具抽屉之后 fs_read 可能在「更多工具」里）。
- **常驻、不做开关**（验尸报告第 20 条）；跟总开关和对话的记忆开关走（和 `[我的记忆]` 同一个 `shouldInject`）。和「目录式注入」开关无关（那个管事实池那段，v4-3 删）。
- **怎么接进去（不碰组装路径）**：只改 `MemoryInjector.roundInputs`（`MemoryService.swift:692-709`）——它给出的「[我的记忆] 整段」改成「记忆插槽开头段」= `[我的记忆]` + `[档案索引]`。`composePrompt`、`PromptAssembler`、记忆 app 预览都只认这个函数，所以**实发 = 检查器 = 记忆 app 预览**自动成立，三个文件一行不改。
- **不在主线程读盘**：根索引文本放按楼层的内存缓存；W7 / 种子 / 撤回写完在后台刷新；启动和切楼层后台预热。缓存还没热的那一轮不带。`MainThreadIOBudgetTests` 不加调用点。
- **事实池那段（`[关于{她}]`）的写法本单不动**（Q7 已定），只是它分到的额度按七½算。

⧫

## 七½、额度分配（新）

两张表，一个页面：设置 → 记忆 →「额度分配」。上面是**总记忆**的分段条（她要的「总记忆也要放一个」），下面是 **v4-2 自己**的几项（整理时喂给模型2号的）。

### 1. v4-2 自己的额度

| 项 | 管什么 | 默认 | 用量怎么显示 |
|---|---|---|---|
| 档案索引（注入） | 根索引进 prompt 的上限；在总记忆条上也是一段 | 1500 token（Q4） | 上一轮实际注了多少 |
| ↳ 每组份额 | 档案索引里每组能占多少 | 自动（按点数比例，每组至少 1 行）；可给某组单独定 | 每组用了几行 / 多少 token、被折叠了几个点 |
| 整理 · 点清单 | 喂给模型2号的全部点一行一个 | 6000 token | 上次整理实际多少 |
| 整理 · 打开的点 | 预选 + 追问打开的点 md 片段 | 6000 token | 同上 |
| 整理 · 一批事实 | 一批最多多少 | 2000 token（≈ 30 条） | 同上 |
| 整理 · 一次最多几批 | — | 5 | 上次跑了几批 |

这几项只影响 W7 的花费和看得全不全，不影响聊天请求体（档案索引除外）。都有下限（点清单 ≥ 2000、一批 ≥ 10 条）防止调到整理不了。

### 2. 总记忆额度（分段条）

一条横条，按段切开，每段写「用了 / 分到」；拖分隔点或点一段填数字调；总数是她设的「记忆总额度」。段：

| 段 | 现在怎么卡（零的表） | 进总数吗 | 默认 = 今天的行为 |
|---|---|---|---|
| 小克的记忆 `[我的记忆]` | 总预算 × 百分比 | 进 | 「先装，不设上限」（= 现在的 100%） |
| 档案索引 `[档案索引]`（新） | 本单 | 进 | 1500；**没有档案时用量 0、不占** |
| 事实池 `[关于{她}]` | 总预算减前两段实占 | 进（拿剩下的） | 剩下的（= 现在） |
| 时间轴 `[时间轴]` | 8 条 / 7 天，没有 token 上限 | 默认**不进**，显示「按条数：8 条 · 7 天」+ 实际用量；她给了 token 上限才算进总数 | 不封顶（= 现在） |
| 上下文摘要 `[上下文摘要]` | 最近 2 段全文，没有 token 上限 | 同上 | 不封顶 |
| 画像 `[用户画像]` | 整份，没有上限 | 同上 | 不封顶 |
| 窗口总结 / 心声 | 不注入 | 不显示 | — |

- **总数**：沿用 `mem_inject_budget`（默认 10000）。约束：进总数的各段「分到」加起来 ≤ 总数；改总数时按比例缩各段、事实池永远拿剩下的。
- **用量**怎么来：发送时现成的记账（`MemoryInjectionMeter`）多记几段的 token 数（用同一个粗算 `Memory.estimateTokens`），设置页读它，不另算。
- **封顶后怎么截**（只在她给了上限时才发生）：时间轴从最老的条目往外丢；上下文摘要先把全文段降成一行标题，再丢最老的标题行；画像截尾加「……」；档案索引按三.4 折叠；小克的记忆和事实池照现有逻辑（装到额度为止）。不截半行。
- **默认必须和今天逐字一样**：总数 10000、小克的记忆「先装」、没有档案时档案索引 0、事实池拿剩下的、时间轴 / 上下文摘要 / 画像不封顶 → 拼出来的每一段和现在一个字都不差，G1–G6 不变（十二）。

**放哪（Q13）**：推荐放本单，单独一组步骤（执行清单 C 组），排在根索引注入之后、可以单独撤回。它**碰请求体的路径**：时间轴 / 上下文摘要 / 画像的封顶要加在 `TimelineStore.recent`、`SessionSummaryStore.injectionText`、画像那一行（`ConversationViewModel.swift:2382`）上；默认不封顶时一个字节都不变。不碰 `PromptAssembler`、不碰工具、不碰〔状态〕。

⧫

## 八、界面（改哪几处）

| 哪 | 改什么 |
|---|---|
| 记忆 app「记忆」格 | 「从聊天里记住的」→「事实池 · N」；组头「整理（未整理 N）」，按下原地变进度条；行尾标记（`→ p0001 小雾` / 未整理 / 跳过 / 撤回过）；⋯ 加「整理」「本次整理」「档案」（打开记忆树浏览、只看 `档案/`） |
| 记忆 app「本次整理」页 | 顶上进度卡 + 按点分组的改动 + 逐行撤回（五） |
| 记忆 app「设置」格 | 健康状态加两行：记新事实（显示实际用的模型）、整理档案；「档案分组」编辑 |
| 设置 → 记忆 | 「事实池」开关（原「原子事实」，key 不变）；模型3号；「记忆模型（模型2号）」改名改副文案、去掉本机；「档案」小节：今天那次整理的进度、每天 05:00 后自动整理开关（默认开）、从 CC 笔记搬第一批；**「额度分配」**（七½，替代现在单独那个「记忆预算」数字框）；高级：试抽（DEBUG + Mac） |
| 旧「整理记忆…」（Q10 已定） | 改名「合并重复 + 重写画像」，挪进设置格「高级」；「整理」只给 W7 |
| 记忆树浏览 | 显示名表加 `档案` |
| 设置搜索 | 加「事实池」「模型3号」「整理」「档案」「额度分配」 |

配色只用主题色（暖奶白 / 浅灰 / 薄荷），不用蓝、黄。给小克看的字（`[关于{她}]`、recall 描述、文件库提示里的记忆树那句）**本单一个字不改**。

⧫

## 九、钱和模型

按 app 自己的粗算（`Memory.estimateTokens`：一个汉字 2 token）：100 字摘要 ≈ 200 token；点清单一行（编号 + 名字 + 摘要第一句）≈ 70 token；根索引一行同。

| 写手 | 模型 | 多久一次 | 每次大概 | 上限怎么卡 |
|---|---|---|---|---|
| W1 | 模型3号：本机（不花钱）或模型2号 | API 每 3 轮；CC 每 6 条新消息 | 输入 ~1.5k，输出 ~300 | 程序截：最多 15 条、每条 600 字 |
| W7 | 模型2号（现 sonnet） | 每天一次 + 手动 | 一批输入 ≤ 14k（点清单 6k + 打开的点 6k + 事实 2k），输出 ~2k（多出来的是每个被改的点一句 100 字摘要，一批约 8 个点 ≈ 1.6k）；一次最多 5 批 + 每批最多 1 次追问 | 输入按七½.1 程序截；输出只能靠 Anthropic `max_tokens` 8192（`sendNonStreaming` 没有单次上限参数，本单不改 `ChatService.swift`） |
| 种子 | 不调模型 | 一次 | 0 | — |
| 试抽 | 本机 + 模型2号 | 她点一次 | 每窗口同 W1 | 她选几个窗口就几个 |

按 sonnet 4.5（$3 / $15 每百万）粗算：每天 60 条新事实 → 2 批 → 约 $0.15 / 天，$4–5 / 月。根索引 1500 token ≈ 20 行，种子搬 60 个点以后会明显折叠（每组只露最近的几个），她可以在额度分配里加。花费记到新的用途「整理档案」（`UsageKind` 加一个，旧版本读到按「其他」，`UsageLedger.swift:3-5`）。

⧫

## 十、失败和重试

| 情况 | 怎么办 |
|---|---|
| W1 断网 / 本机被进后台停掉 | 不算失败、不记健康；计数器不清零，下一轮再跑，窗口带上漏的那截（最多 15 条） |
| W1 JSON 两次解不开 / 模型报错 | 记健康「记新事实」（连 3 次变红）；下一轮照常再试 |
| W1 本机没装 / 模拟器 | 退模型2号，健康那行写清 |
| W7 断网 / 被系统掐 | 停在这一批之前（前面的批已写完），进度条「中断可继续」；自动整理下次有动静接着来 |
| W7 格式两次不合格 | 这批不写；进度条「失败可重试」；健康「整理档案」；这个楼层 30 分钟不再自动跑 |
| W7 写到一半 App 被杀（文件写了、条目没标） | 下次同一条再被放进来时，程序先在目标 md 里找 `池 xxxxxxxx`：已在 → 不再追加，只把条目补标、记录里写「补记」 |
| 编号簿写坏 / 两次整理抢号 | 发号在 W7 actor 里串行；编号簿坏了按「扫最大编号 +1」重建，作废表从整理记录里补 |
| W7 和 W1 同时跑 | W7 开头取一份条目快照，之后新进池的等下次 |
| 种子和 W7 同时 | 同一个 actor，种子跑时 W7 排队（进度条「排队」）；`档案/` 非空不让种子跑 |
| 撤回时那行 / 那句摘要改过 | 不动，提示 |
| 某个点 md 文件头解析不了 | 这个点这次不碰，相关条目留未整理，健康里记一句文件名 |
| 预算闸挡住 | 和现在一样，静默跳过，不算失败 |
| 额度调到装不下 | 照封顶规则截；设置页那段标红「被截了 N 条」 |

⧫

## 十一、测试

规矩照旧：scheme `MemoryPalaceTests`，grep 到对应 Test Suite passed；全部用内存库 + 新建测试楼层 id + 测完整层删，不读她的库和偏好（依赖 #035 测试宿主隔离），模型一律假 caller。

**新套件**

| 套件 | 测什么 |
|---|---|
| `FactPoolExtractorTests` | 提示词里没有人设 / 画像 / 现有事实 / 「我得记着」；编号消息；JSON 带代码块 / 废话也解；`msg` 越界扔；「用户」扔；归日 04:59 / 05:00；只加；一字不差不加 |
| `FactPoolModelRouteTests` | 模型3号：指定 > 自动 > 模型2号；本机路线不调 `ProviderRouter`；记忆模型选项里没有本机 |
| `FactPoolTriggerTests` | API 窗口失败后补上漏的；CC 窗口满 6 条才抽、水位线文件、不进 UserDefaults |
| `PointIdTests` | 发号连续、作废不复用、编号簿丢了按最大号重建；改名 / 换组编号不变、文件名跟着改、各处链接显示名跟着换；`[[小雾]]` 落盘变 `[[p0001|小雾]]` |
| `PointStoreTests` | 点 md 往返；摘要 ≤ 100 字；追加只动三处；`池 xxx` 幂等；分组索引带完整摘要、根索引带第一句；按组份额折叠、不截半行；改组名 |
| `PointOrganizerTests` | 挑条目；预选；`need` 只追问一次；临时号换正式号；每个被加行的点必须有 summary 或 keep；`create` 撞名变 `append`；两次不合格什么都不写 + 冷却；中途抛错前面的批保留；写一半被杀重跑不重复；不读 `windows/` |
| `OrganizeProgressTests` | 状态顺序（排队→读取→整理→写索引→完成）；条目计数；失败停在当时的批；整理记录里「进行中」能恢复成「中断可继续」并接着跑 |
| `OrganizeLogUndoTests` | 记录写在 `memory/` 外；撤回一行 / 新建点（编号作废）/ 摘要；改过的不动；「撤回过」不再被挑 |
| `CCSeedTests` | 私密三道挡 + 链接行删掉，整棵 `档案/` 搜哨兵为零；只搬三类；发编号；摘要截 100 字、`summary_by: 种子`；不调模型；`档案/` 非空拒绝 |
| `PointIndexInjectionTests` | 开头段 = [我的记忆] + [档案索引]；没档案 / 开关关时为空；缓存按楼层；零主线程读盘 |
| `MemoryBudgetAllocationTests` | **默认额度下各段输出和改之前逐字相同**（时间轴 / 上下文摘要 / 画像 / 小克的记忆 / 事实池，拿同一组夹具对比）；总数约束；事实池拿剩下的；封顶后的截法（时间轴丢最老、上下文摘要先降标题、画像截尾）；没有档案时档案索引不占额度 |
| `OrganizeScheduleTests` | 04:59 不算今天、05:00 起算；一天一次；冷却里不自动跑；手动不受限 |

**改写 / 删掉的老单测**（AUDN 退役）：`ExtractionPromptTests`（整套）、`ExtractorQuoteTests` 里 parse / execute 那几例（`testParseActionsReadsQuote`、`testAddWithoutValidQuoteBlocked`、`testAddWithValidQuoteStoresAnchor`、`testDelete*`、`testPinnedMemoryRefuses*`、`testDeleteOrderedBeforeAdd`、`testUpdateKeepsQuoteWhenNoNewQuote`；校验 / 定位 / 去重几例留）、`MV1GraduationTests` 的三个 `testBuildPrompt*`、`MV2ThrottlingTests` 的 `testRule8*` `testRule11*`。

**必须原样绿（不重录）**：`PromptRealPathGoldenTests` G1–G6、`InspectorRealPathTests`、`MainThreadIOBudgetTests`、`ToolRegistryTests`（工具 schema 金样）；记忆核心各套：`MemoryCrudTests` `MemoryFullPresenceTests` `CatalogInjectionTests` `MemoryArchiveOrderTests` `SelfMemoryInjectionTests` `SelfMemoryStoreTests` `SelfMemoryToolTests` `MemoryHealthStoreTests` `MemoryHealthWarningTests` `MemoryInjectionMeterTests` `MemoryPanelSafetyTests` `MemoryTrashTests` `MemoryRevivalTests` `MV5HygieneTests` `MemoryDayTests` `TimelineStoreV2Tests` `TimelineWriterTests` `TimelineInjectionTests` `TimelineTests` `SessionSummaryTests` `SessionCloseoutQueueTests` `MemoryRegenerationTests` `RecallToolTests` `RecallWindowSummaryTests` `CCMemorySyncTests` `MemoryTreeGroupTests` `MemoryTreeTests` `FileLibraryMemoryFolderTests` `MemoryThreeViewsTests` `MemoryTimelineListTests` `ProfileInjectionFlagTests`；设置页 `SettingsSearchTests`。

**新增金样 G7**（只新增，不动 G1–G6）：测试楼层多一份 `档案/`（两个组、三个点，带编号和摘要），录有根索引的实发 body。额度分配**不加金样**：默认值下 G1–G6 原样过就是它的证明，封顶后的形状用 `MemoryBudgetAllocationTests` 测。

⧫

## 十二、和并行单不撞

同一个工位（backend-2）里另一个 session 在做 **#093 工具抽屉**（`ChatService` / `ToolRegistry` / `ToolReplay` / `capabilitySection` / 组 prompt 旁边，`PromptRealPathHarness` 加了两行），还有 **Anthropic Opus 4.1+ / Sonnet 4.5+ / Haiku 4.5+ 只发 temperature** 那个小修（`ChatService` / `ModelLineage` / `ParamCompat` / `ParamErrorClassifier`，重录 G4）。#094 参数自适配已合。

### 1. 顺序

- **本单在 backend-2 里不动手，直到 #093 和 temperature 那单都合进 master**（每条工位同时只挂一件 WIP；现在这条分支在合并队列里）。开工第一步 `git merge master`，跑一遍「必须原样绿」记下基线。
- 本单所有提交都在它们后面；金样只**新增 G7**，G1–G6 不重录。中途 master 上 G1–G6 又被别人重录，本单 merge 后重跑，G1–G6 照样要原样绿。

### 2. 本单碰哪些文件

| 文件 | 改什么 | 和 #093 / temperature 单重叠吗 |
|---|---|---|
| **新文件**：`FactPoolExtractor.swift`、`FactPoolTrigger.swift`、`FactModelRoute.swift`、`PointStore.swift`、`PointIds.swift`、`PointIndexCache.swift`、`PointOrganizer.swift`、`OrganizeProgress.swift`、`OrganizeLog.swift`、`CCSeed.swift`、`MemoryBudgetAllocation.swift`；视图 `OrganizeRunSheet.swift` `OrganizeProgressBar.swift` `PointGroupsEditor.swift` `MemoryBudgetAllocationView.swift`；新测试 12 套 + G7 | — | 不重叠 |
| `Models/Memory.swift` | 加 3 个可选字段 | 不重叠 |
| `Services/MemoryService.swift` | 删 AUDN；`roundInputs` 拼根索引、按分配算各段额度；健康状态加一种 | 不重叠 |
| `Services/MemoryInjectionMeter.swift` | 多记几段 token 用量 | 不重叠 |
| `Services/TimelineStore.swift`、`Services/SessionSummaryStore.swift` | 额度封顶（默认不封顶 = 原样） | 不重叠（第一版写的「不碰 TimelineStore」改了：额度分配要碰，只加封顶参数） |
| `ViewModels/ConversationViewModel.swift` | `extractMemoriesIfNeeded`（`:4573` 起）换新写手；`:404` 旁加一行 CC 触发；画像那一行（`:2382`）过额度封顶 | **同一个文件**，#093 改的是 `:2470-2560`、`:3051-3442`、`:4041-4142`、`:4912-5105` 一带（master 行号），本单三处不在里面；#093 合完后 merge 一次即可 |
| `Services/SessionCloseout.swift` | `SessionCloseoutTrigger.request` 开头喊一声「今天该不该整理」 | 不重叠 |
| `Models/UsageLedger.swift` | `UsageKind` 加 `organize` | 不重叠 |
| `Views/MemoryPageContent.swift`、`MemoryPanelView.swift`、`MemoryOrganizeSheet.swift`、`MemoryTreeBrowserSheet.swift`、`PromptEditorPage.swift` | 界面（八） | 不重叠 |
| `Views/Settings/SettingsSearch.swift` + `SettingsSearchTests` | 加几条 | **#093 也加过一条**；等它合完再加，纯追加 |
| `MemoryPalaceTests/PromptRealPathHarness.swift` + `PromptRealPathGoldenTests.swift` | 加 `pointIndexFixture` + G7 | **#093 加过两行**；等它合完再改，只加不改 |

**不碰**：`ChatService.swift`、`ParamCompat.swift`、`ParamErrorClassifier.swift`、`ModelLineage.swift`、`ToolRegistry.swift`、`ToolReplay.swift`、`MetaTools.swift`、`Tools/*`、`PromptAssembler.swift`（含 `capabilitySection`）、`SelfMemoryTool.swift`、`CalendarInjection.swift`、G1–G6 金样文件。

### 3. 改不改聊天请求体

| 请求体的部分 | 本单改吗 |
|---|---|
| system 里的记忆插槽 | **只多一段 `[档案索引]`**，而且只在这个楼层有点 md 时出现；`[我的记忆]` `[关于{她}]` `[时间轴]` `[上下文摘要]` `[用户画像]` 的模板一字不改 |
| 各段装多少（额度分配） | **默认值下一个字节都不变**；只有她自己在额度分配里调了，相应那段才会变短 |
| 文件库提示 / 记忆树那句 / 〔我的记忆〕〔回忆〕说明 | 不改 |
| 〔状态〕/ [动态上下文] | 不改（〔状态〕不数 `memory/`，G1 里只有 `attachments 1`） |
| tools（remember / recall / fs_* / 抽屉） | 不加工具、不改描述、不改 schema（recall 认编号放 v4-3，Q16） |
| 采样参数 / temperature | 不碰 |

所以 **G1–G6 一行都不会变**：金样楼层没有 `档案/`，根索引为空、不占额度；额度默认值复现今天的装法（总数 10000、小克的记忆先装、事实池拿剩下的、时间轴 / 上下文摘要 / 画像不封顶）。G4 的变化（去掉 `top_p`）是 temperature 那单的。唯一新增的金样是 G7。

### 4. 新加的后台调用走不走 ParamCompat

**不走，本单也不让它走。** `ProviderRouter.sendNonStreaming`（`ChatService.swift:2079`）→ OpenAI 兼容 `sendNonStreaming`（`:886`，body 只有 model / messages / stream）/ Anthropic `sendNonStreaming`（`:1421`，model / messages / `max_tokens` / system），**没有采样参数，也不调 `ParamCompat.resolve`、不做 400 自适配重试**（#094 只接了流式和预览：`:620`、`:1158`、`:1989-2037`、`:2214-2219`）。所以 W7、走云上的 W1、试抽，发出去都不带 temperature / top_p，和 temperature 那单互不影响；被 400 拒就直接报错进健康状态（和 W2 / W3 现状一样）。走本机的 W1 不发网络请求，也不经过 `ProviderRouter`。

⧫

## 十三、风险

1. **W1 不看人设，剧情可能混进事实池。** 对冲：试抽先看；W7 写进点 md 前再过一道。
2. **事实池长得更快。** W1 只加不改、不看现有事实；`[关于{她}]` 整池按时间正序装进额度，装不下时**挤掉的是最新的**（`MemoryService.swift:139-146` + 预算截尾）。额度分配让她看得见「被截了 N 条」，但改装法是 v4-3 的事，验收里写清。
3. **根索引让 CC 笔记的摘要进了每一轮 prompt。** 以前 `memory/cc/` 只是能翻、不注入。只搬三类 + 搬前确认框列全部点名和摘要；搬完不想常驻的点，v4-4 之前只能在「文件」App 里删或请开发者删。
4. **根索引 1500 token 只够约 20 行。** 种子 60 个点以后每组只露最近几个；Q15 选了完整 100 字摘要的话只够约 7 个点。她可以在额度分配里加，但每多 1000 token 每一轮都多花一点。
5. **摘要会被反复重写。** 每次往点里加行都要交新摘要，模型可能把好摘要改坏。对冲：摘要改动能单独撤回；`keep` 允许不改。
6. **本机模型和聊天抢 GPU / 内存。** 本机 W1 只在前台、排在聊天后面串行跑；没在真机上量过。
7. **05:00 不准点。** 没有 BGTask，实际是「05:00 以后第一次有动静」；后台时间不够时整理会停在某一批前，靠「继续」接上。
8. **W7 的点分得乱**（一事两名）。对冲：点清单全喂；`create` 撞名变 `append`；撤回能修。合并两个点不在本单（要改旧文件，违反 P7，要她手动）。
9. **点 md 会越来越长。** W7 只喂最后 30 行 + 摘要；本单不分卷。
10. **SwiftData 加字段**：先例是轻量迁移；全局备份 / 同步导出是不是逐字段列的没查，漏了也只是「已整理」标记，点 md 里有 `池 xxx` 能补回。
11. **删 AUDN**：她改过提取模板的话，那份自定义不再生效。验收里写明。
12. **额度封顶截错东西**：时间轴丢最老、上下文摘要先降标题，这是推断的「最不疼」顺序，没评测台验证过（v4-5）。

⧫

## 十四、未查证

- 本机 Qwen3 4B / 1.7B 抽中文事实准不准、JSON 守不守得住——一次都没跑过（靠试抽她来看）。
- Air 上本机 4B 和聊天同时在内存里会不会被系统杀、发热多少——没在真机量。
- Mac 上 `LocalLLMService` 窗口在后台时能不能跑——没查到限制，也没实测。
- iOS `beginBackgroundTask` 给的时间够不够写完一批（一批要等一次模型回包，可能十几秒到一分钟）——没量。
- 她主楼层平时 API 回复多还是 CC 回复多——没看她的数据。
- `GlobalBackup` / `SyncEngine` 导出 `Memory` 是不是按字段列的——没读那两块代码。
- 手机上 `memory/cc/` 和 Mac 上 CC 原目录是不是一一对应——只读了 hub 代码。
- CC 笔记里 user / project / reference 三类到底哪些是「点」——只按文件名前缀数了个数，正文没读（隐私）。
- #093 合完后 `fs_read` 会不会默认收进「更多工具」——根索引头一行已经不写工具名来躲。
- 文件库「记忆」只读浏览对 `档案/人/p0001-小雾.md` 这种两层中文路径显示是否正常；`[[p0001|小雾]]` 在只读查看器里显示成什么样——没上屏看。
- 画像文件平时多长（决定「画像」那段在分段条上占多宽）——没看她的数据。
- 派单里「现有 ~2000 token 的记忆预算」：代码里默认是 10000（`MemoryService.swift:620-623`、`MemoryPageContent.swift:38`），2000 是 CLAUDE.md 里的老数；本单按 10000 做，她设备上是不是改过没看。
- W7 花费是估计；路线图的「qwen 3B」内置清单里没有，按 4B 做。

⧫

---

## 拍板

### 已定（粟粟 10-14「都按推荐」）

| # | 问题 | 定了 |
|---|---|---|
| Q1 | 整理多久一次 | ✅ 每天 05:00 以后第一次打开 / 聊天时自动跑一次 + 手动「整理」按钮；未整理攒到 100 条冒一句「该整理了」 |
| Q2 | 整理结果怎么审 | ✅ 先写进去，「本次整理」页按点列出加了哪些行、改了哪些摘要，每行可撤回 |
| Q3 | 点 md 放哪 | ✅ `memory/档案/`，每组一个子文件夹（人 / 事 / 物 / 地点 / 时间 / 项目），每层一个 INDEX.md；文件库里叫「档案」。v4-4 清单改成 8 个：时间轴 / 上下文摘要 / 窗口总结 / 档案 / 小克的记忆 / 心声 / CC 笔记 / 旧档 |
| Q4 | 根索引多大 | ✅ 1500 token（现在在额度分配里可调）；超了按组折叠；常驻、不做开关；和「目录式注入」开关无关 |
| Q5 | 本机模型怎么先试 | ✅ Mac 上 DEBUG「试抽」出对照文件；她看之前模型3号「自动」= 跟模型2号 |
| Q6 | 种子搬哪些 | ✅ user / project / reference 约 60 份机械搬、不调模型；feedback 留在 memory/cc/；不按 10 月筛 |
| Q7 | `[关于{她}]` 要不要跟着改 | ✅ 本单不改写法，v4-3 再定 |
| Q8 | CC 窗口抽不抽事实 | ✅ 抽：CC 回复落地每满 6 条新消息一次 |
| Q9 | W1 看不看人设 | ✅ 不看 |
| Q10 | 旧「整理记忆…」重名 | ✅ 改名「合并重复 + 重写画像」挪进「高级」 |
| Q11 | 撤回以后 | ✅ 标「撤回过」，自动整理不再碰 |
| Q12 | 种子按钮在哪 | ✅ CC 同步开着、同步楼层 = 当前楼层时出现，Release 也有 |

### 新的（这一版加的，第一个是推荐）

| # | 问题 | 推荐 | 备选 |
|---|---|---|---|
| Q13 | 总记忆额度分配放哪 | **A：放本单，单独一组步骤（清单 C 组），在根索引注入之后、可单独撤回；默认值逐字复现今天，G1–G6 不变** | B：另开一单，本单只做 v4-2 自己那几项 |
| Q14 | 时间轴 / 上下文摘要 / 画像默认封不封顶 | **A：默认不封顶、不进总数（= 今天），条上只显示用量；她给了上限才算进总数** | B：默认就给上限（比如各 1500），进总数——会改变今天的注入、要重录金样 |
| Q15 | 根索引里每个点放多少字 | **A：编号 + 名字 + 摘要第一句（≤30 字），完整 100 字摘要在分组索引里** | B：根索引也放完整 100 字摘要（1500 只够约 7 个点，要把额度加到 4000 以上） |
| Q16 | recall 认不认点的编号 | **A：放 v4-3（要改工具描述、重录工具 schema 金样，和 #093 的工具改动错开）；本单靠 fs_search / fs_read 找编号** | B：本单就加（recall 给 `p0001` 直接返回那份点 md） |

⧫

---

## 执行清单（一项一个 commit，可单独撤回；测试 scheme `MemoryPalaceTests`，grep 到对应 Test Suite passed；双端编译交集成区，不 push）

**A · 事实池（W1）**

- [ ] 0. 开工条件：#093、temperature 那单已合 master；backend-2 `git merge master`；跑「必须原样绿」记基线（不提交）
- [ ] 1. `Memory` 加 `occurredDay` / `organizedAt` / `organizedNote`；`UsageKind.organize`；健康状态新增 `.organize`。测：`MemoryCrudTests`、`MemoryHealthStoreTests`
- [ ] 2. 模型3号设置 + `FactModelRoute` + 本机调用适配；「记忆模型（模型2号）」改名、去掉本机。测：`FactPoolModelRouteTests`
- [ ] 3. W1 新提示词 + 解析 + 只加写池；`extractMemoriesIfNeeded` 换新写手、失败下一轮补；删 AUDN 及只测它们的单测；提示词编辑页换模板。测：`FactPoolExtractorTests` + 改写的老套件
- [ ] 4. CC 窗口 W1 触发 + 水位线文件。测：`FactPoolTriggerTests`
- [ ] 5. 试抽（DEBUG + Mac）。测：对照文件格式（假 caller）

**B · 档案（点 md、编号、整理、种子、注入）**

- [ ] 6. 编号：`编号.md` 发号、作废、重建；文件名 `<编号>-<点名>.md`；改名 / 换组 / 链接显示名。测：`PointIdTests`
- [ ] 7. `PointStore`：点 md 格式（id / summary / summary_by）、分组目录 + `分组.md`、追加只动三处、`池 xxx` 幂等、两层索引重建（分组完整摘要、根第一句）、按组份额折叠。测：`PointStoreTests`
- [ ] 8. 种子：`SeedSource.eligible` 三道挡 + 链接行删除 + 机械搬 + 发编号 + 摘要截 100 字 + 确认框清单。测：`CCSeedTests`
- [ ] 9. W7 `PointOrganizer`：挑条目、预选、一次追问、临时号、操作单校验（含 summary 必交）+ 落盘、标条目、健康 + 冷却、幂等。测：`PointOrganizerTests`
- [ ] 10. 进度：`OrganizeProgress` 状态机 + 每批写进整理记录 + 后台时间 + 中断可继续。测：`OrganizeProgressTests`
- [ ] 11. 整理记录 + 撤回（行 / 新建点 / 摘要；改过的不动；「撤回过」）。测：`OrganizeLogUndoTests`
- [ ] 12. 触发：`SessionCloseoutTrigger.request` 开头判「今天整理过没」；「该整理了」阈值。测：`OrganizeScheduleTests`
- [ ] 13. 根索引注入：`roundInputs` 开头段 = [我的记忆] + [档案索引]、按楼层内存缓存 + 后台刷新 / 预热。测：`PointIndexInjectionTests`；G1–G6、`InspectorRealPathTests`、`MainThreadIOBudgetTests`、`ToolRegistryTests` **不重录、原样过**
- [ ] 14. 金样 G7：harness 加 `pointIndexFixture`（只加），录 G7。测：G1–G7 全过

**C · 额度分配（Q13=A）**

- [ ] 15. `MemoryBudgetAllocation`：各段额度键、总数约束、事实池拿剩下、默认值 = 今天；`roundInputs` 按它算小克的记忆 / 档案索引 / 事实池。测：`MemoryBudgetAllocationTests`（默认逐字相同）+ G1–G6 原样过
- [ ] 16. 封顶接到时间轴 / 上下文摘要 / 画像（默认不封顶）+ `MemoryInjectionMeter` 记各段用量。测：`MemoryBudgetAllocationTests`（封顶截法）、`TimelineInjectionTests`、`SessionSummaryTests`、`MemoryInjectionMeterTests`；G1–G6 原样过
- [ ] 17. v4-2 自己的额度项（点清单 / 打开的点 / 一批事实 / 批数 / 每组份额）接进 W7 和根索引。测：`PointOrganizerTests`、`PointStoreTests` 补例

**D · 界面**

- [ ] 18. 进度条组件（薄荷填充、浅灰底、无蓝黄）+ 记忆 app「事实池」组（改名、标记、未整理数、整理按钮变进度条）+ ⋯「整理」「本次整理」「档案」+ 本次整理页。测：`MemoryPanelSafetyTests`、`MemoryThreeViewsTests`
- [ ] 19. 设置 → 记忆：事实池开关文案、模型3号、档案小节（今天的进度、自动整理开关、种子入口）、试抽；设置格健康两行 + 档案分组编辑；旧整理改名挪位；记忆树显示名。测：`MemoryTreeGroupTests`、`MemoryHealthWarningTests`
- [ ] 20. 「额度分配」页：总记忆分段条（用了 / 分到、拖动或填数、总数约束、被截了标红）+ v4-2 自己那几项；替掉单独的「记忆预算」数字框；设置搜索。测：`SettingsSearchTests`、`MemoryBudgetAllocationTests` 补约束例

**E · 收尾**

- [ ] 21. 全部「必须原样绿」+ 新套件跑一遍；双端 `build-for-testing`（mac `MemoryPalaceTests`、iOS `MemoryPalaceIOS` + iOS 26 模拟器，只认 `TEST BUILD SUCCEEDED`）交集成区
- [ ] 22. 复盘 `docs/review-memory-v4-2.md`、`docs/now/backend-2.md`、验收 `~/Desktop/cc-rp/记忆系统/花园记忆-v4-2-验收.md`（人话、只用 v4 名字：先开总开关和自动整理；看种子清单再搬；聊几轮看事实池是干句子；点「整理」看进度条走完、看本次整理、撤回一行；点 md 有编号和摘要；prompt-完整里有 [档案索引]；额度分配条默认和以前一样、调小时间轴看它变短；Mac 上试抽）、说明书同步或写「不涉及」
