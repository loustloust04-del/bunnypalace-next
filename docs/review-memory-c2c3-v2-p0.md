# C2/C3 v2 · P0 复盘

对应 `plan-memory-c2c3-v2.md` 第 1 段第 1–8 条；只做 P0。按实现单不提交、不操作真实数据、不运行真实模型或设备。

## 1. 边界情况

- 原料域：10-01 起、`reviewedAt != nil`、未删除的 C2 碎片。自动发现另排整理过、整理驳回、待批占用；手动检索保留整理状态。旧原子档案、画像、未留碎片不混入。
- A 线候选保留层、窗口、日期、段号和消息范围；按楼层未删除窗口集合过滤后做 BM25。日期采用半开区间；旧累计摘要的零时长按时间点处理，第 0 段及旧抄本仍可读取。
- 查询只算一次向量；同 UUID 不重复算分，排序后按原快照映射 f 号。旧 revision 不参与当前向量比对；缺失/过期补算仅处理当前楼层合格候选。
- C3 补算不依赖 `mem_inject_vector`，不改变该开关控制聊天注入的含义，不触发图边扫描。`Memory` 在所属 context 转值快照；补算后在新 context 逐条核对原正文、原楼层及当前资格，批量显式保存，再重新读取当前合格快照。聊天回填复用同一写回核对。
- Apple 模型未就绪、查询编码失败或候选全部缺有效向量记录「向量不可用」，部分缺失另报未算出条数，不冒充正常零命中。沿用已有 tokenizer 的至少双字符词面口径、向量阈值和 topK。
- `.runs` 搜回正文与直接分配碎片分别记录。自动与手动均从结构化回执区间统计实际提供的正文；不计标题、日期、章节标签、工具说明、未命中提示及截掉的尾部。工具字数预算仍计完整回执。
- 默认模板只换虚构例子；提取规则、120 字拒收、自定义模板覆盖语义不变。旧 `.runs` 不回填，不改旧提案或 wiki。

## 2. 与下一模块交互的风险

- P1 尚未接 SearchIndexStore 聊天原文、来源权重及完整四层筛选。P0 已恢复旧数值的基本限量，按共用 RRF 的合并相关度顺序取料；当前 A 线仅 BM25，不建向量库。
- 自动和手动共用 `CatalogRetrieval`；`search_aline(terms,after,before)` 广搜 A 线及已留碎片，`search_fragments(terms)` 定向追搜。参数合同不变，结果明示来源、状态及原 f 号。
- `CatalogALineReader` 只读候选/窗口/段，旧 ALineSearch 的 search/searchSync/firstMatch 和子串模式全部退役，不保留别名或双跑。
- P3 审批/自动分拣行为未动；旧 seed 逐主题机制仅迁用新检索和可见窗口约束，清种子与新 seed agent 仍在第 6 段。
- 来源登记和工具回执截断的既有差异仍按 plan 的 P1/P6 收口；本段只让统计不登记未见正文为已检索字数，不宣称已完成全来源语义校验。
- 真实 Apple 资产向量命中、官方端点输出质量、Air 可视化由车头验收；本单的假 embedder 只证明向量结果进入真实写手调用路径，不冒充真资产或真模型验收。

## 3. 技术债务与验证

- 未增加临时检索开关、第二套 BM25、第二套索引、同义词模型或 reranker。没有重提取旧碎片或改 subject/speaker/审批。
- 确定性行为验证覆盖组合标题 A2/A4、日期/楼层/已删窗口、旧格式和第 0 段、已留原料域、UUID/f 号、revision、不可用/零命中、无关负例及向量无共同词命中进入写手。
- 通过临时文件与内存 SwiftData 跑实际 `CatalogSession.daily`、`organizeNow`、`organizeTopic` → Writer/Agent → 提案出处及 `.runs`。观察：daily 搜回正文 32 字/直接分配 36 字，topic 68/0，now 68/36；三种路径均实际给到 A2/A4，出处为 A2 第 1 段消息 4..<9。
- 基线：16 套件、308 测试通过，mac `TEST BUILD SUCCEEDED`；两组金样原样通过，未 RECORD。
- 最终：22 套件、353 测试、0 failures，`TEST EXECUTE SUCCEEDED`；mac、iOS Simulator 应用、iOS 测试包均 `TEST BUILD SUCCEEDED`。两组金样原样通过，未 RECORD。首轮两处旧用例已适配：删除未命中措辞断言，seed 文件夹夹具补当前楼层可见 Conversation。
  - 日志：scratchpad `sol-p0-baseline-build.log` / `sol-p0-baseline-tests.log`；最终 `sol-p0-final-mac-build-4.log` / `sol-p0-final-ios-build-2.log` / `sol-p0-ios-tests-build-2.log` / `sol-p0-final-tests-2.log`。
  - `build.sh … ios` 只构建应用，额外用同脚本 `C3_TEST_PLATFORM=mask` 分支只编 iOS 测试包以覆盖 CatalogLiveSmokeTests；没有安装、启动或执行真机测试。
- CodeGraph 指向主仓而非当前 worktree，实际以当前文件为准。sourcekit-lsp 无工作区语义服务，references 返回空/不可用，已报告工具问题并用现有调用清单完成迁移。

## 4. P0 fix1：现在整理混合归组回归

- 车头在 `f83dc0404` 的官方端点运行返回：f1 用 `new` 声明「电影观影计划」，f2/f3 用 `page` 引用同一路径。已打码 live `.runs` 解码显示输入 3 条、topics=0、staged=1、unassigned=2；不是 `reviewedAt` 过滤丢了碎片。
- 根因：该版本 `CatalogSorter.swift:604` 的 page 校验只认磁盘已有页或上轮 staged，不认同批 new 声明。f2/f3 被丢后只剩 f1，未达三条门槛；`CatalogRunner.swift:512-522` 遍历空 topics，因此没有 agent 请求或提案。此 guard 的历史归属为 `4976129053`；不能把 P0 前单次 4/4 成功等同于混合形状已受支持。
- 修复：`CatalogSorter.swift:567-578,606-618` 先筛有效且首次出现的 f 编号，收集同批合法 new 声明，再归组。page 可引用本批声明，声明在后也不丢标题/类别/别名；未知编号、忽略的重复声明不能授权新路径。三条开页门槛、已有页、上轮 staged 和审批不变。
- 原样重放 live 的三条模拟碎片、两个 A3/A4 窗口和分拣 JSON，以假 caller/backend 走实际 `organizeNow`：
  - 修前：`eligible=3, topics=0, staged=1, unassigned=2, agentRequests=0, proposals=0`。
  - 修后：`eligible=3, topics=1, staged=0, unassigned=0, agentRequests=2, proposals=1`；全部分配碎片进入开场，实际工具回执含 A 线正文，提案关联原三条 UUID 与窗口出处。
- 新增回归：`CatalogRetrievalTests.testOrganizeNowContinuesAfterLiveMixedNewAndPageAssignments`；`CatalogSorterTests` 覆盖声明前后顺序、元数据、三条门槛，以及未知/重复声明不能放行路径。`MemoryRetrievalTests` 补查询编码失败记不可用、后续显式查询可恢复且不内部重试。
- 验证：修前 2 个新回归实际失败；修后 22 套件 357 测试、0 failures，mac 与 iOS Simulator build-for-testing 均成功。两组金样原样通过，未 RECORD；live 测试断言未改、未跑官方端点或设备。本返工未提交。
- 日志：scratchpad `sol-fix1-before-mac-build.log`、`sol-fix1-before-tests.log`、`sol-fix1-after-mac-build.log`、`sol-fix1-ios-build.log`、`sol-fix1-after-tests.log`。

## 5. P0 fix1：首次向量查询失败的证据边界

- 已确认的现象：车头 `step3-live-tests.log:51-64` 首个 daily 用例出现四次 Apple MIL 加载/建缓存目录 `Operation not permitted`，目标是 `/var/db/com.apple.naturallanguaged/...e5bundlecache`；daily 的 query embed 返回 nil，记录「向量不可用（查询编码失败）」。同进程后续 topic 已命中 3 条（该日志 `101-103`）。这证明该次运行发生加载链故障后恢复，不证明每次冷启动都失败。
- `MemoryEmbedding.swift:49,74-89` 的 isReady 仅看 `hasAvailableAssets`；真正模型加载可能失败。Apple 的 [hasAvailableAssets](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/hasavailableassets) 只承诺资产在设备上，[load()](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding/load()) 独立 throws，不承诺资产存在就一定能加载/推理。
- 不能归咎为本仓自定义测试 HOME 改道：iOS 的隔离仅建立临时数据目录并记录到静态 home（`Utils/TestHostIsolation.swift:101-130`）；HOME/XDG 改写只编在 mac 分支（`:135,247-256,310`），跨平台 swizzle 只替换 UserDefaults（`:312-321`）。iOS XCTest 注入同一个产品 App（`project.yml:481-497`），未有另一份 NL/系统缓存例外 entitlement。测试启动确实跳过产品初始化（`MemoryPalaceApp.swift:723-743`），但这不是普通 App 必现/不现的实证。
- 外部对照：[Apple Developer Forums 799951](https://developer.apple.com/forums/thread/799951) 有非 XCTest 的 Simulator/Playground 同缓存目录权限错误报告；这是开发者报告，不是 Apple 已确认诊断，也不是物理设备普通 App 证据。因此不能声称“只在测试宿主发生”。
- 现有行为已复用：没有专门 embedding 启动预热或重试队列；`requestAssetsIfNeeded` 只下载资产（`MemoryEmbedding.swift:53-67`）。`embed` 仅在 load 成功后置 loaded=true，失败返回 nil，下一次独立调用仍会尝试 load（`:79-89`）；C3 快照补算和查询已走这条路径（`CatalogSorter.swift:103-109`、`MemoryService.swift:1011-1024,574-575`）。第一次 query 失败已按 plan 写不可用，BM25 仍可返回，不算向量零命中。
- 本返工不改向量生产代码、不加预热或重试队列；新增确定性测试证明单次查询失败记不可用、不内部重试，下一次独立查询成功后可返回向量命中。假 embedder 不用于证明 Apple 模型冷启动原因。
- 尚缺的唯一实证：同一设备上、非 XCTest 正常启动 App 后首次 C3 的 NL 加载 trace，才能判断物理设备普通 App 是否也出现该权限问题。本单禁止设备操作，未做这项；交车头保留系统加载错误和向量状态即可，不需要导出真人正文。不能把此项写成已确认的“测试专有”或“普通 App 必现”。

## 6. P0 fix2：astra 四项全收

### 6.1 边界与根因

1. **旧向量写回**：首版 C3 把编码前 context 内的 Memory 直接写回；聊天回填也只核对 UUID。现在 `MemoryRetrievalDocument` 带原楼层，`MemoryEmbeddingBackfill.persist` 新建批次 context，逐条重新 fetch，原正文、原楼层、当前资格均相符才赋值，最后一次显式保存。C3 用 `CatalogMaterial.isEligible`；聊天只查存活，不强加 C3 的审核/日期门槛。C3 返回再次读取的当前合格快照。
2. **搜索原料失去上限**：`166b450ad:MemoryPalace/Services/Wiki/ALineSearch.swift:8-13` 的原值是 A4=10、A3=5、A2=8、正文 chars=6000。`CatalogRetrieval.Result` 复用现有泛型 RRF 合并 A 线 BM25 名次与碎片融合名次，再按层条数、总条数 10+5+8 和字符预算取前面的；不按 A4→A3→A2→碎片塞满。6000 现在约束完整搜索回执（含说明），比旧正文预算保守。自动写手和手动工具发送同一回执，不再自动拼出无界全文。分拣直接分配的碎片、楼层 prompt、已有 wiki 页不是搜索回执，本次不另截它们；旧种子全文原料不动。
3. **文档编码失败被说成零命中**：`fill` 返回 documents、failedCount、validVectorCount，按唯一 UUID 计数；检索以当前 revision 的有效向量覆盖量区分全部不可用、部分不可用和真实零命中。查询仅编码一次，文档失败仍保留 BM25 结果，没有内部重试。
4. **标题/说明误计正文**：移除 `append(_:bodies:)` 的 `range(of:)` 反查；reader 产出正文/元数据 parts，receipt 拼接时直接记 Character 区间，prefix 只保留可见区间。A2/A3 的标题、经过/原话/待续标签及 A4 的「待续：」均不算正文。自动、手动、全文读窗口/段共用定义；目录只数实际给出的 gist，不把省略号或未给出的段全文算进去。

### 6.2 与后段交互、债务

- 不接原文索引、来源权重、P1 完整四层筛选、重试队列或审批改动；旧 ALineSearch 不恢复，数字留在薄适配的 Limits。
- 搜索预算与整次请求预算不是同一件事：空楼层/空 wiki 夹具中实际自动 user 为 6116 字，其中搜索回执 6000 字；手动工具反馈 6000 字，实际正文 5448 字。楼层 prompt、已有页及直接分配碎片仍沿既有入口；每次工具累计 40000 字和轮数闸不改。
- 入选 A 线的限量前全文仅留 `.runs` 取证，模型只收到限量回执；既有运行记录完整原始请求/输出断言保留。原累计工具预算测试只加长合成正文以继续撞到 6000 字，轮数/封顶断言未放松。
- 手动 read_window/read_segment 及累计工具预算的来源登记仍有原有 P1 语义收口项，不宣称完成全来源/语义验真。Apple MIL 冷启动的真实 App 对照边界仍见 §5，本单不跑端点或设备。

### 6.3 回归

- `MemoryEmbeddingBackfillTests`：编码期间另一 context 改正文，旧向量不落库；移楼、彻底删、撤销审核、软删除、改早日期/移出碎片域均跳过；聊天旧档案仍能写当前向量；文档全失败/部分失败而查询成功，词面命中保留，调用次数无重试。
- `CatalogRetrievalBudgetTests`：宽主题 40 条长 A4 + 30 条词面碎片，高分 A2 及排在原快照末尾、无共同关键词的向量碎片 f31 进入实际自动/手动写手并能被提案引用；旧 10/5/8、合计 23 条与 6000 字边界；查询与正文相同、长标题使回执只剩说明时自动/手动统计均为 0。
- `CatalogSearchReceiptTests` 与 reader 新回归：查询/标题/正文重名、章节标签重名、Unicode Character 截断、合并区间、跨层顺序、全文/目录 gist、旧第 0 段、旧 A3 抄本正文定义。
- 最终：25 套件 375 测试、0 failures；两组金样原样通过、未 RECORD。mac 与 iOS Simulator 应用均 `TEST BUILD SUCCEEDED`。日志 `sol-fix2-final-tests.log`、`sol-fix2-final-mac-build.log`、`sol-fix2-final-ios-build.log`。首轮集成也为 375/0；首轮新测试 flatMap 类型推断编译错误已补显式类型，不涉及生产逻辑或放松断言。
- 实际隔离路径：daily 搜回正文 22 字/直接分配 36 字，topic 58/0，now 58/36；均给到 A2/A4、出处为 A2 第 1 段消息 4..<9。fix1 混合 new/page 回归仍为 3 条 → 1 主题 → 2 次 agent → 1 提案。新宽主题实际输入见 §6.2。全程未提交、未运行端点或设备、未接触真实数据。

## 7. 中文专名被共享分词清空（基于 bf3c8f7bf）

### 7.1 根因与修前证据

- mac 宿主实际走 `CatalogRetrieval.search` → 碎片 BM25，关闭向量：单条「云桥城地图画好了」、同条加 keywords=["云桥城"]、混入无关碎片均返回 0 条。恢复 `CatalogDirectionTests.testManualTopicCoveredOnlyLinksTheReadPage` 的云桥城样例后，covered 提案也为空。`sol-tokenizer-before-tests.log:117,120` 打印 query=[]、body=["地图"]、scores=[0.0]、hits=0；三个行为用例共 7 处失败断言，原英文 BM25 控制用例通过。
- `bf3c8f7bf:MemoryPalace/Services/MemoryService.swift:503-513` 以 NLTokenizer.word 分词后丢掉不足 2 字的词；`:522-523` 遇空查询直接返回全 0。专名的查询词被这条链清空，正文亦只留下「地图」。没有另一个停用词表。
- 不是单文档 IDF 问题：原 `:541` 用 `log(1 + (n-d+0.5)/(d+0.5))`，n=d=1 时为 log(4/3)>0。本次不改公式，也不改原 `:591` 的 score>0 命中条件。
- keywords 原本确实进索引：原 `:515-518` 把小写原词加入两份，`:587-589` 碎片召回调用该函数。但 query 已空，keywords 无法挽救；而直接塞原词与查询分词本身也不同口径。

### 7.2 修法、影响和边界

- `MemoryService.swift:503-539`：连续汉字确定性地切相邻双字 token；正文、查询、keywords 均走同一函数。单字不成 token，空格/标点断开，不跨它们拼字。非汉字仍走原 NLTokenizer.word / 小写 / 至少 2 字规则；纯汉字无须创建 NLTokenizer。keywords 切词后仍加入两份，保留 P0 的关键词加权设计。
- 不加同义词、reranker 或第二套索引。汉字双字片段属于宽词面召回，不宣称完整短语精确匹配；仅含「云」「桥」「城」或把这些字隔开的输入不算「云桥城」命中。
- 第 2 段统一候选 BM25 → 原文1.2/A线1.1/碎片1.0 → 10条/正文6000字 → 写手判断的代码与常量不改（`CatalogRetrieval.swift:73-95`）。其统一重排仍按正文评分；keywords 的两份加权位于原碎片召回路，不偷偷改成来源加权。
- 主聊天 Recall L1、注入关键词检索、缺关键词时的词面兜底同用该内核，中文词面命中/名次会随修复变化，不宣称它们零影响；原文 exact 分支不变。C3 A 线、原文扫描排序与 catalogTerms 也复用修正后的词面口径。
- 搜索框不走该 C3 查询扩展：`SearchService.swift:176-204` 是独立 catalogContent 路，搜索框走 `:299-318` 的 performSearch/searchConversationBuckets；FTS 的 segment/ftsQuery 和索引格式均不改，无需重建索引。

### 7.3 行为回归与实际路径

- 临时诊断直接观察到原 NLTokenizer 输出 `["云","桥","城"]`（`sol-tokenizer-focused-tests.log:163,165`），全被旧的至少 2 字规则丢掉。修后查询为 `["云桥","桥城"]`，正文也有这两个 token；单文档分数为 0.5753641449035617，加 keywords 后为 0.9041436562770256，实际 C3 均只返回目标 1 条。诊断代码和 NaturalLanguage 临时测试 import 已移除，保留行为断言。
- 新增 8 个行为用例：C3 单碎片（含内嵌位置及有/无 keywords）、多碎片单字/非相邻负例、仅关键词命中、A2/A4 同源分词；单/少文档公共词 IDF>0、关键词实际召回加权；实际 RecallTool.execute 中文命中而 exact 仍只查原文；C3 原文索引/扫描与搜索框 recent/oldest 的确定顺序。
- 恢复 `CatalogDirectionTests.testManualTopicCoveredOnlyLinksTheReadPage` 为「云桥城地图画好了」；仍要求实际 read_wiki + search_fragments 后出现 confirmCovered、审批前不打标、审批后页原文不改且碎片归到正确页，没有改松断言。
- 删除受影响旧测试里直接钉 document token 数组复制的断言，保留 BM25 命中/负例/短拉丁查询断言，并增加实际 KeywordRetriever 加权排序检查，不钉新版 token 文案。
- 首轮定向验证：7 套件 146 测试、0 failures，原失败的 C3/covered 用例转绿；两组金样原样通过、无 RECORD。日志 `sol-tokenizer-focused-tests.log`、`sol-tokenizer-after-mac-build.log`。
- 所有负例用禁用向量的 fake embedder 隔离词面行为；现有向量路径/阈值不动，不把真实语义向量可能返回的候选解释为词面零误报保证。

### 7.4 最终验证与交回

- 最终 39 套件、462 测试、0 failures，含全部 Catalog*/Recall*/Search*、两组金样及受影响的记忆检索/注入套件。8 个新行为用例和恢复后的 covered 用例均通过。两组金样原样，未 RECORD；未做 git 写操作，改动留工作区。
- mac `sol-tokenizer-final-mac-build-2.log`、iOS Simulator `sol-tokenizer-ios-build.log` 均 `** TEST BUILD SUCCEEDED **`；只编 iOS 应用，不安装/启动设备。最终套件原始日志 `sol-tokenizer-final-tests-2.log`（补齐新增 Recall 测试 MainActor 隔离后，完整 39 套再次通过）。
- `SearchIndexRealStorePerfTests` 通过现有 `TEST_RUNNER_S5_REAL_STORE` 环境注入，输入为本单生成的 32 条虚构 SQLite 数据（scratchpad `sol-tokenizer-synthetic.store`），不是私人真库。宿主环境已在定向日志确认，最终输出 nodes=32、3 个 synthetic profile；这是回填/查询烟测，不作真库性能结论。临时 SQL 脚本和诊断代码已清理，合成数据库仅作本地验证产物，不进仓库。
- 主聊天不是“零变化”：Recall L1 与 KeywordRetriever 同修，keywords 改成共用分词也可能改变多词关键词的匹配/名次。实际 `RecallTool.execute` 已验证中文碎片能回忆、单字不混入，exact 仍只查原文；搜索框同一中文 corpus 在索引/扫描两路均保持 recent=[新,旧]、oldest=[旧,新]。主聊天可见窗口/日期/楼层/失效过滤相关套件仍通过。

构建输出：

```text
mac: ** TEST BUILD SUCCEEDED **
iOS: ** TEST BUILD SUCCEEDED **
```

最终各套件原始 passed 行：

```text
Test Suite 'CatalogALineReaderTests' passed at 2026-10-22 01:35:20.975.
Test Suite 'CatalogAgentTests' passed at 2026-10-22 01:35:24.863.
Test Suite 'CatalogDirectionTests' passed at 2026-10-22 01:35:25.512.
Test Suite 'CatalogImportedOriginalTests' passed at 2026-10-22 01:35:25.662.
Test Suite 'CatalogInjectionTests' passed at 2026-10-22 01:35:25.676.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-22 01:35:25.812.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-22 01:35:26.329.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-22 01:35:26.545.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-22 01:35:26.695.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-22 01:35:27.012.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-22 01:35:27.672.
Test Suite 'CatalogScheduleTests' passed at 2026-10-22 01:35:28.149.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-22 01:35:28.152.
Test Suite 'CatalogSeedTests' passed at 2026-10-22 01:35:28.468.
Test Suite 'CatalogSettingsTests' passed at 2026-10-22 01:35:28.477.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-22 01:35:28.495.
Test Suite 'CatalogSorterTests' passed at 2026-10-22 01:35:28.596.
Test Suite 'CatalogWriterTests' passed at 2026-10-22 01:35:29.162.
Test Suite 'InspectorRealPathTests' passed at 2026-10-22 01:36:06.601.
Test Suite 'MemoryComplexityTests' passed at 2026-10-22 01:36:06.615.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-22 01:36:06.639.
Test Suite 'MemoryFullPresenceTests' passed at 2026-10-22 01:36:06.672.
Test Suite 'MemoryInjectionMeterTests' passed at 2026-10-22 01:36:06.678.
Test Suite 'MemoryResidentTests' passed at 2026-10-22 01:36:07.147.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-22 01:36:07.158.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-22 01:36:09.386.
Test Suite 'RecallToolTests' passed at 2026-10-22 01:36:09.417.
Test Suite 'RecallViewerTests' passed at 2026-10-22 01:36:09.434.
Test Suite 'RecallVisibilityTests' passed at 2026-10-22 01:36:09.459.
Test Suite 'RecallWindowSummaryTests' passed at 2026-10-22 01:36:09.475.
Test Suite 'RecallYesterdayTests' passed at 2026-10-22 01:36:09.544.
Test Suite 'SearchIndexDidSaveProbeTests' passed at 2026-10-22 01:36:15.589.
Test Suite 'SearchIndexRealStorePerfTests' passed at 2026-10-22 01:36:15.604.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-22 01:36:15.704.
Test Suite 'SearchIndexerTests' passed at 2026-10-22 01:36:19.613.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-22 01:36:19.689.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-22 01:36:19.891.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-22 01:36:19.896.
Test Suite 'SearchTypingPredicateTests' passed at 2026-10-22 01:36:19.899.
Executed 462 tests, with 0 failures (0 unexpected) in 58.968 (59.076) seconds
** TEST EXECUTE SUCCEEDED **
```

- 新增的实际 Recall 与搜索框回归均在 MainActor 操作 setUp 创建的 ModelContext；检索入口只传 container/值，不把活 Memory 跨线程传下去。
- 日志还出现未改动的 `SearchServiceIndexPathTests.testEmptyScopeAndScopedConversations` 的 ModelContext 主队列警告（首轮完整日志 `sol-tokenizer-final-tests.log:8172`）；该用例断言通过。本单不顺手改旧 Search 测试的执行隔离。

### 7.5 Claude 审查返工（基于 5b4d38809；三版量化与验收）

本节覆盖上轮 §7.2 中的宽汉字 OR 口径；上轮 §7.4 的 passed/SUCCEEDED 不代表本轮通过。没有 git 写操作，没有修改第 6 段种子禁区文件。

#### 已写入工作区的修补

1. **P1-1，原文路恢复整段短语。** `SearchTextSegmenter.swift:44-81` 的 catalogTerms 保留连续汉字段，非汉字仍按原词法处理。`SearchIndexStore.catalogHits` 用这些整段构造 FTS 相邻字短语；SearchService 的扫描回退与可见正文复核原本就消费同一组 terms，因此同样只按整段子串通过，不再以「云桥 OR 桥城」放入只含「桥城」的原文。BM25 评分仍切双字。补上索引、扫描、旧索引候选的可见正文复核负例。
2. **P1-2，共享数据门槛。** `MemoryService.swift:542-590` 的 MemoryBM25.scores 以连续汉字段分组：3–6 字必须含齐全部双字，否则该组不贡献分数；7 字及以上仅在当前候选 n≥20 时删除 df/n>0.5 的查询双字，等于 0.5 保留，n<20 不删除。不同组仍为 OR，混排中的独立英文词可匹配，但未含齐的短汉字段不得顺带加分。碎片、A 线、Recall L1、KeywordRetriever 同用该函数，无停用词表。门槛约束词面分数，不改现有向量路线/阈值，也不删除零词面向量独有候选。
3. **P1-3，候选上限。** `SearchIndexStore.swift:335-379` 将 profile、删除、role、date、scope 条件放在 SQL 内，`ORDER BY bm25(fts), d.id LIMIT 300` 后才读取候选；scope 使用绑定参数。扫描每个连续汉字段只查询一次。搜索框的 hits/时间排序不改，测试同时要求其仍返回超过 300 条的全部合格结果。
4. **P2-2，NFKC。** `MemoryService.swift:503-539` 的 tokens 入口复用 `SearchTextSegmenter.normalized`，先 NFKC 再小写；正文、查询、keywords 同口径。补全角/半角字母、数字双向实际召回及半角/全角假名测试。
5. **P2-6，实际 Recall 与边界。** `RecallTool.execute` 新增可注入 defaults，进入后台前捕获 mem_master，默认值与生产原逻辑相同；RecallYesterdayTests 使用独立 suite 并清理，不再写 standard 的 mem_master。exact 用例插入真正含「云桥城」和独立标记的 MessageNode，要求返回该原文、无 L1 id/标记。另补 24 条高重要度常见词噪声不能挤掉旅行目标、张小明/小明负例、master 未设/关闭/开启边界。共享内核补「云桥城v2」「用Swift写」、两字词、3/6/7 字及 n=19/20、df=0.5/大于0.5 边界。
6. **P2-7，注释。** `MemoryService.swift:667-668` 改为共享双字评分与短段/长段门槛，不再声称完整关键词命中。MemoryInjector.matchesKeyword / hitScore 死代码保留，只在此记录，不删除。

新增/扩展的行为测试位于 `CatalogRetrievalTests.swift:106`、`RecallToolTests.swift:270-328`、`RecallYesterdayTests.swift:132-153,215-277`、`SearchIndexStoreTests.swift:73-120`、`SearchServiceIndexPathTests.swift:226`；SearchTextSegmenterTests 同步覆盖原文整段与混排术语。本轮完整 42 套件、482 测、0 failures；两组金样共 73 测原样通过，未 RECORD。

验收首轮暴露旧用例 `RecallVisibilityTests.testHitsCarryRetrieverAndScore`：查询「聊聊配色」只共享「配色」，不满足本轮 3–6 字全部双字门槛，keyword hit 为 0；旧断言随后强拆导致宿主崩溃（`sol-tokenizer-fix1-resume-tests.log:7759-7762`）。该用例检验命中元数据，不检验自然语言扩展；现用明确两字查询「配色」，保留恰好 1 条 keyword、非 nil 正分与 persistent 归因断言，改用 XCTUnwrap 避免断言失败再崩溃（`RecallVisibilityTests.swift:43-55`）。没有调低生产门槛或放松断言，完整套件修后重跑通过。

#### 三版比较：同语料、词面排序与 Recall 优先级

- e62b23fa4、5dd2335dd 均用只读 `git show` 提取原始 MemoryBM25（48 / 69 行），只改临时 enum 名；本轮直接调用生产 MemoryBM25。三版分别用自身 document/tokens/scores，无向量、无模型资产、keywords 均为空，不改 k1=1.2、b=0.75 或 IDF 公式。
- 三组文档都先放噪声、最后放唯一目标；score>0 计命中，分数降序、同分按输入顺序。随后调用当前生产 `RecallTool.weightByPriority`；噪声重要度 5、目标重要度 3，记录截取前 4 条之前的目标名次。这样隔离内核差异，不把历史版本的其他调度变化混进来。
- 城市：查询「云桥城」，30 条「桥城」＋目标「云桥城地图画好了，虚构桥梁按颜色编号」。
- 姓名：查询「张小明」，30 条「小明」＋目标「张小明在虚构工坊修好了折叠望远镜」。
- 旅行：查询「上次说的旅行计划」，40 条「上次说的颜色记录」＋目标「旅行计划定在虚构海湾，先乘纸帆船再看星图」。

| 语料（总条数） | 内核 | 正分命中数 | 目标 BM25 名次 | 目标 Recall 名次 | 进入 Recall 前 4 |
| --- | --- | ---: | ---: | ---: | --- |
| 城市（31） | e62b23fa4 | 0 | 未命中 | 未命中 | 否 |
| 城市（31） | 5dd2335dd | 31 | 1 | 13 | 否 |
| 城市（31） | 本轮 | 1 | 1 | 1 | 是 |
| 姓名（31） | e62b23fa4 | 31 | 31 | 31 | 否 |
| 姓名（31） | 5dd2335dd | 31 | 1 | 13 | 否 |
| 姓名（31） | 本轮 | 1 | 1 | 1 | 是 |
| 旅行（41） | e62b23fa4 | 41 | 1 | 13 | 否 |
| 旅行（41） | 5dd2335dd | 41 | 1 | 13 | 否 |
| 旅行（41） | 本轮 | 1 | 1 | 1 | 是 |

实测日志 `scratchpad/sol-tokenizer-fix1-three-kernels.log:107-115`；临时量化烟测 `TokenizerKernelComparisonTests` passed，`** TEST EXECUTE SUCCEEDED **`。本轮三组都只剩目标，旧有噪声按重要度越过目标的问题在此合成语料中消失；不是对真实语料或向量召回的零误报保证。量化结束已删除历史内核副本及临时测试，重新 xcodegen，不留第二/第三套生产内核。

平均文档 token 长度（e62 → 5dd → 本轮）：城市 0.1613 → 1.4516 → 1.4516，姓名 1.1613 → 1.4516 → 1.4516，旅行 3.0488 → 7.2439 → 7.2439。可见旧分词清空专名与新双字长度的差异；本轮未再改变这组纯汉字文档长度。此处 keywords 为空，不能据此推断 keywords 双份计长的净排序效果，P2-3 仍按裁定只观察。

#### 本轮构建与套件原始结果

- 开始先 xcodegen，`sol-tokenizer-fix1-resume-mac-build.log`、`sol-tokenizer-fix1-resume-ios-build.log` 均 `** TEST BUILD SUCCEEDED **`；测试夹具迁移和临时量化器加入后，`sol-tokenizer-fix1-resume-measure-build.log` 再次 `** TEST BUILD SUCCEEDED **`。只走守则脚本，无私有 DerivedData、无设备启动/安装。
- 前次种子编译阻塞记录在 `sol-tokenizer-fix1-measure-build.log:796-801,879`；这次种子方已修复，本单未修改种子禁区文件。首轮完整测试金样已经通过，但元数据旧夹具失败，不把那次部分 passed 当整体成功；以下只引用迁移后完整重跑的日志。
- `sol-tokenizer-fix1-resume-tests-2.log:137-8072`：42 套件、482 测、0 failures；Catalog*/Recall*/Search*，另含 6 个受影响记忆检索/注入套件、两组金样。SearchQueryMappingTests / SearchKindSelectionTests 同跑；CatalogSeedTaskTests 只运行、不修改。
- `SearchIndexRealStorePerfTests` 显式注入 `TEST_RUNNER_S5_REAL_STORE=.../scratchpad/sol-tokenizer-synthetic.store`，实际 nodes=32、3 个 synthetic profile（日志 :7870-7873），不读默认私人库。这是合成回填/查询烟测，不作真库性能结论。
- 实际 RecallTool.execute 验证原文 exact 找到含「云桥城」的消息且不带 L1，默认/关闭/开启 master 边界、姓名后缀负例和高重要度噪声过滤；Search 索引/扫描两路验证整段短语、当前可见正文、300 条上限先过滤、搜索框 recent/oldest 及超过 300 条结果不变。没有靠改金样、改权重或下调阈值取绿。

```text
Test Suite 'CatalogALineReaderTests' passed at 2026-10-22 02:41:43.124.
Test Suite 'CatalogAgentTests' passed at 2026-10-22 02:41:46.536.
Test Suite 'CatalogDirectionTests' passed at 2026-10-22 02:41:47.052.
Test Suite 'CatalogImportedOriginalTests' passed at 2026-10-22 02:41:47.203.
Test Suite 'CatalogInjectionTests' passed at 2026-10-22 02:41:47.218.
Test Suite 'CatalogJSONRepairTests' passed at 2026-10-22 02:41:47.352.
Test Suite 'CatalogOriginalRetrievalTests' passed at 2026-10-22 02:41:47.819.
Test Suite 'CatalogRetrievalBudgetTests' passed at 2026-10-22 02:41:48.019.
Test Suite 'CatalogRetrievalCancellationTests' passed at 2026-10-22 02:41:48.152.
Test Suite 'CatalogRetrievalTests' passed at 2026-10-22 02:41:48.470.
Test Suite 'CatalogRunRecordTests' passed at 2026-10-22 02:41:49.087.
Test Suite 'CatalogScheduleTests' passed at 2026-10-22 02:41:49.149.
Test Suite 'CatalogSearchReceiptTests' passed at 2026-10-22 02:41:49.159.
Test Suite 'CatalogSeedTaskTests' passed at 2026-10-22 02:41:49.569.
Test Suite 'CatalogSeedTests' passed at 2026-10-22 02:41:49.719.
Test Suite 'CatalogSettingsTests' passed at 2026-10-22 02:41:49.730.
Test Suite 'CatalogSharedCorpusTests' passed at 2026-10-22 02:41:49.752.
Test Suite 'CatalogSorterTests' passed at 2026-10-22 02:41:49.852.
Test Suite 'CatalogWriterTests' passed at 2026-10-22 02:41:50.436.
Test Suite 'InspectorRealPathTests' passed at 2026-10-22 02:42:26.318.
Test Suite 'MemoryComplexityTests' passed at 2026-10-22 02:42:26.328.
Test Suite 'MemoryEmbeddingBackfillTests' passed at 2026-10-22 02:42:26.349.
Test Suite 'MemoryFullPresenceTests' passed at 2026-10-22 02:42:26.377.
Test Suite 'MemoryInjectionMeterTests' passed at 2026-10-22 02:42:26.382.
Test Suite 'MemoryResidentTests' passed at 2026-10-22 02:42:26.838.
Test Suite 'MemoryRetrievalTests' passed at 2026-10-22 02:42:26.870.
Test Suite 'PromptRealPathGoldenTests' passed at 2026-10-22 02:42:29.085.
Test Suite 'RecallToolTests' passed at 2026-10-22 02:42:29.114.
Test Suite 'RecallViewerTests' passed at 2026-10-22 02:42:29.130.
Test Suite 'RecallVisibilityTests' passed at 2026-10-22 02:42:29.154.
Test Suite 'RecallWindowSummaryTests' passed at 2026-10-22 02:42:29.167.
Test Suite 'RecallYesterdayTests' passed at 2026-10-22 02:42:29.258.
Test Suite 'SearchIndexDidSaveProbeTests' passed at 2026-10-22 02:42:34.511.
Test Suite 'SearchIndexRealStorePerfTests' passed at 2026-10-22 02:42:34.524.
Test Suite 'SearchIndexStoreTests' passed at 2026-10-22 02:42:34.647.
Test Suite 'SearchIndexerTests' passed at 2026-10-22 02:42:38.507.
Test Suite 'SearchKindSelectionTests' passed at 2026-10-22 02:42:38.520.
Test Suite 'SearchMainPathFilterTests' passed at 2026-10-22 02:42:38.573.
Test Suite 'SearchQueryMappingTests' passed at 2026-10-22 02:42:38.577.
Test Suite 'SearchServiceIndexPathTests' passed at 2026-10-22 02:42:38.804.
Test Suite 'SearchTextSegmenterTests' passed at 2026-10-22 02:42:38.809.
Test Suite 'SearchTypingPredicateTests' passed at 2026-10-22 02:42:38.820.
Executed 482 tests, with 0 failures (0 unexpected) in 55.706 (55.810) seconds
** TEST EXECUTE SUCCEEDED **
```

- 临时量化器移除、重新 xcodegen 后，最终 `sol-tokenizer-fix1-resume-final-mac-build.log` 再次 `** TEST BUILD SUCCEEDED **`。42 套通过的是同一批未改动的生产代码与永久测试，量化器不留在最终源码/工程引用里。

#### 已裁定不修的边界与技术债

- **P2-1：** 单汉字查询（如「猫」）仍不生成 BM25 token，这是修前已有的限制；原文路保留整段短语/子串，可以查单汉字。本轮不扩展 BM25 单字语义。
- **P2-3：** keywords 仍按相同分词加入两份，也仍计入文档长度；长度归一可能改变名次，先观察，不另调权重或归一公式。
- **P2-5：** 不加分词缓存；每次查询仍重新分词候选。无索引迁移、同义词、reranker、重试或新索引。
- 主聊天 Recall L1/KeywordRetriever 的词面命中与名次按上述门槛改变；实际 L1 高重要度噪声与 exact 原文测试已通过。搜索框在同批语料、索引/扫描及超过 300 条的测试中保持时间排序 / 结果合同；没有做设备外观或真实向量模型验收。

