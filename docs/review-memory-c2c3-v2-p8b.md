# C2/C3 v2 · 8b 复盘：时间轴提案 + 到期复核 + 人设变化手动 + A4-only 例外

范围：`plan-memory-c2c3-v2-rev5.md` §3「第 8b 段」，主 plan 第 8 段（实现 2–5、旧数据、验收）和 Q08。基线 HEAD `451d3b52c`，工作区干净。按实现单：没做 git 写操作，没开模拟器，没碰设备，没跑真端点。live 方法 `CatalogLiveSmokeTests.testTimelineProposalsModelVersusCodeBaselineLive` 交给车头在 😷 iPhone 14 上跑，**这里没有冒充已经验过**。

## 0. 做了什么

1. **时间轴提案**
   - A4 读取：`CatalogTimeline`（`CatalogSorter.swift:661` 起）。往回读 30 天的日记录，只认主调写成了的日子。主调是 nil 的日子记成「没准备好」；月文件读不了，整路记成没准备好。整天只有「接前一天」那段的日子标 `carried`，不单算一天。
   - 代码基线：`CatalogSorter.timeline`（`:575`）。同一个话题词在连续 ≥2 个记忆日出现，这段连续碰到最近 7 天，满足下面三条才提开新页：
     - 词里没有字面出现任何现有页的标题 / 触发词（`WikiInjection.match`）；
     - 本轮碎片分拣没出这个主题；
     - 路径放 `楼层/主题/`。

     理由写明哪几天出现过。线索 `basis` 写「A4「词」自 某天 起连续」，同一段连续只提一次。
   - 模型分拣：「A4 时间轴」一栏换成最近 7 天每天的话题（`CatalogModelSorter.timelineText`，`:52`）。`timeline_proposals` 在 `check` 里按 8a 的规矩核（`:305` 起）：
     - 类是八类之一，路径合法，索引里还没有这页，title 不能空；
     - 时间轴是「暂无」却提了，算没过；
     - 不过的给一次重写。

     碎片这轮已经凑够 3 条的同一路径，时间轴那条就不再另提。
   - 两种分拣交的都是同一种方向（`WikiProposal.Direction`，新增可选的 `basis`，`WikiProposal.swift:74`），审批照旧两批。去重改成「有新碎片或新线索才算新」（`CatalogSorter.isNew`，`:568`；`priorDirections` 多返回处理过的线索，`:548`）。
2. **A4-only 例外**：时间轴方向不带碎片线索。批了以后按日常方向执行一次写手，非分组新页本来就没有 ≥3 的检查，所以直接能开页。普通自动开页还是只在 `group()` 里按 ≥3 提，没动。
   - 写手现在能看到方向理由：`【为什么提这个方向】`（`CatalogWriter.swift:961`，`execute` 把 `d.reason` 交给 Topic，`CatalogRunner.swift:474`）。这样时间轴、到期复核这两种方向，写手都知道是为什么来的。
3. **valid_until**
   - 字段：`WikiPage.validUntil`（`WikiStore.swift:28`）。页上写成 frontmatter「有效到: YYYY-MM-DD」（`:60`）。手写的值认不出就原样留在 `extra.meta`，不丢。
   - 收不收：`WikiPage.until`（`:85`）。只有合法日子、并且「现在」里确实写着这一天才收。
   - 写手：JSON 加 `valid_until`，只收在 new_page / rewrite_now 上（`CatalogWriter.swift:185`、`:319`、`:393`）。对不上的不收，进 unapplied 给她看，条目照交。
   - 提案变更：`Change.rewriteNow` 加了 `until`（`WikiProposal.swift:104`），落页时再按「现在」核一遍（`:745`、`:755`）。她在审计台、种子草稿里改「现在」时，`until` 跟着带上（`WikiProposalDisplay`、`CatalogSeedDrafts`）。
   - 代码生成的索引带期限（`WikiIndex.swift:55`），注入快照也带（`WikiInjection.swift:13`、`:40`）。审计台显示「有效到」（`WikiProposalViews.swift:542`、`:571`）。
   - 提示词：「现在」规则加了第 5 条，条目格式加 valid_until 一段（`CatalogWriter.swift:715`、`:792`）。
   - 到期：`CatalogSorter.expired`（`:624`）。期限早于今天（记忆日）就提一条「复核这页的现在」（update），线索是「有效到 某天」。不删、不衰减、不自动改。旧页是 nil，不提。
4. **人设变化手动**
   - 入口在 C3 页「怎么整理」最后一行：「人设改了，整理一次」（`MemoryWriterPages.swift:219`、`:715`）。
   - 调用 `CatalogRunner.personaChanged(profile:)`（`CatalogRunner.swift:1203`）→ `CatalogSession.personaChanged`（`:1006`）：一个 agent，hint 说明人设刚改过、要对照着查页。来源是手动，`request` 就是这句话，没有方向待批，正文照样等批。
   - 没有任何监听人设的自动触发。
5. **空碎片不再整段 return**：`discover`（`CatalogRunner.swift:254`）
   - 没有新碎片时，照样看时间轴和到期。
   - 模型分拣在没有新碎片、但有时间轴时，只拿时间轴调一次；两样都没有就不调。
   - A4 读不了 / 某天没准备好，记一笔 `ok:false` 日志，别的线索照常。
   - 模型分拣失败或被拦也不再挡到期复核。只有「停了」才整轮不提。
   - 什么都没提时，`skipped` 写「没有待整理的碎片，时间轴和到期也没有要提的」。

## 1. 测试

- 基线：66 套 898 测 0 失败。
- 最终：67 套 914 测 0 失败。金样（PromptRealPathGolden / InspectorRealPath）没变，没 RECORD。
- 新增 `CatalogDiscoveryTests`，16 条：
  - 没新碎片也提出具体方向，零模型调用；
  - 只出现 1 天或中间断开的不提；
  - 字面对上已有页的不提；
  - 接前一天那段不算两天；
  - 同一段连续只提一次、待批不重复、断开后再连续才再提；
  - 碎片够 3 条时碎片优先，不够时时间轴照提；
  - A4-only 批了能开页，正文批前 wiki 不变；
  - 普通自动开页的 3 条门槛不变；
  - A4 读不了不挡碎片和到期；
  - 主调没写成的那天不算，并记日志；
  - 到期只提一次、旧页不误报、批正文前 wiki 不变、新期限过了再提；
  - valid_until 只从「现在」来、序列化往返、写进索引；
  - 人设变化只在手动时跑；
  - 模型分拣读到 topics，timeline_proposals 校验、一次重写后交成方向；
  - 没有碎片也没有时间轴时模型不调；
  - 时间轴是「暂无」却提了，校验不过。
- 改了 2 处模式匹配：`CatalogWriterTests` 一处、live 文件一处（`rewriteNow` 多了一个关联值），断言没变。
- live：`testTimelineProposalsModelVersusCodeBaselineLive`（`CatalogLiveSmokeTests.swift:524`）。

## 2. 边界情况

- **「本轮碎片没覆盖到」的理解**：做成「本轮碎片分拣已经出了这个主题（标题相同，或标题 / 别名字面出现在话题词里）」。碎片只有 1–2 条、分拣没出主题时，时间轴照提，这是 Q08 的 A4-only。另一种读法是只要有碎片 subject 写着这个词就不提，那样 Q08 的例外基本永远碰不到，所以没用。需要车头确认。
- **只做正向字面比对**：话题词里出现页的词才算对上，比如「饼干体检」碰上「饼干」页。页标题包含话题词不挡，比如「上海旅行」页不挡「上海」。和 8a 去掉反向包含保持一致。泛词（「工作」「日常」）只要连续两天出现就会被提，靠她驳回。驳回后同一段连续不再提，断开后再出现会再提一次。
- **30 天回看**：连续超过 30 天的话题，「从哪天起」会随窗口往前滑，每天变一次，可能每天重提。概率低，没处理。
- **今天还没写主调**：今天的日记录主调是 nil 时，每次巡检都会记一条「还没写成」（`ok:false`），有点吵。
- **模型分拣的时间轴去重**按路径（「A4（模型）路径」），驳回一次就永远不再由模型从时间轴提同一路径。和代码基线的规则不一样（代码基线断开后会再提）。
- **到期比较**用字符串比 YYYY-MM-DD 和记忆日，口径和 `markExpired` 一致（到期那天当天不算过期）。
- **rewrite_now 不带 valid_until 时，落页把旧期限清掉**（新「现在」不再有那一天）。写手漏填时，页上的期限会丢，靠提示词要求填。
- **到期复核和碎片更新撞同一页**：合成一条方向，线索和理由并在一起（`CatalogSorter.merged`）。
- **A4 关着**（`SessionCloseout.timelineEnabled == false`）：这一路不读，也不记日志。

## 3. 和第 10 / 11 段交互的风险

- **第 10 段 wiki 体检**：
  - 索引行现在可能带「（「现在」有效到 …）」后缀，目录漂移检查比对索引行时要剥掉或一并生成；
  - 页 frontmatter 多了「有效到」键，断链 / 孤页不受影响。
- **第 10 段来源检查**：时间轴方向没有碎片线索，只有 `basis`。如果按「方向必须有线索碎片」查，会误报。A4-only 正文的出处多半只有 A 线、原文，这是合法的。
- **第 11 段（三问 / 目标绑定 / 跳过恢复）**：方向多了 `basis` 字段。共用两批能力时，复制 / 改写方向要带上它，否则去重会退化成「每天重提」。
- **写手输入多了一节「为什么提这个方向」**，所有日常方向都有，碎片方向的理由里带碎片标题。第 9 段的写作者 live 没重跑。本机写手的系统预算问题（p9 复盘）不受影响，加的是 user 文本。
- **`Change.rewriteNow` 多了关联值**：以后新增的模式匹配要写四个位置。旧提案 JSON 没有 `until` 键，按 nil 读（可选关联值）。新测试里的审批往返覆盖了新写入，旧 JSON 解码没有专门测。

## 4. 技术债

- `CatalogTimeline` 放在 `CatalogSorter.swift` 里（为了不新建源文件），这个文件长到 ~720 行。
- 人设变化 agent 的开场还是通用的「先 search_aline 搜主题词」，主题词是「人设变化」，第一轮可能空搜一次。没为它单独改 opening。
- 人设变化没进设置搜索。
- 时间轴「没准备好」只看主调是否为 nil，不看 `TimelineDaily.Report`。A4 根本没跑（没有那天的记录）和那天没聊天分不出来。
- 模型分拣在没有新碎片、只有时间轴时，每天会因为时间轴变化付一次费（指纹每天变）。
- live 方法只在 😷 编了测试包（build-for-testing），没跑。
- 说明书（`manual/facts`）没同步，和第 7 段一样留给收口。

## 5. 返工（astra 审 5b1c79868，8 条 P2 + 方向理由，车头逐条裁定全修）

本节和上文冲突的，以本节为准。上文作废的说法：「回看 30 天 / 只看最近 7 天」「接前一天的日子不单算一天」「模型按路径去重、驳回一次永远不再提」「主调为 nil 都记没准备好」「valid_until 只收正文里写着的那一天，漏填就清掉」。

### 5.1 逐条怎么修（行号按当前工作区）

1. **期限漏填被清掉**
   - 期限一律从新「现在」正文里的「到 YYYY-MM-DD」推：`WikiPage.untilDates` / `until`（`WikiStore.swift:93`、`:100`）。
     - 写手给的 `valid_until`（或原来的期限）是正文里写着的某一天，就用它；
     - 不然取正文里最早的那一天；
     - 正文没写到期日 = 没有期限。
   - 旧期限只有新正文还写着它才留下。写手漏填时按正文推（`CatalogWriter.swift:394`）。写手给的值对不上，照旧进 unapplied 给她看，期限按正文定。
   - 只改了期限、正文没变，也算有变化（`:448`、`:449`）。
   - 审计台改正文（`WikiProposalDisplay.swift:346`、`:354`）、种子草稿改正文（`CatalogSeedDrafts.swift:224`）、落页（`WikiProposal.swift:745`、`:755`）都走同一个函数。
2. **手写无效值盖掉新期限**
   - 有了生效的期限，序列化时把手写的「有效到」换成「有效到（原写法，已换）」留着，不参与解析，文件里只剩一个生效的键（`WikiStore.swift:60-65`、`:88`）。
   - 没有替换的时候原样保留。
   - 解析时只拿掉值等于生效期限的那一行（`:168`），同时写着的无效行不再被一起删掉。
3. **去重身份**
   - 新增轻量状态 `wiki/.sort/discovery.json`：`CatalogDiscoveryState`（`CatalogSorter.swift:756`），和提案历史分开。
   - 每天清提案之前，`rememberHandled`（`:784`、`CatalogRunner.swift:414`）把处理过的方向的来源身份记进去；没记成就这次先不清。
   - `priorDirections` 的 basis 改成一个全局的来源集合（`CatalogSorter.swift:550`）：已处理状态 + 现有方向（待批的也算）。同一来源换个路径也挡得住。
   - 时间轴身份 = 话题词 + 这段连续在**完整历史**里的起始日：`CatalogTimeline.run` / `identity`（`:710`、`:729`）。到期身份 = 页 + 期限（`:615`）。
4. **模型时间轴去重**
   - `timeline_proposals` 要回填 `days`。代码核每一天都在给模型的时间轴里，编的日期算没过，给一次重写（`CatalogModelSorter.swift:37`、`:323` 起）。
   - 然后用 `CatalogTimeline.identified`（`CatalogSorter.swift:732`、`CatalogRunner.swift:293`）按第 3 条的同一种身份去重：标题是那天的话题词就按完整历史往前找起始日，不是就用它依据的最早一天。
5. **同一主题两个目标**：`check` 里，本轮候选（碎片的页 / 新页 + 时间轴提案）规范化后标题相同、路径不同、并且其中有要新开的，就回灌一次让模型统一，算在那一次重写里（`CatalogModelSorter.swift:345` 附近）。两个已有页恰好同名不算冲突。没加词表。
6. **只看最近 7 天会漏**
   - 去掉 7 天 / 30 天窗口，改按消费进度：`CatalogTimeline.load`（`CatalogSorter.swift:677`）读全部月文件。
   - 日记录的话题签名和进度里记的不一样（新写成、刚补齐、话题改过），就算新的。旧的先看，一次最多 31 天（`batch`，`:649`），多的留到下次（日志写还有几天）。
   - 进度在方向存下了才记（`CatalogRunner.swift:304-306`、`:393`）。没交出去的新来源（被待批挡住、超过 maxTopics）依据的那几天不记，下次再看。模型分拣失败也不记。
   - 给模型的是每个新日子连同它前一天（`modelDays`，`:745`）。
7. **continued 日整天被排除**：去掉了 `carried`。有日记录的记忆日（就是有消息的日子）都算，跨天的段每天都算。模型提示里那句限制也删了。测试改用真实的 `TimelineSkeleton.build` 从跨天消息拼出两天的记录。
8. **主调为 nil 记成失败**
   - 只有「过了那天、有 A2 段标题、主调却是 nil」才算真失败（`CatalogSorter.swift:686` 附近）。今天还没到时候、只有没压缩 / 短窗口的日子都不记。
   - 记日志按状态变化去重：上次记过的毛病存在 `reported` 里，一样就不再记（`CatalogRunner.swift:269`）。
9. **方向理由当事实**：写手输入改成「【为什么提这个方向】（自动发现时的线索，待核实：不是事实，也不是出处；页上只写下面原料支持的内容）」（`CatalogWriter.swift:963`）。这条没有真模型核验，只改了提示。

### 5.2 测试

`CatalogDiscoveryTests` 从 16 条变成 24 条（67 套 922 测 0 失败，金样没变、没 RECORD）。
- 改写 4 条：
  - 接前一天 → `testOneSegmentAcrossTwoDaysWithMessagesOnBothCountsAsTwoDays`，真实跨天消息；
  - 主调 nil → `testOnlyRealHeadlineFailuresAreLoggedAndOnlyWhenTheyChange`，三种情况 + 状态没变只记一次；
  - valid_until → `testValidUntilFollowsTheDeadlineWrittenInNowAndRoundTrips`，对不上按正文、漏填按最早；
  - 模型校验 → `testModelTimelineProposalIsCheckedAgainstTheGivenDays`，编的日期不过。
- 拆 1 条为 2 条：碎片不够让给时间轴 / 碎片已开题时间轴不另提。
- 新增：
  - `testDayBackfilledTenDaysLaterIsStillSeen`：十天后补齐的历史日；
  - `testTopicRunningOverThirtyDaysIsProposedOnlyOnce`：连续 41 天，分两批看完；身份起始日是 09-10，不随窗口滑；驳回后往后延不再提；
  - `testOmittedOrHandEditedDeadlineFollowsTheText`：漏填期限、只改期限、审计台手改日期；
  - `testInvalidHandwrittenDeadlineIsReplacedNotWinning`；
  - `testHandledExpirySurvivesProposalPurge`：历史提案清掉以后；
  - `testModelTimelineDedupesBySourceNotPath`：模型换路径不重提，断开后新段再提；
  - `testModelUsingTwoTargetsForOneTopicIsAskedToUnifyOnce`：模型跨来源重复。
- live 方法跟着新接口改（`Source(history:fresh:)`、`modelDays`），打印模型的依据日期和来源身份。

### 5.3 新增的边界和风险

- **第一次跑会看全部历史**：升级后进度是空的，A4 全部历史日记录都算没看过，一次 31 天、从最早的看起。历史上连续出现过的话题会陆续提出来（每次最多 maxTopics 条）。这是「没看过的都要看」的直接结果，粟粟要不要接受，需要车头确认。
- **状态文件读坏了当空**：进度和已处理身份都会重来，可能重提。
- **已处理状态只增不减**：只记字符串，长期会慢慢变大，没清理。
- **读全部月文件**：每天自动那次读一遍全部 timeline 月文件（一月一份），时间长了会变慢，没做增量。
- **第 10 / 11 段**：方向的 `basis` 现在是来源身份（「A4「词」自 日期 起连续」「页 路径 · 有效到 日期」）。复制 / 改写方向必须带上，`wiki/.sort/discovery.json` 不能当垃圾清掉。
