# 复盘 · 记忆三代旧数据搬成 v5 的样子

> 2026-10-16 · backend-2 · [plan](plan-memory-migrate-3gen.md) / [research](research-memory-migrate-3gen.md) · 验收单 `~/Desktop/cc-rp/记忆系统/记忆三代搬迁-验收.md`（已按实现核过）
> 实现：`Services/MemoryMigration.swift`（新，引擎）、`Services/MemoryRegeneration.swift`（备份 / 恢复、`work` 抽锚点）、`Services/SessionCloseout.swift`（`composeWindowSummary` 两个 caller）、`Services/SummaryFileStore.swift`（第一代窗口清单）、`Views/MemoryRegenerationSection.swift`（调试区）、`Views/WindowSummarySheet.swift` + `Views/MemorySessionsView.swift`（窗口总结格）。

## 验证

- mac / iOS `build-for-testing`：`** TEST BUILD SUCCEEDED **`。
- mac 定向 21 套件 219 测全过：MemoryRegenerationTests（扩 4）、MigrationClassifyTests（新 9）、MemoryMigrationTests（新 9）、WindowSummaryReadTests、WindowSummaryRecompressTests（扩 1）、RecallWindowSummaryTests、SessionCloseoutQueueTests、PendingStoreTests、TimelineWriterTests、TimelineWriterPendingTests、PromptRealPathGoldenTests（原样过，金样文件没动）、InspectorRealPathTests、MainThreadIOBudgetTests、MemoryThreeViewsTests、WriterTriggerTests、FragmentPoolTests、MemoryHealthWarningTests、WriteBudgetTests、SettingsSkeletonTests、SettingsSearchTests、ToolRegistryTests。
- 数据安全三条都有测试锁住，并且看过红：
  - 恢复只动 covered：先只加清单字段、恢复照旧 → `testRestoringMigrationBackupBringsPendingBack` 红（旧恢复撞上 pending/）→ 改恢复 → 绿。
  - 每窗口事务 / 待续撤回 / 备份核对：实现后故意改坏三处（A2 写完就落盘、不撤待续、拷完不比大小），`testWindowFailureLeavesThatWindowUntouched`、`testTimelineFailureRollsBackPending`、`testBackupMismatchChangesNothing` + `testMigrationBackupSizeMismatchPublishesNothing` 全红；改回全绿。
- 测试全用假写手 + 测试楼层（`xctest-mig3` / `xctest-regen-pending`，落在测试宿主的 xctest-home 里），不碰真数据、不发网络请求。

## 1. 边界情况

- **备份同一秒点两次**：备份文件夹按秒命名，同名时发布那步 `moveItem` 失败 → 整趟「没做成，原文件没动」。按钮跑着时是灰的，实际碰不到；测试里第二趟换了时间。
- **跨起点的老收尾段**（start < 起点 ≤ end）：按「起点以后」算，拿掉；它盖的起点以前那截只剩备份里有（起点以前的消息不给写手，补不了）。**→ §6 #4 已改：跨起点的整段留着。**
- **起点以前、已经有 sessions/ 的窗口**：不在范围，一个字不改（含挂着的老收尾段，记忆 app 里灰字一组）。
- **没有起点**（「记忆从哪天开始」没设、也没有改版后写的段）：只落第 0 段，确认框单写一句。没设起点时起点退回「第三刀最早一段」，同 v4-1。
- **写手跳过分不清原因**：预算闸拦下和模型返回空内容都是 nil，统一写「被预算闸拦下或模型没回内容」。
- **尾段被拦下时 A3 还会调一次**：尾段和 A3 走 `composeWindowSummary`，尾段返回 nil 它照样压 A3；窗口最后判没成、整个丢掉。被预算闸拦的那次不花钱，模型回空的那次 A3 白调一次。
- **断网 / 被掐断的判定**沿用 `SessionCloseout.isTransient`（取消、`.cancelled` / `.networkConnectionLost` / `.notConnectedToInternet`）；别的网络错（超时等）算这个窗口出错，连着 3 个就停。
- **跑到一半关总开关**：搬迁不按单项 / 总开关逐次闸（同「现在写」），只在按钮上灰；跑着时关了总开关会接着搬完这一趟。
- **并发**：日常写手靠 `setRegenerating` 停；C2 照跑（不碰这几个文件）；{助手}的 `pending_notes` 可能同时改待续本子——撤回只删「这一窗口新加的 id」，不会抹掉她 / 助手的改动。时间轴提交直接原子写月文件，没拿 `TimelineStore` 的写锁（日常写手停着，没有别的写者）。
- **App 被杀**：`regenerating` 只在内存，重开就没了；暂存目录 `staging-<时间>` 可能留在记忆备份里（只在正常返回时清）。一个窗口提交到一半被杀（sessions 换了、windows 没换）→ 下次分类分进「尾段 + A3」，尾段写过了不重写，只补 A3（有测试）。
- **iOS 常亮**只在跑的时候开、结束 / 停下关；她手动切走 App 时请求被掐，按断网停。

## 2. 与下一模块交互的风险

- **文件格式没变**：sessions / windows / timeline / pending 都是原来的格式；注入、锚定、recall 代码没动 → 金样原样过。搬完以后**数据**变了：注入的 A2 里老式段的【待续】没了、老收尾段那截有了正式段（plan §十一，就是要的效果）。
- **接口改了**（调用方都已跟上）：
  - `WindowSummaryReader.Doc` 从 `segments` 改成 `a3` / `a2` / `oldCloseouts`；`listAll` / `merge` 删了，列表改 `WindowSummaryListLayout.rows(windows:sessions:aliveTitles:)`。
  - `WindowSummaryReader.contextSegments` 现在留尾段（只去老收尾段）。
  - `WindowSummaryListLayout.queueNote(masterOn:a3On:a4On:queueEmpty:)`。
  - `SessionCloseout.composeWindowSummary(... tailCaller:windowCaller:)`。
  - `MemoryRegeneration.Manifest.covered`（可选，老清单解码照旧 = 老三个）；`restore(..., profileId:)` 恢复完清待续缓存。
- **待续本子第一次迁移**可能发生在搬迁里（第一个要补时间轴的窗口先 `PendingStore.migrateIfNeeded`），和日常第一次收尾的行为一样。
- **recall**：v5 窗口给编号时只拿到 A3 一段（v5 本来的设计，没在本单动）；搬完以后更多窗口变成这样。

## 3. 技术债

- **老「按新规则重写」引擎没删**：`MemoryRegeneration.run` / `estimate` / `rewriteTimeline` / `swap` / `refile` / `windowIds` 没有界面入口了（按钮换成搬迁），代码和 8 个老测试先留着；`work` 和备份 / 恢复被搬迁复用。要删另开一单（车头定）。`work` 改成可选留起点以前的老收尾段、锚点抽成 `apiAnchor`，老行为不变（默认不留）。**→ §6 #15 已删。**
- **估钱估时是粗的**：输出按每次 1500 token 上限算（偏贵），时间先按 25 秒 / 次，跑起来按实测平均改；没对过她的模型。
- **先算和真搬各读一遍主线消息**（每个候选窗口两次 fetch）；她 1700 个对话里，候选只取起点以后动过的 + 只有第一代老摘要的，Air 上要算多久没测。
- 搬迁的模型调用记了账（`MemoryWriteLog` 的 CostMeter 算「已花」，`modelCaller` 照常 commitSpend），但**不写记忆日志、不改健康状态**（research §7 说了不塞）。
- 窗口总结格列表读 windows/ + sessions/ 两个文件夹全量（之前也是两份都读）。
- 只有 windows/ 一段 from>0、没有 sessions/ 的 v4-1 窗口（理论上有），搬之前点进去只看到「还没压成窗口总结」，抄本内容不显示；搬完就正常了。**→ §6 #13 已改：灰字一组显示。**

## 4. 和 plan 不一样的地方

- **M6 暂存**：新的 A2 / A3 在内存里攒好（不落盘），只有时间轴写进 `记忆备份/staging-<时间>/timeline/`；提交顺序和「全成才提交」一样。效果相同，少一次拷贝。
- **M5 停的条件多一条**：连着 3 个窗口「出错」（非格式、非断网，比如模型报 4xx）也停；格式不对不算进连续。
- **确认框分类不互斥**：「a 个只要补尾段和重压窗口总结，b 个要补写上下文摘要，c 个要补时间轴」——补时间轴的窗口也可能在前两类里，三个数加起来不一定等于总数。
- **没有要搬的**：不弹确认框，下面一行「没有要搬的：N 个窗口已经是新样子」。
- **W2**：「记了 N 段」在 N = 0（只有窗口总结、没有 A2）时不写。
- **恢复确认框**按这份备份的清单写它管哪几样（v5 搬迁 = 五样、v4-1 = 三样）。
- 多了一个套件 `MemoryMigrationTests`（E1 没列）放真跑的测试。
- M1 的 `MigrationKind` 实际叫 `MemoryMigration.Kind`（+ `Plan` 带 `needsTimeline`），挂在新文件 `MemoryMigration.swift` 里，没塞进 `MemoryRegeneration`（它只出备份 / 恢复 / `work`）。

## 5. 没验到的

- **界面一眼没看过**：不能开模拟器，W6 的 390 宽（mac 右栏 / iPad 窄卡）详情页**没看过**；调试区确认框、进度行〔停下〕、结果段、窗口总结格新排法都没在模拟器 / 真机上看过。
- 没调过真模型：分类 / 补写 / 估算都只在假写手上对过；她的真实数据量、花费、耗时、她各层跑没跑过 v4-1 重写都没看。
- iOS 切后台时请求断掉的具体错误码（按断网处理）没实测；`isIdleTimerDisabled` 没在真机上看。
- 说明书只改了事实层 `manual/facts/modules/memory-settings.md`，没跑 `npm run check`（工位没装 node_modules，装要联网）、`npm run rewrite`（会调模型）、`npm run build`。

## 6. astra 裁决（2026-10-16，14 条 + 清老代码）

每条先有测试，再用一批「把修复改回去」的变异整体编一遍确认新测试全红（20 个新测试 + `testTimelineFailureRollsBackPending` 红），还原后全绿。

| # | 改了什么 | 测试 |
|---|---|---|
| 1 | 恢复回退逐项删拷回的 / 挪回原件，有一样没成就整份留着、抛 `rollbackIncomplete(路径)`，不清理 | `testRestoreRollbackFailureKeepsAside` |
| 2 | 提交前落「正在搬」标记（`记忆备份/正在搬/<窗口>.json`：A2 / A3 原文、这个窗口在各月的原条目、真加进待续的编号），全提交完才删；提交半路失败当场按它撤回；被杀了下次点先撤回再重搬（先算时按撤回以后的样子分） | `testHalfCommitMarkerIsRolledBackAndRedoneOnRerun`、`testCommitFailureRollsBackOnTheSpot` |
| 3 | `a2Work` 按段在主线上的实际覆盖求空缺：拿掉的段盖的、起点以后、留着的正式段 + 要补的 + 尾段都没盖到的逐个补写；拿掉的段在主线上找不到 = 补不上，这个窗口不搬、列进没成 | `testIncrementalFillsMiddleGapOrRefuses`、`testUnlocatableOldSegmentWindowLeftAlone` |
| 4 | 「起点以后」改成整段在起点以后开始（分类 / `work` / 增量都是）；跨起点的段留着当老内容；时间轴只换整天在起点以后的条目 | `testSegmentsCrossingStartAreKept`、`testWorkKeepsSegmentsCrossingStart`、`testTimelineEntryCrossingStartIsKept` |
| 5 | 备份前递归查五个文件夹，有符号链接就抛 `symlink(路径)`，什么都没建 | `testSymlinkStopsBackup` |
| 6 | `MemoryMaintenance`（@MainActor 单例）：搬迁 / 恢复原子拿资格、互斥、同时只一趟；停日常写手、iOS 常亮由它统一放开；两个入口共用、按钮跟着灰 | `testMaintenanceGateIsExclusiveAndReleases` |
| 7 | `PendingStore.replacingFiles`：恢复整段拿待续的锁，出来（成 / 败）都清缓存；期间加待续 / 改三态 / 改字都等着 | `testPendingEditDuringRestoreWaitsAndLandsOnRestored`、`testRestoreFailureStillForgetsPendingCache` |
| 8 | 待续记在 `PendingStage`（内存），时间轴提交成了才 `commitAdditions`，编号写进标记再写盘；撤回只删编号 + 窗口 + 原文都对上的 | `testPendingStagedUntilTimelineCommits`（+ #2 两个） |
| 9 | 严格读：`SessionSummaryStore.loadStrict` / `parseStrict`、`SummaryFileStore.loadStrict`、`TimelineStore.entriesStrict` / `monthsStrict` / `mutateStrict`、`PendingStore.checkReadable`；读不了 / 机读注释数对不上就抛（`MemoryReadError`）；坏的窗口不搬、报路径；有月文件或待续本子读坏时不补任何时间轴，月文件绝不写回 | `testCorruptA2FileIsNotOverwritten`、`testCorruptTimelineMonthIsNeverWrittenBack` |
| 10 | `inventory`：逐个文件大小 + SHA256，列目录 / 读属性 / 读内容失败都抛；清单记 `files`；恢复前按清单核，多了少了改了都拒绝；拷回后再核 | `testBackupSameSizeDifferentContentIsMismatch`、`testUnreadableFileStopsBackup`、`testRestoreRefusesBackupNotMatchingManifest` |
| 11 | 现在的全部挪开后、拷回前就发布「回滚前」（带清单）；启动时自动处理未完成恢复——按裁决不做 | `testRestorePublishesAsideBeforeCopyingBack` |
| 12 | 每次模型调用前后、提交前都查取消；进了提交不查，靠 #2 标记做完或撤回；停在哪如实写 | `testStopAfterLastCallDoesNotCommit` |
| 13 | 窗口总结详情：windows/ 认不成 A3 的旧抄本放灰字一组「旧窗口总结（v4，还没搬）」，不算段数 | `testOldWindowsCopyWithoutSessionsStillShows` |
| 14 | 换失败类别清另一个计数；格式不对、读不了、补不上打断「连着」 | `testInterleavedFailuresAreNotInARow` |
| 15 | 删老「按新规则重写」：`MemoryRegeneration.run` / `estimate` / `rewriteTimeline` / `refile` / `swap` / `windowIds` / `Writers` / `Report` / `Estimate` / `move` / `fileSizes`、`WindowWork.timelineParts`、`work(keepOldCloseouts:)`、`composeWindowSummary(writeTail:)`，和只测它们的 7 个老测试；`testRestoreMatchesBackup` 改成不经老引擎 | — |

裁决以后的新边界 / 债：
- 有月文件读坏时，那个月里有条目的窗口也会被当成「起点以后没 v2」→ 要补时间轴 → 整个窗口不搬（宁可不搬）。
- 恢复成功会删掉全部「正在搬」标记（恢复了，标记记的「原来」不作数）；恢复的是不管待续的老 v4-1 备份时，半成品加进待续的那几条不会撤。
- 老清单（没有 `files`）的备份照旧能恢复，只核文件夹在不在 + 符号链接，拷回后按备份现状核。
- 「正在搬」文件夹删空了也留着（空目录，不在备份列表里）。
- `PendingStore.migrateIfNeeded` 仍可能在搬迁中第一次写待续本子（同日常第一次收尾，只从时间轴拆，不属于某个窗口）。

## 7. 真机「一直卡着不动」修补（2026-10-16）

粟粟 Air 上点「搬成新样子…」后一直不动。读码判断不是死锁，是「在等 / 在跑但界面不出字」：
- 点完先在 `SessionCloseout.waitUntilIdle` 等日常写手写完，原来没上限、`try?` 吞取消、期间进度行空白、按钮灰着；
- 一个长窗口要十几到几十次调用，原来进度只在窗口开头报一次。
- 核实：busy 声明没有泄漏（4 个 claim 点都 defer release）；记忆写手非流式是 60 秒空闲超时，不是 600 秒。

改法：等待 60 秒上限 + 可取消 + 说出在写谁；搬迁每次调用 120 秒超时（走「出错」分支）；进度细到步骤；不超过 5 条主线消息的窗口一律跳过（规格 5½，口径 = 搬迁实际喂给写手的主线消息数，不新增 fetch）。

astra 5 条全收：取消在进门 / 返回 idle 前 / 进 body 前都查；备份逐文件、撤回逐窗口、清点逐窗口响应〔停下〕并如实写做到哪；太短判断挪到起点前；段号按分段循环真实序号、重写标「（重试）」；进度回调带 runID。

留着的：记忆写手非流式只有 60 秒空闲超时，慢的思考模型会报超时计「出错」（连 3 个停）——日常写手共用路径，没动；超时放弃的调用若服务端其实回了，钱照记、结果丢弃。

