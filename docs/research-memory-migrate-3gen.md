# research · 记忆三代旧数据搬成 v5 的样子

> 2026-10-16 · backend-2（HEAD = master f6a3443a，v5 刚合）· 只读代码和文档，没碰任何真实数据。
> 需求（粟粟 10-16）：「现在有三代上下文 / 窗口总结，意思都不一样，能不能搬迁到现在的位置」；补充：「这个每个对话里放A2和A3啊？A2还是之前那个，一点描述+原文，然后有很多次啊 A3就是再把A2压一遍啊？？」
> 规格真相源：`~/Desktop/cc-rp/记忆系统/记忆系统v5.md`。计划见 [plan-memory-migrate-3gen](plan-memory-migrate-3gen.md)。

## 0. 时间线（决定了每一代的量）

| 日期 | 事 | 写出来的东西 |
|---|---|---|
| 10-10 以前 | 改造前 | `memory/summaries/` 一个窗口一份累计摘要（第一代） |
| 10-10 | 第三刀 #066 | `memory/sessions/` 分段：压缩段（带【待续】、常以「这个窗口」开头）+ 收尾段 kind=closeout（第二代 · 上半） |
| 10-11 | v4-1 | 收尾不再写 `sessions/`；`windows/` = A2 各段抄一份 + 最后那截（≤150 条）收尾段（第二代 · 下半）；时间轴 v2；DEBUG「按新规则重写」 |
| 10-14 | v4-1 急修 | 重写报「无法解析响应」修了，等她再点一次（`docs/now/backend-2.md`）；v5 规格写「v4-1 重新生成粟粟已真机验过」→ 按「她主楼层跑成过一次」算，但不依赖它 |
| 10-15 | v5（f6a3443a） | A2 收下尾段 `tail=1`；A3 = 读 A2 全部段 + 尾段真·再压约 300 字，`windows/` 只剩一段；待续单独存 `memory/pending/待续.md`；C2 碎片池 |

第三刀到 v4-1 只隔一天，所以「第三刀式压缩段」量很少；大头是第一代累计摘要（10-10 前所有在 app 里聊长过的窗口）和第二代 `windows/` 抄本（10-11 到她装上 v5 之间收过尾的窗口）。

## 1. 三代各自存在哪、长什么样

### 第一代 · 改造前累计摘要

- 位置：`memory/summaries/{convId前8}-{标题slug}.md`（`SummaryFileStore.swift:5`、`:12-18`）。
- 格式：frontmatter `conversationId / coveredCount / updatedAt`，正文一整块摘要（`SummaryFileStore.swift:79-92`）。没有段、没有标题、没有【经过】【原话】，写法是改造前的（「用户 / AI」那套口吻的源头）。
- 停写，只读。读它的唯一入口是 `SessionSummaryStore.legacySeed`（`SessionSummaryStore.swift:137-144`）：当成 `kind=legacy`、标题「改造前的累计摘要」、`from=0 to=coveredCount`、没有 `lastNodeId` 的**第 0 段**。
- 两种存在形态：
  1. 已经被抄进 `sessions/`：窗口 10-10 以后压缩 / 收尾过一次，`loadOrSeed`（`:127-134`）把第 0 段带进去存盘了。
  2. 只在 `summaries/`：窗口 10-10 以后再没写过。读的时候现场当第 0 段（注入 `ContextSummarizer.load` `ContextSummarizer.swift:21-25`、组 prompt `ConversationViewModel.swift:2388`、recall `RecallTool.swift:198-199` 都走 `loadOrSeed`）。**窗口总结格列表不读 `summaries/`**（`WindowSummaryReader.listAll` 只合 `windows/` + `sessions/`，`WindowSummarySheet.swift:26-34`），所以这类窗口在记忆 app 里看不见。

### 第二代 · 上半：v4 / 第三刀的 `sessions/`

- 位置：`memory/sessions/{前8}-{slug}.md`，格式 = frontmatter + 每段 `## 时间 · 标题` + `<!-- seg kind=… from= to= start= end= last= [tail=1] -->` + 正文（`SessionSummaryStore.swift:220-276`）。
- 里面混着三种老段：
  - `kind=legacy`：第 0 段（第一代抄进来的），**v5 照样要**。
  - `kind=rolling` 第三刀式：正文带【待续】（`segmentText` `:165-171` 会把 pending 拼进去），常以「这个窗口」开头。v4-1 重写过「起点以后」的；起点以前的、或重写时这个窗口失败了（`MemoryRegeneration.swift:256-275` 整份保留原文件）的还在。**判别**：`pending` 非空（v4-1 起的 W2 提示词写死「不写待续」，`SessionSegmentWriter.swift:68`，解析时也丢掉【待续】`:101-105`，所以新写的段 pending 一定是空）。
  - `kind=closeout`、没有 `tail=1`：第三刀收尾段（老收尾段）。v4-1 起收尾不再写 `sessions/`，所以它们只出现在「没被 v4-1 重写过的窗口」：起点以前、重写失败的窗口、**没跑过重写的楼层**（重写只跑当前楼层，`MemoryRegenerationSection.swift:116`）。
- 同一文件格式 v5 也在用：v5 的 A2 = legacy + 新式 rolling + 一段 `kind=closeout tail=1` 尾段（`:20-22`、`:224`）。

### 第二代 · 下半：v4-1 的 `windows/`

- 位置：`memory/windows/{前8}-{slug}.md`，格式同上，头上多 `closedThrough`（`WindowSummaryStore.swift`；文件头注释 `:3-5` 还写着 v4-1 的「抄一份 + 最后那段」，已过时）。
- 内容 = A2 各段原样抄一份（kind 是 legacy / rolling）+ 收尾写的最后那截（kind=closeout，`from` = 水位线、最多 150 条）。所以 v4-1 的 `windows/` 一般是**多段**。
- 判别 v4-1 / v5：v5 一定是**一段、kind=closeout、from=0**（`SessionCloseout.recompressWindow` `:954-968` → `WindowSummaryWriter.write` `WindowSummaryWriter.swift:64`）。v4-1 有多段，或只有一段但 `from>0`。**分不开的一种**：v4-1 的短窗口（没压缩过、不到 150 条）只有一段收尾段且 `from=0`——形状和 v5 一样。补一条：v5 收尾在 A2 开着时会同时写尾段，v4-1 时代 `sessions/` 没有尾段 →「`windows/` 一段 from=0 但 `sessions/` 里没有写到同一条的尾段」就当老的。

### 第二代 · 时间轴（参考，不是她点名的「三代」）

- `memory/timeline/{yyyy-MM}.md`，v1 老格式（`day == nil`，一次收尾一条大段话）和 v2（`v=2 day= last=`，一天 × 一窗口一条，话题行 + 待续）混存（`TimelineStore.swift:3-27`）。
- v5 的 A4 条目格式和 v2 一样，差别只在待续：v5 写手传 `pendingProfileId`，待续进 `PendingStore`、条目里 pending 为空（`SessionCloseout.swift:1036-1045`）。

### 第三代 · v5 目标形状（每个窗口）

| 地方 | 内容 |
|---|---|
| `sessions/`（A2） | 第 0 段（有第一代的话）+ 正式段（`标题：` /【经过】≤300 字 /【原话】关键原句逐字，`SessionSegmentWriter.swift:63-68`）+ 一段尾段 `tail=1`（正式段水位线之后到最新，≤150 条，每次收尾整段重写，`SessionCloseout.swift:930-951`） |
| `windows/`（A3） | 一段：读 A2 全部段 + 尾段（老收尾段不算）+ A2 没盖到的原文，压约 300 字（`:954-968`，字数 `MemoryWriterSettings.a3Chars` 默认 300） |
| `timeline/`（A4） | v2 条目，pending 空；待续在 `pending/待续.md` |

她那句「A2 一点描述 + 原文、有很多次；A3 再把 A2 压一遍」和代码一致：A2 每段 = 标题 +【经过】（描述）+【原话】（挑出来的几句原话逐字抄，不是全文），一个窗口聊长了就一段段往后加；A3 只有一段，输入就是 A2 全部段。

## 2. 谁在读，v5 遇到老格式怎么办

| 读者 | 读哪 | 遇到老格式 |
|---|---|---|
| 组 prompt 注入 A2（`ConversationViewModel.swift:2384-2392`，【开窗口】A2 勾） | `sessions/`，没有就 `summaries/` 现场当第 0 段 | `injectableSegments`（`SessionSummaryStore.swift:175-181`）**所有 closeout 都不注**（老收尾段、尾段一样）；legacy、rolling 照注——第三刀式 rolling 的【待续】会跟着注进去 |
| 历史窗口锚定 `compressedCount` | `sessions/` | 照读 |
| A2 写手 `compress` / `compressCC` | `sessions/` | `coverage`（`SessionCloseout.swift:700-704`）不信老收尾段，它盖的那截照样压成正式段；老收尾段本身**留在文件里不删** |
| A2 尾段 `writeTail` | `sessions/` | 只换 `isTail` 那段（`:947`），老收尾段不动 |
| A3 `recompressWindow` | `sessions/` | 输入只要 `kind != closeout || isTail`（`:958`）→ **老收尾段不进 A3**；它盖过、又没被正式段盖到的那截，只剩「水位线后最多 150 条原文」能进 A3 |
| A4 起点 `timelineStart` | `timeline/` v2 最新一条；**没有 v2 条目时退回老收尾段的 lastNodeId**（`:988-1003`、`:1056-1059`、队列 `:634-636`） | 老收尾段被拿掉、又没有 v2 条目 → 起点退回「倒数 150 条」，会和 v1 老条目重叠 |
| 记忆 app 窗口总结格 列表（`MemorySessionsView.swift:132-145`、`:23-34`） | `windows/`，没有就 `sessions/` | 「记了 N 段」= 那份文件的段数：v4-1 抄本 = A2 段数 + 1；v5 = **1**；只有 `sessions/` 的 = 含老收尾段 / 尾段的全部段数。**口径三种，对不上** |
| 窗口总结详情 `WindowSummaryPage`（`WindowSummarySheet.swift:55-117`，窗口总结格、时间轴条目、对话 ⋯「窗口总结」共用） | `WindowSummaryReader.load`：`windows/`，没有就 `sessions/` 整份（`:13-17`） | v5 窗口只看得到一段 300 字，**看不到 A2**；头上写「分 N 段记下」（`:83`）。第 0 段有单独样式（`:126-130`），尾段 / 老收尾段没有标 |
| 对话 ⋯「上下文摘要」（`:181-`，`loadContext` `:20-23`） | `sessions/` 去掉所有 closeout（`:47-49`） | **v5 尾段也被藏了**（尾段 kind=closeout）——和 v5「尾段属于 A2」不一致 |
| 「正在记」提示（`MemorySessionsView.swift:45-50`、`:154-155`、`:228`） | — | 还在读 `mem_content_summary`（A2 写入键）+ `mem_content_timeline`，文案「上下文摘要和窗口总结」——v5 收尾看的是 A3 / A4（`SessionCloseout.closeoutEnabled` `:129`），A3 键是 `mem_write_a3`（`MemoryWriterSettings.swift:79`、`:93`）。A2 关、A3 开时这行会说错 |
| recall 给编号（`RecallTool.swift:193-216`） | `windows/`，没有就 `sessions/` + 第 0 段；待续读 `PendingStore`，没迁移读条目老字段 | 照读。v5 窗口 recall 只拿到 A3 一段（「共 1 段」），v4-1 抄本拿到 A2 标题 + 最近两段——v5 本来的设计，不在本单 |
| 文件库「记忆」 | 三个文件夹原样 | 照显示 |

结论：v5 对三代都**能读不会坏**，问题只是「同一个格子里三种口径」+ 老收尾段一直挂在 `sessions/` 里 + 第一代窗口在 app 里看不见。

## 3. 现有「按新规则重写」做了什么、缺什么

`MemoryRegeneration.swift` + `MemoryRegenerationSection.swift`（DEBUG，设置 → 记忆 最底下「高级 · 重新生成（调试）」，挂在 `MemoryPageContent.swift:115-118`）。

**做了的（能直接复用）**
- 备份：三个文件夹拷进 `.partial-*`，逐个比大小，写 `manifest.json` 再改名（`:181-217`）；备份放 `memory/` 旁边（`:63-65`）。
- 范围：「记忆从哪天开始」；没设从第三刀最早一段算（`:93-97`）。窗口 = 时间轴里有起点以后条目的 + `sessions/` 有起点以后非 legacy 段的（`:100-109`）。
- 每个窗口：`work`（`:124-145`）丢掉起点以后的全部 rolling + 全部 closeout，从头按 W2 写到原锚点（API）/ 写完了的份（CC），不套 150 上限；然后 `composeWindowSummary`（v5 后 = 尾段 + A3 重压，`SessionCloseout.swift:971-982`）；然后时间轴按天重写（`:311-353`）。
- 全写进暂存目录，**全部成功才整体替换**（`:225-306`、`:369-392`）；断网 / 被掐 / 写盘失败整个停，原件不动。
- 跑之前 `setRegenerating(true)` + `waitUntilIdle()`（`MemoryRegenerationSection.swift:144-145`）：日常 A2 / 收尾 / CC / 现在写都停（`SessionCloseout.swift:189`、`:307`、`:418`、`:728`、`:876`）。
- 恢复：核清单 → 现在的挪进 `回滚前-*` → 拷回（`:398-430`）。

**缺的 / 和 v5 对不上的**
1. **全量重写，不分新旧**：起点以后所有 rolling 都重写，包括 v4-1 / v5 已经合格的段——白花钱。搬迁只需要动「老」的。
2. **一个 caller 打天下**：用记忆模型、账本记 `.summary`（`MemoryRegenerationSection.swift:16-25`，`SessionSegmentWriter.modelCaller` 默认 kind `:198`）。v5 每个写手可以单选模型（A7）、账分 `.summary / .windowSummary / .timeline`（A11）。
3. **时间轴待续绕过 `PendingStore`**（`MemoryRegeneration.swift:333` 没传 `pendingProfileId`；review-memory-v5-settings 第 14 条）：楼层迁移过待续以后，注入 / recall 读的是 `PendingStore`，重写进条目的待续等于丢了。
4. **全部成功才替换**：几十上百个窗口跑到一半断网，前面花的钱全白花，原件不动。v4-1 窗口少还行，搬迁要跑「全部窗口」不合适。
5. **范围漏两类**：只有 `summaries/` 的窗口（不在时间轴、没有 `sessions/`）不在 `windowIds` 里；`windows/` 存在但 `sessions/` 没有起点以后段的也可能漏（靠时间轴兜）。
6. **起点以前的老收尾段**：`work` 的 `keep` 只留 legacy 和「起点以前的 rolling」（`:128`），在范围内窗口里起点以前的老收尾段被直接拿掉，又不能重写（起点以前的消息不给写手）→ 那截从 `sessions/` 消失，只在备份里。
7. **恢复会误删新文件夹**：`restore` 把 `folders` 里**所有现存**文件夹挪开，只拷回清单里有的（`:410-418`）。如果给 `folders` 加 `pending` / `summaries`，再恢复一份 v4-1 老备份（清单没有它们）→ 这两个文件夹会被挪走不回来。
8. 备份列表只认 `v4-1-*` / `回滚前-*` 前缀（`:78`）。
9. 只有一行「正在重写…」，没有进度、没有估钱、没有估时（v4-1 复盘技术债）。
10. 只跑当前楼层；总开关关着按钮灰（`MemoryRegenerationSection.swift:65`）；不看 A2 / A3 / A4 单项开关（直接调写手，不走 `gated`）。

## 4. 待续、C2 和搬迁的关系

- **待续**（`PendingStore.swift`）：`memory/pending/待续.md`，第一次收尾写时间轴 / 打开设置记忆页 / 待续页 / 时间轴格时迁移一次——每个窗口只拆**最新一条**时间轴条目里的待续成「没做完」（`:160-183`），之后 A4 只往里加，同窗口一字不差、还没做完的不重复（`:187-201`）。迁移标记在 UserDefaults `mem_pending_migrated_<楼层>`（`:53-57`），内存里有缓存 + 主线程快照（`:46-80`），`forget` 清缓存（`:68-71`）。
  - 搬迁**不写 A4** 时和待续无关，不会重复。
  - 第三刀式 rolling 段里的【待续】：v5 规格待续只来自时间轴；v4-1 验收时已经认定那些「仍未问到」「上段遗留」是噪音。重写这类段时它们会消失，不该搬进待续本子。
  - v4-1 抄本 / 第一代摘要都没有结构化待续。
  - 如果搬迁要给「从没有 v2 条目」的窗口写时间轴：必须走 `pendingProfileId`（只加、去重），而且 `PendingStore` 直接写活目录、不进暂存目录——备份要带上 `pending/`，恢复后要 `forget` 缓存。
- **C2 碎片池**（`FragmentPool.swift`；API 每 N 轮、CC 每满 6 条，`SessionCloseout.swift:1191-1234`，水位在内存 `FragmentCCWatch`）：只读新消息，不读 A2 / A3 / A4，不产生消息。搬迁不碰它、它也不碰搬迁的文件；**不会重复**。代价：老对话不会补碎片（C2 只从上线起记），档案 C 里是旧提取写的条目，原样。要给老对话补碎片是另一单。
- **画像**：v5 已下线，文件不动，与本单无关。

## 5. 风险

| 风险 | 说明 |
|---|---|
| 数据量 | 范围 = 起点以后有消息的窗口。主楼层 v4-1 重写过，A2 大多已合格，主要花在每窗口 2 次（尾段 + A3）。**没跑过重写的楼层（CC 楼层等）** 老收尾段多，A2 要补写的截数按 60 条一份算，CC 窗口动辄上千条 → 几十次调用一个窗口 |
| 花费 | 每次调用输入 ≈ 系统提示（~600 字）+ 人设 + 上一段全文 + ≤60 条消息（每条截 1500 字，`SessionSegmentWriter.swift:37`）；A3 输入 = A2 全部段 + ≤150 条原文。输出按 1500 token 估（预算闸同口径 `:207`）。格式不对多一次。写入预算不查（手动，同 v5 Q10），全局预算闸照查——跑到一半被闸拦下会一窗口接一窗口「写手跳过」 |
| 时长 | 串行、非流式副模型，一次 10–40 秒量级（没测过她的模型）。几十个窗口 = 十几分钟到一小时 |
| 中途失败 | 断网 / 切后台（iOS 挂起后请求断）/ 被杀。现有设计全成才换 → 白花；`regenerating` 只在内存，被杀后日常写手照常、暂存目录残留 |
| 并发收尾 | 跑的时候日常写手停（已有）。她边跑边聊：这个窗口的新消息要等搬完后下一次收尾才进尾段 / A3（`wouldRegress` 保证不倒退）；C2 照跑，不冲突 |
| CC 楼层 | 是不是 CC 窗口按主线最后一条 assistant 有没有 `ccMessageId`（`SessionCloseout.swift:1092-1094`）；A2 只写满 60 条或已过去的天，当天剩的进尾段；不推 `compressedCount` |
| 起点以前 | 起点以前的消息不交给写手（`MemoryStartDay.swift:3-5`、`:37-40`）。整窗口在起点以前 → 不能重写；部分在起点以前 → 那截的老收尾段没法重写（见 §3-6） |
| 时间轴锚点 | 拿掉老收尾段、窗口又没有 v2 条目 → 下次 A4 从倒数 150 条写，和 v1 老条目并排（§2 A4 行） |
| 恢复丢新写的 | 恢复 = 整个文件夹换回备份那一刻；搬完以后日常写的 A2 段 / A3 / 时间轴一起撤回（v4-1 就是这样） |
| 楼层 | 现有按钮只跑当前楼层；人设、写手称呼按楼层取（`SessionCloseout.Context` `:35-45`） |
| 开关 | 她截图「正在记」显示写入都关着。A2 / A3 写入开关关着时日常不会更新尾段 / A3，搬完的就停在搬完那一刻；A2 进不进 prompt 看【开窗口】A2 那一勾（`mem_open_a2`，v5 拆键时按老值定下，`MemoryService.swift:368-376`），A3 不注入 |

## 6. 现成可测的东西

- 测试：`MemoryRegenerationTests`、`WindowSummaryReadTests`、`WindowSummaryRecompressTests`、`RecallWindowSummaryTests`（scheme `MemoryPalaceTests`，module「记忆花园」）。
- 纯函数可直接复用：`pendingRanges(capFirst:)`、`ccCompressRanges(capFirst:)`、`chunks`、`writeContextParts`、`composeWindowSummary`、`timelineParts`、`copyFolders / makeBackup / swap / restore`。

## 7. 没查证

- 她各楼层实际有多少窗口、多少条消息、哪些楼层跑过 v4-1 重写、10-14 急修后那次重写到底成没成（没看她数据，按规矩不看）。
- 她选的 A2 / A3 模型单价和平均响应时间。
- iOS 挂起后非流式请求的具体表现（多半 `networkConnectionLost`，按「断网」处理）。
- `MemoryWriteLog` 的日志条目能不能塞「搬迁」这种非写手事件（本单不打算塞）。
