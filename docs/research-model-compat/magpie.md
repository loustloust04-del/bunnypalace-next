# magpie 模型兼容层调研报告

> 对象：`/Users/susu/Desktop/susu-project/magpie`（Go，本地 LLM 网关，127.0.0.1:3425）
> 范围：只读。证据格式 `文件:行号`，路径相对仓库根；`gw/` = `internal/gateway/`，`prov/` = `internal/provider/`，`cat/` = `internal/catalog/`。
> 调研日期 2026-10-15，仓库 HEAD 时间线到 2026-10-06（共 2039 个 commit）。

---

## 0. 一句话结论

magpie 的兼容做法分**三层**：

1. **一个很薄的统一中间表示（IR）+ 统一流事件**：4 种协议各写一对 `parse/build`（请求）和 `decoder/encoder`（流），全部经过 `gw/ir.go` 里的 `Request/Message/Part` 和 `Event` 中转，N×N 翻译降成 2N。
2. **能透传就透传，透传时只做"外科手术式"字节级修补**：协议对得上就不进 IR，按 host / preset / 模型名正则对 body 做最小改动（gjson 定位、原地拼接，不重排 key，保 prompt cache 前缀）。
3. **"被拒→读错误→剥参重试→记住"的自适配循环**：一个进程内 `unfit map[string]bool`，按 `provider × 模型/字段 × 协议` 记住"这家不吃这个"，下次请求直接不带。

怪癖建模**不是**配置表驱动：几乎全是代码里的 `if host == … / strings.Contains(model, …) / regexp` 分支，每个分支注释里写着 issue 号和原始报错原文。唯一数据驱动的是**模型能力**（温度是否允许、推理档位、上下文、价格、走哪个端点），来自 models.dev 远程目录 + 厂商 `/models` 实时列表 + 用户覆盖。

---

## 1. 协议翻译架构

### 1.1 IR（统一中间表示）—— 有，而且很小

`gw/ir.go` 文件头直接写明：「The APIs are close cousins; everything below is the shape they have in common. A request is parsed into it, and a reply is produced from it.」（`gw/ir.go:14-15`）

| 类型 | 位置 | 要点 |
|---|---|---|
| `Kind` | `gw/ir.go:18-28` | `text / image / file / tool_call / tool_result / thinking / web_search` 七种 part |
| `Part` | `gw/ir.go:31-56` | 一个扁平 struct 装所有种类：图片(MediaType/Data/URL)、调用(ID/Name/Args)、结果(CallID/IsError/Images)、**思考(Text + Signature)**、搜索(Hits) |
| `Message` | `gw/ir.go:76-79` | **只有 user / assistant 两种 role**；system 被提升到 `Request.System` 单字段；tool 结果是 user 消息里的 `ToolResult` part（Anthropic 风格） |
| `Request` | `gw/ir.go:90-148` | `ToolChoice` 归一成字符串 `"" | auto | none | required | name:<tool>`（`:95`）；`Effort` 归一成 `low|medium|high|xhigh|max`（`:101`）；`Thinking`（要看见思考）/`ThinkOff`（明确关思考）两个布尔分开（`:102-106`）；另带一堆"原样转回同协议上游才有用"的透传字段：`CacheKey`(prompt_cache_key)、`Include`、`ClientMetadata`、`Text`、`Metadata`、`Schema`(output_config.format) |
| `EventKind` / `Event` | `gw/ir.go:162-196` | 流事件 11 种：`KStart KText KThink KSig KToolStart KToolArgs KStop KUsage KError KSearch KImage`；`Stop` 归一成 `stop | length | tool | filter`（`:187`） |
| `Usage` | `gw/ir.go:199-227` | `Input` 定义为**未命中缓存的输入**（Anthropic 口径），`CacheRead/CacheWrite/CacheWrite1h/Reasoning` 分开；`prompt()` = Input+CacheRead+CacheWrite 还原 OpenAI/Gemini 口径（`:232-234`） |
| `collector` | `gw/ir.go:287-376` | 把事件流组装成非流式 `Result`；`finish()` 里：stop 为空或 `stop` 但含工具调用 → 改判 `tool`（`:362-376`，注释：中转站给 tool_use 配 end_turn 的情况） |

效率/档位换算也放在 IR：
- `effortOf`：`minimal/none → low`，`ultra → max`（`gw/ir.go:508-518`）
- `fitEffort`：请求档位贴到模型自己档位表里最近的一档，平局取高（`gw/ir.go:546-573`）
- `budgetOf`：effort → Anthropic thinking budget：low 4096 / medium 10000 / high 24000 / xhigh,max 32000（`gw/ir.go:576-588`）
- `effortOfBudget`：反向（`gw/ir.go:591-603`）

### 1.2 各方向翻译所在文件

| 协议 | 解析客户端请求 → IR | IR → 上游请求 | 上游流 → Event | Event → 客户端流 | 非流式渲染 |
|---|---|---|---|---|---|
| OpenAI Chat | `parseChat` `gw/chat.go:65` | `buildChat` `gw/chat.go:216` | `chatDecoder.decode` `gw/chat.go:803` | `chatEncoder` `gw/chat.go:956-1046` | `renderChat` `gw/chat.go:1049` |
| OpenAI Responses | `parseResponses` `gw/responses.go:230` | `buildResponses` `gw/responses.go:578` | `responsesDecoder.decode` `gw/responses.go:811` | `responsesEncoder` `gw/responses.go:920-1150` | `renderResponses` `gw/responses.go:1153` |
| Anthropic Messages | `parseAnthropic` `gw/anthropic.go:87` | `buildAnthropic` `gw/anthropic.go:343` | `anthropicDecoder` + `decodeAnthropic` `gw/anthropic.go:520,565` | `anthropicEncoder` `gw/anthropic.go:698-846` | `renderAnthropic` `gw/anthropic.go:849` |
| Gemini（客户端侧） | `parseGemini` `gw/gemini.go:182` | `buildGemini`（仅 Factory）`gw/gemini.go:91` / `buildCodeAssistSent` `gw/codeassist.go:114` | `codeAssistDecoder.decode` `gw/codeassist.go:525` | `geminiEncoder` `gw/gemini.go:514-609` | `renderGemini` `gw/gemini.go:612` |

调度表：`parse` / `build` / `decoder` / `makeEncoder` / `render` 五个 switch 在 `gw/gateway.go:3838-3996`。`parse` 之后统一跑一次 `unsignCalls`（把藏在 tool call id 里的 Gemini 签名拆出来，见 1.6）`gw/gateway.go:3855`。

**透传 vs 翻译的决策**（`attempt`，`gw/gateway.go:2367-2485`）：
- 上游在客户端那个协议上服务该模型 → `passthrough`（`:2437`）；
- 例外 1：Claude 模型且 provider 有 Anthropic 端点 → 强制翻译到 Messages，因为中转站的 Chat 端点会丢 `cache_control`、丢 thinking（`:2438-2444`，`prov/provider.go:1036-1056`，#997：「0% cache hits until the relay's OpenAI URL was left empty」）；
- 例外 2：请求带 web search 但上游不自带搜索 → 翻译（由网关代搜）（`:2445-2453`）；
- 否则走 `translate`（`gw/gateway.go:3665`），上游**永远以流式**请求（`:3706` `request.Stream = true`），非流式客户端由 collector 组装。

**端点优先级**（`usable`，`gw/gateway.go:3199-3214`）：默认 Chat > Responses > Anthropic（`prov/provider.go:41`）；OpenAI 自家模型在 OpenAI/Copilot/Azure/Bedrock 上 Responses 优先（`prov/provider.go:1019-1030`）；Claude 模型 Messages 优先（`:1036-1038`）。被厂商回"这个模型不在这个端点"→ `markUnfit(provider, model, proto)` 后换下一个端点重建请求（`gw/gateway.go:3377-3385`；识别短语表 `wrongEndpoint` `gw/gateway.go:3627-3660`，如 "not a chat model"、"only supported in v1/responses"、Copilot 的 "not accessible via the"、"unsupported_api_for_model"）。

### 1.3 流式 SSE 逐事件翻译的骨架

- SSE 解析：`readSSEAlive` `gw/sse.go:22-60`。空行 flush 一个事件、`:` 开头是注释（算存活信号）、多行 `data:` 用 `\n` 拼接、`bufio.Scanner` 缓冲上限 32 MB（`:24`）。
- 每个 decoder 是**有状态的小状态机**，输出 `Event`；encoder 也是有状态的，维护"当前打开的 block/item"，在 kind 切换时自动关闭上一个。
- 心跳：每个 encoder 实现 `keepalive()`，客户端静默超过阈值就按**客户端协议自己的方式**发心跳（`gw/gateway.go:3919-3960`）：
  - Chat：SSE 注释 `: keepalive`（`gw/chat.go:1036`）
  - Anthropic：`event: ping`（`gw/anthropic.go:828-830`，「Claude Code's stream watchdog counts」）
  - Responses：重发 `response.in_progress`（`gw/responses.go:1125-1131`，「Codex's idle timeout counts events only, an SSE comment never reaching it」，#436）
  - Gemini：**什么都不发**（`gw/gemini.go:542-545`，「Google's SDK … gets stuck on anything else, a comment too」）
- 流中断补救：翻译路径上游中途断流，若上游支持"prefill 续写"（Anthropic 原生；Chat 仅 DeepSeek `prefix` / Kimi `partial`），把已发给客户端的半截回复作为最后一条 assistant 消息再请求一次（`gw/continuation.go:1-16, 89-130`；`buildChat` 里写 `prefix:true`/`partial:true` 并带回 `reasoning_content` `gw/chat.go:304-314`；DeepSeek prefix 走 `/beta` 路径 `gw/gateway.go:3297-3303`）。其他 Chat 上游不续写（"会拼接一个重新措辞的答案"）。
- 透传流结尾校验：Anthropic/Responses 流没收到终止事件就补一个协议原生错误事件（`gw/gateway.go:3093-3118`，`streamFailure` `:3132`），#370/#470。

### 1.4 Anthropic：content_block / thinking / signature

**解码（上游 Anthropic → Event）** `gw/anthropic.go:520-629`
- `message_start` → `KStart`（带输入侧 usage）（`:598-599`）
- `content_block_start`：`tool_use` → `KToolStart`；`text` 块若 start 里就带文本也发出（`:600-608`）
- `content_block_delta`：`text_delta→KText`、`input_json_delta→KToolArgs`、`thinking_delta→KThink`、**`signature_delta→KSig`**（`:609-619`）
- `message_delta` → `KStop` + `KUsage`（`:620-624`）
- 包装层 `anthropicDecoder` 处理两个怪癖（`:509-562`）：
  - `server_tool_use`（Anthropic 自己跑的 web search）的后续 delta 全部吞掉，不当客户端工具调用；
  - 中转站在 `content_block_start` 里就塞满 `input` 且之后不发 `input_json_delta` → 直接把 start 的 input 当参数，并忽略之后的 delta（蓝猫，commit c5b57b9）。
- `redacted_thinking` 块：解码器**不处理**（只在 fallback 的"是否已说话"判断里认识它，`gw/fallback.go:1603,1617`）。

**编码（Event → Anthropic 客户端流）** `gw/anthropic.go:698-846`
- 单一"当前打开 block"状态 `open Kind`；切 kind 自动 `content_block_stop` 并 `index++`（`:738-760`）。
- 工具块关闭时若一个参数都没收到，补一个 `input_json_delta "{}"`（`:742-745`）——客户端 SDK 不允许空 input。
- `KSig` 只在当前开着 thinking 块时发 `signature_delta`（`:785-788`）。
- 消息 id：非 `msg_` 开头的上游 id 改写成 `msg_…`，`chatcmpl-` 前缀剥掉（`anthropicID` `:712-720`）。

**构建上游 Anthropic 请求时的 thinking 规则** `buildAnthropic` `gw/anthropic.go:343-507`
- 连续同 role 消息合并（`push` `:349-358`）；tool_result 块排在同条 user 消息最前（`:397`）。
- 空白文本块丢弃（`:364-366`，Anthropic 拒收空 text）。
- **只回放带 signature 的 thinking 块**；无签名（来自别家模型）的 thinking 直接丢（`:387-391`）。
- 思考开关：Claude ≥4.6（`adaptiveOnly`，正则识别各种中转站拼法 `claudeVersion` `:243-260`）→ `thinking:{type:"adaptive"}` + `output_config.effort`，xhigh 映射到 max（`:425-432`）；旧模型 → `enabled + budget_tokens`，budget 必须 < max_tokens，客户端给了 max_tokens 就 `budget=min(budget, max_tokens-1024)`，没给就把 max_tokens 抬到 budget+4096（`:433-443`）；max_tokens ≤2048 时不开思考。
- 开思考时**不发 temperature/top_p**，且 temperature 与 top_p 二选一（`:447-451`）。
- 默认 max_tokens = 16384（`:421-424`）。

### 1.5 OpenAI Chat：reasoning_content / reasoning

**解码** `gw/chat.go:803-900`
- `delta.reasoning_content` 优先，空则用 `delta.reasoning`（OpenRouter）；「Some relays send the same thought under both names; one is enough」（`:848-852`）。
- Mistral 的 `content` 可能是 typed parts 数组，含 `{"type":"thinking","thinking":[{type:text,…}]}` → `partsText` 拆出思考和正文（`:853-861`，`gw/chattidy.go:199-234`，#483）。
- Gemini OpenAI 兼容端点会把思考写成正文开头的 `<thought>…</thought>`：`chatDecoder.text` 跨 chunk 缓冲识别这对标签，标签内发 `KThink`（`gw/chat.go:733-801`），包括"结束标签被切在两个 chunk 之间"的情况（`:770-781`）。
- 工具调用分片：按 `index` 追踪；**一些中转站每个分片都重复 id**，规范只在第一片给——「only a new id or a new index starts the next one」（`:876-886`，commit 3c67b5c）。
- 多 choice：锁定第一个可读 index，其余丢；index 可能是数字、数字字符串、`1.0`、null（`chatChoiceIndex` `:905-929`，#168）。
- 流里的 `{"error":…}` → `KError` 且保留安全过滤 code（`:828-831`）。
- usage 只在 prompt/completion 非零时发（`:896-898`）。

**编码到 Chat 客户端**：思考用 `reasoning_content` 字段输出（`gw/chat.go:1007-1010`，非流式 `:1075-1077`）；结尾先发 finish chunk 再单独发一个只含 usage 的 chunk，最后 `[DONE]`（`:1038-1046`）。

**构建上游 Chat 请求** `buildChat` `gw/chat.go:216-448`
- system 永远是第一条 `role:"system"`（`:218-220`）；客户端的 `developer` 在解析时就并入 system（`gw/chat.go:89-90`）。
- 历史 assistant 的思考**只对 DeepSeek（host 或模型名含 deepseek）回放为 `reasoning_content`**（`replay` `:221-224, 315-317`），#388 DeepSeek 报「The reasoning_text in the thinking mode must be passed back」。
- 工具结果里的图片：tool 消息只能放文本，图片挪到 tool 消息之后的一条 user 消息里，并在 tool 文本里写占位说明（`:228-254, 356-370`，#167）；且与紧接着的用户消息合并，避免"两条 user 连发被某些 chat template 拒"。
- `pairToolMessages`（`:450-561`）对**所有** Chat 上游修补工具往返（Kimi 严格校验，400 "tool_call_id is not found"，#554）：按调用顺序重排 tool 消息；重复回答丢弃；孤儿 tool 消息改成 user 消息；没回答的调用补一条合成错误结果 `[The result of this tool call is unavailable: the turn was interrupted.]`；挤在调用和结果之间的空 assistant 消息删掉。
- 流式时自动加 `stream_options:{include_usage:true}`（`:381-383`）。
- `max_completion_tokens` 只对 `*.openai.com`，其余一律 `max_tokens`（`:389-395`）；Bedrock/Azure 另行改写（见 2.1）。
- `rejectTemp`（来自模型能力表）为真则不发 temperature/top_p（`:396-403`）。
- `reasoning_effort` 直发；Gemini 兼容端点改用 `extra_body.google.thinking_config`（见 1.6）。
- `tool_choice` 字符串/对象两种形态都处理；`parallel_tool_calls` 只在有 tools 时发（`:422-441`）。
- OpenRouter + 请求要搜索 → `plugins:[{id:"web"}]`（`:442-445`）。

### 1.6 Gemini：parts / thought / thoughtSignature

**客户端侧 Gemini（Gemini CLI 等）解析** `parseGemini` `gw/gemini.go:182-328`
- 先 `geminiCamel` 把 snake_case 键统一成 camelCase（proto JSON 两种都收），但**不动**用户自己的值（args/response/parameters/schema）（`:109-180`，#934：`inline_data` 没被识别导致图片丢失，模型瞎编）。
- `thinkingConfig.thinkingLevel` → effort；`thinkingBudget:-1` → medium；其他按 budget 换算（`:192-201`）。
- `responseMimeType: application/json` + schema → 没有对等字段，就**写进 system 提示**要求输出 JSON（`:203-213`）。
- `functionResponse` 不管放在哪个 role 下都当 user 侧（Antigravity CLI 把结果放在 model role 下，#650）（`:224-241`）；只有 name 没 id 的旧客户端，按"同名最后一次调用"配对（`:215-217, 252-256`）。
- Gemini OpenAPI 风格 schema → JSON Schema：类型名小写化、`nullable → x-nullable`、丢 `propertyOrdering/example`（`jsonSchema` `:400-458`）。

**上游 Gemini（Code Assist / Antigravity / Factory）解码** `gw/codeassist.go:525-630`
- `part.thought == true` → `KThink`；同 part 的 `thoughtSignature` → `KSig`（`:578-585`）。
- `functionCall` 一次性给全参数 → `KToolStart` + 一个 `KToolArgs`；空 args 补 `{}`（`:568-577`）。
- 函数名带 Gemini 命名空间 `default_api:bash` / `default_api.bash` → 剥掉（`toolOfCall` `:632-645`）；Antigravity 甚至把整个调用写进正文 `call:default_api:bash{command:ls}` → 解析为真调用（`:617-631, 700+`，#636）。
- `finishReason` 映射：`MAX_TOKENS→length`；`STOP/OTHER/FINISH_REASON_UNSPECIFIED/MALFORMED_FUNCTION_CALL/UNEXPECTED_TOOL_CALL → stop`；其余（SAFETY/RECITATION/BLOCKLIST/PROHIBITED_CONTENT/SPII…）→ `filter`；有工具调用且 stop → tool（`:871-882, 610-618`）。
- usage：`Input = promptTokenCount − cachedContentTokenCount`，`Output = candidates + thoughts`，`Reasoning = thoughts`（`:555-559`）。
- 空回复（只有思考或什么都没有、仍 STOP）视为失败重试（`emptyFails` `gw/gateway.go:3795-3797`，#667）。

**上游构建（Code Assist 信封）** `buildCodeAssistSent` `gw/codeassist.go:114-270`
- 每个 `functionCall` part 一律附 `thoughtSignature: "skip_thought_signature_validator"`（Google 文档里给"非本模型签名历史"用的值）（`:150-151`，常量 `:24`）。
- 历史 thinking **不回传**：「its signatures belong to whoever made them, and Google turns away ones it didn't」（`:185-186`）。
- Antigravity 的 tool id 只允许 `[a-zA-Z0-9_-]`，其他字符替换成 `_`（`unsafeToolID` `:26`, `:122-128`）。
- Antigravity 函数声明只吃 OpenAPI 子集 → `plainSchema`：展开 `$ref`、合并 `allOf`、`anyOf/oneOf` 取第一个非 null 分支并转 `nullable`、`type:[x,"null"]` → nullable、只留白名单关键字、enum 只留字符串、`const → enum`、`exclusiveMinimum` 数值形态转 `minimum`、`required` 只保留存在的属性（`:325-520`，#187）。
- thinkingConfig：Gemini 3 用 `thinkingLevel`（Flash 支持 minimal/low/medium/high，Pro 只有 low/high，medium 上调到 high）；其他用 `thinkingBudget`；gpt-oss / 非 thinking 版 Claude 不发（`thinkingConfig` `:271-320`）。

**Gemini 的 OpenAI 兼容端点（AI Studio）上的签名：id 夹带** `gw/gemini_signature.go`
- 问题：Gemini 3 对每一步思考的**第一个** function call 签名，下一轮不带回就 400 "Function call is missing a thought_signature"；签名在 `tool_calls[].extra_content.google.thought_signature`，而 Chat 客户端（Pi、AI SDK）会丢掉这个非标字段（`:11-27`，#687）。
- 解法：**把签名塞进 tool call id**：`<id>__ts__<base64url(签名字节)>`，非规范 base64 用 `__tsr__`（`:29-46`）；客户端原样回传 id，网关在 `parse` 后 `unsignCalls` 拆回来（`:48-99`）；发 Gemini 时放回 `extra_content`，同一步后续调用不带，未签名步用 `skip_thought_signature_validator`（`chatCallSignatures` `:124-181`，`buildChat` `gw/chat.go:277-285`）；发给非 Gemini 上游时 id 还原成原始值。透传方向由 `sigTidy` 逐行改写 SSE（`:183-302`）。
- 识别"是不是 Gemini 兼容端点"：host 为 `generativelanguage.googleapis.com`，或模型名含 gemini 且 host 是 localhost / `.local` / 私网 IP（本地反代）（`geminiCompat` `gw/chat.go:591-607`）。
- AI Studio 不给思考除非请求 `extra_body.google.thinking_config.include_thoughts`，且此时不能再发 `reasoning_effort`；Gemini 3 发 `thinking_level`，2.x 发 `thinking_budget`（1024/1024/8192/24576），关思考时 Gemini 3 关不掉→发 `reasoning_effort:"minimal"`（`gw/chat.go:407-421, 647-670`）。上游拒收这些字段→记 unfit 后改回 `reasoning_effort`（`gw/gateway.go:3319-3325`, `refusesThinkingConfig` `gw/chat.go:639-645`）。

### 1.7 Responses API：item 事件

**解码** `responsesDecoder` `gw/responses.go:767-893`
- `response.created → KStart`；`output_item.added(function_call) → KToolStart`；`output_text.delta → KText`；`reasoning_summary_text.delta` 和 `reasoning_text.delta` 都 → `KThink`。
- **工具参数不按 delta 流出，而是等 `function_call_arguments.done` / `output_item.done` 后取"更完整的那份"**（`pickArgs` 优先合法 JSON、更长者）（`:765-809, 851-863`，#613：delta 拼出来是 `{}`，done 里才有完整参数）。
- `web_search_call` 的 `action.sources` → `KSearch`（`:864-873`）。
- 终止：`completed/incomplete/failed`；incomplete 默认 `length`，`incomplete_details.reason == content_filter` → `filter`；ChatGPT 后端的 completed 里 output 是空的，所以用"流里出现过 function_call"判 tool（`:875-897`）。
- usage：`input_tokens` 是全量，`Input = input − cached − cache_write`（`gw/responses.go:752-758`）。

**编码到 Responses 客户端（Codex）** `gw/responses.go:920-1150`
- 每个事件带递增 `sequence_number`（`send` `:980-985`）。
- item id 前缀：消息 `msg_`、推理 `rs_`、函数调用 `fc_`、tool_search_call `tsc_`、custom_tool_call `ctc_`（`itemPrefix` `:973-978`，`openaiItemPrefix` `gw/codex_backend.go:1019-1022`）——OpenAI 会拒绝前缀不对的 id（"Expected an ID that begins with 'tsc'"）。
- `response.created` 的 `output` 必须是 `[]` 不能是 null（Muse Code 拒收）（`:987-993`）。
- 思考以 `reasoning` item + `summary_text` 输出（magpie 不产生 encrypted_content）。
- 命名空间工具：解析时把 `namespace` 里的函数拍平成 `namespace__name` 提供给模型，回包时还原 `name+namespace`，并加 `encrypted_function_args: []`（否则 Codex 当作加密参数）（`gw/responses.go:149-162, 939-970`）。
- custom（自由文本）工具：以 `{input: string}` 函数形式提供给模型，回包转回 `custom_tool_call.input`（`:80-128`）。

**解析 Responses 客户端请求的细节** `parseResponses` `gw/responses.go:230-449`
- 对话已开始后出现的 `developer/system` 消息**原地保留**为 `<system-reminder>` 包裹的 user 消息，而不是并入 system——否则改变 prompt 开头，整段缓存失效（`:250-276`，#502）。
- 同 role 连续 item 合并（Responses 把一个 assistant 回合拆成多个 item）（`mergeTurns` `:537-547`）。
- `reasoning` item：有 `reasoning_text` 用全文，否则用 summary（`:316-336`）。
- 无 call_id 的 `function_call_output`（Codex 跨线程通知）→ 转成 user 消息，且若夹在调用和结果之间就延后（`orphanedToolOutputs` `:455-533`）。

**构建上游 Responses 请求** `buildResponses` `gw/responses.go:578-736`
- `store:false` 固定（`:654`）。
- 思考只对 DeepSeek 模型回放为 `reasoning` item（非 OpenAI/xAI/Copilot/Azure host）（`:579-586`）。
- tools 的 `strict` **必须显式写出**，省略时 ChatGPT 后端按 strict 规则校验 schema，含 lookaround 的 pattern 被拒（`:703-706`，#383）。
- `include` 原样转发，但 `reasoning.encrypted_content` 只在请求了 reasoning 时才发（不推理的模型会拒）（`:687-698`）。
- 透传到 OpenAI/Azure 时删掉"magpie 自己造的、无 encrypted_content 的 reasoning item"——`store:false` 时 OpenAI 会去查这个 id，查不到 400（`withoutBareReasoning` `gw/codex_backend.go:966-1009`，#1008）。
- call_id 超过 64 字符 → sha256 hex（同一 id 稳定映射，调用与输出仍配对）（`prov/codex_request.go:349-361`，`boundCallIDs` `gw/codex_backend.go:1073-1120`，#732）。

---

## 2. 厂商/模型怪癖怎么建模

### 2.1 建模方式

**结论：没有 per-provider 配置表来描述协议怪癖；怪癖是散落在代码里的条件分支 + 正则，按以下几种"判定键"触发：**

1. **host 判定**：`p.Host()` 字符串比较或后缀（`*.openai.com`、`api.deepseek.com`、`api.x.ai`、`api.mistral.ai`、`openrouter.ai`、`generativelanguage.googleapis.com`、Kimi 的四个域名 `gw/kimi_schema.go:52-58`）。
2. **preset id 判定**：`p.Preset == "mistral" / "deepseek" / "openrouter" / "bedrock"`，以及 `IsBedrock()/IsAzure()/IsCline()/IsKilo()/IsOpenCode()` 谓词（`prov/provider.go:1137-1170`）。
3. **模型名正则**：`anthropicModel`、`claudeVersion`（Claude ≥4.6 adaptive）、`effortInOutputConfig`（`glm-5.[23]`）、`strings.Contains(model,"deepseek"/"gemini"/"kimi")`、`openAIModel`（`gpt-`/`codex`/`o\d`）`prov/provider.go:1058-1076`。
4. **数据驱动的能力表**（唯一的"表"）：`catalog.Model{Temperature *bool, Efforts, Context, Output, APIs, Images, Reasoning, Price}`（`cat/catalog.go:25-89`），来源见第 3 节。网关用它决定：是否发温度（`RejectsTemperature` `prov/models.go:764-771`）、effort 贴到哪一档（`Efforts` `:775-781`）、走哪个端点（`APIs` `prov/account.go:113-121`）、模型能否看图、组路由时的 max_tokens 上限（`gw/maxoutput.go`）。
5. **运行时学习**：`unfit` map（见第 5 节）。

另外 preset 表 `prov/presets.go:102+` 只描述**各家端点 URL（Chat / Responses / Anthropic 三个 base）、models.dev catalog id、区域/套餐**，不描述怪癖。preset 结构见 `prov/presets.go:20-61`。

请求修补的挂载点（按执行顺序）：
- 透传：`passthrough` 里按协议 switch（`gw/gateway.go:2768-2846`）→ `withoutRefused`（`:2851-2853`）；
- 翻译：`forwardTranslated` 改 IR 后 `build`（`gw/gateway.go:3222-3302`）；
- 两者最终都走 `forwardOnce`：DeepSeek/oneOf/Kimi schema 修补 + Anthropic beta/shape/adaptive（`gw/gateway.go:2608-2620`）。

### 2.2 怪癖清单（每条带证据）

#### A. 参数名 / 参数可用性

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| A1 | `max_tokens` vs `max_completion_tokens` | 翻译到 Chat：`*.openai.com` 用 `max_completion_tokens`，其余 `max_tokens`；Bedrock、Azure 的 Chat 无论透传还是翻译都把 `max_tokens` 改名（GPT 推理模型拒 max_tokens，#176） | `gw/chat.go:389-395`；`asCompletionTokens` `gw/gateway.go:4372-4395`，调用点 `:2815-2818`、`:3278-3280` |
| A2 | 客户端解析两个都认 | `MaxCompletionTokens` 优先，否则 `MaxTokens` | `gw/chat.go:70-75` |
| A3 | 推理模型禁 temperature/top_p | **不是硬编码 o 系列**，而是查 models.dev 的 `temperature:false` 字段（"a model released after this binary was built is handled without a code change"） | `prov/models.go:760-771`；`cat/catalog.go:265`；`buildChat` `gw/chat.go:396-403`、`buildResponses` `gw/responses.go:671-678` |
| A4 | Anthropic 开思考时不能带 temperature；temperature/top_p 互斥 | `else if` 链：开思考就都不发；否则 temperature 优先 | `gw/anthropic.go:433-451` |
| A5 | `developer` role | DeepSeek 等 Chat 后端拒收整个请求；透传 Chat 时一律改成 `system`（OpenAI 也接受 system） | `developerAsSystem` `gw/gateway.go:4076-4111`，调用 `:2798` |
| A6 | Responses 里对话中途的 developer 消息 | 原地包成 `<system-reminder>` user 消息，保缓存前缀 | `gw/responses.go:250-276` |
| A7 | 未知字段拒收（Mistral `extra_forbidden`，Gemini "Unknown name"，Groq "unsupported"） | 可选字段白名单 `store, metadata, service_tier, prompt_cache_key, prompt_cache_retention, safety_identifier, stream_options, parallel_tool_calls, verbosity, thinking, enable_thinking` 被点名拒绝 → 去掉重试并记住 | `gw/gateway.go:3415-3421`，见第 5 节 |
| A8 | Qwen `enable_thinking` / Kimi Code `thinking:{type}` 发到 OpenAI/Azure | 透传前直接删 | `gw/gateway.go:2808-2813` |
| A9 | Kimi Code 2.x 把 effort 放在 `thinking.effort` 里 | 搬到 `reasoning_effort` | `thinkingEffort` `gw/chat.go:609-631` |
| A10 | Bedrock 拒 Claude Code 的 `metadata.user_id`（JSON 串） | 透传/翻译都删 metadata | `gw/gateway.go:2824-2829`、`:3265-3269` |
| A11 | Bedrock 的 anthropic-beta 名字不同且拒未知 beta | 改名表 `advanced-tool-use-2025-11-20 → tool-search-tool-2025-10-19`；预先剔除已知拒收的两个；其余被点名拒绝时学习 | `gw/betas.go:23-35, 125-148` |
| A12 | 中转站拒 Claude Code 新字段：`thinking.display:"updates"/"highlights"`、`messages[].output_config` | 400 里点名 → 记住 `shape:*`，之后改写/剔除（highlights→summarized） | `gw/anthropic_shapes.go:13-43, 50-112` |
| A13 | xAI / Copilot 的 Responses 拒绝"有 tool_choice 没 tools" | 删 lone tool_choice | `withoutLoneToolChoice` `gw/gateway.go:4421-4434`，调用 `:2788-2796` |
| A14 | Codex 专有字段（`internal_chat_message_metadata_passthrough`、`encrypted_function_args`、`stream_options.reasoning_summary_delivery`、`configuration_update` item）发给非 OpenAI 中转被判"invalid codex request" | `forVendor` 剥离 | `gw/codex_backend.go:1122-1196`，#292 |
| A15 | 服务等级 `service_tier:priority` | 只发 OpenAI/ChatGPT（Responses）与 Cursor（Chat） | `gw/responses.go:680-682`、`gw/chat.go:384-388` |
| A16 | `stream_options.include_usage` | 翻译到 Chat 时自动加（否则流里没 usage） | `gw/chat.go:381-383` |
| A17 | 厂商对 max_tokens 有下限（"Expected a value >= 16"） | 正则读出下限，抬高后重试一次 | `gw/limit.go:10-60`，调用 `gw/gateway.go:1976-1985`，#260 |
| A18 | 路由组：模型输出上限不同 | 每个成员按自身 Output 上限压低 max_tokens；Anthropic thinking budget 一起压，压不下 1024 就关思考 | `gw/maxoutput.go:21-75`，调用 `gw/gateway.go:1703-1708` |

#### B. 推理 / thinking

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| B1 | 推理字段名：DeepSeek/Kimi/多数 `reasoning_content`；OpenRouter `reasoning`、`reasoning_details`；Mistral 是 content typed part；Gemini 兼容端点 `<thought>` 标签；Anthropic `thinking_delta`；Responses `reasoning_summary_text` / `reasoning_text`；Gemini `part.thought` | 全部归一到 `KThink` | `gw/chat.go:848-861, 733-801`；`gw/chattidy.go:199-234, 304-310`；`gw/anthropic.go:615-616`；`gw/responses.go:847-849`；`gw/codeassist.go:578-585` |
| B2 | 回传历史推理：DeepSeek 要（tool 调用间必须回传），OpenAI 只认自己的密封推理 | Chat：仅 DeepSeek（或 Command Code）回放 `reasoning_content`；Responses：仅 DeepSeek 模型且非 OpenAI 系 host 回放 reasoning item | `gw/chat.go:221-224, 315-317`；`gw/responses.go:579-586` |
| B3 | Mistral 拒收消息里的 `reasoning_content`（422 extra_forbidden），但接受它自己的 thinking part | 透传到 Mistral 时把 `reasoning_content/reasoning/reasoning_details` 转成 content 里的 `{"type":"thinking","thinking":[{type:text}]}` 前置 part | `mistralThinking` `gw/chattidy.go:393-434`，调用 `gw/gateway.go:2803-2807`，#494 |
| B4 | 其他严格厂商拒消息内推理字段 | `refusedInMessages` 解析 `loc:["body","messages",N,…,"reasoning_content"]` → 剥离并记 `messages[].reasoning_content` | `gw/gateway.go:3579-3618` |
| B5 | Claude ≥4.6 拒 `thinking.type=enabled + budget`（"requires adaptive thinking"） | 所有发往 Anthropic 端点的 body 最后一步 `adaptiveThinking`：改成 adaptive + 把 budget 换算成 `output_config.effort`；4.6 没有 xhigh → max | `gw/anthropic.go:240-295`，调用 `gw/gateway.go:2615-2619`；commit 081d836 / 72fd0cb |
| B6 | 非 Anthropic 家的 Anthropic 端点（DeepSeek 等）**默认就思考**，Claude Code 的标题请求不带 thinking 却被烧 token | 对非 Claude 模型，请求没提 thinking 就补 `thinking:{type:"disabled"}`（字节级追加，不重排） | `thinkingOffUnlessAsked` `gw/anthropic.go:182-203`，调用 `gw/gateway.go:2830-2836`；commit da27f2f |
| B7 | 有的模型**关不掉思考**（GLM-5.3 "always engages in thinking"、ZCode 中文「该模型始终支持思考，不可关闭」、DashScope "enable_thinking … restricted to True"、OpenRouter "reasoning is mandatory") | 400 匹配 `alwaysThinks`/`mandatoryReasoning` → 删掉 disabled 重发 | `gw/anthropic.go:209-238`，`gw/gateway.go:3398`、`:2947-2960`、`:2929-2934` |
| B8 | 关思考（effort none/minimal）被拒且错误列出档位（Command Code `expected one of "low"|…`） | 改为该模型最低开思考档位重试，并记 `reasoning off\x00model` | `gw/gateway.go:3326-3335`、`:2919-2928`、`effortLevelsNamed` `:4242-4245`、`onEffort` `:4199-4205` |
| B9 | 模型支持 `none` 档位时，客户端"关思考"直接映射成 `none` | `ThinkOff && Efforts 含 none → Effort="none"` | `gw/gateway.go:3223-3228`，#899 |
| B10 | 档位表不同（GLM-5.3 只有 low/high/max；Gemini 3 Pro 只有 low/high） | `fitEffort` 贴最近档位；只有开关没有档位的模型（Xiaomi mimo）最多发 high（转售商宣称的 max 会被原厂拒） | `gw/ir.go:537-573`；`fitFor` `gw/decide.go:624-637`，#214 |
| B11 | GLM-5.2/5.3 在 Anthropic 端点上 effort 要放 `output_config.effort`，单给 budget 不生效 | 正则 `glm-5\.[23]` 命中就补 output_config.effort | `gw/anthropic.go:301-323, 444-446`，`gw/gateway.go:2837-2839` |
| B12 | Bedrock GPT 的 Chat 端点不允许"工具 + reasoning_effort" | 如果没有其他端点可去 → `reasoning_effort:"none"` 重试 | `toolsWithoutEffort` `gw/gateway.go:3389-3395`、`:3343-3349`、`:2936-2946`，#176 |
| B13 | thinking budget 必须 < max_tokens；Anthropic 最小 1024 | 见 1.4 和 A18 | `gw/anthropic.go:433-443`；`gw/maxoutput.go:52-64` |
| B14 | effort ↔ budget 映射 | `budgetOf`/`effortOfBudget`；AI Studio Gemini 2.x：1024/1024/8192/24576 | `gw/ir.go:575-603`；`gw/chat.go:664-666` |
| B15 | 推理期间可能以拒答结尾（Opus xhigh 思考 10–25s 后 `stop_reason: refusal`） | 拒答前的思考事件被 hold，拒答发生则对客户端"什么都没说"，转给下一个账号 | `gw/fallback.go:1548-1557, 1660-1670`，#248 |
| B16 | 密封推理（`encrypted_content`）跨账号/跨厂商不可读（"could not decrypt"） | 匹配 `foreignReasoning` → 删 reasoning item 重试，仍不行再删 compaction item；按"会话 × 账号"记住被拒的签名 hash | `gw/affinity.go:427-540`，`gw/gateway.go:1935-1964` |

#### C. 工具调用

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| C1 | tool_choice 形态差异：Chat `"required"`/`{type:function,function:{name}}`；Anthropic `{type:any}`/`{type:tool,name}`/`disable_parallel_tool_use`；Responses `{type:function,name}` + `allowed_tools{mode,tools}`；Gemini `functionCallingConfig.mode ANY/NONE/VALIDATED + allowedFunctionNames` | 统一成 `auto|none|required|name:X`；allowed_tools/ANY 子集会真的过滤 tools 列表 | `gw/chat.go:120-133, 432-437`；`gw/anthropic.go:151-164, 485-503`；`gw/responses.go:378-436, 721-726`；`gw/gemini.go:282-326`；`gw/codeassist.go:224-240` |
| C2 | Anthropic 的"并行关"只能挂在 tool_choice 上 | `Parallel=false` 且无 tool_choice 时补 `{type:auto, disable_parallel_tool_use:true}` | `gw/anthropic.go:487-503` |
| C3 | 某些模型拒强制工具（Opus 5.5 / Sonnet 5.5："tool_choice: type tool and any are not supported"；或要求 strict 的 additionalProperties:false） | 改成 auto；若是指定工具则只保留那一个工具；记 `tool forced\x00model` | `gw/gateway.go:4215-4240, 3336-3341`，#668 |
| C4 | tool call id 长度：ChatGPT 后端 ≤64 | 超长 sha256 | `prov/codex_request.go:349-361` |
| C5 | tool call id 字符集：Antigravity 只允许 `[a-zA-Z0-9_-]` | 替换为 `_` | `gw/codeassist.go:26, 122-128` |
| C6 | Responses item id 前缀（fc_/tsc_/ctc_） | 编码时按类型生成；透传时把错误前缀改对，call_id 不动 | `gw/codex_backend.go:1011-1066`，#535 类 commit 23166a7 / 1a9c4ca |
| C7 | 并行调用缺 id / 同一时钟 tick 生成重复 id | `newID` = 纳秒 + 原子自增序号 | `gw/anthropic.go:900-911`，#128 |
| C8 | 流式分片每片重复 id | 同 id 视为同一调用 | `gw/chat.go:876-886` |
| C9 | 流式分片 `function.name:""` 重复出现（grok CLI 用空名覆盖） | `chatTidy` 删空 name | `gw/chattidy.go:21-26, 164-194` |
| C10 | 每个 delta 都带 `"tool_calls":[]`（Qoder 遇到就关文本块，一字一行） | 删空数组 | `gw/chattidy.go:28-33, 139-141` |
| C11 | 工具结果顺序/孤儿/缺失（Kimi 严格） | `pairToolMessages` | `gw/chat.go:450-561`，#554 |
| C12 | 工具结果里的图片（Chat 的 tool 消息不能放图） | 挪到后续 user 消息 | `gw/chat.go:228-254, 356-370` |
| C13 | 空参数 | 统一补 `{}`；非 JSON 字符串参数包成 `{"input": s}` | `argsOf`/`parseArgs` `gw/ir.go:390-413` |
| C14 | 模型把工具调用**写进正文**（Hermes `<tool_call>{json}</tool_call>`、GLM `<arg_key>/<arg_value>`、DeepSeek `<｜DSML｜invoke name=…>`） | 请求带 tools 时，从第一个标记起 hold 文本，结尾解析为真调用并改 stop=tool | `gw/textcalls.go:12-28`，透传 `gw/gateway.go:2999-3003`，翻译 `:3740-3756`；#823/#906/#917 |
| C15 | Gemini 命名空间前缀 `default_api:` | 剥离 | `gw/codeassist.go:617-645` |
| C16 | 中转站 Anthropic 流里 tool_use 的 input 在 start 里一次给全 | 见 1.4 | `gw/anthropic.go:509-562` |
| C17 | 停止原因：中转站给 tool_use 配 `end_turn`/`stop`，或 Anthropic 形状里出现 OpenAI 的 `tool_calls` | 有调用就判 tool | `gw/ir.go:362-376`；`gw/anthropic.go:672-676` |

#### D. JSON Schema（工具参数）

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| D1 | Anthropic 拒 input_schema 根部 anyOf/oneOf/allOf | 转成 object 根 | `objectSchema` `gw/anthropic.go:913-932`，#646 |
| D2 | DeepSeek 拒 pattern 里的 `\0` | 原地改成 `\u0000`（gjson 定位、从后往前拼接，不重编码） | `gw/deepseek_schema.go:14-58` |
| D3 | Kimi/Moonshot「moonshot flavored json schema」拒"有 enum 无 type" | 按 enum 值推断 type 原地插入 | `gw/kimi_schema.go:11-48`，#886 |
| D4 | OpenRouter/Cline/Kilo 背后 xgrammar 拒 `oneOf` | 原地把键名 `oneOf` 换成等长的 `anyOf` | `gw/oneof_schema.go:10-40` |
| D5 | Antigravity 只吃 OpenAPI 子集 | `plainSchema` | `gw/codeassist.go:322-520` |
| D6 | Gemini 客户端发来 OpenAPI 风格 schema | 转 JSON Schema | `gw/gemini.go:400-458` |
| D7 | ChatGPT 后端省略 strict 时按 strict 校验 | 显式写 `strict` | `gw/responses.go:703-706` |
| D8 | 空 schema | Anthropic 补 `{"type":"object","properties":{}}`；Code Assist 同 | `gw/anthropic.go:470-475`；`gw/codeassist.go:198-201` |

#### E. 消息结构

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| E1 | 连续同角色消息 | Anthropic/Gemini 构建时合并；Responses 解析时合并；Chat 侧避免 user 连发（tool 图片并入下一条 user，孤儿结果并入上一条 user） | `gw/anthropic.go:349-358`；`gw/codeassist.go:187-194`；`gw/responses.go:537-547`；`gw/chat.go:504-516` |
| E2 | 空 content | Anthropic 丢空白 text 块；Chat assistant 有 tool_calls 无文本时不写 content，否则写 `""`；空 assistant 消息若卡在调用/结果之间删除 | `gw/anthropic.go:364-366`；`gw/chat.go:291-297, 523-527, 569-580` |
| E3 | 只有无签名 thinking 的 assistant 回合 | 发 Anthropic 时整条消失（push 空不入） | `gw/anthropic.go:349-352, 387-391, 414` |
| E4 | Gemini 结果放在 model role | 强制 user | `gw/gemini.go:224-241` |
| E5 | 文件/PDF：只有 Gemini 能原生吃 | 其他协议降级为文本 `[attachment mime: url]`，不假装读过 | `gw/ir.go:66-73`；`gw/chat.go:175-195` (#934) |
| E6 | 图片格式：data URL ↔ base64+media_type ↔ URL | `imagePart`/`dataURL`/`imageBlock` 互转；Responses 的 `input_image` 只有 file_id 时无法跨协议 → 直接 400 | `gw/chat.go:197-213`；`gw/anthropic.go:325-340`；`gw/image_input.go:38-50`，`gw/gateway.go:3666-3669` |
| E7 | 模型不能看图 | 有 Vision 模型就先让它描述图片替换；没有就当前回合的图报错、历史图替换为占位文本 | `gw/vision.go:20-27`；`gw/image_input.go:11-30` |
| E8 | 中转站要求 body 原样（"请求体疑似被篡改"） | 改模型名用 gjson 原位替换，`withFields` 禁 HTML 转义，避免重排 key | `rewriteModel` `gw/gateway.go:4056-4074`；`gw/gateway.go:4347-4365`；commit 976ae3f |

#### F. 缓存（cache_control / prompt_cache_key）

| # | 怪癖 | 处理 | 证据 |
|---|---|---|---|
| F1 | 非 Anthropic 客户端翻译到 Claude 时没有 cache_control → 永不命中 | system 一个断点；对话最后一个非 thinking 块一个断点；无 system 时最后一个 tool 一个断点（总数 ≤2，给订阅的 1 个留余地，Anthropic 上限 4） | `gw/anthropic.go:399-420, 478-480`；commit ac2340d |
| F2 | 中转站 Chat 端点丢 cache_control | Claude 模型强制走 Messages | `prov/provider.go:1032-1056`；`gw/gateway.go:2438-2444` |
| F3 | `prompt_cache_key`（Codex 线程 id）对 OpenAI 及其中转决定缓存路由 | 翻译到 Chat/Responses 都转发；被拒（含未点名的 400）→ 去掉重试，成功则记住 | `gw/chat.go:378-380`；`gw/responses.go:665-667`；`gw/gateway.go:3254-3257, 3363-3375` |
| F4 | 改动 prompt 开头会废掉整段缓存 | developer 原地保留（A6）；所有 schema 修补都是**原地等长/插入**，注释反复强调 "a cache keeps its prefix" | `gw/oneof_schema.go:17-18`；`gw/kimi_schema.go:19-20`；`gw/deepseek_schema.go:18-21` |

#### G. usage 字段差异与缓存 token 计数

内部口径：`Input` = 未命中缓存的输入（`gw/ir.go:199-234`）。

| 来源 | 字段 | 换算 | 证据 |
|---|---|---|---|
| OpenAI Chat | `prompt_tokens`（含缓存）、`prompt_tokens_details.cached_tokens`、OpenRouter 的 `cache_write_tokens`、`completion_tokens_details.reasoning_tokens` | Input = prompt − read − write | `gw/chat.go:672-717` |
| DeepSeek | `prompt_cache_hit_tokens` | 作为 CacheRead 兜底 | `gw/chat.go:686, 697-701` |
| Moonshot | 顶层 `cached_tokens` | 同上 | `gw/chat.go:687` |
| 中转站把 Anthropic 名字塞进 Chat usage | `cache_read_input_tokens`/`cache_creation_input_tokens` | 若 prompt_tokens < read+write，说明是 Anthropic 口径（不含缓存），不再相减 | `gw/chat.go:688-712` |
| Anthropic | `input_tokens`（不含缓存）、`cache_read_input_tokens`、`cache_creation_input_tokens`、`cache_creation.ephemeral_5m/1h_input_tokens` | 1h 写入单独记（2× 计价） | `gw/anthropic.go:631-664` |
| Responses | `input_tokens`（含缓存）、`input_tokens_details.cached_tokens / cache_write_tokens`、`output_tokens_details.reasoning_tokens` | 相减 | `gw/responses.go:737-765` |
| Gemini | `promptTokenCount`（含缓存）、`cachedContentTokenCount`、`candidatesTokenCount`、`thoughtsTokenCount` | Output = candidates + thoughts；回写 Gemini 时 candidates = Output − Reasoning | `gw/codeassist.go:555-559`；`gw/gemini.go:470-482` |
| 聚合器 | 顶层/`message`/`response` 里的 `provider` 字符串（OpenRouter 的 DeepInfra/Novita…） | 记录实际上游 | `gw/upstream.go:15-40` |
| `Usage.add` | 只用非零值覆盖（流里 usage 分多次到达：Anthropic start 给输入、delta 给输出） | | `gw/ir.go:236-273` |

#### H. stop reason 映射（全部集中）

| 内部 | Chat finish_reason | Anthropic stop_reason | Responses | Gemini finishReason |
|---|---|---|---|---|
| `stop` | stop | end_turn | completed | STOP |
| `length` | length | max_tokens（入：`max_tokens`、`model_context_window_exceeded`） | incomplete / max_output_tokens | MAX_TOKENS |
| `tool` | tool_calls（入：`tool_calls`、`function_call`） | tool_use（入也认 tool_calls/function_call） | 有 function_call 即 tool | （有调用即 tool） |
| `filter` | content_filter | refusal（入：refusal、content_filter） | incomplete / content_filter | SAFETY（入：SAFETY/RECITATION/BLOCKLIST/PROHIBITED_CONTENT/SPII/其他未知） |

证据：`gw/chat.go:931-953`；`gw/anthropic.go:666-695`；`gw/responses.go:875-893, 1133-1149`；`gw/codeassist.go:871-882`、`gw/gemini.go:460-468`。

#### I. 流的"脏数据"修补（透传时）

`chatTidy` `gw/chattidy.go:9-162`：
- `"reasoning_content":""` 每个 delta 都出现（WorkBuddy）→ 删（Qoder 会把每次当作思考重新开始）；
- `"finish_reason":""` → `null`（AI SDK 严格校验拒收）；
- 空 tool name、空 `tool_calls:[]` → 删；
- Mistral content typed parts → 拆成 string content + reasoning_content。
`chatWhole` 同理处理非流式（`:258+`）。

---

## 3. 模型元数据从哪来

**三层叠加，用户覆盖优先：**

1. **models.dev 远程目录**（主数据源）
   - URL `https://models.dev/api.json`（`cat/catalog.go:308`）；`Sync` 下载到 `<cache>/models.json`，也会读 OpenCode 的缓存（`cat/catalog.go:337-355, 467-503`），有 `Stale()` 判过期、后台刷新（`cat/fresh.go`）。
   - 读取的字段（`mdModel` `cat/catalog.go:261-286`）：`temperature`（false=拒温度）、`reasoning`（是否推理）、`reasoning_options[{type:"effort",values}]` / `{type:"budget_tokens"}`、`modalities.input/output`、`cost`（含 `tiers` 长上下文分档计价）、`limit.context/input/output`、`provider.npm`（`@ai-sdk/openai` 表示走 Responses）。
   - 窗口取 `limit.input`，否则 `limit.context`（gpt-5 的 272K/400K）（`:298-306`）。
   - **跨 provider 投票**：同一个裸 id 在多家的值取"多数家给的"作为未知厂商的兜底（images/windows/outputs/efforts/thinks/names 六张表 `cat/catalog.go:310-333`；`ContextOf/OutputOf/EffortsOf` `:680-749`）；id 归一：去厂商前缀、去 Bedrock inference profile 前缀、去 `(high)`、`:free` 后缀（`:686-707`）。
   - **"制造商优先"**：推理档位先问模型原厂（preset 里 `KindVendor` 且非 Hosts 的 catalog），再问转售商，因为转售商会宣称原厂不支持的 max（`ListedBy` `cat/catalog.go:751-779`；`makerCatalogs` `prov/models.go:866-882`，#214）。
   - 价格同理：provider 自己的 → 原厂的（`ListPrice` `prov/models.go:881-900`）；Claude 1h 缓存写自动按 2× 输入补（`OneHourFor` `cat/catalog.go:186-197`）。
   - `RejectsTemperature` 直接读 `Temperature` 字段：「a model released after this binary was built is handled without a code change」（`prov/models.go:760-771`）。

2. **厂商 `/models` 实时列表**（"A vendor's own /models endpoint is the truth about what it serves today; models.dev lags"，`cat/live.go:19-22`）
   - 自动试多种路径；带 key 同时发 `Authorization: Bearer` 和 `x-api-key`；Anthropic 风格加 `anthropic-version`（`cat/live.go:144-262`）。
   - 兼容的扩展字段（`liveModel` `cat/live.go:357-394`）：`data` 或 `models` 数组、`display_name`、`modalities.input`、`supported_endpoints`（Command Code/Copilot：哪个模型走哪个端点）、`context_length`（OpenRouter）、`max_output_tokens`、`supported_reasoning_levels`（Codex/magpie 格式）、`type_target`（PipeLLM）。
   - 非文本模型（embedding、speech）过滤；绘图/视频模型打标单列（`cat/live.go:286-293`）。
   - `Decorate` 用 models.dev 补显示名和档位，保留厂商顺序（`cat/live.go:448+`）。

3. **用户覆盖 / 内置兜底**
   - `Provider.Contexts`（含 `*` 通配）、模型 output 上限、自定义推理档位 `settings.ModelEfforts`、`ModelAPI` 强制端点（`prov/provider.go:220-224`；`prov/models.go:775-781`；`prov/account.go:113-121`）；查找顺序 docs 写明：「this model → this provider's `*` → the provider's own list → models.dev」（`docs/reference.md:595-597`）。
   - 内置小列表仅保证选择器不空（`cat/catalog.go:1-3` 包注释）。
   - 能力**探测**：只有被动探测——上游拒绝时学习（第 5 节），没有主动 probe 能力；`magpie provider test` 是每个 API 发一个小请求测连通（`docs/reference.md:145`）。

---

## 4. 错误归一化

### 4.1 失败分类（决定"重试同家 / 换账号 / 换模型 / 直接告诉客户端"）

核心函数 `failure(status, body)` `gw/routing.go:183-209`，输出类别常量 `gw/routing.go:132-179`：

| 类别 | 判定（按顺序） | 冷却（rest） |
|---|---|---|
| `proxy` | 502 + `proxyconnect`/`socks connect` | 不冷却，换下一个 |
| `verify` | 401/403 + Google `VALIDATION_REQUIRED`（`prov/test.go:540-574`） | 30 分钟 / 直到用户验证 |
| `other`（超长） | `overflowed()`：400/413/422 + `tooLongRe` | 不冷却，见 4.2 |
| `credit` | 402，或 `creditWords` 且（非 429 或 429 带 `brokeWords` 如「余额不足」），或 `insufficient_quota` | 30 分钟 `creditRest` |
| `rate` | 429 + `rateWords`（rate limit / per minute / RPM/TPM / 频率 / 太频繁）且**不含** `plannedWords` | 1 分钟起，反复命中指数退避到 30 分钟 |
| `quota` | `usedUpWords`（quota / usage limit / limit reached / 额度 / 用量 / 套餐 / 上限），或 429 + `plannedWords`（daily/weekly/限额已用完） | 15 分钟，或按 `Retry-After`/`resets_at`/ratelimit-reset 头，最长 8 天 |
| `rate`（兜底） | 其余 429 | |
| `other` | 其余 | |

正则全在 `gw/routing.go:108-130`；冷却时长常量 `gw/routing.go:83-105`；`Retry-After` 与各种 `*ratelimit*reset*` 头解析 `gw/routing.go:559-586`；ChatGPT `usage_limit_reached.resets_at/resets_in_seconds` `gw/routing.go:311-330`。

**是否值得换别家**：`retryable` `gw/fallback.go:741-761`：
- 超长 → **不换**（换哪个账号都一样长，告诉客户端去压缩）；
- 401/402/403/404/408/429/5xx → 换；
- CDN/防火墙拦截页 → 换；
- 400/422 只有命中 `quotaWords | unservedWords | refusedWords | shapeWords` 才换（`gw/fallback.go:704-737`）：
  - `unservedWords`：model not found / unsupported model / 模型不存在|不支持|无权|未开通；
  - `refusedWords`：WorkBuddy "unapproved channel"（拒的是 agent 的 system prompt，不是账号）→ 同账号家族排到最后（`matesLast` `:906-930`），不冷却；
  - `shapeWords`：failed to deserialize / unknown field / extra inputs are not permitted → `failShape`，不冷却。

**同家原地重试**：`passing` `gw/fallback.go:838-860`：408/500/502/503/504/529 重试 2 次；429 且是短期限流（非额度、非欠费）重试 3 次，1s/2s/4s 或 Retry-After，超过 8 秒的等待不等直接报错。

### 4.2 上下文超长

- `tooLongRe` 汇集各家措辞（`gw/gateway.go:4518-4534`）：OpenAI `context_length_exceeded`、Anthropic "prompt is too long"、Gemini "input token count … exceeds the maximum"、xAI "maximum prompt length is"、Groq "reduce the length of the messages"、OpenRouter "maximum allowed input length"、Together、llama.cpp、LM Studio、Copilot "prompt token count of"、MiniMax "context window exceeds limit"、Kimi "exceeded model token limit"、z.ai "Prompt too long"/`model_context_window_exceeded`、Ollama、DashScope "Range of input length should be"、中文「上下文长度超…」。注释说明表来自 pi 的 `overflow.ts`。
- **排除**：提到 `max_tokens/max_output_tokens/max_completion_tokens` 的（是输出上限问题，压缩没用）；`paceWords`（rate limit / per minute / TPM / please wait）——Bedrock 的 "Too many tokens, please wait" 曾被误判导致 Claude Code 疯狂压缩（`tooLong` `gw/gateway.go:4543-4564`，commit eb3a074）。
- **对客户端统一改写**：status 400 + `invalid_request_error` + code `context_length_exceeded`；Anthropic 客户端消息前补 "prompt is too long: "，让 agent 触发自动压缩（`writeError` `gw/gateway.go:4487-4494`；流内 `streamError` `:4457-4466`）。
- **厂商不说原因的超长**（Devin 502 "capacity issues"、WorkBuddy 400 "Invalid request parameters"、Qoder 400 "Error in upstream response"）：估算 token 超过窗口 1.2 倍且错误不属于其他类别 → 当作超长（`tooLongUnsaid` `gw/fallback.go:764-819`）。
- 路由组里：超长成员跳过，只换到"窗口装得下"的成员（`withRoom` `gw/fallback.go:861-880`，#700）。

### 4.3 内容过滤 / 安全拒答

- `filterReasons` 统一表（`gw/fallback.go:1563-1576`）：`refusal`、`content_filter`、`content_policy_violation`、Gemini `SAFETY/PROHIBITED_CONTENT/BLOCKLIST/SPII/IMAGE_SAFETY`。
- 错误码形态：OpenAI `*_policy`（bio_policy、cyber_policy）、`invalid_prompt` + "flagged/usage policy"、Azure content_filter → `policyRefusal` `gw/fallback.go:1896-1953`。
- 流内识别 `streamEvent` `gw/fallback.go:1641-1850`：能在任意协议的单个 SSE 事件上判断"这是前导帧 / 思考 / 内容 / 错误 / 拒答"。**关键策略**：在第一个真正内容出现前 hold 住流（`holdWriter`），若以拒答结束且还没说过话，就把请求转给同模型其他账号（`matesFirst` `:882-905`），对客户端完全透明；拒答在内容开始后才来则不冷却任何人（commit fde0c38）。
- 无内容的拒答返回 400（`refusedStatus` `:1557-1561`），避免 Codex 把空回复当正常结果反复重试烧钱（#248）。
- 翻译时保留拒答 code（`refusedCode` `:1955-1985`），否则 Claude Code 看到的只是普通失败。

### 4.4 其他归一

- 错误回包按**客户端协议**的形状写（Anthropic `{"type":"error","error":{type,message}}`、Gemini `{"error":{code,message,status:"RESOURCE_EXHAUSTED"…}}`、OpenAI `{"error":{message,type,code,param}}`），status → type 映射表（`writeError` `gw/gateway.go:4468-4530`）。
- 流中错误消息反推等价 status（`streamStatus` `gw/fallback.go:2045-2063`）：overloaded→529、欠费→402、rate/quota→429、unserved/invalid/too long→400、其他 502。
- 人类可读错误提取：`APIError`/`ErrorType`（`prov/test.go:499-640`），兼容 `{"error":{message}}`、`{"error":"…"}`、`{"message":…}`、错误 JSON 被包在 `[HTTP 400] …` 文本里（`gw/gateway.go:3460-3482`）。
- 中途断流的 Go "unexpected EOF" 改写成 "connection lost mid-reply"，因为某些客户端不重试 EOF（`gw/gateway.go:3122-3128`，#470）。

---

## 5. 参数自适配（剥参重试 + 学习记忆）—— 有，且是核心机制

### 5.1 记忆体

```go
// gw/gateway.go:303-305
// unfit remembers the endpoints each provider's models were turned away
// from, so every later turn goes straight to one that takes them.
unfit map[string]bool
```
键 = `providerID \x00 X \x00 protocol`（`fits`/`markUnfit` `gw/gateway.go:3179-3190`），X 可以是：

| X | 含义 | 写入点 | 读取点 |
|---|---|---|---|
| 模型 id | 这个模型不在这个端点 | `gw/gateway.go:2967, 3378` | `usable` `:3199-3214` |
| 可选字段名（store/metadata/service_tier/prompt_cache_key/…） | 厂商不认这个顶层字段 | `:2914-2918` | `withoutRefused` `:3553-3573` |
| `messages[].reasoning_content` 等 | 消息内推理字段被拒 | `:2905-2918` | `withoutRefused` `:3565-3572` |
| `reasoning off\x00<model>` | 该模型不许关思考 | `:3331` | `:3258-3261` |
| `tool forced\x00<model>` | 该模型不许强制工具 | `:3339` | `:3262-3264` |
| `thinking_config` | Gemini 兼容字段被拒 | `:3323` | `:3270-3273` |
| Codex image 工具 | 不认命名空间的厂商 | `:3312`, `:2900` | `:3246-3248, 2858-2860` |
| `anthropic-beta\x00<beta>` | beta 头被拒 | `gw/betas.go:134-148` | `gw/betas.go:43-66` |
| `shape:thinking.display(=new)` / `shape:messages[].output_config` | Claude Code 新字段被拒 | `gw/anthropic_shapes.go:50-69` | `:73-87` |

**注意：纯内存、不持久化**（`New()` 里 `make(map…)` `gw/gateway.go:342`；anthropic_shapes 注释「is not sent it again while magpie runs」`gw/anthropic_shapes.go:27-29`）。重启后重新学一次。

### 5.2 重试循环怎么判断"是哪个参数的锅"

**透传路径**（`passthrough` `gw/gateway.go:2868-2919`）：只要是 400/422 就循环：
1. `refusedOptional`：错误里**明确点名**白名单字段才算——解析结构化错误优先（`{"type":"extra_forbidden","loc":["body","store"]}`、`{"code":"unsupported_parameter","param":"x"}`），再回退到文本正则（"unknown name 'x'"、"unsupported parameter: x"、"'x' is not supported"），并且 Gemini 的 `at 'path'` 嵌套字段不算顶层（`gw/gateway.go:3422-3550`）。**刻意不把"值无效"当"字段不支持"**：`unsupported_value`、带 `loc` 的值校验错误一律返回 false（`:3517-3524`），注释：「An invalid value must reach the client without dropping the field or caching it as unsupported」（`:3423-3425`）。
2. `refusedInMessages`：解析 `loc` 指向 messages 内推理字段（`:3583-3618`）。
3. 都没点名：只对 Codex image 工具做一次"盲删"尝试。
4. 删字段后重发；**最终成功（<400）才写入 unfit**（`:2914-2918`）——避免把真正的其他错误误学成"不支持"。

接着是三个专项重试（每个只一次）：关思考被拒→low（`:2919-2928`）、OpenRouter 强制推理→删 reasoning-off（`:2929-2934`）、工具+effort 被拒→none（`:2936-2946`）、Anthropic 关思考被拒→删 disabled（`:2947-2960`）。

**翻译路径**（`forwardTranslated` `gw/gateway.go:3222-3387`）：一个 `for {}` 循环，每轮先按 unfit 预先剔除，再 build、发送；按错误逐项判定改 IR 再 `continue`：thinking_config → effort 名单 → 强制工具 → 工具+effort → image 工具（试错式，记住"上一次猜的"，猜错就恢复）→ prompt_cache_key（点名则立刻记，没点名则"去掉后成功才记"，`dropped` 标志 `:3237-3239, 3305-3310, 3363-3375`）→ 换端点。

**转发层**（`forward` `gw/gateway.go:2563-2605`）：Anthropic 400 最多 3 轮学习 beta/shape。

**路由层**（`gw/gateway.go:1935-1990`）：密封推理被拒（`failForeign`）、`configuration_update` 被拒（`failUpdate`）、max_tokens 下限（`failFloor`）各重试一次。

### 5.3 设计要点（值得照抄的）

- **白名单**：只自动剥"去掉也不影响语义"的可选字段，必需字段/内容字段不剥。
- **点名才学**：必须错误里出现该字段名；未点名的盲试必须"去掉后成功"才落记忆。
- **值错误 ≠ 字段不支持**。
- **记忆粒度**：provider × 字段 × 协议（有的再细到 model），不是全局。
- **成功后才提交记忆**，失败重试有次数上限（每类一次，beta 3 轮）。
- 所有修补都**按字节原地改**（gjson/等长替换/尾部追加），保持 prompt cache 前缀和中转站的"body 未篡改"校验。

---

## 6. git log 高价值兼容踩坑（15 条）

| # | commit | 日期 | 摘要 |
|---|---|---|---|
| 1 | `1abcf8d` | 10-01 | #393：Mistral 对 OpenCode 每次发的 `store:false` 回 422 `extra_forbidden`。引入"被点名的可选字段→剥掉重试→成功后记住"机制（5.2 的起点）。 |
| 2 | `6b89fb2` | 10-02 | #494：历史 assistant 的 `reasoning_content` 是 DeepSeek/Kimi 要的，Mistral 却 422 拒；改成 Mistral 自己的 thinking typed part，其他严格厂商按 `loc` 剥消息内字段并记忆。教训：**同一字段在不同厂商是"必须"和"禁止"两个极端**。 |
| 3 | `89672eb` | 10-01 | #388：DeepSeek 思考模式下 tool 调用之间必须回传推理（"must be passed back"），翻译路径之前丢了；而 OpenAI 系只认自己的密封推理、回传别的会被拒 → 只对 DeepSeek 回放。 |
| 4 | `88fd366` | 10-03 | #687：Gemini 3 每步第一个 function call 有 thought_signature，下一轮必须带回，但 Chat 客户端会丢掉非标 `extra_content` 字段 → 把签名 base64url 塞进 tool call id 里"走私"往返。 |
| 5 | `2e1fcb8` | 10-02 | #554：Kimi 严格校验工具往返（"tool_call_id is not found"）：乱序、重复回答、孤儿结果、中断未答都要修补（`pairToolMessages`）。 |
| 6 | `081d836` + `72fd0cb` | 09-25 / 10-03 | Claude 4.6+ 拒 `thinking.type=enabled+budget`（"requires adaptive thinking"）；第二个 commit 把修补下沉到"所有发往 Anthropic 端点的 body 的最后一步"，不管 budget 是谁写的。 |
| 7 | `da27f2f` | 09-25 | DeepSeek 的 Anthropic 端点默认开思考（与 Anthropic 语义相反），Claude Code 不带 thinking 的标题请求烧 token → 非 Claude 模型未提 thinking 时显式补 disabled。随后 `24bd8aa`/`de29024`（#596/#699）：GLM-5.3/DashScope 关不掉思考，中文报错也要识别后撤回。 |
| 8 | `ac2340d` | 09-29 | 从 Codex（Responses）/Chat 客户端翻译到 Claude 时没有 cache_control，**永不命中缓存** → 自动在 system 和对话末尾打断点。配合 #997（`prov/provider.go:1032`）：中转站 Chat 端点会丢 cache_control，Claude 一律走 Messages。 |
| 9 | `9c44e5b` | 09-28 | Codex 经 Chat 中转时丢了 `prompt_cache_key`，缓存不生效、token 暴涨 → 翻译时保留；被拒再剥。 |
| 10 | `e61d1da` | 10-03 | #668：Opus 5.5 拒绝强制工具（`tool_choice` tool/any 不支持）→ 改 auto 且只留指定工具，并按模型记忆。 |
| 11 | `288767a` | 10-01 | #394：关推理（effort none）被 Command Code 拒，错误里列出可选档位 → 用最低开档重试并记住。 |
| 12 | `11a09d4` + `eb3a074` | 10-03 / 09-30 | 各家"上下文超长"统一改写成 `context_length_exceeded` 让 agent 自动压缩、不 failover；反例：Bedrock "Too many tokens, please wait" 是限流，误判后 Claude Code 无限压缩 → 加 `paceWords` 排除。 |
| 13 | `74242b9` / `ad9536a` / `f2c7536` | 09-29 – 10-01 | WorkBuddy（腾讯）流的脏数据：`finish_reason:""`（AI SDK 拒收）、每个 delta 都带空 `reasoning_content` 和 `tool_calls:[]`（下游客户端每次都开新块导致一字一行）、重复空 tool name → `chatTidy`。教训：**空字符串/空数组 ≠ 字段缺失**，下游解析器会当信号。 |
| 14 | `3c67b5c` + `fb19c5d` | 10-01 / 09-24 | 工具调用 id 两连坑：中转站每个分片重复 id（规范只给第一片）被当成新调用；并行调用转 Responses 时 id 错位导致重复 tool_call_id 被拒。 |
| 15 | `bbc89f9` / `c353f7b` / `307f413` / `a532d15` | 10-05 | #823/#906/#917：长对话（~700k）下 DeepSeek/GLM 把工具调用写进正文（Hermes `<tool_call>`、GLM `<arg_key>`、DeepSeek DSML），agent 不执行直接结束回合 → 文本里解析回真调用。LESSONS.md 专门以此为例：「Build fixtures from the reporter's literal bytes」，第一次用自造 JSON 样本"证明"修好了，实际格式完全不同，前后修了 4 次。 |

补充（未进 15 条但值得一看）：`509e844`（Kimi enum 无 type）、`0b8fca7`（oneOf→anyOf for xgrammar）、`52ac04d`（Anthropic 根 anyOf）、`07ec824`（Responses 必须显式 strict）、`976ae3f`（重编码 body 会被中转站判"篡改"且破坏缓存）、`e63fbb0`（429 + 余额不足应判欠费不是限流；LESSONS 指出更该告诉用户"key 放错端点了"）、`0cb6e13`（#502 developer 消息位置影响缓存）、`71f9884`（#613 Responses 参数要取 done 事件的完整值）。

LESSONS.md 本身（`LESSONS.md:1-238`）主要是流程教训，与兼容直接相关的三条：
- 「Build fixtures from the reporter's literal bytes」（`LESSONS.md:27-35`）——模型输出解析器要收集多个真实失败回合，截断和空 body 也要进测试；
- 「Scope a vendor rule to that vendor」（`LESSONS.md:85-91`）——e950eb08 因一个 DeepSeek 报告把所有模型 cap 到 272K，连 Claude [1m] 也被 cap；需"另一家模型不变"的测试；
- 「Fix what the error is about, not only how it is worded」（`LESSONS.md:57-65`）——见 `e63fbb0`。

---

## 7. 对 MemoryPalace（Swift 客户端，OpenAI 兼容 + Anthropic 原生，17 家预设）的借鉴

> 以下是我的判断，不是 magpie 的事实；供粟粟审。

**可以直接搬的：**
1. **IR + 事件枚举**：我们只需两个上游协议（Chat、Anthropic），但把解码统一成 `Event{start,text,think,sig,toolStart,toolArgs,stop,usage,error}` 后，UI/持久化层就只对接一种流，加 Responses/Gemini 时只写 decoder。`Usage.Input` 统一用"未命中缓存"口径 + `prompt()` 还原，计费与显示一处搞定（`gw/ir.go:199-234`）。
2. **Chat 解码器的容错细节**几乎都适用于客户端：`reasoning_content`/`reasoning` 二选一、Mistral typed parts、`<thought>` 跨 chunk 识别、重复 tool id、choice index 是字符串、`finish_reason:""`、空 `tool_calls:[]`（`gw/chat.go:803-900`、`gw/chattidy.go`）。
3. **请求构建侧的 per-host 规则**：`max_completion_tokens` 只给 openai.com（+Azure/Bedrock）、`developer→system`、DeepSeek 回放 `reasoning_content`、Mistral 改 thinking part、`stream_options.include_usage`、`pairToolMessages` 修补工具往返（我们支持重新生成/分支，最容易产生孤儿 tool 结果）。
4. **温度能力从 models.dev 的 `temperature:false` 取**，而不是硬编码 o 系列；推理档位"原厂优先、转售商兜底"。
5. **unfit 自学习**（建议持久化，magpie 没做）：白名单可选字段 + 点名才学 + 成功才记 + 值错误不学；键 = provider × 字段 × 协议（× model）。
6. **错误分类表**直接移植成 Swift 正则：`failure()` 的 credit/quota/rate 三分、`tooLongRe`+`paceWords`、`filterReasons`。客户端没有多账号 failover，但可以用来：超长→提示/自动压缩；rate→按 Retry-After 退避；credit/quota→提示换 key；filter→明确显示"被安全过滤"而不是空回复。
7. **Anthropic 构建细节**：只回放有签名的 thinking、Claude ≥4.6 用 adaptive + output_config.effort、budget < max_tokens 的夹逼、开思考不发 temperature、自动打两个 cache_control 断点、tool_result 排在 user 消息最前、根 anyOf 的 schema 改成 object。

**magpie 自己的空白/风险（我们别照抄）：**
- `unfit` 纯内存（`gw/gateway.go:342`），重启重学；客户端应持久化并允许用户清除。
- 翻译到 Anthropic 时 tool_use id 没有做字符集清洗（只有 Antigravity 做了 `gw/codeassist.go:26`）；Anthropic 要求 `^[a-zA-Z0-9_-]+$`，从别家（如带 `.`/`:` 的 id）切到 Claude 可能 400——我们若支持"会话中途换模型"需要自己做 id 映射。
- IR 不认 `redacted_thinking`（`gw/anthropic.go:116-131` 只处理 `thinking`），翻译回 Anthropic 时会丢；我们是 Anthropic 原生直连，存历史时必须原样保留 redacted_thinking 块和 signature。
- 怪癖全散在 if 分支里，靠注释里的 issue 号维护；我们 17 家预设规模小，建议做成 per-preset 的 `Quirks` 结构（布尔/枚举字段），配合 models.dev 能力表 + 运行时 unfit，三层叠加。
