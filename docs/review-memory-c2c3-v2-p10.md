# C2/C3 v2 · 第 10 段复盘：来源检查收口 + Coverage / Preservation 只记日志 + 纯代码 wiki 体检

范围：主 plan `plan-memory-c2c3-v2.md` 第 10 段（实现 1–5、旧数据、验收），`plan-memory-c2c3-v2-rev5.md` §0 和 §3「第 10 段」（wiki 体检）。基线 HEAD `5d720229f`，工作区干净。按实现单：没做 git 写操作，没开模拟器，没碰设备，没跑真端点。live 方法 `CatalogLiveSmokeTests.testWriterCoveragePreservationLive` 交车头在 😷 iPhone 14 上跑，**这里没有冒充已经验过**。

## 0. 做了什么

1. **来源检查一个入口**
   - 三条路本来就都走 `CatalogItems.parse`：自动写手（`CatalogWriter.write`）、手动 agent 的 submit、种子交页。都在存提案之前检查，存了才进审计台，没有旁路。
   - 这次收的口子是「出处文字」。记录行「（出处：…）」的字统一由 `CatalogSources.label`（`CatalogWriter.swift:71`、`:83`）给。`recordLine`（`:318`）和种子改稿核出处的 `CatalogSeedDrafts.checkRecords`（`CatalogSeedDrafts.swift:183`）用同一个口径。原来的 `CatalogSeedTools.label` 删了。
   - 整份原料的登记只走 `CatalogSources.addFile`（`CatalogWriter.swift:67`）。种子 `CatalogSeedTools.sources` 改用它（`CatalogSeedTask.swift:517`）。第 11 段的问卷答案也从这里登记，不另开口子。
2. **先截后登记**：查了一遍，现有代码已经满足，没有改。
   - 日常：`CatalogRetrieval` 限量时，只把实际拼进回执的正文登记成出处。截掉的整条不登记。
   - 手动：agent 按回灌出去的那段前缀登记（`receipt.prefix`）。
   - 种子：读到哪份全文，就登记哪份。
   - 三条路丢掉的行和原因，都写进同一份 `.runs` 的「来源检查」一节（`CatalogDiagnostics.faithfulness`）。
3. **Coverage**
   - 写手同一次输出顶层多一个 `coverage`：每份输入一条，写进了哪儿（`at`），或者为什么没写（`why`）。
   - 代码怎么核（`CatalogDiagnostics.coverage`，`CatalogDiagnostics.swift:67`）：
     - 只看编号或出处有没有挂在**留下的**条目上。被 Faithfulness 丢掉的行挂不上，不算覆盖；
     - 不是这次给的输入，记「不算」；
     - 写手没交代的，记「未评估」；
     - 判了 single 的，记「单条就够」。
   - 自报写进「现在」的，提示词要求写手在那条 new_page / rewrite_now 上带 `fragments`。这个字段原来就收，这次只是写进了提示词。
4. **Preservation**
   - 顶层多一个 `preservation`，交了 rewrite_now 才写：旧「现在」里每件事一条，标「保留 / 改了 / 疑似漏了」，带新说法和理由。
   - 代码对每条留下的 rewrite_now，把旧「现在」和新「现在」整段并排记下来，再列写手的说明（`:107`）。
   - 不做字符串包含或相似度比对。
5. **两项都只记日志**
   - 不进提案，不拦，不触发重写，不另发请求。
   - 写手没交，就写「未评估：这次交的没有 coverage / preservation」。任何地方都不出「通过」两个字。
   - 记录位置：
     - 写手：`CatalogWriter.swift:1138`，记在最终交的那一稿上；
     - agent：`CatalogAgent.swift:676`，每次 submit 都记；
     - 种子：`CatalogSeedAgent.swift:373`，每次交页都记，只算这一页留下的条目，丢弃原因含页级丢弃。
   - 提示词：`CatalogPrompts.diagnostics`（`CatalogDiagnostics.swift:137`）。接在写手 / agent 共用的条目格式末尾（`CatalogWriter.swift:827`、`:967`），种子用路径版（`CatalogSeedTask.swift:626`）。
   - 工具定义：submit_proposal 加了 `coverage` / `preservation` 两个可选属性（`CatalogAgent.swift:60`、`:96`；种子 `CatalogSeedTask.swift:478`）。
6. **纯代码 wiki 体检**（`WikiHealth.swift`）
   - 三项检查：
     - **断链**：「连到」指向的页不存在；
     - **孤页**：直接放在两支下、不在任何分组文件夹里，又没有别的页连过来；
     - **目录漂移**：每一层 INDEX.md 和代码此刻会生成的不一样。多列的、漏列的、哪一行对不上，逐条列；那层有页却没有索引文件，也算。
   - 什么时候跑：每天自动整理那次，没被停就跑（`CatalogRunner.swift:431`、`:438`）。
     - 在后台读，零模型调用，零写页；
     - 有漂移就调现有的 `rebuildAllIndexes()` 重建索引。报告里记的是重建前的差异，重建失败也记下来。
   - 结果存三处：
     - `wiki/.sort/health.json`；
     - 同一份 `.runs` 里的「wiki 体检」一节；
     - 一行 C3 记忆日志「wiki 体检：断链 N · 孤页 N · 目录漂移 N」，点开定位到那一节。
   - C3 页顶部状态行下面加了「wiki 体检」一行，显示三项条数和时间，点开是明细 sheet（`MemoryWriterPages.swift:219`、`:264`、`:586`）。设置搜索加了关键词。

## 1. 测试

- 新增 `MemoryPalaceTests/CatalogFaithfulnessTests.swift`，7 条：
  - 混合出处逐行断言。15 行里留下这 7 行：有效碎片、给过的 A2 段、给过的原文、Prompt 槽、CC 文件、给过的 A4 那天、伪造编号配真段。丢掉这 8 行：无源、伪造 f、截掉的尾部碎片、没给的段、没给的层、没给的原文、没读的 CC 文件、截掉的那天；
  - 诊断不拦也不触发重写，坏行不能冒充覆盖；
  - 缺诊断时记「未评估」，不出「通过」；
  - 自动路径：批方向后写手的实际请求、同一份记录；
  - 手动路径：agent 的实际请求、工具定义、同一份记录；
  - 体检：断链、孤页、漂移各一例，零模型、零写页、日志带锚点，第二次跑没有漂移；
  - 空 wiki 体检干净，也不会建出分组文件夹。
- `CatalogSeedTaskTests` 加 1 条 `testSeedPageRunRecordCarriesSourceCheckAndDiagnostics`：种子路径的实际请求、工具定义、同一份记录。假模型 `SeedModel` 加了 `pageExtra`，交页时可以带上 coverage。
- 没删测试。没有改动旧测试的断言。
- live：`MemoryPalaceIOSTests/CatalogLiveSmokeTests.swift:695` `testWriterCoveragePreservationLive`。用虚构的旧页加 3 条碎片（含一条无关的），让写手写一次。打印原文、来源检查、Coverage、Preservation 和 `.runs` 路径，只断言调用成功。

## 2. 边界情况

- **coverage 的 `at` 只当线索**。写手说写进了「现在」，但那条没带 `fragments`，就会记「留下的条目上没挂它（…或写进「现在」没带编号）」。这句是实话，可读起来像漏了。真模型交「现在」带不带编号，要看 live 结果。
- **agent 的 Coverage 输入**只算「分到这个主题的碎片」。「整理一个主题」和「人设改了」两条路没有分到的碎片，只核写手提到的编号在不在这次给过的集合里，不列「未评估」。
- **agent 每次 submit 都记一份诊断**，包括被打回修订的那份，所以同一主题会有好几份。种子交页同理。写手只记最终交的那一稿。
- **Preservation 只对留下的 rewrite_now 做**。rewrite_now 被丢了（比如「无变化」），就没有对照。append 到已有页、新开页都不算「旧事实」。
- **preservation 没写 page**，只有在这次只改了一页「现在」时才归到那页。改了多页、又没写 page 的说明，哪页都不归，那几页记「未评估」。
- **孤页的定义是我的理解**：「不在索引分组里」= 页直接放在 `工程/` 或 `楼层/` 下，不在任何子文件夹里。所以放在分组里、没人连的页（`楼层/人/某人`）不算孤页。见 §5 第 2 条。
- **漂移按整份文本比**。页数、「待分组」标记变了，也算一条「索引文件和代码生成的不一样」。空 wiki 不报，也不重建，不会建出 `工程/` `楼层/` 文件夹。
- **体检读每一页全文**（在后台）。wiki 到几百页时，每天多读一遍。
- **体检日志总是 ok**，除非重建或存结果失败。有断链、孤页不算失败，不标红。
- **停了的那次不体检**。C3 关着时每天自动整理不跑，体检也不跑。

## 3. 与第 11 段交互的风险

- **问卷答案登记**：走 `CatalogSources.addFile(路径, cite:)`。`cite.layer` 写「问卷」，label 会自动显示「问卷 <路径>」。第 11 段要定答案的路径或编号格式（比如 `问卷/q2`），写手记录用 `sources` 引用。`WikiProposalDisplay.citeText` 对「问卷」层没有专门显示，审计台上会是通用格式。
- **问卷的 Coverage 输入**：写手 / agent 的 inputs 现在只认分到的碎片编号，种子认原料路径。第 11 段三问如果走日常写手或 agent，要把答案路径作为 inputs 传进 `CatalogDiagnostics.record`，否则问卷答案的去向只会被核「在不在」，不会列「未评估」。
- **问卷目录**：如果复用种子的目录 → 正文两批，目录项原料要过 `CatalogSeedTools.checkDirection`（「读过的」集合）。问卷答案不在种子 `task.read` 里，需要另给 readable 集合，或者用同样的方式登记。
- **工具定义多了两个属性**：第 11 段新增入口如果复用 `submitDefinition` / 种子定义，会自动带上。提示词里没写诊断，就会一直记「未评估」。

## 4. 技术债

- **本机模型的日常写手**：真实请求会按 `CatalogLocalTrim` 从头裁用户文本，来源却按完整 Material 登记。理论上会登记模型没看到的开头部分（楼层提示、索引、回执前段）。现在写作规则本身就超过本机 3000 字，系统提示放不下直接报错，这条路走不到，所以没改。哪天本机能放下写作规则了，要改成按实际送出的文本登记。
- **`sources.versions` 是全量页版本快照**（日常非分组主题、agent）。没读全文的页也能交 append / retag / rewrite_now。这是 10-16 astra 审过、测试 `testBaseVersionIsWhatTheAgentSaw` 钉住的设计（没读的页按开工时版本当基线），这次没收紧。plan 写「wiki 版本只认本次实际给出的集合」，严格讲这里没对齐。见 §5。
- **孤页 / 断链不进提案**，只有日志和 C3 页。跨页修复（删连线、补连线）不做（rev5 已定）。
- **体检结果只留最近一次**（`health.json`），历史在 `.runs`（30 天清理）和记忆日志里。
- **「CC 段」「Prompt 段」**：种子出处是整份文件 / 整个槽，没有段级出处。plan 写的「段」这里按整份处理。
- 说明书 `scripts/manual` 没跑（同前几段）。

## 5. 偏离 / 拿不准

1. **漂移要不要重建**：实现单写「目录漂移照现有逻辑由代码重建索引」。现有逻辑只在批提案、编辑页时重建，巡检不重建。我在体检里有漂移就调 `rebuildAllIndexes()`（只写 INDEX.md，不写页），报告记重建前的差异。如果车头的意思是「体检只报告，重建等现有路径」，删掉 `CatalogRunner.swift` `checkHealth` 里那一个 `if` 就行。
2. **孤页定义**：见 §2。也可以理解成「索引里也没列」，但索引本来就是代码生成、每层列全，那样孤页就和漂移重合了，所以我没这么理解。
3. **wiki 版本没收紧**：见 §4 第 2 条。收紧会推翻已审过的设计。
4. **提示词改了，金样没变**：写手 / agent / 种子的系统提示和 submit 工具定义都加了诊断写法。两组金样（PromptRealPathGolden、InspectorRealPath）只覆盖主聊天请求，跑过原样通过，没有 RECORD。
5. **UI 没走查**：C3 页「wiki 体检」行和明细 sheet 只编译通过（mac / iOS），按守则没开模拟器。

## 6. 返工（astra 审 `1f487a489`：2 条 P1、6 条 P2，车头逐条裁定）

本节取代前文 §0 第 3–5 条里「诊断和正文同一个 JSON」「诊断记在哪」的说法，以及 §2 第 1–3 条。行号以返工后的工作区为准。

1. **【P1】体检进审批锁。** 检查、有漂移时重建、存 `health.json`，三步一起放进 `WikiProposalReview.exclusive`（`CatalogRunner.swift:443`），和批提案写页 / 重建索引串行。拿锁失败只记一行日志，不体检。
2. **【P1】诊断和正文分开解析。**
   - 拆分在 `CatalogDiagnostics.split`（`CatalogDiagnostics.swift:54`）：
     - 正文取开头那个完整的 JSON 对象；
     - 对象顶层出现 coverage / preservation 时，诊断键之前那几个键单独也算一份正文，所以诊断坏了照样能解析出正文；
     - 输出被截断时，只认诊断键之前那一份完整正文。
   - 诊断单独解码（`:137`），缺、坏、截断都是 nil，记「未评估」。`CatalogItems.parse` 走这一个口子（`CatalogWriter.swift:354`）。
   - 写手：先输出正文对象，后面另起一行输出诊断对象（提示词 `CatalogWriter.swift:1009`）。
   - agent / 种子：诊断字段写在 submit_proposal 参数最后（`CatalogAgent.swift:367`、`CatalogSeedTask.swift:626`）。
   - 截在诊断里的截断不算截断（`CatalogAgent.swift:685`、`CatalogSeedAgent.swift:236`）：不追加请求，不修订，也不让它「少写几条」。
   - 提示里写明「正文优先，篇幅不够就整段省略诊断」。
   - 正文本身被截断时，原有的「少写几条」反馈没改。
3. **【P2】同轮先查后交。**
   - agent：每轮处理工具调用前，先拍一份「模型已经收到的」出处和读过的页（`CatalogAgent.swift:522`、`:662`）。submit 的解析、covered 挂页、single 校验、诊断都只认这一份。这一轮新查到的，要等下一次请求真发出去之后才认（`take` 在 `:547`）。
   - 种子：交目录、交页只认这一轮之前已读的（`CatalogSeedAgent.swift:199`、`:289`、`:369`）。
4. **【P2】审计台手改走同一套出处口径**（车头二次裁定后的版本，见 §7）。
   - 校验在 `CatalogSources.checkEdited`（`CatalogWriter.swift:96`）：
     - 行末留着合法出处（原有的、或「用户编辑」）的，照留，改了字也不动出处；
     - 没写出处的新行，标「（出处：用户编辑）」；
     - 删掉原有出处，或写了不认识的出处，拒存。
   - 普通提案：`WikiProposalStore.edit`（`WikiProposal.swift:328`、`:331`）。种子：`CatalogSeedDrafts.validate`（`:204`、`:209`），原来的 `checkRecords` 并进来了。
   - 直接编辑 wiki 页不受影响。
5. **【P2】只登记完整提供的最小来源单元。**
   - 回执正文按「单元」分组（`CatalogSearchReceipt.swift:46`、`:48`），同一条原料 / 段 / 日 A4 的几段正文算一个单元。
   - 截取前缀时，被截到的单元整个标成不完整（`:93`），登记时跳过（`:129`）。
   - 所以截了半截的碎片、A2 段、日 A4 都不能引用。
6. **【P2】Coverage 按最终交审集合算。**
   - 「写进了页」只看交审条目上挂的编号 / 出处，不再算没挂上的 `covered`。
   - 自动：在三条门槛过滤和补钩子之后才记（`CatalogRunner.swift:563`）。
   - agent：在 `take` 里，covered 挂好之后记（`CatalogAgent.swift:562`）。
   - 种子：只记存成功的那一页（`CatalogSeedAgent.swift:429`）。
   - 打回修订、被替换掉的那份，标「中间稿诊断（这一份不是最后交审的）」（`CatalogAgent.swift:754`，种子 `:402`、`:409`）。
   - 自动 / 手动的正文提案现在带 `run` 链接，指向交审诊断那一节（`CatalogRunner.swift:597`）。
7. **【P2】输入清单动态。**
   - 清单按这次实际给过的全部碎片编号 + 原料路径来列（`CatalogDiagnostics.swift:170`），检索新增的也算。
   - 分组记：写进了页 / 声明了没覆盖 / 说写进了但不算覆盖 / 判单条就够 / 没交代（未评估） / 不是这次给的输入。
8. **【P2】测试。**
   - 删掉了提示词固定措辞的断言，只查工具定义里有没有诊断字段。
   - 「同一份记录」改成沿提案的 `run` 链接打开文件，取锚点那一节再查。
   - 新增：
     - 正文中途截断；
     - 写手诊断完整 / 截断 / 坏掉三种；
     - 没挂上的 covered 不算覆盖；
     - 手动同轮先查后交，以及动态输入；
     - 手动参数截在诊断里；
     - 审计台手改；
     - 体检等审批锁。
   - 改了 3 条旧测试：
     - `CatalogOriginalRetrievalTests` 两条：「出现一个字就登记整条」改成「截到的整条不登记」；截断用例改成第一条完整、尾部那条半截；
     - `CatalogRetrievalTests` 归因那条：半截正文不登记，完整回执才登记；
     - `WikiProposalTests.testEdit`：手写行带「（出处：用户编辑）」。

### 返工后仍留着的边界 / 拿不准

- **日 A4 没做到「按日内条目登记」**：日记录的条目在回执里不显示窗口 id，引用格式也只有 `{"layer":"A4","day":…}`，按条目引用要新增引用写法，还要改回执格式、审计台显示、出处存活检查，属于新机制。这次按「一天整条是最小单元」做：那天全部回灌了才能引用，截了半截整天不能引用。要不要做条目级引用，请车头定。
- **很长的单条原料永远引用不了**：超过 6000 字的单个 A2 段、原文节点，回执一定被截，按新规矩引用不了。agent 用 read_aline 读那一段也会被截到 6000 字。
- **原文、A 线不进 Coverage 清单**：没有给模型的固定编号，所以只列碎片和原料路径。
- **种子同轮 read + 交页没单独写测试**：代码已按同一个快照处理，只测了 agent 那一路。
- **体检在审批锁里读全部页**：页多的时候，体检这段时间批提案要排队。

## 7. 车头二次裁定（返工后 4 条遗留）

- **日 A4**：维持「一天整条是最小单元」，不做条目级引用。
- **单条超过 6000 字就不能引用**：接受，记为技术债。超过 6000 字的单个 A2 段、原文节点，回执一定被截，引用它的行会被丢；read_aline 读那一段也一样。
- **种子同轮测试、原文 / A 线不进 Coverage 清单**：照旧，不处理。
- **审计台手改的出处**，这次改了：
  - 改了字、行末仍留着合法出处的，保留原出处，不改标「用户编辑」（`CatalogWriter.swift:96`）。
  - 只有没写出处的新行才标「（出处：用户编辑）」。
  - 删掉原有出处、写了不认识的出处，照旧拒存。
  - 改完按实际保留的出处重算条目挂的碎片（`CatalogSources.keptFragments`，`CatalogWriter.swift:114`；接在 `WikiProposal.swift:329`、`:333`）：原来某行引用的碎片，改完一行都不引用了，就不再挂在条目上。批的时候它不标「已整理进」，回到池子里。条目级额外挂的碎片（不在任何记录行里的），不受影响。
  - 种子提案的条目只挂原料文件、不挂碎片，所以只走同一个 `checkEdited`，没有碎片要重算。
  - 测试：`CatalogFaithfulnessTests.testAuditEditOfOrdinaryProposalKeepsSourcesAndRecomputesFragments`。覆盖改错字保留出处 → 出处不变；新加一行不写出处 → 标「用户编辑」；删掉一行 → 对应碎片批后不标已整理；删出处 / 伪造出处 → 拒存。
- **剩下的边界**：她改了字但留着模型的出处，出处就照旧挂着。改出来的意思是不是还和那个出处对得上，代码不判断。

## 8. live 回归：正文、诊断各包一段围栏

- 现象：😷 iPhone 14 上 sonnet 把正文和诊断各包了一段 ```json 围栏。正文解析正常，诊断被记成「没有可用的」，其实交得完整。
- 原因：`split` 把正文后面的全部剩余文字当成诊断去解码，前面那个闭合围栏和第二个开围栏没去掉。
- 修法：找完整 JSON 对象的逻辑抽成 `CatalogDiagnostics.object`（`CatalogDiagnostics.swift:80`），正文和诊断共用这一套。`split`（`:54`）在正文后面找下一个「{」，从那里取完整对象当诊断，中间隔着围栏、空行、说明文字都不影响。诊断被截断时照旧解码失败，记「未评估」。
- 回归测试：`CatalogFaithfulnessTests.testDiagnosticsAfterBodyInSeparateFencesOrAfterProseAreRead`，用真实输出的两段 ```json 围栏形状，另加一种「没有围栏、中间隔一句说明文字」。
