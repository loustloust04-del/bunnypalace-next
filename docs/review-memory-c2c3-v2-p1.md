# C2/C3 v2 · P1 复盘与交回

> §1–7 为首交记录（车头已提交 `e6c03fe20`）。原文过滤、停止和消息定位的最新修复与限制，以 §8 为准。

范围：`plan-memory-c2c3-v2.md` 第 2 段实现 1–6、提交 2。基线 HEAD `8f9933307`；开工工作区干净。按实现单仅修改本工位文件，不做 git 写操作，不跑官方端点、不安装或操作设备、不碰真人数据。P2 及后段未实现。

## 1. 按第 1–6 条交回

1. **安全快照后三路并行**：`MemoryPalace/Services/Wiki/CatalogRetrieval.swift:5,125-152` 用三个 `async let` 并行召回原文、Recall 共用 A 线、BM25/向量碎片。只传容器句柄、楼层和不可变碎片 / 原文 DTO，不传活 `Memory` / `MessageNode`。`CatalogRunner.swift:272-275,499-510` 给 daily / now / topic 接同一个原文入口；`CatalogWriter.swift:488-504`、`CatalogAgent.swift:14-16,147-179,238-240,452-454` 共用适配。P0 的共享 BM25、RRF、CatalogALineReader、向量 revision 和写回核对均复用，未另写内核或向量库。
2. **索引相关度与扫描回退**：`MemoryPalace/Services/Search/SearchIndexStore.swift:337-383` 新增 `catalogHits`，现有分词展开后 OR、参数绑定、`bm25(fts)`；正文走既有 `bodies` 批取。`SearchTextSegmenter.swift:39-48` 让索引和扫描用同一组合标题分词。`SearchService.swift:176-276` 后台取得候选，nil / 不可索引 / 错误时复用既有 `fetchContentWithKeyword` 扫描，扫描也用共享 BM25 排序；未建第二索引或第二套扫表器。原 `hits(word:)` 仍按 created 倒序，搜索框合同不变。
3. **原文可见域与归因**：`MemoryPalace/Services/SearchService.swift:165-173,238-275` 保留 profileId / conversationId / nodeId / 时间 / role / 主支线，排除另一楼层、窗口及节点回收站、孤儿、隐藏源、合成根、非 user/assistant。索引与扫描统一用可见正文净化并复核词面，不带思考链或工具专属字段。`CatalogRetrieval.swift:92-95` 将角色和主支线随原文交给写手；助手明确不是用户事实。
4. **本次真实出处与审核定位**：`MemoryPalace/Services/Wiki/CatalogWriter.swift:32-101,118-123,196-230,435` 新增原文登记和 RawCite nodeId，只认实际给出的节点，稳定上下文取登记 DTO；伪节点、错窗口 / 楼层、A4 借成 A2/A3、未给出的 A2 段不能通过。`WikiProposal.swift:17-31` 新增可选原文定位字段；`WikiProposalDisplay.swift:82-114` 保留旧出处展示和同楼层消息目标；`MemoryPalace/Views/WikiProposalViews.swift:474-484,518-524` 审核按钮走既有 `navigateToSearchResult(nodeId:conversation:context:)`。旧提案不编 nodeId，A4 保留自己的层。
5. **统一四层筛选**：`MemoryPalace/Services/Wiki/CatalogRetrieval.swift:18-122` 先按稳定出处去重，再以同一候选集、同一文档频率重算共享 BM25，乘原文 **1.2** / A 线 **1.1** / 碎片 **1.0**，稳定全局排序；最多 **10 条、正文合计 6000 Character**，替换 P0 的 10/5/8 分桶和完整回执预算。各引擎异量纲分数不相加；写手规则要求跳过不相关材料。没有来源预留名额或 reranker。
6. **召回分与出站截断分开**：`MemoryPalace/Services/Wiki/CatalogSearchReceipt.swift:34-114` 给每段正文挂出处，支持正文预算和实际可见前缀；`CatalogALineReader.swift:263-311` 的 A3 / A2 目录 gist / 全段分别挂来源。`CatalogWriter.swift:465-475` 只登记实际搜索回执；`CatalogAgent.swift:455-458,618-639` 仅预登记开场真实分配碎片，工具累计预算截断后才登记。向量独有词面 0 分仍进入统一排序，同分保留召回次序；全局预算不保证所有 0 分候选都入选。日常搜索预算没有套到种子直接分配的全文原料。

## 2. 边界情况

- 同一原文按楼层 + nodeId，同碎片按 UUID，A 线按层 / 窗口 / 日期 / 段及时间 / 正文身份去重；不会把同内容的不同真实出处做语义去重。碎片 BM25 / 向量多路仍由 P0 RRF 按 UUID 合并，f 号不重编。
- 搜索 6000 约束**正文**，不是标题 / 日期 / 引用说明；因此完整回执可以超过 6000，仍受日常 agent 原有累计 40000 字约束。楼层 prompt、已有页和直接分配碎片沿原有合同，不顺手加总请求裁剪。
- Unicode 按 Swift `Character` 截断，部分正文已可见就能引用该真实出处；只有标题 / 查询 / 来源说明可见时不登记，尾部节点、段、碎片不能被引用。来源存在检查不是现实世界语义验真，也不声称阻止模型误读助手发言。
- 原文索引未就绪、不支持 emoji 等词、SQLite 查询错误均实际回退；组合标题在索引和扫描用同一词面 OR。扫描候选是所属后台 context 里的对象，转 DTO 后才返回。
- `CatalogSearchEvidence.original` 允许旧 `.runs` 缺键，旧提案新增 Cite 字段全可选；不清索引、不重新导入、不重提取、不回填旧出处。

## 3. 与下一模块交互的风险

- P2 的 C2 新模板、200 字、subject/speaker、备份链均未动；本段原文 role 不是 P2 的提取 speaker 字段。
- 两次审批、Prompt 同源文件夹、新种子、A4 日级结构都仍在后段。本段 A4 是现存时间轴来源，不伪造未来日 A4 / 单窗口 A2。以后加日级出处仍须沿实际回执的来源区间登记。
- 向量候选在全局 BM25 后可以因 0 分排在正分候选后；本段遵守 plan，不为向量另外保留名额。P0 的向量独有实际输入测试仍保留；宽主题竞争测试改为高相关后层来源，避免与 P1 全局排序合同冲突。
- 审核 UI 已接原 nodeId 定位，纯目标测试覆盖楼层 / 窗口 / 主支线节点。按禁设备守则未做真实点击和像素验收，不将跳转目标单测冒充设备 UI 实测。

## 4. 技术债务与实际路径证据

- 未新增索引、向量服务、同义词模型、reranker、重试队列或新审批机制。删除受影响的逐项 schema 实现断言；旧 6000 整份回执 / 固定轮数断言改为实际正文总预算及累计反馈上限，不钉新提示词。
- `MemoryPalaceTests/CatalogOriginalRetrievalTests.swift:43-113` 在临时文件和内存 SwiftData 中实际执行 Writer、CatalogSession.daily / organizeNow / organizeTopic：只有原文带《云桥城》正文时，26 字正文及 `cloudbridge-original-node` 进入真实写手调用，三种 Session 各产生 1 份带 node cite 的提案；索引和 nil 扫描两路都给到相同正文。
- `CatalogOriginalRetrievalTests.swift:178-235` 复用仓库 `OutputTokenCapTests.ScriptedHTTPServer`，生产 AssistantCloudBackend → ProviderRouter → Anthropic / OpenAI 兼容链各跑两轮；本机假 provider 返回 search tool call，第二次实际 HTTP 请求携带正文和 nodeId，检查 tool_use/tool_result 或 tool_calls/tool_call_id 的配对，最终交回带原文 cite 的提案。没有官方请求或真实 key。
- `CatalogRetrievalBudgetTests.swift:47-98` 放 15 条弱相关原文、40 条宽泛 A4 和 30 条碎片，高分 A2 与原快照末尾 f31 均进入实际自动 / 手动写手并被提案引用。观察自动完整 user 1664 字、搜索正文 1146 字；手动反馈 1548 字、搜索正文 1146 字。不是只数引擎调用。
- `SearchServiceIndexPathTests.swift:225-330` 覆盖回退、另一楼层、两类回收站、孤儿、主支线、助手、隐藏思考 / 工具字段和组合标题；`SearchIndexStoreTests.swift:51-71` 覆盖相关度与旧时间排序互不干扰。`CatalogOriginalRetrievalTests.swift:115-175`、`CatalogWriterTests.swift:104-189`、`WikiProposalDisplayTests.swift:40-90` 覆盖同出处去重、权重、稳定同分、截断 / 未提供尾部、伪出处、旧数据和消息目标。
- 官方 Anthropic / OpenAI 端点、真实 Apple 资产语义命中和 Air / 模拟器 UI 仍按实现单交车头；本单没有权限运行，未声称通过。
- CodeGraph 明示查询的是主仓，不是本 worktree；按当前工位文件接线。sourcekit-lsp 的 references 返回空，已报工具问题，没有把空引用当无调用者。
- 集成首轮 16 个失败均已定位：旧完整回执预算断言、未提供碎片夹具、未生效的全局 URLProtocol 假端点、超长中文标题词面夹具；已换现有本机 HTTP 假服务器，并使测试数据符合实际提供合同。第二轮只剩记录测试把第一条 6 字碎片当整个 6000 字正文预算，已改为按同次全部搜索正文合计验证。

## 5. 基线验证

日志均在实现单指定 scratchpad 下：`sol-p1-baseline-mac-build.log`、`sol-p1-baseline-tests.log`。26 套件、363 tests、0 failures；金样未 RECORD。

```text
** TEST BUILD SUCCEEDED **
Test Suite 'CatalogALineReaderTests' passed at 2026-10-18 23:26:56.126.
Test Suite 'CatalogAgentTests' passed at 2026-10-18 23:26:58.078.
Test Suite 'CatalogInjectionTests' passed at 2026-10-18 23:26:58.095.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-18 23:26:58.262.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-18 23:26:58.395.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-18 23:26:58.679.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-18 23:26:59.314.
Test Suite 'CatalogScheduleTests' passed at 2026-10-18 23:26:59.737.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-18 23:26:59.740.
Test Suite 'CatalogSeedTests' passed at 2026-10-18 23:27:00.087.
Test Suite 'CatalogSettingsTests' passed at 2026-10-18 23:27:00.095.
Test Suite 'CatalogSorterTests' passed at 2026-10-18 23:27:00.412.
Test Suite 'CatalogWriterTests' passed at 2026-10-18 23:27:00.995.
Test Suite 'InspectorRealPathTests' passed at 2026-10-18 23:27:36.570.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-18 23:27:36.591.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-18 23:27:36.603.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-18 23:27:38.844.
Test Suite 'RecallToolTests' passed at 2026-10-18 23:27:38.871.
Test Suite 'RecallVisibilityTests' passed at 2026-10-18 23:27:38.898.
Test Suite 'RecallYesterdayTests' passed at 2026-10-18 23:27:38.962.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-18 23:27:39.022.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-18 23:27:39.075.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-18 23:27:39.202.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-18 23:27:39.205.
Test Suite 'WikiProposalDisplayTests' passed at 2026-10-18 23:27:39.222.
Test Suite 'WikiProposalTests' passed at 2026-10-18 23:27:39.629.
Executed 363 tests, with 0 failures (0 unexpected) in 43.497 (43.577) seconds
** TEST EXECUTE SUCCEEDED **
```

## 6. 最终验证

27 套件、383 tests、0 failures。只用守则指定脚本；日志：`sol-p1-final-mac-build-2.log`、`sol-p1-ios-build.log`、`sol-p1-final-tests-2.log`。iOS 为脚本指定的具体 Simulator 目的地 build-for-testing，仅编译、未启动模拟器。两组金样原样通过，未 RECORD。实际原文、三种 Session、两条 provider 兼容链及预算竞争证据见 §4。

```text
mac: ** TEST BUILD SUCCEEDED **
iOS: ** TEST BUILD SUCCEEDED **
Test Suite 'CatalogALineReaderTests' passed at 2026-10-18 23:41:41.265.
Test Suite 'CatalogAgentTests' passed at 2026-10-18 23:41:44.080.
Test Suite 'CatalogInjectionTests' passed at 2026-10-18 23:41:44.094.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-18 23:41:44.246.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-18 23:41:44.680.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-18 23:41:44.864.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-18 23:41:45.014.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-18 23:41:45.626.
Test Suite 'CatalogScheduleTests' passed at 2026-10-18 23:41:46.054.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-18 23:41:46.058.
Test Suite 'CatalogSeedTests' passed at 2026-10-18 23:41:46.386.
Test Suite 'CatalogSettingsTests' passed at 2026-10-18 23:41:46.394.
Test Suite 'CatalogSorterTests' passed at 2026-10-18 23:41:46.730.
Test Suite 'CatalogWriterTests' passed at 2026-10-18 23:41:47.347.
Test Suite 'InspectorRealPathTests' passed at 2026-10-18 23:42:23.395.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-18 23:42:23.415.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-18 23:42:23.426.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-18 23:42:25.647.
Test Suite 'RecallToolTests' passed at 2026-10-18 23:42:25.673.
Test Suite 'RecallVisibilityTests' passed at 2026-10-18 23:42:25.699.
Test Suite 'RecallYesterdayTests' passed at 2026-10-18 23:42:25.757.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-18 23:42:25.826.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-18 23:42:25.877.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-18 23:42:26.064.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-18 23:42:26.068.
Test Suite 'WikiProposalDisplayTests' passed at 2026-10-18 23:42:26.086.
Test Suite 'WikiProposalTests' passed at 2026-10-18 23:42:26.532.
Executed 383 tests, with 0 failures (0 unexpected) in 45.294 (45.369) seconds
** TEST EXECUTE SUCCEEDED **
```

## 7. 偏离 / 未验 / 交接

- 工程行为无 plan 范围偏离；只完成 P1 1–6。未提前加入 C2 新提示词、200 字、subject/speaker、审批、Prompt 文件夹、种子或 A4 改版。
- P0 宽主题 f31 夹具改为高词面相关碎片，才能验证 P1 的全局竞争，而不是要求 0 分碎片压过 30 条正分候选；独立的向量无共同关键词实际写手回归保留并通过。
- 未完成的仅为实现单明确交车头的真端点 / 真 Apple 资产 / 设备 UI 验收；没有用假 provider 证明真实模型输出质量。审核的消息定位合同已测，真实点击和外观未验。
- 按通用守则未 add / commit / stash / checkout / reset / restore / merge；交车头按「提交 2」提交。NOW.md 未改，状态写在 `docs/now/backend-2.md`。


补充受影响测试文件归属：`MemoryPalaceTests/CatalogAgentTests.swift:147-236,747-767` 属第 5–6 条，保留完整运行记录与累计预算行为断言，删除逐项 schema 拷贝断言；`MemoryPalaceTests/CatalogJSONRepairTests.swift:99-117` 属第 4、6 条，格式修复用例显式把唯一引用碎片放进实际开场，不能再靠预登记全快照绕过出处。两组金样测试文件及金样内容均未修改。

## 8. P1 fix1 · astra 四条全收

基线：`e6c03fe20`，返工开工工作区干净。仍只做 P1，不做 git 写操作、不跑官方端点、不接触真人数据、不启动设备、不 RECORD 金样。

### 8.1 导入思考 / 工具污染：先复现，再按当前结构取正文

- **根因证据**：`MemoryPalace/Services/ClaudeImporter.swift:92-105,375-411` 为旧搜索把 thinking、工具输入 / 结果、附件提取一同拍平进 `content`，其中工具结果无可靠分隔；Claude 的 `<<<THINK>>>` 不在原 `ContentCleaner.visibleText` 的已识别格式里。ChatGPT 的内部 analysis/use/result 链也会折入正常回复（`ChatGPTPayloadBuilder.swift:264-298`）。原 C3 的扫描和索引路径都从这份扁平文本做“可见正文”复核，因此隐藏词仍通过。
- **实际复现**：`MemoryPalaceTests/CatalogImportedOriginalTests.swift:22-59,190-210` 用虚构 JSON 经真实 `ClaudeImporter.load/makePayload`、`ConversationImporter.makePayload`，再经正式 `makeImportedConversation/makeImportedNode` 写内存库；索引故意保留旧扁平正文，分别执行 index/store 与 index:nil。修前 2 测、8 failures：Claude 两路均返回 thinking/use/result/attachment/mixed/visible 六节点，正确集合仅 visible；ChatGPT 两路均把只有内部链提到《云桥城》的 reply 作为命中，并回灌含工具和思考的全文。日志 `sol-p1-fix1-before-mac-build.log` / `sol-p1-fix1-before-tests.log`。
- **修法**：新增 `MemoryPalace/Services/Search/CatalogOriginalText.swift:5-50`，在 node 所属 context 里读取现有 `segmentsData` / `segments`，只允许 `.text`。`MemoryPalace/Services/SearchService.swift:210-288` 在既有窗口批次取得当前 node 后，两路都调用该入口，再复核关键词；角色 / 时间也取当前 node，不信陈旧索引元数据。FTS 只负责候选召回，正文改从批取的当前节点结构取得，不再用旧索引扁平 body 作事实源。未改导入写入、通用搜索清洗器或搜索框合同，未重建 / 重导数据。

| 格式 | 当前能力 / 边界 |
|---|---|
| Claude / ChatGPT / RikkaHub / Kelivo 当前导入器保留的 `segmentsData` | 四条真实导入路径均以虚构夹具测试。只取 text，thinking / toolUse / toolResult / 附件提取 / 音频 script 等不进原文。 |
| 原生节点的结构化思考、工具及旁路字段 | 同一 allowlist；不读 ccThinking、thinkingSummary、toolSummaries、sourceMetadata 等作正文。 |
| 原生助手 `contentType=text` 且非空分段全为 audioRef | 这是正文仍存 content、语音后挂的既有格式；保留 content 正文，不拿 script 当正文。不能用该例外放行 segmented 音频。 |
| 明确 `<<<THINK>>>…<<</THINK>>>`、`[thinking]…[/thinking]`、开头 `<think>…</think>` | 按明确边界剥除，复用现有 LeadingThinkTagSplitter；缺闭合 / 嵌套损坏保守返回空。不猜正文中间的 `<think>` 引用。 |
| 结构存在但坏 / 空 / 含未知段，或明示结构化类型却缺结构 | 不退回可能污染的扁平 content，保守不交正文。 |
| **没有结构、没有可靠标记 / 内部类型的裸工具结果** | **无法与正常正文可靠区分，仍不能排除。** 各导入器 sourceMetadata 未保留可通用恢复的正文 / 工具边界；不凭 provider 名整窗删，不用宽泛正则猜，也不重导真人数据。 |

测试 `CatalogImportedOriginalTests` 共 8 项，另覆盖旧索引与当前结构不一致、坏结构、原生语音正文、已知遗留标记及无法恢复的裸文本边界。没有把“所有旧扁平工具日志已排除”作为结论。

### 8.2 停止传播：同一 CatalogCancel 贯穿检索和快照

- **根因**：原三路中的 detached 工作和 GCD continuation 不继承外层停止；Session/Agent 只能等整次检索结束后检查。
- **修法与文件**：
  - `CatalogSorter.swift:105-129,330-350`：复用 CatalogCancel，Task 取消 handler 桥到同一 token；快照向量补算也接入，不保存取消批次的部分向量。
  - `CatalogRetrieval.swift:63-169`：OriginalSearch 第三参数传同一 token；detached 三路、建词袋 / BM25 / 排序及回执之间检查，取消结果不融合、不登记来源。
  - `SearchService.swift:176-300`、`Search/SearchIndexStore.swift:337-370`：GCD 等待桥接取消，逐词扫描、窗口批次、当前节点及 SQLite 结果行检查；取消错误不进入扫描 fallback。C3 正文已改取当前节点结构，清掉不再有调用的索引 `bodies` 新增取消参数，搜索框原 `bodies(nodeIds:)` 保持原样。
  - `CatalogALineReader.swift:75-144`、`SessionSummaryStore.swift:78`、`RecallTool.swift:444`：逐文件 / 窗口 / 段及建词袋之间检查。
  - `MemoryService.swift:520,578,692,1061,1085`：共享 BM25、碎片检索、向量排名、补算和写回的可选 token；其他消费者默认语义不变，不造第二取消器或重试队列。
  - `CatalogAgent.swift:284-300,451-464`、`CatalogWriter.swift:488`、`CatalogRunner.swift:250,680-710`：手动 / 自动 / 既有 seed 传同一停止；Runner 的生产 start 流程以 job 入口复用，取消后按同一路径释放楼层锁。
- **行为验证**：`CatalogRetrievalCancellationTests.swift:49-196` 的 8 测覆盖首文档编码中停止后不编码下一份、不写部分向量；原生 Task.cancel 抵达 detached 查询；原文提供方取消后返回值不融合；存在匹配正文时已取消的 emoji 查询不继续扫描回退；Agent.stop / Task.cancel 不发下一模型请求；Runner.stop / Task.cancel 使同楼层等待会话取得锁，无后续模型、写回或提案。阻塞点用受控 embedder、信号量及 expectation，不用 sleep 猜时序。
- **不可抢占边界**：已进入的单次 SwiftData fetch、SQLite step、整文件读取 / 解析、同步 embed 无法被 token 强抢；返回后检查，不开始下一文件 / 文档 / 批次。没有声称可中断一个已经运行的模型编码。

### 8.3 出处加载和点击双重核验，不把删除误报为支线

- **根因**：旧 `messageTarget` 只看 cite 字段齐全；点击只 fetch 窗口。不在主线的已删 node 会落入既有导航的“切支线”提示。
- **修法**：`WikiProposalDisplay.swift:97-146` 新增当前存储的可见性校验，检查窗口未 trash，节点真实存在、同楼层同窗口、未 trash / hidden / synthetic、角色和显示内容有效。后台加载只返回可定位目标值集合；点击用新 context 再 fetch，失效直接返回，绝不调用通用导航。`MemoryPalace/Views/WikiProposalViews.swift:225,476-505,522-528,605-621` 用此集合显示箭头，失败立即去掉箭头并显示「原消息已删除 / 不可定位」。只换分支但 node 还在，继续交既有导航；不改通用导航语义或旧 A 线概览。
- **实际导航验证**：`WikiProposalCitationLivenessTests.swift:66-181` 共 6 测，在加载前和加载后点击前分别做 node 软 / 彻底删、窗口 trash / 彻底删、错楼层 / 窗口、hidden / uiSystem / synthetic、不可见角色 / 空正文。观察真实 VM：失效不改 selectedConversation / highlight / scroll / loading / 原提示；有效主线定位并高亮；换分支仍定位原 node，只有这种有效支线显示既有提示，持久分支选择不变。未启动设备，不冒充像素 / 手指点击验收。

### 8.4 跨来源共享 BM25 的独立预期与实际前十条

- **原缺口**：三个来源全是同一 `solarship` 只能验证去重 / 权重，不能区分共享语料和各路独立计算。
- **新样本**：`CatalogSharedCorpusTests.swift:19-85` 构造 8 条原文、4 段真实 A2 文件、6 条碎片。查询 `quartz zephyr`；各文档词频、长度、两个查询词的来源分布不同。走真实 `CatalogWriter.material` / 检索 / Writer，断言实际 caller 收到的十个正文标记及顺序，并引用真实 A2 段，不只检查辅助打分函数。
- **预期来源**：隔离安装并运行独立 [bm25s 0.2.14](https://pypi.org/project/bm25s/0.2.14/)，使用 `BM25(method=\"lucene\", k1=1.2, b=0.75, dtype=\"float64\")`、预分词列表、query `[\"quartz\", \"zephyr\"]`，分别建共享索引及分来源索引，再按 plan 的 1.2 / 1.1 / 1.0 加权、稳定排序。测试冻结该外部运行的顺序，不抄 MemoryBM25 公式，不在测试运行时引入 Python / 包依赖。
- **共享预期及实际写手输入**：`alinethree, alinetwo, alineone, fragmentone, alinefour, rawone, rawsix, rawfour, raweight, fragmenttwo`。
- **分路独立语料的反例顺序**：`fragmentone, alinefour, alinethree, alinetwo, fragmenttwo, fragmentsix, fragmentfive, fragmentthree, fragmentfour, alineone`。新测试会拒绝该结果，不是与正确实现同分的样本。
- 首轮本项的 1 个失败是测试只按空白拆正文标记，没识别紧贴 A 线章节标签的正文；改为 ASCII 词边界后，十项预期数组与断言未改。生产排序公式未改。

### 8.5 最终构建、套件与运行证据

- 只用守则指定 build / runtests 脚本；新增 Swift 文件先 `xcodegen generate`。
- mac：`sol-p1-fix1-final-mac-build-2.log`，`** TEST BUILD SUCCEEDED **`。
- iOS：`sol-p1-fix1-final-ios-build-2.log`，`** TEST BUILD SUCCEEDED **`；仅具体 Simulator destination 编译，未启动模拟器。
- 最终：`sol-p1-fix1-final-tests-2.log`，**41 套、498 tests、0 failures**，`** TEST EXECUTE SUCCEEDED **`。清理无调用的 `bodies` 取消参数后双端重编、同套件复验；既有断言未放松，仅迁 OriginalSearch 的 token 参数。两组金样文件未改、未 RECORD，原样通过。
- 实际生产路径仍通过：daily / now / topic 各生成 1 份带《云桥城》原文 node cite 的提案；索引和扫描正文均 26 字；两条本机假 provider 兼容链各 2 轮交回原文 cite；宽主题实际 user 1664 字、手动反馈 1548 字、搜索正文均 1146 字。新异质语料实际前十条日志与 §8.4 一致；停止与导航的实际状态见上两节。

```text
Test Suite 'BranchSelectionTests' passed at 2026-10-19 00:18:33.297.
Test Suite 'CatalogALineReaderTests' passed at 2026-10-19 00:18:33.369.
Test Suite 'CatalogAgentTests' passed at 2026-10-19 00:18:35.897.
Test Suite 'CatalogImportedOriginalTests' passed at 2026-10-19 00:18:36.063.
Test Suite 'CatalogInjectionTests' passed at 2026-10-19 00:18:36.079.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-19 00:18:36.263.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-19 00:18:36.747.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-19 00:18:36.930.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-19 00:18:37.097.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-19 00:18:37.263.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-19 00:18:37.880.
Test Suite 'CatalogScheduleTests' passed at 2026-10-19 00:18:38.294.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-19 00:18:38.297.
Test Suite 'CatalogSeedTests' passed at 2026-10-19 00:18:38.618.
Test Suite 'CatalogSettingsTests' passed at 2026-10-19 00:18:38.626.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-19 00:18:38.647.
Test Suite 'CatalogSorterTests' passed at 2026-10-19 00:18:38.971.
Test Suite 'CatalogWriterTests' passed at 2026-10-19 00:18:39.563.
Test Suite 'ChatGPTPayloadBuilderTests' passed at 2026-10-19 00:18:39.574.
Test Suite 'ClaudeImporterSegmentsTests' passed at 2026-10-19 00:18:39.580.
Test Suite 'InspectorRealPathTests' passed at 2026-10-19 00:19:15.700.
Test Suite 'KelivoImportTests' passed at 2026-10-19 00:19:15.743.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-19 00:19:15.763.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-19 00:19:15.769.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-19 00:19:17.949.
Test Suite 'RecallToolTests' passed at 2026-10-19 00:19:17.974.
Test Suite 'RecallVisibilityTests' passed at 2026-10-19 00:19:17.999.
Test Suite 'RecallWindowSummaryTests' passed at 2026-10-19 00:19:18.013.
Test Suite 'RecallYesterdayTests' passed at 2026-10-19 00:19:18.065.
Test Suite 'RikkaHubMessageMapperTests' passed at 2026-10-19 00:19:18.082.
Test Suite 'RikkaHubPayloadBuilderTests' passed at 2026-10-19 00:19:18.124.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-19 00:19:18.180.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-19 00:19:18.230.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-19 00:19:18.418.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-19 00:19:18.421.
Test Suite 'SessionSummaryTests' passed at 2026-10-19 00:19:18.452.
Test Suite 'TimelineStoreV2Tests' passed at 2026-10-19 00:19:18.543.
Test Suite 'WikiProposalCitationLivenessTests' passed at 2026-10-19 00:19:18.686.
Test Suite 'WikiProposalDisplayTests' passed at 2026-10-19 00:19:18.697.
Test Suite 'WikiProposalTests' passed at 2026-10-19 00:19:19.115.
Test Suite 'WindowSummaryReadTests' passed at 2026-10-19 00:19:19.131.
Executed 498 tests, with 0 failures (0 unexpected) in 45.856 (45.955) seconds
** TEST EXECUTE SUCCEEDED **
```

### 8.6 边界 / 交接

- 已修复四条，未提前推进 P2+；未改搜索框、导入结果或索引内容，未重导 / 重建用户数据。明确无法恢复的裸工具边界保留为数据事实限制，不宣传全格式过滤。
- 协作式取消有单次 atomic 操作边界；设备 UI 外观 / 手指点击、真端点、真实 Apple 模型资产均未运行。本次验证是临时数据上的实际应用调用与状态，不替代上述真人验收。
- CodeGraph 仍指主仓；sourcekit-lsp references 返回空，按本工位生产调用清单接线。NOW.md 仍为已知旧戳，未改；状态写本工位 docs/now。本返工未提交，交车头提交。

