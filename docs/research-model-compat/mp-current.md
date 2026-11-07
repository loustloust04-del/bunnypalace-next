# research · MP 多 API 提供商层现状底图（对照 magpie / oh-my-pi 用）

> 2026-10-15 · 只读调研，worktree `backend-3`（HEAD 406f97e63）。行号以 `MemoryPalace/` 为根，除非另注。
> 读过的已有文档：`docs/research-api-wave1.md` `docs/review-api-wave1.md` `docs/research-api-真实计费.md` `docs/review-api-真实计费.md` `docs/plan-param-autoadapt.md`（§1–2）`docs/review-param-autoadapt.md` `docs/review-thinking.md` `docs/review-request-body.md` `docs/plan-p-provider-discovery.md`（开头）`docs/research-nonstream-chat.md`（开头）`manual/facts/model/model-api.md`，以及 `~/Desktop/cc-rp/API链路/{参数自适配,请求体修复,thinking}-验收.md`。
> 标记约定：**【推断】** = 读代码得出、没跑过、没测试覆盖；**【文档】** = 来自上面复盘 / 验收文档的自述。

---

## 0. 一页结论

1. **两条 HTTP 主路 + 三条旁路**，全在 `Services/ChatService.swift` 一个 2526 行文件里：`OpenAICompatibleProvider`（:565-1090）、`AnthropicProvider`（:1094-1772）、`ProviderRouter`（:1806-2477）；旁路 `ChatGPTOAuthProvider`（Responses API，`Services/ChatGPTOAuth/ChatGPTOAuthProvider.swift`）、`CCBridgeProvider`（:2481 起，防御 stub，CC 实际走 VM 的 `sendCCFireAndForget`）、`LocalChatProvider`（本机 MLX）。
2. **请求侧有一层半中间表示**：`PromptMessage`（有序消息 + 附件 + 历史工具回合）→ `PromptWire.Plan/Message`（system 前缀 / 降级后的线上消息）→ 各家 wire。**响应侧没有统一中间表示**：只有回调三件套（`onToken(String)` / `onToolCalls([ToolCallBlock])` / `onComplete(String, TokenUsage?)`）+ 规范化的 `TokenUsage`；Anthropic 另有一份原样 JSON 块 `ReplyBlock`，OpenAI 兼容路没有对应物（不解析 reasoning）。
3. **怪癖处理是三套机制叠加**：①`ParamCompat`（学到的 > models.dev 目录 > `ModelLineage` 血统 > 推理档 > 默认）管采样 / 键名 / 思考格式；②按 host 字符串硬编码（`api.openai.com`、`openrouter`）管键名默认值、序列内 system、OR 缓存标与路由、OR 的 `reasoning.effort`；③400/422 报错分类 → 剥参重试一次 + 落盘记忆。**预设（`APIProvider.presets`）本身不带任何怪癖开关**，只有 type / baseURL / extraHeaders / 预填模型；卡上唯一的能力位是 `toolsSupported`。
4. **明显空白**：OpenAI 兼容路完全不解析 `reasoning_content` / `reasoning` / `reasoning_details`；聊天路径没有 429 / 额度 / 529 / 上下文超长 / 内容过滤的识别与重试；模型目录不存 vision / tool_call 能力，`contextTokens` 只用于展示；没有按 token 的上下文裁剪（只按条数 `contextDepth`）；MessageNode 不记生成它的模型。
5. **代码层潜在雷【推断】**：SSE 解析按 `Character` 找 `"\n"`，CRLF 行尾会切不开；每个网络分片单独 `String(data:encoding:.utf8)`，多字节字符被切断时整片丢弃；只认 `"data: "`（带空格）。三处都没有测试覆盖。

---

## 1. 请求链路

### 1.1 主聊天：发消息 → 组装 → 请求体 → SSE → 落库

```
ConversationViewModel.sendMessage            VM:2860
 ├─ CC 卡：assemblePrompt → prepareRouterPayload → sendCCFireAndForget   VM:2949-2955（不走 ProviderRouter）
 └─ startAssistantTurn                        VM:3026
     ├─ toolInjection（按卡类型定 tools 形状）  VM:3070 → toolInjectionDetailed VM:3358
     ├─ assemblePrompt → composePrompt        VM:3075 → VM:2302 → VM:2335
     │    ├─ windowedHistory（按 preset.sampling.contextDepth 条数）  VM:2360-2370
     │    ├─ SendContextResolver.resolve（身份 / 世界书）               VM:2378
     │    ├─ PromptAssembler.assembleTagged（预设插槽 / 记忆 / 动态段） VM:2424
     │    └─ PromptAssembler.orderedMessages + 按节点 id 挂图片、挂工具回合 → [PromptMessage]  VM:2458-2461
     ├─ prepareRouterPayload                  VM:3080 → VM:2543
     │    ├─ withEffectiveEffort（推理档按模型取最近一档）              VM:2561
     │    ├─ OR + cacheFriendly → x-session-id 头                       VM:2565-2571
     │    └─ ToolReplay.orderedForProvider / offeredOnly（不支持真工具块的退纯文字） VM:2573-2582
     └─ runStreamingTurn                      VM:3083 → VM:3947
          └─ ProviderRouter.sendStreaming     ChatService:1908
               ├─ OutputTokenCap.resolved（定可见输出上限）            :1937
               ├─ adaptedSampling（ParamCompat.supported 剥参）        :1947 / :2371
               ├─ 账本 / 预算闭包 record / finished / requestFailed    :1950-2015
               ├─ 按 provider.type 分派：localMLX :2018 / chatgptOAuth :2028 / ccBridge·openai·anthropic :2091-2106 / unsupported 明确报错 :2101
               ├─ adaptiveFailed（400 自愈，见 §3）                    :2117-2183
               └─ chatProvider.sendStreaming(... ordered: ...)        :2191
                    ├─ buildRequestBody(ordered:)  OpenAI :704 / Anthropic :1227
                    ├─ SentShape 记下实发顶层键                         OpenAI :646 / Anthropic :1197
                    └─ startRequest → BudgetPreflight（保险闸，可能先调官方 count_tokens）:287-313
                         → startBudgetCheckedRequest（每次新 URLSession + 代际守卫）:315-326
                         → URLSessionDataDelegate：按 Content-Type 判 SSE / 整包       :478-486, :423-436
                         → processData：OpenAI :979 / Anthropic :1584
                         → 完成：[DONE] :995 / message_stop :1737；整包走 parseNonStreamBody + 假流式 :188-251
 VM 回调：
   onComplete  VM:3984 —— 正则→refusal 尾注→content/segments→attachThinking→webSources→usage→save→记忆提取 / 标题 / 上下文总结
   onToolCalls VM:4081 —— 存段（replySegments 思考→正文）→执行工具→continueToolLoop VM:3869 → 再 runStreamingTurn（带 toolTurns）
   onError     VM:4056 —— 报错文字以「⚠️ …」写进节点 content / 段（落库，进下一轮历史前会被组装层处理）
```

- **预览 = 实发**：检查器用 `ProviderRouter.previewRequestBody`（:2379-2446），和实发同一组 builder + 同一个 `adaptedSampling`；金样 `PromptRealPathGoldenTests` G1–G8 + `InspectorRealPathTests` 锁住【文档：review-param-autoadapt / review-thinking】。真发那一刻 `onRequestSent` → `SentRequestStore` 存一份脱敏 body（:1897-1906, :324）。
- **非流式**：同一个 `sendStreaming`，靠服务器实回的 Content-Type 判（不信请求里的 `stream:false`）；缺头但 body 像 SSE 的中转也认（:425-434）；整包解析后假流式吐字（:203-251）。整包 JSON 里落单 `\uD800` 转义会被换成 `�` 再解（:150-177，给 node 写的 claude-proxy 用）。
- **后台调用**（记忆写手 / 摘要 / 标题 / 图片转述）：`ProviderRouter.sendNonStreaming`（:2226-2338）→ provider 的 `sendNonStreaming`（OpenAI :889 / Anthropic :1479），**每次 new 一个 provider 实例**、不带工具、不过 ParamCompat、不进 400 自愈；OpenAI 口连输出上限都不带，Anthropic 只带 `max_tokens = min(8192, 模型上限)`（:1500）。

### 1.2 中间表示（有没有统一 IR）

| 层 | 类型 | 位置 | 说明 |
|---|---|---|---|
| 组装输出 | `PromptMessage` | `Services/PromptAssembler.swift:31-80` | role(system/user/assistant) + 文本 + `source` + `nodeId` + `pinnedToSystemPrefix` + `attachments` + `toolRounds`。**provider 无关**，检查器也看它 |
| 历史工具回合 | `ToolReplayRound` | `Services/ToolReplay.swift:6-13` | 一轮 = 前置文本 + calls + results + ask 回答；从节点 `segments` 还原（:24-82），**不含思考段** |
| 当轮工具回合 | `ToolTurn` | `Models/ChatToolTypes.swift:34-50` | calls + results + `assistantContent`（Anthropic 原样块，OpenAI 为 nil）+ `thinkingTokens` |
| 线上计划 | `PromptWire.Plan / Message` | `ChatService.swift:503-561` | 定 system 前缀；非前缀 system 原位保留（`.interleaved`）或降级 `<system_note>` user 块并合并相邻同 role（`.degradeToUserNote`） |
| 各家 wire | `openAIWire` / `anthropicWire` / `ChatGPTOAuthProvider.buildRequestBody` | :731 / :1250 / OAuth:265 | 字典拼装，非 Codable |
| 采样 | `SamplingParams` + `ParamCompat` | `Models/Preset.swift:57-78`；`Services/ParamCompat.swift` | 预设原值 → `OutputTokenCap.resolved` → `ParamCompat.supported` 剥成「不发」的哨兵值（temperature/top_p=1.0、top_k=0、seed=-1、effort=auto） |
| 响应 | 回调 + `ToolCallBlock` + `TokenUsage` | `ChatToolTypes.swift:6-13`；`Utils/BudgetCalculator.swift:8` | **没有统一的「回复内容块」IR**。思考只在 Anthropic 路以 `ReplyBlock`（原样 JSON + complete 标志，`ChatToolTypes.swift:54-96`）存在 |
| 用量 | `TokenUsage` | `Utils/BudgetCalculator.swift:8`；解析 `Services/APIUsageParser.swift` | 规范化：input / output / cacheRead / cacheWrite / cacheWrite1h / reasoning / reportedCost / webSearches / responseId / completeness |
| 落库 | `MessageNode.content` + `segments`（`.text/.toolUse/.toolResult/.thinking(text,signature,redactedData)/.image…`） | `Models/Conversation.swift:134-230`；`Models/MessageSegment.swift` | **节点不记 provider / 模型**（只有 usage 账本按 `messageNodeId` 记），见 §6 |

结论：请求侧接近「一个 provider 无关 IR + 两个 renderer」；响应侧是「各家 parser 直接驱动 VM 回调」，思考 / 引用 / server 块只在 Anthropic 路有结构。

### 1.3 两条路各自在哪

| | OpenAI 兼容 | Anthropic |
|---|---|---|
| 类 | `OpenAICompatibleProvider` :565 | `AnthropicProvider` :1094 |
| 端点 | `baseURL + "/chat/completions"` :656 | `baseURL + "/messages"` :1204 |
| 鉴权 | `Authorization: Bearer` :664 | `x-api-key` :1212；`anthropic-version` 只来自卡的 `extraHeaders`（预设 `APIProvider.swift:231,372,382`、自定义卡编辑器 `Views/APICredentialEditor.swift:248`），**无 anthropic-beta** |
| body builder | :704（有序）→ :779（通用） | :1227（有序）→ :1316（通用） |
| 历史工具回放 | `openAIWire` :731（assistant{tool_calls, content:""} + role:tool） | `anthropicWire` :1250（assistant[text?, tool_use] + user[tool_result]，空正文时后续 user 并进 tool_result 消息） |
| 当轮 toolTurns | :809-820（只发 calls，忽略 assistantContent） | :1341-1354 + `toolTurnAssistantContent` :1432（原样块回传） |
| SSE | `processData` :979 → `parseOpenAIChunk` :1015 | `processData` :1584 → `handleAnthropicEvent` :1638 |
| 整包 | `parseNonStreamBody` :953 | :1541 |
| 其他 | OR 缓存标 / 路由 / 前缀分歧探针 :570-597, :675-689 | cache_control 黑名单 + sticky user_id :1116-1152；server web search sources :1668-1686 |

ChatGPT OAuth（Responses API）：`input` 用 `input_text/output_text`，system → `instructions`，`store:false`，tools 从 Chat 形状平铺转换，toolTurns → `function_call/function_call_output`，effort → `reasoning.effort`，**不发任何采样参数、不发输出上限、图片丢弃**（`imageMap` 收了没用：OAuth:30 收参、:43 调 builder 不传）。SSE 只认 `output_text.delta` / function_call 事件 / `*.completed` / `*.error`（OAuth:133-191），不解析 reasoning summary。

---

## 2. 厂商 / 模型怪癖：已处理清单

「判定方式」列：**host** = 按 baseURL 主机名字符串硬编码；**血统** = `ModelLineage` 解析模型名；**目录** = models.dev；**学到** = `ParamAdaptStore`；**卡类型** = `ProviderType`；**硬编码** = 无条件。

### 2.1 输出上限

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| 字段名 `max_tokens` vs `max_completion_tokens` | OpenAI 兼容：学到的键名 > `api.openai.com` 用 `max_completion_tokens` > 其余 `max_tokens`。Anthropic 恒 `max_tokens`。OAuth 不发 | 学到 > host | `ParamCompat.swift:71-72`；`ChatService.swift:843`；`:1370` |
| 上限数值 | 自动档 = min(目录 `limit.output` ?? 16384, 32768)；手动档 = min(她设的, 模型上限) | 目录 | `OutputTokenCap.swift:11-31` |
| 上限太大被拒 | 400/422 正文提到上限 → 降到 8192 重发一次（不记）；认出是键名错则改名不降 | 报错分类 | `ChatService.swift:2134-2139, 2167-2170`；`ParamErrorClassifier.swift:148-162` |
| 思考余量 | Anthropic 思考预算加在可见上限之上：low 1024 / medium 4096 / high 10000 / xhigh 16000 / max 32000，总数封顶模型上限 | 血统 | `ReasoningEffort.swift:152-192` |
| 截断的工具调用 | `finish_reason=length` / `stop_reason=max_tokens` → 最后一个 call 标 truncated、不执行；连续 2 轮停 | 硬编码 | `ChatToolTypes.swift:15-23`；`ChatService.swift:1054, 1003, 1728, 1746`；VM onToolCalls |

### 2.2 采样参数

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| 推理模型禁采样（temperature/top_p/top_k/penalty） | `ParamCompat.resolve`：学到 `sampling` 组 → 目录 `temperature:false` → 血统 `rejectsSampling`（opus ≥4.7、sonnet/fable/mythos ≥5、haiku ≥5.5、OpenAI o 系、GPT ≥5，主版本 <10）→ 推理档非 auto/none 且（官方 host 或 OpenAI 血统） | 学到 > 目录 > 血统 > 推理档 | `ParamCompat.swift:66-96`；`ModelLineage.swift:46-64` |
| temperature 与 top_p 只收一个 | Anthropic 血统 opus ≥4.1、sonnet/haiku ≥4.5（且未整组禁）→ 两个都要发时去 top_p；也可学到 `single_sampler` | 血统 / 学到 | `ModelLineage.swift:66-76`；`ParamCompat.swift:75,110-112`；`ChatService.swift:839, 1394-1396` |
| 开思考时的采样 | Anthropic 开 thinking：不发 temperature/top_k，top_p 只在 [0.95,1) 发 | 硬编码 | `ChatService.swift:1386-1391` |
| 各参数的发送范围 | OpenAI 兼容：temperature / top_p / frequency_penalty / presence_penalty / seed（不发 top_k）；Anthropic：temperature / top_p / top_k（不发 penalty / seed）；默认值不发（temp/top_p == 1.0、penalty == 0、seed < 0、top_k == 0） | 卡类型 | `ChatService.swift:835-848`；`:1392-1398` |
| 预设默认值 | temperature 0.7、top_p 0.95 → 默认每条都带两者 | — | `Preset.swift:58-59` |
| 无效字段 | `maxContextSize`、`verbosity`、`squashSystemMessages`、`continuePrefill`、`postProcessingMode` 只在酒馆预设导入导出里读写，**发送路径不用** | — | `Preset.swift:185-191, 267-273`（全仓 grep 无其他读点） |

### 2.3 system / developer / 预填

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| developer role | **没有**。全仓无 `developer` 角色转换（只有注释提一句） | — | `ChatService.swift:692` 注释 |
| 序列中间的 system | 只有 `api.openai.com`、`openrouter.ai` + `openai/*` 模型原位发 role:system；其余一律降级成 `<system_note>…</system_note>` user 块并合并相邻同 role | host + 模型前缀 | `ChatService.swift:691-699`；`PromptWire.plan` :526-560 |
| Anthropic system | 开头连续 system（+ pinned 段）并成顶层 `system`；其余降级 | 卡类型 | `:1223-1246` |
| system 缓存块 | cacheFriendly 时 Anthropic system 变 `[{text, cache_control}]`；OR+claude 时 system 首条同样包成块 | 卡类型 / host | `:1403-1407`；`:858-861` |
| 末条 assistant（预填） | 组装层：历史以 assistant 结尾时补一条合成 user（不入库）；预设深度 0 的 assistant 段仍会让末条是 assistant → 只记诊断日志「新模型可能不认」；被拒时说人话不重试 | 硬编码 + 报错分类 | VM:2366-2370, 2463-2466；`ParamErrorClassifier.swift:167-169` |
| ChatGPT OAuth | system → `instructions` | 卡类型 | OAuth:314-316 |

### 2.4 推理 / 思考：请求侧

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| 路由 | Anthropic：`anthropicAdaptive`（opus ≥4.7、sonnet/haiku ≥5、fable/mythos）→ `thinking:{type:adaptive}` + `output_config.effort`；否则 `thinking:{type:enabled,budget_tokens}`。OpenAI 兼容：host 以 `openrouter.ai` 结尾 → `reasoning:{effort}`，否则 `reasoning_effort`。OAuth → `reasoning:{effort}` | 血统 / host / 卡类型 | `ReasoningEffort.swift:32-48, 170-202`；`ModelLineage.swift:78-87` |
| 学到的思考格式 | `thinkingFormat` adaptive/budget 覆盖血统 | 学到 | `ParamCompat.swift:73` |
| 「默认」档 | 不发参数也会想的模型（opus/sonnet ≥5、haiku ≥5.5、fable、mythos）显式写 `thinking:{type:adaptive}`、不发 output_config，并按官方默认档（opus 5.5 / haiku 5.5 = medium，其余 high）加余量；其他模型「默认」不发 | 血统 | `ReasoningEffort.swift:180-183`；`ModelLineage.swift:89-107` |
| 思考摘要 | 「思考过程」设置非隐藏 + 默认 omitted 的模型（opus ≥4.7、sonnet ≥5、haiku ≥5.5、fable/mythos）→ `display: summarized`；学到不收则不发 | 血统 + 设置 + 学到 | `ReasoningEffort.swift:163-178`；`ModelLineage.swift:109-119` |
| 档位列表 | 目录 `reasoning_options[type=effort].values` → 目录说不推理 = 只有默认 → 小补表（adaptive 5 档 / budget 4 档 / 其他 3 档） | 目录 > 路由兜底 | `ReasoningEffort.swift:50-70` |
| 换模型档位 | 每「卡/模型」本机记一档，换模型取最近一档（magpie nearestEffort） | — | `ReasoningEffort.swift:76-109`；VM:2561 |
| 「关」档在默认会想的模型上 | 仍是「不发 thinking」= 实际在想【文档：review-thinking §1，未改】 | — | — |

### 2.5 推理 / 思考：响应解析

| 兼容点 | OpenAI 兼容 | Anthropic | ChatGPT OAuth | 本机 |
|---|---|---|---|---|
| 思考文本 | **不解析**：只读 `delta.content`（:1067）；`reasoning_content` / `reasoning` / `reasoning_details` / `<think>` 全被丢弃（全仓 grep 无这些键） | `thinking_delta` 拼进块（:1702-1703），`signature_delta`（:1704-1705），`redacted_thinking` 整块（content_block_start 原样记 :1663）；`citations_delta`（:1706-1710） | 不解析 reasoning summary | `<think>` → `[thinking]` 转换（`ReasoningEffort.swift:205-231`） |
| 思考 token 计数 | `completion_tokens_details.reasoning_tokens`（`APIUsageParser.swift:23`）；Gemini 主机读 `usageMetadata.thoughtsTokenCount`（:24-32） | `usage.output_tokens_details.thinking_tokens`（:1621-1623） | `output_tokens_details.reasoning_tokens`（OAuth:254） | — |
| 块完整性 | — | 思考块必须有签名才算 complete；不完整的不回传、只存文字（:1607-1611；`ChatToolTypes.swift:66-95`） | — | — |
| 落库 | — | 工具回复：段里按顺序 思考→正文→工具；普通回复：`[.text(content), 思考…]`（VM:3781-3809） | — | `[thinking]` 标签在 content 里 |
| refusal | — | `stop_reason: refusal` 读 `stop_details.category`，只有 `reasoning_extraction` 出尾注（:1613-1617, :1729；`ParamErrorClassifier.swift:213-216`；VM:3988-3993） | — | — |

### 2.6 思考签名回放

| 场景 | 现状 | 证据 |
|---|---|---|
| 当轮工具循环（Anthropic） | 这一次回复的全部块原样回传（思考 / redacted / 正文 / server_tool_use / tool_use），只把 tool_use 的 input 换成实发那份；id 集合对不上 → 退回只发 tool_use；某个 tool_use 被改过 → 它之后的思考块全去掉 | `ChatService.swift:1429-1458`；VM:4482, 4494 |
| 空 text 块 | 回传时去掉（API 不收空 text） | `ChatToolTypes.swift:66-73` |
| 思考块被拒 | 400/422 + 正文认出「thinking block cannot be modified / invalid signature」→ 不学、这次去块重发一次，本回合后续几轮也不带 | `ChatService.swift:2141-2158`；`ParamErrorClassifier.swift:193-197`；VM:4085-4088 |
| 预算收尾那次（tools: nil） | 去掉思考块 | VM:3911 |
| BP4 缓存标 | 挂在最后一个非思考块上 | `ChatService.swift:1411-1419` |
| 历史回合 | **不回传思考**（Q1）；`ToolReplay.rounds` 遇 `.thinking` 段走 default 跳过 | `ToolReplay.swift:50-78`【文档：thinking 验收 Q1】 |
| OpenAI 兼容 / OpenRouter 上的 Claude | toolTurns 不带任何思考（builder 只用 calls，:809-820）；OR `reasoning_details` 未回传 = **Q7 债** | 【文档：review-thinking §3】 |

### 2.7 工具调用

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| schema 形状 | 两家渲染器：OpenAI `{type:function,function:{…parameters}}`；Anthropic `{name,description,input_schema}`；OAuth 用 OpenAI 形状再平铺 | 卡类型（`provider.type == .anthropic ? .anthropic : .openAI`） | `Services/Tools/ToolDefinition.swift:91-112`；VM:3318, 3378 |
| 顺序 | 按 name 字典序固定（防缓存抖动） | 硬编码 | VM:3415-3416 |
| server web search | `type == .anthropic` 的卡 + 权限开 → 发 `web_search_20250305` server tool；**按卡类型判，不看 host**（中转 / 代理同样会收到）【推断：中转不认时会 400，现有分类器不认 `tools`】 | 卡类型 | VM:3393-3397；`WebSearchToolService.swift:31-43` |
| 卡级关工具 | `toolsSupported == false` → 不发 tools、system 不提工具 | 卡字段 | `APIProvider.swift:94-97`；VM:3316, 3361 |
| CC / 本机 | 不下发工具 | 卡类型 | VM:3371-3372 |
| 流式解析（OpenAI） | 按 `index` 累积 id/name/args；**id/name 非空才覆盖**（DeepSeek 后续分片发 ""）；`index` 缺省当 0；在 `[DONE]` 时累积非空就当工具轮，**不看 `finish_reason == "tool_calls"`** | 硬编码 | `ChatService.swift:1074-1088, 995-1008` |
| 流式解析（Anthropic） | `content_block_start` 记 id/name，`partial_json` 拼接；只有 `stop_reason ∈ {tool_use, max_tokens}` 才发工具轮 | 硬编码 | `:1660-1667, 1699-1701, 1741-1749` |
| 整包解析 | OpenAI 读 `message.tool_calls`；Anthropic 读 `tool_use` 块，`stop_reason` 不是 tool_use/max_tokens 则清空 calls | 硬编码 | `:965-972`；`:1557-1580` |
| 历史回放 id / 名字 | id 非 `[A-Za-z0-9_-]` 换 `_`、截 64、撞车加序号；名字不合法 → 整节点退纯文字 | 硬编码（按 Anthropic 规则统一做） | `ToolReplay.swift:84-92, 56-65` |
| 历史结果 | 超 2KB 截断 + 存档路径提示 | 硬编码 | `ToolReplay.swift:95-111` |
| 不发真块的情况 | 没下发客户端工具 / 调过这一轮没有的工具 / OAuth / 本机 → 退纯文字 +〔系统记录〕 | 卡类型 + 工具集合 | `ToolReplay.swift:136-212` |
| OpenAI 历史 tool_calls 的 content | 发 `""`（个别端点可能要 null）【文档：review-request-body §3，没逐家测】 | 硬编码 | `ChatService.swift:751, 811` |
| `tool_choice` / `parallel_tool_calls` | 不发 | — | 【文档：plan-param-autoadapt §1.2】 |

### 2.8 用量 / 缓存

| 兼容点 | 现状 | 判定方式 | 证据 |
|---|---|---|---|
| 流式要 usage | 恒发 `stream_options:{include_usage:true}`；学到不收可去 | 硬编码 + 学到 | `ChatService.swift:827, 850` |
| OpenAI 缓存读 | `prompt_cache_hit_tokens`（DeepSeek）优先，否则 `prompt_tokens_details.cached_tokens` | 硬编码字段兜底 | `APIUsageParser.swift:34`；`ChatService.swift:1044` |
| OR 缓存写 / 实价 | `prompt_tokens_details.cache_write_tokens`；OR 主机读 `usage.cost` 当实价；记 `id` 供断流后 `/generation` 补查 | host（`https://openrouter.ai`） | `APIUsageParser.swift:4-7, 11-13, 35`；`ChatService.swift:1020-1022, 1977-1984` |
| Gemini 思考计费 | 只有响应带 `usageMetadata` 分桶时才把 thoughts 加进输出，否则保持 completion_tokens（是否已含待实测） | host | `APIUsageParser.swift:24-32` |
| Anthropic 缓存 | `cache_read_input_tokens` / `cache_creation_input_tokens` / `cache_creation.ephemeral_{5m,1h}_input_tokens`；`server_tool_use.web_search_requests` | 硬编码 | `ChatService.swift:1619-1636`；`APIUsageParser.swift:42-53` |
| OR + Claude 缓存标 | cacheFriendly + host 含 `openrouter` + 模型 `anthropic/` 前缀或含 `claude` → system 块与最后一条 assistant 挂 `cache_control:{ephemeral, ttl:1h}` | host + 模型名子串 | `ChatService.swift:677-682, 851-867` |
| OR 路由 | cacheFriendly + OR + `deepseek/` 前缀 → `provider:{order:[deepseek], allow_fallbacks:true}` | host + 模型前缀 | `:685-689, 868-872` |
| OR sticky | cacheFriendly + OR → `x-session-id: mp-<对话id>` | host | VM:2565-2571 |
| Anthropic 缓存标 | cacheFriendly → BP1 system、BP4 最后 assistant 末个非思考块；`metadata.user_id` 固定 sticky | 卡类型 | `ChatService.swift:1402-1425, 1138-1145` |
| cache_control 被拒 | 4xx 正文含 "cache" → 该 baseURL 拉黑（规整后比对），**下一次**才降级，这次不重试 | 报错子串 + 落盘 | `:1116-1152` |
| 价格 / 计费 | 见 §4.3 | — | — |

### 2.9 stop reason / 结束

| | 识别的 | 不识别的 |
|---|---|---|
| OpenAI 兼容 | `finish_reason == "length"` → 撞上限（:1054, :973）；`[DONE]` 结束 | `content_filter`、`tool_calls`（靠累积判）、`stop`；`delta.refusal` |
| Anthropic | `tool_use` / `max_tokens` / `refusal`（+category）（:1726-1729） | `pause_turn`、`model_context_window_exceeded`、`stop_sequence`（都当普通完成） |
| OAuth | `response.completed` / `.done`（OAuth:178） | `response.incomplete` / 失败原因 |
| 通用 | 200 但无内容 → 「未收到回复」（:466-470） | — |

### 2.10 图片 / 附件

| 兼容点 | 现状 | 证据 |
|---|---|---|
| OpenAI 形状 | `image_url` + `data:<mime>;base64,…` | `ChatService.swift:876-887` |
| Anthropic 形状 | `{type:image, source:{type:base64, media_type, data}}` | `:1460-1477` |
| 范围 | 只挂在 user 消息上；按节点 id 挂（不按正文匹配） | `:771-776, 1303-1313`；VM:2448-2461 |
| 数量 / 旧图 | 最近 `maxImagesToModel`（默认 20）张；3 条之前的旧图有转述就换成 `[图片: 描述]` | VM:2735-2760 |
| 能力判断 | **没有任何 vision 能力判断**（目录不存 modalities），不支持图的模型照发 | 全仓 grep 无 `vision/modalities` |
| ChatGPT OAuth | **图片丢弃**（`imageMap` 收参不用） | OAuth:30, 43, 265-276 |
| 本机模型 | 只传 `hasImages` 标志 | `ChatService.swift:2021-2023` |

### 2.11 传输 / 解析层的其他兼容

| 兼容点 | 现状 | 证据 |
|---|---|---|
| Base URL 规整 | 去空白换行、补 https、剥 `/chat/completions` `/messages` `/models` 尾巴、去尾斜杠、只有域名补 `/v1`；带 `?` 的不动（Azure `api-version` 拼不对，未修） | `Models/BaseURLNormalizer.swift:10-27`；【文档：review-api-wave1 §1】 |
| 缺 SSE 头的中转 | 200 + 无 event-stream 头但 body 以 `data:` / `event:` / `:` 开头 → 当 SSE | `ChatService.swift:425-434` |
| 无视 stream:false 的中转 | 按实回 Content-Type 判 | `:478-486` |
| SSE 行切分【推断·风险】 | `buffer.firstIndex(of: "\n")` 按 `Character` 找；Swift 里 `"\r\n"` 是单个 grapheme，**CRLF 行尾切不开**（同族坑见记忆 `feedback_swift_crlf_single_grapheme`，MCP 已踩过）；没有 CRLF 用例 | `:989`, `:1594` |
| `data:` 无空格【推断·风险】 | 只认 `"data: "`、`"event: "` | `:993`, `:1598`, `:1600`（OAuth 认 `data:`，OAuth:140） |
| 多字节字符跨分片【推断·风险】 | 每个 `didReceive data` 分片单独 `String(data:encoding:.utf8)`，切在中文字中间 → 返回 nil → **整片丢弃**（含其中的完整行） | `:980`, `:1585`；OAuth:117 |
| 错误事件 | OpenAI：chunk 里没有 `choices[0].delta` 且有 `error.message` → onError（:1055-1063）；Anthropic：`event: error`（:1752-1760）。状态码仍是 200 → 不进 400 自愈 | 同左 |
| 陈旧回调 | 每次请求新 URLSession + 代际号，过期回调丢弃 | `:387-421` |
| 超时 | 非流式档 600s，流式用 URLSession 默认 | `:669`, `:1217` |
| 未知卡类型 | 解码成 `.unsupported`，所有网络路径明确报错，绝不降级成 openaiCompatible | `APIProvider.swift:8-27`；`ChatService.swift:2101-2105` |

---

## 3. 参数自适配（#094 + thinking 补丁）现状

**参照来源**【文档：plan-param-autoadapt §2】：认报错抄 magpie `gateway.go refusedOptional / unsupportedOptionalField / unfit`；血统 + 统一剥参抄 oh-my-pi `pi-catalog compat/taxonomy.ts`、`rules/{taxonomy,classes}/{anthropic,openai}.kdl`、`pi-ai stream.ts withSupportedSamplingParams`。

### 3.1 发前：`ParamCompat.resolve` → `supported(_:)`

- 输入：`providerType + baseURL + modelId + reasoningEffort`（`ParamCompat.swift:66-96`）。
- 输出字段：`sendsSampling` / `dropped: Set<组名>` / `singleSampler` / `maxTokensKey` / `anthropicAdaptive` / `source`（:26-37）。
- 组名：`sampling` `seed` `stream_options` `reasoning` `output_config` `single_sampler` `thinking_display`（:12-24）。
- 调用点：router 实发 `adaptedSampling`（`ChatService.swift:1947, 2371-2375`）、各 provider 内再 resolve 一次拿 compat 给 builder（:623-624, :1182-1183）、预览（:2389-2394, 2423）、设置页提示、测试连接的键名（`ProviderProbe.swift:110-112`）。
- 只管 `.openaiCompatible` / `.anthropic`；OAuth / 本机 / CC 原样（:2372）。

### 3.2 发后：报错分类 `ParamErrorClassifier`

- **只认 400 / 422**（`ParamErrorClassifier.swift:62`）；只认这次**真发了的顶层键**（`SentShape`，:36-55，provider 组好 body 时记，`ChatService.swift:646, 1197`）。
- 取证：递归解正文 JSON（字典 / 数组 / 字符串里嵌的 JSON，深度 ≤8，只读 `message/msg/detail/description/raw/error/error_message` 字段当文字）（:268-327）。
- 结构化优先：OpenAI `param + code`（`unsupported_parameter` / `unsupported_value`）、FastAPI `loc + extra_forbidden`（:81-99）；文字只补结构化没说到的字段（:101-117）。
- 文字规则：magpie 三条 + 「字段 40 字内跟拒收词」+ 「Unrecognized request argument」（:232-243）；值问题（range/must be/between…）（:246-250）；只收默认值（`only the default`）例外为可剥（:79）。
- 判决：`.fix([Fix])` / `.explain(人话)` / `.thinkingBlocksRejected` / `.unknown`（:26-33）。
  - Fix：`dropSampling`（点名任一采样字段 → 整组，Q1）、`drop(seed/stream_options/reasoning/output_config/thinking_display)`、`renameMaxTokens`、`lowerOutputCap`、`thinkingFormat(adaptive|budget)`、`singleSampler`（:6-24, 118-165）。
  - 思考格式只在点名 `thinking.type` 且明确拒 adaptive / 只列 enabled 时换 budget；正文说预填的不碰思考格式（:127-138, 184-191）。
  - explain：预填、推理档某档不收、采样值超范围（:167-179）。
- 脱敏：当前 key（原文 + 转义）换 `<API key>`，URL 去 query / userinfo；展示 / 日志 / 落盘都走它（:333-338）。

### 3.3 重试与记忆：`ProviderRouter.adaptiveFailed`

- 位置 `ChatService.swift:2117-2183`。流程：
  1. 分类 → 有学到的 → **立刻**写 `ParamAdaptStore`（Q3）+ 诊断日志「✂️ 参数自适配」带原文前 300 字（:2128-2133）。
  2. 降上限判断：`fixes` 含 `lowerOutputCap`，或没认成改名但正文提到上限；且状态码 400/422 且当前上限 > 8192（:2136-2139）。
  3. 思考块被拒支（Anthropic + toolTurns 有思考 + 400/422）：去块重发，不学（:2141-2158）。
  4. 一般支：`attempt == 0` + **没收到任何输出**（`streamingContent` 空且无 `[DONE]`）+ 有学到或要降上限 → 同参数重新走一遍 `sendStreaming(attempt: 1)`，自然过新的 compat（:2159-2178）。
  5. 否则 `failureMessage` 说人话；重试那次又学到新的 → 记下并在尾巴写「已记住：…下次自动照办」（:2179-2182, 2365）。
- 预算：被拒那次账本记 `.error`、`budgetWaived = true` 扣 0（:1795-1796, 1972, 2145, 2160）。
- 提示：`lastParamAdaptation` → VM 取一次即清，出聊天页小胶囊（:1822-1829；VM `showParamAdaptationNotice`）。
- 记忆表 `ParamAdaptStore`（`Services/ParamAdaptStore.swift`）：UserDefaults `paramAdaptByEndpoint.v1`，键 = `协议|规范化 baseURL（只小写 scheme/host，去尾 /）|模型 id 小写`（:32-45），值 = `Learned{groups, maxTokensKey, thinkingFormat}` + 时间 + 原文前 300 字；上限 200 条超了删最老；**不过期**；只增不减（Q4）。设置 → 全部模型行内「自动适配：…」+ ×，开发调试页整表。
- **同协议同地址不同 key 共享一条**（:32）。

### 3.4 自适配的已知边界【文档：review-param-autoadapt §1、§3 + 代码核对】

- 中文报错（国内中转自翻的「参数 temperature 不支持」）认不出——正则全是英文。
- 只比顶层键；嵌套字段（`tools[].cache_control`、`thinking.display` 以外的嵌套）报错只能按顶层对。
- `tools` 本身被拒、`tool_choice` 被拒都不在 `knownFields`（:60）→ `.unknown` 不重试。
- 流式中途出错、SSE 里的 `error` 事件（状态 200）不进自愈。
- 后台 `sendNonStreaming` 不过 ParamCompat、不自愈。
- 误学没有过期；只拒 top_p 也会整组去掉 temperature。
- 测试宿主目录为空，「目录」一层只在注入 catalog 的单测里测过。
- 报错样本多为按资料还原，真原文只有「does not support assistant message prefill」「Invalid `signature` in `thinking` block」「temperature and top_p cannot both be specified」三条【文档】。

---

## 4. 模型元数据

### 4.1 models.dev 目录 `ModelCatalog`（`Models/ModelCatalog.swift`）

- 源 `https://models.dev/api.json`，TTL 1 天，启动后台读盘 + 过期刷新，失败保旧缓存；测试宿主不联网（:22-36, 79-115）。
- **保留的字段只有**：`id / providerId / name / contextTokens(limit.context) / outputTokens(limit.output) / reasoning / reasoningEfforts(reasoning_options[type=effort].values) / pricing / temperature`（:4-17, 141-194）。
- **丢掉的**：`modalities`（vision / audio）、`tool_call`、`attachment`、`structured_output`、`knowledge`、`open_weights` 等 → 没有能力判断的数据源。
- 索引：同 id 多家时一方厂商优先（anthropic/openai/google/deepseek/xai/…），非一方按「有价 > 0 价 > 无价」；聚合商 `vendor/model` 的末段也建索引（:196-222）。
- 查找：完整 id → 去 vendor 前缀 → 去日期后缀 → 最长前缀（边界必须是 `-:@` 且余下不以数字开头，防拿旧版本冒充）；点号换连字符（:200-242）。
- 用途核对：
  - `outputTokens` → 输出上限（`OutputTokenCap.swift:16-19`）；
  - `temperature` → ParamCompat 目录层；
  - `reasoning / reasoningEfforts` → 档位列表；
  - `pricing`（含 `tiers` / `context_over_200k`、1h 写价、Anthropic 搜索 $0.01）→ 计费；
  - **`contextTokens` 只用于模型池一行的小字展示**（`ModelCatalog.swift:245-262`；全仓 grep 无其他读点）。

### 4.2 上下文窗口

- **没有按 token 的上下文管理**：历史按 `preset.sampling.contextDepth` 条数（默认 40）开窗（VM:2361-2363），`maxContextSize`（默认 100000）不参与发送（§2.2）。超长靠上下文总结（`SessionSummaryStore`）和撞 API 报错。
- 发送前 token 估算只给保险闸用：字符启发式（`TokenEstimator`），临界时官方端点调 `count_tokens` / `responses/input_tokens`（`Services/OfficialTokenCounter.swift:15-87`；`Services/BudgetPreflight.swift:116-131`）。

### 4.3 价格

- `PricingCatalog.price`：一方厂商的目录价 > 手写表 > 中转目录价；查不到 = nil（不知道），保险闸用 `budgetFallback` $3/$15（`Models/ModelPricing.swift:98-106, 201`）。
- 手写兜底表（2026-10）约 50 条：Claude 4.x/5.x、GPT-4o/4.1/5/5.x/6.x、o3/o4、DeepSeek V4 + 旧别名、Gemini 2.5、Grok 3、Llama；带缓存价与长上下文阶梯（:128-198）。匹配：精确 → 去 vendor → 前缀 → contains 最长键（:110-125）。
- 计费：缓存读默认 0.1×、写 1.25×、1h 写 2×，阶梯价按总 prompt 整次换价；缺维度标 partial（:43-77）。
- 账本存「当时算出的金额 + 来源 + 价格版本」，OR 用 `usage.cost` 实价【文档：review-api-真实计费】。

### 4.4 `/models` 拉取

- `ProviderProbe.fetchModels`（`Models/ProviderProbe.swift:26-60`）：OpenAI 兼容 / Anthropic 共用，`GET {base}/models`，**只读 `data[].id` 和 `display_name`**；名字缺了用目录名补；过滤 embed/tts/whisper/dall-e/moderation/davinci/babbage；按 id 排序。
  - 不读 OpenRouter 的 `context_length / pricing / supported_parameters / architecture.input_modalities`，不读 Anthropic 的 `max_input_tokens` 等。
- ChatGPT OAuth 走 codex `/models` 专属端点（`APIProvider.swift:1159-1215`）。
- 合并策略：刷新只加不删（`APIProvider.swift` 现有逻辑，【文档：manual facts】）。
- 测试连接：发 `{model, <键名>:1, messages:[hi]}`，只有 2xx 算成功；`describe` 分 401/403/404/429/5xx/400-model（`ProviderProbe.swift:64-158`）。

### 4.5 内置模型表 / 能力位

- **预设预填模型**（`APIProvider.swift:226-412`）只是 `ProviderModel(credentialId, modelId, name)`，无能力字段；部分已过时（OpenRouter `anthropic/claude-sonnet-4`、`google/gemini-2.5-pro-preview`；DeepSeek `deepseek-chat/reasoner` 在价格表注释里已标「退役别名」）。
- 17 家预设里只有 Anthropic / claude-p / kimi-p（Debug）是 anthropic 协议；SiliconFlow / DashScope / 智谱 / 豆包 / Gemini / Moonshot / Ollama 预填为空（:324-366）。
- `ProviderModel` 没有能力字段；卡级只有 `toolsSupported`（:94-97）。
- 「内置模型知识」实际散在三处：`ModelLineage` 血统规则（只认 anthropic / openai）、`ModelPricing` 手写价表、`ReasoningEffort.levels` 的路由兜底档位。

---

## 5. 错误分类与呈现

### 5.1 正文提取：`BaseChatProvider.errorMessage`（`ChatService.swift:335-360`）

依次认：`{error:{message,type}}`（+ OR `metadata.raw` 上游原文接在后面，递归一层）→ `{error:"…"}` → `{detail:"…"}` → `{detail:[{loc,msg}]}`（FastAPI）→ 顶层数组首元素（Gemini 兼容口）→ `{message}` → 「API 错误 (码)」。Anthropic `not_found_error` + `model: xxx` 说人话（:381-384）。

### 5.2 失败出口：`ProviderRouter.failureMessage`（`ChatService.swift:2343-2367`）

| 状态 | 处理 |
|---|---|
| 400 / 422 | 参数分类 → explain 前缀人话 / 思考块被拒说明；认不出照原文 |
| 401 / 403 | 前缀「key 不对或没有权限。原文：…」→ FixJump `.badKey` |
| 404 | 前缀「地址不对，检查 Base URL。原文：…」→ `.badURL` |
| 其他 > 0 | 原文 + 尾巴「（host · 模型 · HTTP n）」 |
| 0（网络错误） | `localizedDescription`，无尾巴（:444-449） |
| 撞上限关键词 | 追加「本次输出上限 N 可能超出…」（`OutputTokenCap.swift:67-70`） |

- 「去改」按钮靠中文常量反认（`Services/FixJump.swift:6-55`）：badKey / badURL / cardMissing / prefill / reasoning / samplingValue / learned / budget。
- 保险闸：发前超额 → 「保险闸：本次预计花费超过剩余额度」（`FixJump.swift:33`；`ChatService.swift:307-311`）。
- 呈现：VM onError 把「⚠️ 原文」写进节点 `content` / 段并 `save`（VM:4056-4079），已收的部分正文保留。

### 5.3 **没有识别 / 没有专门处理的**

| 类别 | 现状 | 证据 |
|---|---|---|
| 429 限流 vs 余额不足（`insufficient_quota` / `rate_limit_exceeded`） | 聊天路径不区分、不重试、不读 `Retry-After`；只拼尾巴。只有测试连接把 429 写成「被限流或余额不足」 | 全仓 grep 聊天路径无 429；`ProviderProbe.swift:142` |
| 529 / `overloaded_error` / 5xx | 同上，不重试、不退避 | — |
| 上下文超长（`context_length_exceeded` / `prompt is too long` / `model_context_window_exceeded`） | 不识别；不会自动裁历史或触发总结 | 全仓 grep 无 |
| 内容过滤（`finish_reason: content_filter`、OpenAI `refusal`、Azure content policy、Gemini SAFETY） | 不识别；`content_filter` 当正常结束 | §2.9 |
| Anthropic refusal 其他 category | 只给 `reasoning_extraction` 出尾注 | `ParamErrorClassifier.swift:213-216` |
| 流内 `error` 事件 | 原文 + 「HTTP 200」尾巴，不分类 | :1055-1063, :1752-1760 |
| `model_access_suspended`（403） | 归到 badKey（实际是模型被暂停）【文档：review-request-body §3 实撞过】 | — |
| 自动换模型 / 回退 key | 没有（magpie 2.4 的多 key 回退未做） | 【文档：research-magpie §2.4】 |

---

## 6. 跨模型续聊（同一对话中途换 provider / 模型）

### 6.1 存储层不知道「上一条是谁生成的」

- `MessageNode` 字段里没有 provider / model（`Models/Conversation.swift:134-230`）；对话级只有 `selectedModelId`（:64）。生成者只能经用量账本 `messageNodeId` 反查（`FixJump.swift:94-99` 就是这么找卡的）。
- 因此历史组装**必须 provider 无关**——现在的做法也确实是：

### 6.2 历史怎么重新渲染

| 内容 | 处理 | 证据 |
|---|---|---|
| assistant 正文 | `ContentCleaner.extractThinking` 去掉 `[thinking]…[/thinking]`（app 内部标签，来自本机模型 / CC）后发；人设要求的 `<thinking>` 正文**不剥**，交给正则脚本 | VM:2711-2722；`Utils/ContentCleaner.swift:117` |
| 原生思考段（含签名 / redacted） | `ToolReplay.rounds` 跳过 `.thinking` 段 → **历史永不回传思考**（Q1），所以换厂商不会因为签名 / 思考块格式出错 | `ToolReplay.swift:50-78` |
| 历史工具回合 | 按「当前」provider 现渲染：Anthropic / OpenAI 兼容发真块，id 统一清洗成 Anthropic 合法形状（OpenAI 也收）；OAuth / 本机 / 本轮没给工具 / 调过本轮没有的工具 → 纯文字 +〔系统记录〕 | `ToolReplay.swift:84-92, 136-212`；VM:2573-2582 |
| 工具结果 | 历史一律截 2KB | `ToolReplay.swift:95-111` |
| Anthropic server web search | 结果存 `webSourcesData`，不进段 → 历史不回放 server_tool_use / web_search_tool_result | VM:4007-4008 |
| 图片 | 每次按当前 provider 重新渲染成 image_url / image 块；OAuth 丢 | §2.10 |
| system 位置 | 按当前 provider 的 interleave 能力重新降级 | §2.3 |
| 推理档 | 每「卡/模型」各记一档，换模型取最近档 | `ReasoningEffort.swift:76-109`；VM:2561 |
| 学到的参数 | 按「协议 + 地址 + 模型」各自生效 | `ParamAdaptStore.swift:32-36` |

### 6.3 一个回合内

- 工具循环里模型固定（`continueToolLoop` 用发起时的 model，VM:3869-3940），`ToolTurn.assistantContent` 只在 Anthropic builder 里使用，OpenAI builder 忽略（`ChatService.swift:809-820`）。所以回合内不存在「换厂商」。
- 换模型 = 缓存前缀必然整段失效（system / 工具定义 / 参数都可能变），没有额外处理。

### 6.4 跨模型的缺口

- OpenAI 兼容路的推理模型如果要求工具续轮回传 `reasoning_content` / `reasoning_details`（DeepSeek 思考模式工具调用、Kimi K2 thinking、OR 上的 Claude / Gemini 思考签名），现在**一律不回传**——因为根本没解析。当轮续轮可能被拒或丢思考【推断；具体哪家当前强制要求未查证】。OR Claude 一项是已登记的 Q7 债。
- 节点不记生成模型 → 以后若要「同厂商才回传历史思考」之类策略，需要先补字段。

---

## 7. 已知坑 / TODO（与兼容相关）

代码里 `TODO/FIXME/XXX` 在 provider 相关文件中**一个都没有**；坑都记在 docs 复盘和代码注释的「待实测 / 待核」里。下面汇总（来源标注）。

### 7.1 文档已登记的债

| # | 内容 | 来源 |
|---|---|---|
| 1 | OR 上的 Claude 5 默认在想，工具续轮没带 `reasoning_details`（Q7） | review-thinking §3 |
| 2 | 「关」档在默认会想的模型上仍在想（要发 `thinking:{type:disabled}`，Opus 5.5 收不收未查证） | review-thinking §1 |
| 3 | 真请求只验过 Haiku 5.5；display 是否让首回合缓存重写、count_tokens 收不收带思考块的 body、中转认不认 `display` 都未查证 | review-thinking §3；thinking-验收 |
| 4 | VM 工具轮预检 `preCheckToolRequestBudget` 不算回传思考 token | review-thinking §3 |
| 5 | 后台 `sendNonStreaming` 不过 ParamCompat / 不自愈 | review-param-autoadapt §3 |
| 6 | 自适配报错样本多为推断措辞；中文报错认不出；只认顶层键；`tool_choice` / `tools` 不在分类范围；记忆表不过期 | review-param-autoadapt §1–3 |
| 7 | 设置页「不支持采样」提示不管推理档那条 | review-param-autoadapt §3 |
| 8 | 预算收尾请求 `tools: nil` 却带当轮 toolTurns（已去思考块，但 tool_use 仍在） | review-request-body §3（thinking 单只补了去思考块） |
| 9 | OpenAI 兼容历史 tool_calls 的 content 发 `""`，个别端点可能要 null | review-request-body §3 |
| 10 | 两轮工具中间模型没说话 → 回放时被当成同一轮并列调用 | review-request-body §1 |
| 11 | ChatGPT 登录 / 本机模型只走纯文字退路，没做 Responses API 结构化回放 | review-request-body §3 |
| 12 | 「tools 为空但带工具块」「历史里有未定义工具名」API 认不认没实测（代码已退纯文字回避） | review-request-body §3 |
| 13 | 带 query 的 Base URL（Azure `?api-version=`）拼不对 | review-api-wave1 §1 |
| 14 | 测试连接固定 `max_tokens: 1`，推理模型可能因太小 / 键名 400 | review-api-wave1 §1 |
| 15 | Gemini OAI 兼容口 `completion_tokens` 是否含 thoughts 待实测；DeepSeek 命中字段与 `cached_tokens` 是否一致待实测 | `APIUsageParser.swift:25, 33`；review-api-真实计费 §1 |
| 16 | `supportsInterleavedSystem` 对 OR `openai/*` 没实打验证 | `ChatService.swift:693` |
| 17 | OR 补查队列不持久化；价格缓存只存 4 个字段，新维度靠每次启动刷新 | review-api-真实计费 §3 |
| 18 | Anthropic cache_control 被拒只拉黑、这一次不重试 | plan-param-autoadapt R9 |

### 7.2 本次读代码新发现（均【推断】，没跑过）

| # | 内容 | 证据 | 可能后果 |
|---|---|---|---|
| A | SSE 行切分用 `firstIndex(of: "\n")`，CRLF 切不开 | `ChatService.swift:989, 1594` | 回 `\r\n` 的中转 / 网关整段流解析为 0 行 →「未收到回复」 |
| B | 每个网络分片独立 UTF-8 解码，失败整片丢 | `:980, 1585`；OAuth:117 | 中文多字节被切在分片边界时丢 token，甚至丢掉含 `[DONE]` / usage 的整行 |
| C | 只认 `data: ` / `event: `（带空格） | `:993, 1598, 1600` | 不带空格的合法 SSE 被忽略 |
| D | OpenAI 工具轮不看 `finish_reason`，`index` 缺省 0 | `:1077, 999` | 不带 index 的并行调用会被拼成一个（Gemini 兼容口是否带 index 未查证） |
| E | Anthropic server web search 按卡类型下发，不看 host | VM:3393-3397 | Anthropic 协议中转 / 代理不认 `web_search_20250305` 时 400，分类器不处理 `tools` |
| F | OR + Claude + cacheFriendly 时，最后一条 assistant 若是当轮 tool_calls 消息（content `""`），会被包成空 text + cache_control 块 | `:862-865` 与 `:811` | 上游 Anthropic 可能拒空 text 块 |
| G | ChatGPT OAuth 丢图片、不发输出上限、不解析 reasoning summary、不认 `response.incomplete` | OAuth:30-43, 133-191, 265-345 | 订阅通道下图片静默丢失 |
| H | OpenAI 兼容路不解析任何 reasoning 字段 | `:1067` | DeepSeek R1 / Qwen / GLM / Kimi / OR 的思考全丢，也无法回传 |
| I | `contextTokens` / `maxContextSize` 不参与发送；无上下文超长识别 | §4.2、§5.3 | 长对话撞窗口只能看原文报错 |
| J | 没有 vision 能力位，不支持图的模型照发图 | §2.10 | 400 原文直出，不会降级为转述 |
| K | 429 / 529 / 5xx 不重试、不读 Retry-After | §5.3 | 瞬时错误直接落一条「⚠️」进历史 |
| L | 预设预填模型里有过时 id（OR `claude-sonnet-4`、`gemini-2.5-*-preview`，DeepSeek 旧别名） | `APIProvider.swift:271-283, 292-293`；`ModelPricing.swift:176-178` | 新用户选到就 404 / 400 |

---

## 8. 给对照 magpie / oh-my-pi 的提示（只列落点，不给方案）

| 想学的能力 | MP 现在的落点 | 现状 |
|---|---|---|
| 统一请求 IR | `PromptMessage` / `PromptWire` | 已有，较接近 |
| 统一响应 IR（内容块：text / thinking / tool_call / citation） | 无；各家 parser 直接回调，Anthropic 有 `ReplyBlock` | 缺 |
| 模型能力表（vision / tools / reasoning / 上下文 / 采样） | `ModelCatalog`（丢了 modalities / tool_call）+ `ModelLineage`（只 anthropic / openai）+ 价表 | 部分 |
| 按端点的 compat 层（键名、developer role、interleaved system、stream_options、reasoning 字段名） | `ParamCompat` + 散落的 host 判断（`isOfficialOpenAI` / `supportsInterleavedSystem` / `wantsORCacheControl` / `ReasoningEffort.route`） | 部分，host 规则未集中 |
| reasoning 字段解析与回传（reasoning_content / reasoning_details / signature） | Anthropic 全；OpenAI 兼容无 | 缺一半 |
| 拒参自愈 | `ParamErrorClassifier` + `ParamAdaptStore` + `adaptiveFailed` | 已有（只重试一次、整组剥） |
| 错误分类（限流 / 额度 / 过载 / 超长 / 过滤）+ 重试退避 | 只有 400/401/403/404 | 缺 |
| `/models` 元数据吸收 | 只取 id / display_name | 缺 |
