# review · 记忆 v5 设置页 + ABC 写手（plan-memory-abc 第三版）

> 规格 `~/Desktop/cc-rp/记忆系统/记忆系统v5.md`；计划 [plan-memory-abc](plan-memory-abc.md)；小样 [design-memory-abc-settings.html](design-memory-abc-settings.html)。
> backend-2，10-15。逐项改动 / commit 分组见 scratchpad `v5-items.md`（交付时贴进合并说明）。

## 做了什么（按执行清单）

- **0.1 / 0.2**：关着灰字不红、`compress` 查开关；导入后总开关两份对齐（这两项单独有补丁可先合）。
- **A 页面**：骨架 `MemoryPageLayout` 按她拖的顺序锁住（`SettingsSkeletonTests`）；顶上五行；写入十行（一行一个编号、整行进二级页）；A2 / A3 开关拆开（`mem_write_a3`）、B4 开关（`mem_write_b4`）；编号二级页同一模板；每项单选模型；触发三选一 + 静默 / 新建对话都改 12 小时；对话 ⋯「现在写」；【开窗口】二级页（新键没写过 = 老值，一次性迁移把老值定下来）；用途拆分（`.windowSummary`、标签「时间轴」「碎片池」）；`BudgetSection` 能接不同的账；写入预算（关闭 / 周 / 日、超了停、手动不看）；复杂度滑条；设置搜索 + `ConfigSchema`。
- **F 日志**：`memory/log/写入日志.jsonl`，在 `MemoryHealthStore.recordOK / recordError` 顺手追加（带这次调用的花费，`@TaskLocal` 计费表）；日志弹层 + 状态卡 ⓘ + 每行跳到最近一条。
- **G 画像下线**：停写（做梦调用 / 整理里的做梦）、停注入、藏界面（设置三处、记忆 app 首屏卡、整理弹层、Lite 页、状态卡行、做梦提示词路由）。画像文件和 `mem_*_profile` 键不动。
- **B C2**：`Memory` 加四个可选字段（备份文档同步加）；模型路线默认本机、没装 / 后台退提取模型；C2 页下载行 + 一次性提示；严格 JSON 写手换掉 AUDN（旧提示词 / 解析 / 执行和只测它的单测同时删）；CC 窗口每满 6 条；拒收数。
- **C 待续**：`PendingStore`（`memory/pending/待续.md`）+ 一次性迁移；A4 只加；注入 / recall / 记忆 app 换来源（没迁移照读老字段）；`pending_notes` 工具；设置 + 记忆 app 同一份列表。
- **D A 线**：A2 收下尾段（`tail=1`）；A3 每次收尾真·再压约 300 字。

## 和 plan 不一样的地方

1. **记忆日志是弹层，不是推页**：要带「跳到哪一项最近一条」这个参数，mac 设置窗走值驱动路由（`SettingsRoute` 是 String 枚举）带不了参数；弹层两端一样。
2. **「C2 默认用本机模型，去下载 ›」只弹一次的提示**：是聊天里的一行提示（`TransientNotice` 不能点，改它要动 CardFlowView，计划没列），写清去「设置 › 记忆 › C2 碎片池」下载；C2 那一行的副标题同时写「本机没下 · 先用 X」。
3. **写入预算在主页是一行 + 二级页**（按 plan 第二节表格）；小样里是整块控件内嵌在主页，390 宽太挤，没照小样内嵌。
4. **开窗口页**：不列 A3、不单列「↳ 没做完的待续」一勾（plan：A3 不注入不列；待续只带没做完是规则），待续在 A4 下面一行说明。页脚按 Q3 写「每一轮都带进去（所有窗口）」，不用小样「新开一个窗口时」的说法。
5. **状态卡**：总开关关着时整卡一行「总开关关着 · 都暂停了」（小样）；单项关着才是各行灰字（0.1）。红的那行从 0.1 的「点开看原因」换成「点了跳日志」（F2），原因 / 连续几次 / 模型放在编号页状态行。
6. **复杂度**：副标题「中 · 开 5 项」+ 刻度，没做小样那行「开着：A2 上下文摘要、…」（390 宽太长）。
7. **默认值里 plan 没定的**：A2「停 N 分钟」默认 60 分钟；A3 / A4「每 N 回合」默认 30（v5 原话的例子）；「停 N 分钟」步进 30 分钟、30 分钟～24 小时。
8. **D1 尾段**：用 `kind=closeout` + 多一个 `tail=1`（老版本读到当老收尾段，不注入）；尾段跟着 A3 那一步写，A3 关着就没有尾段；尾段写不成时 A3 用原文那截照样压。收尾因此多一次模型调用（尾段 + 重压 + 时间轴 = 三次）。
9. **C2 去重**：只挡一字不差的（plan 原文）；旧 AUDN 的向量近似强化随旧代码删了，没搬到 C2。
10. **C2 · CC 水位线只在内存里**：第一次见到一个 CC 窗口先记位置不回头补，重启后最多漏不到 6 条（不重复记）。
11. **画像下线删得比「藏」多**：`MemoryProfileSheet`、`MemoryOrganizer.rewriteProfile`、`DreamConsolidator.dream / shouldDream / 提示词`、`ProfileFileStore`、`PromptEditorPage.dream` 和 `.dreamPrompt` 路由都没人用了，按「自己造成的废代码自己清」删掉；`PromptAssembler` 的「用户画像」插槽代码保留（是装配器能力，测试在用，只是没人再传画像）。整理记忆从「重写画像 + 合并」变成「只合并」。
12. **待续迁移触发点**：第一次收尾写时间轴、打开设置记忆页、待续页、记忆 app 时间轴格时（都在后台，只跑一次）。组 prompt 不触发迁移，没迁移的楼层照读老字段。
13. **档案 / {助手}的记忆「N 条 ›」**：做成最简单的列表页（档案：看 / 搜；B4：看 / 点开改，复用 `SelfMemoryEditSheet`），没有新功能。
14. **重新生成（DEBUG）**：A3 也走「尾段 + 重压」；它的时间轴照老样子把待续存进条目（不进 `PendingStore`），写入预算不查。
15. **设置搜索**：挪进二级页的行（提示词、间隔、上限……）搜到的是主页上那一行的锚点（`leaf-mem-w-c2` 等），不直接推进二级页（plan §十七 没查的那条，确认推不进去）。

## 边界情况

- 写入预算查账要读整份 `usage.jsonl`（后台）：周期关着不读；开着时每次后台写都读一遍，账本很大时多几毫秒到几十毫秒。
- `UserDefaults.didChangeNotification` 驱动状态卡灰 / 不灰：只比对 4 个布尔，变了才刷。
- 「现在写」时窗口正被巡检占着：不排队，提示「后台正在写这个窗口，稍后再点」（astra #10 起；原先误报「没有要写的」）。
- A2「停 N 分钟」的快照只在内存里，app 被杀就丢，等下一轮回复重新记。
- C2 本机路线：app 进后台被停 = 不算失败，下一轮重来；本机模型守不守得住 JSON 表没实测（拒收会在日志 / C2 页看到）。
- 待续：同一窗口一字不差、还没做完的不重复加；改字压成一行。`pending_notes` 只认编号，不认文字。
- 日志：30 天 / 1000 条，每次追加时整份读改写（≤1000 行，后台队列）。

## 与下一模块交互的风险

- **请求体**：默认下只多 `pending_notes` 一个工具（+ 系统提示「当前能用的工具」那段跟着多一行）；开着画像注入的人 `[用户画像]` 段没了。金样只重录了这两处（见下）。
- **【开窗口】拆键**：靠 `migrateV5SplitIfNeeded` 在启动时把老值定下来；之后关 A2 写入不再连带关注入 / 锚定（这是 plan 要的，但和以前的手感不同）。
- **`tail=1` 是文件格式的一处扩展**：老版本 app 读到只当老收尾段（不注入），不会坏；但老版本收尾时会把它当老收尾段。
- **v4-2 召回侧（PageIndex）/ C3**：C2 现在只加不整理，档案会一直长；C3 做好之前没人合并（整理记忆还能手动合）。
- **纸条（新开窗口当场选带什么）**：要每个对话存一份勾，SwiftData 新字段，留给以后。

## 技术债务

- 组 prompt（主线程）只读待续缓存、不碰盘：启动时后台预热当前楼层，切楼层后第一次组 prompt 没热好就这一轮按条目老字段带待续（后台顺手读进缓存，下一轮就对了）。`MainThreadIOBudgetTests` 的夹具没有 v2 时间轴条目，量不到这条路。
- A2「停 N 分钟」的快照带着那一轮的 ctx（模型 / 人设），到点前改了模型这次还用旧的。

- `DreamConsolidator.consumedIdsFromCandidates / graduateConsumedMemories` 是改造前就没人调的毕业 helper（只有 MV5HygieneTests 测它），没删，提一嘴。
- `MemoryHygiene.sweep` 去掉做梦后已经没有 await，留着 `async` 没改签名。
- `PromptAssembler` 里 `userProfile` 参数、`.userProfile` 段来源没删（见上 11）。
- 预算控件的 80% 琥珀色只给全局那份留着（写入预算传 `warnAt80: false`，避免黄色）。
- mac 上「写入」行里的开关嵌在 `NavigationLink(.plain)` 里，点开关会不会顺带推页：没在 mac 上点过。

## 验证

- mac + iOS build-for-testing 都是 `** TEST BUILD SUCCEEDED **`（iOS 只编，没开模拟器）。
- 定向 72 套 597 测全过（新加 15 套 + 记忆 / 时间轴 / 收尾 / recall / 自记 / 工具 / 金样 / 检查器 / 主线程读盘预算 / 设置搜索 / 请求体相关老套件）；前一遍唯一一例红是 SessionSummaryTests 里「收尾提示词含『窗口总结』」的期望（D1 后那截是 A2 尾段），改期望后整组复跑全过。BudgetGateTests 单跑 38 过。
- 金样：G1–G6、G8 重录，每份只多一行 `- pending_notes — …`（〔当前能用的工具〕）；工具 schema 金样只新增 pending_notes，别的 0 变化。`MainThreadIOBudgetTests` 删画像两项后照过。
- 开工前请 opus 子 agent 只读审了一遍 diff：抓到 `SessionSummaryStore.render` 里 `## ` 少了空格（会让新写的段读回来全丢，已修）、PendingToolTests 少 `@MainActor`、两处老测试期望没跟着改，都修了。

## 说明书

`manual/facts/modules/memory-settings.md` 新建（事实层）；`npm run check / rewrite / build` 没跑（需要 Opus 改写，留给合并后）。

## astra 裁决（10-15，astra 12 条 + 车头 1 条，全改）

1. [高] 写手中途关开关：`SessionSegmentWriter.gated` 每次调模型前后复查总开关 + 这一项（返回 nil = 跳过，调用方拿到结果到落盘之间不隔 await，后查即落盘前查）；`noteFailure` 开关已关不记失败；C2 走同一个闸。测试 `SessionCloseoutQueueTests.testSwitchOffDuringCallStopsWithoutFailure` / `testSwitchOffBeforeRetryAndOnErrorNotCounted`、`MemoryHealthWarningTests.testC2SwitchOffDuringCallDiscards`。
2. [高] 旧快照覆盖新尾段 / A3：巡检的 `closeout` 占到窗口后按当前路径重读（`currentPath`）；窗口总结 / 尾段已写到的那条不在快照里且时间更晚（`wouldRegress`）就不写。时间轴本来就从已写到的那条接着算，不会倒退。测试 `testStaleSnapshotDoesNotOverwriteNewer` / `testCloseoutReloadsCurrentPathAfterClaim`。
3+4. [中] CC 碎片池水位：`FragmentCCWatch.due` 只认领，`commit`（写成 / 空包 / 记了失败）才挪水位，`release`（预算跳过 / 断网 / 被打断）留着重来；同一窗口在跑时不再认领（15 分钟没交回当丢了）；找不到水位且比水位旧 = 晚到的旧快照，不动；比水位新 = 切了分支，只看最后 6 条。整包拒收算「处理完」（记失败、不反复重试同一截）。测试 `FragmentPoolTests.testCCWatermark` / `testCCWatermarkCommitsOnlyAfterSuccess` / `testCCStaleSnapshotDoesNotRewind`。
5. [中] 待续缓存：`PendingStore` 多一份只护字典的快照（锁竞争时沿用上一份），迁移标记 `mem_pending_migrated_<楼层>`（UserDefaults，主线程不读盘可判）；没迁移 → nil 照读老字段，迁移过没热 → 空（这一轮不带），后台预热。测试 `PendingStoreTests.testCachedDistinguishesNotMigratedFromCold` / `testCachedKeepsSnapshotWhileWriting`、`PendingInjectionTests.testMigratedButColdBringsNothing`。
6. [中] CC 窗口 A2 只手动没入口：`closeoutNow` 对 CC 窗口先跑一趟 A2（manual，不依赖 A3；A3 / A4 都关也跑）。测试 `testCloseoutNowWritesCCContextAndReportsBusy`。
7. [中] A2 只手动时 A3 收尾仍写尾段：`writesTail`——A2 关 / 只手动 / 格式冷却中不写尾段，A3 压原文那截；「现在写」照写。测试 `testA2ManualOnlySkipsTailUnlessManual`。
8. [中] CC 落地不触发 A3 / A4「每 N 回合」：`SessionCloseoutTrigger.ccReplyLanded` 一起喊 A2 / 巡检（带这个窗口和它的楼层，`request(profileId:)`）/ C2。测试 `testCCLandingRequestsCloseout`。
9. [中] A2 静默任务失败后出队：`runIdleCompress` 锚点到了 oldCount 才出队；预算拦下 / 被占留着，下次巡检再试；出错（非断网）退避 30 分钟；冷却中 compress 本来就不调模型。测试 `testIdleCompressKeptUntilWritten`。
10. [中] 「现在写」被占却说最新：不排队，`CloseoutResult` 带 busy / skipped / failed（+ API A2 的 `a2Failed`），`writeNowSummary` 分「后台正在写这个窗口，稍后再点」/「没写成，看记忆日志」/「没写成：被预算闸拦下，或模型没回内容（手动不看写入预算）」/「都写到最新了」。测试 `WriterTriggerTests.testWriteNowSummaryDistinguishesOutcomes`、`testCloseoutNowWritesCCContextAndReportsBusy`。
11. [中] 合并巡检丢新窗口：`sweep` 把请求（楼层 ctx / 活动窗口 / 新建对话）攒成队列，补跑逐个消费；CC 巡检按楼层各跑一次。测试 `testMergedSweepKeepsNewActiveWindow`。
12. [中] 本机 C2 绕过写入预算：`FragmentModelRoute.caller` 本机路线先查写入预算，超了跳过（不算失败）；本机不进账本照旧按 0 花费；C2 没有「现在写」。测试 `WriteBudgetTests.testLocalFragmentRouteStopsWhenBudgetExceeded`。
13. [车头] C2 整包拒收可见：两条路收进 `FragmentPool.process / recordFailure`——整包拒收记失败（failStreak +1，日志 rejected=1），连续 3 包状态卡那行红，成功一包清零；断网 / 被打断不算；总开关或 C2 关着不计不红。改前整包拒收其实已计 failStreak，这次补的是「关着不计」+ 两条路一份代码 + 测试锁住；断网从「算 C2 失败」改成不算（和 A2–A4 一致）。测试 `MemoryHealthWarningTests.testWholeBatchRejectionsTurnRedAfterThree`。

## C2 实测调整（10-15）

离线实测（合成 20 段 × 3 遍，Haiku 5.5 / Qwen3-4B 等，结果在 session scratchpad `c2-bench/results.md`、复测 `c2-bench/results-v2.md`，不进仓库）后改了 5 条：
1. 默认模型改成跟提取模型（粟粟 10-15 按推荐定）；本机聪明款 / 轻巧款留作可选，选了本机没装 / 在后台照旧退提取模型；「没下」一次性提示只在选了本机时出；C2 花费「本机不花钱」只在选了本机时写。测试 `WriterModelRouteTests.testFragmentDefaultsToExtract`。
2. 提示词：只记{用户}的事和两人约定 / 关系变化，{助手}的话除非是承诺不记；亲密互动里说的喜好 / 身体感受 / 边界是真事，只有括号动作和架空设定算剧情；「在问」带例子。表结构不变。`FragmentPoolTests.testPromptRulesAfterBench`。
3. 解析前剥开头一块 `<think>…</think>`，剥完照严格规则。`testLeadingThinkBlockStripped`。
4. 本机对话预算按实际 system 字数算（默认提示词下 3000 → 5295 字），并让出重来那句。`testLocalBudgetUsesActualSystemLength` / `testLocalRunSendsMoreAndRetryFitsTrimmed`。
5. msg 只认模型看得到的编号。`testMsgMustBeVisibleToModel`。

复测：Haiku 召回 94% → 98%、s08 亲密段 1/9 → 6/9、误记 0 → 1（擦边）；4B 召回 61% → 84% 但开始逐条复述、误记 6 → 15（主要是「只记…」那行引起，对照见 results-v2）。本机提示词要不要单独一份，留给下一轮定。

技术债：本机 4B 用同一份提示词召回 84% 但误记 15（逐条复述、记{助手}的话）；去掉「只记…」那行误记降到 4、召回 70%。本机是可选项、默认不走，暂不分叉提示词，以后要把本机当默认时再做。老存储值 `"extract"` 读的时候当空（`FragmentModelRoute.pickerChoice`），选择器勾在默认项上。
