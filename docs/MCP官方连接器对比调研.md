# MCP 官方连接器对比调研

日期：2026-06-05

## 结论

当前 MemoryPalace 的 MCP 已经具备“远程 MCP server 配置 + tools/list + tools/call + SSE/Streamable HTTP 基础通信”的雏形，但它还不是 Anthropic 官端 custom connector 的等价实现。

核心差距集中在三块：

1. 官端把远程 connector 当成“受 OAuth 保护的远程服务”来接入，支持授权发现、浏览器授权、token 获取/刷新、连接级身份状态；MemoryPalace 现在只是保存了 OAuth Client ID/Secret 字段，尚未使用。
2. MCP Streamable HTTP 的正式协议不只是简单 POST JSON-RPC。它还涉及 `Mcp-Session-Id`、可选 SSE response stream、DELETE 终止 session、resumability、401 触发授权流程等；MemoryPalace 当前只实现了“POST 后读 JSON 或一次性 SSE payload”。
3. Anthropic 的 Claude API 和 Claude.ai connector 都有一层 toolset/connector 管理模型：server 级授权、tool 级允许、user/tool 交互提示、connector 信任与状态。MemoryPalace 现在是本地 settings 中维护 server/tool 开关，并把 tool schema 转成 OpenAI/Anthropic function tools。

所以现在的状态可以描述为：基础 MCP 客户端可用，但还缺“官方远程 connector 的认证、session、权限和 UX 语义”。

## 参考来源

- Anthropic custom integrations support：`https://support.claude.com/en/articles/11175166-getting-started-with-custom-integrations-using-remote-mcp`
- Anthropic MCP connector building docs：`https://claude.com/docs/connectors/building`
- Anthropic connector authentication docs：`https://claude.com/docs/connectors/building/authentication`
- MCP Streamable HTTP transport spec：`https://modelcontextprotocol.io/specification/draft/basic/transports/streamable-http`
- MCP authorization spec：`https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization`

## 官端/协议要求

### 1. Connector 配置形态

Claude.ai 的“Add custom connector”入口暴露的是远程 MCP connector 配置：

- Name
- Remote MCP server URL
- Advanced settings
- OAuth Client ID optional
- OAuth Client Secret optional

这个 UI 本身不代表 OAuth 已经完成。它只是收集 connector metadata。真正连接时，Claude 会根据 server 的认证要求进入授权流程，或者对 authless server 直接连接。

MemoryPalace 当前已对齐到类似字段：

- `MCPServerConfig.name`
- `MCPServerConfig.url`
- `MCPServerConfig.transport`
- `MCPServerConfig.oauthClientId`
- `MCPServerConfig.oauthClientSecret`
- `MCPServerConfig.headers`

差距：

- 官端没有让普通用户手填 Headers JSON；MemoryPalace 保留了它，用于 Bearer token 或私有 header 的工程调试。
- 官端的 OAuth 字段进入后续授权流程；MemoryPalace 目前只是保存，未参与网络请求。
- 官端可以有 pre-built connectors 和 organization 管理；MemoryPalace 只有自定义 server 列表。

### 2. Transport

MCP 官方远程通信主线是 Streamable HTTP。legacy HTTP+SSE 仍可兼容，但 Streamable HTTP 是更接近当前远程 connector 的形态。

协议层关键点：

- client 向 MCP endpoint POST JSON-RPC message。
- server 可以返回单个 JSON response，也可以返回 `text/event-stream`。
- server 可以用 `Mcp-Session-Id` header 建立 session。
- 后续请求需要带回同一个 `Mcp-Session-Id`。
- client 可发送 DELETE 到 endpoint 终止 session。
- server 也可以支持 resumability，让 client 用 stream id / event id 恢复断开的 SSE stream。
- server 返回 401 时，client 应进入 OAuth 授权流程，而不是只显示错误。

MemoryPalace 当前实现：

- `MCPSSETransport`：legacy SSE。GET 建立 stream，等待 `endpoint` event，再 POST message。
- `MCPStreamableHTTPTransport`：POST JSON-RPC 到 URL，接受 JSON 或一次性 SSE payload。
- `MCPClient`：使用 JSON-RPC `initialize`、`notifications/initialized`、`tools/list`、`tools/call`。

差距：

- 未保存/回传 `Mcp-Session-Id`。
- 未实现 DELETE session termination。
- 未实现 long-lived response stream 管理。
- 未实现 resumability。
- 未处理 server 对 notification 返回 202/empty body 的细节。
- 未把 HTTP 401 转换为授权状态。
- 未发送或验证协议要求相关 header，例如 `Mcp-Session-Id`、可能的 protocol version/header 兼容策略。

### 3. OAuth / Authorization

MCP Authorization 规范基于 OAuth 2.1，并要求使用 Authorization Code + PKCE。远程 MCP server 作为 resource server 时，需要通过 metadata 引导 client 找到 authorization server。

官端/协议层通常涉及：

- 访问 MCP URL，若未授权可能返回 401。
- client 读取 resource metadata 或 authorization server metadata。
- 使用 OAuth 2.1 Authorization Code + PKCE 发起浏览器授权。
- 可选 Dynamic Client Registration。
- 可选自定义 OAuth Client ID/Secret。
- callback 接收 authorization code。
- token endpoint 换取 access token / refresh token。
- 存储 token。
- 后续 MCP 请求带 `Authorization: Bearer ...`。
- access token 过期后 refresh。
- 授权失败或撤销后进入 disconnected/reauthorize 状态。

Anthropic 文档还提到多种认证模式：

- authless
- Dynamic Client Registration
- Claude Integrations Metadata Discovery
- token refresh
- 自定义 OAuth client credentials

MemoryPalace 当前实现：

- 有 `oauthClientId` / `oauthClientSecret` 字段。
- 有 Headers JSON，用户可以手工填 `Authorization`。
- 没有 OAuth discovery。
- 没有 PKCE。
- 没有浏览器授权。
- 没有 callback URL / redirect URI。
- 没有 token endpoint 交换。
- 没有 refresh token。
- 没有 token 安全存储。

差距：

- OAuth 字段目前是“配置壳”，不是功能。
- Client secret 存在 UserDefaults JSON 中，不适合长期存储敏感值。
- 如果实现官端级别 OAuth，应迁移 secret/token 到 Keychain。
- 需要设计 macOS/iOS callback：自定义 URL scheme 或 ASWebAuthenticationSession callback。

### 4. Tool / Toolset 行为

官端 connector 不是简单把所有 tools 变成 function calling。它还会做：

- connector 级连接状态。
- tool 级权限选择。
- 每次调用时的安全边界和用户提示。
- tool result 在 Claude 对话中的结构化呈现。
- server/tool metadata 展示。
- 与 Claude 内部 toolset API 或 connector schema 对齐。

MemoryPalace 当前实现：

- 连接成功后 `tools/list`。
- 将远程 tool schema 保存到 `MCPToolConfig.schema`。
- 每个 server tool 可开关。
- 每个 conversation 可选择启用哪些 server。
- 发送模型前，将 tool 转成 OpenAI function 或 Anthropic tool schema。
- 模型调用 tool 后，通过 `tools/call` 执行，再把 tool result 喂回递归对话。

差距：

- 没有 connector 级 trust/consent UI。
- 没有高风险 tool 调用确认。
- 没有 resource/prompt/list 等 MCP 能力，仅支持 tools。
- tool result 当前 flatten 成文本，图片/resource 只是弱文本占位。
- 没有处理 sampling、elicitation、roots 等更完整 MCP 能力。

### 5. 安全与数据存储

官端预期：

- OAuth tokens 和 client secret 属于敏感数据。
- connector 有信任边界。
- tool 调用可能访问外部服务或用户数据，需要显式授权与撤销。

MemoryPalace 当前：

- `MCPServerConfig` 存在 UserDefaults。
- `headers`、`oauthClientSecret` 都会被 `prettyJSON()` 导出到 JSON 配置。
- 没有 token store。
- 没有撤销授权。
- 没有区分“连接配置”和“敏感凭证”。

建议：

- `oauthClientSecret`、access token、refresh token 放 Keychain。
- JSON 导出默认隐藏 secret/token。
- server row 增加“重新授权 / 断开授权 / 清除凭证”。
- Headers JSON 可保留为高级调试，但要标注会明文保存，或者也迁移敏感 header。

## 逐项对比表

| 项目 | Claude 官端 / MCP 预期 | MemoryPalace 当前状态 | 差距 |
|---|---|---|---|
| Name | 支持 | 支持 | 基本对齐 |
| Remote URL | 支持 | 支持 | 基本对齐 |
| Advanced settings | 支持 | 支持 | 基本对齐 |
| OAuth Client ID/Secret | 支持并参与授权 | 字段已保存但未使用 | 需要 OAuth flow |
| Authless server | 支持 | 理论支持，取决于 server 是否接受当前请求 | 需完善状态与错误处理 |
| Dynamic Client Registration | 支持场景之一 | 不支持 | 需要 discovery + registration |
| Claude Integrations Metadata Discovery | 支持场景之一 | 不支持 | 需要 metadata discovery |
| Authorization Code + PKCE | OAuth 2.1 要求 | 不支持 | 必做 |
| Browser auth | 支持 | 不支持 | 需要 ASWebAuthenticationSession |
| Token exchange | 支持 | 不支持 | 必做 |
| Token refresh | 支持 | 不支持 | 必做 |
| Token/secret storage | 官端安全存储 | UserDefaults 明文配置 | 需要 Keychain |
| Streamable HTTP POST | 支持 | 支持基础 POST | 部分对齐 |
| Streamable HTTP SSE response | 支持 | 只解析一次性 payload | 需 long-lived stream |
| `Mcp-Session-Id` | 支持/需要处理 | 不支持 | 需要 session store |
| DELETE session | 支持 | 不支持 | 需要实现 |
| resumability | 可支持 | 不支持 | 可后置 |
| Legacy SSE | 兼容 | 支持 | 可保留 |
| tools/list | 支持 | 支持 | 对齐 |
| tools/call | 支持 | 支持 | 对齐基础能力 |
| resources/prompts | 协议支持 | 不支持 | 可后置 |
| tool permission | 官端 connector/tool 级 | server/tool/conversation 级开关 | 部分对齐 |
| high-risk confirmation | 官端安全模型内 | 不支持 | 可增强 |
| connector prebuilt | 官端有 | 不支持 | 非本项目重点 |

## 对 MemoryPalace 的实现建议

### P0：把 OAuth 从“字段”变成真正可用

目标：支持受 OAuth 保护的远程 MCP server。

需要新增：

- `MCPOAuthManager`
- `MCPOAuthMetadata`
- `MCPOAuthToken`
- `MCPKeychainCredentialStore`
- `MCPAuthorizationSession`

流程：

1. `connect()` 收到 401 或发现 server 需要 auth。
2. fetch resource metadata / authorization server metadata。
3. 生成 PKCE code verifier/challenge。
4. 用 `ASWebAuthenticationSession` 打开授权 URL。
5. callback 收到 code。
6. token endpoint 换 access token / refresh token。
7. token 存 Keychain。
8. 重新连接 MCP，自动注入 Bearer token。
9. token 过期时 refresh。

### P1：补齐 Streamable HTTP session 语义

目标：让 Streamable HTTP 更接近官方协议。

需要改：

- `MCPStreamableHTTPTransport` 保存 `sessionId`。
- POST response header 读取 `Mcp-Session-Id`。
- 后续 POST 带 `Mcp-Session-Id`。
- `close()` 时 DELETE endpoint。
- 如果 response 是 SSE stream，按 stream 逐事件处理，而不是只处理一次性 data。
- 对 notification 的 202/empty body 做显式兼容。
- 401 抛出专门的 `authorizationRequired` 错误。

### P2：安全存储与 UI 状态

目标：避免 secret/token 明文散落。

需要改：

- `MCPServerConfig` 只保留非敏感 metadata。
- OAuth secret/token/header secret 迁移 Keychain。
- JSON 配置导出隐藏敏感字段。
- UI 增加连接状态：
  - 未授权
  - 授权中
  - 已授权
  - token 过期
  - 授权失败
- 增加按钮：
  - 授权
  - 重新授权
  - 清除凭证

### P3：更完整的 MCP 能力

目标：从 tools-only 变成更完整的 MCP client。

可选：

- resources/list/read
- prompts/list/get
- tool result 的 image/resource 正式渲染
- roots
- sampling/elicitation 能力声明与处理

## 推荐下一步计划

如果 Susu 要继续做“官端级别对齐”，建议不要一次吃完全部能力。第一轮只做 OAuth + Streamable HTTP session，范围清楚，风险可控。

推荐拆成两个 implementation milestone：

1. OAuth 基础闭环
   - metadata discovery
   - PKCE
   - ASWebAuthenticationSession
   - token exchange
   - Keychain
   - Bearer injection
   - refresh token

2. Streamable HTTP 协议补齐
   - session id
   - DELETE
   - streaming response
   - 401 auth error
   - notification 202 handling

做完这两项后，MemoryPalace 才能说和 Claude 官端 remote MCP connector 在“核心连接能力”上接近。

## 当前不能直接实现的点

- Anthropic 官端内部 connector 管理、pre-built connector、organization policy 属于 Claude.ai 产品能力，不是 MemoryPalace 本地 app 能 1:1 复刻的范围。
- 如果某些 remote MCP server 只允许 Claude 官方 OAuth client，MemoryPalace 即使实现 OAuth，也必须由 server 提供自定义 client credentials 或 DCR 才能接入。
- OAuth callback 需要确认 app 的 URL scheme / bundle 配置，macOS 和 iOS 都要验证。
