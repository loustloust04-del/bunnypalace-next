# review · thinking 回传（思考块收全 + 当轮原样回传）

> plan：[plan-thinking.md](plan-thinking.md)（粟粟 10-15 批 Q1–Q9「都按推荐」）。
> 验收说明：`~/Desktop/cc-rp/API链路/thinking-验收.md`。
> 工位 backend-2，基于 b6e149e2a（已含 #093 合并后的 master 73729f71a）。执行者只改工作区、不提交；逐项文件清单交车头逐项提交。

## 做了什么（对应 plan §15 执行清单）

| 步 | 内容 |
|---|---|
| 1 | 不用 merge（工位已含 master）。`ModelLineage.thinksByDefault / defaultEffort / displayDefaultOmitted` |
| 2 | `AnthropicProvider` 按 index 原样记全部内容块（`ReplyBlock`：思考拼 `thinking_delta`、`signature_delta` 填签名、redacted 整块、正文含 `citations_delta`、tool_use / server_tool_use 的 input 分片在 `content_block_stop` 解析回块里）；收到 stop 才算完整，思考块还要有签名 |
| 3 | 非流式 `parseNonStreamBody` 同一份 `replyBlocks` |
| 4 | `output_tokens_details.thinking_tokens` → `reasoningTokens`（流式 message_delta、非流式 usage 都读） |
| 5 | `.thinking(text:signature:redactedData:)`，第三个默认 nil；同一个 kind 多一个 key；3 处模式匹配 + `CodingMessageSegmentsTests` 一处测试模式匹配 |
| 6 | `ProviderRouter.lastAssistantBlocks / lastRefusalCategory`（记最近一次 sendStreaming 的卡类型，换卡不串）；VM 四处落段（见下）；`hasRenderableSegments` 排除思考段；读点核出的两处一起改（气泡模式 `isComplex`、朗读 `speakableText`） |
| 7 | `ToolTurn.assistantContent`；builder `toolTurnAssistantContent` 整条照发、只换 tool_use 的 input；`PendingUserQuestion.assistantContent` |
| 8 | 预算收尾 `droppingThinking()` + 诊断日志（`addingBudgetSummaryInstruction` 顺手保住 assistantContent）；BP4 挂最后一个非思考块 |
| 9 | `anthropicThinking(…, modelId:summarize:thinkingAllowed:displayAllowed:)`；`wantsThinkingSummary` 读「思考过程」设置；harness 加 `modelId` / `thinkingDisplay` 并隔离 `thinkingDisplayMode` |
| 10 | 分类器：`thinking.display` 被拒 → `.drop(thinking_display)`；思考块被拒 → 新 `Verdict.thinkingBlocksRejected`，router 去块重发一次、不学；`refusalNotice` |
| 11 | `BudgetPreflight.estimate` 跳过 `signature`、期望输出加 `thinkingHeadroom`；`OutputTokenCap.budgetEstimate` 同 |
| 12 | 气泡模式 / 页 2 网页聊天的普通回复显示原生思考摘要；`MessageSegmentsView` 空思考不画 |
| 13 | 检查器 `thinkingLine` / `redactingThinkingSecrets`；录 G8；InspectorRealPath 3 例；ProviderOrdering 当轮回传夹具 |
| 14 | 定向全跑 + 双端 build-for-testing（见「验证」） |
| 15 | astra 审一轮（车头派），7 条全收，见下「astra 一轮裁决」 |
| 16 | 本复盘 + 验收说明 + `docs/now/backend-2.md` + `manual/facts/model/model-api.md` |
| 17 | 车头 10-15 用 Haiku 5.5 打了真请求（她账号 opus / sonnet 停用），结果见「真请求实测」 |

VM 落段（plan §3.2）：
- onToolCalls：`replySegments` 按回复顺序 思考 → 正文（整段 streamingText 放在第一个 text 块的位置）→ 进度更新思考，然后才是工具段；块是在 `Task` 之前同步读的。
- onComplete / onError / 停止：先跑原逻辑，再 `attachThinking`：工具节点插在「这次回复追加的段」前面；普通回复存成 `[.text(content), 思考…]`（astra #4 后；正文仍以 content 为准，contentType 不变；正文只剩「⚠️ 出错」/「（已停止）」时不挂）。三处原来的「segments 非空 = 工具节点」判断没动。
- 停止：只在 `providerRouter.isStreaming`（请求还在路上）时挂这一次的块——工具执行间隙停下时，上一次回复的思考已在 onToolCalls 存过，不重复挂。

## 和 plan 不一样的地方

- **文章模式（CardFlowView.simpleStaticBody）的原生思考行**：执行者没碰（禁区），车头按粟粟要求补了 `7d78403e0`（就是建议的那一行）。它走 ThinkingDisclosure，「思考过程 = 隐藏」时本身不画；plain 分支只在 `!hasRenderableSegments` 时进，读到的只会是 `isAttachedThinkingReply` 形状的思考。
- **G8 的 max_tokens 是 20480，不是 plan 写的 36864**：测试宿主没有 models.dev 目录（隔离、不联网），「自动」可见上限取兜底 16384，+ medium 4096 = 20480。真机上目录认得 opus-5-5（128K）时才是 32768 + 4096 = 36864。其余与 plan §6 一致：`thinking: {type: adaptive, display: summarized}`、无 output_config、无采样参数。
- **G8 场景**：anthropic 卡 + `claude-opus-5-5` + 思考过程「原地」+ cacheFriendly 关（G4 是开 + 拉黑）。所以 G8 和 G4 除模型 / 思考字段外，记忆段落在 system 还是〔动态上下文〕也不同——那是 cacheFriendly 的差别，不是本单。
- **BP4「挂最后一个非思考块」写在 builder 通用路径里**：不只当轮，历史 assistant 的最后一块是思考块的情况也照这条走（历史不带思考，实际不会出现）。
- **预算收尾去块放在 VM（continueToolLoop），思考块被拒去块放在 router**：builder 保持纯函数（预览 = 实发不受影响）。
- **读点核多改了几处**（plan §10 R1 预料到的那类）：
  - `ChatBubbleStyle.isComplex`：先看 `hasRenderableSegments`，普通回复挂思考不算「复杂」。
  - `SpeechService.speakableText`：`hasRenderableSegments` 才读段。**顺带修了老问题**：AI 语音条（只有 audioRef 段）的回复以前朗读是空的，现在念 content。
  - astra #4 后：`ChatCardIndex.visibleText`、`ChatSelectionText.body`（复制 / 多选）遇到 `isAttachedThinkingReply` 一律取 content（段里那份是给老版本看的副本，卡片脚本改正文只改 content）。
- **普通回复挂思考的形状是 `[.text(正文), 思考…]`，正文段在前**（astra #4，车头建议的是 `[.thinking, .text]`）：
  - 新版本要在只看段数组（`hasRenderableSegments` 没有 content / contentType）的前提下认出「普通回复挂思考」，又不能把 Claude 导入的 `[思考, 正文]` 认错（导入的 content 是带 `<<<THINK>>>` 标记的压扁文本，按 content 渲染会漏标记，就是 astra #5 那类）。导入、CC、样例数据都是思考在前，正文在前 + 后面只有思考 / 语音条的只有本单写。
  - 不碰 CardFlowView（判断点 `segs.hasRenderableSegments` 在那里），只改 `hasRenderableSegments` 本身。
  - 老版本：照分段渲染，先正文、后一行「思考」——正文看得到；思考在正文下面（顺序和新版本相反，可接受）。
- **`replyBlocks` 的 `refusalCategory`**：plan 写分类器管 refusal，实际 refusal 不是 HTTP 错误，provider 在 message_delta / 非流式顶层记 `stop_details.category`，VM onComplete 用 `ParamErrorClassifier.refusalNotice` 在正文尾巴加一行「⚠️ 模型拒绝在正文里写出内部推理…」（这行会进下一轮历史，同现有「⚠️ 出错」行的做法）。
- **思考块被拒的提示**走现有的参数自适配小灰字（`lastParamAdaptation` →「✂️ 思考块没被接受，这一次没带」），没另起一种提示。
- **`OutputTokenCap.budgetEstimate` 只给 Anthropic 血统加余量**（plan 只说「开思考时」）：OpenAI 系选了推理档不加，免得动 OpenAI 那边的闸。
- **ProviderOrderingTests 当轮回传夹具**做成「只这一条 assistant 变成原样块，其余消息和老夹具逐字节相同」的比较，没新增落盘夹具字符串；另在 ThinkingReplayTests 里逐条测（原样 / 只换 input / id 对不上退老形状 / 去块 / BP4）。

## astra 一轮裁决（3 P1、4 P2，车头裁定全收）

| # | 问题 | 怎么处理 |
|---|---|---|
| 1 P1 | 思考块被拒、去块重发成功后，VM 手里还是原来的 toolTurns，下一轮把被拒的块又带回去 | 收。router 记「这一次是去块重发那次」（`lastRequestDroppedThinking`，按请求序号），VM onToolCalls 同步读到就把前面几轮一律换成去块版本，继续工具循环和 `PendingUserQuestion` 都用它。测：BudgetGate `testStrippedThinkingStaysStrippedForRestOfLoop`（第 2 次 400 → 重发去块 → 第 4 次请求里被拒那轮仍不带、新一轮的思考照带） |
| 2 P1 | 思考 A → tool_use X → 思考 B → tool_use Y，审批卡改了 X：B 的签名覆盖改前的 X | 收。`toolTurnAssistantContent` 按位置走：某个 tool_use 的 input 和模型原来写的不一样（=改过），从它起往后的思考 / redacted 块都去掉，前面的和非思考块照留（真请求实测：去块被接受）。测：ThinkingReplayTests `testEditedInputDropsLaterThinkingOnly`（改 X / 不改 / 改最后一个 Y 三种） |
| 3 P1 | 保险闸不算回传思考的输入，离额度远时也不走官方计数 | 收。`ToolTurn.thinkingTokens`（那一次回复的 thinking_tokens，onToolCalls 的 usage 带）→ `BudgetPreflight.EchoedThinking`：知道 token 数直接加进输入；不知道的——官方端点在保险闸开着时一律走 count_tokens，中转按签名字数 / 4 保守估。签名照旧不按字计。测：BudgetGate `testPreflightCountsEchoedThinking` |
| 4 P2 | 新数据在老版本：普通回复 segments 只有思考 → 老版本按分段渲染，正文看不到 | 收。普通回复存成 `[.text(content), 思考…]`（正文段在前，理由见「和 plan 不一样」）；新版本 `isAttachedThinkingReply` 认这个形状，`hasRenderableSegments` 为 false 照旧按 content 渲染；visibleText / 复制取 content，不重复。测：ThinkingSegmentTests `testAttachedThinkingReplyShape`、BudgetGate 普通回复 E2E、InspectorRealPath 历史带思考仍 = G8 |
| 5 P2 | 导入的只有思考的消息被当成普通回复，content 里的 `<<<THINK>>>` 进正文和朗读 | 收。`hasRenderableSegments` 只对本单写的形状例外，导入的分段照旧（只有思考 = 可分段渲染，朗读只念正文段 = 空）。测：`testImportedSegmentsBehaveAsBefore` |
| 6 P2 | 页 2 原生思考跟的是 CC 思考开关，不跟「思考过程」 | 收。`ChatRenderContext.showNativeThinking`（`DisclosureKind.thinking.mode != .hidden`），CC / [thinking] 标签照旧跟 `ccShowThinking`；两个开关任一改了都 `pushUpdate()` 重推。逻辑抽到 `DisclosureKind.thinkingLine`（mac 测得到）。气泡模式同一闸（隐藏时连气泡底都不画）；文章模式走 ThinkingDisclosure，隐藏时本身不画。测：`testThinkingLineGates` |
| 7 P2 | 上一条 Anthropic 回复的块落进「没 key 提前失败」的新错误节点 | 收。块按请求序号认（见「边界情况」）。测：ParamAutoAdaptRouterTests `testEarlyFailureDoesNotReadPreviousRepliesBlocks` |

## 真请求实测（车头 10-15，Haiku 5.5，真 API）

- 不发 thinking 字段：模型照样想（thinking_tokens 177），回一个**文字为空**的思考块 + 1232 字签名。§0 的判断成立。
- adaptive + `display: summarized`：有摘要文字（158 字，签名约 1188 字）。
- 简单问题：adaptive 经常根本不想（thinking_tokens 0，没有思考块）。
- 工具续轮整条原样回传：200。
- 工具续轮**去掉思考块**：200，静默；模型重新想，输入 703 → 553 token。这个账号上去块不报错。
- 签名改坏：400，原文 `messages.1.content.0: Invalid \`signature\` in \`thinking\` block`，和夹具一致（已核）。
- 只有一个思考块 → tool_use，改 tool_use 的 input：200（签名不覆盖它后面的 tool_use input）。
- 历史回合带着思考块 + 新问题：200。


## 1. 边界情况

- **空正文块**：回传时去掉 `text` 为空的块（API 不收空 text）。这是「原样」里唯一的删改，不碰思考块。
- **不完整的块**（停止 / 断流 / 中转剥了签名）：不回传；落段时有文字的思考只存文字、签名 nil，空的不完整思考不存。
- **id 对不上**（assistantContent 里的 tool_use id 集合 ≠ calls 的 id 集合）：退回只发 tool_use 的老形状，宁可丢思考也不发错配的块。
- **截断的工具调用**（停在 max_tokens）：tool_use 块照样在 content 里，input 换成 calls 里那份（解析不了 = `{}`，和改前一样）。
- **同一 router 换卡 / 提前失败**（astra #7 后）：块按请求序号认——`sendStreaming` 一进来序号 +1，Anthropic provider 真开始这一次请求（会清空块）时才记下序号；换卡、没 key、找不到卡都读到空。
- **「关」档（none）在默认会想的模型上**：仍是「不发 thinking 字段」= 实际在想。plan 没提，没改（要发 `thinking: {type: disabled}`，Opus 5.5 收不收**未查证**）。
- **导入的分段**（astra #5 后）：只有思考 / 思考在正文前的导入消息照旧分段渲染、朗读只念正文段，和改前一样。万一有导入数据正好是「正文在前、后面只有思考」，会被当成普通回复挂思考、按 content 渲染（Claude 导入的 content 带 `<<<THINK>>>` 标记）——没见过这种形状。
- **老版本读到的普通回复被卡片脚本改过正文**：段里那份正文是旧的，老版本显示旧正文；新版本以 content 为准。
- **正文只剩「⚠️ 出错」/「（已停止）」的普通回复不挂思考**：文章模式的「有正文」判断看段，挂了会多画一个空泡；这种回复也没什么可看的思考。
- **思考段进记忆 / 日记**：`TimelineConsolidator.momentLines` 会读到原生思考摘要（多半没有「心声:」格式，捞不到也无害）；若她的 `<thinking>` 同时在正文里，同一意思可能捞两份。
- **搜索**：普通回复的原生思考不进全文搜索（SearchService 只搜 content）；导入的思考是搜得到的。不一致，没改。
- **第一次跑 BudgetGateTests 时 `testTruncatedToolCallIsNotExecutedAndTellsModelToSplit`（OpenAI 路径，改前就有）超时一次**，单跑整套重跑两次都 36/36 过；和 10-14 记录的「BudgetGate 一例超时偶发」同类，未深究。

## 2. 和下一单（记忆 v4-2）交互风险

- **CVM 区域**：本单改 `runStreamingTurn` 三个回调、`cancelAssistantTurn`、`PendingUserQuestion`、`continueToolLoop`、新增两个 static（`attachThinking` / `replySegments`，放在 `toolTurnsEstimateText` 前）。v4-2 改 `extractMemoriesIfNeeded` 和 CC 落地那行，**不交叉**，合并最多相邻行冲突。
- **金样**：本单只新增 G8；G1–G6 没重录、原样过。v4-2 录 G7 时 G8 必须照样绿（G8 依赖 harness 的 `modelId` / `thinkingDisplay` 两个新开关，v4-2 加场景开关时别撞名）。
- **普通回复开始带 `[.text(正文), 思考…]` 的 segments**：v4-2 的 W1 按消息正文取窗口不受影响；若写手要看思考，用 `segments?.attachedThinkingText`（只有摘要，omitted 时为空）。`ChatCardIndex.visibleText`、`ChatSelectionText.body`、`ToolReplay.rounds`、`sideModelText`、搜索、记忆提取、上下文摘要、窗口总结都取 content，不会读两遍正文；**新代码别直接拼 `.text` 段**，先看 `isAttachedThinkingReply`。
- **UsageLedger**：本单只多填了 `reasoningTokens`（字段原有），v4-2 若动账本结构注意这个字段现在 Anthropic 也有值。

## 3. 技术债务

- **Q7 没做**：OpenRouter 上的 Claude 5 同样默认在想，工具续轮没带 `reasoning_details`——和改前直连一样的潜在问题，另开单（交 Dex 登记）。
- **VM 的工具轮预检（`preCheckToolRequestBudget`）没加回传思考的 token**：它按文字估，没地方放 token 数；最后一道闸（provider 发出前的 `BudgetPreflight`）已经算上（astra #3）。
- **UI 没在模拟器 / 真机看过**：思考行长相、空思考不画后工具卡分组（`ChatToolTimeline.pairedSegments` 夹思考段会不会把一组拆开）都没看。
- **真请求只验了 Haiku 5.5**（见「真请求实测」）：display 会不会让第一回合缓存重写、摘要语言 / 口吻、count_tokens 收不收带思考块的 body、中转行为（plan §13 第 3、4、10、14、15 条）仍**未查证**；Opus 5.5 没打（停用）。
- **报错样本**：`anthropic-thinking-display-extra.json` / `fastapi-thinking-display-forbidden.json` / `anthropic-thinking-blocks-modified.json` 是推断措辞；`anthropic-thinking-signature-invalid.json` 那句 10-15 真请求原文核过一致。
- **`MessageSegment.swift` 文件头注释「新增 case 时老解码跳过即可」和代码不符**（plan §1.2 已指出），没改（不在本单范围，提一嘴）。
- **说明书**：`manual/facts/model/model-api.md` 加了 5 条事实（顺手把被挪动的 `OutputTokenCap.swift:39-52` 引用改成 `47-60`）；`npm run check` / `rewrite` / `build` 没跑（rewrite 要调模型），`manual.html` 等下次流水线。

## 验证

- 第一轮（提交 4bf25c35a…919cfd514 那版）：mac / iOS build-for-testing SUCCEEDED；定向 20 套 216 测全过；BudgetGateTests 单跑 36（第一次 1 例老用例超时，重跑两次全过）。
- **astra 修复后（最终代码树）**：
  - mac `build-for-testing`（MemoryPalaceTests）：`** TEST BUILD SUCCEEDED **`；
  - iOS `build-for-testing`（MemoryPalaceIOS，iOS 26 模拟器 9451D1D2）：`** TEST BUILD SUCCEEDED **`；
  - mac 定向（都读到 `Test Suite '…' passed`）：PromptRealPathGoldenTests 7、InspectorRealPathTests 20、MainThreadIOBudgetTests 3、ProviderOrderingTests 13、OutputTokenCapTests 26、ToolReplayTests 18、ToolDrawerTests 17、SentRequestStoreTests 4、ParamCompatTests 14、ParamErrorClassifierTests 18、ParamAutoAdaptRouterTests 17、ReasoningEffortTests 12、NonStreamParseTests 5、CodingMessageSegmentsTests 8、ThinkingLineageTests 3、ThinkingStreamTests 9、ThinkingSegmentTests 10、ThinkingReplayTests 6、ThinkingParamTests 6、ThinkingInspectorTests 4（共 220，0 失败）；BudgetGateTests 单跑 38，全过。
- 金样：G1–G6、G8 **都没重录、原样过**（astra #4 改的是存法，不是请求；InspectorRealPath「历史带思考段」那例改成新形状后实发仍和 G8 逐字节相同）。
- 真请求：见上「真请求实测」（车头打的，执行者没发）。
