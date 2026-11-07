# C2/C3 v2 · P4 复盘：第 4 段「P3 共用审批」

范围：`plan-memory-c2c3-v2.md` 第 4 段实现第 1–7 条、写模块结果表、提交 4。基线 HEAD `b95e72e36`，开工工作区干净。按实现单不做 git 写操作、不开模拟器、不碰设备、不跑真端点、不碰真人数据。第 6 段种子、第 7 段 A4、第 8 段四来源发现都没做。行号以本次工作区为准。

## 0. 逐条交回

1. **方向项**：`WikiProposal.Change` 加 `.direction(Direction)`（路径 / 标题 / 钩子 / 类 / 别名、动作 update|newPage、理由、线索、执行模式 daily|agent，另带执行状态 ranAt / result / contentProposalId），不含正文；复用 Item 的 pending / approved / rejected 和整批 / 逐条 / 改，不建审批库 `WikiProposal.swift:44-81,88-107`。正文提案用 `directionRef` 关联原方向，手动提案用 `request` 记请求和楼层 `:150-151`。批方向只记「已批」，不碰页和碎片 `:259-263,323-326,477-478`。方向的线索不进 `fragmentIds`，所以驳回方向不会给线索打「整理时驳回」。
2. **自动方向全由代码做**：`CatalogSession.discover` 只读碎片值快照（不读正文）、wiki 每页标题 / 触发词 / 钩子、「不触发的词」和以前提过的方向 `CatalogRunner.swift:201-243`；归组在 `CatalogSorter.group` `CatalogSorter.swift:427-497`：标题 = 主体 + 关键词（`titleWords`/`title` `:436-446`，名字和不触发的词不算，空 = 「未命名碎片 + 短编号」）；标题词里逐字出现某页标题 / 触发词 → 更新（复用 `WikiInjection.match`，碰上多页 = 拿不准留着）；没碰上的按第一个标题词归，够 3 条开新页，路径 `楼层/主题/<词>`，可改。去重 `priorDirections` `:500-517`：同页有待批方向不提；处理过的页线索没增加不提。旧「自动模型分拣」整段替掉（见 §3「删掉的」）。daily 改为 `discover` + 原分组调整 → 一份「定时整理」提案 `CatalogRunner.swift:247-273`。完整 A4 来源**没接**，留第 7、8 段。
3. **手动 = 方向授权**：`organizeTopic` / `organizeNow` 直接进 agent，正文提案带 `request`（「整理一个主题：X」/「现在整理」+ profileId），不出待批方向 `CatalogRunner.swift:599-656`。「现在整理」的主题清单改用同一个代码归组（不再调分拣模型），不设主题上限，可停。正文照样进审计台等批。
4. **{助手}主动建议**：新增 `WikiSuggestTool`（`suggest_wiki_direction`，path / title / reason），只交一条 origin=assistant、mode=agent 的待批方向，同页有待批不重复交 `WikiSuggestTool.swift`；沿 ToolDefinition / ToolRegistry `ToolRegistry.swift:50-51` / 聊天分发 `ConversationViewModel.swift:4696-4705`（关了记忆参与就拒）/ 工具抽屉 `ToolDrawerCatalog.swift:77`。不扩 A 线 / C2 编辑 / B5，不改 fs 的 memory 只读。**抽屉里默认关**（见 §4 偏离 1）`ToolRegistry.swift:156-167`、`ToolDrawerPage.swift:213`。
5. **批后才搜写**：`directions(proposalId)` 先在审批锁里认领已批未执行的方向（记 ranAt）`WikiProposal.swift:397-416`，再取快照、三路搜、读完整楼层 prompt（现有 floorPrompt）/ 相关索引 / 已有页全文和版本；daily 模式一次写手、agent 模式最多 N 轮 `CatalogRunner.swift:277-368`。写完交正文提案；第二批批了才写页、存历史、重建索引、碎片标已整理（沿原 `WikiProposalReview.approve`）。审计台批方向后自动 `CatalogRunner.runDirections` `CatalogRunner.swift:751-755`、`WikiProposalViews.swift`（approve）。
6. **covered / 单条**：旧「covered 没条目可挂就直接标已整理」旁路删掉，改为 `.confirmCovered(path)` 内容项（不改页，版本对得上才在批准时打标，页变了 stale）`WikiProposal.swift:89-90,480-481`、`CatalogWriter.swift:403-415`、`CatalogAgent.swift:685-688`。单条就够沿 organizedAt + 空 page：写手 / agent 交 `single`（只认分到这个主题的线索）直接打标 `CatalogWriter.swift:394-401`、`CatalogRunner.swift:371-401`、`CatalogSorter.swift:148-159`；它们仍在检索快照里（可召回），也在发现候选里，但只跟着新证据回来（`isCandidate` `CatalogSorter.swift:89-92`）。
7. **复用**：同一楼层锁（`CatalogRunner.start`）、取消（CatalogCancel）、预算（caller preflight / agent gate）、`.runs`、提案已处理状态都沿原样。认领 + 记结果都走 `WikiProposalReview` 那把锁，重复批 / 重复点 / 并发执行只付一次；待批占用只排同一批线索（`pendingFragmentIds` 加方向线索 `CatalogSorter.swift:80-83`）。失败 / 停止只记结果，不重试、不续跑、不建恢复队列。

### 写模块结果表

| 结果 | 实现 | 证据 |
|---|---|---|
| 有正文变更 | 一份正文提案（关联方向 / 带请求），批了才落页、打标 | `CatalogRunner.swift:371-401`；`CatalogDirectionTests.testAutoDirection…SecondApproval` |
| 只有 covered | 「确认已覆盖」一条，不改页，批了才标，待批占用不重复发现 | `CatalogWriter.swift:403-415`；`testCoveredOnlyDoesNotTouchPage…` |
| 单条就够 | 不造正文提案，直接打单条标，留池可召回，新证据重新归组 | `testSingleStaysRecallableAndJoinsPageWithNewEvidence` |
| 确实无材料 | 不造提案、不打标，方向上记「没有可写的材料：原因」，释放占用；没新证据不重提 | `testNoMaterialReleasesOccupancyWithoutMarks` |
| 失败 / 停止 | 已交的可审；没产出不打标；方向记「被拦 / 停了 / 出错 / 到顶没交」，不自动续跑 | `testCancelDuringWrite…`、`testCancelBeforeExecution…`、`testAgentFailureAndGiveUp…`、`CatalogWriterTests.testDailyMaxTopicsAndBlockedExecutionMarksNothing` |

## 1. 边界情况

- **批了但没执行**：方向「已批」与执行是两步。批完 app 被杀 / C3 关着（`runDirections` 直接不跑）/ 楼层不是当前楼层，方向停在「已批 · 还没开始写」，没有重试入口（按 plan 不建恢复队列）。线索不再被这条方向占用，之后有新碎片会再提新方向；没新碎片则因为「处理过的页线索没增加」不再提。
- **认领即消费**：执行前先记 ranAt。认领后被拦 / 停 / 出错，这条方向就结束了（结果写在方向上），不会再执行；停在认领之后、执行之前也记「停了，没执行」。一次批了多条、中途被预算拦下，后面几条也会各记一次「被拦」（不花钱），不会留到以后。执行中 app 被杀，方向停在「已批 · 正在查原料、写」，不会再跑。
- **线索变化**：执行时只给还在池里的线索（没进页、没驳回）；方向批准前碎片被别处整理进页，就少给一条，不报错。
- **路径被她改了**：「改」只接受合法页路径；动作（更新 / 开新页）显示的是提方向时的判断，执行时按页是否存在重新算。
- **代码归组的粗糙处**：只认主体 / 关键词的第一个词，同义不同字（「云桥城」/「云桥」作主体）在没有页时分成两组；单字触发词会把很多标题拉到同一页（和注入同口径，靠「不触发的词」管）。主体正好是名字时用关键词。
- **去重靠 30 天内的提案**：「处理过的页没有新碎片不再提」读的是现存提案，处理完满 30 天的提案被清掉后，同一批线索可能被再提一次（需要她再批，不会自动付费）。
- **分组调整仍调模型**：daily 里「层超过 30 行提分组调整」是旧功能，仍发一次模型请求；它不属于方向发现，本段没动（见 §4 拿不准 2）。
- **助手建议没有线索**：小克的方向 clues 为空，agent 只能靠主题词自己搜；标题词与页标题都没有时只按路径最后一段当标题。

## 2. 与第 6、7 段交互的风险

- **第 6 段种子目录**：plan 说「种子目录复用这批法」。方向项现在只有路径 / 标题 / 钩子 / 类 / 别名 / 理由 / 线索（碎片 UUID）/ 模式，没有「原料清单」字段，也没有 phase / checkpoint；第 6 段要么扩 Direction（加原料清单、目录项 id），要么另起，扩的时候注意 `claimDirections` 现在只认 daily / agent 两种模式，种子不能被 `directions()` 当日常方向执行。旧 `CatalogSession.seed` 仍是旧路径，本段只让它跟着用新的 `attachCovered(version:)`（seed 的伪碎片本来就不进 covered / single）。
- **第 6 段清旧种子**：origin=seed 的旧提案里没有方向项；新增的 `directionRef` / `request` 都是可选键，清理时按 origin 判断不受影响。
- **第 7 段 A4**：`discover` 现在只吃碎片标题 + 索引；第 8 段接 A4 主调时，A4-only 方向没有碎片线索，需要另一套「新证据」判定（现在的去重是「线索 UUID 集合有没有增加」，对没有线索的方向等于永远不再提）。`CatalogSorter.priorDirections` 是唯一去重入口，扩的时候改它。
- **第 7 段巡检顺序**：daily 现在不调模型就能出方向，A4 先于 C3 的顺序约束对本段没有影响；但第 8 段要在 A4 成功持久化之后再 `discover`。
- **执行模式**：自动方向固定 daily（一次写手），助手方向固定 agent。第 8 段若出 A4-only 新主题，建议用 agent（没有可分配的碎片）。

## 3. 技术债

- **删掉的**：模型分拣整套（`CatalogSorter.run/parse/systemPrompt/userContent/brickTable`、`CatalogSortState` 与 `.sort-state.json` 轮转 / 暂存主题、`CatalogMaterial.sortLimit`、`isRaw`）和 covered 直接打标旁路（`CatalogSession.markCovered`、`markSingle(page:)`）。旧 `.sort-state.json` 留在磁盘上不读也不删。
- **`suggest_wiki_direction` 默认关**：见 §4 偏离 1。打开要在工具抽屉里手动拨；`ToolRegistry.defaultOffNames` 是为它新加的机制，抽屉开关打开时落 `onMode`。
- **结果是一句话**：方向执行结果存为人话字符串（`Direction.result`），UI 直接显示；没有结构化状态码，后段要按结果分流时得补。
- **`runDirections` 只在审计台批准后触发**：其他批准入口（以后若有）要自己调；没有「重新执行」按钮。
- **代码归组只看第一个标题词**：多关键词碎片只归一处；以后要更细的归组（多词投票等）在 `CatalogSorter.group` 一处改。
- **`CatalogFloorPrompt` 仍是五段 + 3000 截断**：plan 第 5 段写好的完整底图（`CatalogRunner.floorBase`）本段没接进写手，留第 9 段（plan 原定）。
- **说明书 `npm run check`** 没跑：工位没装 `scripts/manual` 的 node_modules（同 P5）。

## 4. 偏离 / 没做到 / 拿不准

1. **（已按粟粟 10-22 改为默认开，见 §7 A）偏离：小克的工具在抽屉里默认关。** 加进注册表的工具会进每轮系统提示的〔当前能用的工具〕清单；实测把它默认打开，`PromptRealPathGoldenTests` 8 个金样全部失败，差异只有一行 `- suggest_wiki_direction — 给记忆 wiki 提一个整理方向：动哪一页（已有页或新开一页）、为什么`（日志 `claude-p4-probe-on-golden.log`），随后改回默认关并重编重跑全过。按实现单「金样变了就停下报告、不准 RECORD」，没有重录。要默认开：删 `ToolRegistry.defaultOffNames` 里这一项，重录 8 个金样（只多这一行），同时删 `ToolDrawerTests.testWikiSuggestIsOffUntilDrawerTurnsItOn` 的默认关断言。
2. **拿不准：daily 里的分组调整仍是模型请求。** 实现单写「自动方向待批时没有任何模型请求（分拣 / 搜索 / 写手都没有）」；分组调整是旧功能，只在某层超过 30 行时发，既不是分拣、搜索也不是写手，本段没动。测试里的「零模型」场景都不触发它。如果要求 daily 绝对零请求，需要把分组调整也挪成「代码先提、批了再调模型」，属于新改动，等车头定。
3. **拿不准：「现在整理」改用代码归组。** plan 写「主题清单可沿轻量代码归组，模型追搜与判断在写模块内完成」；这里取了「代码归组」，于是模型分拣整体删除，`single` 判断挪进写手 / agent。代价：没有主体也没有关键词的旧碎片，「现在整理」不再能被模型归到主题里（自动也一样），只能靠点名主题。
4. **没做：** 完整 A4 来源方向（第 7、8 段）；种子目录（第 6 段）；方向「重新执行」入口（plan 明确不加恢复队列）。
5. **测试只跑了 mac 单测**；真端点（live 五条）、模拟器 UI 都交车头。iOS 只 build-for-testing。

## 5. 测试

- **新增** `MemoryPalaceTests/CatalogDirectionTests.swift`（15 条）：自动零模型 + 两次批；逐条批 + 驳回方向不伤线索 + 新证据才重提；待批方向不重复提；重复批 + 并发执行只付一次；手动一次进 agent、正文没批不落页；助手建议先批方向（含路径 / 理由校验、去重）；covered-only 不改页、批后打标；stale；单条就够可召回且新证据归页；没材料释放占用不打标；写手中途停；执行前停；agent 出错 / 到顶没交；代码归组只看标题；旧格式正文提案照常批。`ToolDrawerTests.testWikiSuggestIsOffUntilDrawerTurnsItOn`（1 条）。iOS `CatalogLiveSmokeTests.testAnthropicAssistantDirectionProducesProposal`（1 条，门控）。
- **改写**（按两批流程，行为断言不放松）：`CatalogWriterTests.testDailyDirectionsThenWriteFailureIsolatedWithRegroup`、`testDailyMaxTopicsAndBlockedExecutionMarksNothing`、`testWriterRunPreservesMaterialsRepliesValidationAndFeedback`、`testCoveredHangsOnFirstItemOfThatPage`；`CatalogAgentTests.testOrganizeNowListsTopicsByCodeThenOneProposalPerTopic`、`testOrganizeTopicMakesOneTopicProposal`；`CatalogRetrievalTests.runMode`（daily 走方向→批→执行）、`testOrganizeNowContinuesAfterLiveMixedNewAndPageAssignments`、`testSavedAttributionReachesActualAutomaticWriterWithOriginalLabels`；`CatalogOriginalRetrievalTests.sessionOriginal`；`CatalogSorterTests.testRawMaterialFilter`（单条就够进候选）、`testCancelStopsJSONRetryAndNextRequest`；`ToolDrawerTests.testDefaultDrawerKeepsPreDrawerPartition`（默认关除外）；`ToolRegistryTests` 计数 +1；`Fixtures/tools-schema-golden.json` 手工补 `suggest_wiki_direction` 两家 schema（REGEN 入口要额外环境变量，守则脚本不支持，手工插入后由 `testSchemaMatchesGoldenFixture` 比对通过）。iOS `CatalogLiveSmokeTests.run` 四条原有 live 改成两批（daily：方向零请求 → 批 → 执行 → 第二次批才落页；手动：说一次进 agent、正文带请求、批了才落页）。
- **删除**（模型分拣已删）：`CatalogSorterTests` 12 条（分拣解析 / 重试 / 运行记录 / 轮转 / 暂存 / 分拣时停），`CatalogJSONRepairTests.testStringifiedSorterArrayAndObject`。
- 金样：`PromptRealPathGoldenTests` / `InspectorRealPathTests` 原样通过，未 RECORD。

## 6. 验证

- 基线（改动前，HEAD `b95e72e36`，`claude-p4-base-mac.log` / `claude-p4-base-tests.log`）：mac `** TEST BUILD SUCCEEDED **`；23 套 328 测 0 failures。
- 期间分支 HEAD 被车头推进到 `dd0dd12e0`（第 5 段 sim 走查修复，含 `FileLibraryPromptFolder.swift`、`FileLibraryPanelView.swift`、`PromptFolderTests.swift`，不是本段）。最终验证在 `dd0dd12e0` + 本段改动上重跑：mac `** TEST BUILD SUCCEEDED **`（`claude-p4-final-mac.log`）；24 套 331 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`claude-p4-final-tests.log`）；iOS 应用与 iOS 测试包 build-for-testing 见交回报告（`claude-p4-final-ios.log`、`claude-p4-final-ios-tests.log`）。
- 守则指定的 `scratchpad/build.sh`、`runtests.sh` 在中途被删（不是本段删的）；最后一轮用逐字照抄的副本 `scratchpad/p4/build.sh`、`p4/runtests.sh` 跑，命令与锁行为一致。
- `manual/facts/modules/memory-settings.md` 的工作区改动里另有第 5 段走查修复的两行（Prompt 文件夹「未命名 / 已关闭」标签、自动填充空槽说明），是那次提交说好随第 4 段一起交的，不是本段写的。

## 7. 返工（astra 审查，车头裁定；基于 `e45d7a863`）

粟粟 10-22 定：自动整理先不碰、只修写入；小克的工具默认开。

- **A 默认开**：删掉 `defaultOffNames` / `onMode`，`defaultMode` 和抽屉开关恢复原样 `ToolRegistry.swift:157-159`、`ToolDrawerPage.swift:213`。8 个请求体金样按授权重录，逐个字符比对旧版：每个只多一段插入 `suggest_wiki_direction — 给记忆 wiki 提一个整理方向：动哪一页（已有页或新开一页）、为什么\n- `（〔当前能用的工具〕按名字排序插在中间），其余一字不差（`p4/golden_diff.py`）。`InspectorRealPathTests.testHistoryThinkingSegmentsNeverSent` 重录前红，原因是它直接拿 G8 金样文件逐字比对，不是检查器路径变了；G8 重录后通过，没有改检查器测试。
- **B 完整底图**：`CatalogRunner.writerFloorPrompt(profile:)` = `floorBase(profile:)?.text`（只有没接 PresetManager 时退回旧五段）`CatalogRunner.swift:753-756`；`makeJob` 的 `floorPrompt` 改用它 `:910`，方向执行、整理一个主题、现在整理的写手和 agent 都吃它。旧 CC 种子不动：`CatalogJob.seedFloorPrompt` 仍是旧五段截断 `:117,455,915`。
- **C 手动 covered / single**：agent 记下 `read_wiki` 实际读过的页 `CatalogAgent.swift:512,678`；submit 新增可选 `covered_page`（必须是读过的页）`:79`、`CatalogWriter.swift:116,163-176,408`；covered 目标 = 点名的读过页 → 分到的主题页 → 第一条条目的页 → 只读过一页时的那页 `CatalogAgent.swift:692-694`，能生成「确认已覆盖」。single 改按本次实际给过 agent 的碎片（没进页、没驳回）认，不再只认预分配线索，空线索的助手方向同样适用 `:695-696`。自动日常写手的 single 仍按线索（没在本单范围）。
- **D 编辑进锁**：新增 `WikiProposalReview.edit`，重读 / 校验待批 / 保存都在审批锁里 `WikiProposal.swift:416-427`；「改」表单改走它 `WikiProposalViews.swift:840`。
- **E 没跑成 / 上次中断**：`runDirections` 带上点「批」时那几条的 id；C3 关着记「C3 关着，没执行」，楼层或模型没准备好记「楼层或模型没准备好，没执行」，排队时被停（`start(job:)` 现在返回跑没跑）记「排队时点了停，没执行」，都认领掉、保留消费标记 `CatalogRunner.swift:786-822,857-873`、`WikiProposal.swift:428-447`。冷启动 `attach` 时对每个楼层跑 `finishInterrupted`：开始时间早于这次启动、没有结果的方向，按 directionRef 找到已交正文记「交了 N 条正文等批（上次运行中断前已交）」，没有记「上次运行中断，没交正文」；不重发请求、不排队 `WikiProposal.swift:449-478`、`CatalogRunner.swift:706,714-730`。
- **F 钩子**：`Topic.hook` `CatalogSorter.swift:423`；日常写手输入加「【定好的钩子】…」`CatalogWriter.swift:587-589`，agent 开场 hint 加「定好的钩子：…」`CatalogRunner.swift:344`；写完后 `CatalogItems.applyHook` 落到条目上：新开页用它、模型交了改钩子就改成它、已有页钩子不同又没交就补一条改钩子（照样等批）`CatalogWriter.swift:425-447`、`CatalogRunner.swift:358-361,374-379,573`。正文提案里新开页的「钩子」/ 改钩子「旧 → 新」显示的就是最终值。
- **G 确认已覆盖的展示**：详情页加载 covered 的碎片（只进展示用的 `fragments` 字典，不进 `fragmentIds`），每条带 covered 的条目下列「页上已经写过的碎片」；「确认已覆盖」加「对照这一页现在的样子 ›」，页不在写「这一页已经不在了」`WikiProposalViews.swift:225,368,410-427,512-536,684-702`。

### 新增测试（`CatalogDirectionTests` +7，共 22）
`testWriterAndAgentReceiveFullFloorBaseBeyondOldTruncation`（自建槽、3000 字之后的事实进实际写手输入和 agent 开场）、`testManualTopicCoveredOnlyLinksTheReadPage`、`testSingleCountsFragmentsActuallyProvidedToTheAgent`（含空线索助手方向）、`testEditInterleavedWithClaimNeverOverwritesRanAtOrPaysTwice`、`testNotRunBeforeExecutionRecordsReasonAndConsumes`（C3 关着 + 排队时点停）、`testColdStartFinishesInterruptedDirectionsWithoutRerunning`、`testEditedHookReachesWriterAndAgentAndLandsInContent`。`ToolDrawerTests.testWikiSuggestIsOffUntilDrawerTurnsItOn` 换成 `testWikiSuggestIsInlineByDefaultBehindC3Gate`，`testDefaultDrawerKeepsPreDrawerPartition` 恢复原断言。

### 暂缓（粟粟：自动整理先不碰）
- ① 每天自动的分组调整仍在方向批准前调模型，regroup 仍混在方向提案里（整批批会直接挪页）。
- ② 发现阶段的碎片值快照带正文、`WikiInjection.load` 逐页读整页（只用标题 / 触发词 / 钩子），小克工具在待批前也 `wiki.read`；归组算法本身不用正文，但读取没收住。
- ⑨ 归组只看第一个标题词，关键词顺序不同会漏掉够 3 条的共同词。
- ⑩ 去重依赖可改的路径和 30 天内的提案记录；两个对话同时建议同一路径的查重与保存不是原子的。
- ⑪ 中属于自动归组门槛的测试（三条门槛、跨轮从两条攒到三条、重复编号）一起暂缓。

### 返工验证
- mac `** TEST BUILD SUCCEEDED **`（`claude-p4r-mac8.log`）；25 套 357 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`claude-p4r-final-tests.log`，比首交多 `PromptFolderTests` 19 条和本次 7 条）。
- iOS 应用、iOS 测试包 build-for-testing 见交回（`claude-p4r-ios.log`、`claude-p4r-ios-tests.log`）。
- 观察（没修）：`MemoryBM25` 用 NLTokenizer 分词，单独一条「云桥城地图画好了」用「云桥城」搜不中（关键词里写了「云桥城」也不中），测试改用「纸帆船」样例。这是 P0 共享检索内核的分词问题，不在本段。
