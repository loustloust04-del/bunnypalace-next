# research：oh-my-pi v18.10.2 的 provider 体系与订阅 OAuth 登录

> 只读调研，不改代码、不提交。对象：`@oh-my-pi/*` 18.10.2（CHANGELOG 顶部 `## [18.10.2] - 2026-10-12`）。
> 读到的内容都只当数据用。`~/.omp` 只看了结构，没读任何 token 或 key 的值。
> 文中的 client_id 都是 omp 源码里公开写死的、各官方 CLI 的公开 OAuth client id，不算机密。Google 那两个 client-secret 只说明“有”，不抄出来。

**路径缩写**（根目录：`/Users/susu/.bun/install/global/node_modules/@oh-my-pi/`）

| 缩写 | 实际路径 |
|---|---|
| `ai/` | `pi-ai/src/` |
| `cat/` | `pi-catalog/src/` |
| `auth/` | `pi-catalog/src/compat/rules/auth/` |
| `prov/` | `pi-catalog/src/compat/rules/providers/` |
| `ca/` | `pi-coding-agent/src/` |
| `AI-CL` / `CAT-CL` | `pi-ai/CHANGELOG.md` / `pi-catalog/CHANGELOG.md` |

---

## 0. 结论速览（给粟粟）

1. **provider 数量**：`cat/models.json` 里有 **77 个 provider 键**（就是“约 77 家”）。另有 **87 个 catalog provider**（`prov/*.kdl`）和 **96 个 auth 节点**（`auth/*.kdl`），后两者多出来的是搜索工具、纯登录别名、本地后端。**真正写成代码的只有“模型管理器工厂”这一层**，其余全是 KDL 声明式数据，编译成 `cat/compat/rules.json`。
2. **订阅 OAuth 的三种流程**：
   - **PKCE + 本机回环**：Anthropic、Codex、Gemini CLI、Antigravity、Devin、GitLab、OpenRouter、Stencil。
   - **设备码**：Copilot、Codex-device、Kimi Code、xAI、Factory、Muse、Kilo。
   - **自定义**：Cursor 是“浏览器 + 轮询”，Z.AI 劫持 `zcode://`，Perplexity 借用 Mac App 的会话或走邮箱 OTP。
3. **client_id 几乎全是借官方 CLI / IDE 的**，只有 OpenRouter 和 Devin 不需要 client 注册。Copilot 借的是 **OpenCode** 的 GitHub App，而不是 Copilot CLI 的。
4. **伪装最重的是 Anthropic**：
   - UA 写成 `claude-cli/<ver>`，带 Stainless 头和整套 Claude Code beta。
   - system[0] 塞计费指纹，再用 xxHash64 补 `cch` 校验。
   - system[1] 放 Claude Code 身份句，工具名前加 `_`。
   - metadata.user_id 带 device_id；被拒时自动抬版本号。

   其次是 Gemini CLI / Antigravity（假 UA，钉死 darwin/arm64）、Kimi（KimiCLI 头 + 设备指纹）、Copilot（copilot CLI 头）。**Codex 反而老实**：`originator=omp`、`User-Agent: omp/<ver>`。
5. **国内编码套餐 = API key + 专用 baseURL**。智谱 `/api/coding/paas/v4`、阿里 `coding(-intl).dashscope` 与 `token-plan.*.maas`、小米 `token-plan-{sgp,ams,cn}`、MiniMax `api.minimax(i).io/anthropic` 都是这样。只有 Kimi Code 和 Z.AI 的“Sign in”走 OAuth。
6. **App Store 可行性**：
   - **所有 API key 类 provider 和所有设备码类订阅**，纯 HTTPS 就能做，iOS 也行。
   - **借官方 client 的回环 PKCE** 在 iOS 上只能靠 WKWebView 拦截。MP 现在的 Codex 就是这么做的。但 Google 一般禁止嵌入式 WebView 做 OAuth（外部知识，没实测）。
   - **依赖本机文件或别家程序的**有 Vertex ADC、Bedrock profile、Perplexity 读 Mac App、Codex DeviceCheck 证明、本地后端，iOS 做不了或做不好。
   - **最大风险不在技术，在条款**：Anthropic / Google / Cursor 的订阅都靠冒充官方客户端才能用。上架 App 公开冒充，审核（5.2 第三方服务）和厂商封号都是实打实的风险。详见 §4、§5。

---

## 1. Provider 全表与数据结构

### 1.1 数据分三层

| 层 | 位置 | 内容 |
|---|---|---|
| **catalog 条目** | `prov/<id>.kdl` | `default-model`、`env`、`discovery`、`seed`（手写模型行），以及 compat 级联规则（thinking 格式、模态、限额）。语法见 `pi-catalog/src/compat/rules/README.md` 的 “Provider catalog grammar” 一节。例：`prov/zhipu-coding-plan.kdl:3-17`、`prov/kimi-code.kdl:3-7`。 |
| **auth 契约** | `auth/<id>.kdl` | 显示名、env 回退、登录流程（`api-key` / `oauth-code` / `device-code` / `custom hook=`）、refresh、credential 字段映射、`api-key-format`、`store-as`。语法见同一 README 的 “Auth grammar” 一节。`/login` 列表顺序由 `auth/_order.kdl:4-12` 钉死。 |
| **代码层** | 见下 | ① 模型管理器工厂（每家怎么拉 `/models`、怎么映射字段）：`cat/provider-models/descriptors.ts:97-177`。② pi-ai 侧的 `TRANSPORTS`，只有 bedrock、bedrock-mantle、cloudflare-ai-gateway、muse-code、snowflake 五家有：`ai/registry/registry.ts:17-23`。③ 自定义登录用的 hook 表：`ai/registry/hooks/*`。④ 用量探针：`ai/usage/registry.ts:30-51`。 |

- **编译**：`bun run gen:compat`（`pi-catalog/package.json:92`）把 KDL 编成 `cat/compat/rules.json`，同时生成 `auth-ids.ts` 和 `provider-ids.ts` 两个联合类型；`gen:models`（同文件 `:91`）在构建时跑 discovery，生成 `cat/models.json`。
- **models.dev 底表**：从 `https://catalog.stencil.so/models.json.zstd` 拉，定义在 `cat/provider-models/openai-compat.ts:85`。
- **编译期完整性检查**：每个 catalog provider 都必须有 auth 节点，否则过不了类型检查，见 `ai/registry/registry.ts:43-48`。
- **运行时汇总**：`PROVIDER_REGISTRY = authProviders().map(buildProviderDefinition)`（`ai/registry/registry.ts:33-35`）。`ProviderDefinition` 的字段定义在 `ai/registry/types.ts:61-95`：`login`、`refreshToken`、`storeCredentialsAs`、`callbackPort`、`pasteCodeFlow`、`prepareRequest` 等。

### 1.2 加一家要改哪些地方

| 情形 | 要改的位置 |
|---|---|
| **普通 OpenAI 兼容 + API key**（最常见） | ① 新建 `prov/<id>.kdl`：写 `default-model`、`env`、`discovery label=`，可选 `seed`。② 新建 `auth/<id>.kdl`，填 `login "api-key" { auth-url; prompt; validate "chat-completions"\|"models-endpoint"\|"anthropic-messages" }`。例：`auth/zhipu-coding-plan.kdl:1-9`、`auth/moonshot.kdl:7`。③ 有登录的话，把 id 加进 `auth/_order.kdl`。④ 在 `cat/provider-models/descriptors.ts:97+` 加一行工厂，一般复用 `createOpenAICompatibleModelManagerOptions`（`openai-compat.ts:804`）或 `openAiCompletionsDescriptor`（`openai-compat.ts:7079`）。⑤ 跑 `gen:compat` 和 `gen:models`。 |
| **标准 OAuth / 设备码** | 只写 KDL：`login "oauth-code"` 或 `"device-code"` 由 `ai/registry/engine/oauth-code.ts` 和 `ai/registry/engine/device-code.ts` 通用解释执行。特殊步骤挂 hook：`after-exchange hook=`、`headers-hook=`、`url-hook=`。 |
| **非标准** | `login "custom" hook="…"`，在 `ai/registry/oauth/<id>.ts` 写 TS。现有的：Copilot、Cursor、Alibaba×2、Xiaomi、Kilo、Perplexity、Snowflake、Cloudflare×2、openai-codex-device。 |
| **其他可选项** | 有专用请求形态，写 `TRANSPORTS` 或新的 `api` 实现（`ai/providers/*.ts`）；要读额度，在 `ai/usage/<id>.ts` 注册。 |

### 1.3 Discovery（/models）

- **通用实现**：`fetchOpenAICompatibleModels`（`cat/discovery/openai-compatible.ts:143-232`）。
  - 请求是 `GET {baseUrl}/models`，带 `Authorization: Bearer`（`:150-163`）。
  - 默认超时 10s（`:17`）。
  - 返回体容忍 `data` / `models` / `result` / `items` 几种包法，或者直接是数组（`:247-268`）。
  - 每家通过 `mapModel` 补 reasoning、模态、上下文，没给的用 KDL 规则兜底。例：智谱 `openai-compat.ts:2252-2291`；Kimi Code 还会带 `User-Agent: KimiCLI/1.0` 和 `X-Msh-Platform` 头（`openai-compat.ts:4151-4199`）。
- **`dynamic-models-authoritative #true`**：discovery 成功后整表替换 bundled 模型，例如 `prov/zhipu-coding-plan.kdl:6`。没有 key 时只用 `seed` 或 bundled 行。
- **专用 discovery**：

| provider | 端点 | 位置 |
|---|---|---|
| Codex | `/codex/models` → `/models?client_version=` | `cat/discovery/codex.ts:9,199` |
| Antigravity | `/v1internal:fetchAvailableModels` | `cat/discovery/antigravity.ts:11` |
| Gemini CLI | `/v1internal:retrieveUserQuota` | `cat/discovery/gemini-cli.ts:13` |
| Cursor | gRPC `GetUsableModels` | `cat/wire/cursor.ts:16` |
| Anthropic | 强制 `/v1/models` | `openai-compat.ts:6726` |

- **用户自定义 provider**：在 `ca/` 里通过 `models.yml` 配置，字段有 `baseUrl`、`apiKey`、`api`、`headers`、`auth: apiKey|none|oauth`，以及 `discovery.type ∈ ollama / llama.cpp / lm-studio / openai-models-list / proxy / litellm / apple-foundation-models`（`ca/config/models-config-schema-bundle.ts:316-351`）。

### 1.4 全表（按类别）

数据来自 `cat/models.json`（bundled 行里的 api 和 baseUrl）和 `cat/compat/rules.json` 的 auth / providers 两节，由脚本统计。

“鉴权”一列的写法：
- `key`：粘贴 API key（KDL 里是 `login "api-key"`）。
- `env`：只能走环境变量，没有 `/login` 项。
- 具体的登录方式见 §2。

“api”一列的缩写：`oc` = `openai-completions`（Chat Completions），`or` = `openai-responses`，`am` = `anthropic-messages`。

#### A. 一方厂商（官方 API）

| id | api | baseURL | 鉴权 |
|---|---|---|---|
| openai | or（另有 transcriptions、embeddings、decisions） | `https://api.openai.com/v1` | env `OPENAI_API_KEY` |
| anthropic | am | `https://api.anthropic.com` | 有 sk-ant 前缀的 key 就走 key，否则走 **OAuth**（§2.1） |
| google | google-generative-ai | `https://generativelanguage.googleapis.com/v1beta` | env `GEMINI_API_KEY` |
| xai | or（另有 images、tts） | `https://api.x.ai/v1` | key |
| mistral | oc | `https://api.mistral.ai/v1` | env |
| meta | or | `https://api.meta.ai/v1` | key（`MODEL_API_KEY` / `META_API_KEY`） |
| groq | oc | `https://api.groq.com/openai/v1` | env |
| cerebras | oc | `https://api.cerebras.ai/v1` | key |
| sakana | or | `https://api.sakana.ai/v1` | key |
| deepseek（国内） | oc | `https://api.deepseek.com` | key |
| moonshot（国内） | oc | `https://api.moonshot.ai/v1` | key，校验 `/v1/models`（`auth/moonshot.kdl:7`） |
| stepfun（国内） | oc | `https://api.stepfun.ai/v1` | key |
| qianfan（百度） | oc | `https://qianfan.baidubce.com/v2` | key |
| minimax | am | `https://api.minimax.io/anthropic` | env（`auth/minimax.kdl` 没有 login） |
| minimax-cn | am | `https://api.minimaxi.com/anthropic` | 只出现在 models.json，没有 auth 或 provider 节点（遗留行） |
| xiaomi | oc | `https://api.xiaomimimo.com/v1` | custom：同一个入口收按量 key 和 `tp-` key，按 SGP→AMS→CN 顺序回退探测（`ai/registry/oauth/xiaomi.ts:17-36,45-61`） |
| apple | 本机 Foundation Models | — | 无（`allows-missing-api-key`，`auth/apple.kdl:3`） |

#### B. 云平台（企业鉴权）

| id | api | baseURL | 鉴权 |
|---|---|---|---|
| amazon-bedrock | bedrock-converse-stream | `https://bedrock-runtime.us-east-1.amazonaws.com` | env hook `aws-bedrock`：AWS 凭据链，可以是 profile、IAM、IRSA 或 bearer（`ai/registry/hooks/env.ts:29-30`） |
| bedrock-mantle | or | `https://bedrock-mantle.{region}.api.aws/openai/v1` | `AWS_BEARER_TOKEN_BEDROCK` |
| azure | azure-openai-responses | 用户自填 | `AZURE_OPENAI_API_KEY` |
| google-vertex | am / google-vertex / oc | `https://{location}-aiplatform.googleapis.com/v1/projects/{project}/…` | `GOOGLE_CLOUD_API_KEY`，或 **gcloud ADC 文件**（`ai/registry/hooks/env.ts:33-38`，`ai/providers/google-auth.ts:8-9,70-76`） |
| snowflake | am + oc | `https://<account>/api/v2/cortex(/v1)` | custom：PAT 加账户 URL |
| cloudflare-workers-ai | workers-ai-systemone | `https://api.cloudflare.com/client/v4/accounts/<account>/ai/run` | custom：API token 加 account |
| cloudflare-ai-gateway | am + oc | `https://gateway.ai.cloudflare.com/v1/<account>/<gateway>/{anthropic,compat}` | custom；用 `cf-aig-authorization` 头（`ai/providers/anthropic.ts:463-471`） |

#### C. 聚合商、网关、推理托管（OpenAI 兼容 + key）

| id | api | baseURL |
|---|---|---|
| openrouter | openrouter（另有 images、video、rerank、embeddings） | `https://openrouter.ai/api/v1`；鉴权是 **OAuth PKCE 换出永久 key**（§2.12），也可以直接粘 `sk-or-` |
| vercel-ai-gateway | am | `https://ai-gateway.vercel.sh` |
| kilo | oc | `https://api.kilo.ai/api/gateway`（custom 登录：设备授权 `https://api.kilo.ai/api/device-auth`，`ai/registry/oauth/kilo.ts:4`） |
| zenmux | oc + am | `https://zenmux.ai/api/v1`、`/api/anthropic` |
| nanogpt | oc | `https://nano-gpt.com/api/v1` |
| aimlapi | oc | `https://api.aimlapi.com/v1`（env） |
| opencode-zen | oc / am / or / google | `https://opencode.ai/zen(/v1)` |
| commandcode | oc / or / am | `https://api.commandcode.ai/provider(/v1)` |
| together | oc | `https://api.together.xyz/v1` |
| fireworks | oc | `https://api.fireworks.ai/inference/v1` |
| deepinfra | oc | `https://api.deepinfra.com/v1/openai` |
| novita | oc | `https://api.novita.ai/openai/v1` |
| nvidia | oc | `https://integrate.api.nvidia.com/v1` |
| huggingface | oc | `https://router.huggingface.co/v1` |
| baseten | oc | `https://inference.baseten.co/v1` |
| coreweave | oc | `https://api.inference.wandb.ai/v1` |
| gmi-cloud | oc | `https://api.gmi-serving.com/v1` |
| venice | oc | `https://api.venice.ai/api/v1` |
| siliconflow / siliconflow-cn | oc | `https://api.siliconflow.com/v1` / `https://api.siliconflow.cn/v1`（`openai-compat.ts:2139-2142`） |
| singularityapi-dev / -tech | oc | `https://api.singularityapi.{dev,tech}/v1`（`cat/wire/singularityapi.ts:10-11`） |
| aiand / abliteration / yolo-auto / helmcode / coralbricks | oc / or | `api.aiand.com/v1`、`api.abliteration.ai/v1`、`yolo-auto.com/v1`、`api.helmcode.com/v1`、`inference.coralbricks.ai/v1` |
| typesafe | typesafe（专有协议） | `https://api.typesafe.ai` |
| litellm | oc | 自建，默认 `http://localhost:4000/v1` |

以上鉴权都是 key（`login "api-key"`）。

#### D. 编码套餐 / token plan（订阅，但鉴权是 key）

见 §3。包括：zhipu-coding-plan、zai、alibaba-coding-plan、alibaba-token-plan、xiaomi-token-plan-{sgp,ams,cn}、minimax-code、minimax-code-cn、umans、opencode-go、cline-pass、firepass、synthetic、wafer-serverless、charm-hyper、qwen-portal。

#### E. 订阅 OAuth

见 §2。包括：anthropic、openai-codex（+ openai-codex-device）、github-copilot、google-gemini-cli、google-antigravity、cursor、devin、factory-droid、gitlab-duo、gitlab-duo-agent、xai-oauth、muse-code、kimi-code、zai-coding-plan（登录别名，凭据存到 `zai` 名下）、perplexity、stencil（omp 自家服务，不是模型 provider）。

#### F. 本地后端

| id | 默认地址 | 鉴权 |
|---|---|---|
| ollama | `http://127.0.0.1:11434/v1`（`openai-compat.ts:568`） | 可空（`auth/ollama.kdl:7` 写着 `empty-fallback ""`） |
| lm-studio | `http://127.0.0.1:1234/v1`（`openai-compat.ts:4310`） | 可空 |
| llama.cpp | `http://127.0.0.1:8080`（`ca/config/model-registry.ts:1651`） | 可空 |
| vllm | 用 `VLLM_BASE_URL` 配 | 可空 |
| local | `local://inference`，进程内推理 | 无 |
| ollama-cloud | `https://ollama.com`（ollama-chat 协议） | key；不是本地，但跟 ollama 同协议 |

#### G. 非模型（搜索 / 工具凭据）

web、exa、kagi、tavily、parallel 这几家只有 auth 节点，没有模型。

---

## 2. 订阅 OAuth / 账号登录逐家拆解

KDL 声明的流程由两个通用引擎执行：`ai/registry/engine/oauth-code.ts`（回调服务器、手动粘贴、`paste-key` 短路）和 `ai/registry/engine/device-code.ts`。

**存储**：
- 凭据存在 `~/.omp/agent/agent.db` 的 `auth_credentials` 表，字段为 `provider`、`credential_type`、`data` 明文 JSON、`disabled_cause`、`identity_key`（`ai/auth/sqlite-credential-store.ts:780-790`）。文件权限 0600。本机现有两行：`kimi-code|oauth` 和 `openai-codex|oauth`，只看了计数，没读值。
- 同一 provider 支持**多账号池**，按 `identity_key` 区分，支持轮换（§4）。
- `api-key-format "structured"` 的 provider，发请求时把整份凭据序列化成 JSON 当 apiKey 传，里面有 token、projectId、enterpriseUrl 等（`ai/registry/oauth/index.ts:139-153`）。

### 2.1 Anthropic（Claude Pro/Max）

**登录**（`auth/anthropic.kdl:6-34`）

| 项 | 值 |
|---|---|
| 流程 | PKCE + 本机回环 |
| authorize | `https://claude.ai/oauth/authorize`，带 `code=true` |
| 回调 | `localhost:54545/callback`，端口占用可换（portFallback） |
| 兜底 | 浏览器连不回本机时，粘最终跳转 URL 或 code |
| token 交换 | `https://api.anthropic.com/v1/oauth/token`，JSON body，额外带 `state` |
| client_id | **借 Claude Code 官方公开 client**，base64 存放（`:7-8`），解码是 `9d1c250a-…` |
| scope | `org:create_api_key`、`user:profile`、`user:inference`、`user:sessions:claude_code`、`user:mcp_servers`、`user:file_upload`（`:13-14`）。注释写明：直接推理必须走 claude.ai 授权端点；platform 端点只发 console token |

**身份补全**：after-exchange hook 调 `https://api.anthropic.com/api/claude_cli/bootstrap?entrypoint=cli&model=claude-opus-4-8`，带 `User-Agent: claude-code/<ver>` 和 `anthropic-beta: oauth-2025-04-20`，取 account/org（`ai/registry/oauth/anthropic.ts:15-16,47-86`）。

**刷新**（`auth/anthropic.kdl:35-53`）
- 同一个 token URL，额外带 `anthropic-beta: oauth-2025-04-20` 和 `User-Agent: anthropic-sdk-typescript/{claude_code_sdk_version} userOAuthProvider`。注释说这是照 Claude Code 刷新时的行为。
- 提前 5 分钟（skew 300000ms）刷新。
- **授权家族有效期约 30 天**：rotation 不会延长，到期后刷新会返回 `invalid_grant`，只能重新登录（`ai/registry/oauth/anthropic-constants.ts:1-12`）。



**请求时的客户端伪装**：判定条件是 access token 含 `sk-ant-oat`（`ai/utils/anthropic-auth.ts:42-44`）。订阅号发请求时 omp 把自己装成官方 Claude Code CLI，涉及点（只列位置，不展开具体算法）：

| 项 | 说明 | 位置 |
|---|---|---|
| 头部身份 | `User-Agent: claude-cli/<ver> (external, cli)`、`x-app: cli`、`anthropic-dangerous-direct-browser-access: true`、整套 `X-Stainless-*`（SDK 版本 0.112.1、runtime node v26.3.0），可选 `X-Claude-Code-Session-Id` | `ai/providers/anthropic.ts:474-493`、`:807-816`；版本常量在 `ai/providers/claude-code-fingerprint.ts:15-37` |
| beta 组合 | 订阅号默认带一大串 Claude Code 的 beta（`claude-code-20250219`、`oauth-2025-04-20`、`interleaved-thinking`、`context-management`、`prompt-caching-scope`、`mid-conversation-system` 等） | `anthropic.ts:232-258` |
| system 块 | system[0] 放一个 `x-anthropic-billing-header:` 计费指纹块，system[1] 放 Claude Code 身份句（`claudeCodeSystemInstruction`），随后才是用户的 system | `anthropic.ts:4176-4218`；身份句常量 `claude-code-fingerprint.ts:71-72` |
| 计费校验 | 发出前对请求体做一次校验，把 `cch` 占位符替换成算出来的值（`wrapFetchForCch`） | `anthropic.ts:853-930` |
| 工具名 | 订阅号请求给自定义工具名加 `_` 前缀，内置工具（web_search / code_execution / text_editor / computer）不加 | `ai/providers/anthropic-identity.ts:117-135` |
| metadata user_id | OAuth 请求把 user_id 塞成带 device_id / session_id 的 JSON（device_id 由安装 id + account 派生） | `anthropic-identity.ts:43-115` |
| 版本自愈 | 服务端回 `claude_code_version_too_old` 时，自动抬到服务端要求的版本号再重试 | `claude-code-fingerprint.ts:59-67` |
| 1M 上下文 | 订阅号不带 `context-1m` beta（订阅无长上下文额度，带了会被 429），自动退回 200k（`AI-CL:1239`） |

用量：`GET {api}/api/oauth/usage`，带 `oauth-2025-04-20` beta；额度、extra-usage（USD spend）都从这里读（`ai/usage/claude.ts:648-690`，`ai/usage/claude-api.ts:4-35`）。

### 2.2 OpenAI Codex（ChatGPT Plus/Pro）

登录（`auth/openai-codex.kdl:4-24`，`ai/registry/oauth/openai-codex.ts:12-205`）

| 项 | 值 |
|---|---|
| 流程 | PKCE + 本机回环，端口 1455 不许回退（`:16`，注释说 OpenAI 只允许这个精确 URI） |
| client_id | 借 Codex CLI 官方公开 client `app_EMoamEEZ73f0CkXaXp7hrann`（`:5`，`openai-codex.ts:12`） |
| authorize | `https://auth.openai.com/oauth/authorize`，额外带 `id_token_add_organizations=true`、`codex_cli_simplified_flow=true`、`originator=omp` |
| token | `https://auth.openai.com/oauth/token`，form body |
| scope | `openid profile email offline_access api.connectors.read api.connectors.invoke` |
| 身份 | 从 access/id token 的 JWT claim `https://api.openai.com/auth` 取 `chatgpt_account_id`、`chatgpt_plan_type`、residency（`openai-codex.ts:28-73`，`cat/wire/codex.ts:78-120`）；after-exchange hook `openai-codex-profile` |

设备码分支（`openai-codex-device`，`auth/openai-codex-device.kdl`，`openai-codex.ts:213-302`）：`https://auth.openai.com/api/accounts/deviceauth/usercode` 发码、`/token` 轮询，`store-as "openai-codex"`。端口 1455 不可用或回环 403 时用。

请求后端：`https://chatgpt.com/backend-api`（`cat/wire/codex.ts:5`），协议 `openai-codex-responses`。头部（`ai/providers/openai-codex-responses.ts:4866-4911`、`cat/wire/codex.ts:19-72`）：
- `originator: omp`、`User-Agent: omp/<ver>`（`cat/wire/codex.ts:54`，`pi-utils/src/dirs.ts:37`）——这里 omp 承认自己是 omp，不冒充 Codex。
- `version: <CODEX_CLIENT_VERSION>`（当前钉 `0.159.0`，`cat/wire/codex.ts:17`）——后端按它 gate 模型可见性。
- `chatgpt-account-id`、`x-codex-routing-hint`、`OpenAI-Beta: responses=experimental`，region-pinned 工作区自动补 `x-openai-internal-codex-residency`。
- DeviceCheck 证明 `x-oai-attestation`：仅 macOS/arm64 通过原生模块生成，别的平台留空（`ai/providers/openai-codex-attestation.ts:11-19`，`ca/live/attestation.ts:82-91`，bundle id `com.openai.codex`）。

用量：`{base}/wham/usage`（`ai/usage/openai-codex.ts` 常量 `CODEX_USAGE_PATH`）。

> MP 现状：`MemoryPalace/Services/ChatGPTOAuth/` 已实现这套，redirect `http://localhost:1455/auth/callback`，`originator=codex_cli_rs`（`OAuthConfig.swift:20-37`），mac 用 NWListener 收回调、iOS 用 WKWebView 拦截（`LoginCoordinator.swift`）。可直接对照升级。

### 2.3 GitHub Copilot

登录（`auth/github-copilot.kdl:4` custom，实现 `ai/registry/oauth/github-copilot.ts`）
- 设备码，公网 github.com 用 OpenCode 的 GitHub App `Ov23li8tweQw6odWQebz`，scope 只 `read:user`（`:34,46`）；企业实例用 Copilot CLI 的 `Ov23ctDVkRmgkPke0Mmm`（`:35,43-45`）。
- `https://<domain>/login/device/code` 发码、`/login/oauth/access_token` 轮询（`:91-92`）。
- token 长期有效，不做 JWT 交换，refresh 原样返回（`:233-247`）。
- 登录后调 `{api}/models/<id>/policy` 把 Claude、Grok 等逐个 enable（`:263-272,298,388`）。
- `api-key-format "structured"`：凭据序列化带 enterpriseUrl、apiEndpoint。

请求头伪装成 Copilot CLI（`cat/wire/github-copilot.ts:9-55`）：`User-Agent: copilot/1.0.82`、`Editor-Version: copilot/1.0.82`、`Copilot-Integration-Id: copilot-developer-cli`、`X-GitHub-Api-Version: 2026-08-01`。聊天默认 `copilot-chat` id，被拒再退 CLI id。用量：`https://api.github.com/copilot_internal/user`（`ai/usage/github-copilot.ts:186`）。

### 2.4 Google Gemini CLI（Cloud Code Assist）

登录（`auth/google-gemini-cli.kdl:3-24`）
- PKCE + 回环 `127.0.0.1:8085/oauth2callback`。
- client_id / client_secret 借 Gemini CLI 官方公开凭据，base64 存（`:4-5`）。
- authorize `https://accounts.google.com/o/oauth2/v2/auth`（`access_type=offline`、`prompt=consent`）；token `https://oauth2.googleapis.com/token`。
- scope：`cloud-platform`、`userinfo.email`、`userinfo.profile`。
- after-exchange hook `google-gemini-cli-project`：`/v1internal:loadCodeAssist` + `onboardUser` 拿 project（`ai/registry/oauth/google-gemini-cli.ts:106-229`）。付费 Standard 层需 `GOOGLE_CLOUD_PROJECT`，免费层 `free-tier`。
- `refresh { require "projectId" }`，`api-key-format "structured"`。

请求头伪装成 Gemini CLI（`cat/wire/gemini-headers.ts:8-18`）：`User-Agent: GeminiCLI/<ver>/<model> (platform; arch; terminal)`（默认 0.46.0），`Client-Metadata: ideType=IDE_UNSPECIFIED,…,pluginType=GEMINI`。用量：`/v1internal:retrieveUserQuota`。

### 2.5 Google Antigravity（Gemini 3 / Claude / GPT-OSS）

登录（`auth/google-antigravity.kdl:3-26`）
- 跟 Gemini CLI 同构，但用另一套 Google OAuth 凭据（client_id + secret，base64，`:5-6`），回环 `127.0.0.1:51121/oauth-callback`。
- scope 多 `cclog`、`experimentsandconfigs`。
- hook `google-antigravity-project`：`https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` + `onboardUser`，tier `free-tier`（`ai/registry/oauth/google-antigravity.ts:13-24,275-286`）。

请求头伪装成 Antigravity 客户端（`cat/wire/gemini-headers.ts:111-119`）：`User-Agent: antigravity/hub/<ver> (aidev_client; os_type=darwin; arch=arm64; cl=963137146)`——os/arch 钉死 darwin/arm64，版本从官方更新 manifest 拉（默认 2.19.1）。后端按版本 gate 新模型（`CAT-CL:895`）。用量：`/v1internal:retrieveUserQuotaSummary`。

### 2.6 Cursor

登录（`auth/cursor.kdl:3` custom，`ai/registry/oauth/cursor.ts`）
- 浏览器 + 轮询：生成 PKCE，开 `https://cursor.com/loginDeepControl?challenge=&uuid=&mode=login&redirectTarget=cli`，轮询 `https://api2.cursor.sh/auth/poll?uuid=&verifier=`（`:7-8,28-54`）。
- client_id `KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB`（Cursor IDE 续期 client，`:11`）。
- refresh `https://api2.cursor.sh/oauth/token`，只回 access、复用旧 refresh（`:123-157`）。

请求：gRPC/Connect，后端 `https://api2.cursor.sh`，路径 `/agent.v1.AgentService/Run(SSE)`，头 `x-cursor-client-version: cli-2026.09.02-c22c1a3`、`x-ghost-mode: true`、`connect-protocol-version: 1`（`cat/wire/cursor.ts:11-30`，`ai/providers/cursor.ts:1274-1277`）。用量：`https://cursor.com/api/usage-summary`。

### 2.7 Devin

登录（`auth/devin.kdl:3-27`）：PKCE + 回环 `127.0.0.1:59653/callback`，state uuid。不需注册 client（authorize `https://app.devin.ai/auth/cli/continue`，token `https://api.devin.ai/auth/cli/token`，自定义 body 只带 code + verifier）。token 用 JWT exp 兜底一年。后端 `https://server.codeium.com`，协议 `devin-agent`。

### 2.8 Factory Droid

登录（`auth/factory-droid.kdl:5-27`）：设备码，client 是 WorkOS 公开 client `client_01HNM792M5G5G1A2THWPXKFMXB`，device `https://api.workos.com/user_management/authorize/device`、token `.../authenticate`。身份从 JWT claim 取（email、sub、`external_org_id`）。hook `factory-droid-region` 按 org 定区域。后端 `https://api.factory.ai`，协议 `factory-droid-agent`。用量：`{base}/api/billing/limits`。

### 2.9 GitLab Duo（两个）

- `gitlab-duo`（`auth/gitlab-duo.kdl`）：PKCE + 回环 `localhost:8080/callback`，client 是 omp 注册的公开 client（可被 `GITLAB_CLIENT_ID` + `GITLAB_REDIRECT_URI` 覆盖；GitLab 拒绝时用户自建 OAuth app）。authorize `https://gitlab.com/oauth/authorize`，scope `api`。也支持 PAT（`GITLAB_TOKEN`）。后端 `https://cloud.gitlab.com/ai/v1/proxy/{anthropic,openai}`。
- `gitlab-duo-agent`（`auth/gitlab-duo-agent.kdl`）：借 GitLab 官方 VS Code 扩展的 client `36f2a70…`，redirect `vscode://gitlab.gitlab-workflow/authentication`，manual-only（从浏览器/VS Code 复制回调 URL 粘回）。

### 2.10 xAI Grok OAuth（SuperGrok / X Premium+）

登录（`auth/xai-oauth.kdl:5-24`，注释：设备授权改编自 NousResearch/hermes-agent）：设备码，client `b1a00492-…`，device `https://auth.x.ai/oauth2/device/code`，token URL 由 hook `xai-token-endpoint` 给，userinfo `https://auth.x.ai/oauth2/userinfo`。scope `openid profile email offline_access grok-cli:access api:access`。`oauth-token-env "XAI_OAUTH_TOKEN"`。后端 `https://api.x.ai/v1`（`openai-responses`）。

### 2.11 Kimi Code

登录（`auth/kimi-code.kdl:3-17`）：设备码，client `17e5f671-…`，base `https://auth.kimi.com`，device `/api/oauth/device_authorization`、token `/api/oauth/token`，headers-hook `kimi-fingerprint`。账号 id 从 JWT claim `user_id|sub` 取。
设备指纹（`ai/registry/oauth/kimi.ts:61-72`）：`User-Agent: KimiCLI/<ver>`、`X-Msh-Platform: kimi_cli`、`X-Msh-Version/-Device-Name/-Device-Model/-Os-Version/-Device-Id`。device id 持久化在 `~/.omp/agent/kimi-device-id`（本机确有此文件）。后端 `https://api.kimi.com/coding/v1`。用量：`{base}/usages`。

### 2.12 OpenRouter（OAuth 换永久 key）

登录（`auth/openrouter.kdl:3-28`）：无 client 注册，PKCE S256 是唯一凭证，state 禁用。authorize `https://openrouter.ai/auth`，token `https://openrouter.ai/api/v1/auth/keys`（自定义 body：code + verifier）。换出来的 `key` 当永久 API key 存（`result "api-key"`，`expires never`）。也可直接粘 `sk-or-` key（`paste-key`，校验 `/auth/key`）。

### 2.13 Z.AI Coding Plan（Sign in）

登录（`auth/zai-coding-plan.kdl:3-32`）：`oauth-code` 但无 PKCE，client `client_P8X5CMWmlaRO9gyO-KSqtg`。坑（注释 `:7-11`）：Z.AI 服务端已拒绝所有回环 redirect_uri（issue #10745），只有 ZCode 桌面端的 `zcode://zai-auth/callback` scheme 还能过。omp 在支持的本机桌面临时接管这个 scheme 再还原（`native-scheme=#true, manual-only=#true`）。token `https://zcode.z.ai/api/v1/oauth/token`。after-exchange hook `zai-mint-key`：用 OAuth token 调 Z.AI 业务 API 换出 49 字符永久 `id.secret` key（`ai/registry/oauth/zai.ts:142-204`），`store-as "zai"`、`refresh "none"`。
> 对 iOS 几乎不可行（依赖劫持本机 URL scheme）。普通 Z.AI 走 key（§3）。

### 2.14 Perplexity（Pro/Max）

登录（`auth/perplexity.kdl` custom，`ai/registry/oauth/perplexity.ts`）三条路：① 读旧版 Mac App `ai.perplexity.mac` 会话（`defaults read ai.perplexity.mac authToken`，`:74-79`）——仅 macOS；② host 托管浏览器 SSO；③ 邮箱 OTP（`https://www.perplexity.ai/api/auth/{csrf,signin-email,signin-otp,totp/...}`，`:122-222`）。伪装成 `Perplexity/641 CFNetwork/… Darwin/…`。

### 2.15 Stencil（omp 自家服务）

`auth/stencil.kdl`：标准 PKCE，client `omp`，issuer `auth.stencil.so`。不是模型 provider，是 omp 托管服务的账号。列出仅为完整。

---

## 3. 国内编码套餐 / token plan 怎么接

结论：全是 "key + 专用 baseURL"，登录即粘 key + `/models` 或 chat 校验。只有 Kimi Code（§2.11）和 Z.AI Sign-in（§2.13）走 OAuth。

| provider | baseURL | 登录 | 要点 |
|---|---|---|---|
| zhipu-coding-plan | `https://open.bigmodel.cn/api/coding/paas/v4` | key，校验 chat（`glm-5.1`） | `auth/zhipu-coding-plan.kdl`；key 形如 `<id>.<secret>`；thinking 格式 `zai` |
| zai | `https://api.z.ai/api/coding/paas/v4`（+ `/api/anthropic`） | key，校验 chat（`glm-5.2`） | `auth/zai.kdl` |
| alibaba-coding-plan | 国际 `coding-intl.dashscope.aliyuncs.com/v1` / 国内 `coding.dashscope.aliyuncs.com/v1` | custom：先选区再粘 key | `ai/registry/oauth/alibaba-coding-plan.ts:5-48`；`api-key-format structured` |
| alibaba-token-plan（QwenCloud） | 国际 `token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` / 国内 `token-plan.cn-beijing.maas…` | custom：选区 → 粘 key → 可选粘 Cookie 开额度上报 | `ai/registry/oauth/alibaba-token-plan.ts:60-121`；区域错了会 401，区域存进凭据 |
| xiaomi-token-plan-{sgp,ams,cn} | `token-plan-{sgp,ams,cn}.xiaomimimo.com/v1` | key，校验 chat（`mimo-v2.5`） | 三个独立 provider；统一入口 `xiaomi` 自动探区 |
| minimax-code / -cn | `https://api.minimax{,i}.io/anthropic` + `/v1` | key，校验 anthropic-messages（`MiniMax-M3`） | 国际 / 国内两套 |
| umans | `https://api.code.umans.ai` | key，校验 anthropic-messages（`umans-coder`） | 用量 `{base}/v1/usage` |
| opencode-go | `https://opencode.ai/zen/go(/v1)` | key | 用量 `{base}/v1/usage` |
| cline-pass | `https://api.cline.bot/api/v1` | key，校验身份路由 `/users/me`（不耗额度） | `auth/cline-pass.kdl:7-10` |
| firepass | `https://api.fireworks.ai/inference/v1` | key | Fireworks 订阅 |
| synthetic | `https://api.synthetic.new/openai/v1` | key | 用量 `/v2/quotas` |
| wafer-serverless | `https://pass.wafer.ai/v1` | key | — |
| qwen-portal | `https://portal.qwen.ai/v1` | key（Qwen OAuth token 或 API key），校验 chat（`coder-model`） | `auth/qwen-portal.kdl` |
| charm-hyper | `https://hyper.charm.land/v1` | key | `cat/wire/charm-hyper.ts:5` |

MP 要接这类：复用现有「OpenAI 兼容 key 预设」框架即可，baseURL 写死、一个 key 字段，最多加个"校验按钮"打 `/models`。阿里 token-plan 的 Cookie 额度上报可跳过。

---

## 4. 风险（来自代码注释 / CHANGELOG）

1. Anthropic 授权家族 30 天硬到期：rotation 不延长，到期只能重新登录（`anthropic-constants.ts:1-12`）。
2. 各家按"客户端版本"gate 模型，太旧会少模型甚至被拒：Codex `0.159.0`（`cat/wire/codex.ts:11-17`）；Anthropic `claude_code_version_too_old` 会自愈抬版本（`claude-code-fingerprint.ts:59-67`）；Antigravity 按 UA 版本（`CAT-CL:895`）；Cursor 版本号。
3. 区域封锁：Anthropic / Codex token 端点在某些出口回 `403 Request not allowed` 并禁用凭据（`AI-CL:940-941`）；Codex 企业工作区 region-pinned，不声明 residency 会 401（`cat/wire/codex.ts:91-120`）。
4. 403 / 429 处理：omp 对 403（权限/模型策略拒绝）和 usage-limit 做账号轮换而非直接失败，被拒账号软封 60s 后复验（`AI-CL:1337`）；账号被自动禁用会记 `disabled_cause` 并告警（`AI-CL:434`）。说明被厂商识别时表现是"该账号被限/被拒"，omp 的对策是多账号池 + 轮换。
5. Z.AI 回环 redirect 被服务端全面拒绝（issue #10745），只剩桌面 scheme（`auth/zai-coding-plan.kdl:7-11`）——厂商主动收紧第三方客户端。
6. GitLab / Copilot 的 client 漂移：注册 redirect 一变官方 client 就失效，留了用户自建 OAuth app 的口子（`auth/gitlab-duo.kdl:5-11`、`github-copilot.kdl:3-12`）。
7. 代码/CHANGELOG 里没有"用了会封号"的明确警告文字；但整套设计（版本自愈、多账号轮换、区域声明、client 漂移应对）本身就是在和厂商的第三方客户端检测长期拉锯的证据。README 只把这些列为"需要订阅"，未谈合规。

---

## 5. 对"上架 App Store 的原生 Swift 客户端"的可行性

### 5.1 技术上 iOS 能做（纯 HTTPS + ASWebAuthenticationSession / 粘贴）

- 全部 API key 类 provider（§A/B 的 key 部分、§C 聚合商、§D 编码套餐）：baseURL + Bearer，MP 现有 17 家预设框架直接扩。推荐优先做，尤其国内编码套餐。
- 设备码类订阅：Copilot、xAI、Factory、Muse、Kimi Code、Codex-device。设备码不依赖回环，iOS 最干净。
- OpenRouter OAuth：无 client 注册、PKCE、换永久 key，`ASWebAuthenticationSession` 可做。
- Codex / Anthropic 回环 PKCE：iOS 无本机 HTTP 监听，靠 WKWebView 拦 redirect（MP 现已这么做）。Anthropic 还有"粘贴 code"兜底，适配 iOS 更稳。但见 5.3 条款风险。

### 5.2 iOS 做不了 / 做不好（依赖本机 CLI / 别家程序 / 原生能力）

- Vertex ADC、Bedrock profile/IRSA：读 `~/.config/gcloud/…` 和 AWS 凭据链，iOS 无（`ai/registry/hooks/env.ts`）。
- Perplexity 借 Mac App 会话：`defaults read ai.perplexity.mac`，仅 macOS（`perplexity.ts:74-79`）。邮箱 OTP 路可做但要自己扛 CSRF/TOTP。
- Codex DeviceCheck 证明：omp 只在 macOS/arm64 生成，别处留空仍可用（`attestation.ts:82-91`）——不是硬阻塞。
- 本地后端（ollama/lm-studio/llama.cpp/vllm/local）：指向 `127.0.0.1`，iOS 无意义。
- Z.AI Sign-in：劫持本机 `zcode://` scheme，iOS 不可行；用 Z.AI key 代替。
- Cursor / Gemini CLI / Antigravity：技术上 HTTPS 能打，但重度冒充官方客户端，且 Google 一般禁止嵌入式 WebView OAuth（外部知识，未实测）。

### 5.3 上架的真正拦路虎是条款，不是技术

omp 能用这些订阅，核心手段是把请求伪装成官方客户端：Anthropic 装 Claude Code（UA、Stainless 头、system 身份句、计费指纹、工具名前缀、版本自愈）、Copilot 装 copilot CLI、Gemini/Antigravity 装对应 CLI（钉死 darwin/arm64 UA）、Cursor 装 Cursor CLI、Kimi 装 KimiCLI。借的 client_id 也都是官方 CLI/IDE 的。

对要过审、公开分发的 App：
- App Store 审核：Guideline 5.2（知识产权 / 未授权使用第三方服务）与 2.3（冒充）。公开冒充官方客户端访问订阅后端很可能被拒。
- 厂商封号：§4 的版本 gate、区域检测、client 漂移、Z.AI 封回环都表明厂商在持续识别第三方客户端；一旦识别，用户订阅账号可能被限/封（omp 用多账号轮换硬扛，个人 App 用户扛不住）。
- 相对安全子集：① 用户自带 API key 的所有 provider；② OpenRouter / 各编码套餐 key；③ 对订阅 OAuth 最多保留 Codex / Anthropic（MP 已有、用户自己订阅、做成"自担风险"开关），且老实发 UA、不要去抄计费指纹/工具前缀那套——那套只增加被判定为伪造客户端的面，对普通聊天 App 也非必需（它为跑 Claude Code agent 流程）。

### 5.4 给 MP 的落地建议（排序）

1. 扩 key 预设：把 §3 的国内编码套餐 + §C 主要聚合商做成预设（baseURL 写死 + key + 可选 `/models` 校验），复用现有 17 家框架。收益大、零条款风险。
2. OpenRouter OAuth：一个按钮换永久 key，体验好、风险低。
3. 设备码订阅（Copilot / Kimi Code / xAI / Factory）：iOS 友好，按需加。
4. Codex / Anthropic OAuth：保留并完善现有实现，做成显式"订阅登录（实验/自担风险）"，只带必要头，不复刻计费指纹体系。
5. 放弃：Vertex ADC、Bedrock profile、Perplexity Mac 会话、Z.AI Sign-in、本地后端（iOS 端）、Cursor/Gemini CLI（冒充过重）。

### 5.5 加 provider 的数据结构值得借鉴

omp 的"KDL 声明 + 极少代码"很适合 MP：每家 provider 做成一份声明（id、名字、baseURL、api 类型、鉴权方式、discovery 开关、校验方式），只有要特殊请求形态的才写代码。MP 可把预设表从"17 家硬编码"升级成一份可扩展声明表（JSON/Swift 数据），discovery 统一走 `GET /models`（容忍 data/models/result 包法，见 §1.3），新增一家就加一条数据。
