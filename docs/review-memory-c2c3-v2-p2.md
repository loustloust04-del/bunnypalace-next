# C2/C3 v2 · P2 复盘与交回

范围：`plan-memory-c2c3-v2.md` 第 3 段实现 1–5、来源表和提交 3。基线 HEAD `e62b23fa4`，开工工作区干净。只改本工位，不做 git 写操作、不调用官方端点、不安装/启动设备、不碰真实数据、不 RECORD。

## 1. 边界情况

- 正文按 Swift `String.count`：121、160、200 字完整接受，201 拒收；200 个复合 emoji 同样接受，不按 UTF-16 长度误拒。不做截句或句法检查器，1–3 句交提示词。
- `msg/content/tags/importance/category` 必填；tags 最多 5，importance 1–5，emotion -2…2，resolved 保持可选。未知 category 拒收，不再回落 fact。valid_until 沿既有宽松字段处理：坏日子只丢该字段，合法日写到该记忆日结束（次日 05:00）。
- 复制检测只比较 content 和其 msg 原文，去 Unicode 空白与标点后完全相同才拒收；不改大小写、不做相似度/语义去重。原文仍按编号取原始 Message，不用另一条消息充出处。
- JSON 或卡片错误均触发唯一一次整包重写，反馈第一处具体错误及坏卡总数。第一轮好卡不提前写；最终采用第二轮整包的合格卡，坏卡丢弃，精确重复正文只加一次。第二轮 JSON 仍非法则整包拒收，不发第三次请求。
- 选定批次保留双方上下文，每消息 600 字、本机 3000 system/6000 总预算及触发水位不变。第二轮具体错误也计入预算，必要时丢最早整条并以第二轮实际可见编号校验，不让 LocalChatProvider 再偷偷裁掉回灌文本。
- 模板在本次调用开始时选定；重写期间设置变化不放松本次合同。旧自定义原文不覆写、不迁移；编辑器「用默认模板」保存时清除自定义键，避免新版全文被当旧自定义而放松归因。

### 来源表（四种来源）

| 来源 | subject / speaker 缺失 | 已实现的处理与证据 |
|---|---|---|
| 旧 SwiftData | nil | 可选持久字段，不重提取、不扩写、不回填。用无两字段的旧实体创建真实磁盘 store，再由当前实体打开同一路径，旧短正文及原字段保持不变。`Memory.swift:31-33`；`MemoryAttributionPersistenceTests.swift:39-135,256-312`。 |
| 旧备份 | nil | 缺键解码为 nil，导入磁盘、重开、再导出、恢复第二个磁盘库仍 nil；不套新提取校验。`FullDocuments.swift:251-253`；`FullDocumentMapping.swift:436-437`；`MemoryAttributionPersistenceTests.swift:193-250`。 |
| 保留的旧自定义模板新输出 | 允许缺失 | 共同字段仍严格校验；任一归因字段一旦提供，不得为空、null、错误类型或非法 speaker。模板原文保持不变。`FragmentPool.swift:259-268,315-403,424-442`；`FragmentPoolTests.swift:165-224`。 |
| 新默认新输出 | 不允许缺失 | subject 非空，speaker 在三个协议值内；缺/坏进入一次重写，第二轮坏卡不存。默认提示词只要求「用户自述 / AI 承诺」，不因协议保留「AI 观察」就放开默认提取普通观察。`FragmentPool.swift:209-252,383-403,424-442`。 |

C3 只展示已有归因，nil 明示未知，不从正文猜。现有审计台归因专用 UI 不在本段新增范围。

## 2. 与下一段交互的风险

- P3 可直接消费 CatalogFragment 的 subject、speaker、原有 keywords。它们在所属 context 转成值快照；原 f 编号不重编，不跨线程传活 Memory。
- 自动分拣/备料、agent 开场、search_fragments 和广搜碎片均带归因。归因是正文区间外的元数据，不消耗 6000 字搜索正文预算、不算正文统计；agent 原累计工具总字数仍计算实际整份回灌，未放松。
- speaker 协议保留 AI 观察，供旧数据/自定义模板及后段写手消费；默认模型是否遵守“普通观察不提取”必须由真实模型验收，结构校验不冒充语义判断。
- 没有改两次审批、Prompt 文件夹、种子、A4、方向发现、写手规则、Faithfulness 或三问。旧非种子页/提案/.runs 不批量归因或重写。
- 真模型的五组 C2 及随后 C3 由车头在真机跑。已新增门控方法 `CatalogLiveSmokeTests.testC2ExtractionContentAndAttributionLive`（`MemoryPalaceIOSTests/CatalogLiveSmokeTests.swift:59-153`），复用现有 `TEST_RUNNER_MP_C3_LIVE_*` 框架；无 key 时既有 setUp 自动 XCTSkip。未运行该 live 方法，不把编译当真实模型质量证明。

## 3. 技术债务、逐条交回与验证

### 第 1–5 条落实

1. **新默认提示词、双方上下文**：`MemoryPalace/Services/FragmentPool.swift:218-252,276-288` 安装长期事实决策树、独立状态/结论句、全虚构正反例；保留字段说明、日期换算、真实感受/边界与架空动作区分、写后自检，工程名字宏仍为 `{{USER_NAME}} / {{CHAR_NAME}}`。`MemoryPalace/Views/PromptEditorPage.swift:20-27,111-116`、`MemoryWriterPages.swift:585-588` 明示旧自定义保留及主动恢复默认的切换合同。
2. **200 字与原有字段**：`FragmentPool.swift:209-213,383-417` 设置 maxContentChars=200，严格 Character 边界，不裁剪；tags/importance/emotion/resolved/valid_until 语义保留。
3. **必填、非法类别、原样复制**：`FragmentPool.swift:170-186,315-403` 严格解码共同字段、按卡给出原因，去空白/标点后与 msg 原文精确比较；没有近似照抄或去重模型。正文及归因仅归一化一次，校验与入库共用结果。
4. **subject/speaker 全链**：`MemoryPalace/Models/Memory.swift:31-33`；`Services/GlobalBackup/Schemas/FullDocuments.swift:251-253`、`FullDocumentMapping.swift:400-402,436-437`、`SchemaCoverageCheck.swift:278-279`；`FragmentPool.swift:457-466` 写库前赋齐；`Services/Wiki/CatalogSorter.swift:27-40,56-66,555-557,664` 读快照和展示；`CatalogWriter.swift:543` 自动备料、`CatalogAgent.swift:349-351` 开场、`CatalogRetrieval.swift:108-110` 搜索回执带归因，keywords 保留。
5. **最多一次重写、最后才写**：`FragmentPool.swift:420-476,511-519` 本次模板合同固定、具体错误反馈、第二轮只收好卡；process 只有一个 write 出口，原有精确正文去重不变。模型和写库期间开关、预算、异常、水位沿既有机制，不加第三轮或新重试队列。

### 新增 / 删除 / 适配的测试

- `FragmentPoolTests.swift:123-298` 新增 6 个行为用例：Character 121–200/201 与复合 emoji、共同字段缺失/非法、归因缺失与非法/三个协议 speaker、实际默认/自定义分支及重写期间模板变化、原样复制及唯一重写、第二轮好坏混合只写一批并精确去重。
- `MemoryAttributionPersistenceTests.swift` 新增 3 个磁盘/备份行为用例：真实旧库轻量迁移、新归因备份/磁盘往返、旧缺键备份导入再导出再恢复。不是用新库默认 nil 冒充迁移。
- `CatalogRetrievalTests.swift:344-451` 新增 3 个消费者用例：实际 Sorter/Writer caller、Agent 开场及两种工具回灌、归因元数据与正文预算/出处区间分离。用已留虚构 Memory 持久化后取快照，覆盖用户自述、AI 观察、AI 承诺和旧未知，不只检查字段存在。
- 新增上述一个 iOS 门控 live 方法，五组全虚构对话分别断言长期属性、纯讨论/工具失败负例、AI 普通观察负例、AI 承诺、上下文代词；核对语义实体和归因，不断言模型逐字输出。
- 删除 `testPromptOnlyNamesNoPersona`、`testDefaultTemplateHasNoHardcodedNames`、`testPromptAsksValidUntilWithConversationDay`、`testNote` 中旧提示词/日志措辞断言；保留自定义宏展开的行为验证。删掉跨天测试中的旧默认措辞 contains、本机固定第 7 条/4700 字假设及备份字段列表拷贝断言，不改钉新版措辞。
- `testUnknownCategoryFallsBackToFact` 删除旧回落合同，改为消费者可见的非法类别拒收；原单卡错误组合改用真正超界输入，不钉旧 120 字上限。`MemoryHealthWarningTests.swift:182` 合法夹具带新版归因；`MemoryOrganizeFieldsTests.swift:55` 全量覆盖样例带非空新字段。

### 实际生产路径 smoke

在隔离 XCTest 宿主、虚构 Message 和内存库中调用实际 `FragmentPool.process → run → write`，两轮请求期间用另一个 context 确认库仍为空，最终再用新 context 读取。实际输出：

```text
[P2 C2 smoke] modelCalls=2, writeBatches=1, stored=1, subject=烛墨, speaker=AI 承诺, source=n1
```

第一轮独有好卡未落库；第二轮同一好卡重复出现只加一次，缺归因及缺字段坏卡均未存。C3 行为用例实际执行 Writer 和 Agent，出站 caller/工具续轮可看到对应归因，实际提案保留原 f→UUID 出处。模型用确定性 caller/backend，不冒充真模型验收。

### 基线（16 套、252 tests、0 failures）

日志位于实现单同目录 scratchpad：`sol-p2-baseline-mac-build.log`、`sol-p2-baseline-tests.log`。

```text
** TEST BUILD SUCCEEDED **
Test Suite 'CatalogAgentTests' passed at 2026-10-21 20:47:51.770.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-21 20:47:52.014.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-21 20:47:52.529.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-21 20:47:52.737.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-21 20:47:52.887.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-21 20:47:53.053.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-21 20:47:53.707.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-21 20:47:53.737.
Test Suite 'CatalogSorterTests' passed at 2026-10-21 20:47:54.065.
Test Suite 'CatalogWriterTests' passed at 2026-10-21 20:47:54.687.
Test Suite 'FragmentPoolTests' passed at 2026-10-21 20:47:54.918.
Test Suite 'GlobalBackupAssistantTests' passed at 2026-10-21 20:47:54.927.
Test Suite 'InspectorRealPathTests' passed at 2026-10-21 20:48:31.674.
Test Suite 'MemoryHealthWarningTests' passed at 2026-10-21 20:48:31.808.
Test Suite 'MemoryOrganizeFieldsTests' passed at 2026-10-21 20:48:31.817.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-21 20:48:34.019.
Executed 252 tests, with 0 failures (0 unexpected) in 45.001 (45.050) seconds
** TEST EXECUTE SUCCEEDED **
```

### 最终集成验证（41 套、512 tests、0 failures）

首轮集成同为 41 套 512 测、0 failures。随后移除重复归一化和旧备份字段列表拷贝断言，再次构建并跑同套件；最终日志为 `sol-p2-final-mac-build-2.log`、`sol-p2-final-ios-build-2.log`、`sol-p2-final-tests-2.log`。mac 与具体 iOS Simulator 目的地应用 build-for-testing 通过；仅编译，没有启动模拟器。两组金样原样通过，未修改、未 RECORD。

```text
mac: ** TEST BUILD SUCCEEDED **
iOS Simulator: ** TEST BUILD SUCCEEDED **
iOS tests: ** TEST BUILD SUCCEEDED **
Test Suite 'BranchSelectionTests' passed at 2026-10-21 21:07:39.560.
Test Suite 'CatalogALineReaderTests' passed at 2026-10-21 21:07:39.799.
Test Suite 'CatalogAgentTests' passed at 2026-10-21 21:07:46.441.
Test Suite 'CatalogImportedOriginalTests' passed at 2026-10-21 21:07:46.730.
Test Suite 'CatalogInjectionTests' passed at 2026-10-21 21:07:46.764.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-21 21:07:46.931.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-21 21:07:47.731.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-21 21:07:48.064.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-21 21:07:48.249.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-21 21:07:48.682.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-21 21:07:50.236.
Test Suite 'CatalogScheduleTests' passed at 2026-10-21 21:07:51.224.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-21 21:07:51.230.
Test Suite 'CatalogSeedTests' passed at 2026-10-21 21:07:51.646.
Test Suite 'CatalogSettingsTests' passed at 2026-10-21 21:07:51.662.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-21 21:07:51.683.
Test Suite 'CatalogSorterTests' passed at 2026-10-21 21:07:52.050.
Test Suite 'CatalogWriterTests' passed at 2026-10-21 21:07:52.833.
Test Suite 'FragmentPoolTests' passed at 2026-10-21 21:07:53.296.
Test Suite 'GlobalBackupAssistantTests' passed at 2026-10-21 21:07:53.318.
Test Suite 'InspectorRealPathTests' passed at 2026-10-21 21:08:36.830.
Test Suite 'MemoryAttributionPersistenceTests' passed at 2026-10-21 21:08:37.608.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-21 21:08:37.695.
Test Suite 'MemoryHealthWarningTests' passed at 2026-10-21 21:08:38.209.
Test Suite 'MemoryOrganizeFieldsTests' passed at 2026-10-21 21:08:38.240.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-21 21:08:38.264.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-21 21:08:42.552.
Test Suite 'RecallToolTests' passed at 2026-10-21 21:08:42.608.
Test Suite 'RecallVisibilityTests' passed at 2026-10-21 21:08:42.704.
Test Suite 'RecallWindowSummaryTests' passed at 2026-10-21 21:08:42.753.
Test Suite 'RecallYesterdayTests' passed at 2026-10-21 21:08:42.973.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-21 21:08:43.117.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-21 21:08:43.304.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-21 21:08:43.906.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-21 21:08:43.916.
Test Suite 'SessionSummaryTests' passed at 2026-10-21 21:08:44.012.
Test Suite 'TimelineStoreV2Tests' passed at 2026-10-21 21:08:44.273.
Test Suite 'WikiProposalCitationLivenessTests' passed at 2026-10-21 21:08:44.626.
Test Suite 'WikiProposalDisplayTests' passed at 2026-10-21 21:08:44.653.
Test Suite 'WikiProposalTests' passed at 2026-10-21 21:08:45.374.
Test Suite 'WindowSummaryReadTests' passed at 2026-10-21 21:08:45.434.
Executed 512 tests, with 0 failures (0 unexpected) in 65.762 (66.015) seconds
** TEST EXECUTE SUCCEEDED **
```

另以守则现有脚本的具体 iOS 设备目的地**仅编译** `MemoryPalaceIOSTests`，最终 `sol-p2-final-ios-tests-build-2.log` 返回 `** TEST BUILD SUCCEEDED **`，新增 live 方法已纳入编译；没有安装、启动或运行真机测试。

### 偏离 / 未验 / 技术债

- 工程范围无偏离；只做 P2。没有触发频率调整、预算取消、第三轮、近似照抄、归因回填或后段提前施工。
- 真模型质量、随后的真 C3、设置页像素/点击验收未运行，按实现单交车头。确定性消费者/磁盘行为不替代这些验收。
- 既有 `feedbackDownCount` 未纳入全量备份的缺口保持原样，不借 P2 修无关字段；迁移测试确认旧库里的该值不丢。
- CodeGraph 明示指向主仓，不把它当本工位文件证据；Swift LSP references 返回空但实际有调用者，已报工具问题，按本工位读集迁齐。
- 实现单引用的 c3-brief-common.md 已不在磁盘；通过 Obelisk `fileHistory` 找回原始 Write 全文并遵守。按通用守则未 add/commit/stash/checkout/reset/restore/merge，交车头按提交 3 提交；NOW.md 未改。

## 4. 返工 · Claude 审查逐条裁定

基线为车头已提交的 `94b695af8`。本节覆盖首交记录中涉及默认 speaker、subject 上限、旧默认识别、全拒健康状态和归因展示的说明。守则文件已恢复并在开工先读；同工区另一 Claude 的第 5 段改动原样保留，未碰其文件库 / Preset / PersonaSettingsTab / CatalogFloorPrompt / CatalogFloorBase / Runner 注入 / App 等实现。仅指定的 CatalogWriter 碎片展示出口属于本返工。

### 4.1 逐条修法与边界

1. **emotion 必填对齐（P1）**：默认必填清单和 emotion 字段说明同时补齐，解码合同不变。`MemoryPalace/Services/FragmentPool.swift:264,271`。新增缺 emotion 的真实 process → 写库出口用例，两轮均缺时返回既有 rejected、零 write、库中零记录。
2. **默认拒绝 AI 观察（P1）**：requireAttribution 为真时 AI 观察属于非法 speaker；旧自定义仍接受三个协议值，旧持久数据不重新校验。`FragmentPool.swift:428-435`。分别走实际默认 / 自定义 run 验证两次拒收和一次接受。
3. **subject ≤40 Character（P2-1）**：上限与默认说明同步；40 接受、41 拒收并走唯一重写，不裁剪；明确提供字段的自定义输出也受此格式约束，旧库长值仍可展示。`FragmentPool.swift:213,267,429-432`。用普通汉字及 40 个复合 emoji 验证 String.count，而非 UTF-16 数。
4. **仅识别那一份旧默认（P2-2）**：从 `e62b23fa4:MemoryPalace/Services/FragmentPool.swift` 取旧默认全文，作为私有比对常量；存储值只去首尾空白后逐字相等，才选新默认及其必填合同。改一个字仍保留自定义，不改写 UserDefaults、不建立版本系统，旧常量不出站。`FragmentPool.swift:219-251,294-299`。测试独立冻结历史输入，验证原文、带首尾空白、改一字三种实际调用结果。
5. **全拒计失败，保留首轮诊断（P2-3）**：run 第一次拒收时回调数量及具体原因；process 第二轮零好卡且拒收>0 时不 write、不 recordOK，沿用 recordFailure / MemoryHealthStore.recordError、failStreak 及既有 rejected 结果。首轮原因和数量放在唯一最终日志前部，避免 recordError 的 200 字尾部裁切丢掉它们；最终结构化 rejected 仍记录最终数量。完全修复、好坏混合、第二轮 JSON 错误及预算 / 开关 / 瞬态跳过均保留首轮诊断；跳过只记现有日志，不更新健康。`FragmentPool.swift:463-486,554-608`。
6. **种子文件不冒充未知归因（P2-5）**：仅在 CatalogWriter assigned 输出对 sourcePath 非空省掉归因，保留来源路径与正文；未改 CatalogSeed 或种子其他流程。`MemoryPalace/Services/Wiki/CatalogWriter.swift:542-544`。实际 Writer 调用验证正文、CC cite、来源快照和生成记录不变。
7. **归因统一条目行内（P2-6）**：分拣、自动备料、agent 开场、search_fragments、search_aline 均按编号 / 日期 / 状态或类别 / 归因 / 正文排列在同一行。`CatalogSorter.swift:555-557`、`CatalogWriter.swift:542-544`、`CatalogAgent.swift:349-351`、`CatalogRetrieval.swift:108-110`。receipt 归因仍在 appendBody 之前，正文区间、6000 字预算、截断和 P1 实际可见出处登记不变。旧库超长 subject 压力夹具保留，不反套新提取规则。
8. **复制比较忽略 Unicode symbols（P2-7）**：在空白/标点集合上加 symbols，并按 Character 检查其 scalar，整簇忽略含符号的 emoji，避免只删图形却残留 ZWJ。只做归一化后完全相同的比较，不做近似匹配。`FragmentPool.swift:417,436-439`。覆盖「璃央喜欢猫～」→「璃央喜欢猫」、~、^、单 emoji、复合 emoji，以及近似但非相同的反例。
9. **恢复行为测试（P2-8）**：默认 system 无未展开宏、无写死人名，换称呼后实际展开新名字；跨天批次用仅含 DATE 的自定义探针验证实际 run 收到最后消息记忆日，不依赖默认措辞。testNote 按裁定原样恢复。`MemoryPalaceTests/FragmentPoolTests.swift:44-58,862-885`。
10. **live 唯一放宽（P2-9）**：承诺组恢复条件关键词由「恢复建议」改为「恢复」，其余实体及归因断言不变。`MemoryPalaceIOSTests/CatalogLiveSmokeTests.swift:106`。未运行真实端点或设备。

### 4.2 新增 / 恢复的测试

- FragmentPoolTests：`testMissingEmotionRewritesOnceAndNeverWrites`、`testDefaultRejectsAIObservationAndRewritesOnlyOnce`、`testCustomTemplateAcceptsAllThreeSpeakersWithoutRewrite`、`testSubjectFortyCharacterBoundaryAndRewriteWithoutTruncation`、`testCopiedSymbolsAreIgnoredWithoutFuzzyMatching`、`testStoredExactLegacyDefaultUsesCurrentContractButSingleEditRemainsCustom`；恢复 `testDefaultSystemExpandsNamesWithoutHardcodedNames`、原样 `testNote`，强化原跨天 DATE 验证。`FragmentPoolTests.swift:44-58,243-403,862-885`。
- MemoryHealthWarningTests：新增 `testAllCardRejectionsTurnRedWithoutWritingOrAdvancingLastOK`、`testMixedRepairWritesGoodCardsOnceAndKeepsFirstRejection`、`testFullRepairKeepsFirstRejectionInSingleSuccessLog`、`testSecondRoundInvalidJSONKeepsFirstCardRejection`、`testSkippedRetryKeepsFirstRejectionWithoutChangingHealth`。保留原三包三日志、网络/保存失败/开关、水位等断言。`MemoryHealthWarningTests.swift:134-305`。
- CatalogRetrievalTests：新增 `testSeedSourcePathOmitsAttributionOnlyInActualWriterAssignedEntry`；原自动 / agent / 两类搜索回执的归因、预算、正文区间与 sources 行为继续验证。其余受行内格式影响的既有测试迁为逐条检查原编号、日期、类别/状态及完整正文，保留原排序、待批排除、未引用留池、预算和出处断言；没有降低阈值、放松实体匹配或改金样。

### 4.3 P2-4 技术债（按裁定不修）

同一批消息在跨多次触发时仍可能重复付费：既有 skipped / failed 不提交水位，下一次触发可以重新认领并再次调用模型；现在卡片错误也会使用同一调用内的唯一重写，付费重放更容易出现。此返工只修健康与诊断，不修改既有认领 / 释放 / 触发 / 预算语义，不增加持久重试状态或自动恢复队列。最终 rejected 仍按既有 settled 语义提交，不把本次两轮全拒伪装成未结算无限重试。

### 4.4 实跑边界与首轮验证

只用守则脚本；mac `sol-p2-fix1-mac-build.log`、iOS Simulator 应用 `sol-p2-fix1-ios-build.log` 均 `** TEST BUILD SUCCEEDED **`。首轮 41 套 526 测有 7 个失败，均为既有 C3 测试把类别/状态与正文直接相连的旧格式断言；C2 42 测、健康 15 测及两组金样已原样通过。没有把首轮记为全过；随后只迁移这些 C3 格式断言，保留原行为约束。

隔离宿主的真实 process / MemoryHealthStore / MemoryWriteLog 输出：

```text
[P2 fix1 health smoke] calls=6, writes=0, streak=3, lastOKUnchanged=true, logs=3, rejected=6
[P2 C2 smoke] modelCalls=2, writeBatches=1, stored=1, subject=烛墨, speaker=AI 承诺, source=n1
```

没有安装或运行真机/模拟器，没有官方 key 请求，没有修改或 RECORD 金样；未做任何 git 写操作。真模型质量仍交车头。

### 4.5 最终验证

41 套、526 tests、0 failures。相较首交新增/恢复 14 个用例；首轮 7 个旧行格式失败已按同一条目保留原编号/日期/状态与完整正文约束迁移，排序、待批排除、未引用留池、预算和出处断言均保留。没有放松旧阈值或实体约束；live 仅有第 10 条已裁定的关键词例外。

日志均在实现单同目录 scratchpad：
- mac：`sol-p2-fix1-mac-build-2.log`
- iOS Simulator 应用：`sol-p2-fix1-ios-build.log`
- iOS 测试包（只编译）：`sol-p2-fix1-ios-tests-build.log`
- 最终套件与 smoke：`sol-p2-fix1-final-tests.log`

```text
mac: ** TEST BUILD SUCCEEDED **
iOS Simulator: ** TEST BUILD SUCCEEDED **
iOS tests: ** TEST BUILD SUCCEEDED **
Test Suite 'BranchSelectionTests' passed at 2026-10-21 21:38:43.999.
Test Suite 'CatalogALineReaderTests' passed at 2026-10-21 21:38:44.075.
Test Suite 'CatalogAgentTests' passed at 2026-10-21 21:38:47.086.
Test Suite 'CatalogImportedOriginalTests' passed at 2026-10-21 21:38:47.236.
Test Suite 'CatalogInjectionTests' passed at 2026-10-21 21:38:47.253.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-21 21:38:47.344.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-21 21:38:47.794.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-21 21:38:47.994.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-21 21:38:48.127.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-21 21:38:48.394.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-21 21:38:49.009.
Test Suite 'CatalogScheduleTests' passed at 2026-10-21 21:38:49.436.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-21 21:38:49.439.
Test Suite 'CatalogSeedTests' passed at 2026-10-21 21:38:49.768.
Test Suite 'CatalogSettingsTests' passed at 2026-10-21 21:38:49.781.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-21 21:38:49.810.
Test Suite 'CatalogSorterTests' passed at 2026-10-21 21:38:50.144.
Test Suite 'CatalogWriterTests' passed at 2026-10-21 21:38:50.761.
Test Suite 'FragmentPoolTests' passed at 2026-10-21 21:38:51.053.
Test Suite 'GlobalBackupAssistantTests' passed at 2026-10-21 21:38:51.062.
Test Suite 'InspectorRealPathTests' passed at 2026-10-21 21:39:26.926.
Test Suite 'MemoryAttributionPersistenceTests' passed at 2026-10-21 21:39:27.216.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-21 21:39:27.239.
Test Suite 'MemoryHealthWarningTests' passed at 2026-10-21 21:39:27.443.
Test Suite 'MemoryOrganizeFieldsTests' passed at 2026-10-21 21:39:27.451.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-21 21:39:27.466.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-21 21:39:29.573.
Test Suite 'RecallToolTests' passed at 2026-10-21 21:39:29.609.
Test Suite 'RecallVisibilityTests' passed at 2026-10-21 21:39:29.640.
Test Suite 'RecallWindowSummaryTests' passed at 2026-10-21 21:39:29.654.
Test Suite 'RecallYesterdayTests' passed at 2026-10-21 21:39:29.710.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-21 21:39:29.787.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-21 21:39:29.836.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-21 21:39:30.025.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-21 21:39:30.032.
Test Suite 'SessionSummaryTests' passed at 2026-10-21 21:39:30.071.
Test Suite 'TimelineStoreV2Tests' passed at 2026-10-21 21:39:30.165.
Test Suite 'WikiProposalCitationLivenessTests' passed at 2026-10-21 21:39:30.311.
Test Suite 'WikiProposalDisplayTests' passed at 2026-10-21 21:39:30.330.
Test Suite 'WikiProposalTests' passed at 2026-10-21 21:39:30.770.
Test Suite 'WindowSummaryReadTests' passed at 2026-10-21 21:39:30.788.
Executed 526 tests, with 0 failures (0 unexpected) in 46.795 (46.932) seconds
** TEST EXECUTE SUCCEEDED **
```

最终日志再次观察到 §4.4 的两条实际路径 smoke，健康为连续三包全拒→6次模型/0次写库/失败计数3/lastOK不动，合法空包随后清零；混合结果仍只写一次。两组金样原样通过，未 RECORD。没有 P5 半成品编译阻塞；本返工所有可达项完成，真实模型/设备验证未运行。

## 5. 返工 2/3 · 真机 C2 JSON 取证与引号反馈

基线 `b20a8876f`。车头报告 Anthropic 官方端点 / claude-sonnet-4-6 的五组 C2 live 在第 125 行抛 `format("JSON 数据格式不合法")`；没有场景名或原文。本次已定位代码出口、增加 live 诊断，但**未完成模型输出复现或生产修复**：复现构建被禁改的第 5 段文件阻塞，按守则停止。

**返工 3 更新**：车头已提供两轮原文，根因确认为 content 内未转义的 ASCII 双引号；已完成默认规则、具体反馈和行为回归，mac/iOS 编译通过。§5.3、§5.4 保留返工 2 当时的阻塞记录；当前结论与验证见 §5.5–5.7。

### 5.1 三个问题的代码证据

1. **为何 run 抛出，而非重写或返回拒收？** 首轮 `decodedBatch` 和卡片拒收都在 do/catch 内，失败后带原因重写一次；第二轮 `return try decodedBatch(...)` 没有同样的收口，整包错误直接向外抛。`MemoryPalace/Services/FragmentPool.swift:470-485`。整包 JSONDecoder 失败会被包装成 `.format(decodingReason(error))`（`:386-393`）；`decodingReason` 只对缺字段、类型错误和 null 给字段信息，其余包括 `DecodingError.dataCorrupted` 都归为「JSON 数据格式不合法」（`:370-377`）。因此这句报错不能定位具体场景、字符或字段。对于正常可解的 JSON 容器，resolved/emotion 的单卡类型错由 Lossy 捕获并记卡片拒收（`:351-366`），不等同于第二轮整包解码抛错。
2. **生产自动提取如何表现？** API 与 CC 都通过 process 调 run；process catch 会 recordFailure，并将 MemoryWriterError 映射为 `.rejected`，不走 write 或 recordOK（`FragmentPool.swift:554-606`）。它沿现有 failStreak / 健康警告记失败；rejected 属于 settled，随后提交该批水位，不让同一已拒收批次在下次触发重新来一遍（`:544-549,721-727`）。API 还显示「🧠 记忆提取失败」，不抛穿聊天任务（`MemoryPalace/ViewModels/ConversationViewModel.swift:5033-5056`）；CC 记健康/日志并收尾水位（`MemoryPalace/Services/SessionCloseout.swift:1256-1269`）。live 是直接调用 run，没有生产的 process 收口。
3. **与 P2 前是否不同？** 已读取 `git show e62b23fa4:MemoryPalace/Services/FragmentPool.swift` 的 run / parse 原文。旧 run 同样在两轮整包 parse 失败后抛 `.format`，当时文案为「整包不是一个合格的 JSON 对象，拒收」。P2 将整包错误改成具体解码原因，并把单卡校验错误也纳入唯一重写；旧版首轮只要整包能解就返回，包括有拒收卡的 Batch。故“第二轮整包非法会抛出”不是本次新增，新的卡片重写入口与错误信息是变化点。

读码还确认：一层 json/无语言围栏原已允许；对象外说明文字不接受；`{"fragments":[]}` 是合法空包，裸 `[]` 不是协议整包；valid_until 错误类型仍只丢字段（`FragmentPool.swift:180-198,328-345,347-349,408-414`）。这些是代码合同，**不是已跑过的假 provider 复现结论**；不能据此认定真机是哪一种输出。

### 5.2 live 诊断交付

仅改 `MemoryPalaceIOSTests/CatalogLiveSmokeTests.swift:125-152` 的既有 `testC2ExtractionContentAndAttributionLive`；保留环境变量门控、五组虚构对话及原语义/实体/归因断言。不加生产诊断钩子、不改提示词或解码、不增加请求轮数。

- 每组先打印编号和标签 BEGIN。
- 每轮在调用前打印 ROUND n REQUEST；返回后用 RAW BEGIN/END 标出交给 C2 解析的完整文本，nil 显示 `<nil>`。沿用 caller 原有首尾 trim，不另做 JSON 抽取或修补；日志沿用 CatalogLiveAuthProtocol.redacted 遮掉运行时 key。
- 每轮 caller 抛错打印 ROUND n ERROR；run 最终成功/拒收/跳过打印 FINAL rounds=n 及完整 Batch/可选值，含卡片、拒收数及原因；最终抛错打印 FINAL ERROR。
- 抛错时记录带场景标签的 XCTFail 并继续后续场景，避免第一组失败让其余四组没有证据；nil 同样失败后继续。
- 增加 `batch.rejected == 0` 断言，避免未来 run 用拒收 Batch 返回后，负例场景仅因空卡片误判为模型合格。没有放松原合同。

日志形状如下，**仅为格式说明，不是真机实跑输出**：

```text
[C2 LIVE 1/5 · 长期属性] BEGIN
[C2 LIVE 1/5 · 长期属性] ROUND 1 REQUEST
[C2 LIVE 1/5 · 长期属性] ROUND 1 RAW BEGIN
（完整模型返回文本）
[C2 LIVE 1/5 · 长期属性] ROUND 1 RAW END
（如果发生唯一重写，继续打印 ROUND 2）
[C2 LIVE 1/5 · 长期属性] FINAL rounds=… （Batch / nil）
（抛错则为 FINAL ERROR，并保留具体错误）
```

### 5.3 复现范围、阻塞与验证

基线先通过 mac build-for-testing 和原有两个相关套件，共 57 测、零失败：

```text
** TEST BUILD SUCCEEDED **
Test Suite 'FragmentPoolTests' passed at 2026-10-21 21:50:30.258.
Test Suite 'MemoryHealthWarningTests' passed at 2026-10-21 21:50:30.464.
Executed 57 tests, with 0 failures (0 unexpected) in 0.447 (0.456) seconds
** TEST EXECUTE SUCCEEDED **
```

随后准备了本地假 Anthropic HTTP provider、同一默认提示词和虚构饮品对话，覆盖围栏、前后说明、合法空包/裸数组、resolved/emotion 类型、valid_until 类型/日期、非法正号/未转义引号及混合首轮后整包非法。**尚未执行**：批准脚本的复现构建报：

```text
** TEST BUILD FAILED **
MemoryPalace/Views/PersonaSettingsTab.swift:1707:56: error: the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions
```

该文件属于同工区第 5 段禁区；未改它、未重试或绕过。未留尚未验证且依赖拟议生产修复的测试：FragmentPoolTests 已撤去本次新增的临时复现方法，恢复原内容；无新增永久单测、无生产修改。最终 mac/iOS 及 iOS live 测试包编译、假 provider 行为 smoke 均未完成，不能拿基线或上一轮 SUCCEEDED 充当本次修改后验证。

日志在 scratchpad：`sol-p2-fix2-baseline-build.log`、`sol-p2-fix2-baseline-tests.log`、`sol-p2-fix2-repro-build.log`。没有真机/模拟器操作、真实端点请求或真实数据读取；未 RECORD 金样、未做 git 写操作。

### 5.4 返工 2 当时的边界 / 下一段风险 / 技术债

- **边界情况**：具体真机场景和原文仍未知；仅凭统一错误文案不能判定合法 JSON 被误判，不能对字符串数字做类型放宽、用正则抢救或加第三轮。本次保留原严格校验与生产行为，不宣称“不再抛错”。
- **与下一段交互风险**：同工作区 P5 的 PersonaSettingsTab 编译错误挡住了本次复现和 iOS 诊断代码的编译验证；需该编译前置恢复后，才能继续假 provider 取证与车头真机日志验证。不需要修改 P5 接口。
- **技术债 / 待补证据**：run 第二轮整包错误向外抛的既有出口仍在，生产 process 能接住，但直接 run 的 live 必须记录它。若后续假 provider 或真实原文确认根因，再按 P2 第 5 条把非法输出收敛为唯一重写后的拒收，不把坏卡存成成功。本节不把尚未执行的回归测试记为通过。

### 5.5 返工 3 · 根因证据与 P2 前行为

本次基线 `75295cc40`，工作区干净。车头报告 😷 iPhone 14 / Anthropic 官方端点 / claude-sonnet-4-6 连跑四次，承诺组三次两轮失败，其余四组每次一轮通过。本次读取 scratchpad 的 `c2-live-repeat-1.log:69-76` 和 `c2-live-repeat-3.log:69-76`：两轮 content 都在 JSON 字符串内直接写 `"纸灯暂停"` / `"恢复建议"`，没有反斜杠转义；随后均为 FINAL ERROR rounds=2 的 `.format("JSON 数据格式不合法")`。这是非法 JSON，不是 resolved/emotion 类型被误判，也不是归因断言失败。

**这类错误在 P2 前就存在**：`e62b23fa4` 的 parse 同样直接用严格 JSONDecoder，未转义字符串内双引号本来就会整包失败，旧 run 也只重写一次、两轮整包非法后抛 format。P2 没有新引入这条语法限制；此前只保留笼统原因，模型重写时不知道要修哪处。这里指既有解析/拒收机制，不把本次四轮观察外推成 P2 前的模型失败频率证据。

### 5.6 修法、边界与新增测试

- **默认提示词**：在单对象示例旁加一句，content/subject/tags 内引用词语用「」，不要用英文双引号。只改新默认，旧自定义和旧默认比对常量不变。`MemoryPalace/Services/FragmentPool.swift:264`。
- **重写反馈**：单列 dataCorrupted，沿用项目现有 NSError 底层诊断读取模式，保留 JSONDecoder 的 NSDebugDescription；有 NSJSONSerializationErrorIndex 时，将 UTF-8 下标换成 Swift Character 位置，并取前后各最多 10 个 Character 原文；补充字符串内双引号写成 `\"` 或改用「」的提示。整包解码 catch 传入解析文本。`FragmentPool.swift:371-391,406`。
- **严格性不变**：没有调用 C3 的自动引号修复，没有正则/启发式抢救、类型放宽或第三轮；run/process 的控制流没有改。第二轮仍非法时 run 仍抛 format，生产 process 沿原机制返回 rejected、记健康失败并结算水位，不写库。
- **位置可用性边界**：下标来自 JSONDecoder，不猜错误位置。若系统未提供下标或下标不能映射成 Character 边界，只回传解析器上下文与通用引号提示，不编造位置或截取无关内容。

新增两个永久行为测试，无旧断言删除或放宽：

1. `testLivePromiseQuoteFeedbackAndAtomicPersistence`，`MemoryPalaceTests/FragmentPoolTests.swift:480-565`：首轮使用实现单 ROUND 1 全文；第二轮分别给合法转义 JSON、实现单 ROUND 2 全文。检查出站重写反馈准确指向第 48 Character，包含错误附近原文和引号提示；两轮调用期间库始终为空。合法分支只 write 一次、只存一张，正文保留合法解码的英文引号，归因/来源节点正确；两轮非法分支零 write/零记录、failStreak 增加、lastOK 不变，并产生失败日志。
2. `testOutboundDefaultQuoteGuidanceDoesNotChangeCustomTemplate`，`FragmentPoolTests.swift:567-590`：实际 run 出站 system 同一规则行包含三个字段、中文引号和禁止双引号的含义，不钉完整句子；切到自定义后出站仍只有其宏展开结果，存储原文不变。

### 5.7 本次验证与剩余风险

只使用批准脚本，无设备或真实模型调用。没有新 Swift 文件，不需要重新生成工程。mac / iOS Simulator 的 build-for-testing 均通过；8 套 160 测零失败，包含原金样且未 RECORD：

```text
mac: ** TEST BUILD SUCCEEDED **
iOS Simulator: ** TEST BUILD SUCCEEDED **
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-21 22:13:13.056.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-21 22:13:13.340.
Test Suite 'FragmentPoolTests' passed at 2026-10-21 22:13:13.688.
Test Suite 'InspectorRealPathTests' passed at 2026-10-21 22:13:50.972.
Test Suite 'MemoryAttributionPersistenceTests' passed at 2026-10-21 22:13:51.264.
Test Suite 'MemoryHealthWarningTests' passed at 2026-10-21 22:13:51.475.
Test Suite 'MemoryOrganizeFieldsTests' passed at 2026-10-21 22:13:51.484.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-21 22:13:53.723.
Executed 160 tests, with 0 failures (0 unexpected) in 40.718 (40.751) seconds
** TEST EXECUTE SUCCEEDED **
```

实际 process → 严格解析/唯一重写 → 内存 SwiftData 写库 → 健康/日志路径输出：

```text
[P2 fix3 quote smoke] repaired=true, calls=2, writes=1, stored=1, outcome=done(added: 1), failStreak=0
[P2 fix3 quote smoke] repaired=false, calls=2, writes=0, stored=0, outcome=rejected, failStreak=1
```

实际反馈（两分支相同）：

```text
写出来的格式不对：JSON 数据格式不合法（解析器：Unexpected character 'ç' in object around line 1, column 72.）；第 48 字符附近：诺：岚舟在对话中说"纸灯暂停"时，星砚立；字符串里的双引号要写成 \" 或改用「」。；共 1 张不合格
```

解析器原文的字符提示按系统返回保留；补充的第 48 Character 和 20 Character 中文窗口由测试独立核对，避免把 UTF-8 字节列号误当中文字符位置。反馈只帮助模型改写，不处理原文。

日志在 scratchpad：`sol-p2-fix3-mac-build.log`、`sol-p2-fix3-ios-build.log`、`sol-p2-fix3-tests.log`。无前次 P5 编译阻塞；未提交，未修改设备/真实数据/金样。下一段接口、提取频率和预算不变。

剩余风险：真实模型仍可能无视提示，不能承诺真机成功率；两轮不合法仍按既有拒收处理。车头后续连跑验证提示是否改善承诺组，不新增自动恢复机制。P2-4 跨触发重复付费债务仍按 §4.3 保留。
