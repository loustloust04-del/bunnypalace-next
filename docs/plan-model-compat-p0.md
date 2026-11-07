# plan · 模型兼容 P0（SSE 三坑 / OpenAI 兼容路思考 / 工具续轮回传 / 错误分类重试 + 集中 compat 骨架）

⚠️ DON'T IMPLEMENT YET

> 来源：[research-model-compat.html](research-model-compat.html) §3 的 P0 A–D + P1 E 的骨架；底图 [mp-current.md](research-model-compat/mp-current.md)，参照 [magpie.md](research-model-compat/magpie.md) / [ohmypi.md](research-model-compat/ohmypi.md)。
> 粟粟 10-15 已拍板 Q1–Q4 全按推荐：范围 = A–D + E 骨架；OpenAI 兼容路的思考进「思考过程」折叠、跟同一个设置；5xx / 529 / 短时 429 自动重试 2–3 次、小胶囊提示、已开始输出不重试；先实测再动 B / C（实测还没做，见 §1）。
> 基线：工位 backend-3，HEAD `facd4d3bf`（代码同 `406f97e63`）。行号以 `MemoryPalace/` 为根。
> 只写文档，没改代码、没编译、没提交。

---

## 0. 一句话 + 分阶段

把三家流式解析共用一个按字节切行的 SSE 解码器；建一个集中的 `ResolvedCompat`，先把散着的 host 判断收进去；OpenAI 兼容路把 `reasoning_content` / `reasoning` / `reasoning_details` 解析成思考段，工具续轮按原字段名回传；聊天请求认出限流 / 过载 / 额度 / 超长，前两类在还没出字时自动重试最多 2 次。

| 阶段 | 内容 | 改动面 | 请求体变不变 | 可独立合并 |
|---|---|---|---|---|
| 1 | **A** SSE 解码器（CRLF、多字节跨分片、`data:` 无空格；三家共用） | `ChatService.swift` 解析层 + OAuth 一处 | 不变 | ✅ |
| 2 | **E 骨架** `ResolvedCompat` + `KnownHost`，收拢 4 处 host 判断；B / C 要的开关先占位（默认值 = 现行为） | `ParamCompat.swift`（或新文件）、`ChatService.swift` provider / preview | 不变（金样 G1–G8 一字不动） | ✅ |
| 3 | **B** OpenAI 兼容路解析思考 → 思考段；**C1** 当轮工具续轮回传 | provider 解析、builder `:809-820`、`ToolTurn`、VM 4 处读点 | 只在「有思考 + 工具续轮 + 开关开」时多一个字段 | ✅ |
| 3b | **C2** 历史回合回传（DeepSeek 带工具时 / Kimi K3）——**等实测结论再定做不做**（§1、Q4） | `MessageSegment` 加来源 key、组装层、builder 历史 wire | 只对开关开的端点 | ✅ |
| 4 | **D** 错误分类 + 有限重试 + 胶囊 + 说人话 / 去改 | 新 `ChatErrorClassifier`、router `adaptiveFailed`、`FixJump`、VM 一个回调 | 不变 | ✅ |

阶段之间的依赖：3 依赖 2（开关从 `ResolvedCompat` 读）；3b 依赖 3；1、4 不依赖别的阶段，可以和 2 并行。

---

## 1. 待实测（Q4）+ 官方文档查证

实测还没做。先用官方文档把「要不要回传、不回传会怎样」查清楚，作为实测前的证据。**下面的结论和 research 里的推断不完全一样：DeepSeek 的要求比我们以为的更宽（不只当轮，历史也要）。**

### 1.1 文档结论

| 厂商 | 官方说法（原文要点） | 出处 | 对本单的影响 |
|---|---|---|---|
| **DeepSeek**（思考模式） | 思考模式**默认开**，默认档 high；OpenAI 格式用 `thinking: {type: enabled/disabled}` + `reasoning_effort`。流式思考在 `delta.reasoning_content`。**带 `tools` 的请求**：之前所有回合的 `reasoning_content` 都要回传，「even for turns where the model did not perform a tool call」；没回传「the API will return a 400 error」。**不带 `tools`**：不用回传，传了也被忽略。思考模式下 temperature / penalty 不报错、只是不生效 | <https://api-docs.deepseek.com/guides/thinking_mode> | ① C1 当轮续轮必须回传；② **历史回合也要（C2）**——我们几乎每条都带 tools（卡 `toolsSupported` 默认开），所以第二轮起就可能 400；③ 文档没说「别家模型生成的历史 assistant」怎么办 |
| **Kimi / Moonshot**（K2 thinking 系列、K3） | 思考在 `reasoning_content`，流式时总在 `content` 之前。工具循环里「keep all of the reasoning content … and send it back」，并建议「Pass the complete assistant message … as-is」。**K3：多轮和工具循环都必须带**；K2.6 历史默认被忽略，`thinking.keep: "all"` 才保留；K2.7-code 一直保留。没写不带会报什么错。另：「Do not set temperature」、`max_tokens >= 16000` | <https://platform.kimi.ai/docs/guide/use-kimi-k2-thinking-model>（原 platform.moonshot.ai 301 过来） | C1 当轮回传；K3 还需要 C2；`temperature` / `max_tokens` 建议记进 P1（现在默认发 0.7，靠 400 自愈兜） |
| **OpenRouter** | 思考在 `reasoning`（字符串）和 `reasoning_details[]`（`reasoning.text` 带 `signature` / `reasoning.summary` / `reasoning.encrypted` 的 `data`，带 `id` / `format` / `index`）。流式时按顺序把各片拼起来。工具调用时把 `reasoning_details` 放回 assistant 消息，「you cannot rearrange or modify the sequence of these blocks」。只给原始推理字符串的模型可以用更简单的 `reasoning` 字段回传；`reasoning_content` 是 `reasoning` 的别名。没写不带会报什么错 | <https://openrouter.ai/docs/use-cases/reasoning-tokens> | C1：有 `reasoning_details` 就原样整串回传（还掉 Q7 债：OR 上 Claude 的签名）；只有字符串就回 `reasoning` |

### 1.2 实测矩阵（车头打，执行者不发真请求）

用粟粟指定的卡或测试 key，模拟器 / 单测壳都行；**报错原文按字节存进 `MemoryPalaceTests/Fixtures/chat-errors/`**（magpie LESSONS：样本用原文，别自己编）。

| # | 端点 · 模型 | 场景 | 预期（按文档） | 决定什么 |
|---|---|---|---|---|
| T1 | DeepSeek 官方 · 现在预设里的 id（`deepseek-chat` / `deepseek-reasoner` 老别名）+ 文档里的 `deepseek-flash` | 带 tools，第一轮调工具 → 第二次请求**不带** reasoning_content | 400 | C1 是不是现在就在坏 |
| T2 | 同上 | 第二次请求带上当轮 reasoning_content | 200 | C1 回传形状对不对 |
| T3 | 同上 | 下一轮用户消息：历史里那条 assistant(tool_calls) 不带 reasoning_content | 400？ | C2 要不要做 |
| T4 | 同上 | 历史里是**没调工具**的 DeepSeek 回复，不带 reasoning_content，本轮带 tools | 400？ | C2 范围是「所有 assistant」还是「只 tool_calls 的」 |
| T5 | 同上 | 历史里是别家模型（Claude）的回复，发 `reasoning_content: ""` / 不发 | ? | Q5 兜底写法 |
| T6 | Kimi 官方 · K2 thinking 系 + K3 | 当轮续轮不带 / 带 reasoning_content；K3 下一轮历史不带 | ?（文档没写错误） | C1 / C2 对 Kimi 的开关 |
| T7 | Kimi 官方 | tool_calls 那条 assistant 的 `content: ""` | ? | `requiresAssistantContentForToolCalls` 开不开（omp 说 Kimi 要非空） |
| T8 | OpenRouter · `anthropic/claude-sonnet-5`（或她账号能用的 Claude） | 带 tools + 思考，续轮不带 / 带 reasoning_details | ? | Q7 债：会不会 400 / 只是静默重想 |
| T9 | 任一 | 5xx / 429 的真实报错正文 + `Retry-After` 头 | — | D 的分类样本 |

实测结论回填本节后再定 3b 做不做（Q4）、各开关默认值。

---

## 2. 阶段 1 · A：SSE 解码器（三家共用）

### 2.1 现状（坑）

| 坑 | 位置 | 后果 |
|---|---|---|
| CRLF 切不开 | `ChatService.swift:989` / `:1594` `buffer.firstIndex(of: "\n")`——Swift 里 `"\r\n"` 是一个字符，找不到 `"\n"` | 回 `\r\n` 的中转整段流 0 行 →「未收到回复」 |
| 多字节跨分片整片丢 | `:980` / `:1585` / OAuth `ChatGPTOAuthProvider.swift:117` 每个分片单独 `String(data:encoding:.utf8)`，切在中文中间返回 nil → `return` | 丢字，甚至丢掉含 `[DONE]` / usage 的整行；非 200 时 `errorBody` 也一样丢（`:982-985` / `:1587-1590`） |
| 只认带空格的 `data: ` / `event: ` | `:993` / `:1598` / `:1600` | 不带空格的合法 SSE 被忽略 |
| 附带 | OAuth `:120` 按 `"\n\n"` 切事件，同样 CRLF 切不开；OAuth 的 `processData` 不分 200 / 非 200，非 200 正文进了 `buffer` 不进 `errorBody`（`handleErrorBody` 拿到空 → 只剩「API 错误 (码)」） | 订阅通道报错看不到原文 |
| 附带 | 嗅探缺头 SSE：`:426` `String(data: data.prefix(16), encoding: .utf8)` 也可能切在多字节上 | 极少见；顺手改成有损解码 |
| 附带 | 流结束时 buffer 里最后一行没有换行就丢了（`didCompleteWithError` 不 flush） | 末行是 usage / `[DONE]` 时少记 |

### 2.2 新类型

`Services/SSELineDecoder.swift`（新文件，纯值类型，无依赖）：

```swift
/// 按字节缓冲，只在完整行上做 UTF-8 解码；行尾认 \n、\r\n、单独 \r（\r 在分片末尾时等下一片再判）
struct SSELineDecoder {
    enum Field: Equatable { case event(String), data(String), comment, other }
    private var pending = Data()
    mutating func feed(_ data: Data) -> [Field]
    /// 流结束：把没换行的最后一行也吐出来
    mutating func finish() -> [Field]
    mutating func reset()
    /// 规范：`field:value`，冒号后**最多去一个**空格；以 `:` 开头 = 注释；没冒号 = 整行是字段名、值为空
    static func parse(line: String) -> Field
}
```

- **行为不变的地方**（刻意不做的）：仍然「每个 `data:` 行单独当一个 payload」、`event:` 行设置当前事件类型——和现在逐行处理的语义一样。**不做**空行派发 + 多行 `data:` 拼接（没有任何一家 LLM 把一个 JSON 拆成多行 data，改派发时机有回归风险，列入 §8）。
- 解码用 `String(decoding:as: UTF8.self)`（整行已完整，不会再切在字中间；万一上游本身发了坏字节，替换成 `�` 而不是丢整行）。
- `pending` 无上限会被恶意 / 坏上游撑大：设 32 MB 上限（同 magpie `bufio.Scanner`），超了报错「回包一行太长」走 onError。

### 2.3 接入点

| 位置 | 改动 |
|---|---|
| `BaseChatProvider.buffer`（`:40`）| 换成 `var sseDecoder = SSELineDecoder()`；`resetState` `:262` 改成 `sseDecoder.reset()`；新增 `var errorBytes = Data()`，`errorBody` 改成计算属性（`String(decoding: errorBytes, as: UTF8.self)`）——**所有读 `errorBody` 的地方不用动**（router `adaptiveFailed`、`onHTTPError`、分类器） |
| `OpenAICompatibleProvider.processData` `:979-1012` | 非 200 → `errorBytes.append(data)`；否则 `for field in sseDecoder.feed(data)`：`.data(payload)` 走原来的 `[DONE]` / `parseOpenAIChunk` 分支，其余忽略 |
| `AnthropicProvider.processData` `:1584-1604` | 同上；`.event(name)` 设 `currentEventType`（现在 `:1599` 还 trim 了空白，保留） |
| `ChatGPTOAuthProvider.processData` OAuth `:116-125` + `handleEvent` `:131-140` | 改成同一个解码器：`.data(json)` 直接进 `handleEvent` 的 JSON 段（不再按 `\n\n` 切事件、不再自己找 `data:` 行）；非 200 进 `errorBytes` |
| `didCompleteWithError` `:438-475` | 在 `if receivedDone { return }` 之前：`isEventStream && httpStatusCode == 200` 时 `for field in sseDecoder.finish()` 走一遍 `processData` 同款分发（抽一个 `handle(_ fields:)`，三家各自 override；基类默认空） |
| 嗅探 `:426` | `String(decoding: data.prefix(16), as: UTF8.self)` |

**和现有机制衔接**：`receivedDone`、`enqueueCallback` 代际守卫、`processData` 是 `@objc` override（`:489`）都不变；`hitOutputLimit`、工具累积、`ReplyBlock` 记块逻辑都在 payload 层，不受影响。

### 2.4 影响范围 / 回归风险

- 流式解析是所有聊天的必经之路。风险点：① `\r` 在分片末尾的延迟判定写错会吞一行；② `errorBody` 改计算属性后，`onHTTPError` 里 `errorBody.lowercased().contains("cache")`（`:1150`）照常；③ OAuth 改成逐 data 行后，`event:` 行被忽略（它本来就只看 data 里的 `type`）。
- 现有 `ThinkingStreamTests` / `BudgetGateTests` / `NonStreamParseTests` 喂的是 `\n` 结尾、整段一次喂，结果必须不变。

### 2.5 测试（新 `SSELineDecoderTests` + 三家 provider 喂流）

- 解码器：`\n` / `\r\n` / 单独 `\r` / 三种混用；`\r` 恰好落在分片末尾、`\n` 在下一片；空行；`:` 注释；`data:x`（无空格）= `x`、`data:  x`（两个空格）= ` x`；`event:message_stop`；没冒号的行；`finish()` 吐出没换行的末行；超 32 MB 报错。
- **多字节跨分片**：同一段 SSE（含中文、emoji、`[DONE]`）在**每一个字节位置**切成两片喂（循环 1…n-1），OpenAI / Anthropic 两家的 `streamingContent`、工具调用、usage、`receivedDone` 都和整段喂一致。
- CRLF 版本的 `ThinkingStreamTests.toolTurnSSE`（把 `\n` 全换成 `\r\n`）：块、签名、usage 全一致。
- OpenAI：`data:{...}` 无空格 + `data:[DONE]` 能结束；Anthropic：`event:content_block_delta` 无空格。
- OAuth：`response.output_text.delta` 跨分片中文；非 200 时 `handleErrorBody()` 拿到原文。
- 非 200 的错误正文中文被切在分片边界：`errorBody` 完整。

---

## 3. 阶段 2 · E 骨架：`ResolvedCompat`

### 3.1 现状：散着的 host 判断（6 处，判定写法还不一样）

| 判断 | 位置 | 判定写法 |
|---|---|---|
| `isOfficialOpenAI` → 键名 `max_completion_tokens`、推理档禁采样 | `ParamCompat.swift:71, 91, 114-116` | `host == "api.openai.com"` |
| `supportsInterleavedSystem` → 序列内 system 原位发 | `ChatService.swift:691-699` | `host == api.openai.com` 或 `contains("openrouter.ai") && openai/*` |
| `wantsORCacheControl` → OR 上 Claude 挂 cache_control | `:675-682` | `baseURL.contains("openrouter")`（**路径里含 openrouter 的代理也算**） |
| `orPreferredProviderOrder` → OR 路由 deepseek 优先 | `:685-689` | `contains("openrouter")` |
| `ReasoningEffort.route` → `reasoning:{effort}` vs `reasoning_effort` | `ReasoningEffort.swift:32-43` | `host.hasSuffix("openrouter.ai")` |
| `APIUsageParser.isOpenRouter` → 读 `usage.cost`、记 response id | `APIUsageParser.swift:4-7` | `https` 且 `host == "openrouter.ai"` |

调用点：provider 发送 `ChatService.swift:621-643`、预览 `:2393-2416`、检查器说明 `:2454`、VM `ConversationViewModel.swift:2530`、`CardFlowView.swift:3470`（后两处只用 `route`）。

### 3.2 新类型（组合，不改 `ParamCompat` 本身——Q1）

放 `Services/ResolvedCompat.swift`：

```swift
/// 端点 × 模型的兼容配置：建请求前算一次，builder / 解析只读字段（抄 omp resolve.ts「发请求的代码不做探测」）。
/// 解析顺序：协议默认 → baseURL 主机探测（KnownHost）→ 按血统规则 → 学到的（ParamAdaptStore）。卡上的用户覆盖留 P1
struct ResolvedCompat: Equatable {
    var params: ParamCompat              // 现有：采样 / 键名 / 思考格式 / 学到不收的组（原样）
    var host: KnownHost
    // —— 收拢的 host 判断（值 = 现在的行为）——
    var interleavedSystem: Bool          // supportsInterleavedSystem
    var orCacheControl: Bool             // wantsORCacheControl（依赖 cacheFriendly）
    var orProviderOrder: [String]?       // orPreferredProviderOrder（依赖 cacheFriendly）
    var reasoningRoute: ReasoningEffort.Route
    // —— 阶段 3 要读的开关（阶段 2 先占位，默认 = 现行为：不解析、不回传）——
    var reasoningContentField = "reasoning_content"            // 没抓到来源字段时回传写哪个
    var requiresReasoningContentForToolCalls = false           // C1
    var requiresReasoningContentForAllAssistantTurns = false   // C2（3b）
    var requiresAssistantContentForToolCalls = false           // tool_calls 那条 content 不能是空串（Q12，默认全关）
    var splitsLeadingThinkTag = false                          // B：正文开头的 <think> 拆成思考（Q3）

    static let permissive: ResolvedCompat                      // builder 默认参数 / 老测试用
    static func resolve(providerType: ProviderType, baseURL: String, modelId: String,
                        sampling: SamplingParams?, store: ParamAdaptStore? = .shared,
                        catalog: ...) -> ResolvedCompat
}

enum KnownHost: Equatable {
    case openai, openrouter, anthropic, deepseek, moonshot, other
    /// 都按小写 host 判（不按整串子串——见 Q2）
    static func detect(_ baseURL: String) -> KnownHost
}
```

KnownHost 词表（阶段 2 只认这 5 个，别的厂商 P1 再加）：

| case | host 规则 |
|---|---|
| openai | `api.openai.com` |
| openrouter | host 以 `openrouter.ai` 结尾 |
| anthropic | `api.anthropic.com` |
| deepseek | host 以 `deepseek.com` 结尾 |
| moonshot | `api.moonshot.ai` / `api.moonshot.cn` / `api.kimi.com` |

### 3.3 行为规则

- **阶段 2 是纯搬家**：每个字段的值必须和改前那个函数算出来的一样（Q2 例外，见下）。`ParamCompat.resolve`（`ParamCompat.swift:66-96`）内部的 `isOfficialOpenAI` 改成读 `KnownHost.detect(baseURL) == .openai`，结果不变。
- 原来 4 个静态函数（`wantsORCacheControl` / `orPreferredProviderOrder` / `supportsInterleavedSystem` / `ParamCompat.isOfficialOpenAI`）删掉，调用点改读 `compat.xxx`（检查器说明 `:2454` 也读 `interleavedSystem`）。`ReasoningEffort.route` 保留（ccBridge / 本机 / OAuth 也走它，VM 和 CardFlowView 在用），只把 `.openaiCompatible` 分支改成 `KnownHost.detect(baseURL) == .openrouter ? .openRouter : .chatCompletions`；`ResolvedCompat.reasoningRoute` 调它。
- **一次解析**：provider 的 `sendStreaming` 里原来两行（`:623` resolve ParamCompat + `:625` route）+ builder 参数里三次现算，合成一次 `ResolvedCompat.resolve`；`previewRequestBody` 同一个函数同一组输入 → 预览 = 实发不变。builder 的 `compat: ParamCompat` 参数换成 `compat: ResolvedCompat`，`orCacheControl` / `orProviderOrder` / `interleavedSystem` / `reasoningRoute` 四个参数并进去（builder 签名变短）。
- `adaptedSampling`（`:2371`）、`ProviderProbe.swift:107`、`PersonaSettingsTab.swift:294` 只要采样层，继续直接用 `ParamCompat.resolve`，**不动**。
- `APIUsageParser.isOpenRouter` 不收进来（它管计费解析，不是请求兼容；收进来要把 compat 传进 usage 解析，改动面大），列 P1。

### 3.4 衔接 / 风险

- `ParamAdaptStore` / `ParamErrorClassifier` / `adaptiveFailed` 一行不动（它们只认 `ParamCompat` 和 `Learned`）。
- 金样 `PromptRealPathGoldenTests` G1–G8、`InspectorRealPathTests`、`ProviderOrderingTests` 夹具**一个字节都不能变**——这是阶段 2 的验收线。
- 风险：Q2 若选「统一成 host 后缀」，路径里含 `openrouter` 的自建代理（如 `https://x.com/openrouter/v1`）不再挂 OR 缓存标、不再走 deepseek 优先路由——这是行为变化，单列一条测试锁住新行为。

### 3.5 测试（`ResolvedCompatTests`）

- `KnownHost.detect`：5 个 host + 大小写 + 带路径 + `api.openai.com.evil.com` 不算 openai + 子域名 `eu.openrouter.ai` 算 openrouter。
- 等价表：对一组（type × baseURL × model × cacheFriendly）组合，新字段 == 旧四个函数的返回值（改前先把旧函数结果抄成表，删函数前跑一次锁住）。
- 「换一家不受影响」：DeepSeek / Moonshot 的 host 不改变 `params` 任何字段（magpie LESSONS「厂商规则只作用于这个厂商」）。
- 现有 `ParamCompatTests` / `ReasoningEffortTests` / `ProviderOrderingTests` / `CardSlashRequestBodyTests` / `PersonaRequestBodyTests` / `RegexPipelineTests` 里调四个旧函数的地方改成读 `ResolvedCompat`（断言值不改）。

---

## 4. 阶段 3 · B：OpenAI 兼容路解析思考

### 4.1 新类型（`Models/ChatToolTypes.swift`）

```swift
/// OpenAI 兼容路这一次回复的思考（plan-model-compat-p0 §4）。来源字段名照记，回传时写回同一个字段（抄 omp「签名里存来源字段名」）
struct ReasoningCapture {
    /// reasoning_content / reasoning / reasoning_text / reasoning_details / think_tag
    var field: String?
    var text = ""
    /// OpenRouter reasoning_details 原样（按 index 合并分片后），回传时整串照发、不改顺序
    var details: [[String: Any]] = []
    var isEmpty: Bool { text.isEmpty && details.isEmpty }
    /// 存段：有文字才存（只有密文的 reasoning.encrypted 不存段，但仍可回传）
    var segment: MessageSegment?    // .thinking(text: text, signature: nil)
}
```

### 4.2 解析规则

`OpenAICompatibleProvider` 新增 `private(set) var reasoning = ReasoningCapture()`，`sendStreaming` 开头和 `toolCallAccum` 一起清空。

流式 `parseOpenAIChunk`（`:1015`，在 `:1067` 读 `content` 之前）：

1. **文字**：按 `reasoning_content` → `reasoning` → `reasoning_text` 取**第一个非空字符串**（同一片里中转会把同一段思考同时放两个名字下，只取一个，magpie `chat.go:848-852`）；第一次取到时记 `field`。`reasoning` 不是字符串（对象）时跳过。
2. **reasoning_details**（OpenRouter）：`delta.reasoning_details` 数组逐项合并进 `details`：同 `index`（没有 index 就按「同 type 且上一项还开着」）的 `text` / `summary` / `data` 拼接，`signature` / `id` / `format` 取最后一个非空；有 details 时 `field = "reasoning_details"`（回传优先用它，见 §5）。**文字**只在第 1 步这一片没取到时，才从 details 的 `reasoning.text` / `reasoning.summary` 补（OR 同一片通常既有 `reasoning` 又有 details，避免双份）。
3. **`<think>` 正文**（`compat.splitsLeadingThinkTag` 开、且这次还没收到第 1、2 步的原生思考时）：正文**开头**（去掉空白后）是 `<think>` 才进入「思考中」，直到 `</think>`；标签被切在两片之间时先压着（照 `ThinkTagConverter` `ReasoningEffort.swift:203-231` 的尾巴压住写法，另写一个 splitter，不改它）。正文中间出现的 `<think>` 不动（人设可能要求写，原样留给正则脚本，同现在 `ContentCleaner` 不剥人设 `<thinking>` 的规矩）。`field = "think_tag"`。
4. 空字符串、`null` 不算收到（magpie chatTidy：`"reasoning_content": ""` 每片都带的中转）。

非流式 `parseNonStreamBody`（`:953-976`）：`message.reasoning_content` / `reasoning` / `reasoning_text` / `reasoning_details` 同规则，结果放进 `NonStreamResult`（新增 `reasoning: ReasoningCapture`），`emitPaced` 时赋给 provider。

usage 不变：`completion_tokens_details.reasoning_tokens` 已经在读（`:1049-1051`）。

### 4.3 落库 / 显示（Q2：和 Claude 思考一样）

- router 加 `@ObservationIgnored private var openAIReasoningSerial = -1`，照 `anthropicBlocksSerial`（`:1834`）的做法在 `chatProvider.sendStreaming` 前记序号；新增
  - `var lastReasoning: ReasoningCapture?`（序号对得上才给）
  - `var lastThinkingSegments: [MessageSegment] { lastAssistantBlocks.thinkingSegments + (lastReasoning?.segment.map { [$0] } ?? []) }`
- VM 4 个读点：`onComplete` `ConversationViewModel.swift:3994`、`onError` `:4065`、停止 `:2251` 从 `lastAssistantBlocks.thinkingSegments` 换成 `lastThinkingSegments`；`onToolCalls` `:4085` 的 `replySegments(replyBlocks, text:)`（`:3795`）加参数 `reasoning:`——没有 Anthropic 块、有 reasoning 段时输出 `[思考, 正文]`（OpenAI 兼容路思考总在正文前，Kimi 文档原话）。`attachThinking`（`:3781`）不用改：普通回复照旧存成 `[.text(正文), 思考]`，`isAttachedThinkingReply` 照旧认。
- 显示：`.thinking(text:, signature: nil)` 已经被 `MessageSegmentsView` / 文章模式 / 页 2 当思考画、跟「思考过程」设置（`DisclosureKind.thinking`）走，**不用新 UI**。思考标题沿用现有文案；如有新文案提到对方，用楼层的 `assistantName` 变量，不写死。
- **流式中不实时显示思考**（和现在 Anthropic 路一样：回复完才挂上），实时显示列 P1（Q9）。
- 存储量：DeepSeek / Kimi 思考可能上万字进 `segments`，和 Anthropic summarized 同一量级（omitted 时更小），不做截断；记在复盘里。

### 4.4 衔接 / 风险

- `ReplyBlock` / `wireContent` / `assistantContent` 不碰（那是 Anthropic 原样块；OpenAI 路的思考不混进去，免得 `thinkingBlockCount` / `droppingThinking` / `BudgetPreflight.EchoedThinking` 误算）。
- `streamingContent` 不含思考 → 正文、正则、记忆提取、搜索、标题都和现在一样只看正文。
- `TimelineConsolidator.momentLines` 会读到思考段（同 review-thinking §1 已知行为）。
- 回归风险：`replySegments` 改签名，调用点只有 `:4085`；`lastThinkingSegments` 对 Anthropic 卡的结果必须和原来逐项相同。

### 4.5 测试（`OpenAIReasoningStreamTests`）

- 各字段名：`reasoning_content`（DeepSeek / Kimi 形状）、`reasoning`（OR）、`reasoning_text`、`reasoning_details`（三种 type，分 3 片、带 index）→ `text` / `field` / `details` 正确；同一片 `reasoning_content` 和 `reasoning` 都有 → 只取一份。
- `"reasoning_content": ""` 每片都带 + 正文 → 不产生思考段。
- 跨 chunk `<think>`：`<thi` | `nk>想` | `法</th` | `ink>正文` → 思考「想法」、正文「正文」；正文中间的 `<think>` 不拆；开关关时整段原样进正文；已收到原生 reasoning 时不拆。
- 非流式整包 `message.reasoning_content` → 同结果。
- VM：普通回复 `[.text, .thinking]`；工具轮 `[.thinking, .text, .toolUse…]`；Anthropic 卡的段和改前一致（复用 `ThinkingSegmentTests` 夹具）。
- 换卡 / 提前失败读到空（照 `testEarlyFailureDoesNotReadPreviousRepliesBlocks`）。

---

## 5. 阶段 3 · C1：当轮工具续轮回传思考

### 5.1 现状

`OpenAICompatibleProvider.buildRequestBody` `:809-820`：每个 `ToolTurn` 写 `{"role":"assistant","content":"","tool_calls":[…]}`，忽略 `assistantContent`，没有思考可回传。

### 5.2 改动

- `ToolTurn`（`ChatToolTypes.swift:34-50`）加 `var reasoning: ReasoningCapture? = nil`；**`results` 从 `let` 改 `var`**，三个「换结果重建 ToolTurn」的地方（VM `:2070`、`:3864`、`:4494`）改成 `var t = 原 turn; t.results = …`，新字段自动带上（防 astra #1 那类「重建漏字段」）。`PendingUserQuestion`（VM `:1932`）加 `reasoning` 字段，`:4482` 存、`:2070` 取。
- `droppingThinking()`（`:44-47`）**不去** `reasoning`：它是给 Anthropic 签名 / 前缀用的；预算收尾 `tools: nil` 那次（VM `:3911`）DeepSeek 仍然要回传，否则正好撞 400。
- VM `onToolCalls` 组 ToolTurn 时 `reasoning: router.lastReasoning`。
- builder `:809-820` 每个 turn 的 assistant 消息：
  - `compat.requiresReasoningContentForToolCalls` 且 `turn.reasoning` 非空：
    - `field == "reasoning_details"` → `msg["reasoning_details"] = details`（原样整串，OR 文档：不能改顺序）
    - `field` 是 `reasoning_content` / `reasoning` / `reasoning_text` → `msg[field] = text`（写回同一个字段）
    - `field == "think_tag"` → `msg[compat.reasoningContentField] = text`
  - 开关开、但这一轮没抓到思考（中转剥了）→ 不发字段（不编占位；占位写法等实测，Q5）。
  - `compat.requiresAssistantContentForToolCalls` 开且 content 是空串 → 写 `"."`（omp `openai-completions.ts:2699-2701`）；阶段 3 默认全关（Q12）。
- **开关默认值**（阶段 3 在 `ResolvedCompat.resolve` 里填，按 omp `resolve.ts:541-545` 收窄到我们有证据的）：

| 条件 | requiresReasoningContentForToolCalls |
|---|---|
| `KnownHost == .deepseek` | ✅（文档） |
| `KnownHost == .moonshot` | ✅（文档） |
| `KnownHost == .openrouter` | ✅（文档：工具调用要保留 reasoning_details） |
| 其他 host（中转 / SiliconFlow / 自建） | ❌，但 400 能学到（下一条） |

- **报错自学（复用 #094 机制）**：`ParamErrorClassifier` 加两条认法，进 `ParamAdaptStore.Learned.groups`：
  - 正文含 `reasoning_content` / `reasoning` 且含 `must be passed back`（DeepSeek #388 原文，magpie）→ `Fix.require("reasoning_replay")`：学会「这个端点+模型要回传」，没输出时重发一次（这次 turn 里有 reasoning 才重发；没有就说人话不重发）。
  - 422 `extra_forbidden` 且 `loc` 指向 `messages.N.reasoning_content` / `reasoning_details`，或文字点名这俩字段 + 拒收词（Mistral 那类，magpie 6b89fb2）→ `Fix.drop("reasoning_replay")`：学会不回传，重发一次。
  - `SentShape` 只存顶层键（`ParamErrorClassifier.swift:36-55`），新增 `sentReasoningReplay: Bool` 记这次有没有回传，只认真发过的（同 #094 规矩）。
  - `ResolvedCompat.resolve` 里「学到的」覆盖默认表。设置页「自动适配：…」的说明文字补两条：「工具续轮回传思考」/「不回传思考」。

### 5.3 衔接 / 风险

- 只影响「OpenAI 兼容卡 + 工具续轮 + 这次有思考 + 开关开」的请求；不带工具、Anthropic、OAuth、本机都不变。预览 `previewRequestBody` 不带 toolTurns，金样不变。
- 保险闸：`BudgetPreflight.estimate` 按 body 字典估字（`BudgetPreflight.swift:79-95`），`reasoning_content` 文字会被算进去；`reasoning_details` 里的 `data`（密文）被它排除——轻微低估，可接受，记复盘。
- VM 工具轮预检 `preCheckToolRequestBudget` 用 `toolTurnsEstimateText`（VM `:3810`）只拼 calls / results，不含思考——和 review-thinking §3 已登记的同一条债，顺手把 `reasoning.text` 拼进去（一行）。
- 风险：OR 上 `reasoning_details` 合并错一个字节就可能被拒（文档说顺序不能改）；单测用 OR 文档里的形状 + 实测 T8 原文。

### 5.4 测试

- `ProviderOrderingTests` 加夹具：DeepSeek host、一个 turn 带 `reasoning(field: reasoning_content)` → assistant 消息多 `reasoning_content`，其余字节和老夹具相同。
- 回传字段名：`reasoning` 来的写回 `reasoning`；`reasoning_details` 来的写回整串 details（顺序、index、signature 原样）；`think_tag` 写 `reasoning_content`。
- 开关关（未知中转）→ 不写；学到 `reasoning_replay` 后 → 写；学到 drop → 不写。
- `droppingThinking()` 后 `reasoning` 还在；预算收尾那次 body 里仍有 `reasoning_content`。
- `PendingUserQuestion` 恢复后的 ToolTurn 带着 reasoning。
- 分类器：DeepSeek「must be passed back」原文 → `.fix([.require("reasoning_replay")])`；FastAPI `loc: [body, messages, 2, reasoning_content]` extra_forbidden → `.drop`；没真发回传字段时不认（SentShape）。
- Router（假服务器）：第一次 400 must be passed back → 记住 + 重发带字段 → 200；第二次同端点直接带。

---

## 6. 阶段 3b · C2：历史回合回传（**等 §1 实测结论**）

只在 T3 / T4 / T6 证明「历史不带会 400」时做。设计先写在这里，供批注。

- **来源标记**：`MessageSegment.thinking` 加第 4 个关联值 `source: String? = nil`（Codable 多一个可选 key，老版本解码时忽略、照样读成思考段——和 `redactedData` 同一种加法，`MessageSegment.swift:9-10, 94, 164-167`）。值 = `"<field>|<规范化 host>|<模型 id 小写>"`，只有 B 写的段有；导入的（`ClaudeImporter.swift:242`、`AIStudioParser.swift:128-132`）、Anthropic 的、CC 的都是 nil。模式匹配 `.thinking(let a, let b, let c)` 的 ~8 处补一个 `_`。
- **组装**：VM `composePrompt` 挂工具回合那段（`ConversationViewModel.swift:2454-2461`）旁边，按节点 id 挂 `historyReasoning`（PromptMessage 加 `var reasoning: ReasoningCapture?`）；`ToolReplay.rounds`（`ToolReplay.swift:24-82`）遇到 `.thinking` 段把它挂到下一个工具回合上（`ToolReplayRound` 加 `reasoning`），节点最后的正文那条拿节点里最后一段思考。
- **发送**（`compat.requiresReasoningContentForAllAssistantTurns` 开时，`openAIWire` `ChatService.swift:731-766`）：
  - 段的 `source` 和当前「host + 模型」一致 → 按 `field` 写回原文；
  - 不一致 / 没有（别家模型、导入、改过模型）→ 按 Q5 写 `reasoning_content: ""` 或不写（待实测 T5）。
- **默认开的端点**：DeepSeek host 且这次带 tools（文档：不带 tools 时被忽略，不发省 token）；Kimi `kimi-k3*`。
- 风险：历史体积变大（每轮都带上一轮的长思考）、缓存前缀会因为补字段变一次；只对开关开的端点生效，金样不受影响。
- 测试：组装层挂对节点；同模型写原文、跨模型走兜底；DeepSeek 不带 tools 时不写；老版本解码新数据（带 `source` 的 JSON）能读成思考段（`CodingMessageSegmentsTests` 同款）。

---

## 7. 阶段 4 · D：错误分类 + 有限重试

### 7.1 现状

- `adaptiveFailed`（`ChatService.swift:2117-2183`）只对 400 / 422 自愈；`failureMessage`（`:2343-2367`）只给 401 / 403 / 404 补人话；429 / 5xx / 529 原文 +（host · 模型 · HTTP n）尾巴直接落一条「⚠️」进历史，不重试、不读 `Retry-After`。
- 响应头只读了 Content-Type（`:478-486`）。流内 `error` 事件（状态 200，OpenAI `:1055-1063`、Anthropic `:1752-1760`）只把 message 往上传，原始 JSON 丢了，分类拿不到 `type`（如 `overloaded_error`）。
- 网络错误（状态 0）只有 `localizedDescription`（`:444-449`），拿不到错误码。

### 7.2 新类型：`Services/ChatErrorClassifier.swift`

```swift
/// 聊天请求失败归类（抄 magpie gw/routing.go failure() 的判定顺序 + omp flags.ts 的超长正则）。
/// 400 / 422 的参数问题仍归 ParamErrorClassifier，这里只管它不管的
enum ChatErrorClassifier {
    enum Kind: Equatable {
        case transient                        // 408 / 500 / 502 / 503 / 504 / 529 / overloaded
        case rateLimited(retryAfter: TimeInterval?)   // 短时 429
        case quota                            // 402 / 欠费 / 额度用完 / insufficient_quota
        case contextTooLong                   // 上下文超长
        case contentFiltered                  // 报错正文说被安全策略拦（finish_reason 那条留 P1 J）
        case connectionLost                   // 状态 0 且 NSURLErrorNetworkConnectionLost（Q6）
        case other
    }
    struct Input { var status: Int; var body: String; var streamError: String?; var headers: [String: String]; var urlErrorCode: Int? }
    static func classify(_ input: Input) -> Kind
    static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval?   // retry-after 秒数或 HTTP 日期；retry-after-ms
}
```

判定顺序（照 magpie，先命中先用）：

1. **超长**：状态 400 / 413 / 422（或流内 error）且正文命中超长表，**并且**不提 `max_tokens` / `max_completion_tokens` / `max_output_tokens`（那是输出上限，交给现有 R8），也不含限流措辞（`rate limit` / `per minute` / `TPM` / `RPM` / `please wait` / `try again later` / `频繁`——magpie eb3a074：Bedrock「Too many tokens, please wait」）。超长表（omp `flags.ts:90-117` + magpie `gateway.go:4518-4534`）：`context_length_exceeded`、`prompt is too long`、`exceeds the context window`、`maximum context length is \d+`、`input token count.*exceeds the maximum`、`maximum prompt length is \d+`、`reduce the length of the messages`、`exceeded model token limit`（Kimi）、`model_context_window_exceeded`、`context window exceeds limit`（MiniMax）、`range of input length should be`（DashScope）、`input is too long for requested model`、`token limit exceeded`、`上下文长度超`、`超出.{0,10}上下文`、`输入.{0,6}过长`。
2. **额度 / 欠费**：402；或含 `insufficient_quota` / `insufficient balance` / `exceeded your current quota` / `exceeded_current_quota` / `credit` / `billing` / `payment required` / `余额不足` / `欠费` / `账户余额`，且（不是 429，或 429 但带欠费词）。
3. **短时限流**：429 且含 `rate limit` / `rate_limit` / `too many requests` / `per minute` / `RPM` / `TPM` / `频率` / `太频繁` / `请求过多`，且不含「已用完」类词（`daily` / `weekly` / `usage limit` / `limit reached` / `quota` / `额度` / `用量` / `套餐` / `限额已用完`）。
4. **额度用完（计划类）**：含「已用完」类词，或 429 + 这类词 → `.quota`。
5. **其余 429** → `.rateLimited`（magpie 兜底同）。Kimi 的 429 `engine_overloaded_error` 也落这里（读 Retry-After，没有就按短时退避）。
6. **过载 / 服务器**：408 / 500 / 502 / 503 / 504 / 529，或流内 error 的 `type` / `code` 是 `overloaded_error` / `api_error` / `server_error` / `service_unavailable` → `.transient`。
7. **内容过滤**（正文）：`content_policy_violation` / `content_filter` / `ResponsibleAIPolicyViolation` / `data_inspection_failed` / `invalid_prompt` + `flagged` / `敏感` → `.contentFiltered`（不重试）。
8. 状态 0 + `NSURLErrorNetworkConnectionLost`（-1005）→ `.connectionLost`；其他网络错误 → `.other`。

### 7.3 provider 侧补料

- `BaseChatProvider` 加 `responseHeaders: [String: String]`（小写键）、`streamErrorBody: String?`、`urlErrorCode: Int?`；`didReceive response`（`:478`）存头，`didCompleteWithError`（`:444`）存 `NSError.code`，`resetState` 清空。
- OpenAI `:1055-1063`、Anthropic `:1752-1760` 流内 error：把这一片的原始 JSON 存进 `streamErrorBody`。
- 新增 `var hasEmittedOutput: Bool`（基类 = `!streamingContent.isEmpty || receivedDone`；OpenAI 再加 `!reasoning.isEmpty || !toolCallAccum.isEmpty`；Anthropic 再加 `blockAccum` 里有 text / thinking / tool_use 内容）——**思考也算已输出**（Q11）。router `:2140` 的 `noOutput` 改读它（400 自愈那一支随之变严：思考了一半断掉的不再走参数重发——那种情况状态码本来就是 200，实际不受影响）。

### 7.4 重试规则（Q3 已拍 + Q7 细节）

在 `adaptiveFailed` 里、参数自愈两支之后、`requestFailed` 之前加一支：

```
kind = ChatErrorClassifier.classify(...)
guard !chatProvider.hasEmittedOutput, transientRetry < 2 else → 走原失败出口
.transient        → 等 [1s, 3s][transientRetry]
.rateLimited(ra)  → ra ≤ 8s 就等 ra（再加 0–0.5s 抖动），ra > 8s 不重试；没有 ra → [2s, 4s]
.connectionLost   → 只在 transientRetry == 0 时等 1s 重试一次（Q6）
其余               → 不重试
```

- `sendStreaming` 加参数 `transientRetry: Int = 0`（放在 `attempt:` 后）。重试时 `attempt` 原样传，参数自愈那两支重发时 `transientRetry` 原样传——两个计数互不重置，最坏 1 次参数重发 + 2 次服务器重试。`lastParamAdaptation` 只在两个都是 0 时清（`:1941`）。
- 被拒那次：账本照记 `.error`，`settlement.budgetWaived = true`（5xx / 429 不计费，同 #094 400 那支的做法，`:2160-2161`）。
- 等待：`DispatchWorkItem` 存在 router 的 `pendingRetry`，`cancel()`（`:2465`）里先 `pendingRetry?.cancel()`；等待期间 `isStreaming`（`:1861`）要算上 `pendingRetry != nil`，否则停止按钮 / `cancelAssistantTurn` 的 `isStreaming` 判断（VM `:2251`）会以为已经结束。
- 测试可注入：router 加 `@ObservationIgnored var retryDelay: (TimeInterval) -> TimeInterval = { $0 }`，单测换成 `{ _ in 0 }`。
- 只管 OpenAI 兼容 / Anthropic（走 `adaptiveFailed` 的两家）。ChatGPT 登录 / 本机 / CC 不在本单（§8）。
- 后台 `sendNonStreaming`（记忆写手 / 摘要 / 标题）不重试（§8）。

### 7.5 用户看到的（中文、说人话）

**重试中的小胶囊**：`ProviderRouter.sendStreaming` 加 `onRetry: ((String) -> Void)? = nil`；VM `runStreamingTurn`（`:3964`）传 `{ self.transientNotice = TransientNotice($0) }`（现有淡出胶囊，`ConversationViewModel.swift:7-14`，不新做 UI）。

| 情况 | 胶囊 |
|---|---|
| 5xx / 529 | ⏳ 服务器有点忙，1 秒后自动重试（1/2） |
| 429 | ⏳ 请求太频繁被限流了，3 秒后自动重试（1/2） |
| 连接断开 | ⏳ 连接断了，马上重试一次 |

**最终失败**（`failureMessage` `:2343` 按 kind 在原文前加一句；尾巴「（host · 模型 · HTTP n）」照旧）：

| kind | 前缀 | 去改（FixJump） |
|---|---|---|
| transient（重试过） | 服务器暂时出问题，已自动重试 2 次还是不行，过一会儿再发 | 无 |
| rateLimited（等太久 / 重试完） | 被限流了，大约 N 秒后再发（没有 N 就「过一会儿再发」） | 无 |
| quota | 这张卡的额度用完了或余额不足，充值或换一张卡 | 新 `.quota`「去看」→ 那张卡的编辑页（同 badKey 的找卡逻辑 `FixJump.swift:79-92`） |
| contextTooLong | 对话太长了，超过这个模型一次能读的长度。把预设里的「上下文条数」调小，或先压缩一下上下文 | 新 `.contextTooLong`「去改」→ 预设上下文条数那一行（Q8） |
| contentFiltered | 这条内容被服务商的安全过滤拦下了 | 无 |

- 识别常量放 `FixJump`（`:15-26` 那组），生成方和识别方共用；`kind(for:)`（`:43-55`）按「401/403 → 404 → … → quota → contextTooLong」顺序加两条，放在 `.learned` 之前。`.quota` 的人话里不能含 `HTTP 401）` 那类串（防被 badKey 先认走）。
- 文案里不出现人设名；若以后要提「对方」，用楼层 `assistantName` 变量。

### 7.6 衔接 / 风险

- 和 400 自愈的关系：400 / 422 先过 `ParamErrorClassifier`（学参数 / 降上限 / 思考块），认不出再进 `ChatErrorClassifier`（超长 / 过滤 / 额度说人话）。超长的 400 原来走「原文 + 尾巴」，现在多一句人话——会被 `FixJump` 认成 `.contextTooLong`。
- R8 降上限（`OutputTokenCap.mentionsOutputLimit`）和超长互斥：超长判定排除了提到输出上限键名的正文。
- 预算：每次重试都重新过 `BudgetPreflight`（`startRequest` `:287`）；失败那次扣 0。
- `RequestUsageSettlement` 每次 `sendStreaming` 新建一个，重试不会串账。
- 回归风险：`hasEmittedOutput` 换掉 `noOutput` 影响 400 自愈判定（见 7.3）；`isStreaming` 多一个条件影响停止按钮，要单测 cancel-during-backoff。

### 7.7 测试

- `ChatErrorClassifierTests`（样本放 `Fixtures/chat-errors/`，资料还原的标注「未实测」，T9 拿到原文后替换）：
  - OpenAI 429 `rate_limit_exceeded` + `retry-after: 3` → `.rateLimited(3)`；429 `insufficient_quota` → `.quota`；DeepSeek 402 `Insufficient Balance` → `.quota`；Anthropic 529 `overloaded_error` → `.transient`；Anthropic 流内 `event: error` `overloaded_error`（状态 200）→ `.transient`；OpenAI 500 `server_error` → `.transient`；Kimi 429 `engine_overloaded_error` → `.rateLimited(nil)`；中文「请求过于频繁」429 → `.rateLimited`；「今日额度已用完」429 → `.quota`。
  - 超长：OpenAI `context_length_exceeded`、Anthropic `prompt is too long: 210000 tokens > 200000 maximum`、Kimi、DashScope、中文；**反例**：「max_tokens is too large」不是超长、「Too many tokens, please wait」是限流不是超长。
  - 过滤：Azure `content_filter`、OpenAI `content_policy_violation`。
  - `retryAfter`：秒数、HTTP 日期、`retry-after-ms`、乱写 → nil。
- Router（假服务器 `OutputTokenCapTests.ScriptedHTTPServer`，测试侧给它加可选响应头）：
  - 503 → 503 → 200：成功，共 3 次请求，账本 `[.error, .error, .ok]`，前两条扣 0，胶囊回调 2 次。
  - 503 ×3：失败，人话含「已自动重试 2 次」，共 3 次请求（不第 4 次）。
  - 429 + `Retry-After: 1` → 等（注入的 delay 记到 1）→ 200；`Retry-After: 30` → 不重试、人话「大约 30 秒后再发」。
  - **已输出不重试**：200 SSE 先出两片正文、再流内 `error` overloaded → 不重试，节点保留已出正文 +「⚠️」。思考了一半（只有 reasoning / thinking delta）再断 → 也不重试。
  - Anthropic SSE `message_start` 后直接 `overloaded_error` → 重试。
  - 400 参数自愈 → 503 → 200：`attempt` 和 `transientRetry` 各用一次，最终成功、学到的参数照记。
  - 等待中 `cancel()` → 不再发请求、不再回调，`isStreaming` 在等待期间为 true、cancel 后 false。
  - 401 / 404 / 400 预填：行为和改前一致（不重试，人话不变）。
- `FixJumpTests`：新两类认得出、不抢 badKey / badURL。

---

## 8. 不做 / 留 P1

| 项 | 为什么不在本单 |
|---|---|
| SSE 空行派发 + 多行 `data:` 拼接 | 没有证据有厂商这么发；改派发时机风险大于收益 |
| 流式中实时显示思考（OpenAI / Anthropic 两路） | UI 活，和本单解析层解耦；Q9 |
| Mistral typed parts（content 数组里的 thinking 块）、Gemini 兼容口 `<thought>` | 预设里没有 Mistral；Gemini 兼容口留 P1 |
| `finish_reason: content_filter` / `refusal` / `pause_turn` / `response.incomplete` 等 stop reason 补全（J） | P1；本单只认报错正文里的过滤 |
| 关思考按方言写（F）：DeepSeek `thinking:{type:disabled}`、Kimi、Qwen、OR `reasoning.enabled:false` | P1；本单不改请求侧思考开关 |
| Kimi「不要设 temperature」「max_tokens ≥ 16000」、K2.6 `thinking.keep` | P1（ParamCompat 血统规则 + 400 自愈先兜着） |
| `ResolvedCompat` 其余 ~10 个开关（maxTokensField 按 host、supportsMultipleSystemMessages、supportsUsageInStreaming、thinkingFormat、reasoningDisableMode、supportsToolChoice、stripImageInput、cacheControlFormat、Mistral 三件套…）、卡上用户覆盖、`APIUsageParser.isOpenRouter` 收拢 | P1 E 正式版 |
| MessageNode 记生成模型（G）、发送前统一整理消息序列（H） | P1；C2 只加段级来源标记，不碰 MessageNode |
| ChatGPT 登录通道的错误分类 / 重试（含 `usage_limit_reached.resets_at`）、后台 `sendNonStreaming` 的重试 | 走的不是 `adaptiveFailed`，各自另做 |
| 超长后自动压缩 / 按 token 裁历史（K） | P2，要动开窗逻辑 |
| 多 key 故障转移、换账号重试 | 网关的事 |
| OpenAI `x-ratelimit-reset-*` 头、Anthropic `anthropic-ratelimit-*-reset` 头 | 只读 `Retry-After` 先够用 |
| EOF 没有 `[DONE]` 但累积了工具调用（现在当普通完成，工具调用丢） | 属 J；A 只保证末行不丢 |

---

## 9. 待粟粟批注

> 每题给了推荐；批「都按推荐」即可开工（仍然先等 §1 实测）。

**Q1 `ResolvedCompat` 的形态**
- A（推荐）：组合——新 struct 里放 `params: ParamCompat` + host / 方言开关。`ParamCompat`、`ParamAdaptStore`、分类器、设置页、测试连接一行不动；builder 参数从 `ParamCompat` 换成 `ResolvedCompat`。
- B：把 `ParamCompat` 整个改名成 `ResolvedCompat` 再加字段（~100 处引用、15 个文件机械改名，一个独立提交）。

<⧫>  </⧫>

**Q2 OpenRouter 判定统一**：现在 4 处写法不一样（§3.1）。推荐统一成「host 以 `openrouter.ai` 结尾」；代价是路径里含 `openrouter` 的自建代理不再挂 OR 缓存标 / 不再走 deepseek 优先路由。另一个选择：骨架里保留各自原判定（零行为变化，但「集中」只集中了位置没集中规则）。

<⧫>  </⧫>

**Q3 正文里的 `<think>` 拆不拆**：推荐只拆「回复开头就是 `<think>`、且这次没收到原生思考字段」的情况。开关 `splitsLeadingThinkTag` 对哪些端点开：推荐所有 OpenAI 兼容卡都开（只认开头，误伤面很小）；保守选项是默认全关、等撞上再按 host 开。

<⧫>  </⧫>

**Q4 阶段 3b（历史回合回传）做不做**：DeepSeek 文档说带 tools 时历史回合都要回传、否则 400（§1.1）。推荐：实测 T3 / T4 证实会 400 就做 3b（要给思考段加一个来源 key，老版本兼容）；不 400 就不做、列 P1。

<⧫>  </⧫>

**Q5 历史里不是同一个模型生成的 assistant，对 DeepSeek 怎么发**：推荐等 T5 实测；实测前的默认写 `reasoning_content: ""`（omp 的兜底），不把别家的思考文字塞进去。

<⧫>  </⧫>

**Q6 网络错误（没有 HTTP 状态码）重试不重试**：推荐只重试「连接中途断开」一次（且没出字）；超时、没网不重试，直接说人话（超时重试会让她等两倍）。

<⧫>  </⧫>

**Q7 重试次数和间隔**：推荐 5xx / 529 / 408 最多 2 次（等 1 秒、3 秒）；429 最多 2 次，有 `Retry-After` 且 ≤ 8 秒就照它等，> 8 秒不等直接说「大约 N 秒后再发」，没有就等 2 秒、4 秒。

<⧫>  </⧫>

**Q8 上下文超长的「去改」跳哪**：推荐跳预设「上下文条数」那一行；不自动压缩（那是 P2 K）。另一个选择：按钮直接触发现有的「压缩上下文」（`manualCompressContext`）。

<⧫>  </⧫>

**Q9 OpenAI 兼容路的思考流式时要不要实时显示**：推荐本单不做，和 Claude 现在一样回复完才出现在「思考过程」里；实时显示两路一起做，列 P1。

<⧫>  </⧫>

**Q10 重试胶囊用哪种**：推荐用现有淡出胶囊（`TransientNotice`），每次重试出一条；不做常驻状态条。

<⧫>  </⧫>

**Q11「已开始输出」算不算思考**：推荐算——模型已经开始想（DeepSeek / Claude 的思考 delta）就不自动重试，免得重复计费、她也看不到发生了什么。

<⧫>  </⧫>

**Q12 tool_calls 那条 assistant 的 `content` 要不要填 `"."`**：omp 说 Kimi / 直连 DeepSeek 推理要非空。推荐开关进骨架、默认全关，等 T7 实测证明会 400 再对那家开。

<⧫>  </⧫>

**Q13 回传与否也走「报错自学」**：推荐做——DeepSeek 式「must be passed back」学会回传、Mistral 式「不认这个字段」学会不回传，都记进现有的「自动适配」表，设置里能看能清。

<⧫>  </⧫>

---

## 10. 验证方式

- 工位暂停本地编译（MEMORY）：执行者在工位里只跑定向单测，**以 `xcodebuild test` / `build-for-testing` 的标记为准**——mac 用 `MemoryPalaceTests` scheme（模块名 `记忆花园`），定向测试要 grep 到目标类的 `Test Suite '…' passed`；iOS 用 `MemoryPalaceIOS` scheme + iOS 26 模拟器（`-destination 'platform=iOS Simulator,id=…'`，不写 generic），只认 `** TEST SUCCEEDED **` / `** TEST BUILD SUCCEEDED **`，不认退出码。
- 正式编译由合并管家（Warden）在集成区按平台做。
- 每阶段必跑的回归套件：`PromptRealPathGoldenTests`（金样不重录）、`InspectorRealPathTests`、`ProviderOrderingTests`、`ParamCompatTests`、`ParamErrorClassifierTests`、`ParamAutoAdaptRouterTests`、`ThinkingStreamTests`、`ThinkingSegmentTests`、`ThinkingReplayTests`、`NonStreamParseTests`、`ToolReplayTests`、`FixJumpTests`、`BudgetGateTests`（单跑）。
- 真请求：只有车头按 §1.2 打；执行者不发。
- 每阶段收尾：astra + kimi 各审一轮（MEMORY「每个节点各审一轮就收口」）；写 `review-model-compat-p0-阶段N.md`；说明书 `manual/facts/model/model-api.md` 补事实（思考显示、自动重试、新报错人话）。

---

## 11. 执行清单

### 阶段 0 · 实测（车头）
- [ ] T1–T5 DeepSeek（记下模型 id、是否 400、原文字节）
- [ ] T6–T7 Kimi
- [ ] T8 OpenRouter Claude 思考 + 工具
- [ ] T9 收集 5xx / 429 原文 + 响应头
- [ ] 结论回填 §1.2，原文存 `Fixtures/chat-errors/`、`Fixtures/param-errors/`
- [ ] 按结论定 Q4 / Q5 / Q12，更新本 plan

### 阶段 1 · A SSE 解码器
- [x] 新建 `Services/SSELineDecoder.swift`（feed / finish / reset / parse）
- [x] `SSELineDecoderTests`：行尾三种 + `\r` 跨片 + 注释 + 无空格 + 两个空格 + 无冒号 + finish + 32 MB 上限
- [x] `BaseChatProvider`：`buffer` → `sseDecoder`；`errorBytes` + `errorBody` 计算属性；`resetState` 清空
- [x] OpenAI `processData` 改用解码器
- [x] Anthropic `processData` 改用解码器
- [x] OAuth `processData` / `handleEvent` 改用解码器，非 200 进 `errorBytes`
- [x] `didCompleteWithError` 流结束 `finish()` 分发末行
- [x] 嗅探 `:426` 改有损解码
- [x] 逐字节切两片的等价测试（OpenAI / Anthropic）
- [x] CRLF 版 `toolTurnSSE` 测试
- [x] OAuth 跨片中文 + 非 200 原文测试
- [x] 回归套件全过（mac test；iOS build-for-testing 交集成区）
- [x] review 文档 + astra / kimi 审 + 提交 + `docs/now/backend-3.md`（`b3ab3c9ac` + 审查修 `30a64992e`；复盘合成一份 [review-model-compat-p0.md](review-model-compat-p0.md)；只跑了 astra，kimi 未审）

### 阶段 2 · E 骨架
- [x] 改前：把 4 个旧函数在一组输入上的结果抄成等价表测试
- [x] 新建 `ResolvedCompat` + `KnownHost`（Q1 / Q2 按批注）
- [x] `ParamCompat.resolve` 内部改读 `KnownHost`，删 `isOfficialOpenAI`
- [x] `ReasoningEffort.route` 的 openaiCompatible 分支改读 `KnownHost`
- [x] OpenAI provider `sendStreaming` 一次 resolve，builder 参数合并成 `compat: ResolvedCompat`
- [x] Anthropic provider 同上（只换类型，读 `params`）
- [x] `previewRequestBody` / `previewSystemPlacementNote` 改读 `ResolvedCompat`
- [x] 删 `wantsORCacheControl` / `orPreferredProviderOrder` / `supportsInterleavedSystem`，测试调用点改读字段
- [x] B / C 开关占位（默认 = 现行为）
- [x] `ResolvedCompatTests`（host 词表、等价表、换一家不受影响、Q2 行为变化锁定）
- [x] 金样 G1–G8 不重录、全过；回归套件全过
- [x] review + 审 + 提交（`27f3b1d4f` + 审查修 `4518ab999`；astra 审，kimi 未审）

### 阶段 3 · B + C1
- [x] `ReasoningCapture` 类型
- [x] `parseOpenAIChunk`：三个文字字段 + `reasoning_details` 合并 + 空串不算
- [x] `<think>` 开头拆分（按 Q3）
- [x] `parseNonStreamBody` + `NonStreamResult.reasoning`
- [x] router `lastReasoning` / `lastThinkingSegments`（序号守卫）
- [x] VM 3 个读点换 `lastThinkingSegments`；`replySegments` 加 `reasoning:`
- [x] `OpenAIReasoningStreamTests` + VM 段形状测试
- [x] `ToolTurn.reasoning`；`results` 改 `var`，3 个重建点改成拷贝改字段；`PendingUserQuestion.reasoning`
- [x] `droppingThinking()` 保留 reasoning
- [x] builder `:809-820` 按字段名回传 + `requiresAssistantContentForToolCalls`（默认关）
- [x] `ResolvedCompat.resolve` 填 C1 默认表（deepseek / moonshot / openrouter）
- [x] `ParamErrorClassifier`：`must be passed back` → require；`loc … reasoning_content` → drop；`SentShape.sentReasoningReplay`
- [x] `ParamAdaptStore.Learned` 两个新组 + `summary` 文案 + 设置页 / 调试表显示
- [x] `toolTurnsEstimateText` 拼进 reasoning 文字
- [x] C1 测试（夹具、字段名、开关、学习、预算收尾；恢复提问卡只是透传一个字段，没写单测——VM 构造太重）
- [x] 回归套件全过；金样不变
- [x] 说明书事实：OpenAI 兼容模型的思考进「思考过程」
- [x] review + 审 + 提交（`959b23703` + 审查修 `90f081b84`；astra 审，kimi 未审）

### 阶段 3b · C2（Q4 批了且实测证实才做）
- [ ] `MessageSegment.thinking` 加 `source`；~8 处模式匹配补位；老版本解码测试
- [ ] B 写段时填 `source`
- [ ] `ToolReplayRound.reasoning` + `rounds` 挂思考；`PromptMessage.reasoning` + 组装层按节点挂
- [ ] `openAIWire` 按 `requiresReasoningContentForAllAssistantTurns` 写历史（同模型原文、跨模型按 Q5）
- [ ] 开关默认：DeepSeek 带 tools 时、Kimi K3
- [ ] 测试（挂对节点、同 / 跨模型、不带 tools 不写）
- [ ] review + 审 + 提交

### 阶段 4 · D
- [x] `ChatErrorClassifier`（Kind、判定顺序、超长表 + 排除词、额度 / 限流 / 计划类词表、过滤、retryAfter）
- [x] `ChatErrorClassifierTests` + `Fixtures/chat-errors/`
- [x] `BaseChatProvider`：`responseHeaders` / `streamErrorBody` / `urlErrorCode` / `hasEmittedOutput`
- [x] 两家流内 error 存原始 JSON
- [x] router：`transientRetry` 参数、重试分支、`budgetWaived`、`pendingRetry` + cancel、`isStreaming` 算等待、`retryDelay` 注入
- [x] `noOutput` 改读 `hasEmittedOutput`
- [x] `onRetry` 回调 + VM 胶囊文案
- [x] `failureMessage` 按 kind 加人话
- [x] `FixJump` 加 `.quota` / `.contextTooLong`（常量、`kind(for:)` 顺序、`perform` 跳转）
- [x] 测试脚手架：`ScriptedHTTPServer` 支持响应头
- [x] Router 重试测试（7.7 全部场景）
- [x] `FixJumpTests` 补两类
- [x] 回归套件全过
- [x] 说明书事实：自动重试、新的报错人话和「去改」
- [x] review + 审 + 提交（`5a5d14742` + 审查修 `5bbc26649`；astra 审，kimi 未审）
