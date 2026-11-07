# magpie 的 provider 预设与订阅登录：调研

> 2026-10-15，只读调研。源码在 `/Users/susu/Desktop/susu-project/magpie`，HEAD `a65cf52`。
> 下文路径都相对 magpie 仓库根目录；`MP:` 开头的是记忆花园 backend-3 工位里的文件。
> 和 `docs/research-magpie.md`（09-24，讲网关、用量、agent 接线）、`docs/research-model-compat/`（10-15，讲模型兼容）不重复，本篇只讲两件事：**预设 provider** 和 **订阅登录**。

---

## 0. 结论速览

1. **预设就是一张静态表**：`internal/provider/presets.go:102` 的 `var presets = []PresetDef{…}`，一共约 60 项。每项只填三个端点（Chat / Responses / Anthropic）、models.dev 的 catalog id、拿 key 的链接，以及可选的 Regions（区域或套餐变体，切换时整组端点一起换）。**所有预设都是 API key 鉴权**；订阅登录完全是另一套（`Accounts()` / `StartSignIn`），不进预设表。
2. **订阅登录有 4 种做法**：
   - (a) 自己跑 PKCE，回调落在本机回环地址：ChatGPT/Codex、ChatGPT API（SIWC）、Gemini CLI、Antigravity、Devin、Kiro、Zed；
   - (b) 设备码：Copilot、Qoder、Factory，Kimi 通过 pi；
   - (c) 直接起官方 CLI 的 login：Claude（`claude auth login`）、Grok（`grok login`）、Cursor（`cursor-agent login`）；
   - (d) 读本机别的 app 留下的凭据文件：`~/.claude`、`~/.codex/auth.json`、`~/.config/github-copilot`、`~/.gemini`、`~/.pi/agent/auth.json`、ZCode / WorkBuddy 的存储等。

   **除 SIWC 外，client_id 全是借官方 CLI / IDE 的**，请求头也全按官方客户端伪装。
3. **Claude 订阅 magpie 已经不发 HTTP 了**：它拉起真正的 `claude` 二进制，用 `-p --input-format stream-json` 跑，调用方的工具通过 MCP 桥进去。原因写在代码注释里：Anthropic 按**请求内容**（system prompt）判断是不是第三方流量，判成第三方就记到 Extra Usage；用量也改成跑 `claude -p /usage` 读，不再请求 `/api/oauth/usage`。
4. **对 App Store 版最值得做的是 OpenAI 的「Sign in with ChatGPT」（SIWC）**：它是 OpenAI 官方给第三方 app 的通道。动态注册 client（`dynamic_agent_client`），token 直接打 `api.openai.com/v1/responses`，用我们自己的 instructions，**不用伪装成 Codex**。限制：只认回环回调；只支持 Responses，而且要去掉一批字段和托管工具；没有用量接口；OpenAI 原话说的是「运行在用户机器上的开源 app」，上架闭源 app 符不符合要先查清楚。
5. **其余订阅大多数在 iOS 上做不了，或者风险很高**：
   - Claude 必须有本机 CLI；
   - Cursor / Grok / Devin / Kiro / Qoder / Zed / Factory / MiMo / WorkBuddy / ZCode / Command Code 已被 magpie 自己标成 Deprecated、挪到社区插件里，理由是「违反厂商条款，免得 magpie 本体被封」；
   - Antigravity 有封号风险；Gemini CLI 的个人账号 Google 已经不给登录了。

   相对能做的：**Copilot（设备码，纯 HTTPS）**和 **Kimi Code（设备码，纯 HTTPS；会员 key 本来就是官方允许第三方用的）**。
6. **对 MP 现有 ChatGPT OAuth 的一条直接发现**：`MP:MemoryPalace/Services/ChatGPTOAuth/OAuthConfig.swift` 里 UA 写的是 `codex_cli_rs/0.0.0 (MemoryPalace)`。magpie 的注释说 Codex 后端会按 UA 里的 Codex 版本号放行最新模型，版本不对的话 `/codex/responses` 对 `/codex/models` 列出来的模型也会回 404「Model not found」（`internal/provider/codex_request.go:23-27`；magpie 用真实版本号 `newerVersion(codexVersion(), …)`，见 `:43-47`）。值得实测一下 0.0.0 下最新模型能不能用。

---

## 1. 预设 provider

### 1.1 数据结构

`PresetDef`（`internal/provider/presets.go:20-63`）的字段：

| 字段 | 含义 |
|---|---|
| `ID / Name / Icon / Kind` | Kind 取 `vendor` / `relay` / `local`（`:14-16`），在选择器里按这个分组 |
| `Chat / Responses / Anthropic` | 三个协议各自的 base URL；空着就表示这个协议没有 |
| `Decide` | 「决策 API」（System One，只做路由，比如 TypeSafe Jev） |
| `Catalog` | models.dev 的 provider id，可以写成逗号列表（例如 `"stepfun-ai-step-plan, stepfun-ai"`） |
| `Website / KeysURL` | 文档链接和「去拿 key」的链接 |
| `NoKey / KeyHint` | 本地服务或免费模型可以不填 key |
| `Regions []Region` + `RegionLabel` | 区域或套餐变体，第一个是默认；切换时 Chat/Responses/Anthropic/Decide/KeysURL/Website/Catalog/Models 一起换（`:66-95`，应用逻辑在 `atRegionOf` `:570`） |
| `HeaderHints` | 编辑器里提示用户可以加的头（如 `anthropic-workspace-id`、OpenRouter 的 `HTTP-Referer`） |
| `Only / Models / NoList` | 套餐只暴露某个前缀的模型；厂商没有 `/models` 接口时用写死的列表兜底 |
| `Endpoint / EndpointHint / EndpointNeeded` | 用户自己的资源地址（Azure、Remote magpie） |
| `Hosts` | 这家同时托管别家的模型（Groq、Ollama Cloud、Azure、腾讯云），它给的模型列表不当成「模型厂商的权威说法」 |

旧 id 兼容：`presetAliases`（`:525`）把旧 id 映射成「新 preset + region」，比如腾讯云三个旧 preset 合并成一个。

`FromPreset`（`:548`）只把字段拷进 `Provider`，然后由调用方补上 key。

### 1.2 全表（行号是 `presets.go` 里 `{ID:` 所在的行）

鉴权：除非标了 NoKey，**全部是 API key**（Bearer；Anthropic 协议用 `x-api-key`）。

**Vendor（模型厂商自营）**

| 行 | id | Chat | Responses | Anthropic | 区域 / 套餐 | catalog |
|---|---|---|---|---|---|---|
| 103 | anthropic | — | — | api.anthropic.com | — | anthropic |
| 108 | openai | api.openai.com/v1 | 同左 | — | — | openai |
| 111 | google | generativelanguage.googleapis.com/v1beta/openai | — | — | — | google |
| 115 | deepseek | api.deepseek.com/v1 | 同左 | api.deepseek.com/anthropic | — | deepseek |
| 118 | xai | api.x.ai/v1 | 同左 | api.x.ai | — | xai |
| 121/124 | moonshot / moonshot-cn | api.moonshot.ai(.cn)/v1 | — | …/anthropic | 国际 / 国内各一个 preset | moonshotai |
| 129/133 | kimi-code / kimi-code-cn | api.kimi.ai(.com)/coding/v1 | — | api.kimi.ai(.com)/coding | 会员 key，「Kimi lets members use them from third-party tools」（`:127-128`） | kimi-code-plan-global / -cn |
| 137 | zhipu | open.bigmodel.cn/api/paas/v4 | Coding Plan 才有：/api/v1 | /api/anthropic | 按量付费 / Coding Plan（`/api/coding/paas/v4`） | zhipuai |
| 148 | zai | api.z.ai/api/paas/v4 | Coding Plan 才有 | /api/anthropic | 同上 | zhipuai |
| 155/158 | minimax / -cn | api.minimax.io(i.com)/v1 | — | …/anthropic | — | minimax |
| 163/170 | stepfun / -cn | …/step_plan/v1 | — | …/step_plan | Step Plan / 按量付费 | stepfun-ai-step-plan, stepfun-ai |
| 180 | xiaomi | token-plan-cn.xiaomimimo.com/v1 | 同左 | …/anthropic | Plan 国内 / 新加坡 / 欧洲 / 按量付费 | xiaomi-token-plan-cn, xiaomi |
| 197 | baidu-qianfan | qianfan.baidubce.com/v2/tokenplan/personal | 同左 | /anthropic/tokenplan/personal | 个人 / 企业 Token Plan / 按量付费；NoList + 写死 Models | — |
| 228 | tencent-cloud | api.lkeap.cloud.tencent.com/plan/v3 | 只有按量付费有 | …/plan/anthropic | Plan / TokenHub 国内 / 国际（`Catalog: tencent-tokenhub`） | — |
| 246 | huaweicloud | api.modelarts-maas.com/plan/v2 | — | …/plan/anthropic | Token Plan / 按量付费 | — |
| 262 | volcengine | ark…/api/coding/v3 | 同左 | …/api/coding | Coding / Agent Plan / 按量付费 | — |
| 276/280 | qwen / qwen-cn | dashscope(-intl).aliyuncs.com/compatible-mode/v1 | — | …/apps/anthropic | — | alibaba |
| 289 | qwen-token-plan | token-plan.maas.qianwenaiapi.com/compatible-mode/v1 | — | …/apps/anthropic | sk-sp- key | — |
| 295 | mistral | api.mistral.ai/v1 | — | — | — | mistral |
| 298 | groq | api.groq.com/openai/v1 | 同左 | — | — | groq |
| 311 | bedrock | bedrock-runtime.{r}.amazonaws.com/openai/v1 | 同左 | …/anthropic | 10 个 AWS 区域；Bedrock API key（不走 SigV4）；NoList | — |
| 329 | azure | 用户自己的 `<resource>.openai.azure.com` | 同左 | — | Endpoint 由用户填 | azure, openai |
| 335 | ollama-cloud | ollama.com/v1 | — | ollama.com | — | ollama-cloud |
| 445 | typesafe | 只有 Decide | | | | |
| 463 | bailian-decision | 只有 Decide | | | 北京 / 新加坡 / Token Plan | |

**Relay（聚合转售）**

| 行 | id | Chat | Responses | Anthropic | 备注 |
|---|---|---|---|---|---|
| 340 | openrouter | openrouter.ai/api/v1 | — | openrouter.ai/api | HeaderHints: HTTP-Referer, X-OpenRouter-Title；catalog openrouter |
| 349 | opencode-go | opencode.ai/zen/go/v1 | 同左 | opencode.ai/zen/go | $10/月 |
| 357 | clinepass | api.cline.bot/api/v1 | — | — | `Only: "cline-pass/"` |
| 365 | opencode-zen | opencode.ai/zen/v1 | 同左 | opencode.ai/zen | NoKey（免费模型） |
| 379 | kilo | api.kilo.ai/api/openrouter | — | — | NoKey |
| 386 | commandcode | api.commandcode.ai/provider/v1 | 同左 | …/provider | |
| 389–405 | together / fireworks / siliconflow / nvidia / modelscope | 各家 /v1 | modelscope 有 | — | |
| 409–425 | aihubmix / pipellm / 302ai / cherryin / yylx | | | | yylx 有 3 个区域 |
| 437 | remote-magpie | 用户填 LAN 地址 | | | 另一台机器上的 magpie |
| 450/456 | vercel-jev / cloudflare-jev | 只有 Decide | | | |

**Local**：ollama（474，:11434）、lmstudio（477，:1234）、omlx（约 480 行，:8000），全部 NoKey。

### 1.3 加一家要改哪些地方

- **必改**：`presets.go` 里加一项。位置就是选择器里的显示顺序；`Sponsored` 排在本组最前面（`Presets()` `:506`）。
- **图标**：`internal/gui/assets/icons/<icon>.svg`（目前 176 个）。
- **模型 / 价格**：填 `Catalog` 就会从 models.dev 拉；如果厂商没有 `/models` 接口，就用 `NoList` + `Models` 写死。
- **可选**：
  - 套餐 key 的额度卡：`internal/provider/planquota.go:33` `planQuotaSourceOf`，按 host 匹配。例如：GLM `/api/monitor/usage/quota/limit`、Kimi Code `…/coding/v1/usages`、MiniMax `/v1/token_plan/remains`、OpenCode Go `/zen/go/v1/usage`、Command Code `/alpha/billing/credits`；
  - 余额：`balance.go:50-66`，例如 DeepSeek `/user/balance`、Moonshot `/v1/users/me/balance`、OpenRouter `/api/v1/credits`、SiliconFlow `/v1/user/info`；
  - 网站导入页 `site/public/docs/*/import.html`；
  - 测试：`model_api_preset_test.go`、`catalogs_test.go`。
- 别处都只通过 `provider.Presets()` 读这张表：`internal/gui/providers.go:628`、`internal/tui/pages.go:405`。

**对 MP 的启发**：MP 的 `APIProvider.presets` 可以补上 magpie 的两个思路：
- **Regions**（同一家的国际 / 国内 / 套餐端点做成一个预设下的分段选择，套餐 key 打按量端点会被拒）；
- **planQuota**（Kimi Code / GLM / MiniMax 这类会员 key 能读到 5 小时 / 周窗口）。

这两件都是纯 HTTPS，iOS 上能做。

---

## 2. 订阅登录逐家拆解

入口在 `internal/provider/signin.go:197-324`，`begin()` 用一个 switch 按 agent 分发。凡是走回环回调的，都在 `127.0.0.1` 上起 HTTP server，同时支持「粘贴回调地址」兜底（`:327-337`、`pastedCallback` `:400-460`）。

### 2.1 总表

| 订阅 | 流程 | client_id 来源 | token 去向 / 刷新 | 请求伪装 | 用量 | magpie 现状 |
|---|---|---|---|---|---|---|
| **Claude** (Pro/Max/Team) | 不自己跑 OAuth，直接起 `claude auth login`，把 magpie 自己设成浏览器来截获 URL（`claude_signin.go:3-8, 40-60`），支持粘贴 code。另外读 `~/.claude/.credentials.json` 或 Keychain 的 `Claude Code-credentials`（`account.go:398-450`） | Claude Code 自己的（magpie 不碰） | Claude Code 自己刷新 | **不直接发 HTTP**：`claudeProvider` 的 sign 直接返回 `errClaudeViaCLI`（`account.go:653-668`）；请求由网关拉起真 `claude` 跑，`-p --output-format stream-json --input-format stream-json --tools "" --strict-mcp-config --mcp-config … --setting-sources "" --dangerously-skip-permissions`（`internal/gateway/claude_subscription.go:1637-1656`），调用方工具走 MCP 桥 | 跑 `claude -p /usage` 解析输出（`claude_usage_cli.go` 头注释；commit `9bf6d43`） | 内置，加账号前弹封号警告 |
| **Codex / ChatGPT** | PKCE + 回环 `localhost:1455/auth/callback`（固定端口，「OpenAI only sends Codex's client back to port 1455」 `signin.go:34-36`）；参数带 `codex_cli_simplified_flow=true`、`originator=codex_cli_rs`、`id_token_add_organizations`（`:210-226`），scope `openid profile email offline_access api.connectors.read api.connectors.invoke`（`:39`）。也读 `~/.codex/auth.json` | **借 Codex CLI 的** `app_EMoamEEZ73f0CkXaXp7hrann`（`account.go:824`） | `auth.openai.com/oauth/token`，提前 5 分钟刷新，新 token 写回 `~/.codex/auth.json`（`account.go:877-946`） | `chatgpt.com/backend-api/codex`；头 `chatgpt-account-id`、`OpenAI-Beta: responses=experimental`、`originator: codex_cli_rs`、`version`、UA `codex_cli_rs/<真版本> (Mac OS x; arm64) Apple_Terminal/455`、`session_id`/`conversation_id`（`codex_request.go:31-89`）。**body 必须带 Codex 的 instructions**：调用方的 system 降级成 developer 消息塞进 input，`store:false stream:true`，删掉 temperature / top_p / max_output_tokens 等（`codexBody` `:240-300`） | `GET chatgpt.com/backend-api/wham/usage` + `chatgpt-account-id`（`subscription_usage.go:786-848`） | 内置 |
| **ChatGPT API（SIWC）** | PKCE + 回环（优先 1455，被占就随机端口，「only the port of a loopback address may vary」 `chatgpt_api.go:52-55`）；授权页 `auth.openai.com/api/accounts/authorize`，参数 `client_id=dynamic_agent_client`、`agent_name_hint=magpie`、`ext_agent_host_id=urn:uuid:<本机固定 UUID>`、`resource=https://api.openai.com/v1`、scope `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`、nonce（`:173-187, 58-66`） | **OpenAI 动态签发**：回调里带回新的 `client_id`，之后换 token、刷新、吊销都用它（`:192-246`） | `…/api/accounts/oauth/token`，提前 3 分钟刷新，加锁串行；refresh token 会轮换；`invalid_grant` 等算登录失效；登出时按 discovery 文档里的 `revocation_endpoint` 吊销（`:378-470`） | `api.openai.com/v1/responses` + Bearer，**用自己的 instructions，不带 Codex 头**。删掉 `siwcDropped`（max_output_tokens、temperature、prompt_cache_retention、previous_response_id…，`:571-575`），去掉托管工具（`:577-579`），system 改成 developer，`store:false stream:true`（`siwcBody` `:584`）。模型列表 `GET /v1/models` | **没有用量接口**，只能把用户引到 chatgpt.com/settings/usage；错误码 `subscription_sharing_*` 有对应解释（`siwcExplain` `:675`） | 内置，10-06 新增（#933） |
| **GitHub Copilot** | GitHub 设备码：`github.com/login/device/code`，scope `read:user`；支持 GHE（`copilot_signin.go:20-60`）。也读 `~/.config/github-copilot/apps.json` | **借 VS Code Copilot 的** `Iv1.b507a08c87ecfe98`（`copilot_signin.go:20`） | 用 GitHub token 换短期会话 token：`api.github.com/copilot_internal/v2/token`（`account.go:951`, `copilotToken` `:1179`） | `api.githubcopilot.com`（Chat、Responses、/v1/messages 都有）；头 `Editor-Version: vscode/1.140.0`、`Editor-Plugin-Version: copilot-chat/0.68.0`、`Copilot-Integration-Id: vscode-chat`、UA `GitHubCopilotChat/0.68.0`、`X-GitHub-Api-Version`、`Openai-Intent: conversation-panel`、`X-Initiator: user/agent`（影响计费）、`Copilot-Vision-Request`（`account.go:955-1081`） | `copilot_internal/user`（`copilot_cli.go:40`、`subscription_usage.go:965`） | 内置，GUI 没标风险 |
| **Gemini CLI** | PKCE + 回环 `127.0.0.1:<port>/oauth2callback`；也读 `~/.gemini/oauth_creds.json`（只读，不写回） | **借 Gemini CLI 的** installed-app client 和 secret（`google.go:70-79`，注释说「secret 不算秘密，随 CLI 一起发」） | `oauth2.googleapis.com/token`，只在内存里刷新 | Code Assist（`cloudcode-pa.googleapis.com`）自有的信封格式；UA `GeminiCLI/0.61.0/<model> (darwin; arm64; terminal)`（`:381-391`） | `retrieveUserQuota`（`:1024`） | 内置；**个人账号 Google 已不给登录**，只剩 Code Assist Standard/Enterprise，还要 GCP 项目（`google.go:11-14`） |
| **Antigravity** | 同上，回环 `localhost/oauth-callback` | **借 Antigravity IDE 的** client 和 secret，scope 多了 `cclog`、`experimentsandconfigs`（`google.go:81-91`） | 同上 | `daily-cloudcode-pa`；UA `antigravity/hub/<从 Google 更新清单读到的版本> darwin/arm64`（`:383-384`，版本来自 `antigravityVersionURL` `:67`） | `retrieveUserQuotaSummary`（`:1184`） | 内置，加账号前弹封号警告（`AntigravityRisk` `:107`） |
| **Grok** (SuperGrok / X Premium+) | 起 `grok login` 跑设备码（`grok.go:633-660`）；读 CLI 的 auth.json | Grok CLI 的（magpie 不碰）。参考：pi-ai 自己实现了 xAI 设备码，client `b1a00492-…`、scope `grok-cli:access`（`local-plugins/kimi-code-subscription/node_modules/@earendil-works/pi-ai/dist/auth/oauth/xai.js:5-8`） | CLI 刷新 | `cli-chat-proxy.grok.com/v1`（Responses）；头 `x-xai-token-auth: xai-grok-cli`、`x-grok-client-identifier: grok-shell`、`x-grok-client-mode: headless`、UA `grok-shell/<v>`（`grok.go:472-487`） | `/billing?format=credits`（`grok_usage.go:59`） | **Deprecated → 插件** |
| **Cursor** | 起 `cursor-agent login` | Cursor CLI 的 | CLI | 内置版：在隔离的 home 里跑 cursor-agent；插件版：`agentn…api5.cursor.sh/agent.v1.AgentService/Run`（HTTP/2 上的 Connect 双向流，`internal/gateway/cursor.go:13, 292`） | `api2.cursor.sh`（`cursor_usage.go:34`） | **Deprecated → 插件** |
| **Kimi Code 会员** | magpie 本体没有。本地插件复用 pi 的登录：RFC 8628 设备码 `auth.kimi.com/api/oauth/device_authorization` | **借 Kimi CLI 的** `17e5f671-d194-4dfb-9706-5516cb48c098`（pi-ai `auth/oauth/kimi-coding.js:11`） | `auth.kimi.com/api/oauth/token` refresh；pi 用文件锁串行刷新 | `api.kimi.com/coding`，Anthropic 协议，只要 Bearer（`kimi-coding.js:245`，`providers/kimi-coding.js:10`），**没看到伪装头** | 会员 key 走 `…/coding/v1/usages`（`planquota.go:41-44`） | 本地插件（粟粟自己的，见 §3.4） |
| **Qwen** | **magpie 没有 Qwen OAuth**（全仓 grep `chat.qwen.ai` / `portal.qwen` 都没有），只有 key 预设 `qwen` / `qwen-token-plan` | — | — | — | — | 没有 |
| Devin | PKCE + 回环，`app.devin.ai/auth/cli/continue` + `cli_pkce_marker=1`（`signin.go:250-267`），exchange 在 `devin.go:626` | devin CLI 的流程 | — | GetChatMessage RPC | — | Deprecated → 插件 |
| Kiro | app.kiro.dev 登录页（Google / GitHub / AWS Builder ID / IdC），回环回调；Builder ID 走 AWS 动态注册的 client（`kiro_signin.go:12-19, 233-240`） | Kiro IDE 的流程 | — | — | — | Deprecated → 插件 |
| Factory | WorkOS 设备码 | **借 droid 的** `client_01HNM792M5G5G1A2THWPXKFMXB`（`factory.go:66-67`） | WorkOS refresh（`:248`） | — | — | Deprecated → 插件 |
| Zed | 本机生成密钥对，zed.dev 回环回调，token 用公钥加密（`zed_signin.go:12-15`） | Zed 编辑器的流程 | — | — | — | Deprecated → 插件 |
| Qoder / Qoder CN | 设备码 | Qoder 桌面端的流程 | — | 按桌面端签名 | — | Deprecated → 插件 |
| MiMo / WorkBuddy / ZCode / Command Code | 各自 app 的长轮询 / 外链登录；或读这些 app 的本地凭据（ZCode 要解它的 AES-GCM 加密存储，`zcode.go:17-20`） | 各 app 的流程 | — | WorkBuddy 拒绝非自家 system prompt（「unapproved channel」） | — | Deprecated → 插件 |

### 2.2 刷新的共同规矩

`docs/subsystems/providers-accounts.md:44`：**每个 refresh token 只能有一个持有方**。厂商刷新时会轮换 token，两份副本会互相把对方踢下线，所以：
- 刷新完要写回 agent 自己的存储；
- 加锁（`savedTokenMu`、`siwcRefreshing`）。

刷新返回 400/401 算「被拒」，要重新登录；403 当网络抖动处理（`account.go:675-684`）。

---

## 3. 插件机制

### 3.1 形态

- **provider 插件**：直接复用 **OpenCode 的 v1 server plugin**（`auth` hook）或 **pi package**（`pi.registerProvider`）。magpie 用 **Bun** 跑（第一次需要时自动下载），宿主是 `internal/plugin/host.js`（1844 行）。
- **网关中间件**：另一种东西，用 Go 写的 JS 引擎 moejs 在进程内跑，只做请求和响应改写（`docs/reference.md:454-506`）。和订阅登录无关。

### 3.2 宿主协议（`internal/plugin/host.js:1-26`）

- magpie 和 host 之间是 stdin/stdout 上逐行的 JSON-RPC：`{id, method, params}` 换 `{id, result|error}`；
- fetch 分段返回：先 `head`，再 base64 的 `chunk`，最后 `result:null`，用 `credit` 做背压；
- 支持的方法（`handlers` `:1642`）：`init / providers / authorize / callback / apiKey / load / usage / checkin / fetch / abort / credit`；
- host 会主动推 `log` / `toast` / `auth` 事件；
- 凭据存在 magpie 的 `plugin-auth.json`，格式和 OpenCode 的 `auth.json` 一样；多账号用 `id#<slot>` 区分；每个请求在自己账号的作用域里跑（AsyncLocalStorage）。

### 3.3 插件作者要写的东西（OpenCode `auth` hook）

- `auth.provider`、`auth.methods[]`：每个 method 是 `{type:"oauth", authorize(inputs)→{url, instructions, method:"auto"|"code", callback(code?)}}` 或 `{type:"api", label, placeholder, prompts}`；
- `auth.loader(getAuth, provider)` 返回 `{apiKey, baseURL, headers, fetch}`，其中 fetch 用来自定义上游请求（`host.js:1386-1410`）；
- magpie 额外认的字段：
  - `icon`；
  - `auth.usage(getAuth, provider)` → `{plan, user, windows:[{name, used%, resetsAt, …}], signIn}`（`:1414-1433`）；
  - `auth.checkin`（每日签到；遇到 captcha 不解）。

host 会把 magpie 的代理注入每个 fetch，以及 node:http2（最新 commit `51d2cf8`）。

### 3.4 哪些是插件

- `internal/plugin/market.json` 里的社区插件（`@magpie-community/opencode-*-auth`）：zcode、qoder、devin、zed、factory、grok、commandcode-plan、mimo-app、cursor、kiro、workbuddy，正好就是 `AGENTS.md:25-44` 那张「Deprecated built-in」表；另有 5 个 middleware；
- 迁移机制：`movers`（`internal/provider/migrate*.go`）+ `migrations.json` 的 `moving / plugin / back / failed` 四种状态（`docs/subsystems/provider-plugins.md:45-52`）；
- **本地插件 `local-plugins/kimi-code-subscription`** 是一个 pi package（`package.json` 的 `pi.extensions`），复用 `~/.pi/agent/auth.json` 里的 Kimi OAuth；magpie 只存一个引用标记（`shared.ts`）。README 里写着「记忆花园沿用原 Magpie 地址和网关 Key」「手机 Key 的模型范围需要包含 Kimi」，也就是说**粟粟现在已经让 MP 通过 LAN 上的 magpie 网关用 Kimi 订阅**。

---

## 4. 风险（magpie 自己的代码、文档和 commit 里写明的）

1. **magpie 正把订阅从本体里剥出去**：AGENTS.md:27-29 原话说这些订阅「Reaching them can break their vendors' terms」，挪到社区插件「keeps magpie itself from being banned」；GUI 文案见 `internal/gui/assets/app.js:4774`（`DEPRECATED_WHY`），commit `70a6c72`（10-02）。
2. **Anthropic**：
   - 「Anthropic classifies another agent's system prompt as third-party traffic even when the OAuth request otherwise looks like Claude Code」（`docs/reference.md:914-922`）；
   - 网关注释说资格检查看的是**请求内容**，不只看凭据 / CCH，判成第三方就记到 Extra Usage（`internal/gateway/claude_subscription.go:3-7`）；
   - 于是 magpie 改成拉起真 `claude` 二进制；commit `9bf6d43` 不再请求 `/api/oauth/usage`（粟粟原话「不要伪造任何的 Claude 请求…我害怕被封」）；
   - 加账号前弹 `ClaudeRisk`（`google.go:111`）。有人因为账号被封登出后删不掉条目（commit `782380a`）。
3. **Google**：
   - Antigravity「may suspend an account it sees used outside Antigravity」（`google.go:107`）；
   - GUI 能识别「violation of Terms of Service」并显示「此账号已被 Google 停用」（`app.js:10740`）。
4. **OpenAI Codex**：magpie 没标封号风险，但请求是完整伪装成 Codex CLI 的（UA、originator、instructions）。官方的替代就是 SIWC：拒绝时返回 `subscription_sharing_*` 错误码（`chatgpt_api.go:675-700`）。
5. **DimAgent**：团队成员在 X 上说经代理使用会封号或取消折扣，magpie 直接下架（commit `d0d0fce`）。
6. **Command Code Go 计划**：私有接口 `/alpha/generate`，官方说可能封号（`app.js` riskNote，commit `f8512b8`）。
7. **Qoder / Zed / Factory / MiMo**：GUI 的 riskNote 都写着「magpie signs requests as its … client would, which … may treat as third-party use」（`app.js` 约 9626-9643 行）。
8. **WorkBuddy**：拒绝 Codex / Claude Code 的 system prompt，报「Illegal API invocation from an unapproved channel」（commits `5353ed5`、`6168bd1`、`2033df0`），说明厂商会**按 system prompt 识别客户端**。
9. **借用别人 client_id 本身就是条款风险**：Codex（`app_EMoam…`）、Copilot（`Iv1.b507…`）、Gemini CLI / Antigravity（连 secret 一起）、Factory、Kimi 全是借来的，只有 SIWC 是动态注册、名义上属于「magpie」自己。

---

## 5. 对「上架 App Store 的原生客户端」哪些可行

判断标准：只用 HTTPS、`ASWebAuthenticationSession`（或 WKWebView）、iOS 上不依赖本机 CLI / Node / 读别的 app 的文件；再看条款风险。

| 订阅 | 技术可行 (iOS) | 条款 / 审核风险 | 建议 |
|---|---|---|---|
| **ChatGPT · SIWC** | ✅ PKCE + 回环。iOS 上 `ASWebAuthenticationSession` 截不到 `http://127.0.0.1`，需要 app 自己在前台起 NWListener，或像 MP 现在这样用 WKWebView 拦 URL（**需实测**）。全程 HTTPS，不用伪装 | **低**：官方通道。但 OpenAI 的说法是「open-source app that runs on the user's machine」（commit `7a926dd`），闭源上架 app 是否符合资格**要先查 OpenAI 的 SIWC 条款**；动态注册的名字（`agent_name_hint`）会显示在用户的授权页上 | **P0**，放在现有 Codex OAuth 旁边，或者直接取代它。注意：只有 Responses、没有用量接口、不支持 temperature 等参数和托管工具 |
| ChatGPT · Codex 后端（现有） | ✅ 已实现 | **中高**：借 Codex 的 client_id，UA 伪装成 Codex。审核如果看到「用别人的 OAuth client」有被拒的可能 | 保留但加风险提示；UA 版本号别写 0.0.0（见 §0.6） |
| Kimi Code 会员（key） | ✅ 纯 key，已经在预设里 | **低**：Kimi 明说会员可以在第三方工具里用（`presets.go:127-128`） | 加预设 + `/coding/v1/usages` 额度卡 |
| Kimi Code（OAuth 设备码） | ✅ 设备码是纯 HTTPS，iOS 完全能做 | 中：借 Kimi CLI 的 client_id | 有 key 方案就够了，可做可不做 |
| GitHub Copilot | ✅ 设备码 + 纯 HTTPS | **中**：借 VS Code 的 client_id，伪装 `Editor-Version: vscode/…`；GitHub Copilot 条款对第三方客户端的态度没在 magpie 里找到明确说法 | 可做，但要放风险提示 |
| Claude Pro/Max | ❌ magpie 的结论是只能靠本机 `claude` 二进制；在 iOS 上直接用 OAuth token 发 HTTP 会被判成第三方（Extra Usage 或封号） | **高** | **不做**。Mac 上可以走现有的 CC 桥（MP 已经有） |
| Gemini CLI | 技术上可以（PKCE + 回环） | 高 + **个人账号已经登不了**（只给 Code Assist 企业版） | 不做 |
| Antigravity | 技术上可以（PKCE + 回环 + 借 client secret） | **高**：Google 会封号 | 不做 |
| Grok | 设备码可以（参考 pi-ai 的 xAI client） | 高：伪装成 grok-shell，magpie 已 Deprecated | 不做；用 xAI API key 预设 |
| Cursor | ❌ HTTP/2 Connect + protobuf + CLI 登录 | 高 | 不做 |
| Devin / Kiro / Zed / Factory / Qoder / MiMo / WorkBuddy / ZCode / Command Code | 部分技术上能做（回环 / 设备码），但不少要读本机 app 的存储 | 高（magpie 已剥离） | 不做 |
| Qwen 订阅 | magpie 也没有 OAuth | — | 只做 key 预设（`qwen-token-plan` 等） |

**依赖本机的（iOS 做不了，macOS 沙盒版也难做）**：
- 读 `~/.claude` / Keychain 的 `Claude Code-credentials`；
- 读 `~/.codex/auth.json`、`~/.config/github-copilot/*.json`、`~/.gemini/oauth_creds.json`、`~/.pi/agent/auth.json`、`~/.zcode/v2/credentials.json`、WorkBuddy 的 info 文件；
- 拉起 `claude` / `grok` / `cursor-agent` / `devin` 这些 CLI；
- Bun / pi 插件宿主。

**Mac 的另一条路（只适合粟粟自用，不适合上架用户）**：MP 把 LAN 上的 magpie 网关当成 OpenAI 兼容 relay（magpie 预设表里也有「Remote magpie」这个概念）。这条路 kimi-code-subscription 插件 README 已经验证过（10-06 手机 Key 拉到 4 个 Kimi 模型，流式请求 200）。

---

## 6. 待确认

1. **OpenAI SIWC 的资格条款**：闭源、上架的 iOS/macOS app 能不能用 `dynamic_agent_client`？`ext_agent_host_id` 每台设备一个 UUID，在 iOS 上的语义对不对？
2. **iOS 回环回调**：`ASWebAuthenticationSession` 跳到 `http://127.0.0.1:1455/auth/callback` 时，app 前台的 NWListener 能不能收到？现有 Codex OAuth 在 iOS 上是靠 WKWebView 拦截的，SIWC 能直接复用。
3. **MP 现在的 Codex UA `codex_cli_rs/0.0.0`**：最新模型会不会被拦成 404？建议在 sim 上对 `/codex/models` 列出来的最新模型各发一次实测。
