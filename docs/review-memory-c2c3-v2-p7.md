# C2/C3 v2 · 第 7 段复盘：A4 一天一条跨窗口 + ≤40 字主调（含 topics）

范围：`plan-memory-c2c3-v2.md` 第 7 段全文、「粟粟已定」11 / 13，`plan-memory-c2c3-v2-rev5.md` §3 第一条（主调那次顺带 topics）。基线 HEAD `12639113b`，开工时工作区干净。按实现单：没做任何 git 写操作，没开模拟器、没碰设备、没跑真端点；live 方法 `CatalogLiveSmokeTests.testTimelineHeadlineLive` 交车头在 😷 iPhone 14 上跑，**这里没有冒充已经验过**。第一轮交回后车头裁定返工四条（尾段算 A2、保留 conv 编号、待续改由 A2 段字段搬、金样只剩时间轴那段就 RECORD），见 §5。

## 0. 做了什么（一句话版）

- 新数据：`timeline/yyyy-MM.md` 里一天一个 `<!-- day {json} -->` 块（主调、话题词、标题指纹、各项带窗口 / 标题 / 当天首末消息 id / 接前一天），和留下来的老条目（`<!-- entry …-->`）同住一份月文件，同一把写锁、严格读（`TimelineStore.swift`）。
- 骨架纯代码拼（`TimelineSkeleton.build`，`TimelineWriter.swift:151`）：只读已落盘的 A2 段（正式段 + 尾段，返工后），按段内主线消息的时间分到碰到的每个记忆日，后几天标「接前一天」、指针是该段当天首 / 末条；同窗口下标连着、同时段的段合一项；没压成 A2 的那截列「（N 条，没压缩）」（≤5 条且无 A2 的窗口记为短窗口）；老收尾段 / 第 0 段盖的消息不列。
- 主调写手（`TimelineWriter`）：system 固定、不带人设，user 只有日期 + 当天标题；交 `{"headline","topics"}`，主调 >40 截 40 记日志，topics 坏了只丢 topics，本机小模型不给 JSON 时第一行当主调。一天一次调用、不重写。
- 入口 `TimelineDaily`（新文件）：过了 05:00 第一次巡检跑一次（最近 7 天 + 还没换成的老条目日子），标题指纹没变就不调模型；「现在写」顺手拼今天；时间轴页长按一天「重写这天的主调」。全程不碰 `compress` / `compressCC`。
- 收尾不再写 A4：`SessionCloseout` 的时间轴写手、队列里的 `.timeline`、`writeTimeline` / `timelineStart` / `closeTimeline` 全删；三代搬迁（`MemoryMigration`）的补时间轴分支删掉（老「正在搬」标记里的月份 / 待续照样能撤回）。
- 注入 / 显示同一份字：`TimelineStore.itemText` / `headlineText` / `legacyText` 界面和注入共用，行尾带窗口短编号 `conv xxxxxxxx`（界面画成小号灰字）；今天、昨天带各时段，往前到第 7 天只带主调；待续单独一段（也带编号）。
- 待续：A4 拼日时由代码把当天碰到的 A2 段（含尾段）自带的 `pending` 搬进待续本子，不调模型（返工后；以前是 A4 窗口写手的模型写）。
- 消费者：时间轴页改成一天一组（`MemoryTimelineView.swift`）、窗口总结页按时间 + 标题定位那段 A2（`WindowSummarySheet.swift`）、A 线读取 / recall / C3 出处按日期引用 A4（`conversationId` 可空，`CatalogSources.days`，RawCite 加 `day`）、计量按日 / 项、A4 模型默认本机轻巧款、备份白名单加 `A4日级前-`、C3 每天那次先 await A4。

## 1. 测试

- 基线（改之前）：35 套 439 测，1 条失败（`MainThreadIOBudgetTests` 清理测试楼层目录时权限报错，环境问题，和本段无关）。
- 第一轮：46 套 632 测 0 失败（`p7-final-tests.log`）。
- 返工后：48 套 707 测 0 失败，含金样和 `InspectorRealPathTests`（`p7r-final-tests.log`）。
- 新增 `TimelineDailyTests`（18 条）：跨 00:00 / 05:00 / 三天的段每天都列（后几天接前一天、指针跳当天首条、三天各有主调）；四时段；同窗连续 / 不连续 / 跨时段 / 两窗口；短窗口；老收尾段不列；分支找不到的段无指针；**零 A2 调用**（sessions/ 文件逐字节不变、模型只收到主调 system）+ 没压缩的尾巴等 A2 压完下次补上；主调只喂日期 + 标题；>40 截、topics 坏只丢 topics、模型没回存骨架 / 已有的不盖；一个记忆日只跑一次、force 带今天；2 天 / 3–7 天边界；显示与注入同字、当前窗口还在窗口里的项不注、待续单独一段；备份失败一个字不换；按日迁移（成了的不重复调用、失败的原样再试、只有老收尾段的留老条目、旧待续进本子且照样注入）；起点以前不碰；模型默认本机 / 回退 / 显式选择保留；真实读窗口（记忆参与关的、时间外的不读）；窗口总结页定位。
- `TimelineWriterTests` 重写为主调写手 4 条（留 2 条 A2 写手检查）；`TimelineStoreV2Tests` 改为月文件新旧混住 / 严格读 / 并发；`TimelineInjectionTests`、`PendingInjectionTests`、`MemoryTimelineListTests`、`SessionCloseoutQueueTests`、`MemoryMigrationTests`（加老标记撤回 1 条、删 2 条补时间轴的）、`MigrationClassifyTests`、`CatalogALineReaderTests`（加一天一条候选 1 条）、`CatalogWriterTests`（加按日期引用 1 条）等随行为改。删除 `TimelineWriterPendingTests.swift`（A4 写手已不加待续）。
- 编译：mac `build-for-testing` / iOS（`MemoryPalaceIOS`）/ 😷 测试包（`build.sh … mask`）都 `** TEST BUILD SUCCEEDED **`。
- **金样**（第一轮没 RECORD，返工后按车头裁定 RECORD 了，见 §5）：`PromptRealPathGoldenTests` 8 条（G1–G6、G8、G9）和 `InspectorRealPathTests.testHistoryThinkingSegmentsNeverSent` 的实发 body 只有 `[时间轴]` 那一段不同，其余逐字相同（脚本核过）。夹具是 4 条 v2 老条目、「现在」10-11 12:00：

```
- golden: [时间轴]（按时间排，一天一个窗口一条；想看哪个窗口从头到尾，用 recall 给 conversation_id 翻它的窗口总结）
  - 10-08 20:00–21:00 《别的窗口》conv xctest-o：聊了团子的体检
  - 10-09 14:00–15:00 《本窗口》conv CONVID00：本窗口早先聊的（原文已不在窗口里）（待续：本窗口待续：周三复诊）
  - 10-10 09:00–10:00 《别的窗口》conv xctest-o：给团子买了猫粮；停在挑罐头（待续：周末问团子吃不吃）
+ actual: [时间轴]（一天一条，05:00 换日；最近 2 天带各时段聊了什么，更早的只带一句主调）
  10-08 周四：（旧格式）《别的窗口》聊了团子的体检
  10-09 周五：（旧格式）《本窗口》本窗口早先聊的（原文已不在窗口里）
  10-10 周六：（旧格式，没有主调）
    旧格式 · 09:00–10:00 《别的窗口》给团子买了猫粮；停在挑罐头
  [待续]（还没做完的；做完了 / 淡了用 pending_notes 标）
  - 《别的窗口》：周末问团子吃不吃
  - 《本窗口》：本窗口待续：周三复诊
```

  另外 `InspectorRealPathTests` 两条行为断言按老格式写的（`testSendRecordsExactlyWhatIsInjected` 期望键 `日期|窗口` 三条和「（待续：…）」跟在条目后；`testTimelineLedgerFollowsAssembledSegments` 期望 3 条），现在记账键是 `["2026-10-08","2026-10-09","2026-10-10","2026-10-10|xctest-other-window-0001"]`（4 条）。（第一轮的情况；返工后已按新键改、金样已 RECORD，见 §5。）

## 2. 她装上后第一次打开会发生什么

（按 §9「待续在哪儿产生就在哪儿保全」后的最终版本重写）

1. **待续：先迁老的，迁不好就照实说、不许改**。她一打开记忆页 / 时间轴页 / 待续页，或者助手第一次用 `pending_notes`，都走 `TimelineDaily.preparePendingForEdit`：
   - 待续本子头上已标 `legacy: done`、或者没有老时间轴月文件 → 不用迁。
   - 否则拿着月文件锁：先把 timeline/ + pending/ 原样备份到 `floors/<楼层>/记忆备份/A4日级前-<时间>/`（按清单核大小 + SHA256）→ 严格读全部月文件和本子 → 把每个窗口最新一条老条目的待续补进本子。以前迁过的条目（含她改过字、标过做完的）按来源对上、补记搬运身份，不重复 → 都成了才标迁完。
   - 本子还得每一行都认得。**任何一步不成**：本子一个字节不动；记忆页 / 时间轴页那行写「待续本子现在读不全或还没迁好（原因），先不能改」，待续页顶上同一句、所有改三态 / 改字都点不了；`pending_notes` 直接回这句错误、不列不标。底层 `setState` / `setText` 没迁好也拒绝，所有改动都在锁里严格读实际文件，有认不出的行就拒写。
2. **新待续：A2 覆盖之前先保全**（§10 最终版）。A2 每次要存正式段、写或换尾段（`SessionCloseout.saveA2`；三代搬迁提交也一样）：
   - 先严格读磁盘上的**旧**摘要（读不了 = 这次不存）；
   - 改本子之前 `ensureBackup`（按清单核现有备份，核不上就重做）；
   - 先迁老待续、补身份；
   - 把旧摘要和新摘要两边各段的【待续】一起导入本子（来源 + 原文哈希去重；不调模型，不看 A4 开关）；不成就写进 `pending/.待补.json`。
   - **本子写成了、或待补确认落盘了，才覆盖 A2 文件**；两样都不成，这次尾段 / 压缩记失败、文件原样，下次再来。
   - 所以升级前就写在旧尾段里、还没进本子的待续，会在第一次收尾覆盖它之前进本子。
3. **A4 巡检**（A4 开着）：启动 / 回复后的收尾巡检跑完 → `TimelineDaily.runDue`。同一层排队；C3 每天那次排在后面等它。
4. **扫 A2 文件**（`timeline/.a4-sources.json` 记每个 sessions/ 文件的大小、修改时间、内容哈希）：
   - 第一次、或者「记忆从哪天开始」改过 → 全量盘点：每个文件都读，全部 A2 段碰到的日子都标成待拼，起点以后结束的段的待续再搬一遍（同一句不重复）。
   - 平时只读变了的文件，标日子，不搬待续（存段时已经搬了）。读不了的文件下次再试。
5. **要拼的日子** = 昨天往前 7 天 + 待拼的日子（起点以后、今天以前、恢复冻住的范围以外）。
   - **第一次打开就是起点以后所有有 A2 的日子**；没设起点就是全部历史。主调调用 = 这些天里有 A2 标题的天数，一天一次。
   - 读窗口第一次会把这段时间动过的对话主线读一遍，只发生一次。
   - 今天扫到的留在待拼里，过了 05:00 再拼。十天没开 App 也不会漏。
6. **备份**：要迁老待续、补待补、全量盘点搬待续、或往有老条目的月份加日记录之前，先确认 `A4日级前-…` 备份还在、按清单核得上，不在就原样重做。备份没做成：本子不动，有老条目的月份不加日记录，其他月份照拼，30 分钟后再试。
7. **拼一天**：读那天碰到的窗口（主线 id + 时间 + 严格读 A2）。窗口的 A2 读不了 → 这天原样、记失败、不调模型。
   - 列项（A2 段 / 没压缩的那截）；标题有变化（或还没有主调）才调一次主调。
   - 默认本机 1.7B，整份输入放得下才走本机；放不下 / 本机报错 / 回来解析不了，退到提取模型（云端，查写入预算 + 全局闸）。被停下 / 进后台不退。
8. **老条目一条不删**：新的一天一条只是加进同一个月文件。
   - 时间轴页：这天有新记录，就以新的为主，老条目折在「旧格式 N 条」下面，点开看；只有老条目的日子照旧列。
   - 注入 / recall / C3 检索：这天有新主调就只用新的，没有才用老条目那一行。
9. **进度**：一天写成了就出队；没写成 / 没读全的、今天的留着；起点以前、恢复冻住的丢掉（起点改了会整轮重新盘点）。成了的日子标题不变，就不再调模型、不再收费。全新的日子主调没写成，先存骨架「（还没有主调）」。
10. **搬迁 / 恢复**：
   - 进行中：A4 停手，在途那趟后面的所有提交作废；存段时搬待续也先记待补。
   - 恢复了带 timeline/ 的备份：恢复前后出现过的日子、连同恢复那天以前的全部日子，自动都不碰（空备份也一样）。
   - 要重新生成某天：时间轴页可以长按主调「重写这天的主调」、在老条目菜单里「重写这天」，或者点顶上「重写某一天…」选日期。手动不受冻结限制。

## 3. 偏离 / 拿不准（逐条）

1. **「最近 2 天」按今天算第 1 天**：今天 + 昨天带各时段，第 3–7 天只带主调。自动只拼到昨天，今天要「现在写」或长按重写才有，所以平时实际只有昨天带各时段。也可以读成「昨天 + 前天」，等定。
2. **第 3–7 天只有老条目的日子**：没有主调，我带了一行「（旧格式）《窗口》话题…」，不然迁移前 / 迁不了的日子在注入里整天消失。严格按「仅主调」应该不带。
3. ~~注入不带 conv 编号~~ → 返工已改回带（§5）。
4. ~~A4 不再产出新待续~~ → 返工改由 A2 段字段搬（§5），但**现在的 A2 写手不写待续**，见 §5 第 3 条。
5. ~~尾段不算 A2~~ → 返工已改成算（§5）。
6. **迁移范围**：只重拼「有老条目的日子」，不是起点以后的每一天（A4 关着的那些天本来就没有老条目，没去补）。
7. **迁移是自动的**（第一次巡检就跑），不是手动按钮。要改成手动的话入口加在时间轴页即可。
8. **A4 设置页去掉了「什么时候写」三选一**（`hasTrigger` 不含 A4），换成两行说明；`MemoryTriggers` 里 a4 的键还在、没人读。「开窗口」页去掉「最多带几条」，「最多往回看几天」下限改 2。
9. **主调不重写**：plan 说每天一次调用，没拿到就记失败、下次巡检再试（30 分钟冷却）。
10. **窗口总结页定位按时间 + 标题**，不按消息 id（那页不读主线）。合并项落在第一段；找不到明确写「切了分支或删了」。
11. ~~恢复备份后不会自动再迁~~ → 原来只对七天以前的日子成立，astra #9 指出最近几天照迁；已改成记恢复的日期范围（§7）。
12. ~~本机路线的输入上限靠裁剪~~ → 放不下就不走本机、退提取模型（§7）。
13. `MemorySessionsView`「正在记」只看 A3 了（A4 不在那个队列），文案跟着改。

## 4. 复盘三块

### 边界情况

- **同一天多个分支**：段的 `lastNodeId` 不在当前主线 → 按段自己的起止时间列、没有指针、记日志；那个窗口当天的老条目不换。
- **消息没时间**：跟前后的走（`MemoryDay.split`）；整段都没时间的那截不列。
- **时区 / 夏令时**：记忆日、时段都按设备当前日历；跨时区出差那几天的时段归属会跟着变。
- **巡检只在前台 / 启动 / 回复后**：iOS 不保证 05:00 准点，跨界后第一次巡检补；进后台时那次跑的话本机模型会退回云端。
- **月文件被手改坏**：严格读失败 → 那个月的日子记失败、原样不动；老条目块数对不上同样判坏。
- **并发**：A4 是 actor、一层同时只跑一趟；手动重写会等自动那趟跑完。月文件和三代搬迁撤回共用一把写锁。
- **空状态**：一天只有没压缩的项 → 存骨架、主调显示「（还没有主调）」，3–7 天不注入。

### 与第 8b / 10 段交互的风险

- **8b 读主调**：从 `TimelineStore.day` / `month().days` 读 `headline` + `topics`。`headline == nil`（没标题 / 写不成）要当「来源未就绪」，不能当「没有新话题」；`topics` 可能是空数组（坏了被丢）。
- **8b 拿 A4 状态**：`SessionCloseoutTrigger.timelineDaily` 返回 `Report?`，今天已经跑过 / A4 关着返回 nil；要判今天成没成得读那天的记录或 A4 健康状态，别只看返回值。
- **8b 代码基线「话题词连续 ≥2 天」**：topics 每天最多 3 个、≤16 字、去重，按天存；跨天同一段的话题会连续出现，可能被当成「连续两天」，要按需去重。
- **第 10 段来源检查**：A4 一天一条的出处是 `{"layer":"A4","day":"…"}`，只认 `CatalogSources.days` 里实际给过的日期；老条目照旧按窗口。Faithfulness 收口时别把无窗口的 A4 当坏引用。
- **写作者提示词**加了一句 A4 按日期引用的写法（`CatalogWriter.swift:772`），第 9 段的写作者金样 / live 没重跑。

### 技术债

- `TimelineDaily.windows` 用 `SessionCloseout.mainPathNodes` 读整个节点（含正文），实际只要 id + 时间；第一次迁移跨度大时偏重。
- `TimelineConsolidator.enabled` 还当 A4 开关用（名字是老日记的）。
- `MemoryTriggers` / `TriggerRows` 仍支持 `.a4` 三个键，已经没人读。
- 迁移进度、备份名、每天跑过的标记都在 UserDefaults，不跟着楼层文件夹走。
- 迁移没有界面进度，只有记忆日志 / 健康状态和 `CacheDiagLog`。
- `InspectorRealPath` 的夹具还是 v2 老条目，金样里测不到一天一条的项格式（单测覆盖了），以后可换夹具。
- 待续从 A2 段字段搬，但新 A2 不写待续（§5 第 3 条），待续实际仍停产，待定。
- live：`testTimelineHeadlineLive` 待车头跑；本机 1.7B 实际出 JSON 的比例没量过（解析器有第一行兜底）。
- 说明书（`manual/facts`）没同步，不涉及本段交付范围，留给收口。

## 5. 返工（车头裁定，10-22）

1. **尾段算 A2**：`TimelineSkeleton.isA2`（`TimelineWriter.swift:141`）= 正式段 + 尾段，只排除老收尾段 / 第 0 段；列项、主调输入、短窗口判断都用它（`:172`、`:203`）。尾段后来被整段重写，那天下次重拼时标题指纹变了就重调主调。测试 `testTailSegmentCountsAsA2`（`TimelineDailyTests.swift:143`）：只有尾段、没超窗的 API 窗口，那天有项、主调输入是尾段标题、写出主调。
2. **conv 编号保留**：`itemText` = `itemBody` + 空格 + `convTag`，老条目同理（`TimelineStore.swift:274-293`）；第 3–7 天的旧格式那行、待续那行也带编号（`:365`、`:395`）。界面用 `TimelineLine.text`（`MemoryTimelineView.swift:515`）把编号那截画成小号灰字，拼起来和注入那一行一字不差。
3. **待续来源换成 A2 段字段**：
   - 骨架顺手收出当天碰到的 A2 段（含尾段）的 `pending`，按行拆、「无」/ 空的不搬，锚点 = 段末条消息，日期 = 段末那天（`TimelineWriter.swift:172-180`）。
   - `TimelineDaily` 拼日前先 `migrateIfNeeded`（免得本子一建就被当成迁过、老条目里的待续漏掉），再 `PendingStore.addFromSegments`（`TimelineDaily.swift:191-198`，`PendingStore.swift:157`）：同一个窗口已经有一字不差的（不管没做完 / 做完 / 淡了）不再加，所以尾段重写成同一句、重拼都不重复，做完了的不会被翻回来。没有要加的不写盘。
   - `PendingStore.add` 恢复回生产（`PendingStore.swift:137`），测试夹具那份删掉；`commitAdditions` / `PendingStage` 只有已删的三代搬迁补时间轴用，没恢复。
   - 测试 `testPendingHarvestedFromA2Segments`（`TimelineDailyTests.swift:159`）。原 `TimelineWriterPendingTests` 测的是已删的 A4 窗口写手，没恢复这个文件，改由上面这条覆盖。
   - **要车头知道的**：现在的 A2 写手不写待续——`SessionSegmentWriter.swift:68` 提示词明说「不写待续（没做完的事记在时间轴里）」，`:202` 存段时 `pending: ""`；`WindowSummaryWriter.swift:65` 同样。所以这条只会搬出改版前老压缩段里带的待续，**新聊天不会产生新待续**，待续本子事实上还是停产。要真恢复，只能改 A2 提示词让它写【待续】（plan 禁改 A2 / A3），或让 A4 主调那次顺带交待续（plan 说模型只写主调）。两条都越过了本段边界，我没动，请车头 / 粟粟定。
4. **金样**：改完再比，`PromptRealPathGoldenTests` G1–G6、G8、G9 和 `InspectorRealPathTests.testHistoryThinkingSegmentsNeverSent` 都只有 `[时间轴]` 那一段不同，其余逐字相同（脚本核过），G7 本来就过。按裁定 RECORD 了 8 份金样，每份 1 行变化。`InspectorRealPathTests` 两条记账断言改成新键：`["2026-10-08","2026-10-09","2026-10-10","2026-10-10|xctest-other-window-0001"]`、插槽开着记 4 条。新的 `[时间轴]` 段：

```
[时间轴]（一天一条，05:00 换日；最近 2 天带各时段聊了什么，更早的只带一句主调）
10-08 周四：（旧格式）《别的窗口》聊了团子的体检 conv xctest-o
10-09 周五：（旧格式）《本窗口》本窗口早先聊的（原文已不在窗口里） conv CONVID00
10-10 周六：（旧格式，没有主调）
  旧格式 · 09:00–10:00 《别的窗口》给团子买了猫粮；停在挑罐头 conv xctest-o
[待续]（还没做完的；做完了 / 淡了用 pending_notes 标）
- 《别的窗口》conv xctest-o：周末问团子吃不吃
- 《本窗口》conv CONVID00：本窗口待续：周三复诊
```

5. 其余偏离（「最近 2 天」= 今天 + 昨天、第 3–7 天老条目注入一行旧格式、自动迁移、A4 页去掉触发三选一、窗口总结按时间 + 标题定位、恢复备份后不自动再迁）车头接受，见 §3。

## 6. 破例：A2 恢复写待续（方案 1，04fef679f 之后）

粟粟 5 分钟没回，车头按推荐走方案 1：A2 写手恢复写【待续】，A4 拼日时由代码搬进待续本子（`addFromSegments` 不变，不调模型）。

**改了什么**（只有 `SessionSegmentWriter.swift`，A2 正式段和尾段共用）：
- 提示词（`:65-71`）：格式块加一行「【待续】这一段里做到一半的事、答应了的事、还没哄完的情绪，一条一行；真的没有就写「无」」，措辞照改版前（`ed6c98b95^`）A2 那行；「三块都要有」随之改「四块」；删掉「不写待续（没做完的事记在时间轴里，不在这里）」。标题、【经过】【原话】的写法、切段时机都没动。
- 解析（`:103-111`）：【待续】单独收，按行拆、去「- 」，「无」或没写 = 空；多写的【时间轴】照旧丢。`Output` 加 `pending`（`:32`）。
- 存段（`:208`）：`pending: ""` 改成 `pending: o.pending`。存储格式不变（`SessionSummaryStore` 本来就读写【待续】层），读回来一样。

**没改 `WindowSummaryWriter`（A3）**：车头单子写了 `WindowSummaryWriter.swift:65`，同时又写「A3 不碰」。A3 存在 windows/，A4 只读 sessions/ 里的 A2 段，A3 的待续不会流到任何地方，所以按「A3 不碰」留着没改，A3 照旧 `pending: ""`。

**测试**：`testA2WrittenPendingFlowsIntoPendingStore`（`TimelineDailyTests.swift:188`）：假模型写两段，一段待续两条、一段「无」→ 段的 pending 是「周三问结果\n买药」和空 → 存盘读回一样 → A4 拼日搬进本子 2 条（锚点 = 段末条消息），「无」不搬。另外改了 `SessionSummaryTests` 3 处、`TimelineWriterTests` 1 处原来断言「A2 不写待续 / 【待续】被丢掉」的。52 套 743 测 0 失败；金样和 InspectorRealPath 没变（夹具里 A2 段的 pending 本来就是空的）。

**连带影响，没改，请车头知道**：
1. **三代搬迁会误判**：`MemoryMigration.classify`（`MemoryMigration.swift:130`）把「起点以后、带待续的正式段」当第三刀老式段，整段重写（`.a2Full`）。A2 恢复写待续以后，新写的段也会被当成老式段——DEBUG「搬成新样子」再点一次会花钱重写这些新段，还会把它们的待续抹掉。目前只有手动点这个 DEBUG 按钮时才会触发。修法要么换判断依据，要么把这个按钮下掉。
2. **A2 注入带出【待续】**：`SessionSummaryStore.segmentText`（`:229-233`）本来就会把非空 pending 拼成「【待续】…」。所以当前窗口注入的最近两段上下文摘要里会出现待续，和时间轴的 [待续] 段重复。A3 重压时的输入（`WindowSummaryWriter.userContent`）也会带上这一层，但 A3 解析会丢掉、A3 照旧不存。recall 的「更早段落里没做完的」（`SessionSummaryStore.swift:272`）也会重新出现内容。这些都是改版前就有的老路径，我没动。
3. 本机 / 云端 A2 的输出多了一块，每段多几十个 token。

## 7. astra 审查返工（04fef679f 的 5 项 P1 + 6 项 P2，外加车头 B）

审查原文 `review-p7-astra.out`。安全优先：宁可多留旧的。行号按当前工作区。

**P1**
1. ~~**老条目按「窗口 + 日期」盖全才退役**~~（已被 §8 整个拿掉：老条目一律不退役）：骨架按窗口逐日核（`TimelineWriter.swift:240-249`）——那天有 A2、没有老收尾段 / 第 0 段的内容、没有没压缩的消息、没有分支找不到的段，才进 `Day.covered`；还会补上的进 `Day.incomplete`（窗口 7 天内动过）。拼日只退役 `legacy ∩ covered`（`TimelineDaily.swift:347`），其余老条目留着、新的并列。测试 `testLegacyRetiredOnlyForFullyCoveredWindowDay`。
2. **先备份原始的、再严格读、再迁 / 搬**：`perform` 里先 `backupValid`（按清单逐文件核内容，`TimelineDaily.swift:466`）/ `backup`（原样 timeline/ + pending/，核过才记名），成了才在月文件锁里 `PendingStore.migrateIfNeededStrict` + `addFromSegments`（`TimelineDaily.swift:252-280`）。`migrateIfNeededStrict`（`PendingStore.swift:247`）本子在就严格核、不在就严格读全部月文件；`checkReadable`（`:201`）改成每个非空行都要认得（以前只数带机读注释的行，手写的行会被整份重写吃掉）；`addFromSegments` 写前也严格核（`:161`）。任何一步失败 → `safe = false`，有老条目的月份 / 要搬待续的日子一律不动（`rebuild` 里 `!safe` 那条）。测试 `testBackupFailureLeavesPendingUntouched`（pending 字节不变）、`testUnreadablePendingBlocksAndKeepsEveryLine`（有一行认不出：文件原样、老条目不退役）、`testLegacyPendingSavedBeforeEntryRetires`（补回旧安全性质：老待续先进本子、写成了老条目才退役；备份里是原始的）、`testBackupValidChecksContent`。
3. **A2 读不了不当「没有 A2」**：读窗口返回 `TimelineSkeleton.Source`（`TimelineWriter.swift:133`），对话 / 消息取不出 → `error`，整趟一天都不拼（`unreadAll`）；每个窗口用 `SessionSummaryStore.loadStrict`，读不了记 `Window.summaryError`（`TimelineDaily.swift:523` 起），它碰到的日子 `Day.failed` → 原样留着、记失败、不调模型（`rebuild` 开头）。消息改用 `SessionCloseout.mainPathNodesStrict`（`SessionCloseout.swift:979`，取不出就抛）。测试 `testSummaryReadFailureKeepsExistingDay`（含真实接线：坏 sessions 文件 → `summaryError`）。
4. **A4 纳入维护互斥**：`TimelineGate`（`TimelineDaily.swift:35`）——`MemoryMaintenance.exclusive` 一进来就 `pause()`（纪元 +1），出去 `resume()`（`MemoryRegenerationSection.swift:125-126`）；`runDue` / `regenerate` 暂停时不进；在途那趟的两处提交（待续迁 / 搬、月文件写）都在 `TimelineStore.withWriteLock`（`TimelineStore.swift:149`）里先 `gate.valid(epoch)`，变了就作废（`TimelineDaily.swift:264`、`:388`）。恢复换文件夹也拿同一把锁（`MemoryRegeneration.swift:252`，锁序月文件锁 → 待续本子锁，和 A4 提交同序）。测试 `testMaintenanceInvalidatesInFlightAndBlocksNew`（模型回来前进了维护 → 不落盘；待续那步开始后进了维护 → 一条不搬；暂停时 runDue / regenerate 都不进）。
5. **Recall / C3 的日主调按来源过滤**：`CatalogALineReader.dayParts`（`CatalogALineReader.swift:180`）——这天的项有看不见的窗口就不给主调和话题，只给看得见的项；一项都看不见整天不给。测试 `testDayHeadlineHiddenWhenAnySourceHidden`（含 `RecallTool.searchALine` 端到端）。

**P2**
6. **串行队列**：`tail[profileId]` 存最后一个任务，新任务先 `await` 前一个再跑，登记只在还是自己时清（`TimelineDaily.swift:164`）；自动那趟轮到时再判今天跑过没有（`due`）。原来「有人在跑就直接回 nil」去掉了，所以 C3 那次真的会等。测试 `testQueueSerializesWaiters`（在途 + 自动等待者 + 现在写，同时调模型峰值 = 1，排完不卡）。
7. **迁移进度四态**：成了、明确留着（只有老收尾段 / 第 0 段、窗口已定下来）出队；没写成、没盖全、没读全的留着（`TimelineDaily.swift:203`）。清点（`legacyDays`，`:211`）有月文件读不了就返回「没全」，这次不提交进度。测试 `testMigrationProgressNotCommittedWhenCountIncomplete`、`testLegacyRetiredOnlyForFullyCoveredWindowDay`（没盖全的留在队列）。
8. **A2 后来落盘补拼老日子**：`staleDays`（`TimelineDaily.swift:303`）看这趟读到的窗口里每段 A2 真有消息的那几天，起点以后、恢复范围以外、存着的那天没有这段（窗口 + 标题）的，加进来重读重拼；不调 A2。测试 `testLateA2RebuildsOlderDays`（十天一段，七天以前的也补、起点以前的不碰、补过的不再补）。
9. **恢复后自动不碰**：`MemoryRegeneration.restore` 恢复了带 timeline/ 的备份 → `TimelineDaily.noteRestored`（`MemoryRegeneration.swift:264`、`TimelineDaily.swift:449`）记下恢复回来的日期范围，自动调度（最近 7 天 + 迁移 + 补拼）都跳过，手动 `regenerate` 照写。§3 第 11 条自述已改。测试 `testRestoreFreezesRestoredDays`。
10. **本机不拿裁过的输入写**：`headline()` 先 `localFits`（`TimelineDaily.swift:429`，和 `LocalChatProvider.trimmed` 同一口径），放不下直接退提取模型，不调本机、不记指纹。
11. **本机运行失败退提取模型**：`timelineInput` 本机路线时另给 `fallback` = 提取模型的云端 caller（同样 `gated(.timeline)`、查写入预算 / 全局闸，`SessionCloseout.swift:1219`）；`headline()`（`TimelineDaily.swift:406`）本机报错 / 没回 / 解析不了 → 退，`CancellationError` 和 `FragmentPoolError.interrupted`（被停下 / 进后台）不退。测试 `testLocalFallsBackToExtractModel`（10、11 两条）。

**车头 B**
- **A3 不改**。
- **三代搬迁误判**：`SessionSegment.format`（`SessionSummaryStore.swift:25-27`），A2 写手新写的段标 `currentFormat = 1`（`SessionSegmentWriter.swift:208`），文件里多 ` w=1`（`SessionSummaryStore.swift:296`），老文件没有 = 0 照读。`classify` 只把没标的带待续正式段当老式段（`MemoryMigration.swift:131`），按钮保留。没有现成字段能分新旧（老式段同样有 `lastNodeId`、同样是 `.rolling`），所以加了最小标记。测试 `testNewFormatRollingWithPendingIsNotOldStyle`、`testSegmentFormatMarkerRoundTrip`。
- **待续只一份**：`segmentText`（`SessionSummaryStore.swift:235`）不再拼【待续】——注入、recall（顺带删了 `recallText` 的「更早段落里没做完的」）、A3 重压输入都走它；存盘另用 `fileText`（`:243`）把【待续】留在文件里给 A4 搬。A 线检索的 `segmentParts` 也去掉【待续】。测试 `testSegmentPendingOnlyInFileNotInModelText`；`SessionSummaryTests` / `CatalogALineReaderTests` / `CatalogSearchReceiptTests` 原来断言带【待续】的 4 处改了。

**界面**：时间轴页「重写这天」在维护中 / 被作废时给一句「正在搬迁 / 恢复记忆…」（`MemoryTimelineView.swift:471-477`）。

**测试**：52 套 759 测 0 失败（新增 `TimelineDailyTests` 13 条、`SessionSummaryTests` 2 条、`MigrationClassifyTests` 1 条）。金样（`PromptRealPathGoldenTests` / `InspectorRealPathTests`）不用 RECORD、全过：夹具里 A2 段的待续本来就是空的。mac / iOS / 😷 测试包 build-for-testing 过。

**还要车头知道**：
1. 补拼（#8）让第一次打开时，起点以后有 A2、但从没有过时间轴记录的日子也会补主调（§2 第 2 条），调用数比只迁老条目多。要只补「已有记录」的日子，`staleDays` 里加一个「record != nil 或有老条目」的条件即可。
2. 老待续读不全（有月文件读不了）时，整趟老条目一条不退役（§7 第 2 条），直到那个月文件修好；这是按「宁可多留」做的。
3. 「窗口 7 天没动 = 定下来」是我定的阈值（`lookbackDays`），用来不让没压缩的老窗口永远留在迁移队列里每天重拼。

## 8. astra 第二轮返工（6e1358bb8 的 3 项 P1 + 4 项 P2）+ 车头 10-22 第一性原理

审查原文 `review-p7-astra.out`（`tokens used` 之后）。行号按当前工作区。

### 车头定：老条目一律不退役（替代二轮 P1-1）

**plan 原文是「替换」，这里改成「并列保留」**。依据是数据安全：要证明「这条老条目记的东西已经被新 A2 完整盖住」，就得核旧分支、删过的消息、老收尾段锚点失效等各种情况，二轮 astra 仍找到了漏洞；不退役就不用再证明覆盖范围。
- 删掉了覆盖 / 退役整套：`TimelineSkeleton.Day` 去掉 `covered` / `incomplete` / `pending`，`Window` 去掉 `settled`（`TimelineWriter.swift:119-149`）；`rebuild` 只往月文件里换这天的日记录，`entries` 一条不碰（`TimelineDaily.swift:403` 起）；`Report.incomplete`、迁移队列 `migrateLeftKey` / `legacyDays`、`staleDays` 都删了。
- 显示：`TimelineListLayout.foldsLegacy`（`MemoryTimelineView.swift:35`）——有新记录又有老条目的日子，老条目折在「旧格式 N 条」那一行下面（`legacyFoldRow`，`:431`），点开看；只有老条目的日子照旧列。
- 注入：最近两天里有新主调的日子不再带老条目行（`TimelineStore.swift:384`）；第 3–7 天本来就是「有主调用主调、没有才用老条目那一行」。没有新主调（日记录存在但主调没写成）的日子照带老条目——比「没有新记录才用老的」多带一点，宁多不少。
- recall / C3 检索：有新主调的日子不出老条目的 hit（`CatalogALineReader.swift:125`）。
- 备份照旧先做、照旧核。进度只记「这一天的新记录写成了没有」（见下面 P2-4 的待拼队列）。
- 测试：`testLegacyEntriesNeverRemoved`（切过分支：老条目末条锚点不在当前主线；删过消息——两条都留着；列表折叠；注入只用新的）、`testMigrationByDay` 改写（三条老条目都在）、`testDisplayAndInjectionShareText` 补「有主调不注老条目 / 没主调照注」和折叠判断。原来的 `testLegacyRetiredOnlyForFullyCoveredWindowDay`、`testLegacyPendingSavedBeforeEntryRetires` 删了 / 改写。

### 其余

- **P1-2 待续迁移只有一个严格入口**：`TimelineDaily.ensurePendingMigrated`（`TimelineDaily.swift:567`）——维护中不跑；拿月文件锁；标了迁完 / 没有老月文件就返回；否则先 `ensureBackup`（`:552`，记着的备份按清单核内容，核不上重做）再 `PendingStore.importLegacyStrict`（`PendingStore.swift:309`）。
  - 迁完标记写在本子头上 `legacy: done`（`isLegacyDone`，`PendingStore.swift:114`；日常写盘照原样带回去，`write` `:107`），跟着本子一起备份 / 恢复。**本子在 ≠ 迁完**。
  - 严格迁移会补齐以前宽松入口漏掉的月份：已有的条目不动；以前整条迁过的（没有来源身份、同窗口同日同锚点）不重复（`importing`，`:217`）。
  - 宽松的 `migrateIfNeeded` / 半严格的 `migrateIfNeededStrict` 删了，四个入口全换：`MemoryTimelineView.swift:343`、`MemoryPageContent.swift:585`、`MemoryWriterPages.swift:1053`、`PendingNotesTool.swift:30`。A4 自己在 `perform` 里同一把锁、同一个函数（`TimelineDaily.swift:328` 起）。
  - 测试 `PendingStoreTests.testStrictMigrationFillsGapsLeftByLenientPath`（宽松入口先建的本子漏了一个月 → 补上，三态 / 改过的字不动，标迁完）、`testStrictMigrationStopsOnUnreadableMonth`、`testMigrationOnlyLatestEntryPerWindowAndOnce` 改走新入口。
- **P1-3 历史 A2 的待续先盘点**：`TimelineSources.scan`（`TimelineDaily.swift:96`）每趟扫 sessions/ 所有文件，记大小 + 修改时间 + 内容哈希（`TimelineSourceState`，`:53`，存 `timeline/.a4-sources.json`，文件库不显示点开头的文件）。第一次全量读，起点以后结束的 A2 段的待续由代码搬进本子，不调模型、不依赖窗口最近有没有消息；以后只读变了的文件。待续搬成了才记下这批文件的指纹（`:331`、`:366`），没搬成下次重扫。测试 `testOldWindowPendingAndDaysFoundBySourceScan`（十天前结束的窗口，待续搬进来、那天拼出来）。
- **P2-4 两种指纹分开**：「骨架 / 待续来源」= A2 文件内容哈希，文件变了（新段、同标题的新段、改锚、改待续、文件删了）就把它新旧 A2 段碰到的日子都标成待拼（`TimelineSourceState.dirty`），重拼、搬待续；「主调标题」= 原来的 `TimelineDayRecord.source`，只有它变了才重调主调。重拼时整条日记录比对，指针变了照写、不调模型。「窗口 7 天没动就算定下来」删了；扫描每趟只 stat 一遍，不会永久漏。测试 `testSameTitleNewSegmentRebuildsWithoutNewHeadline`、`testLateA2RebuildsOlderDays`（改成靠文件变化）、`testProgressOnlyTracksWrittenDays`（没写成留在待拼、写成了出队）。
- **P2-5 空备份恢复**：`MemoryRegeneration.restore` 在锁里先记恢复前的日子（`MemoryRegeneration.swift:256`），恢复后再记一次，交给 `TimelineDaily.noteRestored`（`TimelineDaily.swift:527`）：冻住 `0000-01-01` 到「恢复前后出现过的最晚那天、恢复那天的前一天」里较晚的那个。来源账也被恢复换回去了，不冻住全部历史就会被重扫重拼。空备份同样记。测试 `testEmptyBackupRestoreStillStopsAutoRebuild`、`testRestoreFreezesRestoredDays`（期望值改成新范围）。
- **P2-6 老条目的待续读本子**：`CatalogALineReader.a4Lines(_:book:)`（`CatalogALineReader.swift:203`）——本子标了迁完就读本子里这条老条目搬进去的、还没做完的（按现在的字，`PendingStore.items(from:in:)` `:249` 按来源身份认）；没迁完才读老字段。测试在 `testLegacyPendingMigratedAndBackupIsOriginal`。
- **P2-7 编辑后不重复搬**：`PendingItem` 加 `source`（来源身份哈希：A2 = 窗口 + 尾段 / 正式段起点，老条目 = 窗口 + 日期 + 末条消息）和 `origin`（搬进来时原文的哈希），存成 `src=` / `orig=`（`PendingStore.swift:29`、render / parse）。去重按「同窗口 + 原文哈希」，以前没哈希的按一字不差（`importing`）。测试 `PendingStoreTests.testImportDedupesByOriginAfterEdit`、`TimelineDailyTests.testEditedPendingNotHarvestedAgain`。
- **假 loader 遵守日期区间**：`TimelineDailyTests.input` 只给区间里有消息的窗口，并把窗口的 A2 落到 sessions/（扫描靠它）；真实 loader 的测试照旧在 `testWindowsLoaderReadsMainPathAndA2`、`testSummaryReadFailureKeepsExistingDay`。

**测试**：52 套 766 测 0 失败。`TimelineDailyTests` 38 条（新增 / 改写见上），`PendingStoreTests` 新增 3 条。金样（`PromptRealPathGoldenTests` / `InspectorRealPathTests`）没变、没 RECORD：夹具只有老条目、没有日记录，A2 段待续为空。mac / iOS / 😷 测试包 build-for-testing 过。

**还要车头知道**：
1. 第一次打开要拼的日子 = 起点以后所有有 A2 的日子（§2 第 4 条）。「记忆从哪天开始」没设就是全部历史，主调调用数和第一次读窗口的量都比以前（只迁老条目的日子）多。
2. A4 关着时 A2 照写待续，但只有 A4 的扫描会搬进本子；段里的待续又不再注入。A4 关着的那段时间新出的待续，要等 A4 打开后第一次巡检才进本子，不会丢。
3. 恢复后冻住的是「恢复那天以前的全部日子」，比只冻住恢复回来的那几天宽；理由见 P2-5。
4. 时间轴页老条目那一行展开后仍显示老字段里的「待续：…」（看的是这条老条目本身），没改成读本子。

## 9. astra 第三轮返工（6def31d53 的 3 项 P1 + 2 项 P2）+ 车头「待续在哪儿产生就在哪儿保全」

审查原文 `review-p7-astra.out`（最后一个 `tokens used` 之后）。行号按当前工作区。

- **P1-2 → 结构改动：A2 存段那一刻就搬待续**
  - SessionCloseout 里四处写 sessions/（压缩分段、压缩收尾、CC 窗口、尾段）都改走 `SessionCloseout.saveA2`（`SessionCloseout.swift:94`）：先 `SessionSummaryStore.save`，再 `TimelineDaily.preserveSegmentPending`（`TimelineDaily.swift:608`）。
  - `preserveSegmentPending` 把这份 A2 各段（正式段 + 尾段）的待续交给 `PendingStore.addCandidatesFlushingRetry`：来源 + 原文哈希去重，不调模型，不看 A4 开关 / 调度，A2 提示词和切段时机不动。真楼层第一次时先做 A4 备份。
  - 三代搬迁提交成功后也调一次（`MemoryMigration.swift:646`）。
  - 搬不成（本子有坏行、维护中、写盘失败）→ `PendingStore.enqueueRetry` 记进 `pending/.待补.json`（`PendingStore.swift:236`），下次存段或 A4 巡检（`perform` 里的待续那一步也走 `addCandidatesFlushingRetry`）一起补，成了才清。
  - A4 日任务不再负责搬待续。`TimelineSources.scan` 只在全量盘点（`full`，第一次 / 起点变了）时收待续，平时只标待拼日（`TimelineDaily.swift:100`）。
  - 测试 `SessionCloseoutQueueTests.testTailPendingSavedAtWriteEvenWithA4Off`（A4 关着，尾段写出待续 → 本子里有；尾段被整段重写没了这句 → 本子里照样在）、`testTailPendingRetriedAfterFailure`（本子坏 → 进待补；修好后下一次存段补上，待补清空）。
- **P1-1 迁移失败不再吞**
  - 四个入口改走 `TimelineDaily.preparePendingForEdit`（`TimelineDaily.swift:632`）：严格迁移 + 本子每行都认得，失败抛。
    - 记忆页：待续那行写原因（`MemoryPageContent.swift:588`）。
    - 时间轴页：同样写原因（`MemoryTimelineView.swift:387`）。
    - 待续页：顶上写原因，改字 / 左滑 / 菜单全部禁用，改的时候被拒也显示原因（`MemoryWriterPages.swift:1067`）。
    - `pending_notes`：直接回错误，不列不标（`PendingNotesTool.swift:31`）。原因文字在 `pendingProblem`（`:638`）。
  - `PendingStore.mutate` 改为锁里 `strictLoad` 实际文件（`PendingStore.swift:96`、`:103`），有认不出的行就拒写，不再宽松读缓存后整份重写。`addCandidates` / `importLegacyStrict` 同样走 `strictLoad`。
  - `setState` / `setText` 先 `requireMigrated`，老待续没迁好抛 `NotMigrated`（`:321`、`:330`、`:337`）。
  - 测试 `PendingStoreTests.testEditRefusedWhileBookUnreadableOrNotMigrated`：坏行 + 老月文件 → 准备失败、改三态 / 改字 / mutate / 工具都被拒，文件一个字节不变。
- **P1-3 未到期日不出队、起点变了重新盘点**
  - 待拼队列分三种：成功完成（出队）；还没到时候（今天，`later`，留着）；被范围暂时排除（起点以前 / 冻住，丢掉）（`TimelineDaily.swift:379`）。
  - 来源账记 `harvestedFrom`（全量盘点是按哪个起点做的，`:66`）。起点和它不一样就整轮重新盘点（`:313`），已登记、文件没变的也重读：补搬待续、补标日子。盘点的待续没搬成，就不记 `harvestedFrom`，下次整轮重来。
  - 测试 `testTodayStaysPendingUntilDue`（今天扫到 → 留着 → 11 天后补拼）、`testStartMovedEarlierRescansSources`（起点前移 → 补搬、补拼）。
- **P2-4 旧条目补搬运身份**：`importing`（`PendingStore.swift:263`）。
  - 老条目候选对上「以前整条迁过」的那批（没来源身份、同窗口同日同锚点）时，给每条补 `source`：字没改的按字对上、补 `origin`；改过字的按先后对上剩下的原文、补 `origin`。都算搬过，不新增。
  - 任何候选一字不差对上没 `origin` 的条目时，也补记 `origin` / `source`。有身份变化就写盘。
  - 测试 `PendingStoreTests.testOldBookEntriesGetOriginAndAreNotReharvested`：旧本子里「买药」改成「买感冒药」并标做完 → 迁移补身份 → A2 再来「买药」不新加；一字不差对上的补记后再改字，同一句也不再搬。
- **P2-5 冻结后的手动入口**：冻结保留，没新增设置项。时间轴页加了两个入口，手动 `regenerate(day:)` 不受冻结限制：
  - 老条目菜单「重写这天」（`MemoryTimelineView.swift:540`），给只有老条目的日子用；
  - 顶上一行「重写某一天…」（`:318`），选日期（`TimelineListLayout.dayKey(picked:)`，`:35`，取那天中午算记忆日），给空日子用。
  - 没写成会提示原因；没变化提示「这天没写：没有能拼的… 或者和原来一样」。
  - 测试在 `testRestoreFreezesRestoredDays`：恢复后冻住的、只有老条目的那天手动照写，选日期的换算对。

**测试**：52 套 772 测 0 失败。本轮新增 `TimelineDailyTests` 2 条、`PendingStoreTests` 2 条、`SessionCloseoutQueueTests` 2 条。金样没变、没 RECORD。mac / iOS / 😷 测试包 build-for-testing 过。

**还要车头知道**：
1. 三代搬迁（DEBUG「搬成新样子」）是在维护期间跑的，那时搬待续会先进待补，搬迁结束后的下一次存段或 A4 巡检才补进本子。
2. 存段搬待续在 SessionCloseout 这个 actor 里同步做（读写一次本子；第一次时还有一次备份），不调模型。
3. 恢复冻结的范围仍是「恢复那天以前的全部日子」，现在有了手动入口。

## 10. astra 第四轮返工（eff1e2b08 的 3 项 P1 + 2 项 P2）：saveA2「先保全，后覆盖」

审查原文 `review-p7-astra.out`（最后一个 `tokens used` 之后）。行号按当前工作区。

- **P1-1 / P1-2 / P2-4 / P2-5 一起收：`saveA2` 改成先保全、后覆盖**（`SessionCloseout.swift:94`）：先 `TimelineDaily.preserveBeforeSave`（`TimelineDaily.swift:627`），成功了才 `SessionSummaryStore.save`。
  1. 严格读磁盘上的旧摘要：不在 = 空；读不了抛 `PendingNotPreserved`（`:616`），不覆盖。
  2. 改本子之前调 `ensureBackup`（只真楼层）。它自己核现有备份（清单 + SHA256），不能复用就重做，不再只看记过的名字。
  3. 先 `importLegacyStrict`（老待续迁移 + 补身份），再导入。
  4. 旧摘要和新摘要两边各段的待续，连同待补一起 `addCandidatesFlushingRetry`。2–4 任何一步失败（含维护中），这批记进待补；待补也落不了盘，就抛 `PendingNotPreserved`。
  5. 抛了，调用方就不覆盖 A2：压缩 / 尾段 / CC 窗口那几处原有的错误处理接着走（记失败、冷却、下次再来）。
  - 三代搬迁提交在覆盖 sessions/ 之前同样调它（`MemoryMigration.swift:631`）；失败就走提交的撤回。
  - 待补队列区分「不存在」和「读不了」：`retryQueueStrict`（`PendingStore.swift:231`）在文件读不了 / 解不出来时抛。`enqueueRetry`（`:246`）原来那份读不了就拒绝覆盖、写失败往上抛。`addCandidatesFlushingRetry`（`:258`）待补读不了时只搬这一批、坏的那份不动。A4 判断有没有待补用 `hasRetry`（`:241`），读不了也算有。
  - 删掉原来存好以后再搬的 `preserveSegmentPending`。
- **P1-3 全量盘点**：扫描有任何读取错误，就不提交全量完成标记（`TimelineDaily.swift:387`，`done = !full || (harvested && found.errors.isEmpty)`）。sessions/ 目录在却列不出来时记一条错误、照旧用上一次的账，不当空目录（`:107`）。选的是「整轮不算完」这个简单做法：下一轮整轮重读，修好的文件那时补搬。
- **测试改动（三代搬迁）**：`MemoryMigrationTests` 四处原来断言「搬迁不碰待续本子」。现在老式段被重写之前，它的【待续】「仍未问到」会先进本子；撤回时这条也留着（只增不减）；注入根的演练里落在注入的根上，真根照旧一个文件不多。这四处断言按新规则改了。

**新增测试**：
- `SessionCloseoutQueueTests.testOldTailPendingPreservedBeforeOverwrite`：升级前旧尾段有待续、没进本子 → 第一次收尾写新尾段 → 本子里有。
- `SessionCloseoutQueueTests.testA2NotOverwrittenWhenPendingUnwritable`：`pending` 是个文件，本子和待补都写不进去 → A2 文件逐字节不变，尾段记失败。
- `SessionCloseoutQueueTests.testEditedOldBookItemNotDuplicatedOnA2Save`：旧本子「买药」改成「买感冒药」并标了做完；A2 先保存、尾段又有「买药」→ 不多出一条 open，并标迁完。
- `SessionCloseoutQueueTests.testStaleBackupNameIsRedone`：记过名字但备份已不在 → 重做并核得上。
- `PendingStoreTests.testCorruptRetryQueueNotOverwritten`：坏待补读 / 入队都抛、原样不动；搬的时候只搬这一批。
- `TimelineDailyTests.testFullHarvestNotDoneWhileAFileUnreadable`：盘点时一个文件读不了 → 不记盘完 → 修好后补搬。

52 套 778 测 0 失败；金样没变、没 RECORD；mac / iOS / 😷 测试包 build-for-testing 过。

**还要车头知道**：
1. 旧 A2 文件读不了的窗口，从此存不了新段（每次都失败、记健康状态），直到文件修好。这是按「读不了就不覆盖」做的；以前会宽松读了直接覆盖。
2. 待补文件坏了的话，本子能写成时照常存；本子也写不成时，这个楼层所有带待续的存段都会失败，直到待补修好。
3. 盘点有文件读不了时，每一轮巡检都整轮重读 sessions/，直到修好。
