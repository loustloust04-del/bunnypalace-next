# plan · thinking 回传（思考块收全 + 当轮原样回传）

✅ 粟粟 10-15 批 Q1–Q9「都按推荐」——可以实现（#093 已合 master；先做本单，再做记忆 v4-2，同在 backend-2）。

> 任务书：`~/Desktop/cc-rp/API链路/派单/prompt-thinking.md`（粟粟 10-15「派吧」）。
> 前置：#089 请求体修复（[plan](plan-request-body.md) §7、[review](review-request-body.md) §2）、#094 参数自适配（[plan](plan-param-autoadapt.md)、[review](review-param-autoadapt.md)）已合；#093 工具抽屉（[plan](plan-tool-drawer.md)、[review](review-tool-drawer.md) §2）在本工位做完待合。
> 本文 = research + plan 合一。研究基于工位 `backend-2` HEAD `d274d6734`（含 #093 全部提交 + temperature/top_p 小修）。行号都是这个树上的。
> 不在本单：CC 会话的思考链（cc-bridge / Stop hook，见 §0.3）、ChatGPT 登录、本机模型、OpenAI 兼容口的 reasoning（Q7）。

---

## 0. 先说几件和之前文档 / 交接不一样的事

1. **「默认档 = 不思考」对 opus-5-5 不成立。** #089 §7 写「推理强度停在默认 → 一个 thinking 字段都不发 → 没开」。官方配置表：Opus 5.5 / Opus 5 / Sonnet 5.5 / Sonnet 5 / Haiku 5.5 / Fable 5.x / Mythos 5.x **不发 thinking 字段 = adaptive thinking 开着**，而且 `display` 在这些模型上默认 `omitted`（思考块文字为空，只有签名）。[thinking §Configuring](https://platform.claude.com/docs/en/build-with-claude/thinking#configuring-thinking)
   - 所以 10-11 那份 body 虽然没有 thinking 字段，模型照样在想，回了思考块，被 app 丢了；32768 上限是思考和正文共用的。
   - 工具循环续轮也一直没回传那些思考块（§1.3）。粟粟没报过 400，推测 API 是静默降级（未查证，§13）。
   - Opus 4.6 / 4.7 / 4.8、Sonnet 4.6、4.5 及更老的模型才是「不发 = 不想」。
2. **历史回合的思考块不该发回去。** 官方三句话：工具回合内**必须**回传；跨回合**建议**全回传；工具回合以外**可以**不带。[thinking §Preserving](https://platform.claude.com/docs/en/build-with-claude/thinking#preserving-thinking-blocks)
   但 Preserved thinking 有前缀校验：一个思考块只在「顶层 system、tools、它前面的所有消息」都没变时有效，变了就 400 或被丢（被丢的位置往后缓存也断）。2026-08-31 后建的账号默认开、默认报错。[preserved-thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)
   MP 的组装不是「只追加」：〔状态〕每轮挪到最新用户消息、过去的工具结果截 2KB、记忆注入改 system、窗口滑动、正则、深度注入……历史里的思考块发回去，基本每轮都过不了校验。→ **推荐历史一律不带，只在当轮工具循环里原样带**（Q1）。
3. **交接文档《思考链回传-交接给写代码CC》讲的是 CC 会话**（Stop hook、`showThinkingSummaries`、transcript 保留期 `cleanupPeriodDays`），走 `MessageNode.ccThinking` 那条链；本单是 API 直连的思考块。两件事不相干，本单不碰 CC，那三件另开单。
4. **粟粟人设要求正文里先写 `<thinking>`**（TimelineConsolidator.swift:189 注释）。官方：Fable 5.1 / Opus 5.5 / Opus 5 / Sonnet 5.5 / Fable 5 上，「要求模型把内部推理写进正文」的请求可能被拒，`stop_details.category: "reasoning_extraction"`。[thinking §Summarized](https://platform.claude.com/docs/en/build-with-claude/thinking#summarized-thinking)
   她写的是角色内心戏，不一定触发（未查证）。本单给原生思考摘要的显示作为替代；那段删不删由她定（Q8）。
5. **#093 复盘 §2 说的「退纯文字时 thinking 怎么办」**：三处 textFallback 只作用于历史；历史不带 thinking（Q1-A）→ 三处天然一致，不用改。当轮 toolTurns 不经过 textFallback。

---

## 1. 现状（带出处）

### 1.1 收：思考块全丢
- 流式 `AnthropicProvider.handleAnthropicEvent`（ChatService.swift:1561）：
  - `content_block_start` 只认 `tool_use` / `web_search_tool_result`（:1582–1609）；
  - `content_block_delta` 只认 `delta.text` / `delta.partial_json`（:1612–1621）。
  - `thinking_delta`（`delta.thinking`）、`signature_delta`（`delta.signature`）、`redacted_thinking` 整块、`server_tool_use` 都丢了。
- 非流式 `parseNonStreamBody`（:1483）注释直说「thinking 块跳过」。
- 用量 `APIUsageParser.anthropic`（APIUsageParser.swift:42）不读 `output_tokens_details.thinking_tokens`。OpenAI 侧读了 reasoning_tokens（ChatService.swift:1044）。

### 1.2 存：段结构有，没人写
- `MessageSegment.thinking(text:signature:)` 已有（MessageSegment.swift:9，编码 :92–95，解码 :161–164）。现在只有导入写它（ClaudeImporter.swift:242 带签名；ChatGPT / Kelivo / RikkaHub / AI Studio 导入不带签名）。
- 没有 `redacted_thinking` 的表示。
- **不能加新 kind**：`MessageNode.segments` 是 `try? decode([MessageSegment])`（Conversation.swift:241–244），一个不认识的 kind 会让整个数组变 nil，老版本（另一台设备、旧备份还原）整条消息的分段就没了。文件头注释「新增 case 时老解码跳过即可」和代码不符。
- 工具循环节点：`onToolCalls` 把这一次回复的正文 `.text(streamingText)` + 每个调用的 `.toolUse` / `.toolResult` 追加进 segments（CVM:4039、:4093–4301）；`onComplete` 追加最后的正文（CVM:3940–3944）。
- 普通回复：没有 segments，只写 `content`（CVM:3945）。
- 停止 / 出错：segments 非空才往里追加（CVM:2251–2254、:4008–4011）。

### 1.3 发：参数通，块没回传
- 推理档：`ReasoningEffort.anthropicThinking`（ReasoningEffort.swift:163）。
  - `auto` → `headroom` 返回 nil → 不发 thinking / output_config，`max_tokens` = 可见上限（自动 32768，OutputTokenCap.swift:11、:21）。
  - 选了档 → adaptive + `output_config.effort` + 余量（low 1024 / medium 4096 / high 10000 / xhigh 16000 / max 32000，ReasoningEffort.swift:150–159）；老模型 budget_tokens。
- builder（ChatService.swift:1291–1399）：
  - 当轮 `toolTurns` 只发 `tool_use` 块（:1315–1331）。**这一次回复里调工具前说的话、思考块、服务端搜索块都没带。**
  - 开思考分支：只发 0.95–1 的 top_p（:1360–1364）。
  - BP4 缓存标打在最后一条 assistant 的最后一块（:1378–1390）。
- 历史：`ToolReplay.rounds`（ToolReplay.swift:24）遇到 `.thinking` 走 `default: continue`；`anthropicWire`（ChatService.swift:1225）不发思考块。
- 预算收尾那次 `tools: nil` + 带着 toolTurns（CVM:3865–3894）。
- 审批卡改过参数：下一次请求里 tool_use 的 input 换成改过的（CVM:4398–4404）。
- ask_user 暂停：toolTurns / calls 存在内存里的 `PendingUserQuestion`（CVM:1906、:4413），恢复时拼上 Q/A 继续（CVM:2065）。

### 1.4 显示：现成的三处
- `ThinkingDisclosure`（ThinkingSheet.swift:6）：标题优先用一句话总结（`ThinkingSummarizer`，先端上模型、再便宜 API 模型），模式按设置「思考过程」（隐藏 / 原地展开 / 弹出，DisclosureMode.swift:36）。
- 普通回复：`simpleStaticBody`（CardFlowView.swift:3876）显示 `[thinking]` 标签里的或 `ccThinking`。
- 分段回复：`MessageSegmentsView` 的 `ThinkingBlockView`（MessageSegmentsView.swift:82、:208、:298），标签「思考」，空文字也会画。
- 走哪条：`hasRenderableSegments`（MessageSegment.swift:262）只把 `audioRef` 排除。先例：AI 语音条的 segments 只有 audioRef、正文在 content，照样走普通渲染。

### 1.5 检查器
- 预览 `TurnPreview.requestBody` 和实发同一个 builder（#089 P0-c），`SentRequestStore` 存实发 body，`SentRequestBodyView.displayText`（SentRequestBodyView.swift:92）把图片换成占位。

### 1.6 别家
- OpenAI 兼容 `parseOpenAIChunk`（ChatService.swift:1012）不读 `reasoning` / `reasoning_content` / `reasoning_details`。OpenRouter 上的 Claude 5 同样默认在想，工具续轮同样没回传。
- ChatGPT 登录：只读 reasoning_tokens（ChatGPTOAuthProvider.swift:254）。
- 本机：`ThinkTagConverter` 把 `<think>` 换成 `[thinking]` 进正文（ReasoningEffort.swift:192）。
- CC：`ccThinking`（hook 经 hub 回传）。

### 1.7 保险闸
- `BudgetPreflight.estimate`（BudgetPreflight.swift:51）把块里除 data / url / source… 以外的字段都当正文估字数。思考块的 `signature` 是一长串密文，会被当成几千字的输入。
- 期望输出固定 4096（:72），不看思考。

### 1.8 读思考段的别处
- `TimelineConsolidator.momentLines`（TimelineConsolidator.swift:180–195）从 `.thinking` 段 + ccThinking + `<thinking>` 正文里捞「心声: / 时刻:」行（日记素材）。
- 导出（ChatGPT / Kelivo / RikkaHub 格式）按 `.thinking` 段导出思考文字。

---

## 2. 官方规则（2026-10-14 读的文档，以此为准）

| # | 规则 | 出处 |
|---|---|---|
| R1 | 不发 thinking：Opus 5.5 / Opus 5 / Sonnet 5.5 / Sonnet 5 / Haiku 5.5 / Fable / Mythos = adaptive 开；Opus 4.6–4.8、Sonnet 4.6、4.5 及更老 = 关 | [thinking §Configuring](https://platform.claude.com/docs/en/build-with-claude/thinking#configuring-thinking) |
| R2 | `display`：`summarized` 返回摘要（Opus 4.6 / Sonnet 4.6 及更老默认）；`omitted` 文字为空只给签名（上面那批新模型 + Opus 4.7 / 4.8 默认）。计费一样；omitted 首字更快；两轮之间换 display 允许，签名不变 | [§Controlling display](https://platform.claude.com/docs/en/build-with-claude/thinking#controlling-thinking-display) |
| R3 | 摘要由另一个模型写，不是原始思考；任何 display 都拿不到原文 | [§Summarized](https://platform.claude.com/docs/en/build-with-claude/thinking#summarized-thinking) |
| R4 | 流式：`thinking_delta` 若干 → 一个 `signature_delta` → `content_block_stop`；omitted 时 thinking_delta 文字为空 | [§Streaming](https://platform.claude.com/docs/en/build-with-claude/thinking#streaming-thinking) |
| R5 | 工具循环是一个 assistant 回合；回传工具结果时，思考块必须**完整、原样**跟着它的 tool_use 一起回去；最新一条 assistant 里连续的思考块（含 redacted）不能重排、改、删一部分；改了 400 | [§Preserving](https://platform.claude.com/docs/en/build-with-claude/thinking#preserving-thinking-blocks) |
| R6 | 回合中途切思考开关不报错，API 静默关思考 / 剥掉块 | [§Thinking with tool use](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-with-tool-use) |
| R7 | 工具回合以外，历史思考块可以不带；带了按模型保留（Opus 4.5+ / Sonnet 4.6+ / Haiku 5.5 / Fable / Mythos 全保留并按输入计费；更老的只留最后一回合） | [§Preservation by model](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-block-preservation-by-model)、[§Encryption](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-encryption) |
| R8 | 前缀校验：思考块只在 system / tools / 它前面的消息都不变时有效。改早先的消息、截短早先的 tool_result、改早先 tool_use 的 input、改 system / tools 都算改；改 effort / max_tokens / output_config / thinking.display / cache_control 不算。从历史开头或结尾整段去掉思考块合法，去中间的会让后面的失效。8-31 后的新账号默认 400，老账号要设 `block_binding` 才查。不发任何历史思考块就没有检查 | [preserved-thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking) |
| R9 | 换模型：读不了的块静默丢、不计费；Sonnet 5.5 / Haiku 5.5 的块绑账号，别的账号发回去静默丢 | 同上、[§Preservation by model](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-block-preservation-by-model) |
| R10 | `redacted_thinking`：`{type, data}`，原样回传；按 type 过滤时别漏它 | [§Redacted](https://platform.claude.com/docs/en/build-with-claude/thinking#redacted-thinking-blocks) |
| R11 | 缓存：思考配置和 effort 渲染进 prompt，改了就断缓存；显式写成默认值 = 不写；思考块不能直接挂 `cache_control`，跟着别的块一起缓存；工具循环里会随工具结果增量缓存 | [§Prompt caching](https://platform.claude.com/docs/en/build-with-claude/thinking#thinking-and-prompt-caching)、[prompt-caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) |
| R12 | 采样：Opus 4.7+ / 5 系 / Sonnet 5 系 / Haiku 5.5 / Fable / Mythos 非默认 temperature / top_p / top_k 一律 400；更老的模型开思考时 temperature / top_k 不行，top_p 只能 0.95–1 | [§Sampling](https://platform.claude.com/docs/en/build-with-claude/thinking#sampling-parameters) |
| R13 | 预填：4.6+ 一律拒；更老的开思考时不能预填。强制工具（tool_choice any / tool）：Opus 5.5 / Sonnet 5.5 / Fable 5.1 / Mythos 5.1 一律拒 | [§Prefill](https://platform.claude.com/docs/en/build-with-claude/thinking#response-prefill-and-forced-tool-use) |
| R14 | interleaved：adaptive 自动，不要 beta 头；budget 模式的 Opus 4.5 / Sonnet 4.5 / 更老 Claude 4 要 `interleaved-thinking-2025-05-14`；budget 模式要求最后一个 assistant 回合以思考块开头（adaptive 不要求） | [extended-thinking §Interleaved](https://platform.claude.com/docs/en/build-with-claude/extended-thinking#interleaved-thinking-in-manual-mode) |
| R15 | 进度更新：Fable 5.1 / Mythos 5.1 / Opus 5.5 / Sonnet 5.5 / Fable 5 会在工具调用前写一个单独的思考块（有自己的签名），照样原样回传；停在 max_tokens 时最后一块可能是「This part of the response was interrupted before it finished.」 | [§Progress updates](https://platform.claude.com/docs/en/build-with-claude/thinking#progress-updates-between-tool-calls) |
| R16 | 默认 effort：Opus 5.5 / Haiku 5.5 是 medium，别的是 high；max_tokens 是思考 + 正文的硬上限，要留够 | [steering §Effort levels](https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost#effort-levels)、[§Cost control](https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost#cost-control) |
| R17 | 计费：思考按输出全额计（不管 display）；保留在上下文里的历史思考按输入计；摘要生成不收费；`usage.output_tokens_details.thinking_tokens` 流式只在最后一个 message_delta 里 | [steering §Pricing](https://platform.claude.com/docs/en/build-with-claude/thinking-steering-and-cost#pricing) |

和我们旧文档不一致的：§0.1（默认档）；#089 review 写「开了思考又调工具，第二次请求多半会被 API 拒」——文档对「缺了思考块」没写会怎样，只写了中途切开关是静默降级（R6）。

---

## 3. 改法

### 3.1 收全（provider）
- `AnthropicProvider` 按 `index` 记**这一次回复的全部内容块，原样**（JSON 对象）：
  - `thinking`：`thinking_delta` 拼文字，`signature_delta` 填签名；
  - `redacted_thinking`：`content_block_start` 里整块带 `data`；
  - `text`（含 citations）、`tool_use`（input 由 `partial_json` 拼完再解析）、`server_tool_use`、`web_search_tool_result`。
- 非流式 `parseNonStreamBody` 同一份：`content[]` 原样留着。
- 只在 `content_block_stop` 之后才算一块「完整」；没收到签名的思考块标「不完整」（停止 / 出错时只拿来显示，绝不回传）。
- `ProviderRouter` 照 `currentWebSources` 的写法暴露 `lastAssistantBlocks`，VM 在 onComplete / onToolCalls / onError / 停止 时读。
- 用量：`output_tokens_details.thinking_tokens` → `TokenUsage.reasoningTokens`（流式在最后一个 message_delta）。

### 3.2 存进节点（不显示也存）
- 每个思考块 → 一个 `.thinking(text: 摘要或空, signature: 签名)` 段，顺序照回复里的顺序。
- redacted → 同一个 kind `thinking`，加一个可选字段 `redactedData`（Q6-A）：
  - Swift 里 `.thinking(text:signature:redactedData:)`，第三个带默认值 nil，现有构造点不用改；
  - 编码仍是 `kind: "thinking"`，多一个 key；**老版本读成一段空思考**，不会整组解码失败；
  - 要改的模式匹配 3 处（MessageSegmentsView.swift:82、TimelineConsolidator.swift:184、ClaudeImporter.swift:383），加一个 `_`。
- **工具循环节点**（本来就有 segments）：
  - onToolCalls：这一次回复里第一个 tool_use 之前的块按顺序写（思考 → 正文 → 进度更新思考），工具调用之间的进度更新思考也放在工具段前面（只影响显示；回传用 §3.3 的原样块）。
  - onComplete：最后一次回复的思考段插在最后那段 `.text` 前面。
- **普通回复**（没有工具）：segments **只放思考段**，正文照旧只在 `content`，`contentType` 不变。
  - `hasRenderableSegments` 把「只有思考 / 语音条」的当成不可渲染，照旧走普通正文（和 AI 语音条同一个先例）。
  - 写入时机放在 onComplete / onError / 停止 原逻辑**之后**：这三处现在用「segments 非空」判断是不是工具节点（CVM:3940、:4008、:2251），先跑完原逻辑再挂思考段，就不用改那三个判断。
- 停止 / 出错：已完整（有签名）的块照存；正在收的那块只存文字、签名 nil。
- 存储格式：**SwiftData 表不加列**，`segmentsData`（externalStorage）里多几段；文件库存储格式和路径一律不动。备份 / 同步本来就带 `segmentsData`，不用改 schemaVersion。

### 3.3 当轮工具循环：原样回传
- `ToolTurn` 加 `assistantContent: [[String: Any]]?`：这一次回复的全部块原样（§3.1）。nil = 走现在的「只发 tool_use」（OpenAI 兼容、老调用点、测试夹具）。
- Anthropic builder：有 `assistantContent` 就整条照发（Q2-A）：
  - 思考 / redacted / 正文 / server 块一个字节不动；
  - 只有 tool_use 的 `input` 在审批卡改过时换成改过的（按 id 对）。按 R8，改的是思考块**后面**的块，不在它的前缀里；下一次回复的思考是在改过的版本上生成的，前后一致。
- `PendingUserQuestion` 带上这份块；ask_user 恢复时拼进 ToolTurn。
- **预算收尾那次**（`tools: nil`）：tools 变了 = 当轮所有思考块的前缀变了（R8）→ 这一次请求把 toolTurns 里的思考 / redacted 块去掉，其余照旧，记一条诊断日志。（发 `tools: nil` 却带 tool_use 是 #089 留下的债，本单不改。）
- **BP4 缓存标**：最后一条 assistant 的最后一块是思考 / redacted（停在进度更新上）时，挂到它前面最后一个非思考块；整条都是思考就不挂（R11）。
- 当轮的前缀天然不变：同一个 `payload`（system、〔状态〕、历史）+ 只追加 toolTurns，tools 一个回合内不变（#093 保证）。

### 3.4 历史：不带（Q1-A）
- `ToolReplay.rounds` / `anthropicWire` / 三处 textFallback 不动，历史节点里的思考段照旧跳过 → **历史字节一个不变**。
- 理由：R7 允许；R8 下 MP 的组装过不了前缀校验；带了还按输入计费；导入对话里的思考块是别的账号签的（claude.ai 导出），R9 会被丢或报错。
- 缓存不吃亏：#089 §0.3 已经是「每轮重写最后一来一回」（〔状态〕挪走那条用户消息字节就变了），历史不带思考不额外断缓存。

### 3.5 参数：默认档 + 摘要 + 余量
- `ModelLineage` 加三个判断（没有官方清单的部分按文档表，见 §13）：
  - `thinksByDefault`：opus ≥5、sonnet ≥5、haiku ≥5.5、fable / mythos；
  - `defaultEffort`：opus 5.5 / haiku 5.5 → medium，其余 high（R16）；
  - `displayDefaultOmitted`：opus ≥4.7、sonnet ≥5、haiku ≥5.5、fable / mythos。
- **推理档「默认」**（Q5-A）：
  - 默认就会想的模型：`thinking: {type: "adaptive"}`（显式写默认值 = 不写，R11 不断缓存），**不发 output_config**（档位还是官方默认）；`max_tokens` = 可见上限 + `headroom(defaultEffort)`。
  - 其余模型：照旧不发（Opus 4.6–4.8 / Sonnet 4.6 「默认」仍然不想；老模型仍然不想）。
- **摘要显示**（Q3-A）：`displayDefaultOmitted` 的模型、设置「思考过程」不是「隐藏」时，thinking 里加 `display: "summarized"`；隐藏时不发 display（用默认 omitted，首字更快）。默认就是 summarized 的老模型不发这个字段（少一个字段，中转少一个出错点）。
- 选了具体档位的：照旧 adaptive + output_config + 余量，同样按上面规则加 display。
- 余量规则不变（low 1024 … max 32000，总数不超过模型上限）。「自动」的可见上限 32768 + medium 4096 = 36864（opus-5-5 默认档）。
- 采样：开思考分支照旧（R12 已由 #094 / 血统处理）。

### 3.6 自适配 / 报错（#094 分类器）
- 中转不认 `thinking.display`（报错点名 display）→ 新组 `thinking_display`：只去掉 display、重发一次、记住。现在这种报错会落到「thinking 不支持 → 去掉思考」（ParamErrorClassifier.swift:124），等于把思考整个关了。
- 400「thinking blocks cannot be modified」/「Invalid `signature` in `thinking` block…」→ 不学、不记；这一次把当轮 toolTurns 里的思考块去掉重发一次（R6：缺块时 API 降级而不是报错），聊天里闪一行「思考块没被接受，这一次没带」，诊断日志记原文前 300 字。正常不该出现（原样回传、前缀不变），出现说明中转在改 body。
- `stop_reason: "refusal"` 且 `stop_details.category == "reasoning_extraction"` → 气泡尾巴说人话「模型拒绝在正文里写出内部推理」+ 诊断日志（Q8）。
- 样本放 `MemoryPalaceTests/Fixtures/param-errors/`，措辞没有真原文的标「推断」。

### 3.7 检查器（预览 = 实发）
- 「上一次真实发出」：
  - 头部加一行：`思考：adaptive · 摘要 · effort 默认(medium) · max_tokens 36864`；第 2 次及以后的请求再加「回传思考块 N 个」。
  - 正文显示时签名 / redacted data 缩成 `<签名 1832 字>`（同图片占位的做法，`displayText`）；「复制」照旧复制原文。
- 「下一轮预览」：和实发同一个 builder，所以 thinking 参数、display、max_tokens 一样；历史不带思考块，两边一样。
- 当轮的思考块只在「上一次真实发出」的第 2 次及以后的请求里出现（预览永远是第 1 次，没有 toolTurns）。

### 3.8 界面（任务书第 5 条）
**她的需求**：人设要求每轮先想、中文、叫主人，并且她能看到。原生思考摘要是另一个模型写的（R3），语言多半跟着思考走，「叫主人」这类口吻不保证（未查证）。
- **v1（Q3-A + Q4-A）**：
  - 普通回复：正文上方一行「› 思考过程」，用现有 `ThinkingDisclosure`（标题优先一句话总结，展开 / 弹出按「思考过程」设置），和 `[thinking]` 标签、ccThinking 同一个位置、同一套样式。
  - 工具循环：工具卡之间按顺序出「思考」行（现有 `ThinkingBlockView`），**空的不画**（omitted / 进度更新为空时）。
  - 流式时不实时滚思考文字；等待动画照旧。完成后出现。
  - 同一条回复里既有原生思考、正文里又有她的 `<thinking>`：都保留，原生的在上；她的那段怎么显示由她的正则决定，不动。
- 颜色沿用 `ThinkingDisclosure` 现有的 textMuted，不引蓝 / 黄。标题不带人设名；如果要「xx 在想」，用 `assistantName` 变量拼，不写死名字。
- 不新增设置：显示开关就是现有的「思考过程：隐藏 / 原地 / 弹出」，隐藏时连摘要都不要（§3.5）。

### 3.9 保险闸 / 用量（Q9-A）
- `BudgetPreflight.estimate` 跳过 `signature` 字段（redacted 的 `data` 已经跳过）。当轮回传的思考按输入计费，但签名长度不等于 token 数；低估部分靠 Anthropic 走官方计数接口时精确（`OfficialTokenCounter`，收不收带思考块的 body 未查证）。
- 开思考时期望输出 = 4096 + 这一档余量（宁可多估，和 #094「宁可多扣」一致）。实际结算照真实 usage。
- 用量账本显示 thinking_tokens（`reasoningTokens` 已有字段）。

### 3.10 和别的单 / 别家逐个说
| 对象 | 交互 | 本单怎么办 |
|---|---|---|
| 工具抽屉 #093 | 一个回合内 tools 不变 → 当轮思考块前缀稳；执行前复查拒掉的调用回 is_error 结果，配对按原 tool_use id，不碰思考块；三处 textFallback 只管历史 | 不改 #093 的代码；`tool_choice` 不发 |
| 参数自适配 #094 | 思考格式 adaptive / budget、采样剥离、output_config 都按 ParamCompat；自愈重试那次是同一请求的重发，第一次没输出 | 加 `thinking_display` 组和思考块被拒那支（§3.6）；`singleSampler` 只在非思考分支，开思考不受影响 |
| ask_user | 一个 API 回合被拆成两个节点（A 带 tool_use、Q/A 用户节点、B 接着说），当轮靠 toolTurns | `PendingUserQuestion` 带原样块；历史不带思考，A / B 各自存自己的思考段 |
| 预填 | 4.6+ 一律拒（R13）；更老模型开思考也不能预填 | 检查器已有预填提醒（#089 P0-a）；Sonnet 4.5 选了档 + 预设里有深度 0 预填 → 400，分类器说人话（#094 已有这支） |
| OpenAI 兼容（reasoning_effort / reasoning_content） | 不收不回传；DeepSeek 一类的 reasoning_content 回传规则各家不同 | Q7-A：本单不做 |
| OpenRouter（`reasoning` / `reasoning_details`） | OpenRouter 上的 Claude 5 默认在想，工具续轮要把 `reasoning_details` 原样带回（[OpenRouter 文档](https://openrouter.ai/docs/use-cases/reasoning-tokens)）；现在没带，和直连今天一样的潜在问题 | Q7-A：另开单（按同一套「当轮原样、历史不带」） |
| ChatGPT 登录（Responses，encrypted reasoning） | 只读 reasoning_tokens；工具历史走纯文字退路 | 不动 |
| 本机模型 | `<think>` → `[thinking]` 进正文 | 不动 |
| CC 会话 | ccThinking 走 hook；交接文档那三件 | 不动，另开单 |
| 记忆 / 日记 | 记忆提取、上下文摘要的输入取 content，不含思考；`TimelineConsolidator.momentLines` 会开始读到原生思考摘要（多半没有「心声:」格式，捞不到也无害） | 只改那 1 处模式匹配；v4-2 要不要让写手看思考，留给 v4-2 |

---

## 4. 数据格式 / 持久化（汇总）
- **MessageNode 表不变**，不需要迁移。
- `segmentsData` 里多 `.thinking` 段：`{"kind":"thinking","text":"…","signature":"…"}`，redacted 多一个 `"redactedData":"…"`（text 为空、signature 为空）。
- 普通回复从此可能带「只有思考段」的 segments（正文仍在 content）。读 segments 的非视图代码约 90 处，按类核一遍（§10 R1）。
- 老版本 app 读新数据：思考段照常解（redacted 读成空思考）；新版本读老数据：没有思考段，照旧。
- 文件库（`floors/…`、tool-results 存档）不动。
- 体积：每个思考块一个签名（Claude 4+ 签名「明显更长」，具体多长未查证）；opus-5-5 每条回复至少一个块。

## 5. 预览 = 实发
- 参数（thinking / display / output_config / max_tokens）只在 builder 里算，预览和实发同一个函数 → InspectorRealPathTests 照样「预览 body = 重新生成实发 body」。
- display 取决于「思考过程」设置（UserDefaults）：测试 harness 隔离这个键（同 #093 隔离 `toolDrawer.v1` 的做法）。
- 当轮块只在实发的第 2 次以后出现，检查器「上一次真实发出」直接是真 body。

## 6. 金样
- G1–G6：gpt-4o 和 claude-sonnet-4-5（「默认」档、budget 血统、不默认思考）→ **body 一个字节不该变**。变了 = 实现有 bug，不许重录。
- 新增 **G8**（G7 已被 v4-2 plan 占用，见 §11）：claude-opus-5-5、「默认」档、思考过程「原地」→ `thinking: {type: adaptive, display: summarized}`、无 output_config、max_tokens 36864、无采样参数。
- ProviderOrderingTests：加一条当轮回传夹具（思考 + 正文 + 进度更新思考 + tool_use，审批卡改过 input），断言原样 + 只换 input；老夹具（`assistantContent` 为 nil）不变。
- 「每次落地只录一次」见 §11.3。

## 7. 成本 / token
- **思考本来就在花钱**：opus-5-5 默认档今天就在想，按输出全额计（R17），display 不影响。
- 摘要显示：不加钱（摘要生成不收费），首字稍慢（R2）。
- 当轮回传：工具续轮的输入多了思考块 + 调工具前那段正文（+ 有服务端搜索时的搜索结果块）。官方说会随工具结果增量缓存（R11）。这是 API 要求的，不回传才是错的。
- 历史不带：不多花输入。
- 默认档留余量：max_tokens 变大不花钱，用多少算多少。
- 一句话总结：沿用 `ThinkingSummarizer`（先端上模型，近期消息才用便宜 API 模型），和 ccThinking 一样。
- 存储：每条 Claude 回复多一到几个签名（几 KB 级，未查证），备份 / 同步跟着变大。

## 8. 失败模式
| 情况 | 会怎样 | 处理 |
|---|---|---|
| 两轮之间换模型 / 换卡（直连 ↔ OpenRouter ↔ 中转 ↔ 另一个账号） | 历史不带思考 → 无影响 | — |
| 编辑 / 重新生成 / 切分支 | 新回合，新思考；历史不带 → 无影响 | — |
| 副模型（记忆写手、摘要、标题、一句话总结） | 输入取 content；非流式解析不收思考 | 不变 |
| 老历史没签名 / 导入别人签名的思考 | 历史不带 → 无影响 | — |
| 当轮思考块被拒（中转改 body / 签名坏） | 400 | §3.6：去块重发一次 + 提示 |
| 预算收尾 `tools: nil` | tools 变了，当轮思考块失效 | §3.3：这一次去掉思考块 |
| #094 自愈重发改了思考格式 | 同一请求的重发；若中途 adaptive ↔ budget，API 静默关思考（R6） | 不额外处理 |
| 停在 max_tokens，最后一块是进度更新思考（R15） | 原样存、原样回传；显示那句「被打断」 | 现有截断提示照旧 |
| 用户中途停止 | 已完整的块存；正在收的只存文字 | §3.2 |
| 只有思考、没有正文（refusal / 空回复） | content 空、segments 只有思考 → 气泡只显示思考行 | refusal 说人话（§3.6） |
| 中途改「思考过程」显示设置 | 下一次请求生效，签名不变（R2） | — |
| 中途改推理档 | 当轮 payload 固定，不会中途变；下一回合整段缓存重写一次（R11） | 验收说明写明 |
| Sonnet 4.5 等 budget 模型选了档 + 工具 | 没有 interleaved 头时续轮不想；回合以第一次的思考块开头（R14），我们原样回传 → 合法 | 不加 beta 头（§13） |

## 9. 测试
- **新增**：
  - SSE 夹具：summarized / omitted / redacted / 进度更新 / 停在 max_tokens / 中途断流 → 块顺序、签名、完整标记；非流式同款。
  - `ThinkingBlocksTests`：块 → 段（顺序、redacted、空文字）；段编解码（老格式读、老版本读新格式＝用不带 redactedData 的结构解）。
  - 普通回复只挂思考段：`hasRenderableSegments` false、`ChatCardIndex.visibleText` = content、`ToolReplay.rounds` = []、历史字节和不带思考时相同、记忆提取 / 上下文摘要输入不变。
  - 当轮回传：原样、只换改过的 input、ask_user 恢复带块、预算收尾去块、BP4 不落在思考块。
  - 参数：`thinksByDefault` / `defaultEffort` / `displayDefaultOmitted` 血统表（点号、OpenRouter 前缀、日期段）；默认档余量；隐藏时不发 display；老模型不发 display。
  - 分类器：display 被拒、思考块被拒、refusal reasoning_extraction。
  - 保险闸：签名不计字、开思考期望输出加余量。
  - 用量：thinking_tokens 解析。
- **要跑通的现有套件**：PromptRealPathGoldenTests（G1–G6 不变 + G8）、InspectorRealPathTests、ProviderOrderingTests、OutputTokenCapTests、ParamAutoAdaptRouterTests、ParamCompatTests、ParamErrorClassifierTests、ReasoningEffortTests、ToolReplayTests、ToolDrawerTests、SentRequestStoreTests、MainThreadIOBudgetTests、BudgetGateTests（单跑）、NonStreamParseTests。
- **双端** build-for-testing 交集成区（工位只跑 mac 定向，iOS 交 Warden）。
- **真请求实测**（要粟粟点头）：opus-5-5 默认档 + 工具两轮：①续轮 200 且回了思考块；②第二回合 cache_read ≫ cache_creation；③摘要是不是中文。

## 10. 风险
- **R1 普通回复开始带 segments**：读 segments 的非视图代码约 90 处（导出、备份、同步、搜索、复制、朗读、卡片索引、进度卡…），「只有思考段」被当成工具节点的地方会出错。实现第 5 步逐类核，测试覆盖历史 / 记忆 / 卡片索引三条主路。UIKit 新聊天页（原生 cell）是不是同一个判断没读到（§13）。
- **R2 工具节点里多了思考段**：`ChatToolTimeline.pairedSegments` 把连续工具合成一组，夹着思考段可能把一组拆成几组；进度卡 `noteTurnSegment` 收到不认识的段。显示上要看一眼（本单不起模拟器，留给验收）。
- **R3 当轮回传形状变了**（Q2-A）：没开思考的工具循环也会多发「调工具前那段正文」和服务端搜索块，续轮输入变大（搜索结果块可能很大，未查证多大）。
- **R4 首字变慢**：summarized 比 omitted 慢（R2）；她嫌慢可以把「思考过程」切成隐藏。
- **R5 升级后第一回合缓存**：thinking 字段从「不写」变成「显式 adaptive + display」，按文档显式默认值不断缓存，display 算不算没写（未查证），最坏每个对话重写一次。
- **R6 中转**：不认 display / 剥思考块 / 不透传签名的中转，第一次 400 后靠 §3.6 自愈。
- **R7 和 v4-2 并行时的合并冲突**（§11）。

---

## 11. 排期：和工具抽屉 / 记忆 v4-2 怎么排

### 11.1 本单要碰的文件
| 文件 | 改什么 |
|---|---|
| `Services/ChatService.swift` | AnthropicProvider 收块（流式 / 非流式）、builder 当轮原样回传 + BP4 + 默认档参数、router 暴露块、自愈新支 |
| `Models/ChatToolTypes.swift` | `ToolTurn.assistantContent` |
| `Models/MessageSegment.swift` | `.thinking` 加 `redactedData`、`hasRenderableSegments` |
| `Services/ModelLineage.swift` | 三个血统判断 |
| `Services/ReasoningEffort.swift`、`Services/OutputTokenCap.swift` | 默认档余量、display |
| `Services/ParamCompat.swift`、`Services/ParamErrorClassifier.swift` | `thinking_display` 组、思考块被拒、refusal |
| `Services/APIUsageParser.swift`、`Services/BudgetPreflight.swift` | thinking_tokens、签名不计字 |
| `ViewModels/ConversationViewModel.swift` | `runStreamingTurn` 三个回调 + `cancelAssistantTurn` 落段、`PendingUserQuestion`、预算收尾去块 |
| `Views/CardFlowView.swift`（simpleStaticBody）、`Views/MessageSegmentsView.swift`、`Views/SentRequestBodyView.swift` | 显示、检查器 |
| `Services/TimelineConsolidator.swift`、`Services/ClaudeImporter.swift` | 各 1 处模式匹配 |
| 测试：PromptRealPathGolden（+G8）、InspectorRealPath、ProviderOrdering、OutputTokenCap、ParamCompat / Classifier / AutoAdaptRouter、ReasoningEffort、ToolReplay、BudgetGate + 新 SSE / 段测试；`PromptRealPathHarness`（隔离显示设置） | |
| `manual/facts/model/model-api.md` | 事实层 |

### 11.2 重叠
- **和 #093：几乎全重叠。** #093 分支动过 ChatService、ModelLineage、ParamCompat、ParamErrorClassifier、ToolReplay、CVM 工具循环（+131 行）、InspectorRealPathTests、ProviderOrderingTests、PromptRealPathHarness、G4。→ **必须 #093 先合，thinking 从合完的 master 开工**，不并行。
- **和 v4-2**（以 [plan-memory-v4-2.md](plan-memory-v4-2.md) §十二 为准，我写到一半它出现了）：
  - v4-2 自己声明**不碰** ChatService、ParamCompat、ParamErrorClassifier、ModelLineage、ToolReplay、PromptAssembler、G1–G6；只**新增** G7。
  - 真正共用的只有三处：
    - `ConversationViewModel.swift`：v4-2 改 `extractMemoriesIfNeeded`（CVM:4573 起）+ CC 落地那行旁边（CVM:404）；本单改 `runStreamingTurn` 三个回调（CVM:3824–4430）、`cancelAssistantTurn`（CVM:2240）、`PendingUserQuestion`（CVM:1906）。**区域不交叉**，合并时最多是相邻行的文本冲突。
    - `PromptRealPathHarness.swift` + `PromptRealPathGoldenTests.swift`：两边都只**加**一个场景开关 + 一个金样。**编号撞了**：v4-2 已占 G7 → 本单用 **G8**。
    - 都不改 G1–G6。
  - 本单碰、v4-2 不碰：MessageSegment、TimelineConsolidator（1 处模式匹配）、UsageLedger 以外的一切。v4-2 碰、本单不碰：Memory 模型、MemoryService、SessionCloseout、UsageLedger、记忆页面。
  - 语义上的接口：本单之后普通回复会带「只有思考段」的 segments，正文仍在 `content`；v4-2 的 W1 按消息正文取窗口，不受影响（v4-2 若想让写手看思考，自己决定）。

### 11.3 推荐顺序
1. **#093 合 master**（带着 temperature/top_p 小修、G4 已重录）。thinking 和 v4-2 都等它。
2. **thinking 和 v4-2 可以并行实现，但不能在同一个工位**（每条工位 WIP=1；v4-2 plan 写的是「backend-2 等 #093 合完再动手」）：
   - 推荐：v4-2 留在 backend-2（它的 plan 就这么写的），thinking 另找一个空的热工位（`zone list` 挑，别建新的冷工位）。
   - 两边都从合完 #093 的 master 开工。
   - 如果只能有一个在跑（额度 / 编译锁），按你默认的 **#093 → thinking → v4-2**：thinking 小、直接解锁「opus 推理强度能调」。
3. 谁先做完谁先交合并；后交的那单 `git merge master`，解 CVM 和 harness 的相邻行冲突（都是纯追加），再跑一遍全部金样。
- **金样每次落地只录一次**：
  - #093：G4 已录（只去掉 top_p），Warden 集成区按最新 master 跑一遍。
  - thinking：只在执行清单第 13 步录 **G8** 一次；G1–G6（和先合进来的 G7）**不许变**，变了是 bug，不重录。
  - v4-2：只录 G7 一次（它的第 12 步）；G1–G6（和先合进来的 G8）同样不许变。
  - 两单都不重录别人的金样；后合的只需确认 G1–G8 全绿。

---

## 12. 要粟粟拍板（每条第一个是推荐；说 go 时没单独回的按推荐走）

- **Q1 历史回合的思考块**
  - **A（推荐）**：一律不带，只在当轮工具循环里原样带。字节稳、不额外花输入、不会撞前缀校验。
  - B：只带最近一个已完成回合的。新账号多半 400（〔状态〕挪走了那条用户消息）。
  - C：全带 + beta 头 `thinking-binding-controls-2026-08-01` + `drop_block`，让 API 自己丢过不了的。要处理 `input_transformations`，被丢的位置往后缓存断。
- **Q2 当轮回传的形状**
  - **A（推荐）**：这一次回复的所有块原样回传（思考、正文、进度更新、服务端搜索块、tool_use），只换审批卡改过的 input。最贴官方「原样回传」。
  - B：只在 tool_use 前面补思考块，其余照旧。中间夹着正文 / 进度更新时会把思考块变「连续」，可能被判改过。
- **Q3 思考显示**
  - **A（推荐）**：「思考过程」设置不是「隐藏」时向新模型要摘要（display summarized），完成后折叠显示；隐藏时不要摘要（首字更快）。不新增设置。
  - B：一律不要摘要，只存签名、不显示。
  - C：单独加一个「显示模型思考」开关。
- **Q4 流式时**
  - **A（推荐）**：v1 不实时显示思考文字，回复完成后出现。
  - B：边想边显示摘要（要改 ArticleStreamingBody / SegmentedAssistantBody 的流式路径，性能页要过 playbook-perf）。
- **Q5 推理档「默认」**
  - **A（推荐）**：默认就会想的模型（Opus 5 / 5.5、Sonnet 5 / 5.5、Haiku 5.5、Fable、Mythos）显式写 adaptive、按官方默认档留余量；Opus 4.6–4.8 / Sonnet 4.6 / 老模型「默认」照旧不想。
  - B：维持现状（默认档不留余量，思考和正文挤 32768）。
- **Q6 redacted 怎么存**
  - **A（推荐）**：`.thinking` 段加可选字段 `redactedData`，老版本读成空思考不炸。
  - B：只存一段空思考、丢掉 data（历史不回传，用不上）。
- **Q7 OpenAI 兼容 / OpenRouter**
  - **A（推荐）**：本单只做 Anthropic 直连；OpenRouter 的 `reasoning_details` 当轮回传 + reasoning 显示另开一单（交 Dex 登记）。
  - B：本单一起做（OpenAI 兼容 SSE / builder / 分类器各多一份，测试翻倍）。
- **Q8 正文里的 `<thinking>` 人设段**
  - **A（推荐）**：不替你动；真遇到 `reasoning_extraction` 拒绝时气泡说人话，验收说明里写清楚在哪个槽位、要不要删你定。
  - B：检查器像预填那样标一行提醒。
- **Q9 保险闸**
  - **A（推荐）**：开思考时期望输出按 4096 + 这一档余量估（宁可多估）；签名不计字。
  - B：照旧 4096。

---

## 13. 未查证
1. opus-5-5 现在（默认档、不发 thinking 字段）工具续轮不带思考块，API 是静默关思考还是报错。粟粟没报过错，推测静默降级。
2. 粟粟的组织是不是 2026-08-31 以后建的（决定前缀校验默认开不开）。Q1-A 下不影响。
3. 显式写 `thinking: {type: adaptive}` + `display: summarized` 会不会让每个对话第一回合缓存重写一次（文档只说显式默认值 = 不写；display 没说）。
4. 摘要的语言：中文对话里摘要是不是中文；「叫主人」口吻不保证。
5. 她正文里的 `<thinking>` 会不会触发 `reasoning_extraction` 拒绝。
6. 签名多长（存储增长只能估量级）。
7. 审批卡改过 tool_use input 后当轮回传：按 R8 改的是思考块后面的块，应当合法；没有实测。
8. Haiku 5（5.0）默认想不想、display 默认是什么（文档表里没有这个模型；先按 haiku ≥5.5 算）。
9. budget 模式（Sonnet 4.5 等）不加 interleaved 头时，续轮只靠第一次的思考，行为没实测；不加头。
10. 中转（OpenRouter 的 Anthropic 协议口、Vertex、Bedrock、国内中转）认不认 `display`、透不透传思考块和签名。
11. `thinking.display` 被拒、思考块被拒的报错原文（样本按文档措辞推断；文档给了「Invalid `signature` in `thinking` block…」这一句原文）。
12. 服务端搜索块原样回传让续轮输入涨多少。
13. UIKit 新聊天页（原生 cell）是不是和 CardFlowView 用同一个 `hasRenderableSegments` 判断——没读那部分代码，实现第 11 步要先确认。
14. `OfficialTokenCounter`（count_tokens）收不收带思考块的 body。
15. 缓存回看窗口 20 块：思考块让每轮块数变多，工具轮很多时 BP4 往前找不找得到上一次写入。
16. DeepSeek / Kimi 等 `reasoning_content` 在工具续轮里要不要回传（各家不同；本单不做）。
17. 进度更新思考块在 `display: summarized` 下和普通思考块分不出来（文档原话），显示上都叫「思考」。

## 14. 验收说明要写的（`~/Desktop/cc-rp/API链路/thinking-验收.md`）
- 合进来以后，opus 的推理强度**可以从「默认」调走了**（任务书第 7 条）；调了之后这个对话下一回合缓存整段重写一次（R11），之后恢复。
- 怎么在检查器里核：第 1 次请求看 thinking 参数行；调工具的回合切到第 2 次看「回传思考块 N 个」。
- 「思考过程」设置隐藏 = 不要摘要（更快）；原地 / 弹出 = 要摘要。
- 正文 `<thinking>` 那段在哪个槽位、和原生思考的关系、要不要删。
- 真请求实测三项（§9）要她点头才打。

---

## 15. 执行清单（每项单独 commit，可单独撤）

- [x] ✅ 0 本 plan（等批）
- [x] ✅ 1 `git merge master`（#093 已合后）；`ModelLineage.thinksByDefault / defaultEffort / displayDefaultOmitted` + 血统单测
- [x] ✅ 2 AnthropicProvider 流式按 index 原样收全块（思考 / redacted / 签名 / 正文 / tool_use / server 块，完整标记）+ SSE 夹具单测
- [x] ✅ 3 非流式 `parseNonStreamBody` 同款 + 单测
- [x] ✅ 4 用量：`thinking_tokens` → reasoningTokens + 单测
- [x] ✅ 5 `MessageSegment.thinking` 加 `redactedData`（编解码兼容）+ 3 处模式匹配 + 编解码单测
- [x] ✅ 6 router 暴露 `lastAssistantBlocks`；VM 落段（onToolCalls / onComplete / onError / 停止，普通回复只挂思考段且挂在原逻辑之后）；`hasRenderableSegments` 排除只有思考的；逐类核 segments 读点 + 单测（历史字节不变、卡片索引、记忆输入）
- [x] ✅ 7 `ToolTurn.assistantContent` + Anthropic builder 原样回传（只换改过的 input）+ `PendingUserQuestion` 带块 + 单测
- [x] ✅ 8 预算收尾去思考块；BP4 不落在思考块 + 单测
- [x] ✅ 9 参数：默认档 adaptive + 余量、display 跟「思考过程」设置、老模型不发 display；harness 隔离显示设置 + OutputTokenCap / ReasoningEffort 单测
- [x] ✅ 10 分类器：`thinking_display` 组、思考块被拒去块重发一次、refusal `reasoning_extraction` 说人话 + 样本 + 单测
- [x] ✅ 11 保险闸：签名不计字、开思考期望输出加余量 + BudgetGate 单测
- [x] ✅ 12 显示（**simpleStaticBody 没改：CardFlowView 本单禁区**，改了气泡模式 / 页 2 网页聊天，见 review）：simpleStaticBody 读原生思考段；MessageSegmentsView 空思考不画；先确认 UIKit 新聊天页走哪条（§13-13）
- [x] ✅ 13 检查器：思考参数行、回传块数、签名缩写显示（复制保留原文）+ InspectorRealPathTests；金样核 G1–G6 不变、录 G8、ProviderOrdering 当轮回传夹具
- [x] ✅ 14 定向全跑（§9 列表）+ mac / iOS build-for-testing 交集成区
- [x] ✅ 15 astra 审一轮、逐条裁（车头派；7 条全收，见 review「astra 一轮裁决」）
- [x] ✅ 16 复盘 `docs/review-thinking.md` + 验收说明 + `docs/now/<工位>.md` + `manual/facts/model/model-api.md`
- [x] ✅ 17 真请求实测（车头 10-15 用 Haiku 5.5，见 review「真请求实测」；摘要语言 / 缓存重写未测）
