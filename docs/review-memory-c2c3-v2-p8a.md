# C2/C3 v2 · 8a 复盘：分拣（代码基线 + 模型可选 + 第八类「用户」）

范围：`plan-memory-c2c3-v2-rev5.md` §1 第 8a 段。基线 HEAD `7ee22ba47`，工作区干净。按实现单：没有做 git 写操作，没开模拟器，没碰设备，没跑真端点。模型分拣的 😷 iPhone 14 live（`testModelSorterVersusCodeBaselineLive`）交给车头跑，**没有冒充已验**。

**中途改单（车头转粟粟，10-22）**：代码基线开新页那一路原先按 tag 词频，「习惯 / 计划 / 睡眠」这类泛词也会凑够 3 条，所以改回按 subject。前提是 C2 的 subject 已经修好（c46021be3）。tags 现在只用来字面对上已有页。

## 0. 做了什么

1. **代码基线（默认，零模型）**，`CatalogSorter.group`（`CatalogSorter.swift:453` 起）：
   - **归已有页**：碎片的 subject、tags、content 拼在一起，和每页的标题、触发词做字面比对（复用 `WikiInjection.match`；名字和「不触发的词」不算）。
     - 只中一页就归它，理由写「碎片里有这页的标题 / 触发词「X」」；
     - 中了多页记为拿不准，不归。
   - **开新页**：没对上任何页的碎片，按 trim 之后不分大小写的 subject 聚。
     - 同一组 ≥3 条，并且这个 subject 没有字面对上任何页的标题或触发词（双向都查），才以 subject 提开新页。路径照旧先放 `楼层/主题/`，她可以改。
     - subject 是本楼层用户的名字时，不以名字开页，也不按方面拆。凑够 3 条就提一条「整理{用户}本人」，路径 `楼层/{用户}`，类为「用户」。归到哪页、开不开新页，交给写手判断。
     - 没 subject 的旧碎片照旧规则，按第一个关键词聚。subject 是助手名或「不触发的词」时也按这条走。
   - **用户新建页、改触发词**：每轮现读 `WikiInjection.load`，下一轮就生效，不用改代码。
   - 「整理本人」这条方向写手能接住：
     - 写手输入多一段说明「对照 `楼层/{用户}/` 下现有的页归，或者在下面开新页，不建这一页本身」（`CatalogWriter.swift:593-594`）；
     - 相关索引在方向指向分组本身时，加上那一层（`CatalogWriter.swift:541`）；
     - 现在整理的 agent 提示带上归组理由（`CatalogRunner.swift:907-908`）。
2. **模型分拣（可选）**：
   - 新文件 `CatalogModelSorter.swift`：
     - 提示词 `:36`：新稿第 2 部分，去掉了固定路由表和固定子页清单，改成「对照索引里现有的 `楼层/{用户}/` 下的页」；示例里的人名换成 `{用户}` / `{助手}` 变量，路径改成本项目的 `楼层/...`。
     - 输入 `:192`：碎片、A4 时间轴（写「暂无」）、实时索引。
     - 校验 `:210`：能解析、每条都判了、没有重复、四选一、page 在索引里、new 的类是八类之一、路径合法、已有的页不能当新页。
     - 调用 `:285`：校验不过，带上逐条原因给一次重写；再不过就抛错。
   - C3 页加了「分拣：代码 / 模型」，默认代码（`MemoryWriterPages.swift:442,644-651`）。
     - 设置项 `CatalogSettings.sorterKey` / `sorter()` 在 `CatalogRunner.swift:18-26`，`CatalogJob.sorter` 在 `:125`，`makeJob` 读设置在 `:1207`；
     - 配置导出白名单 `ConfigSchema.swift:131`，设置搜索加了「分拣」。
   - 走 `job.caller`，也就是写入预算、全局闸和记账（`UsageKind.catalog`），和写手同一条路。
   - 失败、被拦、停止时，本轮不提方向，只记日志和报告，不退回代码基线（`CatalogRunner.swift:285-320`）。
   - 模型判 single 的走现有 `CatalogMaterial.markSingle`；暂存的留在池里。
3. **两种分拣交同一种方向提案**：
   - 自动方向和现在整理共用 `CatalogSession.sort`（`CatalogRunner.swift:285`），产出同一个 `CatalogSorter.Grouped`；
   - `Topic.reason`（`CatalogSorter.swift:424`）进方向理由，后面再拼碎片标题（`discover`，`CatalogRunner.swift:249`）；
   - 后面的两批审批没动。
4. **第八类「用户」**：
   - `WikiPage.Kind.user = "用户"`（`WikiStore.swift:7`）；
   - `pathRules` 的类清单和说明改成八类，她本人的页挂在 `楼层/{用户}/` 下、不预设子页（`CatalogSorter.swift:394`）；
   - 种子目录校验文案和种子提示词改成八类（`CatalogSeedTask.swift:537,623`）；
   - 种子工具 schema 和审计台类选择器都用 `allCases`，自动带上「用户」；
   - 旧页不迁移。

## 1. 测试

- 基线：19 套 326 测 0 失败。
- 改完：同 19 套 + 新的 `CatalogSortingTests`，共 20 套 339 测 0 失败；另外 11 套周边（配置导入导出、设置骨架、Wiki 索引 / 连线等）73 测 0 失败。两组金样没变，也没 RECORD。
- 新增 `CatalogSortingTests`，13 条：
  - 代码基线：
    - 新稿的「饼干胖了」只归饼干页，不进她的身体页；
    - 只有单条就够的碎片不成组；
    - 田中老师第 3 条才开页；
    - 撞多页记拿不准；
    - 泛词 tag 不开页：习惯 / 计划 / 睡眠 / 职场各出现 ≥3 次，开页候选只有 豆包 / 林栖 / 半盏 和「岚舟本人」；
    - 没 subject 的旧碎片按关键词；
    - subject 被现有页的词包含时不开页；
    - 用户新建一页、加了触发词，下一轮碎片就能归进去（全程零模型调用，并验证「用户」类读写往返）。
  - 模型分拣（假模型）：
    - 一次重写，回灌原因后交出同一种方向；
    - 两次都不过就不提方向，并记日志；
    - 被预算拦下；
    - `check` 各项；
    - 默认是代码。
- `CatalogSeedTaskTests.testOutlineAcceptsTheUserKind`：种子目录接受「用户」类。
- 删除 `CatalogDirectionTests.testCodeGroupingReadsOnlyTitlesAndLeavesUnclearAlone`：它断言「不读正文」，和 rev5「content 字面比对」相反。它覆盖的单条就够跟随、拿不准、未命名标题，已经在新套件里重写。
- live：`MemoryPalaceIOSTests/CatalogLiveSmokeTests.testModelSorterVersusCodeBaselineLive`。用 9 条虚构碎片，其中一条应能归进用户新建的页「楼层/岚舟/手作」，逐条打印模型判断、代码判断和分歧。

## 2. 边界情况

- **碎片池很大时**，模型分拣把整池加上整个索引一次送出去，没有分批。几百条就可能超出上下文或很贵。现在的处理是报错、记日志、不提方向。
- **字面比对是子串**。两个字的页标题（比如「身体」）会被 content 里的任何「身体」命中，`content` 一进比对，误归会变多。按原则 4 只做字面，这个误差接受，靠她驳回方向。
- **subject 规范化只做 trim 和不分大小写**。「豆包」和「琥珀将军」这种同物异名，代码基线分成两组，可能都凑不满 3 条。跨段统一叫法不归 C2 管，按复盘结论交给模型分拣或她手动。
- **「整理本人」的路径是 `楼层/{用户}`**（一个分组，不是页）：
  - 如果她恰好有一页就叫 `楼层/{用户}.md`，方向会指到那页上，没处理；
  - 改名后的楼层用户名不同，旧的本人碎片按新名字不再被识别成本人，会当成普通 subject 走。
- **模型分拣判 single 是立刻打标**，不经审批，和代码基线的行为不对称（代码不判 single）。这是照 rev5 表格做的。
- **两种分拣都不处理 `timeline_proposals`**，模型返回了也忽略。

## 3. 与第 9 / 7 / 8b 段交互的风险

- **第 9 段写作者**：
  - 「整理本人」方向靠写手自己判断归哪页、开不开页，现在只加了一句说明，写手规则还是旧的；
  - 第 9 段换新稿提示词时，要保留或改写 `CatalogWriter.userContent` 里那段「【{用户}本人】」，否则写手可能直接建 `楼层/{用户}` 这一页；
  - 新开页「凑够 3 条」在写手那边没有代码检查。
- **第 7 段 A4**：模型分拣提示词里时间轴先写死「暂无」（`CatalogModelSorter.timelineNone`）。第 7 段接 topics 时，要把 `user()` 那一栏换成实际数据，`timeline_proposals` 要由第 8b 段消费。
- **第 8b 段**：
  - 时间轴提案的代码基线（话题词连续 ≥2 天、没字面对上任何页）可以复用 `group` 里的「没字面对上任何页」双向检查；
  - 去重沿用 `priorDirections`，按路径和线索；时间轴来源的方向没有碎片线索，去重要另想。
- **方向理由格式变了**：从「N 条碎片的标题碰上了这页」改成「理由 · N 条碎片：标题」。审计台显示的是原文，没有代码依赖它，旧提案不受影响。

## 4. 技术债

- 模型分拣提示词第一步保留了新稿的「用 subject 匹配，不要读 content 猜」，和原则 5「subject 只当线索」有张力。照实现单「其余照用」保留，等测试台比。
- 新稿的「暂存主题」输入没做持久化：我们的碎片没归页就留在池里、每轮全量重判，所以把输入第 4 项改成「碎片含以前暂存、还没归页的」，`stash` 输出不落盘。
- 模型的 new 页归到「同一路径 ≥3 条」才提，按 path 字面相等聚；模型同一东西给出两种 path 就凑不够。
- 代码开新页的类固定写「主题」、路径放 `楼层/主题/`，属于代码猜的，她在方向上可以改。
- live 方法在 `MemoryPalaceIOSTests` target 里，这次只编了 iOS app（`build.sh ios` 编的是 `MemoryPalaceIOS` scheme），**测试 target 没编**。车头在 mask 上编的时候先看这一个方法能不能过编译。
- 每轮分拣日志里的「暂存或新页不到 3 条」只有总数，没有逐条列出。

## 5. 返工（astra 审 ea71d4eeb，车头逐条裁定）

本节和上文冲突的，以本节为准。上文 §0 里这几条已作废：subject 被页标题包含就不开页（双向检查）；助手名 / 不触发的词作 subject 时退回关键词；写手里那段「【{u}本人】」。

### 5.1 逐条怎么修

1. **P0 分组写手要看全文**
   - 「整理分组」方向备料时，读 `楼层/{u}/` 下现有的每一页全文，加上同名页 `楼层/{u}.md`，版本和全文同一次读（`CatalogWriter.swift:585` 起）。
   - 写手的 `versions` 只有这几页，所以 `rewrite_now / append / link / retag` 只能落在给过全文的页上，别的页只能 `new_page`。这条复用解析器原有的「没记版本的页不能改」，不另写规则。
   - 写手输入改成「【整理分组】…」，后面附各页全文（`:631`）。
2. **P0 分组和具体页分开**
   - `CatalogSorter.Topic.group`（`CatalogSorter.swift:426`）和 `WikiProposal.Direction.group`（`WikiProposal.swift:72`，可选；旧数据是 nil，按「写这一页」处理）明确标出「整理分组」。
   - `.user` 只是页的类，不再拿它当目标类型。模型提的 `楼层/{u}/作息` 就是写那一页。
   - 执行入口 `CatalogRunner.swift:420` 起：分组方向不按同名页判 existing，不套钩子，agent 的 `path` 置空、换成分组提示（`groupHint`，`:876`）。
   - 审计台的类别显示「方向 · 整理分组」（`WikiProposalDisplay.swift:41`），动作记为 update。
   - 同名页 `楼层/{u}.md` 存在时，方向照样是分组，同名页作为给过全文的页之一交给写手。
3. **P0 模型提示词**
   - 删掉「用 subject 匹配，不要读 content 猜」和对应的自检项。
   - 第一步改成：subject 是强线索，不是标准答案，结合 tags、content 和索引里的标题、别名、钩子，判断说的是谁、哪个话题（`CatalogModelSorter.swift:68` 起）。
   - 第三步不再写「subject 相同 = 同一个东西」。
   - 保留「饼干胖了不进身体页」的反例，另加一个「别名对上」的正例。
4. **P1 拆页后每个新页都要 ≥3 条**
   - 新增 `CatalogItems.dropThinNewPages`（`CatalogWriter.swift:423`）。只在日常方向（`mode == .daily`）的正文入口调用（`CatalogRunner.swift:451`）。
   - 规则：每个要新开的页，按去重后的碎片出处数计，不到 3 条就整条不交，指向它的连线一并去掉；这些碎片不打标，留在池里。方向结果里写明是哪一页、有几条。
   - 种子、点名主题、现在整理、{助手}建议（agent）都没套这条。
5. **P1 反向包含**：去掉了这个硬否决。原来的测试改成「上海旅行页不挡 subject 上海开页」。
6. **P1 subject 被屏蔽时**：只有真正没有 subject 的旧碎片才按关键词回退。subject 非空但是助手名、在「不触发的词」里，或者别的屏蔽名，直接不开页。
7. **P1 规范化**
   - `CatalogSorter.key`（`:531`）：NFKC、全半角、大小写、连续空白。
   - 用在 subject 分组、和用户名比较、屏蔽表上；显示用第一次出现的原文。
   - 不做同义词或昵称合并。
8. **P1 指纹**
   - 内容：模型分拣成功后，把 system 提示、用户文本（碎片 + 实时索引 + 时间轴栏）和模型名拼起来算 SHA256，存到 `wiki/.proposals/sort-fingerprint.txt`（`CatalogModelSorter.swift:300` 起）。
   - 判断：下一轮现读索引、重算指纹，和上次一样就跳过不付费，并记一行日志（`CatalogRunner.swift:296`）。
   - 存的时机：指纹按 single 打完标之后的池子算（`:321`）。
9. **P1 single 正例**：「今天穿红色外套」换成「血型是 O 型、索引里没有讲基本情况的页」，和三条件一致，没加词表。
10. **P2 理由**
    - 代码基线：「碎片里有这页的标题 / 触发词：subject「饼干」、content「饼干」」，写明哪个字段的哪个词，匹配合同不变（`CatalogSorter.swift:516`）。
    - 模型：输出里加可选的 `why`，进 Direction.reason，格式是「模型：归到这页——why」（`CatalogModelSorter.swift:292`），条数由 `discover` 补上。
11. **P2 校验**：new.title 必填且非空（`:261`）；同一路径的多条 new，kind / title 必须一致，矛盾的走一次重写（`:264`）。

### 5.2 测试

- **新增 8 条**：
  - `testSubjectInsideALongerPageTitleStillOpensItsOwnPage`（替换原来的反向包含那条）
  - `testAssistantOrBlockedSubjectsNeverBorrowATagToOpenAPage`
  - `testSubjectsAreComparedAfterWidthCaseAndSpaceNormalization`
  - `testRealWriteBudgetPreflightBlocksModelSorting`：用生产的 `FragmentModelRoute.caller` 和写入预算闸，替换原来只是让 caller 返回 nil 的那条
  - `testSameInputIsNotSortedTwiceAndAnyIndexChangeSortsAgain`
  - `testModelProposedUserPageKeepsItsExactPath`
  - `testGroupDirectionGivesFullTextAndEveryNewPageNeedsThree`：写手拿到旧正文；没给全文的页改不了；不到 3 条的新页不交；同名页也是分组
  - `testDailyNewPageCitingTooFewFragmentsStaysInThePool`
- **补断言**：`testModelCheckCatchesWhatCodeCanJudge` 加了「缺 title」「同路径不一致」两条；代码基线理由加了字段断言。
- **夹具因新的 ≥3 门槛调整**：只改了写手假输出里引用的碎片编号，行为断言没放松。
  - `CatalogDirectionTests` 自动两批：改成 4 条碎片，引用 3 条、covered 1 条。
  - 编辑钩子那条：甲引用 3 条。
  - `CatalogOriginalRetrievalTests` / `CatalogRetrievalTests` 的写手假输出：引用 f1–f3。
  - `CatalogWriterTests` 自动方向那条：引用 3 条，断言改成「只挂明确引用的那三条」。
- 金样没变，也没有 RECORD。

### 5.3 剩下的风险

- **分组备料是全量**：分组下页很多时，全文全量进写手输入，没有分批。
- **手动 agent 没收紧**：agent 路径（现在整理、{助手}建议）还是原来的 `versionSnapshot`，只在提示里要求「改之前先读全文」，没在代码里收紧到「读过的页」。这是 agent 原有的合同，本次没动。
- **指纹会多付一次**：
  - 成功之后，方向会占住线索，下一轮池子因此变小，指纹自然不同，会再付一次；从再下一轮起才命中跳过。
  - ~~方向没存成，指纹却已经记下~~：已修（27a53ec19 之后）。模型分拣成功时只把指纹暂存在会话里；自动那次要方向提案存盘成功，现在整理要整轮没停、没失败、没被拦，才落盘到 `wiki/.sort/fingerprint.txt`。停了或任何一步失败都不写，也不覆盖旧的。测试 `testFailedDirectionSaveDoesNotRecordFingerprint` 守着这条。
- **新开页门槛只数碎片出处**：只引 A 线、原文的日常新开页一律不交。（已在 §6 第 5 条改掉）

## 6. 第二轮返工（astra 审 ea71d4eeb..0fdc2d15b，车头逐条裁定）

本节和 §5 冲突的，以本节为准。

### 6.1 逐条怎么修

1. **P0 本机截断**
   - `CatalogWriter.write` 新增可选参数 `trim`（`CatalogWriter.swift:678` 起）。
   - 拿真实的裁法 `CatalogLocalTrim.apply`（`:534`）模拟最终请求：它和本机路线 `LocalChatProvider.trimmed` 用的是同一个函数。给了全文的已有页（单页或分组下各页）只要有一页不在裁剪后的请求里，就直接抛 `CatalogWriterError.pagesDontFit`（`:523`），不发请求。
   - 报错是人话：「这几页的全文放不进当前模型，没写（不裁剪、不分批）」，后面附每页的全文字数、整份请求字数、当前模型一次收得下的字数。
   - 只有 C3 选的是本机模型时才传 `trim`（按 `job.seedModel` 的 `local:` 前缀判断，`CatalogRunner.swift:466`）；云上模型不传。
2. **P1 目标身份**
   - 新增 `Topic.target`（`CatalogSorter.swift:432`），由 `CatalogSorter.target(path, group:)`（`:443`）算出「页:路径」或「分组:路径」。代码基线 `group()` 的字典键、自动方向去重、`priorDirections`（`:549`）、`WikiSuggestTool.swift:45` 都改用它。
   - 同名页的碎片归「页:楼层/{u}」，本人分组归「分组:楼层/{u}」，两者互不吞并，结果和碎片顺序无关。
   - 同名页仍会作为分组备料的全文之一交给写手。
3. **P1 旧 nil 方向**：按车头裁定不修。ea71d4eeb 还没合进 master，没有用户数据带着不含 group 字段的旧「整理本人」方向；`group == nil` 一律按「写这一页」处理。
4. **P1 分组 covered**
   - 分组方向下，covered 只挂到写手写明的 `covered_page`，而且那一页必须给过全文（在 `m.versions` 里），见 `CatalogWriter.swift:724`。
   - 没写 `covered_page`，或写的页没给过全文，就不挂，碎片留在池里；不会默认挂到分组路径上。
   - 写手输入里补了一句说明（`:651`）。
5. **P1 新页门槛**
   - 非分组方向：撤掉拆页后 ≥3 的检查，分拣阶段已经按 ≥3 提过方向。
   - 分组方向：保留。`dropThinNewPages(_:among:threshold:)`（`:424`）按每个新页在记录或 covered 里认领的、本组不同碎片数来算；原文 / A 线出处照常允许，只是不算认领（`CatalogRunner.swift:472`）。
   - 4 个测试文件里的夹具恢复成原来的样子，其中 `CatalogOriginalRetrievalTests.swift:15` 恢复「只凭原文出处交页」的正例；这 4 个文件现在和 7ee22ba47 完全一致。
6. **P1 指纹 · 待批**：自动那次只要有分拣结果因为已有待批方向被过滤，或者因为超过 maxTopics 被留到下次，这一轮就不记指纹（`CatalogRunner.swift:270`）。没有做「缓存分拣结果」这套机制。
7. **P1 指纹 · 现在整理**：`sort(…, fingerprinted:)` 参数，现在整理传 false（`:934`），整条路径不读也不写指纹；删掉了原来现在整理末尾的 `rememberSort()`。
8. **P2 regroup**：自动那次只要方向提案存成功（或本来就没有方向要存）且没停，就落盘指纹（`:379`）。regroup 失败不再影响指纹。

### 6.2 测试

`CatalogSortingTests` 新增 10 条，删掉 1 条：
- 删：`testDailyNewPageCitingTooFewFragmentsStaysInThePool`（对应的规则撤了）。
- `testNonGroupNewPageIsNotRecountedAfterWriting`：非分组方向的新页只引 1 条碎片也照交。
- `testGroupFullTextSurvivesRealLocalAssemblyOrFailsInPlainWords`：用真实备料 `material()` 加真实本机裁法。放得下时，裁剪后的请求里全文还在；放不下时，抛出的人话报错带页路径和全文字数，并且没有发请求。
- `testPageEditedAfterTheGroupReadGoesStale`：读完全文之后页又被改了，审批时判 stale，不硬盖。
- `testGroupCoveredMustNameAPageWhoseFullTextWasGiven`、`testGroupCoveredOnAPageNotGivenIsNotAttached`：分组 covered 的两种情况。
- `testSameNamePageAndHerGroupAreSeparateTargetsInAnyOrder`：两种输入顺序得到相同结果。
- `testDirectionHeldByAPendingOneIsProposedAfterItIsResolved`：待批解除之后，同样的输入会重新分拣并提方向。
- `testOrganizeNowNeverReadsOrWritesTheFingerprint`：现在整理不受指纹影响。
- `testRegroupFailingAloneStillRecordsTheSortFingerprint`：regroup 单独失败时，分拣指纹照样记、下一轮不重付。

### 6.3 剩下的风险

- 本机截断只在日常写手这一步卡住。手动 agent（现在整理、点名主题、{助手}建议）走的是 `AssistantLocalBackend`，有自己的上下文处理，没在这一轮里查。
- 「被扣下」只按两种情况认：有待批方向挡着，或超过 maxTopics。不在这两种里的情况一律当作交付完了。
