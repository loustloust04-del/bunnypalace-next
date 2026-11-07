# C2/C3 v2 · 第 11 段复盘：新用户三问接进引导，基础页两批审

范围：主 plan `plan-memory-c2c3-v2.md` 第 11 段（实现 1–3、旧数据、验收、影响文件）、「粟粟已定」Q11、rev5 第一性原理（用户类挂 `楼层/{u}/`、不预设子页）。基线 HEAD `5c215cc71`，工作区干净。按实现单：没做 git 写操作，没开模拟器，没碰设备，没跑真端点。live 方法交车头在 😷 iPhone 14 上用 Haiku 跑，UI 走查见 [走查单](walkthrough-memory-c2c3-v2-p11.md)，**这里都没有冒充已验**。

## 0. 做了什么

1. **三问接在确定目标楼层之后**（`Services/Assistant/XiaoyaScript.swift`）
   - 引导里建了 Ta（陪伴起名 / 酒馆导卡）：楼层建好之后、出口卡之前问，答案落 Ta 那层。为此把出口卡从 `tavernDone` / `companionDone` 拆成 `tavernExit` / `companionExit` 两个节点，出口卡、「去找 X / 继续问我」的含义没变。
   - 没建 Ta（小白跳钥匙、小白不建 Ta、技术线）：收尾 `end` 之前问，答案落当前楼层。
   - 保持神秘不问；走完引导的老用户不补问；设置「?」→ 新手引导（主动重走）会再问一次。
   - 实现是一个 `detour`：主线要去 `tavernExit / companionExit / end` 时，没问过就先去 `survey`，记下回哪、落哪层、预填的称呼。
   - 一张卡三格（想让我叫你什么 / 平时在做什么（工作 / 学习 / 创业）/ 有没有我应该知道的），「就这些」或「都跳过」。称呼预填默认称呼或起名 / 挑头像卡填的名字。
2. **答完走种子同一套两批**（`Services/Wiki/CatalogSurvey.swift`、`CatalogRunner.swift`、`CatalogSeedTask.swift`）
   - `CatalogSeedEntry.survey`：同一个 `CatalogSeedTask` / `CatalogSeedAgent` / 审计台，目录 → 批 → 逐页写 → 正文批。没有问卷引擎，没有新审批。
   - 答完先把答案落成目标楼层里一个还没开跑的种子任务（`CatalogSurvey.create`），能跑就 `resumeSeed` 排队；不等模型，引导照常往下走。
   - 第一次真跑时才定原料清单和开场、绑模型（`resumeSeedCancellable` 里 `fresh` 那段），先存任务再问模型。
   - 提示词另写一份三问版：原料只有答案，她本人的页放 `楼层/{u}/`，类写「用户」，页名自己起，不预设子页，页要少，不推测；目录项、页条目格式和写作规则跟种子共用（`CatalogSeedPrompts.items`）。
   - 不清旧种子、不做备份搬迁、不写 `.seed-state.json`（种子完成标记）；完成只记在任务快照里。
3. **出处只认这次的答案**
   - 原料：每条答案一份（路径 `问卷/称呼` 等，层 `问卷`），必须读，是唯一能当出处的；楼层 wiki 的各层索引和页也在白名单里，只用来看有什么、要更新已有页先读它。
   - 出处登记走第 10 段的统一入口 `CatalogSources.addFile`，`cite.layer = 问卷`、`cite.name = 称呼 / 在做什么 / 应该知道的`；记录行显示「（出处：问卷「在做什么」）」，审计台显示「问卷 · 在做什么」。
   - 目录校验（`CatalogSeedTools.checkDirection`，三问分支）：原料只能是 `问卷/…`；路径是已有页但没读过，拒（「先 read 它再列进目录，只能交更新」）。文件库 / 审计台改目录也过这一道。
   - 任务绑目标 `profileId`（落进那层的 `wiki/.proposals/<任务 id>/task.json`），答案存在任务里；不读 Prompt、CC、小芽历史。
   - 全空 / 全跳过：不建任务、不留记录、不交（剧本那边直接记 `empty`）。
   - 没有能用的模型 / C3 关着：任务停在「还没生成：…可稍后在这里点「继续这个种子任务」生成」，C3 页种子那节照常显示，小芽说「可以稍后生成」，引导照常走完。
   - 中途恢复：剧本只多存问过没有、回哪、落哪层、预填称呼、答案、任务 id、结果；任务 id 先落 script.json 再交，重放用同一个 id，目录那边同一个 id 只建一次、不覆盖答案。
4. **旧数据**
   - 旧引导完成状态不变；走完的人不补问。
   - 升级前正停在旧出口卡上的进度（`tavernDone` / `companionDone` 最后一拍），恢复时挪到新的 `*Exit` 节点接着等（`resumable`）。
   - 称呼：三问答的名字写目标楼层称呼 + 默认称呼（同起名卡，`OnboardingFloorFactory.applyUserName`），不回写已有的记忆、wiki。
   - 已有同名页只出更新提案（追加记录 / 改现在 / 连线 / 改钩子），整页新开被扔，批之前一个字不动。

## 1. 边界情况

- **两个种子任务同时开着**：三问不看「已有没完成的种子任务」，直接建。C3 页种子那节原来只看最新一个任务，这次改成先显示还开着的（新的在前），都结束了再显示最近一个（`MemoryWriterPages.swift` `CatalogSeedSection.reload`）。所以两个都开着时先看到三问那个，它结束后旧的那个和它的「继续 / 放弃」才露出来；旧任务的目录一直在审计台能批。反过来，三问任务开着时，「从人设生成 / 从 CC 播种」会被「还有一个种子任务没完成」挡住。
- **重走多次**：每次重走是新的任务 id，会多一个三问任务。
- **能不能马上跑的判断**：C3 关着、所选模型会回退（本机模型没下 / 在后台）、所选远端模型的卡没开或没钥匙 → 稍后生成。不需要钥匙的服务商（本地中转之类）会被误判成「没有能用的模型」，任务停着，点「继续」照样能跑（续跑不查钥匙）。
- **跑的时候报错**（钥匙错、网络）：任务停在「第 N 轮出错」，C3 页能继续；小芽那句已经说了「整理好会先给你看」，不会改口。
- **称呼**：每次交都会写一次默认称呼和目标楼层称呼（同一个名字就不动楼层）。预填没改也照写——如果目标楼层原来是兜底的「你」，会被改成预填的名字。
- **答了称呼，楼层名字之后又在设置里改了**：wiki 里已经写的「楼层/<旧名>/…」不跟着改名（rev5：不迁旧页）。
- **wiki 很大的老用户重走**：开场只列各层索引，页都在白名单里按需读；交目录前只要求读完答案。但原料清单（白名单）还是全量扫了一遍 wiki。
- **三问页数**：「页要少」只写在提示词里，代码不设页数上限（种子不设人为上限的老规矩）。
- **审计台批目录**：在当前楼层的审计台批。目标是 Ta 楼层时，要切过去才看得到。

## 2. 与后续（读侧 / 试写台）的交互风险

- **读侧**：三问写出来的页和别的页一样走 wiki 注入 / Recall；`楼层/{u}/` 下的页靠标题 / 触发词命中，没有为「本人页」开特例。第一次聊天时如果三问的正文还没批，读侧什么都拿不到，这是两批审的代价。
- **新层名「问卷」**：出处显示、`CatalogSources.label`、`WikiProposalDisplay.citeText` 都接了。读侧如果以后要按出处层过滤 / 加权（原文 > A 线 > 碎片），要决定「问卷」放哪一档；现在没有任何检索按它排序。
- **试写台**：三问的系统提示是 `CatalogSeedPrompts.system(names:entry: .survey)`，和种子共用条目格式与写作规则（`items`）。试写台要比三问效果时，直接拿这个函数；改共用部分会同时影响种子。
- **剧本节点**：多了 `tavernExit / companionExit / survey / surveyDone`。以后再往出口卡附近加拍子，要记得出口卡已经不在 `*Done` 里了；`XiaoyaScriptTests.testResumableKeepsAnswerableWaits` 钉的是新布局。
- **C3 页**：三问任务出现在「种子」那节（标签「新用户三问」），完成后那里显示的「种子完成」时间仍只看种子的完成标记，不会因为三问完成而出现。

## 3. 技术债

- `XiaoyaScriptWorld.survey` 是可选的，`nil` 就不问。线上一定给；旧的剧本测试夹具没给，所以那些测试走的是「不问」的老路径，三问的流程只在 `XiaoyaSurveyTests` 里测。
- 「没有能用的模型」只按卡开没开、有没有钥匙判断，没有共用的「这个服务商要不要钥匙」口径。
- 两个开着的种子任务时 C3 页一次只显示一个（见 §1），没加列表。
- 答案只存在任务快照里（`.proposals/<任务 id>/task.json`）和整理记录开头那一节；文件库里没有单独的「问卷」文件夹，「答案出处可查」靠审计台的「这次的整理记录 ›」。放弃 / 结束后 30 天，任务和记录一起清掉，已入库页的记录行里出处文字还在，但点不回原答案。
- 说明书 `scripts/manual` 没跑（同前几段）。

## 4. 偏离 / 拿不准

1. **称呼答案会改楼层称呼和默认称呼**。plan 只写「名字可以预填、不回写过去的事实」，没说答了要不要改称呼。「想让我叫你什么」答了不生效说不过去，我照起名卡的做法写了目标楼层称呼 + 默认称呼，不碰已有记忆。车头不要的话，删 `XiaoyaScript.swift` live 里那行 `factory.applyUserName`。
2. **问的位置**：建了 Ta 的线在出口卡之前问，没建 Ta 的线在收尾之前问；保持神秘不问。拆出口卡节点是为了「楼层建好之后马上问」，不是挪到收尾。
3. **一张卡三格**，不是三张卡。三格都能空，「都跳过」= 全空。
4. **三问不受「已有没完成的种子任务」限制**（见 §1）。
5. **wiki 页进白名单但不要求读**：三问交目录前只要求读完答案；改已有页必须先读那一页（代码查）。种子仍是全读。
6. 改了一条旧测试的断言：`XiaoyaScriptTests.testResumableKeepsAnswerableWaits` 原来钉「出口卡在 companionDone 第 3 拍」，改成新节点 `companionExit`，并加了「升级前停在旧出口卡上的挪到新节点」一条。`XiaoyaScriptTests` 的卡种类映射补了 `survey`。

## 5. 测试

- **新增** `MemoryPalaceTests/CatalogSurveyTests.swift`（8 条）：
  - `testAnswersBecomeOutlineThenApprovedPagesThenWikiCitingOnlyTheAnswers`：存答案不调模型、不绑模型 → 续跑出目录（三项全待批、只有一份提案、零页、不读 Prompt）→ 批两项驳一项 → 只写获批的、正文没批不落页 → 记录行「（出处：问卷「在做什么」）」、cite 能查回答案原话、审计台文字 → 正文批了才进 wiki → 任务完成、不写种子完成标记、整理记录里有答案。
  - `testOutlineMayOnlyCiteTheAnswers`、`testExistingSamePageOnlyGetsAnUpdateProposal`、`testExistingPageNotReadCannotBeListed`、`testBlankOrSkippedAnswersCreateNothing`、`testNoModelKeepsTheAnswersForLaterAndBindsTheModelOnTheFirstRealRun`、`testTheSameTaskIdIsCreatedOnceAndKeepsTheFirstAnswers`、`testSurveyLeavesOtherWikiDataAndOldSeedStateAlone`。
- **新增** `MemoryPalaceTests/XiaoyaSurveyTests.swift`（11 条）：陪伴线建好 Ta 后问、落 Ta 楼层、交一次再出出口卡；酒馆线问完「去找」照样切；小白不建 Ta 在收尾前问、落当前楼层、全跳过不交；没模型说「稍后生成」且不挡聊天；保持神秘不问；停在三问卡上重开原地等、卡丢了按记下的称呼重出；切到别的楼层后答，仍交到原目标；同一张卡答两次只交一次、交到一半被杀重放用同一个任务 id；走完的不补问、主动重走才问；卡 / 答案 / 进度编解码往返；称呼只写目标楼层和默认称呼。
- **改**：`XiaoyaScriptTests`（见 §4 第 6 条）。没删测试。
- **live**：`MemoryPalaceIOSTests/CatalogLiveSmokeTests.swift` `testSurveyOutlineThenPagesLive`（门控照旧，没 key 跳过）：虚构三问 → 目录 → 全批 → 逐页正文，打印目录和正文，只断言调用成功。

## 6. 验证

- 基线（`5c215cc71`，先 `xcodegen generate`）：mac `** TEST BUILD SUCCEEDED **`（`p11-base-mac.log`）；75 套 1044 测，1 个失败是 `MainThreadIOBudgetTests.testHintComposePreviewFlatAndWithinBudget` 删临时楼层目录没权限（`p11-base-tests.log`），和本段无关，最终那次跑过了。
- 最终：mac `** TEST BUILD SUCCEEDED **`（`p11-mac5.log`）；77 套 1063 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`p11-final2-tests.log`，含 PromptRealPathGolden / InspectorRealPath 金样原样，没有 RECORD）。iOS 应用（模拟器 destination）`** TEST BUILD SUCCEEDED **`（`p11-ios2.log`）；😷 测试包 `build.sh … mask` `** TEST BUILD SUCCEEDED **`（`p11-mask2.log`，只编不装）。
- 没跑：真端点 live、模拟器 / 真机 UI。

## 7. astra 返工（审 `b3198b254`：3 条 P2，车头全收）+ 车头 live 两处

基于 `4fb1a8f08`（`b3198b254` + 文档 `c2b5d75c2` + 合 master）。本节取代前文 §0 第 3 条的出处格式「问卷「在做什么」」、§1「不需要钥匙的服务商会被误判」那条、§3「答案只存在任务快照里」那条。行号以返工后工作区为准。

1. **【P2】出处回查不随清理丢**
   - 每次问卷先把原答案存成目标楼层的 `wiki/.survey/<任务 id>.json`（任务 id、楼层、答题日期、答题时间、三条答案），再建任务（`CatalogSurvey.swift:136`）。`.survey` 和 `.runs`、`.proposals` 同级，是隐藏文件夹：不进页列表、索引、文件库，30 天清理、整理记录清理都不碰它。同一个任务 id 只写一次。
   - 出处 cite 改为指向这份文件：`layer = 问卷`、`filePath = .survey/<任务 id>.json`、`name = 称呼 / 在做什么 / 应该知道的`、`day = 答题日期`（`CatalogSurvey.cite`，接在 `CatalogSeedTask.swift:532`）。
   - 记录行出处文字带日期和任务 id 前 8 位：「（出处：问卷「在做什么」2026-10-22#1A2B3C4D）」（`CatalogSurvey.label` :100，`CatalogSources.label` 走它）。多次重走出处名不重复。审计台小字「问卷 · 2026-10-22 · 在做什么」。
   - 只凭 wiki 页里那一行就能查回原话：`CatalogSurvey.resolve(出处那一项, wiki:)`（:106）。
2. **【P2】桥接模型不再被判成没模型**：`surveyBlocker`（`CatalogRunner.swift:1378`）改用 `ProviderManager.isUsable`（桥接卡看连得上、本机卡看下好没、示例卡不算、其余看钥匙），不再统一要钥匙。
3. **【P2】延期带原因、按原因给恢复提示**
   - `CatalogSurvey.Outcome.later(Blocker)`。`Blocker` 分五种：记忆总开关关着 / C3 关着 / 没有能用的模型 / 选的本机模型用不了 / app 在后台。每种都带「为什么」和「怎么恢复」（`CatalogSurvey.swift:41`）。
   - 任务停着时，C3 页种子那行写「还没生成：<为什么>。<怎么恢复>」；小芽说「现在<为什么>，可以稍后生成：<怎么恢复>」（`XiaoyaScriptLines.swift:48`）。C3 关着就叫她先去打开 C3，不再说「配好模型后点继续」。
4. **【live】不再出现「未注明」**
   - 答题日期就是来源日期。它写进每份答案原料（「答题日期：…」，`CatalogSurvey.materials` :124）、开场清单标题（`CatalogSeedTask.swift:687`）和三问系统提示（:644）：记录开头写答题日期，「现在」写「（自 答题日期 起）」，答案里说的相对时间按答题日期换算，不写「日期未注明」「时间未注明」。
   - 三问提示词里条目格式的例子也换成带日期的（`items` 加了 `now` / `record` 两个参数）。种子传原来那两句，种子提示词逐字不变。
5. **【live】不拆碎**：只改三问版提示词（:641）。同一件事只开一页；只够一句话的东西写进相关那页、不单开；另开页只限「能单独写出几句的项目或人」。没加代码阈值、没写死页数。

### 测试
- **新增** `CatalogSurveyTests.testRecordSourcesStillResolveAfterTasksProposalsAndRunRecordsAreCleaned`：走完两批、正文入库后，删掉 `.proposals` 和 `.runs`，从三页的记录行出处查回原答案（任务 id、答题日期、原话都对）。再答一次同一题：两次出处名不同，各查回各的。
- **新增** `CatalogSurveyRunnerTests`（2 条，同文件）：真的 `CatalogRunner.survey` 入口，用独立偏好域、真 `ProviderManager` 加一张没有钥匙的 CC 桥接卡、C3 选它。
  - `testBridgeModelWithoutAKeyStartsRightAway`：返回 `.started`，任务停在「读原料」等着跑。
  - `testClosedSwitchesDeferWithTheirOwnRecoveryHint`：C3 关 → `.later(.c3Off)`，记忆总开关关 → `.later(.memoryOff)`；任务备注和小芽那句都按原因给提示，关着时不排队。
  - 能跑时怎么排队通过 `survey(..., enqueue:)` 换成只记下来，不真发请求、不碰桥。
- **改**：
  - `CatalogSurveyTests`：主流程断言改成带日期的记录行和出处、cite 指向原答案文件；开场和每份答案带答题日期；没模型的备注按原因；假模型交的记录用答题日期开头。
  - `XiaoyaSurveyTests`：`.later` → `.later(.noModel)` / `.later(.c3Off)`，另断言小芽那句含恢复提示。

### 验证
- mac `** TEST BUILD SUCCEEDED **`（`p11r-mac2.log`）。
- 78 套 1066 测 0 failures、`** TEST EXECUTE SUCCEEDED **`（`p11r-full.log`）；PromptRealPathGolden / InspectorRealPath 金样原样，没有 RECORD。
- iOS `** TEST BUILD SUCCEEDED **`（`p11r-ios.log`）；😷 测试包 `** TEST BUILD SUCCEEDED **`（`p11r-mask.log`，只编不装）。
- live 没重跑（不跑真端点）；第 4、5 两条要车头在 😷 上用 `testSurveyOutlineThenPagesLive` 复看。

### 剩下的边界
- 出处查回只有函数（`CatalogSurvey.resolve`）和测试，界面上还没有「点出处看原答案」的入口；`.survey` 是隐藏文件夹，文件库里看不到。
- 「答题日期」按设备当地日历日算，不按记忆日 05:00 切。
- 同一天、同一题答两次，靠任务 id 前 8 位区分；8 位撞上的概率可以忽略。
- 拆不拆页只靠提示词，模型照样可能拆，靠目录审批挡。
