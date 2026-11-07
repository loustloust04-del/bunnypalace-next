# C2/C3 v2 · P6 复盘：第 6 段「P3 种子」

范围：`plan-memory-c2c3-v2.md` 第 6 段 A–E 共 22 条 + 提交 6。基线 HEAD `5b4d38809`（工作区干净）。按实现单不做 git 写操作、不开模拟器、不碰设备、不跑真端点、不碰真人数据。😷 iPhone 14 实跑和五处可视化交车头（走查单 `walkthrough-memory-c2c3-v2-p6.md`），**未冒充已验**。行号以本次工作区为准。

期间另一个 session 在同一工作区改分词（`MemoryService.swift`、`RecallTool.swift`、`Search*`、`CatalogRetrievalTests.swift` 新增一条、`TokenizerKernelComparisonTests.swift` 等），本段没碰那些行；`CatalogRetrievalTests.swift` 两边都改了（本段只删了一条旧种子测试），提交时注意分开。

## 0. 逐条交回

**A 清旧（一次性 cutover）** — `Services/Wiki/CatalogSeedCleanup.swift`（新）

1. 只清三类：旧 `.seed-state.json`、全部旧 origin=seed 提案（任何状态）、旧种子提案**已批新开页**及其 `.history`；不碰 CC、Prompt、非种子提案 / 页 `:44-63`。清理整段拿着审批锁（`WikiProposalReview.exclusive`，`WikiProposal.swift:461-464`），又在会话的 CatalogLock 里跑（`CatalogRunner.swift:435-487`）。
2. 认定只看提案记录：`isLegacy` = origin seed 且既不是新目录（无 `.seed` 目录项）也不是新正文（无 directionRef）`:39-42`；不看标题、不追 regroup。
3. 旧种子改过的非种子页（已批的非新开页条目的目标）只进 `touched` 清单；另列「还连着被删页」的页 `danglingLinks`，都不动 `:48-62`，写进结果摘要 `:25-35`、记忆日志、`.runs`。
4. 备份复用 `MemoryRegeneration.makeBackup(folders: ["wiki"])`（memory 旁「记忆备份/种子清理前-时间」，`.partial` 暂存、逐文件大小 / SHA256、清单后发布），清理清单 `种子清理清单.json` 写进备份根，再 `verify` 一遍才删 `:75-96`；备份前缀加入可恢复列表 `MemoryRegeneration.swift:74-77`。删除先全部挪进 `.proposals/.seed-cleanup-*` 暂存夹，任何一步挪不动就全部挪回再抛 → 删除数 0 `:99-130`。
5. 删后 `rebuildAllIndexes`，收掉只剩 INDEX.md 的空分组 `:132-142`；索引重建失败单独记，不当清理失败。旧 `.runs` 不动。失败时会话报「清旧种子没成，一个都没删：…」，不读原料、不发请求 `CatalogRunner.swift:452-461`。
6. 删了 `CatalogSeed.topics`、`CatalogFragment.sourcePath` 伪碎片包装（`CatalogSorter.swift:18-32`、`CatalogWriter.swift` resolve / covered / single / userContent）、旧 `seed(reseed:)` 逐主题写手路径和 `CatalogJob.seedFloorPrompt`。完成标记改为带 taskId 的新格式，旧格式只用于识别要清的旧状态，界面不再被它拦 `CatalogSeed.swift:224-249`、`MemoryWriterPages.swift:219-330`。

**B 一个 CatalogAgent 任务**

7. 两个入口「从人设生成基础 wiki」「从 CC 记忆播种」→ `CatalogRunner.seed(profile:entry:)` → 同一个 `CatalogSession.seed(entry:)` `CatalogRunner.swift:426-487,940-962`。任务绑定楼层、模型名、目录 id（checkpoint `CatalogSeedTask`，`CatalogSeedTask.swift:68-210`）；续跑时 C3 模型换了就拒（不换模型）`CatalogRunner.swift:507-511`。原料 = Prompt 完整底图 + CC user/project 合格文件 + wiki 根索引和每页全文，每份带版本 `CatalogSeedTask.swift:40-63`；没有任何原料直接跳过不调模型。
8. `private_` 沿 `CatalogSeed.load` 不打开只记数（开场「【没读的】跳过 N 份私人文件」）；feedback / 日记 / 类型不明跳过列名；规矩 / 指令不进 wiki 写在种子系统提示里 `CatalogSeedTask.swift:425-466`（代码不做关键词过滤）。
9. 同一个 CatalogAgent 类、同一个 Deps / 后端 / step / trace（把这几个成员从 private 放开，`CatalogAgent.swift`）；新循环 `CatalogSeedAgent.swift:55-212`，不调 CatalogSorter、不用 search_aline/search_fragments、不按页开 agent、不先抽事实。读过的全文在回合里，续跑不重读（读过的再读回一句）`:225-240`。
10. 没有日常 resultLimit / maxToolChars / 轮数上限；read 回执是原料全文。服务商「上下文太长」（复用 `ChatErrorClassifier` 判定）→「这次完整种子材料超出当前模型上下文，尚未完成（第 N 轮 · 模型 X）。服务商原话：…」，不记完成 `CatalogSeedAgent.swift:159-165`、`CatalogSeedTask.swift:489-497`。种子 Deps 只过全局总闸 `CatalogBudget.globalGate`、用量记新 `UsageKind.catalogSeed`「wiki 种子」，不在写入预算的五类里 `CatalogRunner.swift:1020-1031,1056-1060`、`UsageLedger.swift:5,13`。停止照旧。

**C 工具最少**

11. 只两个工具：`read`（白名单 = 本次原料清单；不在清单的一律拒）和 `submit_proposal`（同名，加 `phase` outline/page、`item`、`outline`，复用条目 schema，记录改 `sources`）`CatalogSeedTask.swift:298-372`。写只经宿主：目录 = `.proposals/<任务 id>.json`（方向提案，mode `.seed`），正文 = 一页一份 `.proposals/<uuid>.json`（directionRef 指目录项），checkpoint = `.proposals/<任务 id>/task.json`。agent 指定不了正式页 / INDEX / 状态 / 别的任务。
12. `FileLibraryTools` 没改（测试确认主聊天 fs 写 `.proposals`、wiki 页、任务快照都拒）。taskId = 目录提案 UUID；目录 / 正文先存成功再回成功，目录存了 checkpoint 存不上就撤回目录 `CatalogSeedAgent.swift:194-201`；同一目录项再交回「已经交过了」，不落第二份 `:305-307`；正文记到目录项失败就撤回正文 `:330-336`。
13. 文件库 记忆 › wiki ›「种子待批」：每个任务一个文件夹，「目录」+ 各页稿，数据就是待批提案（`CatalogSeedDrafts.swift`，显示 `FileLibrarySeedFolder.swift`，面板接线 `FileLibraryPanelView.swift:291-302,1485,1547`）。目录可改路径 / 七类 / 标题 / 钩子 / 原料，页稿可改新开页整页 / 追加记录 / 新「现在」；保存先和打开时比（别处改过拒），再核路径、七类、出处（只能是这一条原有的出处）、页版本，已批 / 驳回只读，走 `WikiProposalReview.edit`（批量版同锁）`CatalogSeedDrafts.swift:107-244`、`WikiProposal.swift:266-280,466-474`。审计台「改」对种子目录项也能改类和原料 `WikiProposalViews.swift`（编辑表单）、`WikiProposalDisplay.swift`（Draft）。审计台批时带上她看到的内容，存着的变了就拒批 `WikiProposal.swift:343-353`、`WikiProposalViews.swift:676-688`。

**D 两批**

14. 读完才能交目录（没读完的回执列出来）；目录项校验路径、七类、原料都读过、同路径去重；交完 `.outlineSubmitted` 暂停，后台不再请求 `CatalogSeedAgent.swift:249-287`、`CatalogSeedTask.swift:374-396`。
15. 审计台批 / 驳回种子目录 → `runner.resumeSeed` → 从 checkpoint 接同一段会话：审批结果作为控制消息接在上一个回执后面（已批待写 / 已交 / 驳回 / 还在等批，带她改过的路径 / 类 / 标题 / 钩子 / 原料）`CatalogSeedTask.swift:468-487`；只写获批未交的项，交完一页能接着下一页，获批的都交了就停 `CatalogSeedAgent.swift:136-139`。
16. checkpoint：任务 / 楼层 / 模型、完整 history、工具回合 DTO（calls / results / provider 内容块 JSON / 思考）、原料清单与读到的版本、目录关系（目录项上记 contentProposalId）、记录链接、轮号；每轮存一次 `CatalogSeedTask.swift:68-225`。执行重取楼层锁（runner.start），不长持锁等批。
17. 种子提示词：可重述人设事实、不按底图去重、不只留空架子；事实与规矩分开；钩子 = 使用场景；无日期写「日期未注明」`CatalogSeedTask.swift:425-466`。
18. 出处 = 读过的 Prompt 槽 / 字段、CC 文件、wiki 页 / 索引（`Cite.layer` Prompt / CC / wiki + filePath，Prompt 带显示名）；复用 `CatalogItems.parse` 校验，没出处 / 出处没读过的行丢；已有页走版本基线、只出更新 `CatalogWriter.swift:132-146,196-213`、`CatalogSeedTask.swift:340-372`。
19. 第二批照旧 `WikiProposalReview.approve` 写页 / 历史 / 索引；目录批准、草稿存在都不落页；版本变了 stale。

**E 完成与可视化**

20. 完成 = 目录无待批 + 至少一项获批 + 获批项都有正文提案（正文待批不拦），才写 `.seed-state.json`（带 taskId）；部分批 / 空目录 / 全驳回 / 停 / 失败都不记 `CatalogRunner.swift:572-600`、`CatalogSeedTask.swift:141-152`。
21. 同一份 `.runs`：每轮请求（首轮全量、之后增量）、模型回复、每个工具实际回执、目录 / 正文校验、停下原因；续跑 `CatalogRunRecord(continuing:)` 接着写同一份 `CatalogRunRecord.swift:41-62`；记忆日志每轮一行带链接 + 本轮锚点 `CatalogSeedAgent.swift:366-374`；目录 / 正文提案存 `run` 链接，详情页「这次的整理记录 ›」`WikiProposalViews.swift:280-286`、`MemoryWriterPages.swift`（`MemoryWriteLogRunReader.load(link:)`）。
22. 30 天清理跳过还没结束的种子目录（`CatalogSeedTaskStore.keeps`），结束了的连任务快照一起清 `WikiProposal.swift:236-252`、`CatalogSeedTask.swift:287-291`。

## 1. 边界情况

- **批了但 C3 关着**：`resumeSeed` 直接不跑，目录项停在「已批 · 等种子任务写这一页」；二级页给「继续这个种子任务」（C3 关着时灰）。
- **原地打转**：同一处（目录 / 某目录项）连交 3 次不合格、或连两轮不调工具才停（`seedInvalidLimit`）。这不是原料上限，但确实是一道「停」——拿不准是否算 plan 说的人为闸门，见 §4。
- **续跑只补控制消息，不改历史**：控制消息拼到上一个回执末尾（同日常 agent 的提醒做法），checkpoint 里会留下这段；多次续跑会叠几段，模型看最后一段。
- **读的时候原料没了**：续跑在读阶段重新取原料，清单里某份不见了 → 回「已经不在了」并当作读过（版本空、不能当出处）。
- **改目录路径到已存在页**：动作按新路径重算（更新已有页），agent 写时只能交更新；改到不合法路径保存就拒。
- **页稿只覆盖三种**：新开页 / 追加记录 / 新「现在」能在文件库改；连线、改钩子只读（审计台「改」能改）。
- **审批锁内的清理**：清理和批 / 驳回互斥，但和日常 C3 的方向执行之间靠 CatalogLock（同楼层）互斥；别的楼层不受影响。
- **旧种子新建页后来被她手改过**：仍按提案记录删（备份里有）；她要的话从「记忆备份/种子清理前-…」恢复。
- **停在目录交了之后、checkpoint 存之前崩溃**：目录 json 在、任务快照还是读阶段 → 续跑会再交一次目录，`submitOutline` 发现 outlineSaved=false 会覆盖同 id 目录（同一份文件，不会多一份），但这次的历史比上次少一轮。

## 2. 与第 7、8 段交互的风险

- **第 7 段 A4**：种子不读 A 线 / A4，没有交集；但 A4 迁移备份前缀若再加，记得一起进 `MemoryRegeneration.backups` 白名单（这次加了 `种子清理前-`）。
- **第 8 段四来源发现**：`CatalogSorter.priorDirections` 会把**待批的种子目录项路径**算成「待批方向」，自动发现不会对同一页再提方向（合理，但种子目录长期挂着会压住日常发现）；种子目录项的 `clues` 是空的，`pendingFragmentIds` 不受影响。
- **第 8 段 `valid_until`**：种子新开页现在没有这字段；第 8 段加 WikiPage 字段时，`CatalogSeedDrafts.parsePage` 用的是 `WikiPage.parse`，新字段要能往返，否则文件库改页稿会丢。
- **第 10 段 Faithfulness 收口**：种子出处现在走 `CatalogSources.files` 一个口子；第 10 段统一来源检查时要把它并进去，`CatalogSeedTools.label` 和 `CatalogSeedDrafts.checkRecords` 的出处文字口径要一起改。
- **方向模式多了 `.seed`**：`claimDirections` / `closeDirections` / 日常 `execute` 都跳过它；第 8 段若新增方向执行入口，要同样跳过。

## 3. 技术债

- 正文提案落在 `.proposals/` 顶层（和日常提案一样），只有 checkpoint 在 `.proposals/<任务 id>/`；plan 原文「保存到 `.proposals/<本次id>/` 待批区」是按「同一任务的待批数据」理解的，没有把提案文件挪进子目录（挪了审计台和 30 天清理都要另读一处）。见 §4。
- `.runs` 增量记录：只有首轮 / 每次续跑首轮是完整请求，中间轮要往前拼；提醒 / 控制消息改了上一回合，所以每轮都重记上一回合。
- 文件库「种子待批」每次 reload 都在后台全量 `WikiProposalStore.list()`；提案多了要做缓存。
- `CatalogSeedDrafts` 的目录文本格式是手写解析（`## 序号` + `键: 值` + `原料:` 列表），不容错多余格式；改坏了直接报错不存。
- live 方法 `testSeedOutlineThenPagesThenWikiLive` 断言「回答时先给结论」不进提案，依赖模型理解规矩 / 事实之分，可能偶发红。
- 说明书 `scripts/manual` 的 `npm run check` / rewrite / build 没跑（同前几段，工位没装 node_modules）。

## 4. 偏离 / 没做到 / 拿不准

1. **没做真机**：😷 iPhone 14 实跑完整种子、五处可视化逐项看都交车头（plan 写「少一处不得勾」）。plan 里提交 6 的勾我按实现单要求勾了，但写明真机未验；车头验完不过请取消勾。
2. **待批区目录结构**：见 §3 第一条。
3. **防打转的停**：`seedInvalidLimit = 3`、连两轮不调工具即停。plan 只说不设原料 / 文件 / 页数上限，没禁这种卡死保护；车头若认为也算人为闸门，删 `CatalogSeedAgent.swift:9` 那两处判断即可。
4. **「去掉指向已删页的连线残项」**：理解为重建生成的索引；非种子页里写着的「连到」不改（plan 同时写了不碰非种子 wiki），只列进 `danglingLinks` 给她看。
5. **续跑换模型**：plan「不自动换模型」——实现成换了就拒续跑并说明，没做「沿用任务开始时的模型」（那要绕开 C3 设置另建后端）。
6. **种子目录项「为什么」**：方向项的 `reason` 固定写「种子目录」，界面对种子项显示「原料」代替「为什么」。
7. **iOS 测试包**：`build.sh … mask` 的 build-for-testing 用了 😷 的设备 destination 编测试包（只编不装、不跑）；iOS 应用用模拟器 destination 编。
8. **金样**：两组金样未变、未 RECORD；`CatalogAgentTools` 的 schema 改成函数只是重构，日常 agent 的工具定义逐字不变。

## 5. 测试

- **新增** `MemoryPalaceTests/CatalogSeedTaskTests.swift`（12 条）：一个任务全读一次 → 目录暂停 → 部分批 → 同任务只写获批页 → 正文批了才落页 → 剩下批 / 驳回后完成（含两份 user 合一页、一份 project 拆两页、Prompt 自建槽 3000 字后事实、private_ / feedback 不进、坏出处行丢、已有页只出更新 + 钩子、整理记录同一份 + 每轮锚点、页版本 stale）；失败 / 停 / 重启续跑同一任务、不重读、重复不重交；无上限全文进请求（12 份 × 5.6 万字）；上下文超长人话 + 原文；空目录 / 全驳回不完成；白名单 / 交目录前必须读完 / 非法路径 / 非七类 / 没读的原料 / 没批的项 / 别的页条目；清旧三类 + 清单 + 备份可原样恢复 + 只做一次；备份失败（拷贝失败、拷贝对不上、备份根不可写）一个都不删、种子不开跑；文件库目录 / 页稿与审计同一份、只读 / 冲突 / 出处 / 七类校验、审计批时内容变了拒批；「种子待批」挂在 wiki 下 + 主聊天 fs 对 memory 仍只读；30 天清理留未完成任务；种子用自己的 Deps 不过日常写入预算。
- **改写** `CatalogRunRecordTests`：`testSessionLogsAndWriterErrorsPreserveAnchorsWithoutPreflush`、`testSeedRunKeepsSourceAndValidationWithoutWritingWikiPage` 换成新种子路径（每条日志能打开同一份记录并定位、服务商原话进记录、文件回执 / 目录原参数进记录、不落页）。
- **删除**（旧种子路径已删）：共 17 个测试方法——`CatalogSeedTests` 9 条（播种 / 再播 / 预算 / 停 / topics / 旧完成标记），`CatalogScheduleTests` 种子完成标记 8 条。（`CatalogRetrievalTests.testSeedSourcePathOmitsAttributionOnlyInActualWriterAssignedEntry` 的删除随分词提交 `87999873a` 进了库，不在 `bcc13f28b` 里。）其中取消、持久化失败、私人信息不泄漏的语义在返工里按新流程迁回，见 §8。CC 文件过滤 / private_ / 日记等解析测试保留。
- **iOS live**：`CatalogLiveSmokeTests.testSeedProducesProposal` → `testSeedOutlineThenPagesThenWikiLive`（门控照旧，没 key 跳过）：目录（批前只一份提案、零页）→ 全批 → 续跑逐页 → 完成标记带任务 id → 正文全批 → 入库；打印 `.runs` 路径、每轮 anchor 和整份记录 base64。

## 6. 验证

- 基线（改动前，`5b4d38809`；先 `xcodegen generate`，merge 后不生成会编不过）：mac `** TEST BUILD SUCCEEDED **`；37 套 488 测 0 failures（`claude-p6-base-tests.log`）。
- 最终：mac `** TEST BUILD SUCCEEDED **`（`claude-p6-final-mac.log`）；同 37 套 + `CatalogSeedTaskTests`，38 套 522 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`claude-p6-final-tests.log`，含 PromptRealPathGolden / InspectorRealPath 金样原样、SettingsSearch）。iOS 应用（MemoryPalaceIOS，模拟器 destination）`** TEST BUILD SUCCEEDED **`（`claude-p6-final-ios.log`）；iOS 测试包（MemoryPalaceIOSTests，含改写的 live 方法）`** TEST BUILD SUCCEEDED **`（`claude-p6-final-ios-tests.log`）。
- 没跑：真端点 live、模拟器 UI、😷 真机。


## 8. 返工（astra 审查 17 条，基于 `bcc13f28b`）

车头逐条裁定全修。😷 iPhone 14 上 live `testSeedOutlineThenPagesThenWikiLive` 已 passed（目录 5 项 → 5 页入库，7 轮），这次没动它的流程。上面 §3 第 1 条（存储位置）、§4 第 1–3 条（勾 plan、待批区布局、防打转停止）已被本节取代。行号以返工后工作区为准。

1. **【P0】清旧回滚**：删除做成一个事务：先全部挪进暂存夹，再重建索引。任一步出错就逐样挪回，再按快照把 INDEX.md 恢复原样（新建的删掉），每样都核实回到原处。全部回去了才报普通失败、删暂存夹。有一样没回去就抛 `CleanupError.partial`：暂存夹留着，报出没回去的路径、暂存夹和备份位置，会话也不再说「一个都没删」。`CatalogSeedCleanup.swift:63-170`、`CatalogRunner.swift:491-498`。挪动和重建都可注入，方便测失败。
2. **【P0】符号链接**：wiki 原料改走 `SafeWiki.scan`。它自己遍历楼层 wiki 根：根本身是链接或真实路径不在本楼层 memory 内，就整份拒，并记一条「wiki 文件夹是链接…，没读」；文件或文件夹是链接一律跳过，也不进去；每个条目都核真实路径还在 wiki 根内；读正文、分组钩子、生成索引都只用这份结果，不再借会跟链接的 `WikiStore.read` / `layerMarkdown`。`CatalogSeedTask.swift:55-190`。CC 原料沿用 `CatalogSeed.load` 已有的检查（目录真实路径在根内、文件不是链接）。
3. **【P1】完成判定**：同时满足三条才写完成：agent 正常停下（交目录 / 获批页写完）、没被取消、最后一次 checkpoint 存成了。
   - 写入顺序：先把完成态写进任务快照，存成了，再写完成标记。
   - 写标记前后都查取消；被取消或写失败，就把标记恢复成写之前的原样，快照退回没完成。
   - 代码：`CatalogRunner.swift:635,644-700`、`CatalogSeed.swift:247-258`、`CatalogSeedAgent.swift:28-30,47`。
4. **【P1】provider 内容块**：
   - 后端：`AssistantCloudBackend` 在工具轮记下 `lastTurnExtras`（Anthropic 原样内容块 wireContent，含 thinking / 签名 / redacted / 正文 / tool_use，加思考 token 和兼容接口 reasoning），见 `AssistantBackend.swift:28-33,65-90`；`CatalogAgent.Deps.roundTurn` 读出它（`CatalogAgent.swift:225`）。
   - 存：种子把它和这一轮跟调用一起说的正文一起放进 `ToolTurn`，再进 checkpoint DTO（`CatalogSeedAgent.swift:183-190`、`CatalogSeedTask.swift` Turn）。
   - 回灌：`ToolTurn` 新增 `text`（`ChatToolTypes.swift:45`）。OpenAI 兼容路有 text 就当 assistant content 回灌（`ChatService.swift:838`）；Anthropic 没有原样块时，把 text 块放在 tool_use 前面（`:1575-1576`）。主聊天不填 text，请求体不变，金样原样。
5. **【P1】崩溃窗口**：
   - 首次付费请求前先存任务；存不上就不问模型（`CatalogRunner.swift:524-531`）。
   - 模型回了工具调用，先把这一轮作为 `pending` 存进 checkpoint，再执行（`CatalogSeedAgent.swift:183-190`）。重启续跑先处理 pending，不重新问模型（`:138-141`）。
   - 正文用稳定提交 id = hash（任务 id、调用 id、目录项 id），见 `CatalogSeedTask.swift:276-280`；已经存过就直接认，不重存（`CatalogSeedAgent.swift:321-330`）。目录 id = 任务 id，已存就认（`:265-270`）。
   - 续跑前对账：目录存了就认 outlineSaved；正文存了、目录上没记的补记上（`CatalogRunner.swift:538-560`）。
6. **【P1】续跑合并**：
   - 审计台只有这一下真的新批 / 新驳回了目录项才续跑：批之前从盘上重读一次再比；两个窗口重复批，第二次不触发。见 `WikiProposalViews.swift:675-712,726-729`。
   - 新增 `CatalogSeedResumeQueue`（`CatalogRunner.swift:130-155,1062-1075`）：同一任务还在排队，就不再排第二个；正在跑时又来新审批，等它正常结束再续一次；失败 / 停 / 被拦之后，排着的旧请求不再自动付费。
7. **【P1】模型身份**：任务存 `modelKey`（`local:<id>` / `remote:<凭据>/<模型>`），续跑按它比，不看显示名（`CatalogRunner.swift:576-581,1148-1152`）。所选模型这次会回退到别的模型时（本机没下、在后台等），记 `seedBlocked`：开新种子直接拒，续跑也拒，不发请求（`:473-477`）。换了模型就拒绝续跑，这一点保留。
8. **【P1】去掉防打转硬停**：`seedInvalidLimit`、`invalid` 计数、连两轮不调工具即停都删了。不调工具只提醒，交得不合格只回错误让它改。停止只剩：用户点停、真实 provider 报错、全局预算闸。
9. **【P1】实质正文**：新开页没有带出处记录的直接扔；一页的条目里必须有「带出处的新开页记录」或「带出处的追加记录」，才算这一页正文已产出。空页、只改现在 / 钩子 / 连线都回错误，不存、不记到目录上，也就不会因此记完成。`CatalogSeedTask.swift:573-605`。
10. **【P1】页版本基线**：已有页的所有条目，baseVersion 都统一成本任务读到的版本。自动补的改钩子，旧钩子 / 触发词也取读到的那一版（`readText` 从回合里的 read 回执取，不重读盘），见 `CatalogSeedTask.swift:283-293,596-602`。她后来手改过页面，审批时整组 stale，钩子盖不掉她的改动。
11. **【P1】出处贯穿**：
   - 目录项（模型交的、文件库改的、审计台改的）都过 `CatalogSeedTools.checkDirection`：原料必须在已读集合里（`CatalogSeedTask.swift:533-560`）。
   - 写正文时，出处只认这一项最终获批目录的 sources（`CatalogSeedAgent.swift:331`）。
   - 审计台「改」种子提案改走 `CatalogSeedDrafts.saveChange`（`WikiProposalViews.swift:905-915`），和文件库共用 `CatalogSeedDrafts.validate`（`CatalogSeedDrafts.swift:201-236`），同一套路径 / 出处 / 版本校验；正文页路径改不了。
12. **【P1】文件库保存进锁**：读、比 baseline、校验、写回，都在同一次 `WikiProposalReview.exclusive` 里（`CatalogSeedDrafts.swift:251-275`）；审计台改也一样（`:277-293`）。
13. **【P1】同任务连线**：
   - 写正文时，`CatalogSources.linkTargets` = 本任务获批目录项的路径，可以连（`CatalogWriter.swift:64,333`、`CatalogSeedAgent.swift:332`）。
   - 正文审批时再处理目标在不在（`WikiProposal.swift:625-642`）：目标页存在，或同任务里还有它待批的新开页，连线就留着；都没有就扔掉连线（新开页里的），单独的连线条目记页已变。
14. **【P2】各层索引**：每个有页的真实分组都生成一份索引原料（`memory/wiki/<分组>/INDEX.md`，带分组钩子）。历史、提案、备份、`.runs` 本来就是隐藏目录，不进。出处显示「wiki <分组> 索引」。
15. **【P2】留存**：结束时记 `endedAt`（空目录 / 全驳回 / 完成 / 放弃）。30 天清理在清完到期提案后，再清「已结束、满 30 天、文件夹里没剩提案」的任务文件夹，包括没交出目录的。还能续跑的任务不清（`WikiProposal.swift:258-275`）。
16. **【P2】存储收敛**：`WikiProposal.seedTask`，本任务的目录和正文都存到 `.proposals/<任务 id>/<提案 id>.json`；load / list / edit / 清理都会去任务文件夹里找；顶层的日常和旧提案照旧能读（`WikiProposal.swift:159,195-256`）。旧种子认定也排除带 seedTask 的。
17. **【P2】测试与文档**：
   - 删测数量更正为 17 条（见 §5）；取消 / 持久化失败 / 私人信息不泄漏按新流程迁回（见下）。
   - 假模型改成看盘上的任务快照和目录作答，不再解析提示词文案；还加了请求上限，测试不会挂死。
   - plan 的提交 6 勾已取消，改成「工程完成，真机五处可视化未验」。

### 返工测试（`CatalogSeedTaskTests` 12 → 33 条）
- **迁回**：`testCancelBeforeAnythingSendsNoRequestAndKeepsPreviousCompletion`、`testCancelBeforeCompletionMarkerWriteRestoresPreviousState`、`testCancelAfterCompletionMarkerWriteRestoresPreviousState`、`testPersistenceFailuresDoNotCompleteOrAskTheModel`、`testPrivateNamesStayOutOfProposalsLogsRunRecordAndRequests`。
- **新增**：
  - 清理：`testCleanupRollsBackMovesAndIndexesOrKeepsTheTrashWithPaths`。
  - 符号链接 / 下层索引：`testSymlinkedWikiPagesAndFoldersAreNeverRead`，wiki 页链到 private_ 文件、链到其他楼层文件、整个文件夹是链接、wiki 根是链接，都读不到。
  - 完成判定：`testStopRightAfterTheLastPageDoesNotComplete`。
  - 崩溃与对账：`testPendingTurnIsReplayedAndSavedContentIsAdoptedWithoutAskingTheModelAgain`、`testResumeReconcilesSavedOutlineAndUnlinkedContent`。
  - 内容块：`testProviderContentBlocksSurviveCheckpointAndReplay`，覆盖签名 / redacted / 正文 / reasoning details 的编码解码往返、续轮请求原样回灌、无块时正文回灌。
  - 续跑合并：`testResumeQueueCoalescesAndDoesNotRetryAfterFailure`。
  - 模型绑定：`testModelIdentityBindsTaskAndSeedNeverFallsBack`。
  - 不设闸门：`testTextRepliesAreNudgedNotStopped`。
  - 实质正文：`testEmptyOrHookOnlyPageDoesNotCountAsWritten`。
  - 页版本：`testAllItemsOfAPageUseTheVersionReadByTheTask`。
  - 出处：`testSourcesAreLimitedToTheApprovedItemAndEditsShareTheSeedCheck`。
  - 锁：`testFileLibrarySaveComparesBaselineInsideTheLock`。
  - 连线：`testLinkToAnApprovedOutlinePageIsKeptWhileItsContentIsPending`、`testLinkIsDroppedAtReviewWhenTheTargetWillNeverExist`。
  - 留存：`testPurgeKeepsOpenTasksAndRemovesEndedOnesIncludingThoseWithoutOutline`。
  - 存储：`testSeedProposalsLiveInTheTaskFolderAndOldTopLevelOnesStillLoad`。
  - 首次请求前存任务：并进 `testContextTooLongShowsPlainWordsWithProviderTextAndIsNotComplete`，失败后同一任务续跑。
- **改写**：`CatalogRunRecordTests.testSeedRunKeepsSourceAndValidationWithoutWritingWikiPage` 改用新假模型。live 方法没动。

### 返工后的边界 / 债
- 去掉硬停以后，模型一直不调工具或一直交不合格，会一直付费跑，直到她点停、provider 报错或全局预算闸拦下。这是粟粟定的取舍；界面上有轮号可看，「停止」随时可点。
- `pending` 只记「模型回了工具调用、还没处理完」。如果模型回复本身在落盘前就丢了（进程在 step 和存 pending 之间被杀），那一轮仍会重问一次：这个窗口是第一次能拿到回复的时刻，再往前收不了。
- 续跑合并状态只在内存里：app 重启后排着的续跑就没了，要她点「继续」或再批一项。
- 审计台判断「真有新审批」是在批之前从盘上重读一次再比。两个窗口在同一瞬间都读到「待批」的极窄竞争仍可能触发两次续跑，由续跑队列合并：第二次要么被丢弃，要么在第一次正常结束后再跑一次，而那时已经没有未写的页，不会再付费。
- `SafeWiki` 自己生成索引文字，形状和 WikiIndex 生成的一致，但没有共用代码。WikiIndex 以后改索引格式时，要同步改这里。

### 返工验证
- 基线（`bcc13f28b` + `87999873a`，先 `xcodegen generate`）：mac `** TEST BUILD SUCCEEDED **`；38 套 522 测 0 failures（`claude-p6r-base-tests.log`）。
- 最终：mac `** TEST BUILD SUCCEEDED **`；同 38 套 543 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`claude-p6r-t3.log`；`CatalogSeedTaskTests` 33 条，PromptRealPathGolden / InspectorRealPath 金样原样、未 RECORD）。回灌相关 5 套（ThinkingReplay / ReasoningReplay / ProviderOrdering / ParamAutoAdaptRouter / BudgetGate）96 测 0 failures（`claude-p6r-t4.log`）。iOS 应用 `** TEST BUILD SUCCEEDED **`（`claude-p6r-final-ios.log`），iOS 测试包 `** TEST BUILD SUCCEEDED **`（`claude-p6r-final-ios-tests.log`，只编不装）。

## 9. 返工 2（😷 iPhone 14 走查，基于 `a75448d1a`）

走查报告和截图 00–34 在车头 scratchpad `p6-walk/`（含真实楼层画面，不进 git）。③④⑤ 过，① 基本过，② 不过。

### 9.1 P0 整理记录查看页卡死（截图 15、「记忆花园 8303 ms」、冻 9 分钟）
- **根因**（`a75448d1a` 行号）：`.runs` 只读预览把整节交给 Markdown 渲染器，节里每个工具回执 / 请求原文都是代码围栏 → `CodeBlockView`。
  1. 语法高亮：没标语言就 `.automatic` 自动识别（`Packages/SwiftStreamingMarkdown/Sources/MarkdownText/UI/CodeBlockView.swift:38-45`），所以头上显示 unknown / applescript；高亮结果经 HighlightSwift 转 HTML 再 `NSMutableAttributedString(data:options: .html)` 导入（HighlightSwift `Highlight.swift:83-91`），调用方在 `HighlightTaskManager` actor 上，不在主线程。Apple 文档（`NSAttributedString.init(data:options:documentAttributes:)` Discussion）原话：HTML 导入不要在后台线程调，否则它会去跟主线程同步、失败、然后超时。iOS 上每个回执块各卡一次，块多就是几秒到几分钟。mac 上我量的（临时探针，已删）：后台调 HTML 导入 100 / 500 / 2000 行分别 1305 / 279 / 841ms，主线程在这期间最长忙段 3–8ms。也就是说 mac 不会卡死，iPhone 会，mac 复现不了这一条。
  2. 回执不折行：`ScrollView(.horizontal) { ParagraphView(...).fixedSize(horizontal: true, vertical: true) }`，`lineBreakMode = .byClipping`（`CodeBlockView.swift:126-139`）。整块一次在主线程排 TextKit。mac 探针：不折行排 1 万 / 6 万 / 20 万字分别 45 / 77 / 281ms。高亮回来以后 body 重算，又整块重排一次。每次 body 还要把整块 AttributedString 转一遍 NSAttributedString 并枚举属性（`CodeBlockView.swift:110-134`）。
  3. 懒加载只到节：`preparedPreviewStack` 一节一行（`FileLibraryPanelView.swift:2454-2490`）。种子第 1 轮 16 份回执、第 2 轮请求里回灌的全文都挤在一行里，进视口就整节一起排。
- **最终修法（粟粟 10-22 拍板，原生实现；改道经过见 §9.9）**：只改 `.runs` 只读预览。文件库里别的文件、聊天页、编辑器都没动，也没抽成通用组件给别处用。
  - **解析**：`MemoryPalace/Views/FileLibrary/RunRecordDocument.swift`。后台按 `<a id>` 分节，节里拆代码围栏，每段保留原始区间（拼回逐字节等于原文）。
    - 节里每个 `#` 标题单独一行；叙述按空行分段，原地显示；`<a id>` 行不显示。
    - **每个代码块都折成一张卡**，不按长度决定折不折。卡名取紧挨着的「正文：」「argumentsJSON：」「### 系统提示」这类标签，没有就用语言，再没有写「原文」。
    - 整理记录不再走 SwiftStreamingMarkdown，也不做语法高亮。
  - **分行 / 围栏**：`RunRecordScanner.swift` 被分节器（`FileEditorPreviewLocation`，`FileLibraryPanelView.swift:1898-1935`）和拆围栏器共用，修了 astra 的两条：
    - 按 utf8 字节切行，认 LF / CRLF / CR，行尾原样保留（`:14-35`）。
    - 一个 `FenceState` 状态机，缩进按 CommonMark 列宽算（tab 跳到 4 的倍数，`:67`），开栏和闭栏分开判断（`:94` / `:106`）：反引号围栏的 info 不能含反引号，闭栏后面只能有空格或 tab。
  - **后台、可取消**：`RunRecordDocument.load` 用 `Task.detached` 加 `withTaskCancellationHandler`（`:44-51`），分节、拆围栏、出行之间都检查取消。视图在 `.task` 里调它（`FileLibraryPanelView.swift:2450-2466`），关页或换文件就停。视图 init 里不再整份扫 anchor（`:2123`）。
  - **iOS**：`RunRecordListView.swift:131-302`。
    - UICollectionView 用 flow layout，行高按当前宽度直接算（`boundingRect` 和 UILabel 用同一字体），不估高。
    - 卡用 `UIHostingConfiguration` 嵌 SwiftUI 卡。
    - 锚点：第一次有宽度时 `scrollToItem(.top)` 一次滚准（`RunRecordCollectionView.layoutSubviews`）。
  - **mac**：`RunRecordListView.swift:305-485`。
    - NSTableView 一列，`heightOfRow` 用同款 NSTextField 的 `cellSize` 量准。
    - 标题和叙述是可选中的原生标签；卡是 NSHostingView 里的 SwiftUI 卡，`hitTest` 把点击交给表格。
    - 锚点：`rect(ofRow:).minY` 直接滚过去（`:388-395`），宽度一变整表重量行高（`tile`）。
  - **卡**：`RunRecordBlockCard`，照 page1 工具调用卡的折叠行做：图标、名字、「· 共 N 字」、首行摘要单行截断、右侧 chevron。底色用 `Theme.accent`：page1 那张卡的 `mainBg` 底放在文件库的 `mainBg` 上看不出来。
  - **sheet**：同一个 `DisclosureSheet`，加了 `scrolls: false` 参数（默认 true，别的调用方不受影响），让壳不再套 ScrollView。里面是原生只读文本视图：iOS `UITextView(usingTextLayoutManager: true)`，mac `NSTextView.scrollableTextView()`（实测就是 TextKit 2）。等宽、可选中、不高亮、不切段、不折叠，整块原文一字不差。头上有「复制」，复制的是整块原文。
  - **删掉的**：
    - 切段（≤600 字 / ≤15 行）、「展开全文」、懒排整块；
    - 1.5s 跟随计时和整理记录那条路上的 LazyVStack 估高；
    - `RunRecordPreview.swift` 整个文件；
    - 旧测试 `testLargeRunOpeningKeepsMainRunLoopResponsive`、`testSeedReceiptRecordStaysResponsiveAndAnchored`、`testRunRecordPreviewKeepsEveryCharacter`（它们测的是 NSTextView 首屏和切段，实现已经不存在）。
- **定量**（mac Debug 离屏宿主，双观察者 common modes，单跑；负载 6–20；iPhone 14 复测由车头做）：
  - 31.3 万字种子形状夹具，720×640，首屏 + 第 1–4 轮 + 末尾，每种 3 次：

    | | 落位 ready | 单次最长忙段 | 落点 |
    |---|---:|---:|---|
    | 走查版 `a75448d1a`（Markdown + CodeBlockView，§9.1 根因） | 369–815ms | 181–370ms | 第 3 轮静置后被推走，往回划一下就找不到 |
    | 切段版 `3294acd33`（LazyVStack + 1.5s 跟随） | 77–190ms | 36–67ms | 标题顶边 35pt；靠计时跟随 |
    | **原生版（本次）** | 50–121ms | 30–80ms | 标题行顶边 **0.0pt**；后面不满一屏时停在底，第 3 / 4 轮 / 末尾分别在 122 / 348 / 574pt；落位后不漂 |
  - 冷开（进程里第一次建表格和卡，单独记，不设门槛）：ready 75–321ms，忙段 242–273ms。
  - sheet：
    - sheet 那一页直接上屏：30.7 万字 31–66ms，10 个字 38–89ms，两者一个量级。
    - 走真实 `.sheet` 弹出：30.7 万字和 10 个字都在 300–440ms，开销在 SwiftUI 弹 sheet 本身，和字数无关。
    - 30.7 万字多行块滚到底：单次最长忙段 20–162ms；3 次里有 1 次 1265ms 的离群值，没复现。
  - 关页取消：312 万字（10 份夹具）打开后立刻关页，后台解析报「已取消」，没有跑完。
  - **没解决的：单行超长**。21.4 万字的单行 JSON 在 sheet 里上屏 1.4–2.7s（mac）。TextKit 2 一个段落是一个排版片段，整段要排完才知道高度。换 TextKit 1（noncontiguous）实测更慢，上屏 4.3s。不改原文就没法拆这个段落。真实记录里单行最长的是 submit_proposal 的参数，量级是几千到几万字；iPhone 上会更慢，请车头复测时留意。要根治只能在显示时按宽度插软换行，但那会改变显示，复制仍是原文，需要粟粟拍板。

### 9.2 P1 记忆日志 anchor 落点不准（截图 17、30、31）
- **根因**：
  - 旧的跟随在目标行第一次对准时就停（`a75448d1a` `FileLibraryPanelView.swift:2468-2472`）。之后上面的节才排出来、或高亮回来变高，内容就被推走。
  - 一节一行、行高差几十倍，LazyVStack 估高很不准（截图 30、31）。
- **最终修法**：不再估高，也没有跟随计时。两端的行高都按当前宽度算准：卡固定高，标题和叙述按字体量出来。锚点直接滚到那一轮的标题行（iOS `scrollToItem(.top)`，mac `rect(ofRow:)`）。宽度变了就整表重量一遍行高。
- **验证**：`testSeedRecordOpensFastAndEachRoundLandsAtTheTop`。首屏和第 1、2 轮的标题行顶边都是 0.0pt（允许 ±2）；后面不满一屏的停在最底，标题在屏内；第一次落位就是那一轮，2s 内不漂（±0.5pt）。`FileEditorTextModeTests` 里 OCR 版的锚点 / 首尾可达测试照样过。

### 9.3 P1 用量页没有「wiki 种子」（截图 34）
- **查账**：账本是记上了的。种子的后端是 `AssistantCloudBackend(usage: UsageContext(kind: .catalogSeed))`（`CatalogRunner.swift` `makeJob` 的 `backend(.catalogSeed)`）。用量页之前只有按模型 / 按卡两张榜，`UsageSummarizer` 没按 kind 分组，所以页面上看不到。
- **修法**：`UsageSummary.kinds` 按 `UsageKind.label` 分组，排序规则和另两张榜一样（`UsageSummary.swift:185`）。用量页加「按用途」榜，Code 范围不显示（`UsageSettingsPage.swift:80`），设置搜索补了「按用途 / wiki 种子」。
- **C3 页「花费 · 这个月」**：种子按 plan 不占写入预算，所以本期那一行还是只算 `.catalog`，和写入预算口径一致。底下另加一行「wiki 种子 · 这个月，另算，不占写入预算 $x.xx」（`MemoryWriterPages.swift:111` 读账本时并上 `.catalogSeed`，`:494`、`:524`）。写入预算页「花在哪」不动。

### 9.4 P2 小问题
- **每驳回一项多一行「写好了」**：
  - 根因：`resumeSeedCancellable` 只要没有要写的页，就记一行「种子：目录批 / 驳回了，没有要写的页，看完成没有」，`ok` 用默认值 true（`a75448d1a` `CatalogRunner.swift:572`），显示成「写好了」。
  - 修法：目录还有待批、这一下也没批出要写的页时直接返回（skipped「目录还有 N 项待批」），不续整理记录、不记日志（`CatalogRunner.swift:568-574`）。批完最后一项时只记 settle 那一行。全部驳回的「目录全部驳回…不记完成」改成 `ok: false`，因为什么都没写。
- **正文批了，目录详情还显示「交了 1 条正文等批」**：
  - 根因：方向的 `result` 只在交正文时写一次，之后批正文不会回写（`WikiProposalViews.swift:419`）。
  - 修法：目录详情加载时顺带读方向指向的正文提案。正文没有待批了，就显示「已批 · 正文批了 N 条（、驳回 M 条）」（`WikiProposalDisplay.contentStatus`，`WikiProposalViews.swift:421`；§9.8 补了失效 / 读不到）。只是显示时推算，不跨提案回写，也就不用在批正文时再去抢目录那份提案的锁。普通方向的正文同样适用。
- **「上次：」被「没有要执行的方向」盖掉**：
  - 根因：批任何非种子目录的提案时，`waiting` 用的是 `$0.change.direction?.ranAt == nil`（`a75448d1a` `WikiProposalViews.swift:684`）。正文条目没有 direction，`nil == nil` 成立，于是批正文也会空跑一次 `runDirections`，`directions` 认领不到返回「没有要执行的方向」，再被 `start` 写进 `lastReport`（`CatalogRunner.swift:1111`）。普通整理的正文提案也有这个毛病。
  - 修法：`WikiProposalDisplay.unranDirections` 只认真的方向条目（`WikiProposalDisplay.swift:61`、`WikiProposalViews.swift:687`）。
- **种子虚拟文件顶上「文件已在外部删除或移动」**：
  - 根因：`seedEditorSheet` 传了 `currentModifiedAt: { nil }`，而 `checkExternalChangeForOpenFile` 把 baseline nil + current nil 判成已删（`FileLibraryPanelView.swift:3103-3124`）。
  - 修法：虚拟文件给一个不变的时间戳 `.distantPast`（`FileLibraryPanelView.swift:295-296`）。别处改过，靠保存时的 baseline 比对拦（`CatalogSeedDrafts.save`，原样）。没有加自动化测试，靠走查复验。

### 9.5 不修，记下
- 设置 › 记忆「C 档案 · 0 条」：数的是 SwiftData 里活着的碎片（`MemoryWriterPages.swift:612`、`:674` `SwiftDataMemoryStore().listActive`），wiki 页不在里面。改口径要另定是加一行「wiki N 页」还是改文案。
- 文件库树视图顶部「还没有文件」但下面有文件：标题行只数她自己的 `files`（`FileLibraryPanelView.swift:1057`），记忆 / Prompt 这些虚拟文件夹不算。截图对应的是不是这一处，未在真机核对。

### 9.6 新增 / 改的测试
- `FileEditorLargeRecordTests` 整套重写（只单跑，不进整跑清单）：
  - `testCRLFAndMixedLineEndingsKeepSectionsBlocksAndEveryByte`：LF / CRLF / CR / 混合四种，分节数、块数、卡名正确；分行、分节、拆围栏拼回都按 UTF-8 逐字节等于原文；每块原文逐字节一致；目标行是那一轮的标题。另有 5000 行密集 CRLF。
  - `testFencesUseCommonMarkColumnsAndInfoStringRules`：tab、空格混 tab 的 ``` 不闭栏，一个空格的闭栏；`` ``` a`b `` 不开栏，后面真实 anchor 照样分节；`~~~ a`b` 照样开栏，栏里的 anchor 不分节。
  - `testCancellingTheLoadStopsParsing`、`testClosingThePreviewCancelsBackgroundParsing`：取消 / 关页后解析不跑完。
  - `testSeedRecordOpensFastAndEachRoundLandsAtTheTop`：31.3 万字夹具，首屏和各轮落点、响应。
  - `testLargestBlocksOpenInSheetScrollToEndAndCopyTheOriginal`：每个代码块都折成卡；30.7 万字多行块和 21.4 万字单行 JSON 走真实 `.sheet` 打开后，文本视图逐字节等于原文、TextKit 2、只读可选中、能滚到底、复制等于原文。
  - `testBlockSheetBodyCostDoesNotGrowWithSize`：sheet 那一页 30 万字和 10 个字的开销同一量级。
  - 保留 `testSectionedPreviewDoesNotSplitFencedAnchorsOrLoseText`。
  - 删掉三条旧测试（见 §9.1）。
- `FileEditorTextModeTests.testReadOnlyRunPreviewScrollsToStructuredAnchorAndRetainsBothEnds`：init 里不再做分节，`initialPreviewLocation` 断言改成 nil，另断言后台解析出 4 节。OCR 的落点和首尾可达断言没动。
- 「复制」按钮本身没法在离屏测试里按：offscreen 窗口没有无障碍树，SwiftUI 按钮也不是 NSButton。测试调用的是按钮背后同一个 `RunRecordBlockSheet.copy(_:)`，再用 `RunRecordClipboard.override` 接住结果，不碰系统剪贴板。
- 之前那几条测试照旧：`CatalogSeedTaskTests.testOutlineDecisionsLogOneSettlingRowWithAccurateFlag`、`UsageLedgerTests.testPurposeBoardSeparatesWikiSeed` / `testPurposeBoardShowsEveryKindEvenPastEight`、`WikiProposalDisplayTests.testOnlyApprovedUnranDirectionsRunAndContentDecisionShowsOnOutline`。

### 9.7 验证
- mac `** TEST BUILD SUCCEEDED **`（`claude-p6n-mac11.log` 起），iOS `** TEST BUILD SUCCEEDED **`（`claude-p6n-ios-final.log`）。
- 40 套 564 测 0 failures，`** TEST EXECUTE SUCCEEDED **`（`claude-p6n-full-final.log`），金样原样，没有 RECORD。
- `FileEditorLargeRecordTests` 单跑 8 测（新增 7 条 + 保留 1 条；原先写「9 测」是数错了）：3 次里 2 次全过（`claude-p6n-final2-large-2/3.log`），1 次是 30.7 万字滚到底的 1265ms 离群值超了单跑参考门槛（`-1.log`）。§9.10 又补了 4 条，现在是 12 条。
- iOS 只编译、没跑（不碰模拟器 / 设备）：UICollectionView 列表、sheet 里的 UITextView、锚点落位都要车头在 iPhone 14 上看。

### 9.8 astra 审 `3294acd33` 后的返工（车头裁定；粟粟在考虑整个换原生只读文本视图，1/2/4/6 暂停）
- **P1-3 用量榜截 8 行，种子可能看不见**：「按用途」榜显示全部用途。截断改成 `UsageFormat.visibleRows(_:limit:)`，用途榜传 nil，模型榜 / 卡片榜仍截 8 行（`UsageSettingsPage.swift` `visibleRows`、`board(_:rows:limit:)`）。测试 `UsageLedgerTests.testPurposeBoardShowsEveryKindEvenPastEight`：10 种用途、种子花得最少排第 10，用途榜全显示、各行加起来等于总花费；同一组数据截 8 行时确实把种子截掉了。
- **P2-5 正文汇总漏「失效」、读不到退回「等批」**：`WikiProposalDisplay.contentStatus(_:)` 改成这样：
  - 读不到（已删、解码失败）：显示「正文提案读不到了（已删除或文件坏了）」。
  - 还有待批：返回 nil，照旧显示方向的 result。
  - 都处理完：显示批了 / 驳回 / 失效各几条，0 条的不写；全部失效时显示「正文失效 N 条」，不再出现「批了 0 条」。
  - 详情页状态只存 id → 一句话（`contentStatus: [String: String]`），不再持有正文提案全文（`WikiProposalViews.swift` 加载处 / `statusLabel`）。
  - `WikiProposalDisplayTests` 补了失效、全失效、读不到三种情况。
- **P1-1 CRLF、P1-2 围栏缩进、P2-4 取消、P2-6 测试**：暂停后按粟粟拍板的原生方案重新定义，全部做完，见 §9.1、§9.2、§9.6。`RunRecordScanner.swift` 已接上分节器和拆围栏器。
- **P2-7 墙钟性能门槛的 CI 抖动：不修。** `FileEditorLargeRecordTests` 继续不进整跑清单，只单跑。它的首屏 300ms / 忙段 200ms 门槛只作 mac 单跑参考，真机表现以车头在 iPhone 14 上复测的数据为准。
- **验证**：
  - mac `** TEST BUILD SUCCEEDED **`（`claude-p6w2-mac.log`），iOS `** TEST BUILD SUCCEEDED **`（`claude-p6w2-ios.log`）。
  - 40 套 564 测 0 failures（`claude-p6w2-tests.log`，机器负载 30 左右），金样原样。

### 9.9 改道：从「切段懒排」到「原生列表 + 卡 + sheet」（10-22）
- 粟粟原话：「为啥不 uikit」，以及「只有这里用，这里用，也要折叠（不是为了快，方便 user 预览），折叠全用弹 sheet，跟 page1 的工具调用一样」。
- 切段版（`3294acd33`）在 mac 上数据已经可以，但它是在 SwiftUI LazyVStack 上补丁：靠估高，再加 1.5s 跟随计时把落点拽回来，把大块切成 600 字一段再拼回去。astra 又挑出 CRLF、tab 围栏、取消三处缝。粟粟要的是「预览」：看见每轮有哪些块、点开看全文。块就该是一张卡，不该在页面里摊开。
- 原生列表的行全是短行（标题 / 叙述 / 卡），行高能直接算准，锚点不用估也不用追；大文本只在 sheet 里出现，交给系统 TextKit 2 文本视图。
- 代价：
  - 叙述不再渲染 Markdown（标题单列，其余原样显示）。
  - 单行超长块在 sheet 里慢（§9.1 末尾）。
  - mac 上 SwiftUI 弹 sheet 本身有 300ms 左右的固定开销，和字数无关。

### 9.10 astra 审 `97d41cbab` 后的返工（车头裁定）
- **P1 末尾字节**：
  - 根因：`codeText` 用 `Character.dropLast()` 删末尾。原文 "A\r" 被 `CatalogRunRecord.code` 包装后，末尾变成 CR LF，而 CR LF 在 Swift 里是一个字符簇，两个字节被一起删掉；没闭栏的围栏也被删了真实的末尾 LF（`97d41cbab` `RunRecordDocument.swift:79`、`:133`）。
  - 修法：按字节只剥写入器在闭栏前追加的那一个 LF，没闭栏的一个字节都不剥（`RunRecordDocument.swift:146`，调用处 `:89` 传 `close != nil`）。CRLF 整份文档里，块末的 CR 现在算原文；这和写入器的约定一致，夹具也改成照写入器只加 LF。
- **P1 iOS 宽度变化**：
  - flow layout 覆写 `invalidationContext(forBoundsChange:)`，宽度变了就设 `invalidateFlowLayoutDelegateMetrics = true`，同时清掉自己的高度缓存（`RunRecordListView.swift:279-289`）。
  - 记下变化前最上面那一行和它的露出量，排完停回去（`keepTopRowThroughRelayout` `:298`）。
  - mac 同理：`tile` 发现宽度变了就整表重量行高，再停回原来最上面那行（`:453`、`:465`）。
  - mac 上传统滚动条出现或消失会改内容宽度，所以列表改用浮层滚动条（`:423`）。
  - mac 的记录页是定宽 720 的 sheet，测试直接给列表本身改宽。iOS 转屏要车头在真机上复测。
- **P2 取消**：
  - 分行器每扫 64KB 查一次（`RunRecordScanner.swift:17-31`），超长单行也会停。
  - 分节（`FileEditorPreviewLocation` 的 rethrows 版 `FileLibraryPanelView.swift:1907`）、`segments`（`:112`）、叙述（`:180`）都逐行查；摘要只扫到第一行非空就停，同样按字节查（`:152`）。
  - `parse` 返回前、`load` 返回前（`:54`），以及视图发布结果前（`FileLibraryPanelView.swift:2471`）各再查一次，被取消的结果不会发布。
- **P2 字号**：
  - 新增 `RunRecordTypography`（`RunRecordListView.swift:13`），接旧预览那套 `fontScale`：正文 13.5×、标题 20 / 17 / 15×、代码 0.88×正文；卡的字号和卡高跟着放大。iOS 再乘系统动态字体（`UIFontMetrics`），视图读 `dynamicTypeSize`，它一变就重算（`FileLibraryPanelView.swift:2456-2459`）。
  - 测量缓存的键改成「宽度 + 字号」，字号变了就重量行高，并停回原来最上面那行。没有新增设置项。
  - 默认 `fontScale` 1.2 下叙述是 16.2pt（旧预览也是这个值），比上一版的固定 13pt 大，各轮落点的绝对 pt 值跟着变了（第 3 轮 122 → 68pt），仍然是后面不满一屏、停在底的情况。
- **P2 测试**：
  - 新增 `testTrailingBytesSurviveParseSheetAndCopy`：原文 "A\r"、没闭栏的 "B\n"，在解析、sheet（走真实 `.sheet`）、复制三处都逐字节等于原文。
  - 新增 `testCancellingMidScanStopsAtTheNextCheckpointWithoutAResult`：在第 5 个检查点取消，就在这个检查点当场停下（计数正好 5），`load` 抛取消、不交结果。另测 1MB 无换行的单行，检查点次数不少于字节数 / 64KB。
  - 新增 `testUserScrollIsNotPulledBackToTheAnchor`：落位后往回滚 300pt，1s 后还停在 300pt。
  - 新增 `testWidthAndFontChangesRemeasureRowsAndKeepTheTopRow`：列表从 720 改窄到 420、字号从 1.2 改到 1.8，每行高度都等于按新宽度和新字号单独量出来的值，第 2 轮标题仍在顶上。
  - 测试里没有 `c0-1` / `f0` 这类字面 id 断言了：上一轮的切段测试已整条删除，现在的断言都查行类型、卡名和字节内容。
  - `landing` 改用表格的行位置判断落点：单元格视图刚复用时自己的 frame 可能还没排到位，之前「先 12pt 后 0pt」就是这个测量误差，滚动本身是准的。
  - 滚到底的忙段多数在 3–60ms，偶尔有离群值（162 / 379 / 1265ms，TextKit 2 估高被纠正），所以只记数、不设门槛。
- **单行超长块试 `.byCharWrapping`（字级折行），没变快，已撤回**。21.4 万字单行 JSON，sheet 那一页直接上屏，单次最长忙段：
  - 撤前（3 次，负载 5–6）：1092 / 1096 / 1281ms。
  - 字级折行（6 次，负载 8–20）：1334 / 1270 / 1166 / 2224 / 2904 / 1429ms。
  - 负载有出入，但同时段测的多行块没变（52–66ms），说明慢的是单个超长段落的排版本身，换折行方式没用。sheet 文本视图恢复原设置。
- **验证**：
  - mac `** TEST BUILD SUCCEEDED **`（`claude-p6x-mac10.log`），iOS `** TEST BUILD SUCCEEDED **`（`claude-p6x-ios.log`）。
  - 40 套 564 测 0 failures（`claude-p6x-full.log`），金样原样。
  - `FileEditorLargeRecordTests` 单跑 12 测，连续 2 次全过（`claude-p6x-final-large-1/2.log`）。

### 9.11 短单行原地显示（😷 iPhone 14 复测后，粟粟默认同意）
- **起因**：复测时，很短的值也被折成了卡，比如约 30 字的 id、4 个字的工具名「read」，看的时候反而要多点一下。折叠本来是为了方便预览。
- **规则**：代码块里没有换行（LF / CR 都算换行，`RunRecordTypography.isSingleLine` `RunRecordListView.swift:45`），并且按当前宽度和代码字号实际量出来一行排得下，就原地显示：等宽、可选中，点它不弹 sheet。多行的、或一行排不下的，照旧折卡、点开弹 sheet。没写字数阈值。
  - 原文以 \r 结尾的块（例如 "x\r"）按「有换行」处理，折成卡，sheet 里能看到那个 CR。
- **实现**：
  - 「原地 / 折卡」和行高用同一个缓存键（宽度 + 字号），每次一起重算。
  - **mac**：用原地显示那个标签实测一行宽度（`fitsInline` `:591`、`isInline` `:536`）。宽度变了先重量行高，再整表重载，因为 cell 可能要换样子。
  - **iOS**：用代码字体量一行宽度（`fitsInline` `:245`）。原地显示的 cell 是不滚动、一行、只读可选中的 UITextView（`RunRecordCodeLineCell` `:397`）。宽度变了先清缓存，排完那一轮再整表换 cell（`needsCellReload` `:216`）。
  - 只有卡能点开（iOS `shouldSelectItemAt`，mac `open(row:)`）。
- **测试**：
  - 新增 `testShortSingleLineValuesShowInlineAndTheRestFoldIntoCards`：
    - id、read、60 字符的值原地显示，那一行显示的就是值本身；
    - 长单行、多行、"x\r" 仍是卡；
    - 只有卡能点开；
    - 每行高度等于单独量出来的值；
    - 改窄到 420 后，60 字符那块变成卡，id 仍原地显示；改回 720 后，60 字符那块又原地显示。
  - `testLargestBlocksOpenInSheetScrollToEndAndCopyTheOriginal` 里那块小的改成两行（"call_small\n2"），不然它会原地显示、没法当 sheet 冷开的基线。
  - `FileEditorLargeRecordTests` 现为 13 条。
- **验证**：
  - mac `** TEST BUILD SUCCEEDED **`（`claude-p6y-mac2.log`），iOS `** TEST BUILD SUCCEEDED **`（`claude-p6y-ios.log`）。
  - `FileEditorLargeRecordTests` 单跑 13 测，连续 2 次全过（`claude-p6y-t1-1.log`、`claude-p6y-t2-1.log`）。
  - 40 套 564 测 0 failures（`claude-p6y-full.log`），金样原样。
  - iOS 原地显示的 UITextView 一行高度用的是 `lineHeight + 2` 的余量，有没有被截要真机看。

