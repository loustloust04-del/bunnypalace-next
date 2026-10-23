import Foundation

// MARK: - ChatGPT OAuth (Codex backend) 常量
//
// 这套是 OpenAI 给 codex CLI 用的 OAuth flow。client_id 公开，
// 用户用 ChatGPT 账号登录后能直接调 codex backend 跑 gpt-5.2 等模型，
// 走 ChatGPT 订阅 quota，不用买 Platform API key。
//
// 参考实现：/Users/susu/Desktop/vocab-studio/src/vocab_studio/codex_oauth/config.py
// 源协议：codex_cli_rs（OpenAI 官方 Rust）—— 与官方 CLI 共用 client_id

enum ChatGPTOAuthConfig {
    // OAuth 端点
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let scopes = ["openid", "profile", "email", "offline_access"]

    // 回调（macOS 起 :1455 监听；iOS WKWebView 拦同 URL）
    static let redirectHost = "localhost"
    static let redirectPort = 1455
    static let redirectPath = "/auth/callback"
    static var redirectURI: String {
        "http://\(redirectHost):\(redirectPort)\(redirectPath)"
    }

    // 业务 API 端点
    static let codexBaseURL = "https://chatgpt.com/backend-api/codex"
    static let responsesPath = "/responses"
    static let modelsPath = "/models"

    // 兜底默认模型（登录前预览；登录后拉 /models 会覆盖整个卡的 models 列表）
    static let defaultModel = "gpt-5.2"

    // 客户端 UA（codex CLI 协议要求）
    static let userAgent = "codex_cli_rs/0.0.0 (MemoryPalace)"
    static let originator = "codex_cli_rs"

    // /models 端点要求带 client_version query
    static let modelsClientVersion = "0.0.0"

    // Token 刷新时机：access_token 距过期 < 60 秒就刷
    static let refreshMarginSeconds: TimeInterval = 60

    // 登录回调等待超时（mac 端 NWListener 用）
    static let loginTimeoutSeconds: Int = 180

    // OOB pending 持久化 TTL：5 分钟够用户切去 Safari 登 + 复制 URL 切回来
    static let pendingPersistSeconds: TimeInterval = 300
}
