# L4 —— Provider 接入层与账号登录

先读 `COMMON.md`（同目录）。本文件只写这条 lane 独有的东西。

## 这条轴问什么

**接入多家模型这件事，怎么做才不会长成一坨。**

OM 的 `Providers/` 是 69 个文件 31K 行——七家（Anthropic / OpenAI / Gemini / xAI / Kimi / OpenRouter / Antigravity）**每家都带独立的 OAuth 子目录**，另有 `Thinking/` 和 `Voice/` 两个横切目录。
MP 也是多 provider（6 家内置），但实现集中在 `Services/` 里，且 `Models/APIProvider.swift` 已经 1464 行、被 MODULE_INDEX 标为 🔴 god class。

这条轴同时有工程价值（怎么分层）和产品价值（**账号登录 vs API key**，直接影响非技术用户能不能用）。

## OM 侧读什么（`src/ios/Providers/`）

- 先看**目录形状本身**：七家 × 各自 OAuth 的对称结构说明了什么分层原则？共同抽象在哪个文件？
- 挑 **两到三家深读**（建议 Anthropic + OpenAI + 一家小的如 Kimi 或 xAI 做对照）：请求构造、SSE 流式解析、工具调用编解码、错误/重试、模型能力差异（thinking / vision / tool）怎么被吸收。
- `Providers/OAuth/`（各家的）—— **账号登录链路**。重点：授权流程怎么跑（ASWebAuthenticationSession？）、token 存哪、刷新怎么做、失效怎么办。
- `Providers/Thinking/` —— 思考/推理内容的横切处理。各家 thinking 格式不同，他们怎么统一。
- `Providers/Voice/` —— 语音相关的 provider 面。
- `Agent/Chat/AIChatViewModel+ProviderFactory.swift` + `+Fallback.swift` —— provider 怎么被装配、失败怎么降级。

## MP 侧对照坐标

- `Models/APIProvider.swift`（1464 行 🔴）、ProviderRouter → `OpenAICompatibleProvider` / `AnthropicProvider` 两条实现路径，6 家内置。
- OAuth：MP 只有 `Services/ChatGPTOAuth/`（`ChatGPTOAuthProvider.swift` 379 行 + `LoginCoordinator.swift` + `OAuthConfig.swift`）——**只有 ChatGPT 一家**。
- API key 存储：`docs/report-api-key-storage.md`（钥匙串，见下面的事故）。

## 车头给的额外情报（你查不到的）

1. **MP 的 API key 钥匙串曾经重启就清空**，根因不是签名而是 `getAll` 用 `MatchLimitAll + ReturnData` 在 macOS 报 -50 读空。改逐条 get 修好，但会狂弹授权框（已关交互）。签名不稳是次因。
   → 去看 OM 的凭据存储怎么做的（Keychain 用法、access group、有没有 iCloud Keychain 同步）。这条对 MP 是**现成的对照修复参考**。
2. **流式 tool_call 空名覆盖**：DeepSeek 等 provider 的后续分片会把 `function.name` 发成空串，如果无条件覆盖，真名会被清空 → 出现「(未命名 tool)」空调用循环。MP 踩过，修法是 name/id 必须非空才覆盖。**无参工具最易踩**。
   → 去看 OM 的流式工具调用组装逻辑有没有等价防御，他们是怎么写的。
3. **OpenRouter 缓存 0 命中**排查链：session_id 钉上游 → provider.order 指官方 → 隐私设置挡官方。且 Opus 经 OR 最小 4096 token。MP 有 OR 接入。
   → OM 也有 OpenRouter，看他们怎么处理 OR 的特殊性。
4. **MP 是产品不是粟粟的个人工具**——推方案不要按「粟粟自己用什么 provider」缩范围，基础功能的默认前提是**所有 provider 都得能用**。（这是粟粟明确纠正过的一条，请务必带着它做判断。）
5. MP 走 claude-proxy 把 `claude -p` 包成 Anthropic/OpenAI 端点当 provider 用（本机 8792）。所以 MP 的 provider 层还要吃「本地端点」这种形态。

## 特别要回答的

1. **账号登录（OAuth）vs API key**：OM 七家全做了 OAuth。对 MP 这个要上架的产品，账号登录是不是必要门槛？（想清楚：非技术用户会不会自己去搞 API key？）如果要做，**从哪家开始、每家的代价档位**。
2. `APIProvider.swift` 1464 行该怎么拆？OM 的目录形状能不能直接当 MP 的目标形态？给一个**可执行的拆法**（拆成什么、边界在哪），不要只说「该拆」。
3. `Thinking/` 这个横切目录解决的问题，MP 现在是怎么处理的？（MP 有思考块 UI）各家 thinking 格式差异有没有在 MP 里长成 if-else 面条？
4. MP 有一条 OM 没有的形态：**cc-bridge 通道**（provider 之一是本机 Claude Code 的真实终端）。注意 MP 有个已知事实：`Conversation.provider` 的真值只有 `api`/`sillytavern`/`chatgpt` 三种，**没有 cc-bridge 字串**，按 cc-bridge 过滤永远是空集。你在分析 provider 抽象时把这条算进去——它可能是抽象漏了一层的症状。
