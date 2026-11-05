# L4 —— Provider 接入层与账号登录对比报告

> 证据口径：本文只做静态源码阅读。`MP` 指本仓库根目录；`OM` 指任务书冻结的 OpenMinis clone 根目录。所有采纳建议均指“按 MP 架构原生实现”，不产生 GPL 源码搬运。

## TL;DR

| 发现 | 差距性质 | 采纳建议 | 代价档位 |
|---|---|---|---|
| 账号登录是消费级入口，但不等于所有 provider 都做 OAuth | 能力缺失 | 改造搬：先稳住现有 ChatGPT，再做 OpenRouter；其余逐家过上游准入 | 天级起，最深到架构级 |
| `provider / wire / auth / transport / conversation origin` 必须拆成正交轴 | 实现更优 | 改造搬：引入 ProviderInstance + CredentialKind + WireProtocol + TransportKind | 周级 |
| OAuth 刷新要有 shared single-flight 和 compare-before-delete | 实现更优 | 改造搬：先建共享刷新协调器，再接第二家 OAuth | 天级 |
| `APIProvider.swift` 和 `ChatService.swift` 应按职责拆，不应照抄“每品牌一目录” | 实现更优 | 改造搬：先做零行为文件拆分，再换抽象 | 周级 |
| 模型能力应是数据，不应继续靠 model id 猜 | 能力缺失 | 改造搬：给 ProviderModel 增加可选 capability metadata | 周级 |
| thinking 的“请求线格式 + 响应事件”应统一成规则和类型 | 实现更优 | 改造搬：先内置只读规则，再接结构化 thinking 流事件 | 周级 |
| 失败应先分类，再决定原模型重试或模型组降级 | 能力缺失 | 只借思路：先做 opt-in 模型组，不默认静默换模型 | 周级 |
| 未知 provider 类型不能让整张凭据表读成空 | 实现更优 | 直接搬思路：unknown sentinel + 原始值回写 | 小时级 |

## 前提冲突与替代口径（escape hatch）

1. lane 任务书写 MP “6 家内置、`APIProvider.swift` 1464 行”（`docs/prompts/2026-08-24-minis-compare/L4-providers-auth.md:9-10`）。当前源码的预设数组实际列出 16 张 provider 模板（`MP MemoryPalace/Models/APIProvider.swift:139-144`），文件内容到 1507 行（`MP MemoryPalace/Models/APIProvider.swift:1494-1507`）。本文以当前源码为准。
2. lane 任务书把 OM 描述成“七家 × 各自 OAuth 的对称结构”（`docs/prompts/2026-08-24-minis-compare/L4-providers-auth.md:9,16-18`）。当前 OM 的公共工厂实际列出 8 个可用 provider type，并让 OpenRouter、xAI、Kimi 复用 OpenAI 实现（`OM src/ios/Providers/LLMProviderFactory.swift:20-38,174-189,229-273`）；目录并非七份等形实现。本文把真正可学的部分改写为“共同协议、实例/认证分轴、复用 wire implementation”。
3. lane 任务书写 `Conversation.provider` 只有 `api/sillytavern/chatgpt` 三值并存在 cc-bridge 过滤问题（`docs/prompts/2026-08-24-minis-compare/L4-providers-auth.md:45`）。当前模型注释列出 `chatgpt/claude/api/sillytavern` 四值（`MP MemoryPalace/Models/Conversation.swift:49-50`）；新实时对话固定写 `api`（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:3561-3569,3604-3614`），使用 cc-bridge 时另写 `ccBridgeSessionName`（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:1924-1932`）。我检查了 Sidebar 高级筛选的范围/时间/角色/排序/类型路径（`MP MemoryPalace/Views/SidebarView.swift:2840-2931`），未发现按 provider 的筛选入口，因此“现有 cc-bridge filter 永远空”这一具体表现无法按当前快照复现；但“对话来源与执行通道混在相邻字段里”的抽象漏层仍成立。

## 发现

### 1. 账号登录是消费级入口，但不应把“所有 provider 都 OAuth”当发布门槛

- **OM 怎么做**：认证是 provider instance 的独立字段，支持 `.apiKey` 与 `.oauth`（`OM src/ios/Providers/ProviderInstance.swift:14-27,51-79`）。登录机制并不统一：OpenRouter 用 PKCE 换一把永久 API key 后存入 Keychain，不存在 refresh token 生命周期（`OM src/ios/Providers/OpenRouter/OAuth/OpenRouterOAuthManager.swift:45-96`）；Kimi 用 RFC 8628 device flow，展示 user code 后轮询 token（`OM src/ios/Providers/Kimi/OAuth/KimiOAuthManager.swift:69-104,138-165`）；Anthropic 使用浏览器 + localhost callback + PKCE，并在调用前按到期时间刷新（`OM src/ios/Providers/Anthropic/OAuth/ClaudeOAuthManager.swift:68-132,141-165`）；Gemini 登录后还要发现/创建并轮询 GCP project（`OM src/ios/Providers/Gemini/OAuth/GeminiOAuthManager.swift:70-139,363-380,436-528`）。
- **MP 现状**：MP 已有一条可用的 ChatGPT/Codex OAuth 形态：预设直接显示“账号登录”（`MP MemoryPalace/Models/APIProvider.swift:146-155`），登录使用 PKCE/state（`MP MemoryPalace/Services/ChatGPTOAuth/LoginCoordinator.swift:53-105`），token 写入 Keychain 并在请求前刷新（`MP MemoryPalace/Services/ChatGPTOAuth/TokenStore.swift:15-42,76-91`; `MP MemoryPalace/Services/ChatService.swift:1063-1095,1142-1151`）。其余当前预设仍是 API key 或本地端点（`MP MemoryPalace/Models/APIProvider.swift:161-315`）。
- **差距性质**：能力缺失。这里的缺失不是“没有任何账号登录”，而是“只有一扇免 API key 的门，且没有可扩展到第二家的认证框架”。
- **采纳建议**：**改造搬**。产品判断（推断）：面向非技术用户，上架版本至少要有一条无需手工申请 API key 的路径；MP 已由 ChatGPT OAuth 达到这个最低门槛，所以不需要等“全 provider OAuth”才发布。下一家优先 **OpenRouter**：一份账号授权覆盖聚合模型面，且 OM 证明其实现只需 PKCE + code-to-key，无 refresh 生命周期。建议顺序和粗代价：

  | 顺序 | provider | 建议 | 代价 |
  |---|---|---|---|
  | 0 | ChatGPT（已有） | 先补共享刷新协调、失效态和并发保护 | 天级 |
  | 1 | OpenRouter | 第二条账号入口；授权后按普通 API key 使用 | 天级 |
  | 2 | Kimi | 采用 device flow；需要 code UI、轮询、取消、refresh | 周级 |
  | 3 | Anthropic | 仅在确认第三方客户端准入后做；需要 provider 专属 refresh/请求语义 | 周级 |
  | 4 | xAI | 需要 discovery、nonce/PKCE、refresh 与账号状态（OM 路径见 `OM src/ios/Providers/xAI/OAuth/XAIOAuthManager.swift:67-180,194-219`） | 周级 |
  | 5 | Gemini | OAuth 后不是简单把 bearer 塞进现有 OpenAI-compatible endpoint，还带 project discovery/onboarding | 架构级 |
  | 不排期 | DeepSeek/Groq/SiliconFlow/DashScope/智谱/豆包/Ollama | OM 没给出这些品牌的账号登录证据；继续支持 API key/本地端点，不猜 OAuth | 不适用 |

- **代价档位**：整体是架构级；按上述顺序可从天级增量交付。
- **风险与前置**：每家上游是否允许第三方上架 app 使用相应 client id、订阅 quota 和回调方式，本批次未查证；这是编码前置，不可从 OM “能写出来”推导为“可上线”。必须先完成第 2、3 条，否则第二家 OAuth 会复制当前特例。

### 2. 把认证、线协议、传输和对话来源拆开，cc-bridge 才不会继续漏层

- **OM 怎么做**：`ProviderInstance` 分开保存 `providerType`、`credentialType`、custom base URL 等实例信息（`OM src/ios/Providers/ProviderInstance.swift:14-38,51-79`）；工厂再按 provider type 选择 wire implementation，并在构造器内按 credential type 注入 API key 或 OAuth token provider（`OM src/ios/Providers/LLMProviderFactory.swift:15-40,81-107,134-170`）。通用 agent 面则只看到 provider-agnostic message/tool/event 类型和 `AgentProvider` 协议（`OM src/ios/Providers/AgentProvider.swift:14-33,53-70,124-193`）。
- **MP 现状**：`ProviderType` 同时放了 OpenAI wire family、Anthropic wire family、本地 WebSocket transport 和 ChatGPT OAuth 产品登录（`MP MemoryPalace/Models/APIProvider.swift:3-10`）；`APICredential.type` 只能选这个混合枚举（`MP MemoryPalace/Models/APIProvider.swift:64-72`）。另一方面，`Conversation.provider` 实际记录对话来源，实时聊天统一写 `api`，执行模型在 `selectedModelId`，cc-bridge 再用 `ccBridgeSessionName` 补一块通道状态（`MP MemoryPalace/Models/Conversation.swift:49-65`; `MP MemoryPalace/ViewModels/ConversationViewModel.swift:1924-1962,3561-3569`）。
- **差距性质**：实现更优。
- **采纳建议**：**改造搬**，目标数据模型应是四个正交概念：
  1. `ConversationOrigin`：chatgptImport / claudeImport / apiChat / sillyTavern；
  2. `WireProtocol`：openAIChatCompletions / openAIResponses / anthropicMessages / localBridge；
  3. `CredentialKind`：apiKey / oauth(providerID) / localToken / none；
  4. `ConversationModelBinding`：credentialId + modelId + 可选 channel/session binding。

  cc-bridge、Codex bridge 和未来 claude-proxy 都应是 `transport/endpoint` 差异，不再伪装成“云 provider 品牌”；ChatGPT OAuth 则是 OpenAI Responses wire + OAuth credential，不再独占一种 `ProviderType`。先加新字段和兼容读取，双写一版，再迁旧值，最后删旧分支。
- **代价档位**：周级。
- **风险与前置**：会碰 `Conversation` SwiftData schema、备份/同步文档、`selectedModelId`、Keychain account、cc session 路由和旧迁移。必须保留稳定 credential id；不要在同一次提交里顺便改 UI。

### 3. OAuth 刷新必须共享 single-flight；MP 当前实现有并发重复刷新的风险

- **OM 怎么做**：共享 `OAuthRefreshSingleFlight` 按 instance id 保存一个 in-flight `Task`，并发调用者加入同一任务（`OM src/ios/Providers/OAuthRefreshSingleFlight.swift:3-15,23-43`）。刷新失败后，`OAuthRefreshCoordinator` 重新读取当前 token，只有“持久层仍是自己失败的旧 refresh token”才删除凭据；若另一请求已经轮换成功，就保留新 token（`OM src/ios/Providers/OAuthRefreshCoordinator.swift:161-179,193-225`）。错误分类也读取结构化 HTTP status 和 OAuth `error` code，不靠宽松字符串包含（`OM src/ios/Providers/OAuthRefreshCoordinator.swift:22-58,94-129`）。
- **MP 现状**：`ProviderRouter.ensureFreshAccessToken` 只做“过期检查 → 直接 refresh → 写回”，没有按 credential id 的 in-flight 去重或 stale-token 比较（`MP MemoryPalace/Services/ChatService.swift:1142-1151`）。同一 OAuth 凭据可被主聊天和多个后台 `ProviderRouter` 调用；“两个调用同时看到过期 token”是静态可达的并发风险，但本批次未运行复现。
- **差距性质**：实现更优。
- **采纳建议**：**改造搬**。在 `Services/Auth/` 原生实现一个 actor：`validAccessToken(credentialId:)`、每 credential 一条 refresh task、成功原子写回、失败按结构化错误决定保留/清除。OAuth token 不再伪装成普通 API key 字符串；给 Keychain 使用独立 account kind（如 `oauth-token`）。第二家 OAuth 开工前先完成。
- **代价档位**：天级。
- **风险与前置**：要定义“网络失败但 access token 尚可用”的策略、注销与 refresh 并发的先后关系、以及 app 多进程/extension 是否共享 token。本报告没有验证上游是否轮换 refresh token，因此 MP 的实际登出频率是未查证，不把风险写成已发生事故。

### 4. 可执行拆法：按职责拆 `APIProvider.swift` / `ChatService.swift`，不要按品牌机械复制 OM

- **OM 怎么做**：公共面很小：`LLMProvider` 只规定普通/流式消息（`OM src/ios/Providers/LLMProvider.swift:3-20`），`AgentProvider` 规定统一的 tool/thinking/usage 事件（`OM src/ios/Providers/AgentProvider.swift:124-193`），工厂把 Kimi/xAI/OpenRouter 复用到 OpenAI 实现（`OM src/ios/Providers/LLMProviderFactory.swift:20-38,174-189,229-273`）。但 OM 也说明“有目录”不等于“没有巨石”：同一个 `OpenAIAgentProvider` 同时做 body、thinking、SSE、工具调用与 reasoning echo（`OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:58-160,265-376,930-1016`），而 `AIChatViewModel+ProviderFactory` 又重复一套构造分支（`OM src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift:20-47,61-243`）。
- **MP 现状**：`APIProvider.swift` 同时包含类型/模型/凭据（`MP MemoryPalace/Models/APIProvider.swift:3-137`）、16 个预设（`MP MemoryPalace/Models/APIProvider.swift:139-316`）、Keychain cache/CRUD/预算/收藏（`MP MemoryPalace/Models/APIProvider.swift:347-540,543-807`）、模型拉取/连接测试（`MP MemoryPalace/Models/APIProvider.swift:809-1153`）和多轮迁移（`MP MemoryPalace/Models/APIProvider.swift:1177-1459`）。`ChatService.swift` 则把 transport base（`MP MemoryPalace/Services/ChatService.swift:30-208`）、OpenAI（`:212-590`）、Anthropic（`:591-1004`）、router（`:1009-1257`）和本地 bridge（`:1258-1302`）放在一起。
- **差距性质**：实现更优。
- **采纳建议**：**改造搬**，分两步：

  **第一步，零行为拆文件：**

  ```text
  Models/Providers/
    ProviderTypes.swift          # ProviderModel / ProviderInstance / enum
    ProviderPresetCatalog.swift  # 只放内置模板
  Services/Providers/
    ProviderCredentialStore.swift# Keychain + credential CRUD
    ProviderModelService.swift   # fetch models + test connection
    ProviderMigration.swift      # 一次性迁移与 legacy decode
    ProviderRouter.swift         # 只装配，不解析协议
    Transports/
      OpenAIChatTransport.swift
      OpenAIResponsesTransport.swift
      AnthropicMessagesTransport.swift
      LocalBridgeTransport.swift
  ```

  **第二步，再换抽象：** router 依赖统一 `ChatTransport` / typed stream event，品牌模板只选择 wire/auth/capability 配置。OpenRouter、DeepSeek、Groq、xAI、SiliconFlow、DashScope、智谱、豆包、Gemini OpenAI-compatible、Moonshot、Ollama 不各复制一份 transport；只有 wire shape 真不同才建实现。
- **代价档位**：周级。
- **风险与前置**：第一步必须是机械移动并保持符号/访问级别；第二步才改行为。迁移文件是旧用户数据保险，不可因“看起来脏”删掉。OM 的双 factory 是反例，MP 应只有一个装配真值源。

### 5. `ProviderModel` 需要 capability metadata，停止用 model 名字符串推断

- **OM 怎么做**：模型类型显式保存 modality、context window、max output、reasoning 支持、interleaved reasoning field 和允许的 effort tiers（`OM src/ios/Providers/LLMTypes.swift:5-43,47-78`）。OpenRouter model API 从返回值解析输入/输出模态、上下文、最大输出和 reasoning 支持，再交给统一 enrichment（`OM src/ios/Providers/OpenRouter/OpenRouterModelsAPI.swift:43-95`）。
- **MP 现状**：`ProviderModel` 只有 credential id、model id、显示名（`MP MemoryPalace/Models/APIProvider.swift:19-23`）。图片能力靠包含 `gpt/claude/gemini/vision/...` 的字符串表判断（`MP MemoryPalace/Services/ChatService.swift:300-306`），思考强度选项同样按 `opus/o1/gpt-5/gemini` 字符串分支（`MP MemoryPalace/Views/CardFlowView.swift:2250-2271`）。这会让新模型、别名和自定义中转端点默认落入猜测路径。
- **差距性质**：能力缺失。
- **采纳建议**：**改造搬**。给 `ProviderModel` 增加可选 `ModelCapabilities`：input/output modality、tools、reasoning、reasoning wire hint、context/max output；拉模型时解析，预设可覆盖，自定义模型允许用户手工改。字段必须 optional，未知时保持当前宽松行为，不能因 catalog 没收录就禁用用户中转。
- **代价档位**：周级。
- **风险与前置**：会改持久化 JSON、picker、附件校验和请求构造。capability 是“该 endpoint 的事实”，不能把另一家聚合商对同名模型的声明当绝对真值。

### 6. thinking 不只是 UI：MP 缺的是 provider wire rule 与结构化流事件

- **OM 怎么做**：OM 把各家请求形状建模为 `ThinkingWireFormat`，区分“完全不发字段”、root/nested effort、DeepSeek sibling、Qwen dual、Anthropic adaptive/budget、Gemini budget/level 等（`OM src/ios/Providers/Thinking/ThinkingWireFormat.swift:16-103`）；resolver 采用 first-match-wins，并返回匹配规则、发出的 key、clamp 和 gate trace（`OM src/ios/Providers/Thinking/ThinkingRuleResolver.swift:100-129,173-196,323-374`）。响应侧统一成 `.thinkingDelta`、`.reasoningContent`、`.reasoningEcho` 等事件（`OM src/ios/Providers/AgentProvider.swift:124-148`），OpenAI-compatible stream 会读取 `reasoning_content`、`reasoning` 和 model 指定字段，也处理 content 内 `<think>` 前缀（`OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:265-303`）。
- **MP 现状**：OpenAI 请求只有一个通用 `reasoning_effort` 字段（`MP MemoryPalace/Services/ChatService.swift:375-383`）；流解析只消费 `delta.content` 和 `delta.tool_calls`，没有读取 reasoning 字段（`MP MemoryPalace/Services/ChatService.swift:550-585`）。Anthropic 发送侧只有 legacy `enabled + budget_tokens`（`MP MemoryPalace/Services/ChatService.swift:736-789`），接收侧的 block start/delta 只处理 tool、web source、text 和 partial JSON，没有 thinking block（`MP MemoryPalace/Services/ChatService.swift:924-962`）。MP 已有可持久化的 `.thinking` segment（`MP MemoryPalace/Models/MessageSegment.swift:7-22,86-103`），所以缺口在 provider 层，不在 UI 容器。
- **差距性质**：实现更优。
- **采纳建议**：**改造搬**，但不要复制 OM 的完整可编辑规则系统。第一版只做：`ThinkingLevel`、只读 built-in rule table、`ThinkingRequestAdapter`、typed `ChatStreamEvent.thinkingDelta/reasoningFinal`、把最终 thinking 写入现有 `MessageSegment.thinking`。第二版再考虑自定义 relay override 与 trace UI。Anthropic adaptive 与 OpenAI Responses 要作为不同 wire case，不再塞进一个 `reasoningEffort` 字符串。
- **代价档位**：周级。
- **风险与前置**：公开展示完整 chain-of-thought、保存签名/encrypted reasoning、跨模型回灌都有产品与协议风险；第一版只显示上游明确给客户端的 reasoning summary/text，并按同 provider/model 隔离 opaque echo。现有导入 thinking 与 ccThinking 数据路径不能被覆盖。

### 7. 失败分类与 opt-in 模型组降级值得学，但不能在已输出内容后盲重试

- **OM 怎么做**：`LLMError` 明确区分 retryable（网络/暂时性服务错误）与 immediate fallback（限流、无效 key、provider 拒绝）（`OM src/ios/Providers/LLMError.swift:41-74`）。网络类按 3/5/10/15/30 秒重试（`OM src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:9-78`），provider 类错误直接换组内下一模型，并更新 session binding（`OM src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:90-172,172-213`）；HTTP 200 但无文本/工具/reasoning 也会被识别为空响应再尝试下一成员（`OM src/ios/Agent/Chat/AIChatViewModel+Fallback.swift:363-435`）。Anthropic 只在建立 stream、尚未 yield 时透明重试，mid-stream 错误直接上抛，避免重复已输出内容（`OM src/ios/Providers/Anthropic/AnthropicAgentProvider.swift:205-251,395-424`）。
- **MP 现状**：router 找到一张 credential 后只选一个 concrete provider 并直接发送（`MP MemoryPalace/Services/ChatService.swift:1058-1139`）；基础错误处理把网络、HTTP 和空响应都压成字符串 `onError`（`MP MemoryPalace/Services/ChatService.swift:157-188`）。上层 `onError` 保存 partial/error 后结束本轮，没有重试或跨 provider 路由（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:2699-2715`）。
- **差距性质**：能力缺失。
- **采纳建议**：**只借思路**。先做用户显式配置的 model group：同模型不同 credential 或按用户排序的不同模型；默认仍坚持用户选中的模型。规则：认证/配额/确定性 4xx 可立即换成员；网络/5xx 在“尚未产生 token/tool call”时有限重试；产生任何可见文本或工具副作用后不得透明重放；最终错误要显示完整尝试轨迹。
- **代价档位**：周级。
- **风险与前置**：换模型会改变人格、能力、价格和 thinking 上限，必须与预算系统、capability metadata、工具幂等和 UI 提示一起设计。不能把 OpenRouter 自己的 `allow_fallbacks` 当 MP 跨 provider fallback。

### 8. Provider 配置解码要向前兼容，不能让一个未来枚举值清空全部凭据

- **OM 怎么做**：未知 raw provider type 会映射为 `.unsupported`，而不是 decode 抛错（`OM src/ios/Providers/ProviderTypes.swift:22-33`）；`ProviderInstance` 额外保存原始字符串，并在 encode 时原样写回（`OM src/ios/Providers/ProviderInstance.swift:88-130`）。
- **MP 现状**：`ProviderType` 是没有 unknown case 的直接 `Codable` enum（`MP MemoryPalace/Models/APIProvider.swift:5-10`），`APICredential` 强制 decode 该 enum（`MP MemoryPalace/Models/APIProvider.swift:108-120`）；整个 `[APICredential]` 任一元素 decode 失败时，`loadCredentials` 用 `?? []` 把全表变成空数组（`MP MemoryPalace/Models/APIProvider.swift:1162-1164`）。这是静态可确认的数据可见性风险。
- **差距性质**：实现更优。
- **采纳建议**：**直接搬思路**：自定义 decode unknown sentinel，保留 `unknownProviderTypeRaw`，UI 显示“当前版本不支持”但不删除、不重写；配置导入和同步也走同一 decoder。
- **代价档位**：小时级。
- **风险与前置**：unknown provider 必须不可发送，但仍可导出/备份；迁移不能把 unknown 自动降级成 `.openaiCompatible`，否则会向错误端点发请求。

## 已核查的额外情报

### 流式 tool-call 空名覆盖：MP 与 OM 都已有等价防御

MP 只在 `id/name` 非空时更新 accumulator（`MP MemoryPalace/Services/ChatService.swift:571-583`）；OM 也要求新分片同时带非空 id/name 才新建/覆盖，参数分片只追加到已存在项（`OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:306-340`）。这条事故不需要从 OM 再采纳修复；建议保留成回归测试对象，但本批次按红线未运行测试。

### Keychain：OM 的单条读取可作对照，但 MP 当前主故障路径已经修掉

OM 按 instance service + account 存储，读 API key 与 OAuth token 都用 `kSecMatchLimitOne`；并无批量返回 data 的查询（`OM src/ios/Providers/ProviderConfigStore.swift:3025-3085,3116-3176`）。MP 当前 `getAll()` 先批量只取 attributes，再逐 account `get()`，正面避开 `MatchLimitAll + ReturnData`（`MP MemoryPalace/Utils/KeychainStore.swift:61-84,85-117`）。我在两边相关 Keychain query 中均未见显式 `kSecAttrAccessGroup`；这只是“代码未设置”，不等于 entitlement 状态已验证。OM 对 API key/OAuth token 无条件设置 `kSecAttrSynchronizable = true`（`OM src/ios/Providers/ProviderConfigStore.swift:3037-3042,3132-3136`），MP 则由用户开关决定（`MP MemoryPalace/Utils/KeychainStore.swift:9-30`; `MP MemoryPalace/Models/APIProvider.swift:473-516`）。因此不建议用 OM 覆盖 MP 当前实现。

### OpenRouter：OM 没有解决任务书所述全部特殊性

OM 的 OpenRouter 工厂只设置归因 header 与 `useOpenRouterCompat`（`OM src/ios/Providers/LLMProviderFactory.swift:174-189`），请求侧对 Claude 只加顶层 `cache_control`（`OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:106-121`）。我检查了 OM 的 OpenRouter/OpenAI provider、agent provider 与 factory，并搜索 `provider.order/allow_fallbacks`，未找到上游 provider pinning。相反，MP 会写稳定 `x-session-id`（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:1913-1922`）、为 DeepSeek 指定官方 provider 并允许 OR fallback（`MP MemoryPalace/Services/ChatService.swift:318-322,402-405`），Claude 缓存还使用明确的 per-block 断点（`MP MemoryPalace/Services/ChatService.swift:385-400`）。

关于“OR 上 Opus 最小 4096 output token”：当前 OM 仍直接把传入 `maxTokens` 写为 `max_tokens`（`OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:106-110`），MP 也直接透传非默认 `sampling.maxTokens`（`MP MemoryPalace/Services/ChatService.swift:375-383`）；两边都未见 Opus/OR 专属下限保护。该上游约束来自任务书额外情报，本批次没有联网或运行验证，不能把 OM 当现成修复参考。

## Checked and clean

- MP 的 OpenAI-compatible tool call accumulator 已防空 id/name 覆盖；OM 是同类写法。
- MP 当前 Keychain `getAll()` 已采用“先 account、后逐条 data”的 macOS 兼容路径。
- MP 的 ChatGPT OAuth login 校验 state，并将 verifier/state/auth URL 持久化 5 分钟以恢复未完成登录（`MP MemoryPalace/Services/ChatGPTOAuth/LoginCoordinator.swift:43-80,84-143`）。
- MP 的 OpenRouter cache-friendly 路径已经包含 session pinning、官方 DeepSeek provider order 和 per-block cache breakpoint；这是本 lane 的反向优势，不应被 OM 的更泛化实现替换。

## Not verified

- 按红线未 build、未跑测试、未执行任何 OAuth 登录、Keychain、SSE、fallback 或 App Store 流程。
- 未联网核对各上游 2026-08-24 的 OAuth client 注册、第三方 app 使用许可、订阅 quota、回调 URL 或审核政策；所有“能否上线”结论均未查证。
- 未验证 OM 的 OAuth fixed-port localhost callback 在所有 iOS 网络/生命周期场景的运行表现。
- 未验证 MP 当前 ChatGPT refresh token 是否会轮换，以及重复 refresh 是否已经导致真实登出；这里只报告缺少并发协调的静态风险。
- 未验证 OpenRouter/Opus 的 4096 下限和缓存价格数据；只确认两边当前请求构造没有专属下限 guard。
- 未拆 `Voice/` 的全部 vendor 细节；它与本报告的 LLM auth/wire 主轴无直接依赖。

## §反向发现

1. **MP 的 OpenRouter 缓存路由比 OM 更贴近已经发生的真实故障。** MP 不只“打开 cache_control”，还在请求进入 router 前固定 session（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:1913-1922`），对 DeepSeek 指定官方上游（`MP MemoryPalace/Services/ChatService.swift:318-322,402-405`），并把动态上下文留在缓存断点外（`MP MemoryPalace/Services/ChatService.swift:385-400`）。OM 的已查路径只有通用 OpenRouter compat + 顶层 cache control（`OM src/ios/Providers/LLMProviderFactory.swift:174-189`; `OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:106-121`）。
2. **MP 给用户选择 API key 是否同步 iCloud，OM 是强制同步。** MP 的 `sync` 参数直接控制 `kSecAttrSynchronizable`，并可批量重写现有 key（`MP MemoryPalace/Utils/KeychainStore.swift:9-30`; `MP MemoryPalace/Models/APIProvider.swift:473-516`）；OM 每次保存 key/token 都固定写 `true`（`OM src/ios/Providers/ProviderConfigStore.swift:3037-3042,3132-3136`）。凭据同步是产品隐私选择，MP 这一点更好。
3. **MP 的未完成 ChatGPT 登录可跨 coordinator 实例恢复。** pending verifier/state/auth URL 有 TTL 持久化（`MP MemoryPalace/Services/ChatGPTOAuth/LoginCoordinator.swift:43-80,107-143`）；OM 的 Codex flow 把 verifier/state 留在一次 `login` 调用的局部变量，并在同一调用等待 callback（`OM src/ios/Providers/OpenAI/OAuth/CodexOAuthManager.swift:60-117`）。在 iOS 切后台/对象重建场景，MP 的设计更有恢复力；本批次未做运行验证。
4. **cc-bridge 是 MP 的产品优势，不是“provider 异类就该删”。** 它能走 WebSocket 本地终端 transport（`MP MemoryPalace/Models/APIProvider.swift:301-315`; `MP MemoryPalace/Services/ChatService.swift:1258-1302`），并把对话绑定到独立 session（`MP MemoryPalace/ViewModels/ConversationViewModel.swift:1924-1962`）。OM 的 provider factory 只列云端 LLM wire families（`OM src/ios/Providers/LLMProviderFactory.swift:20-38`）。应修的是抽象分层，不是牺牲这条能力。

## §不建议学

1. **不建议照着“七家 OAuth”逐家补齐。** OM 实际是多种完全不同的授权产品：OpenRouter 换永久 key、Kimi device flow、Gemini/Antigravity 还要 project onboarding；它不是一套 OAuth 模板换域名。尤其 Kimi 源码自己记录了复用第一方 client id 的接受风险与未来替换点（`OM src/ios/Providers/Kimi/OAuth/KimiOAuthManager.swift:11-43`）。没有上游准入证据前，不应为功能对齐投入。
2. **不建议直接采用 OM 的目录形状。** 它有好的协议/工厂思想，但也有重复 factory 和巨大的 provider implementation（`OM src/ios/Agent/Chat/AIChatViewModel+ProviderFactory.swift:20-243`; `OM src/ios/Providers/OpenAI/OpenAIAgentProvider.swift:58-160,412-700,930-1016`）。MP 应按 wire/auth/transport 职责拆，不能把 12 个 OpenAI-compatible 品牌复制成 12 套 SSE parser。
3. **不建议复制 OM 的 credential availability switch。** OM 工厂能创建 Antigravity OAuth provider（`OM src/ios/Providers/LLMProviderFactory.swift:276-289`），但 `ProviderInstance.computeHasAnyCredential` 的 Antigravity 分支返回 false（`OM src/ios/Providers/ProviderInstance.swift:268-298`）；这说明“实例 + credential 分轴”值得学，当前具体 switch 不能逐字搬。
4. **不建议把 OM 的 `Voice/` 目录当 LLM provider 分层模板。** OM 的 `VoiceProvider` 是独立 ASR/TTS adapter，公开的是 transcribe/synthesize 和窄 override hooks（`OM src/ios/Providers/Voice/VoiceProvider.swift:3-14,37-76`）；MP 已有自己的通话状态机与 STT/TTS 注入点（`MP MemoryPalace/Services/Voice/CallSession.swift:3-28,58-84`）。两者应保持横切协作，不应为目录对称强并入聊天 provider router。
5. **不建议改成 OM 的无条件 iCloud Keychain 同步。** MP 当前显式保留用户选择，且已修复这批任务关心的 macOS 批量读取问题；这里 OM 没有更优修复可搬。
