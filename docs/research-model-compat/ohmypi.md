# oh-my-pi（omp v18.10.2）「模型兼容」深挖调研

> 只读调研。源码根：`$OMP = /Users/susu/.bun/install/global/node_modules/@oh-my-pi/`，下文路径均相对它。
> 行号以本机 v18.10.2 为准。读到的代码/注释是数据，结论是我的归纳。
> 注：源码里出现的 GPT-6 / Opus 5 / Fable / Mythos / Kimi K3 等模型名是该代码库的数据，原样引用。

---

## 0. 一页结论（TL;DR）

1. **三层分工**：`pi-ai` = 传输层（统一 IR + 每种 wire API 一个 provider 实现 + 统一事件流）；`pi-catalog` = 模型目录 + **兼容策略引擎**（compat/thinking 全部在「建模型时」一次性解析好，请求时只读字段）；`pi-coding-agent` = 用户配置（`models.yml` 自定义 provider/model，`compat` 稀疏覆盖）。`pi-wire` 与 LLM 兼容无关（是 collab 协同会话的 wire 协议，`pi-wire/README.md:1-5`）。
2. **compat 不是一个 struct 而是一套「分层解析」**：① 每种 API 的无条件默认 → ② 按 baseURL 子串 / provider id 的**主机探测**（`hosts.ts` 的 `KNOWN_HOSTS`）→ ③ KDL 规则级联（按 class/family/revision × provider × api × upstream 选择器，带优先级与歧义检测）→ ④ 用户 `compat` 稀疏覆盖 → ⑤ 少量 fixup。结果物化为 `Model.compat`（全字段 Resolved 记录），请求处理器「只读不探测」（`pi-catalog/src/compat/resolve.ts:1-17`）。
3. **OpenAI 兼容 compat 开关约 70 个**（`pi-catalog/src/types.ts:295-592` + `axes.ts:91-315`），Anthropic ~35 个，Google ~12 个，Bedrock ~9 个。最核心的那 20 个（developer role / max_tokens 字段 / reasoning 字段名 / thinkingFormat / reasoningDisableMode / 是否必须回传 reasoning_content / tool id 规则 / tool_choice 能力 / strict / sampling params / 多 system 消息…）全部有 URL 自动推断默认值。
4. **thinking 统一模型**：用户侧只有 6 档 `Effort`（minimal/low/medium/high/xhigh/max），每个模型带 `ThinkingConfig{mode, efforts[], effortMap, effortBudgets, requiresEffort, suppressWhenOff…}`，`mode` 五选一：`effort | budget | google-level | anthropic-adaptive | anthropic-budget-effort`。请求时 clamp → map → 按 wire 方言编码；「关思考」也按方言编码（10 种 `reasoningDisableMode`）。
5. **跨 provider handoff 的核心在 `transformMessages`**（`pi-ai/src/providers/transform-messages.ts:756-1468`），每个 provider 的 convertMessages 都先过它：同模型保留签名原样回放；跨模型时 thinking **默认降级为文本**（用目标模型自己的 thinking 方言包裹，Claude 例外用裸文本），签名剥离；只有「目标能读外来未签名 thinking」或「同一权重的另一个 host（portable-reasoning）」才原生保留；tool call id 归一化 + 去重（`_dupN`）；孤儿 tool_call 补 `"No result provided"`/`"aborted"`；孤儿 tool_result 删掉或转成 `<stale-tool-result>` user 文本。
6. **元数据来源**：bundled `models.json`（77 provider / 5697 行，12MB）由生成脚本从 stencil.so（models.dev 风格的目录服务）+ 各 provider 的 discovery（`/v1/models` 等）+ KDL seed 行生成；运行时 `static → cache → stencil/models.dev → provider discovery` 逐层覆盖；未知自定义模型按 id 去 bundled 索引找「参照模型」继承价格/窗口/compat。
7. **usage 归一化**：`input` 永远是「不含缓存的新输入」，`cacheRead`/`cacheWrite` 分开，`output` 含 reasoning（`reasoningTokens` 是其子集）；OpenAI 系 `prompt_tokens - cached - cacheWrite`，DeepSeek 的 hit/miss 特判，Gemini `prompt - cached`，Anthropic 原生三桶 + 5m/1h TTL 拆分；OpenRouter 用服务端回报的 `cost` 按比例缩放本地估算。
8. **错误分类**：位标志 `errorId`，`ContextOverflow` 由 ~25 条各家措辞正则 + 「usage 证明输入 > 窗口」双路判定（`pi-ai/src/error/flags.ts:90-117, 1010-1022`）。

---

## 1. pi-ai 架构：统一 IR、按 API 分的 provider、统一事件流

### 1.1 统一中间表示（IR）
文件：`pi-ai/src/types.ts`

| 类型 | 定义位置 | 要点 |
|---|---|---|
| `Context` | `types.ts:1628-1634` | `{ systemPrompt?: string[]; messages: Message[]; tools?: Tool[]; inactiveTools? }` —— system 是**有序数组**（为了 KV cache 前缀稳定，见 §4.6） |
| `Message` | `types.ts:1351` | `UserMessage | DeveloperMessage | AssistantMessage | ToolResultMessage` 四种 role |
| `UserMessage` | `types.ts:1171-1187` | `content: string | (Text|Image)[]`，`synthetic` / `steering` / `historyRewriteAt` / `providerPayload` |
| `DeveloperMessage` | `types.ts:1189-1201` | 独立 role，是否映射为 `developer` 由 compat 决定（§4） |
| `AssistantMessage` | `types.ts:1245-1327` | content 块联合；**带 `api`/`provider`/`model` 出处三元组**（跨模型判定的依据）；`upstreamModel`（路由器实际服务模型，可从 Anthropic 签名反推）；`usage`、`stopReason`、`errorId`、`errorStatus`、`providerPayload`（provider 原生历史快照） |
| `ToolResultMessage` | `types.ts:1329-1349` | `toolCallId`、`toolName`、`content: (Text|Image)[]`、`isError` —— 工具结果是**独立消息**而不是 user 内容块 |
| `TextContent` | `types.ts:874-878` | `textSignature?`（Responses message id / Gemini text 签名） |
| `ThinkingContent` | `types.ts:880-896` | `thinking`、`thinkingSignature?`（含义因 API 而异，见 §3.1）、`itemId?`、**`summary?: boolean`**（true=厂商写的摘要；false=原始推理；只有 false 才可跨 host 原生回放） |
| `RedactedThinkingContent` | `types.ts:898-901` | Anthropic `redacted_thinking` 的 `data` |
| `ImageContent` | `types.ts:948-970` | base64 + mimeType；`detail`（OpenAI 专用）；`providerFile`；`url` 镜像 |
| `ToolCall` | `types.ts:1016-1039` | `id/name/arguments(object)`；`thoughtSignature?`（Gemini）；`customWireName`（OpenAI custom tool） |
| `StopReason` | `types.ts:1041` | 仅 5 种：`stop | length | toolUse | error | aborted` |
| `Tool` | `types.ts:1590-1626` | `name/description/parameters(JSON Schema)/strict?` + 少量厂商扩展 |
| `Usage` | `pi-catalog/src/types.ts:201-266` | 见 §6.1 |

### 1.2 按 API 类型分的 provider
- API 枚举：`pi-catalog/src/types.ts:9-26`（`KnownApi`：openai-completions / openai-responses / openrouter / openai-codex-responses / azure-openai-responses / anthropic-messages / bedrock-converse-stream / google-generative-ai / google-gemini-cli / google-vertex / ollama-chat / cursor-agent / factory-droid-agent / gitlab-duo-agent / devin-agent / apple-foundation-models），`Api = KnownApi | string`（可扩展）。
- **关键设计：`provider` ≠ `api`**。provider 是「谁家的 key/endpoint」（openrouter、deepseek、我自定义的 foo），api 是「说哪种 wire 协议」。一个 provider 下不同模型可走不同 api（例如 Cloudflare AI Gateway 按前缀路由 `anthropic/`→anthropic-messages，`openai/`→openai-completions：`compat/rules/README.md:304-307`）。
- 分发：`pi-ai/src/stream.ts:918-1000`（`streamDispatch`）—— 先查自定义 API 注册表（`api-registry.ts:19-80`，扩展可注册新 api 名），再按 `model.api` switch 到 `streamOpenAICompletions` / `streamOpenAIResponses` / `streamAnthropic` / `streamGoogle*` / `streamBedrock`…；`openrouter` 默认走 Responses API（`stream.ts:991-997`，`PI_OPENROUTER_RESPONSES=0` 退回 chat completions）。
- `streamSimple` 把通用选项（`reasoning: Effort`、`toolChoice`、`maxTokens`…）经 `mapOptionsForApi`（`stream.ts:1814-2350`）翻译成每个 API 的专用 options（如 anthropic 的 `thinkingEnabled/thinkingBudgetTokens/effort`）。

主要 provider 文件规模（行数）：`openai-completions.ts` 2930、`openai-responses.ts` 1939、`openai-shared.ts` 4372（chat 与 responses 共享的策略/编码）、`anthropic.ts` 6910、`google-shared.ts` 1183、`amazon-bedrock.ts` 1428、`transform-messages.ts` 1468。

### 1.3 统一流事件
`pi-ai/src/types.ts:1636-1659`：
```
start | text_start/text_delta/text_end | thinking_start/thinking_delta/thinking_end
| image_end | toolcall_start/toolcall_delta/toolcall_end(toolCall)
| done(reason: stop|length|toolUse, message) | error(reason: aborted|error, error: AssistantMessage)
```
每个事件带 `contentIndex` 和**完整 partial AssistantMessage**（UI 可随时渲染当前快照）。error 也是一个 AssistantMessage（带 `errorMessage/errorStatus/errorId`），所以失败的回合可以原样进历史，再由 transformMessages 处理（§4）。

外加一层「泄漏思考修复」包装：非官方端点的流一律过 `wrapLeakedThinkingStream`（把 content 里漏出来的 `<think>…</think>` 拆回 thinking 块），官方 Anthropic/OpenAI/Codex 豁免（`stream.ts:102-159`）。chat-completions 还有更细的 `streamMarkupHealingPattern`（kimi/dsml/qwen/thinking/harmony：把漏到正文的 chat-template 工具调用/思考标记修复成结构化事件，`utils/stream-markup-healing.ts:1-40`；默认值规则见 §2.4 `detectStreamMarkupHealing`）。

---

## 2. 兼容层建模（compat）

### 2.1 解析流水线（最值得抄的骨架）
`pi-catalog/src/compat/resolve.ts:1-17` 文件头注释写明了层次，`resolveModelPolicy`（`resolve.ts:1319-1360`）是唯一入口：

```
spec(ModelSpec: id, provider, api, baseUrl, reasoning, compat?(稀疏), thinking?)
  └─ identity = classifyModel(provider, id)          // class/family/revision，见 §5.3
  └─ axes = resolveCascade(target)                    // KDL 规则级联
  └─ compat = per-API:
        detect*Compat(spec)        // 层1+2：无条件默认 + URL/provider 主机探测
        applyWireAxes(compat, axes.wire, api)   // 层3：规则
        applyCompatOverrides(compat, spec.compat) // 层4：用户稀疏覆盖（只覆盖已存在的 key）
        overlayEffortMapAxis / fixup*            // 层5：依赖前面结果的派生值
  └─ thinking = resolveThinkingPolicy(...)  // 见 §3.3
  └─ catalog = axes.catalog                  // 价格/窗口修正等，buildModel 应用
```
- `applyCompatOverrides` 只写入 resolved 记录里**已有的 key**，未知 key 忽略（`compat/apply.ts:7-15`）——所以 resolved 记录里很多字段刻意写成 `undefined` 占位，好让用户能覆盖（例：`resolve.ts:919-927`）。
- `buildModel`（`pi-catalog/src/build.ts:348-373`）调用 resolveModelPolicy 并把 `compat`、`thinking`、`identity` 物化到 `Model`；`compatConfig` 保留用户原始稀疏值仅供查看（`types.ts:1705-1710`）。
- 请求期 handler 只读 `model.compat.*`（`types.ts:1704-1708` 注释：“Protocol handlers read fields; they never detect, resolve, or allocate”）。

### 2.2 主机探测词表（URL 子串 + provider id）
`pi-catalog/src/hosts.ts:26-75` `KNOWN_HOSTS`：每类主机 = `providers[]`（provider id 命中即算）+ `urlMarkers[]`（baseURL **大小写不敏感子串**，故意不解析 hostname——代理常把上游主机名放在 path 里，`hosts.ts:6-11`）。

| host key | provider ids | URL 子串 |
|---|---|---|
| openai | openai | `api.openai.com` |
| openaiCodex | （仅 URL） | `chatgpt.com/backend-api` |
| azureOpenAI | azure | `.openai.azure.com`, `azure.com/openai`, `models.inference.ai.azure.com` |
| openrouter | openrouter | `openrouter.ai` |
| vercelAIGateway | vercel-ai-gateway | `ai-gateway.vercel.sh` |
| githubCopilot | github-copilot | `githubcopilot.com`, `copilot-api.` |
| anthropic | anthropic | `api.anthropic.com` |
| deepseekDirect / deepseekFamily | deepseek | `api.deepseek.com` / `deepseek.com` |
| cerebras / groq / together / mistral / xai | 同名 | `cerebras.ai` / `api.groq.com` / `api.together.xyz` / `mistral.ai` / `api.x.ai` |
| zai / zhipu | zai / zhipu-coding-plan | `api.z.ai` / `open.bigmodel.cn` |
| alibabaDashscope | alibaba-*-plan | `dashscope`, `token-plan.` |
| moonshotNative | moonshot, kimi-code | `api.moonshot.ai`, `api.kimi.com` |
| minimax | minimax* | `api.minimax.io`, `api.minimaxi.com` |
| xiaomi | xiaomi, `xiaomi-token-plan-*` 前缀 | `xiaomimimo.com` |
| fireworks | （仅 URL，provider 按模型路由） | `fireworks.ai` |
| googleAistudio | — | `generativelanguage.googleapis.com`（OpenAI 兼容 shim，拒 `store`） |
| nvidia / venice / qwenPortal / opencode / zenmux / kilo / umans / baseten / chutes | … | … |

**唯一严格匹配**：Anthropic 官方端点判定（关系到 OAuth 凭据是否附加）要求精确 origin 或 `https://api.anthropic.com/` 前缀，防 `api.anthropic.com.evil.com`（`compat/anthropic.ts:19-23`）。签名代理（会校验 thinking signature 的非官方端点）：Copilot、ZenMux、Cloudflare AI Gateway `/anthropic`、Vertex `publishers/anthropic`、Bedrock `/anthropic`、Azure Foundry（`compat/anthropic.ts:57-68`）。
**本地后端**：provider id ∈ {llama.cpp, lm-studio, vllm, ollama} 或 baseURL 是 loopback / 10.x / 192.168.x / 172.16-31.x / `*.local`（`resolve.ts:252-281`），litellm 显式排除（代理）。

### 2.3 OpenAI 兼容（chat completions）开关全表 + 默认值推断
定义：`pi-catalog/src/types.ts:295-592`（每个字段有注释与默认说明）；规则词表：`compat/axes.ts:120-227`；默认推断：`resolve.ts:378-601`（`detectOpenAICompat`）+ fixup `resolve.ts:624-681`。下表「默认」列就是 `detectOpenAICompat` 的返回值（再被 KDL 规则/用户覆盖）。

**消息/角色**
| 字段 | 作用 | 默认推断（resolve.ts 行） |
|---|---|---|
| `supportsDeveloperRole` | system/developer 角色用 `developer` | 仅 OpenAI 官方 host 或 Azure（503）；且只在 `model.reasoning` 时才真用 developer（`openai-completions.ts:2360`）。不支持时 `developer` 消息降级为 `user`（`:2394-2396`）|
| `supportsMultipleSystemMessages` | 多条前置 system 是否允许 | OpenAI/Azure/OpenRouter/Cerebras/Together/Fireworks/Groq/DeepSeek/Mistral/xAI/Z.ai/Copilot/ZenMux = true；MiniMax/DashScope/QwenPortal/任何 Qwen 模型 = false；**未知 host 默认 false**（440-458）。false 时用 `\n\n` 合并成一条（`openai-completions.ts:2368-2374`）|
| `requiresAssistantAfterToolResult` | tool 结果后紧跟 user 时插一条 assistant | Mistral（525）；插入文本 `"I have processed the tool results."`（`openai-completions.ts:2383-2392`）|
| `requiresToolResultName` | tool 消息带 `name` | Mistral（524）|
| `requiresMistralToolIds` | tool call id 归一为 9 位字母数字 | Mistral（527）；实现：去非字母数字，不足补 `ABCDEFGHI`，超出截断（`openai-completions.ts:346-359`）|
| `usesOpenAIToolCallIdLimit` | id 截到 40 字符 | false（589），规则开启 |
| `requiresAssistantContentForToolCalls` | 带 tool_calls 的 assistant 必须非空 content | Kimi 模型、直连 DeepSeek 推理（556）；填 `"."`（`openai-completions.ts:2699-2701`）|

**token/采样参数**
| 字段 | 默认 |
|---|---|
| `maxTokensField` | `max_tokens`：Mistral / Moonshot 原生 / Z.ai / 智谱 / chutes / Fireworks / 直连 DeepSeek；其余 `max_completion_tokens`（428-435, 523）|
| `alwaysSendMaxTokens` | Kimi 模型（Kimi 用 max_tokens 推 TPM，514）|
| `clampOutputToModelMax` | 本地后端（594）；另有通用 64k 上限 `resolveOpenAIOutputTokenParam`（`openai-shared.ts:670-685`）；OpenRouter 上未显式指定 maxTokens 时不发（:677）|
| `supportsSamplingParams` | true（510）；KDL：OpenAI o 系列与 GPT≥5 全 host false（`rules/classes/openai.kdl:3-13`），Claude Opus≥4.7 / Sonnet≥5 等 false（`classes/anthropic.kdl:81-107`）|
| `supportsPenaltyAndStopParams` | xAI 推理模型 false（511）|
| `supportsStore` | 非标准 host（Cerebras/xAI/Mistral/AI Studio/chutes/DeepSeek/Fireworks/DashScope/Z.ai/智谱/Kilo/Qwen/小米/Moonshot/OpenCode）= false，其余 true（411-426, 502）；true 时发 `store:false`（`openai-completions.ts:1992-1994`）|
| `supportsUsageInStreaming` | Cerebras false，其余 true（513）→ `stream_options.include_usage` |

**工具**
| 字段 | 默认 |
|---|---|
| `supportsToolChoice` | 直连 DeepSeek 推理 false（519）|
| `supportsForcedToolChoice` | Kimi K2.7-code 原生 / OpenCode 上的 DeepSeek 推理 / cline-pass Qwen false（520-521）；false 时强制 choice 降为 `auto`（`openai-completions.ts:2084-2089`）|
| `supportsNamedToolChoice` | true；llama.cpp/LM Studio 规则置 false → 降级为 `"required"` 并把 tools 收窄到那一个（`openai-completions.ts:2052-2073`）|
| `disableReasoningOnForcedToolChoice` | Kimi（非 K3）、Claude 模型（515-516）|
| `disableReasoningOnToolChoice` | DeepSeek 推理（非 OpenRouter）（517）；此时冗余的 `tool_choice:"auto"` 会被删掉以保住思考（`openai-shared.ts:958-971`）|
| `disableReasoningWithTools` | false |
| `supportsStrictMode` | OpenAI/Azure/Cerebras/Together/OpenRouter/DeepSeek URL（568-574），未知 host 保守 false |
| `toolStrictMode` | Cerebras `all_strict`，其余 `mixed`（576）|
| `toolSchemaFlavor` | Moonshot 原生或任何 Kimi 模型 → `moonshot-mfjs`；本地后端 → `grammar`（577-582）|
| `rejectRootObjectUnion` / `retryWithoutStrictOnGrammarError` | false，规则开（xAI / OpenRouter-Anthropic）|

**reasoning / thinking**（详见 §3）
| 字段 | 默认 |
|---|---|
| `thinkingFormat` | Kimi(非K3)@Moonshot、Z.ai、智谱、MiMo@小米 → `zai`；OpenRouter → `openrouter`；Qwen@NVIDIA → `qwen-chat-template`；Qwen@Fireworks/Venice → `openai`；DashScope 或任何 Qwen → `qwen`；其余 `openai`（485-499）|
| `reasoningDisableMode` | 由 thinkingFormat 推：openrouter→`openrouter-enabled-false`；zai/kimi→`zai-thinking-disabled`；qwen→`qwen-enable-thinking-false`；qwen-chat-template→`qwen-template-false`；chat-template→`chat-template-thinking-false`；默认 `lowest-effort`（283-301）；cline-pass/Venice/直连 DeepSeek/K2.7 另有特判（fixup 642-652）|
| `supportsReasoningEffort` | xAI false、小米 MiMo false、Z.ai/智谱 仅 GLM≥5.2 true（505）；false ⇒ fixup 自动 `omitReasoningEffort=true`（653-659）|
| `supportsReasoningParams` | GitHub Copilot chat-completions false（509）|
| `reasoningEffortMap` | `{}`，KDL 规则填（例 Kimi K3: minimal→low, medium→high, xhigh→max，`classes/kimi.kdl:40-45`）|
| `reasoningContentField` | `reasoning_content`（cline-pass 为 `reasoning`）（539）|
| `requiresReasoningContentForToolCalls` | Kimi（非 OpenCode）、DeepSeek 推理、MiMo、OpenRouter 推理（541-545）|
| `requiresReasoningContentForAllAssistantTurns` | DeepSeek 推理 / MiMo（非 OpenRouter）（546-547）|
| `allowsSyntheticReasoningContentForToolCalls` | DeepSeek 推理与 MiMo 为 false（会校验精确值），其余 true（548）|
| `syntheticReasoningContentFallback` | 默认 `""`；droid 代理的 DeepSeek 需 `" "`（types.ts:355-361）|
| `replayReasoningContent` | 本地后端 true（为了 llama.cpp KV cache 前缀一致，551；types.ts:362-375）|
| `qwenPreserveThinking` | qwen 方言 + 本地后端（552-553）|
| `requiresThinkingAsText` | Mistral（526）|
| `thinkingKeep` | Kimi K2.6@Moonshot → `"all"`（538）|
| `filterReasoningHistory` | OpenRouter 上的 Claude（537）|
| `includeEncryptedReasoning` | true |
| `reasoningDeltasMayBeCumulative` | false（有的 host 每个 delta 发全量快照，开了就做前缀差分，`openai-completions.ts:1219-1238`）|
| `whenThinking` | 「思考真正开启时」整套 compat 的替代视图（指针切换，不合并）；直连 DeepSeek 推理自动生成 `extraBody.thinking={type:"enabled"}`（661-680）|

**缓存/路由/流**
| 字段 | 默认 |
|---|---|
| `cacheControlFormat:"anthropic"` | OpenRouter 上的 Claude、cline-pass 的 Qwen/Claude（557-560）→ 在最后一个非空 text 部件加 `cache_control: ephemeral`（`openai-completions.ts:2253-2283`）|
| `supportsPromptCacheBreakpoints` | 仅 OpenAI 官方 + GPT≥5.6（437-438）|
| `promptCacheSessionHeader` | xAI → `x-grok-conv-id`（590）|
| `wireModelIdMode` | OpenRouter → `openrouter`，否则 `raw`（480-482）|
| `streamFirstEventTimeoutMs` / `streamIdleTimeoutMs` | 本地后端首事件不超时（0）、idle 300s；GLM≥5 编码套餐 600s；部分推理 host 300s（461-478, 583-584）|
| `stripDeepseekSpecialTokens` | DeepSeek 模型 @ nvidia/deepseek（585）|
| `streamMarkupHealingPattern` | Kimi K2/kimi-code/moonshot→`kimi`；DeepSeek 模型（任何 host）→`dsml`；OpenAI 官方→不修；其余→`thinking`（610-622）|
| `emptyLengthFinishIsContextError` | false，规则对 Ollama 开：`length` 结束且无内容 ⇒ 报上下文溢出（`openai-completions.ts:1731-1738`）|
| `stripImageInput` | false；KDL：DeepSeek class 全 true（除 ocr/vision/v4.1-flash，`classes/deepseek.kdl:69-94`）|
| `extraBody` | 透传到请求体（OpenClaw 风格网关路由 / DeepSeek `thinking`）|
| `openRouterRouting` / `vercelGatewayRouting` | 仅对应 host 生效 |

### 2.4 OpenAI Responses 开关（与 chat 共享的字段 + 专有）
`resolve.ts:699-850`：`supportsDeveloperRole` = Azure/OpenAI URL/Copilot；`strictResponsesPairing` = Azure/Copilot（工具调用与结果必须严格配对）；`supportsImageDetailOriginal` = OpenAI/Azure/Codex；`supportsLongPromptCacheRetention`（`prompt_cache_retention:"24h"`）= OpenAI URL；`supportsReasoningSummary` / `supportsReasoningEffort` / `supportsPenaltyAndStopParams` = 非 xAI；`supportsObfuscationOptOut`、`officialEndpoint`、`statefulResponses`（用 `previous_response_id` 链式）、`supportsConfigurationUpdate`/`supportsSteering`（GPT-6）、`connectionBoundNativeHistory`、`harmonyLeakMitigation`……OpenRouter 的 compat 是 chat 与 responses 两份合并（`resolve.ts:1326-1329`）。

### 2.5 Anthropic Messages 开关
定义 `types.ts:599-800`，默认 `resolve.ts:875-933`：
- `officialEndpoint` / `signingEndpoint`（签名校验端点：官方+Copilot+ZenMux+签名代理 URL）
- `replayUnsignedThinking` = 非签名端点且（模型可推理或 DeepSeek host）——Z.ai/DeepSeek 等兼容端点要原样收回未签名 thinking（`types.ts:713-721`）
- `disableStrictTools` = Azure Foundry 或 Bedrock `/anthropic`；`disableAdaptiveThinking`（Vertex 不认 `adaptive`）；`supportsOutputEffort`（Vertex 拒）
- `supportsEagerToolInputStreaming` / `supportsLongCacheRetention`（1h TTL）= 官方
- `supportsForcedToolChoice` = 非 Kimi 强制思考、非 Fable/Mythos；`supportsSamplingParams`
- `requiresToolResultId`（Z.AI 代理读 `.id`，issue #814）、`requiresThinkingEnabled`（Kimi K2.7-code/K3 @Moonshot）
- `escapeBuiltinToolNames`（网关会把 `web_search` 等名字劫持成服务端工具）
- `maxImageDimension`（默认 8000px）、`maxImagePayloadBytes`（默认 10485760，按 base64 字符串长度算）
- `stripThinkingHistory`、`disabledThinking`（关思考的 wire 形态：omit/disabled/adaptive/between-tools）、`effortBeta`、`fastMode`、`bedrockMessagesApi` 等

### 2.6 Google / Bedrock
- Google（`types.ts:1259-1290`，默认全 false `resolve.ts:968-987`）：`supportsFunctionPartId`、`requiresSkipThoughtSignature`（Gemini 3 无签名 functionCall 需哨兵）、`requiresSkipThoughtSignatureOnFirstFunctionCall`（Cloud Code Assist）、`dropUnsignedThinking`（Antigravity Claude）、`multimodalFunctionResponse`（Gemini 3+）、`ccaLegacyParametersSchema`…
- Bedrock（`types.ts:806-852`，`resolve.ts:936-955`）：`promptCacheMode` none/automatic/explicit、`promptCacheMinimumTokens/MaximumCheckpoints`、推理模型 idle 600s。

### 2.7 KDL 规则级联（厂商特判住在这里）
- 目录：`pi-catalog/src/compat/rules/`：`taxonomy/*.kdl`（模型身份）、`classes/*.kdl`（**模型血统真理**，如“DeepSeek V4 的 effort 梯子是 low/high/max”）、`providers/*.kdl`（**部署契约**，如“deepseek 官方要发 extra-body thinking”）、`runtime/behavior.kdl`、`auth/*.kdl`。README 明确禁止把“统计上常见的 provider 行为”塞进 class 文件（`rules/README.md:5-13`）。
- 选择器：`class` / `provider` / `on "p1" "p2"`（部署 provider）/ `on-api`（请求适配器，自定义 provider 名也能命中）/ `on-upstream`（网关背后实际上游）/ `family` / `revision ">=2.5 <4"` / `models "glob*"`（`README.md:180-199`）。
- 优先级：每个 axis 独立解析，按 `(model 选择器精确度, 约束维度数, priority)` 字典序取最大；完全打平且赋同一 axis ⇒ **编译报歧义错误**，绝不靠文件顺序（`README.md:265-279`）。
- 能力门：thinking 类 axis 只对 `reasoning` 模型生效；「缺失不代表能力被剥夺」（`README.md:281-283`）。
- 词表封闭：`axes.ts:91-532`，每个 directive 声明适用于哪些 compat 记录（openai / openai-responses / anthropic / bedrock / google / devin / request），API→记录映射 `axes.ts:535-547`。
- 例子：
  - DeepSeek：`classes/deepseek.kdl:21-38`（各 family 的 effort 梯子），`:59-68`（deepseek/alibaba 上 `supports-developer-role #false`；deepseek/opencode-go 上 pro 用 `max_tokens` + `reasoning_content` 且 tool call 必带），`:69-94`（class 级 strip-image-input + 视觉变体豁免），`:99-106`（dsml 修复、thinking loop guard、V4 `portable-reasoning`）。
  - DeepSeek 官方 provider：`providers/deepseek.kdl:8-16`（`extra-body { thinking { type "enabled" } }`、`supports-reasoning-effort #true`）。
  - Qwen：`classes/qwen.kdl:18-20`（DashScope 系不支持 developer role）、`:42-58`（LM Studio/vLLM 上 Qwen≥3.8 用模板 `reasoning_effort` 且思考强制）。
  - Kimi：`classes/kimi.kdl:33-46`（K3 默认 max、梯子 low/high/max、强制思考、effort 映射）。
- 自定义 provider 想复用规则：`buildDiscoveredModel(spec, providerType)` 记录后端类型（如自定义名的 llama.cpp），之后 provider 选择器按 `providerType` 匹配（`README.md:201`；`resolve.ts:1274-1288` 用 `providerType ?? provider`）。

### 2.8 「请求期」二次策略（compat 之上的动态降级）
`openai-shared.ts:973-1087` `resolveOpenAICompatPolicy` 每次请求根据 `toolChoice/hasTools/disableReasoning` 计算：思考是否真开（强制 tool_choice、任意 tool_choice、带 tools 三种冲突原因），开启时切到 `whenThinking` 视图，算出 `wireEffort`、`systemRole`、tool id 规则（`mistral-9-alnum | openai-40 | default`）。然后 `applyChatCompletionsCompatPolicy`（`:1123-1252`）按方言写请求体。
还有**会话级粘性降级**（provider session state）：严格工具被拒（grammar too large / structured_outputs not supported）⇒ 去 strict 重试并记住（`openai-shared.ts:555-600, 1360-1418`；CHANGELOG 16.3.10、18.2.9）；Anthropic 签名 400 ⇒ 先降级未签名为文本重试，再不行丢弃 thinking 并 pin 该模式（CHANGELOG pi-ai 18.2.1 L577、16.3.3 L1851）。

---

## 3. 推理 / thinking 兼容

### 3.1 各家 reasoning 字段的解析（入）
| wire | 解析位置 | 存成 IR |
|---|---|---|
| chat completions `delta.reasoning_content` / `reasoning` / `reasoning_text` | `openai-completions.ts:1413-1462`：按此顺序取**第一个非空字段**（避免同一 chunk 多别名重复） | `ThinkingContent{thinking, thinkingSignature: <字段名>, summary:false}`（`openThinkingBlock` `:1135-1150`）——**签名里存的是来源字段名**，回放时用它决定写回哪个字段 |
| LiteLLM `thinking_blocks`（带签名的 Anthropic thinking 镜像） | `:1431-1454`：优先于文本别名 | 保留签名 |
| Mistral content parts `{type:"thinking", thinking:[{type:"text"}]}` | `:1435-1470`（`mistralReasoningContentParts`） | thinking 块 |
| OpenRouter/Gemini 网关 `delta.reasoning_details[]`（`reasoning.encrypted` 按 tool call id 挂签名） | `:1634-1652` | 合进对应 `ToolCall.thoughtSignature`（JSON 结构存 perCall/message 两种），同时从中反推 `upstreamModel` |
| 正文里漏出来的 `<think>`/chat-template 标记 | stream markup healing（§1.3） | thinking 块/工具调用 |
| Responses API `reasoning` item（summary_text / reasoning_text / encrypted_content） | `openai-shared.ts:3662`：`thinkingSignature = JSON.stringify(item)`（整条 reasoning item，含加密 blob）；请求时自动 `include: ["reasoning.encrypted_content"]`（`:4118`） | thinking 块（summary=true 表示是摘要） |
| Anthropic `thinking`（signature）/`redacted_thinking` | anthropic.ts 流解析 | `thinkingSignature` = Anthropic 签名；`RedactedThinkingContent` |
| Gemini `thought:true` part + `thoughtSignature`（可挂在任何 part 上，包括 functionCall/text） | `google-shared.ts:107-139` | thinking 块签名 / `TextContent.textSignature` / `ToolCall.thoughtSignature` |

### 3.2 回传（出）——同模型 vs 跨模型
**chat completions 回放**（`openai-completions.ts:2470-2650`），分支优先级：
1. `mistralReasoningContentParts` ⇒ 按顺序回写 thinking/text parts（`:2474-2486`）。
2. `requiresThinkingAsText` ⇒ 用目标模型方言渲染 thinking 拼到 content 前（`:2488-2497`）。
3. `requiresReasoningContentForToolCalls` ⇒ 写回字段：若 `allowsSynthetic` 且签名是已知字段名就用签名字段，否则用配置的 `reasoningContentField`（`:2498-2514`）。
4. `thinkingFormat==="zai"` 且模型推理 ⇒ 总是写 `reasoning_content`（Z.ai/智谱/Kimi 原生/MiMo 把它当续写提示，`:2515-2525`）。
5. `replayReasoningContent`（本地后端）⇒ 写回（为了 chat template 重建 `<think>`，KV cache 不失配，`:2526-2549`）。
6. 否则**丢弃**（不发）。
然后三级兜底（`:2579-2650`）：
- Tier1：provider 要求精确值且不收占位 ⇒ 从**所有** thinking 块（含空文本）按签名恢复；
- Tier2：真没有推理（代理剥掉了）⇒ 写 `syntheticReasoningContentFallback`（默认 `""`）；
- Tier3：收占位的（Kimi/OpenRouter，thinkingFormat ∈ openai/openrouter/zai）且有 tool_calls ⇒ 写 `"."`。
- DeepSeek V4：一旦有过 reasoning，**每个** assistant 回合都要带（`requiresReasoningContentForAllAssistantTurns`）。

**Responses 回放**（`openai-shared.ts:2325-2520`）：从 `thinkingSignature` 反解析出 reasoning item 原样回放（含 encrypted_content）；跨 host 携带的同权重推理用无 id 的合成 reasoning item（`:2484-2491`）；要求必带推理的目标（DeepSeek 系）缺失时合成 `"reasoning unavailable"` 占位（`:2349, 2395-2436`）；没有可回放 reasoning item 时把 message id 去掉（否则服务端拒，#4173，`:2513-2519`）。

**Anthropic 回放**（`anthropic.ts:6026-6103`）：
- 同一 assistant 消息里**只要有一个签名 thinking**：签名块原样回放，未签名块降级为文本（Anthropic 的 all-or-none 规则）。
- 没有签名 thinking：未签名的若 `compat.replayUnsignedThinking`（兼容端点）⇒ 以 `signature:""` 原生回放，否则降级为文本。
- `redacted_thinking` 原样回放（transform 层已决定去留）。
- 生成侧：签名 400 时自愈重试（见 §2.8）。

**Gemini 回放**（`google-shared.ts:143-156, 219-276`）：只有「同 provider 且同 model」且签名是合法 base64 才保留 thoughtSignature；同模型 thinking 即使无签名也回 `thought:true`；跨模型 ⇒ 降级为文本；Gemini 3 函数调用缺签名时按 compat 填哨兵 `"skip_thought_signature_validator"`（Vertex 拒哨兵则不填）。

### 3.3 跨 provider handoff（transformMessages 中的 thinking 策略）
`transform-messages.ts:836-1108`，判定维度：
- `isSameModel` = provider、api、model id 三者全等（`:838-841`）。
- **签名策略**（`:861-1031`，仅 anthropic→anthropic 回放）：
  - 同部署（同 provider 且官方端点或 prefix-binding）保留签名，让 Anthropic 自己做单向兼容检查；
  - 跨部署且涉及签名端点（源是官方 anthropic 或目标是签名端点）⇒ 剥签名；3p↔3p（Z.ai、DeepSeek、自定义）保留签名作不透明提示（#2265）；
  - 最新一条 assistant 若由**其他 provider** 产出，签名必剥（否则 `400 Invalid signature` 卡死会话）；
  - 中断/出错回合：只有**最后一个块**的签名不可信（流在它中间断掉），之前块的签名完整可用；「abandoned tool use」（有 toolCall 但 stopReason≠toolUse）全剥，但最新回合例外（字节级不可改）（`:913-942`）；
  - 凭据不同（同一签名端点但换了账号 credentialId）⇒ thinking/redacted 全删（`:901-905, 970`）；
  - 历史被改写过（compaction/prune）且模型 `prefixBinding` ⇒ 改写点之前的 thinking 全删（`:787-807, 971-976`）。
- **跨 API 的 thinking**（`:1032-1082`）：
  1. 同模型且有签名 ⇒ 原样（OpenAI 加密推理文本可为空但签名关键）；
  2. 空 thinking ⇒ 删；
  3. 目标「证明能读外来未签名 thinking」⇒ 原生保留、去签名：`anthropic-messages` 且 `replayUnsignedThinking`，或 `openai-completions` 推理模型且 `thinkingFormat==="zai"` 且不 `requiresThinkingAsText`（`targetReadsForeignThinking` `:471-480`）；
  4. **同一权重的另一个 host**（`carriesReasoning`：两端在 KDL 里都声明 `portable-reasoning` 且 class/family/revision 完全一致；且目标 encoder 有原生 reasoning 槽；且块 `summary===false`）⇒ 原生保留（标记 `kCarriedReasoning`，去签名去 item id）（`:848-859, 1054-1056`；`compat/reasoning-carry.ts:29-64`；目标槽判定 `targetReplaysPlaintextReasoning` `:498-521`）；
  5. 其余 ⇒ **降级为 text**，用 `renderDemotedThinking(target.id, text)` 包成**目标模型自己的 thinking 方言**（Gemini 用 ```thinking 围栏、其它用 `<think>` 等）；Claude 方言例外：**裸文本、不加标签**（Anthropic 的 `reasoning_extraction` 分类器看到 `<thinking>` 包裹的历史推理会拒答或泄漏）；Harmony/Gemma 方言改用 `<think>`（避免控制 token 进结构化消息）（`dialect/demotion.ts:4-40`）。降级块用 symbol 标记，chat-completions 拼接时在其后加换行防止和正文粘连（`openai-completions.ts:2454-2467`）；若降级块是最后一块则 `trimEnd`（Anthropic 拒绝末尾空白，`transform-messages.ts:1197-1207`）。
- **redacted thinking**：只在同模型 / 同部署 / 本 provider 最新回合 / 目标接受未签名时保留，跨 API 一律丢（`:1085-1108`）。
- Anthropic 服务端工具块、server-side fallback 块：只回同 provider（官方）（`:1110-1132`）。
- Gemini `thoughtSignature`（挂在 toolCall 上）：跨模型一律去掉（`:1153-1155`）。
- 实证注释：Gemini 3 对未签名 thought part「schema 接受但静默丢弃」，所以降级为文本才能让推理真正进上下文（`transform-messages.ts:1057-1066`，`demotion.ts:5-9`）。

### 3.4 thinking level → budget / effort 映射
- 用户档位：`Effort` 6 档（`pi-catalog/src/effort.ts:2-18`）。
- 模型能力：`ThinkingConfig`（`types.ts:135-192`）：`mode`、`efforts[]`（有序、非空；不可调的推理模型 `thinking: undefined`）、`defaultLevel`、`effortMap`（档位→wire 值）、`supportsDisplay`、`prefixBinding`、`effortRouting`（不同档位路由到不同 wire model id，如 `-thinking` 变体）、`effortBudgets`、`suppressWhenOff`、`requiresEffort`。
- **默认 mode**（`resolve.ts:1014-1041`）：google 系 Gemini 3 → `google-level`，否则 `budget`；anthropic-messages：MiniMax m2/m3 → adaptive；GLM≥5.2@umans/zai → budget-effort；Claude：Haiku≥5.5 / 其它≥4.6 → `anthropic-adaptive`，Opus≥4.5 → `anthropic-budget-effort`，否则 `budget`；其余 API → `effort`。
- **默认梯子**（`resolve.ts:993-994, 1044-1065`）：anthropic-messages 与 Responses 与「openai 格式且支持 effort」的 chat = minimal..xhigh；其它 = minimal..high。KDL 可覆盖（DeepSeek low/high/max、Kimi K3 low/high/max…）。
- **clamp**：请求档位不在支持列表时取不超过它的最高档，否则最低档（`model-thinking.ts:35-65`）；强制推理模型（`requiresEffort`）在用户关思考时被抬到最低档（`stream.ts:1762-1777`）。
- **wire 编码**：
  - OpenAI effort：`compat.reasoningEffortMap[e] ?? thinking.effortMap[e] ?? e`（`openai-shared.ts:932-939`）。
  - Anthropic budget：`ANTHROPIC_THINKING = {minimal:1024, low:4096, medium:8192, high:16384, xhigh:32768, max:32768}`（`stream.ts:1601-1608`），用户 `thinkingBudgets` 可覆盖；`max_tokens = 调用方 maxTokens + budget`（封顶模型 maxTokens，未知时 64000），并保证 budget ≤ maxTokens − 4000、≥1024，否则关思考（`stream.ts:1883-1979, 1587-1598`）；adaptive 模式发 `output_config.effort`，`minimal` 夹到 `low`（`model-thinking.ts:119-127`）。
  - Bedrock Claude budget 表 `stream.ts:1619-1626`；Google budget 表 `stream.ts:1610-1617`，`getGoogleBudget` 优先自定义 → `effortBudgets` → `-1`（动态）（`:2352-2370`）；Gemini 3 level：minimal→MINIMAL（某些路由→LOW）、low→LOW、medium→MEDIUM、high/xhigh/max→HIGH（`model-thinking.ts:85-106`）。
  - Google 关思考：budget 模式发 `thinkingBudget:0`，level 模式且 `suppressWhenOff` 发 `MINIMAL`（`stream.ts:1739-1748`）。
- **chat-completions 方言编码**（`openai-shared.ts:1089-1252`）：
  | 方言 / disableMode | 开 | 关 |
  |---|---|---|
  | openai（lowest-effort） | `reasoning_effort: <wire>` | 调用方关且没指定档 ⇒ 发最低档（OpenAI o 系列不能真关）；否则删 |
  | none-effort | 同上 | `reasoning_effort: "none"` |
  | openrouter | `reasoning: {effort}` | `reasoning: {enabled:false}` |
  | zai / kimi（zai-thinking-disabled） | `thinking:{type:"enabled"[, keep]}` (+ `reasoning_effort` 若支持；kimi 为 `thinking:{type, effort}`) | `thinking:{type:"disabled"}`；**未请求推理时也主动发 disabled** |
  | qwen | `enable_thinking: true` (+ 模板 `reasoning_effort`) | `enable_thinking:false` |
  | qwen-chat-template（NVIDIA NIM/vLLM） | `chat_template_kwargs.enable_thinking:true` | `chat_template_kwargs.enable_thinking:false`（NIM 拒绝未知顶层字段） |
  | chat-template | `chat_template_kwargs.thinking:true` | `…thinking:false` |
  | venice | — | `venice_parameters.disable_thinking:true` |
  | cline | — | `reasoning:{enabled:false}`；budget 模式发 `reasoning.max_tokens` |
  另：Qwen3.6+ 本地 `preserve_thinking:true` 永远发（模板否则会剥掉旧回合 `<think>`，导致 KV cache 失效，`:1124-1166`）。

---

## 4. 消息序列规范化（transformMessages + 各 convertMessages）

入口：每个 provider 的 convertMessages 第一步调 `transformMessages(messages, model, normalizeToolCallId?, maxIdLen=64, dupSuffix="_dup", targetCompat, targetCredentialId)`（`transform-messages.ts:756-764`；chat 调用 `openai-completions.ts:2317-2324`）。

### 4.1 预处理
1. 可选凭据脱敏（`:765-768`）。
2. **畸形 tool call 清洗**（`sanitizeMalformedToolCalls` `:386-444`）：id 空/空白，或 name 空、>128 字符、含空白/控制字符（网关把整段调用文本塞进 name 的情况）⇒ 删掉该 toolCall 及**按 FIFO 位置配对**的 toolResult；整条 assistant 空了就删。

### 4.2 第一遍：逐条变换
- user/developer：原样（`:817-819`）。
- toolResult：按映射表重写 `toolCallId`（含 Responses 组合 id `call_x|fc_y` 按 call 部分匹配）（`:822-833`）。
- assistant：thinking/签名策略见 §3.3；**assistant 里的图片一律删**（无 provider 接受 assistant 图片，`:1134-1139`）；text 跨模型时剥掉 `textSignature`（`:1141-1147`）；toolCall 跨模型剥 `thoughtSignature`、归一化 id：
  - 目标是 Anthropic（且跨模型或官方端点）：必须满足 `^[a-zA-Z0-9_-]{1,64}$`，否则先用 provider 归一函数，仍不合法则 `toolu_<hash>`（`:523-544, 1158-1168`）；
  - 其它目标跨模型时调用 provider 提供的 `normalizeToolCallId`（chat：Responses 组合 id 取 `call_id` 部分、非法字符换 `_`、截 40；同模型 chat id 原样保留——它是 provider 的不透明关联 token，`openai-completions.ts:2298-2316`）。
- Responses 组合 id 的配对 key 有**按具体 id 的来源作用域**，防止把 chat 的含 `|` 不透明 id 误拆（`:61-144`，#10284）。

### 4.3 tool call id 去重
`deduplicateToolCallIds`（`:212-334`）：同一 id 在历史里重复出现（Responses 组合 id 折叠、compaction 后复用）⇒ 后出现的改成 `id_dup1`、`_dup2`…（组合 id 每段都加后缀，且保证不超过长度上限，`:146-165`），对应的下一个 toolResult 同步改名；每个 assistant 回合首次出现某 id 时清掉上一回合遗留的待改写队列，避免旧 dup 抢新结果。Mistral 时后缀前缀改为 `dup`、上限 9（`openai-completions.ts:2292-2297`）。

### 4.4 第二遍：保证「每个 tool call 紧跟恰好一个结果」
`:1263-1467`：
- **截断的纯 thinking 回合**（stopReason ∈ length/error/aborted 且无 text 无 toolCall）⇒ 删（否则形成连续 assistant，Anthropic 拒；`:1336-1351`）。`stop` 的纯 thinking 回合保留（推理回放需要）。
- **出错/中断回合**的 tool calls：先找真实结果，找不到就在下一个边界补 `{isError:true, content:"aborted"}`（`:1301-1324, 1355-1366`）。
- 正常回合的 tool calls：遇到下一个 assistant/user 边界时 flush，找不到结果就补 `{isError:true, content:"No result provided"}`（`:1277-1299`）；只从**该 assistant 之后**的位置拉结果，不会把更早的孤儿结果挪过来（`:1252-1261`）。
- 重复结果：同一 call 只放第一个（`toolCallStatus`，`:1275, 1376`）。
- **孤儿 toolResult**（对应 tool_use 已被 compaction 折掉）：若当前有待配对窗口 ⇒ 静默丢；否则转成 `role:"user"` 的 `<stale-tool-result tool=… id=… [is-error]>…</stale-tool-result>` 文本（**故意用 user 而非 developer**，防止陈旧工具输出获得更高指令优先级，`:1391-1447`）。

### 4.5 图片对非视觉模型降级
- chat completions：`isOpenAICompletionsVisionSupported = input 含 image && !compat.stripImageInput`（`vision-guard.ts:39-43`）；不支持时图片部件替换为占位文本 `"[image omitted: model does not support vision]"`（`vision-guard.ts:4`；user 消息 `openai-completions.ts:2405-2434`；tool 结果 `:2719-2734`）。
- tool 结果里的图片：chat completions 的 `tool` 消息只能放文本，所以批量 tool 结果后**追加一条 user 消息**「Attached image(s) from tool result:」+ 图片（`:2745-2779`）；Anthropic 同理把错误结果里的图片挪出来（`anthropic.ts:6175-6206`）；Google 不支持时同占位（`google-shared.ts:195-210`、tool 结果 `:283-288`）；Anthropic 不支持时同占位（`anthropic.ts:1252`）。
- 「`sendsImageInputOnWire`」统一回答「这个模型的请求最终会不会带图」（`vision-guard.ts:58-62`），UI/模型列表用它而非 `model.input`。

### 4.6 空消息 / 角色处理
- chat：空字符串 user 跳过；text 部件 trim 为空跳过；全部为空则整条跳过（`openai-completions.ts:2397-2435`）；assistant 文本一律**拼成字符串**（有后端把数组原样回显造成递归嵌套，`:2450-2468`）；assistant 只有 tool_calls/推理时 `content:""` 而非 null（`:2685-2690`），什么都没有则跳过（`:2702-2704`）；文本 `.toWellFormed()` 修孤立代理对。
- system：`Context.systemPrompt` 是数组，默认每段一条 system（KV cache 前缀稳定），不支持多 system 的 host 合并（§2.3）。
- Anthropic：consecutive toolResult 合并为一条 user（Z.ai 需要，`anthropic.ts:6175-6211`）；丢掉空 user 后出现**两个相邻 assistant** ⇒ 中间插 `user:"Continue."`（`:6311-6321`）；末尾是 assistant（prefill）⇒ 追加 `user:"Continue."`（`:6344-6347`）。
- chat-completions 本身不做 user 合并（OpenAI 兼容端允许相邻 user）。

---

## 5. pi-catalog：元数据来源、生成、运行时覆盖、自定义模型

### 5.1 数据形态
- `src/models.json`（12MB，77 provider，5697 行；本机实测）：每行是**完整物化的 Model**（含已解析 `compat`、`thinking`、`identity`、`cost`、`contextWindow`、`maxTokens`、`promptCache` TTL…），启动零计算直接用（`models.ts:25-44`）。示例 `anthropic/claude-sonnet-4-0`：cost 3/15/0.3/3.75，ctx 200000，max 64000，thinking budget minimal..xhigh，promptCache short 300 / long 3600。
- `src/compat/rules.json`（441KB）：KDL 编译产物。
- `Model` 字段全集：`types.ts:1460-1751`（重点：`cost: ModelCost`、`contextWindow: number|null`、`maxContextWindow`、`maxTokens: number|null`、`omitMaxOutputTokens`（给 Ollama 这类无法知道上游真上限的代理）、`input: ("text"|"image")[]`、`reasoning`、`thinking`、`supportsTools`（只有 `false` 才算不支持）、`requestModelId`（wire id 与本地 id 不同）、`promptCache`、`pricingStatus`（全零价格要区分 free/included/unknown）、`premiumMultiplier`、`serviceTierCost`、`tokenizer`）。
- `ModelCost`（`types.ts:1364-1417`）：per-million `input/output/cacheRead/cacheWrite` + `longContext{inputThreshold,…}`（超过阈值整单换价）+ `timeBased`（峰谷时段倍率 + 按日期生效的整卡替换，DeepSeek 用）。

### 5.2 来源与生成
- README：`models.json` 由 `scripts/generate-models.ts` 从**上游源（stencil.so、provider 目录 discovery、OpenCode 文档）**生成，rules 从 KDL 编译；禁止手改（`pi-catalog/README.md:22-31`）。stencil.so 是作者公司（Stencil Labs，`package.json` author）运营的目录服务，代码里与 `models.dev` 同义使用（`model-manager.ts:105-114`：`ModelResolutionSource = "bundled" | "cache" | "models.dev" | "provider"`）。生成脚本不在 npm 包里（包只带 `src/`）。
- KDL `seed` 节点为「无法在生成时 discovery 的 provider」手写行（必须给 reasoning/input/cost/limits），`bundle = always|fallback|empty|never` 控制何时入包（`rules/README.md:426-441`；例 `providers/openrouter.kdl:20-117`）。
- 价格修正、窗口修正走 catalog axis：`cost-patch`、`cost-fallback`、`limits-patch`、`long-context-cost`（可写倍率，随上游价自动跟）、`time-based-cost`、`cache-read-at-input-rate`、`context-window-authoritative`、`max-context-window`（`axes.ts:333-470`；DeepSeek 实例 `providers/deepseek.kdl:22-60`）。
- discovery：OpenAI 兼容 `/v1/models`（`discovery/openai-compatible.ts`）、Gemini、Codex、Cursor、Antigravity、Ollama 等；只返回 `{id}` 的网关通过 bundled「canonical reference」恢复上下文/价格/推理梯子（`recover-canonical-params`，`rules/README.md:149`；CHANGELOG catalog 17.3.8 L843 GMI Cloud）。

### 5.3 运行时解析与覆盖
- `resolveProviderModels`：**static(bundled) → cache → stencil/models.dev → provider discovery**，后者按 id 覆盖前者；缓存只在某个远端源失败时参与（`model-manager.ts:236-241`）。
- 身份分类（`classifyModel`）：taxonomy 用 exact/bounded/namespace/prefix/glob 匹配器把 id 映射到 class（如 `anthropic`），family 用 glob（`*sonnet*`），revision 从前缀后提取三段数字（`claude-opus-4-6` → 4.6.0）（`rules/README.md:49-107`）。**所有 compat/thinking 判断只看 identity 字段，不做模型名字符串匹配**（`resolve.ts:75-118`）。这让 `vendor/claude-sonnet-4-6-thinking`、`[Kiro] claude-opus-4-8` 这类代理 id 也能命中正确规则。

### 5.4 用户自定义模型（`~/.omp/agent/models.yml`）
- schema：`pi-coding-agent/src/config/models-config-schema-bundle.ts`：
  - compat 可配字段（OpenAI+Anthropic 共用一个 compat 槽，按 api 解释）：`:40-89`，含 `supportsStore/supportsDeveloperRole/supportsMultipleSystemMessages/supportsReasoningEffort/reasoningEffortMap/maxTokensField/supportsUsageInStreaming/requiresToolResultName/requiresMistralToolIds/requiresAssistantAfterToolResult/requiresThinkingAsText/reasoningContentField/requiresReasoningContentForToolCalls/allowsSyntheticReasoningContentForToolCalls/requiresAssistantContentForToolCalls/supportsToolChoice/supportsForcedToolChoice/disableReasoningOn*/thinkingFormat/qwenTemplateReasoningEffort/openRouterRouting/vercelGatewayRouting/extraBody/cacheControlFormat/supportsStrictMode/toolStrictMode/streamIdleTimeoutMs/streamMarkupHealingPattern/…/stripImageInput` + Anthropic 的 `supportsContextManagement/supportsEagerToolInputStreaming/requiresToolResultId/replayUnsignedThinking/bedrockMessagesApi`；还可写 `whenThinking: {…}`（`:91-94`）。
  - `thinking`：`{mode, efforts[] | levels[] | minLevel+maxLevel, defaultLevel, effortMap, supportsDisplay, requiresEffort}`（`:135-170`）。
  - model 定义：`id, name, api, baseUrl, reasoning, thinking, input, supportsTools, cost{4项}, promptCache, contextWindow, maxContextWindow, maxTokens, omitMaxOutputTokens, headers, compat…`（`:203-237`）；provider 级也有 `compat`，与 model 级 `mergeCompat`（`custom-models.ts:101`）。
  - discovery 类型：`ollama | llama.cpp | lm-studio | openai-models-list | proxy | litellm | apple-foundation-models`（`schema :316-324`）。
- 构建（`custom-models.ts:117-164`）：按 id 去 bundled 索引找**参照模型**（`identity/reference.ts:1-9`：剥代理标记 `[Kiro]`、`:cloud`、`-thinking` 等，优先窗口大、有缓存价、OpenAI 一方的，`:44-59`），缺失的 cost/input/reasoning/thinking/contextWindow/maxTokens/compat 从参照继承；仍缺失用默认 `reasoning:false, input:["text"], contextWindow:128000, maxTokens:16384, cost 全 0`；最后过 `buildModel` 走完整 compat 引擎（于是 baseURL 主机探测 + KDL 规则 + 用户 compat 三层都生效）；用户显式 cost 胜过一切目录修正。

---

## 6. usage / 成本 / stop reason / 错误分类

### 6.1 Usage 统一语义（`pi-catalog/src/types.ts:201-266`）
- `input` = **未命中缓存的新输入**；`cacheRead`、`cacheWrite` 单独；`output` = 全部输出（含 thinking 与工具参数）；`reasoningTokens` ⊂ output，`undefined` = 未知（不是 0）；`totalTokens`；`contextTokens`（provider 报告的真实占用，多次内部调用的 provider 用它）；`orchestration`（服务端编排 token 另计）；`cttl{ephemeral5m, ephemeral1h}`（Anthropic 写缓存 TTL 拆分）；`server{webSearch, webFetch}`；`credits`；`premiumRequests`；`cost{input,output,cacheRead,cacheWrite,total}`。

### 6.2 各家归一化
- **OpenAI 兼容 chat**（`openai-completions.ts:2186-2251` → `openai-shared.ts:493-511`）：cached 取 `cached_tokens` / `prompt_cache_hit_tokens`（DeepSeek）/ `prompt_tokens_details.cached_tokens` / `cachedContentTokenCount`（Gemini 网关）中**第一个正数**（某些 host 根部给 0 嵌套给真值，CHANGELOG 16.3.3）；Fireworks 头 `fireworks-cached-prompt-tokens` 兜底；cacheWrite 取 OpenRouter `prompt_tokens_details.cache_write_tokens`；`input = prompt − cached − cacheWrite`；**DeepSeek 特判**：有 hit+miss 且无 OpenRouter 字段时 `input = prompt − cached`、`cacheWrite = 0`（miss 不是写缓存）。
- **Responses**（`openai-shared.ts:4190-4264`）：`input_tokens_details.cached_tokens`、`output_tokens_details.reasoning_tokens`，并把 orchestration token 从主桶里扣出（根据 total 判断主桶是否已包含）。
- **Anthropic**：`input_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens` 直接三桶（`anthropic.ts:3162-3163, 3530-3535`），`cache_creation.ephemeral_5m/1h` → `cttl`、`server_tool_use` → `server`（`:1886-1913`）；compaction 多 iteration 求和（`:2023-2050`）。
- **Gemini**（`google-shared.ts:491-506`）：`promptTokenCount` 含 cached ⇒ `input = prompt − cached`；`output = candidates + thoughts`；prompt 缺失时用 `total − candidates − thoughts`，cached 夹到 ≤ prompt。

### 6.3 成本计算（`pi-catalog/src/models.ts:73-197`）
- 先按请求时间戳选生效价卡（dated effectiveRates）→ 再按 prompt 总输入（input+cacheRead+cacheWrite+orchestration）是否越过 `longContext.inputThreshold` 选长上下文价 → 乘峰谷倍率（`:73-106, 151-165`）。
- 写缓存：有 `cttl` 时 5m 按 `cacheWrite` 价、1h 按 `input×2`，未归属余量按 5m 价（`:172-197`）。
- **服务端回报成本优先**：OpenRouter/cline-pass 的 `usage.cost`（BYOK 时加上 `cost_details.upstream_inference_cost`）按比例缩放各分项，估算为 0 时整笔记在 input（`openai-shared.ts:430-471`）。
- 历史消息按当时时间戳定价并保存金额，不在展示时重算（`pi-catalog/README.md:57`）。

### 6.4 stop reason 映射
| wire | 映射 | 位置 |
|---|---|---|
| chat `stop`/`end` | stop | `openai-completions.ts:2883-2930`（大小写折叠，兼容网关回传 Gemini 的 `STOP`/`MAX_TOKENS`）|
| `length`/`max_tokens` | length | |
| `tool_calls`/`function_call` | toolUse | |
| `content_filter`/`network_error` | error（带说明）| |
| `error` / `insufficient_system_resource`（DeepSeek）| error，措辞故意匹配「瞬时错误可重试」正则 | |
| 其它未知 | error | |
| `null` | stop | |
| **后处理**：有结构化 tool_calls 但报 `stop` ⇒ 升级为 toolUse（`:1718-1729`）；修复出工具调用且 stop ⇒ toolUse（`:1681-1687`）；`[DONE]` 结束但无 finish_reason ⇒ 正常 stop，真 EOF 才报截断（CHANGELOG 18.0.2）；空 length ⇒ 上下文错误（Ollama，`:1731-1738`）| | |
| Anthropic `end_turn`/`pause_turn`/`compaction`/`stop_sequence` | stop | `anthropic.ts:6880-6910` |
| `max_tokens` / `model_context_window_exceeded` | length | |
| `tool_use` | toolUse | |
| `refusal` / `sensitive` | error | |
| 未知 | **stop**（新 stop reason 先在服务端上线，不应让已流完的回合失败）| |
| Responses `completed`→stop、`incomplete`→length、`failed`/`cancelled`→error、未知→stop | | `openai-shared.ts:3895-3917` |
| Gemini `STOP`→stop、`MAX_TOKENS`→length、SAFETY/RECITATION/MALFORMED_FUNCTION_CALL 等→error | | `google-shared.ts:398-424` |
注意 Anthropic「end_turn 但带 tool_use」不升级（语义是放弃工具调用），由 agent 层处理（CHANGELOG pi-agent-core 15.5.14）。

### 6.5 错误分类
- `errorId` 位标志：`ContextOverflow / Transient / Timeout / UsageLimit / AuthFailed / ContentBlocked / AccountPolicy / Grammar（strict 工具被拒）/ PayloadRejected（413 字节/媒体超限）/ EmptyResponse / ProviderFinishError / MalformedFunctionCall / StaleResponsesItem / CacheControlUnsupported / FastModeUnsupported / OAuthExpiry …`，可重试集合 `RETRIABLE_KINDS`（`pi-ai/src/error/flags.ts:20-88`）。
- **上下文溢出正则**（`flags.ts:90-117`，节选）：Anthropic `prompt is too long`；Bedrock `input is too long for requested model`；OpenAI `exceeds the context window`；Gemini `input token count.*exceeds the maximum`；xAI `maximum prompt length is \d+`；Groq `reduce the length of the messages`；OpenRouter `maximum context length is \d+ tokens`；llama.cpp `exceeds the available context size` 及多种 n_ctx 变体；LM Studio `greater than the context length`；MiniMax `context window exceeds limit`；Kimi `exceeded model token limit`；Z.ai `model_context_window_exceeded`；Ollama 空 length；通用 `context_length_exceeded` / `too many tokens` / `token limit exceeded`；消息条数上限 `chat history exceeds the \d+-message limit`。
- **413 二义性**：媒体/字节超限（`request_too_large`、`payload too large`）≠ token 溢出；只有 token 措辞才算溢出，裸 `413 (no body)` 双标让上层按本地余量裁决（`flags.ts:118-166, 694-702`，#9235）。
- 终态 4xx（除 408/429）上的「超时/断流」措辞不算瞬时错误（`flags.ts:593-595, 649-674`）。
- `isContextOverflow(msg, contextWindow)` = 标志位 ∨ **usage 证明**（`contextTokens ?? input+cacheRead+cacheWrite > contextWindow`）∨ error 文本匹配（`flags.ts:1010-1022`）。

---

## 7. CHANGELOG 高价值兼容条目（20 条，按主题）

（路径 `pi-ai/CHANGELOG.md` / `pi-catalog/CHANGELOG.md`，L=行号）

**跨 provider / thinking**
1. **pi-ai 16.1.19 (L2096)**：跨 API 切换（Z.AI Anthropic→Z.AI OpenAI、Kimi、DeepSeek…）时先前所有 thinking 被一律降级为文本、推理链丢失 ⇒ 对「能读外来未签名 thinking」的目标保留原生 `reasoning_content`。
2. **pi-ai 17.1.0 (L1471)**：切换 Anthropic 兼容 provider 后 `400 Invalid signature in thinking block` 卡死 ⇒ 签发方与目标不同就剥签名。
3. **pi-ai 18.2.1 (L577)**：故障转移代理中途换上游（Claude→GLM→Claude）导致签名 400 永久卡死 ⇒ 先降级未签名重试，再不行丢 thinking 并对会话 pin 该模式。
4. **pi-ai 18.2.1 (L574)**：把模型自己的推理以「降级文本」回传给 Anthropic 会触发 `reasoning_extraction` 分类器（Fable 拒答、Opus/Sonnet 泄漏到正文）且破坏缓存前缀。
5. **pi-ai 16.3.7 (L1795) / 16.3.0 (L1879) / 16.2.2 (L2007)**：同模型丢未签名旧推理；跨模型降级不输出原始 thinking 标签；降级文本用**目标模型的规范 thinking 方言**包裹（Gemini 用 thinking 围栏），Claude 用裸文本。
6. **pi-catalog 16.0.9 (L1655) / 16.3.0 (L1440)**：GitHub Copilot、ZenMux 的 anthropic 代理其实会转发到签名校验的 Anthropic，被误判为非签名端点（replayUnsignedThinking=true）⇒ 400；签名端点识别扩展到 Cloudflare/Vertex/Bedrock/Azure（16.3.3 L1411）。

**reasoning_content 回传**
7. **pi-ai 17.2.13 (L1141)**：DeepSeek Responses 目标在交接 + compaction 后报 `reasoning_text in the thinking mode must be passed back` ⇒ 缺失时合成 reasoning item。
8. **pi-catalog 16.1.22 (L1551) + pi-ai 16.1.22/16.1.23 (L2076/L2070)**：本地 llama.cpp/LM Studio/vLLM 每轮全量重算 prompt，因为没回传 `reasoning_content`，Qwen3.6 模板还会剥旧回合 `<think>` ⇒ `replayReasoningContent` + `preserve_thinking`。
9. **pi-ai 18.5.1 (L251)**：DeepSeek / Responses 在回放修复过的工具参数、孤儿结果、缺推理上下文时失败或重试死循环。

**工具调用 / 序列**
10. **pi-ai 16.1.10 (L2203, L2205)**：Anthropic 回放清洗畸形 tool id（含中断留下的空 id）；`transformMessages` 不再把更早的孤儿结果拉到复用同一 id 的后续调用上。
11. **pi-ai 18.2.1 (L578)**：Codex 回放 >64 字符或含 `|`/`\n` 的 tool id 报 `string_above_max_length` ⇒ 线上 id 清洗 + 确定性截断。
12. **pi-ai 16.3.12 (L1755)**：assistant 在 tool_use 之后还有文本（跨 provider 回放、server-side fallback）⇒ Anthropic 报 tool_use 后无 tool_result ⇒ 稳定分区把 tool_use 放到最后（`anthropic.ts:6141`）。
13. **pi-ai 18.0.2 (L922)**：以 `[DONE]` 结束但不给 `finish_reason` 的兼容主机每轮都报错 ⇒ `[DONE]` 视为正常结束。

**参数兼容**
14. **pi-ai 17.0.1 (L1562) / pi-catalog 18.5.1 (L181)**：o 系列/GPT-5+ 以及新 Claude 在任何 host 都拒 `temperature/top_p` ⇒ `supportsSamplingParams` 按模型血统（不按 host）关闭。
15. **pi-catalog 16.1.8 (L1611) / 18.0.1 (L766)**：Fireworks 上的 Qwen 拒顶层 `enable_thinking`（要 `reasoning_effort`），Venice 上的 Qwen 也要 `reasoning_effort` + `venice_parameters.disable_thinking` ⇒ 同一模型不同 host 不同思考方言。
16. **pi-ai 17.4.0 (L1003)**：Fireworks 上 DeepSeek 只要带 `tool_choice` 就关思考 ⇒ 省略冗余的 `tool_choice:"auto"`。
17. **pi-ai 16.2.0 (L2047) / 17.2.0 (L1295)**：llama.cpp/LM Studio 只认字符串 tool_choice ⇒ 命名强制降为 `"required"` 并收窄 tools。
18. **pi-ai 18.0.1 (L939)**：DeepSeek 历史里有图片（或 model.input 误标视觉）⇒ `unknown variant image_url` 400 ⇒ 剥图片换占位。
19. **pi-catalog 16.0.6 (L1688)**：Mistral/Devstral tool 结果后不能直接接 user ⇒ 合成 assistant 桥接消息。

**用量 / 错误**
20. **pi-ai 16.3.3 (L1850) + 18.0.4 (L909) + 18.4.2 (L354)**：嵌套 cached_tokens 优先于根部 0；413 区分「字节/媒体超限」与「token 溢出」；多次内部调用的 provider 用 `contextTokens` 判溢出，避免误触发压缩。

---

## 8. 对记忆花园（Swift，17 家预设，OpenAI 兼容 + Anthropic 原生）的借鉴建议

> 仅供 plan 阶段参考，未动代码。

1. **把 compat 做成「建模型时一次性解析」的值类型**：`struct ResolvedOpenAICompat`（全字段非可选） + `struct OpenAICompatOverride`（全可选，用户/预设填）。解析顺序照抄 `resolve.ts`：默认 → baseURL 子串主机探测（一个 `KnownHost` 枚举 + `urlMarkers`）→ 按模型身份的规则表 → 用户覆盖。请求代码只读字段，不在发送路径里 `if baseURL.contains(...)`。
2. **优先实现的 ~20 个开关**（覆盖我们 17 家预设的 90% 坑）：`supportsDeveloperRole`、`supportsMultipleSystemMessages`、`maxTokensField`、`supportsSamplingParams`、`supportsUsageInStreaming`、`supportsStore`、`thinkingFormat`（openai/openrouter/zai/qwen/qwen-chat-template）、`reasoningDisableMode`、`supportsReasoningEffort` + `reasoningEffortMap`、`reasoningContentField`、`requiresReasoningContentForToolCalls`、`requiresReasoningContentForAllAssistantTurns`、`allowsSyntheticReasoningContentForToolCalls`、`requiresAssistantContentForToolCalls`、`requiresToolResultName`/`requiresMistralToolIds`/`requiresAssistantAfterToolResult`（Mistral 三件套）、`supportsToolChoice`/`supportsForcedToolChoice`/`disableReasoningOnToolChoice`、`supportsStrictMode`、`stripImageInput`、`cacheControlFormat`、`extraBody`；Anthropic 侧：`officialEndpoint`/`signingEndpoint`/`replayUnsignedThinking`/`requiresToolResultId`/`disableStrictTools`。
3. **模型身份 = class/family/revision**，规则按身份而非字符串匹配；这样代理/中转站的奇怪 id（带前缀、带 `-thinking`、带 `:free`）也能命中。
4. **IR 里保留出处**：AssistantMessage 存 `api/provider/model`；ThinkingContent 存 `signature` + `summary`；**chat completions 的 signature 存来源字段名**（`reasoning_content`/`reasoning`），回放时写回同一字段——这是零成本又很关键的技巧。
5. **发送前统一跑一遍 transformMessages**：畸形 tool call 清洗 → 跨模型 thinking 降级/保留 → tool id 归一 + `_dupN` 去重 → 孤儿 call 补结果、孤儿 result 转 user 文本 → 截断的纯 thinking 回合删除 → assistant 图片删除。我们已有的「换模型续聊」场景直接受益。
6. **降级 thinking 的包裹方式按目标模型决定**：发给 Claude 用裸文本（不要 `<thinking>` 标签），其它用 `<think>`。
7. **usage 统一成「input 不含缓存」四桶 + reasoningTokens 子集**，DeepSeek hit/miss 与 OpenRouter cache_write 特判；OpenRouter 有 `usage.cost` 就用它。
8. **上下文溢出判定**直接搬 `flags.ts:90-117` 的正则表 + usage>窗口兜底，用于自动截断/提示。
9. **未知 finish_reason / stop_reason 不要报错**（Anthropic 未知按 stop），有 tool_calls 却 `stop` 的升级为 toolUse，`[DONE]` 无 finish_reason 视为正常。
10. KDL 规则引擎本身对我们过重（他们支持 77 家、5697 个模型）；我们 17 家可以用 Swift 字典/表驱动的「按 host + 按模型 class」两张表，但**保持「血统规则」与「部署契约」分开**这一原则。
