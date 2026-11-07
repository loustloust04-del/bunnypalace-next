# C2/C3 v2 · 第 9 段复盘：写作者换新稿

范围：`plan-memory-c2c3-v2-rev5.md` §2 第 9 段，以及 todo「提交 9」。基线 HEAD 是 `03d87775b`，开工时工作区是干净的。按实现单执行：没做任何 git 写操作，没开模拟器，没碰设备，没跑真端点。live 方法 `testWriterNewDraftPagesLive` 交给车头在 😷 iPhone 14 上跑，**这里没有冒充已经验过**。

## 0. 做了什么

1. **换提示词**
   - 新稿第 3 部分写进 `CatalogPrompts.pageRules(names:seed:)`（`CatalogWriter.swift:613`）和 `itemFormat(names:)`（`:697`）。`itemFormat` 原来是 static let，里面留着字面的 `{u}`，现在改成按名字生成。
   - 日常写手（`CatalogWriter.systemPrompt`，`:824`）、手动 agent（`CatalogAgent.swift:346-349`）、种子正文（`CatalogSeedTask.swift:639`）三处共用这一套。
   - 改写的地方：
     - 示例里的「小鹿 / 她」全部换成 `names.user` / `names.char`，示例路径都带「楼层」支；
     - 页上不写「用户 / AI / 助手 / 她 / 他」，AI 的观察写「{c}认为」；
     - 出处保留 fragments + aline（层 / 窗口 / 段 / 原文 nodeId），种子是 sources；
     - 「」引号、judgment、covered、`covered_page`、single 都保留，single 补了一句「会变的状态不算」。
   - 主 plan 第 9 段原有的几条保留在规则里：不编日期、写「（时间未注明）」；归因不明不猜；未兑现的承诺不写成已兑现；事页的经过引用出处。
   - 页型（普通 / 行为模式 / 事 / 项目 / 主题）写明是写法建议，代码不按页型做任何检查。
   - 写手和 agent 输入里，「楼层提示词」的标注改成「权威底图：已有的写「详见人设」」（`CatalogWriter.swift:839`、`CatalogAgent.swift:355`）。
2. **一套提示词**：没有 `{model_tier}`，也没有按模型分支。
3. **代码硬查**（`CatalogChecks`，`CatalogWriter.swift:508`），四项：
   - 「现在」里有 `-` `·` `●` `▪` 开头的行；
   - 记录正文超过 30 字。不算开头的日期或「日期未注明」、代码接的「（出处：…）」、只写日子的括号、只写碎片编号的括号，空白也不算；
   - 关系不在四种之内，包括新开页里的连线和单独的 link 条目；
   - 想改已有记录行：类型名带 record 的未知类型（比如 `rewrite_records`）。解析器原本就不收这类条目，现在多了一次重写。

   怎么处理：
   - 解析时把没过的项写进 `Parsed.checks`（定位 + 哪项），同样的话挂在对应条目的 `WikiProposal.Item.checks` 上（`WikiProposal.swift:142`）。
   - 收不进页的两种（坏关系的连线、改旧记录的条目），说法原样挂到同一页的第一条条目上；同页没有条目就挂到第一条（`CatalogWriter.swift:427`）。
   - 日常写手（`:895` 起）：不过就重写一次，回灌里写明哪项、在哪儿，并附上上次交的原文。重写还不过、没回、或交了坏 JSON，都用没过的那一份。原来格式错误的 3 次重试照旧。
   - 手动 agent（`CatalogAgent.swift:640`）：submit 回执打回一次，不是最后一轮才打回。
   - 种子交页（`CatalogSeedAgent.swift:344-350`）：每个目录项打回一次，记在 `CatalogSeedTask.checkRetried` 里（`CatalogSeedTask.swift:270`），续跑之后不会重复打回。
   - 审计台：条目下面用红色小标题列出「写手交稿时没过的检查（重写一次还没过）」（`WikiProposalViews.swift:395`）。不丢条目，不截字。
   - 下面三样判不准，只记进整理记录（`CatalogChecks.soft`，`:569`；`CatalogWriter.recordChecks`，`:971`），三条路都记：
     - 钩子里没有「当 / 时」；
     - 「现在」里没有「自 / 到 / 详见人设 / 未注明 / 基于」或日期的句子；
     - 记录以名字、「她 / 他 / 我 / 用户 / 助手 / AI」开头，可能不是动词开头。
4. **种子**：用同一套 `pageRules(seed: true)`，只有一处不同，把「只写增量 / 详见人设」换成「人设写过的也完整写，不写详见人设」。种子提示词里原来重复的那段页面规则删了。种子示例里有一条带主语的记录（「日期未注明 {u}收藏…」），改成了动词开头。
5. **第 8a 段的行为不变**：「【整理分组】」那段说明和各页全文、分组 covered 必须写 `covered_page`、本机模型放不下页全文就报错，都没动；对应的 8a 测试全部通过。

## 1. 测试

- 基线：30 套 420 测，0 失败。
- 改完：同样 30 套 429 测，0 失败；PromptRealPathGolden 和 InspectorRealPath 都通过，**金样没变，没有 RECORD**。
- 新增 9 条：
  - `CatalogWriterTests`：
    - `testRecordLengthCountsOnlyTheBodyNotDateOrSources`
    - `testEachHardCheckIsCaughtAndPassesAfterOneRewrite`：四项各一条坏输出，被抓到、回灌写明定位、重写后通过、不留标记
    - `testFailingTwiceStillDeliversWithFlagsAndNothingCut`：第二次还坏、交坏 JSON、没回三种情况
    - `testUnstorableFindingsHangOnTheSamePageItem`
    - `testSoftChecksOnlyGoToTheRunRecord`
    - `testDailyAgentAndSeedShareOneSetOfPageRules`：只查三处是不是同一套、示例里没有字面的 `{u}`，不钉措辞
  - `CatalogAgentTests.testHardCheckGetsOneRewriteThenFlagsStayIfStillFailing`
  - `CatalogSeedTaskTests.testSeedPageFailingHardCheckGetsOneRewriteThenGoesToReviewFlagged`
  - `CatalogDirectionTests.testDailyContentFailingHardChecksTwiceReachesReviewFlagged`：从自动方向到批正文走一遍，提案存盘带着标记，批了原样落页
- 删除：无。旧测试里没有钉写手提示词措辞的断言。
- live：`MemoryPalaceIOSTests/CatalogLiveSmokeTests.testWriterNewDraftPagesLive`。用虚构底图和碎片写两页，一页「楼层/人/豆包」，一页「楼层/岚舟/行为模式/赶稿」。打印模型原文、整页、条目上的标记、硬查和只记日志的结果，只断言调用成功。

## 2. 边界情况

- **本机模型会截掉系统提示**：写手系统提示从约 2500 字涨到约 5400 字，`LocalChatProvider.systemBudget` 是 3000，本机路线会截掉尾部。
  - 已经做的：输出格式挪到了页面规则前面；截掉时整理记录里会记一节「本机模型截了系统提示」（`CatalogWriter.swift:881`）。
  - 还在的问题：会丢掉后半截写法（记录、连到、新旧、清单）。没有报错拦下，要不要拦交车头定。
  - 手动 agent 走 `AssistantLocalBackend`，那条路的截断没查。
- **列表行判断按行首字符**：「-5 度也晨跑」这种以负号开头的句子会被当成列表行，概率低，没处理。
- **30 字按 Swift Character 数**，英文单词按字母算。英文多的记录容易超，会多一次重写或多一个标记。
- **她改过的条目**，checks 照旧挂着。标题写的是「写手交稿时」，不会重算。种子草稿在文件库里显示时，没有展示 checks。
- **重写附上上次交的原文**，请求会变长。分组方向下各页全文本来就大，再加一份输出，离上限更近；本机放不放得下只在第一次请求前查过，重写那次没再查。
- 手动 agent 在**最后一轮**交出没过的稿子，就直接带标记收下，不再打回（照「最后一轮不再打回」的老规矩）。

## 3. 与第 7 / 8b / 10 段的交互风险

- **第 7 段 A4**：规则里写「事页的经过引用出处」。A4 改成一天一条之后，`aline` 里 A4 的出处字段（现在是 window + 层）要跟着改，`itemFormat` 的示例也要一起改，不然模型会按旧格式引用 A4。
- **第 8b 段 valid_until**：现在「到 YYYY-MM-DD」只是写在正文里的时间锚。8b 加结构化 valid_until 后，要决定写手是另交一个字段，还是代码从「（到 …）」里解析。`CatalogChecks.recordBody` 已经把「（到 日期）」排除在 30 字之外，解析时可以复用同一个正则。
- **第 10 段 Faithfulness / Coverage**：
  - checks 和 dropReasons 是两套：dropReasons 是丢了的，checks 是没丢、带标记的。坏关系和改旧记录两样两边都有，第 10 段汇总时别重复计数。
  - 硬查不管出处。Coverage / Preservation 只记日志的项会挂在同一份运行记录里，章节名不同（「只记日志的检查」和第 10 段的诊断），要统一的话第 10 段来做。
- **`CatalogItems.Parsed` 加了 `checks`**，种子的 `CatalogSeedTools.page` 会把不是这一页的条目过滤掉，但 `parsed.checks` 里还留着它们的定位。第 10 段如果要按页汇总，要按 location 过滤。

## 4. 技术债

- 新稿自己的例子有几处没有时间锚（核心三步的「线」例、行为模式的路径）。普通页的猫例补上了锚；核心例子照新稿保留，和「每句带时间锚」略有矛盾，等测试台比。
- ~~新稿第 3 部分末尾按类型给了完整 JSON 页例，这次没全搬~~ → 第二轮返工已补齐六组（见 §6.1 第 7 条）。
- 「改已有记录行」用「类型名带 record」来认，属于字面判断。模型如果用别的类型名改记录，只会按「不支持的条目类型」丢掉，不会重写。
- live 只覆盖普通页和行为模式页两种。主 plan 第 9 段要求的「同一底图下增量 / 共存 / 冲突 / AI 观察 / 未兑现承诺、种子底图事实完整」这套模型行为矩阵，单测只验了管线（同一套规则、解析、标记），模型照不照做要靠 live 或以后的测试台。
- live 方法在 `MemoryPalaceIOSTests` 里，这次 `build.sh mask` 已编过测试包（TEST BUILD SUCCEEDED，只编不装）；方法本身没跑。
- 说明书（`manual/facts/modules/memory-settings.md`）没同步审计台新增的「没过的检查」一栏，留给收口时做。

## 5. 返工（astra 审 460960b89：5 条 P1、6 条 P2，车头逐条裁定）

本节和上文有冲突时以本节为准。上文已作废的几条：第 0 节第 3 条里「改旧记录靠类型名带 record 来认」「坏关系的说法挂到同页第一条条目上」「审计台写死『重写一次还没过』」；第 2 节第 1 条「截掉了只记一节、不拦」；第 4 节第 2、3 条。

### 5.1 逐条怎么修（行号以当前工作区为准）

1. **P1 本机截系统提示**：日常写手发请求前，系统提示有一点送不全就抛 `CatalogWriterError.promptDoesntFit`（`CatalogWriter.swift:929`）。报错是人话，由 `shortfall` 生成（`:746`），说明系统提示共多少字、当前模型只收前多少字、从哪一节中间断开，以及后面整节没送到的各节名和字数。不裁剪，不换模型，不发请求。agent 和种子走 `AssistantLocalBackend`，没动。
   - **后果，车头要知道**：写手系统提示约 5400 字，本机只收 3000 字（`LocalChatProvider.systemBudget`），所以**选本机模型时，日常写手现在每次都会报这个错**，等于本机日常写手不可用，直到提示词变短或预算放大。
   - 8a 的 `testGroupFullTextSurvivesRealLocalAssemblyOrFailsInPlainWords` 原来用真实的 `CatalogLocalTrim.apply` 走全程，现在第一步就会在系统提示上失败。改成「系统提示原样过，用户文本按本机真实裁法留尾」，只验页全文那一层。本机系统提示的失败另有测试。
2. **P1 每次请求都重查容量**：`overflow`（`:912`）在每一次真正要发的请求上都查一遍，查两样：给过全文的页还在不在；第一次实际送到的那段原料有没有被挤掉。
   - 重写请求放不下：不发，交第一稿，`revision` 写明原因和各自字数（`:962`）。
   - 格式重来的请求放不下：没有可审的稿，抛 `retryDoesntFit`。
3. **P1 修订用不了就交上一份可审的稿**：
   - **日常**（`:948` 起）：第二次调用出错（`:976`）、没回、交坏 JSON、放不下，都交第一稿，并写明原因；第二稿还没过就交第二稿，标「重写了一次，还有没过的」（`:1005`）。取消照旧抛出。
   - **agent**（`CatalogAgent.swift:521` 起）：
     - 「全部被扔」和「没过检查 / 格式诊断」共用一个 `revised`，打回时保存第一稿 `firstDraft`。
     - 修订那次截断、格式坏、没有能用的条目，当场交第一稿（`:660`）。
     - 之后出错、被预算拦下、到顶没交，`finish` 里交第一稿（`:551`）。取消不交。
     - 修订机会：收尾提醒从第 N 轮提前到第 N−1 轮（`:629`、`:750`），在原来的 N 轮上限之内给修订留一轮。
     - 最后一轮才交出没过的稿，照收，标「最后一轮交的，没有机会重写」（`:691`）。
   - **种子**（`CatalogSeedAgent.swift:344-366`）：打回时把第一稿的原参数存进 `CatalogSeedTask.revisionDrafts`（`CatalogSeedTask.swift:270`）。第二次还是坏 JSON 或没有有效条目，就把第一稿重新校验后交成提案，带标记和原因，不再要求重交。
4. **P1 坏关系不丢**：关系不在四种之内的连线，原样存进 `WikiProposal.HeldLink`（来源页、目标页、关系原文、why、原因），挂在提案的 `heldLinks` 上（`WikiProposal.swift:76`、`:176`）。
   - 解析在 `hold`（`CatalogWriter.swift:357`）；新开页里的坏连线和单独的 link 条目都走这里，不算扔掉。
   - 审计台把它显示在来源页那一组下面；来源页没有条目时，单独一组「没收进页的连线」（`WikiProposalViews.swift:298-312`、`:445`）。只展示，不执行，不可编辑。
   - 整稿只剩坏连线也照样建提案（`CatalogRunner.swift:506`）。种子只留来源是本页的。
   - 不再挂到别页的条目上。
5. **P1 single 三条件**：共用提示里写明三条（几乎不变、自己就完整、不属于任何已有页的话题范围），并加一个「已有页优先」的例子：有身体页时，「血型是 O 型」归那一页（`CatalogWriter.swift:725`）。没有加路由表。
6. **P2 30 字口径**（`:525` 起）：
   - 开头日期只认 `YYYY-MM-DD` / `YYYY-MM` 和「日期未注明」，后面不能紧跟数字或连字符。
   - 正文里只剥三种：「（到 日子）」「（自 日子 起）」「（日子）」和碎片编号括号。「（1234）」这种说不准的数字括号算正文。
7. **P2 列表行**：标记后面跟空格（含全角空格）才算，所以「-5 度」「●减糖」都不算，不触发重写（`:528`）。
8. **P2 改旧记录**：删掉了按类型名猜意图的 `recordEdit`。改成两类格式诊断，都写进 `Parsed.formatIssues`（`:131`、`:320`、`:434`），条目照旧不收，但和硬查共用那一次修订：
   - 不认识的条目类型，诊断里写明只有哪五种、记录只追加；
   - 条目带了它不收的字段，比如 rewrite_now 带了 records。
   落页接口本来就没有改旧记录的入口。
9. **P2 append 映射**：「更新已有页」写明：补充的新信息改变了现在的样子，就同时交 rewrite_now 和 append，旧记录不动（`:704`）。
   - ~~新稿末尾整页 JSON 正反例只节选了部分~~ → 第二轮返工已补齐六组（见 §6.1 第 7 条）。
10. **P2 审计台标签**：标题改成「写手交稿时没过的检查（实际修订状态）」，状态取自提案的 `revision`。她改过带标记的条目，`checksEdited` 记一笔，标题后面加「· 编辑后未重新检查」（`WikiProposal.swift:304`、`:318`；`WikiProposalViews.swift:412`）。
11. **P2 测试**：见 5.2。

### 5.2 测试

- 结果：同样 30 套 436 测，0 失败；`PromptRealPathGoldenTests` 和 `InspectorRealPathTests` 都通过，**金样没变，没有 RECORD**。
- 删掉 / 改掉的：
  - `testUnstorableFindingsHangOnTheSamePageItem`（它钉的是「坏关系挂到别的条目上」）；
  - `testDailyAgentAndSeedShareOneSetOfPageRules`（只证明字符串拼接）；
  - `testItemValidation`：「替代」那条连线从「扔掉」改成「留在提案上」，dropped 9 → 8；
  - `testRoundCapForcesSubmitAndMarksIncomplete`：收尾提前一轮，轮数 3 → 2；
  - `testRunRecordPreservesEveryRoundFullTextParsingFeedbackAndLogLinks`：上限 6 → 7，保持原来的剧本不变；
  - 8a 的本机全文测试：改法见 5.1 第 1 条。
- 新增 / 重写：
  - `CatalogWriterTests`：
    - 口径与列表行，含工号括号、日期边界、负号；
    - 三项硬查加两种格式诊断，各一条坏输出，重写后通过；
    - 修订用不了的四种情况（还没过 / 交坏 / 没回 / 出错），外加取消照旧抛出；
    - 坏连线留在来源页，整稿只有它也留下；
    - 重写请求放不下就不发，交第一稿；
    - 本机系统提示放不下就报错，零请求；
    - 判不准的三样只记日志；
    - 改过带标记的条目，记「编辑后未重新检查」。
  - `CatalogAgentTests`：
    - 硬查重写，含修订状态；
    - 修订用不了的五种情况（出错 / 被拦 / 交坏 / 截断 / 交空），都交第一稿；
    - 「全部被扔」和硬查共用一次修订，不会有第三次提交；
    - 收尾提前一轮，留给修订。
  - `CatalogSeedTaskTests`：
    - 第二稿还没过时的修订状态；
    - 修订那稿没有能用的条目，交第一稿，不再要求重交。
  - `CatalogDirectionTests`：
    - 两次都没过，提案带修订状态；
    - 整稿只剩一条坏连线，也照样建提案。
- **live** `testWriterNewDraftPagesLive` 改成断言每页交出了条目，分三部分：
  - ① 普通页和行为模式页；
  - ② 语义矩阵：一页已有页，同一底图下五条碎片，分别是增量、共存、冲突、{c} 观察、{c} 未兑现承诺；
  - ③ 种子：只用人设一份原料，跑目录 → 批 → 写页，打印正文。
  只打印，不对模型内容做断言。

### 5.3 剩下的风险

- **本机日常写手现在必然报错**（见 5.1 第 1 条）。要恢复，得把写作规则压到 3000 字以内，或者给 C3 单独放大本机系统预算。两样都超出这次范围，交车头定。
- **agent 收尾提前一轮**：上限 N 时，搜索最多 N−2 轮。模型在第 N−1 轮交得干净，就少用一轮。
- **agent 被预算拦下但有第一稿时**，按「交第一稿」处理，不再标「被拦」。所以 `report.blocked` 不会因为这一次置上，后面的主题还会各自过闸。
- **整稿只剩坏连线时**，提案里没有可批的条目，状态直接显示「处理完」。连线只能看，要她手动去页上补。
- `heldLinks` 和 `revision` 是提案级字段。她编辑条目不会改动它们。

## 6. 第二轮返工（astra 审 08ad0c1c9：2 条 P1、5 条 P2；车头裁定以收窄、合并为主）

本节和上文冲突的，以本节为准。HeldLink 和 formatIssues 两套机制合并成了一套，旧名字都不再使用。5.3 的「被拦不再标被拦」「整稿只剩坏连线直接显示处理完」两条已作废。

### 6.0 一句话规则（三条路共用）

每一页最多修订一次。修订之后只要不是被取消，交上来的结果用不了（坏 JSON、截断、请求失败、被预算拦、交上来的东西全被扔掉），就交上一份可审的稿，标明原因，不发第三次请求。

- 修订状态的文字三条路共用：`CatalogChecks.revised` / `fellBack` / `noChance`（`CatalogWriter.swift:590-592`）。
- 「可交付」只用一个判定：`Parsed.deliverable`（`:138`），即有条目、有没收进页的内容，或者有合法的 covered / single。

### 6.1 逐条怎么修

1. **P1 日常第二稿不可交付**：修订稿能解析但 `deliverable` 为假时，退回第一稿，原因写「那次交的没有能用的内容（扔掉的原因）」（`CatalogWriter.swift:1043`）。
2. **P1 种子保底**：统一走 `deliverRevisionDrafts`（`CatalogSeedAgent.swift:319`）。它把已存的第一稿按原路径交成提案，原因由 `submitPage` 的 `fallback` 参数打上（`:373`）。
   - 触发点：
     - 工具入口，交页时截断或参数是坏 JSON（`:235`）；
     - 被预算拦下（`:157`）；
     - provider 出错（`:177`）；
     - 页内，修订稿没有能用的条目。
   - 取消照旧不交。
   - 原来断言「504 后没有提案」的测试改成三种情况（出错 / 坏参数 / 交空），都断言交了第一稿、不再要求重交。
3. **P2 预算状态**：agent 修订被拦时交第一稿，但 stop 仍是 `.blocked`（`CatalogAgent.swift:560`）。runner 的 `.blocked` 分支先把第一稿交成提案，再置 `report.blocked`，返回 continues = false，后面的主题停掉。汇总写「被拦：…，后面的主题停了」（`CatalogRunner.swift:889-897`）。
4. **P2 纯留存重试**：
   - 修订用过之后，下一份就是最后一份（`CatalogAgent.swift:665`）：能交付就收下，标「重写一次后通过 / 仍有没过的」；用不了就交第一稿；没有第一稿就到此为止。
   - 修订之后只回文字，也直接收尾（`:632`）。
   - 空提交的判定改用 `deliverable`，已经包含留存内容（`:707`）。
5. **P2 合并成「没收进页的内容」**：
   - 结构：`WikiProposal.Unapplied` 记来源页、原始操作原文、原因和位置（`WikiProposal.swift:76`），挂在提案级的 `unapplied` 上。
   - 三种都进这一个列表，不再算扔掉：非法关系（新开页里的连线和单独的 link 条目）、未知操作、非法字段。
   - 原文从写手输出里原样取，按 sortedKeys 序列化（`CatalogWriter.swift:287`）；取不到就退回到用字段拼的说明。
   - 审计台用同一个组件 `unappliedRow` 展示（`WikiProposalViews.swift:460`）：有来源页的挂在那一页的组下面，没有的单独一组。只展示，不执行。
   - 修订状态显示在头部「修订：…」（`:284`），有没有条目都显示。条目标签只留「写手交稿时没过的检查」，被她改过的再加「编辑后未重新检查」。
6. **P2 生命周期**：
   - 新增 `unappliedSeenAt` 和 `unreadCount`（`WikiProposal.swift:180-191`）。
   - 有没看过的留存内容时，status 不算 done：只有留存内容的提案算 `.pending`，条目都处理完、留存还没看的算 `.partial`。
   - 角标 `pendingItemCount` 把没看过的条数算进去；状态文字显示「待阅 N 处没收进页的内容」（`WikiProposalDisplay.swift:116`）。
   - 她点「知道了」才算处理（`WikiProposalViews.swift:326`，走 `WikiProposalReview.acknowledgeUnapplied` 加锁，`WikiProposal.swift:283`、`:543`）。30 天从那一刻起算。
7. **P2 示例补齐**：新稿六组整页 JSON 正反例全部补进「各类页整页正反例」（`CatalogWriter.swift:723`）。
   - 只改了三处：名字（小鹿 / 她 → {u}）、路径（加「楼层」支）、种子版身体页正例去掉「（详见人设）」。
   - **偏离一处**：行为模式例子里的 `\"来不及了\"` 改成了「」，和本项目「引用别人的话用「」」的规则保持一致。
8. **live 修订状态**：修订后通过，现在如实标「重写一次后通过」（日常 `:1043` 起、agent `:665`、种子 `revised()`）。整理记录里单独记一节「修订」（`:1092`）。
9. **live 冲突对人设**：
   - 和人设矛盾时：两条都留、各带日期，「现在」按新的写；人设不是 wiki 页，不连线（`:658`）。
   - 冲突的另一方在别的页上，才连「矛盾」；另一方是人设，或者就在这一页上（旧说法、旧记录），不连线，也不连回自己（`:718`）。
10. **本机模型**：照旧报错。C3 页模型那一行，选了本机时加一行小字「本机模型放不下写作规则，日常整理会报错」（`MemoryWriterPages.swift:552`）。没加新设置。

### 6.2 测试

- 结果：同样 30 套 439 测，0 失败；PromptRealPathGolden、InspectorRealPath 都通过。**金样没变，没有 RECORD**。
- 新增：
  - 合并后的留存内容：`testUnappliedContentKeepsTheOriginalOperationAndItsPage`、`testUnappliedOnlyProposalStaysUnreadUntilAcknowledged`；
  - 日常：修订稿全被扔掉时退回第一稿；
  - agent：`testUnappliedOnlyTwiceIsDeliveredWithoutAThirdRequest`、`testBudgetBlockDuringRevisionDeliversTheFirstDraftAndStopsLaterTopics`；
  - 种子：`testSeedRevisionThatCannotBeUsedDeliversTheFirstDraft`，覆盖出错 / 坏参数 / 交空三种。
- 改掉的旧断言（钉的是已改掉的行为）：
  - `…AreDroppedWithRepairHint` 改为 `…AreKeptAsUnappliedWithRepairHint`；
  - `testMalformedNested…`：dropped 11 → 10；
  - `testItemValidation`：dropped 8 → 6，留存 3 项；
  - `testAllDroppedAllowanceIsNotResetByEmptyRepair` 改为 `testAfterTheRevisionAnEmptySubmissionIsFinal`；
  - run-record 测试：把「全部被扔」挪到最后，其余全文断言不变；
  - 各处修订状态改成新的文字。
- live 方法只把两处打印里的 heldLinks 改名成 unapplied，好让它编译过，别的没动。

### 6.3 剩下的风险

- **种子工具入口遇到坏参数时，读不出是哪一页**：会把所有等修订的页都交第一稿。同一轮里另一页的修订如果稍后才到，那一页就拿不到修订了（概率低）。
- **「修订后下一份就是最后一份」只管修订之后**：修订之前的格式坏、截断、交空提醒保持原样，没有并进这一次修订。
- **只有留存内容的提案没有可批的条目**：她只能点「知道了」，在审计台里改不了关系；要用的话得去页上手动补。
- **本机日常写手仍然不可用**：C3 页已经加了提示。
