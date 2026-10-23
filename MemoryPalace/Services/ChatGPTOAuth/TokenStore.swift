import Foundation

// MARK: - ChatGPT OAuth Token 持久化
//
// 一张 ChatGPT OAuth 卡的 token 三件套（access / refresh / expiresAt）以 JSON 形式
// 存进 Keychain，account = credentialId（跟普通 API key 卡同 keychain service，
// 借用 `apiKey(for:)` 读路径就能读到，再用 JSON 解就拿到结构化 token）。
//
// 这样设计：
// - Keychain 复用同一套 service / iCloud 同步开关
// - ChatGPTOAuthProvider 调用前从 ProviderManager.apiKey(for: credentialId) 拿到 JSON
//   字符串再解码，跟其它 provider 同一路径
// - JWT 自带过期判断由 expiresAt 字段兜底

struct OAuthTokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    /// Unix epoch 秒
    var expiresAt: TimeInterval

    func isExpired(now: Date = Date(), margin: TimeInterval = ChatGPTOAuthConfig.refreshMarginSeconds) -> Bool {
        now.timeIntervalSince1970 + margin >= expiresAt
    }

    /// 解析 access_token（JWT）payload 里的 `chatgpt_account_id` claim
    /// 用于 Codex 请求的 `ChatGPT-Account-ID` header。
    var chatgptAccountId: String {
        Self.extractChatGPTAccountId(from: accessToken)
    }

    /// 编码为 JSON 字符串（用于存进 Keychain 当 value）
    func toKeychainString() -> String? {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// 从 Keychain 读到的 JSON 字符串解码回结构（失败返 nil，让上游当作"未登录"）
    static func fromKeychainString(_ raw: String) -> OAuthTokenSet? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    // MARK: - JWT claims 解析（不验签，只取 payload）

    /// 给 ChatGPTOAuthProvider 用：拿到裸 access_token 时直接抠 chatgpt_account_id
    static func extractChatGPTAccountId(from accessToken: String) -> String {
        // JWT 形如 header.payload.signature，三段 base64url
        let parts = accessToken.split(separator: ".")
        guard parts.count >= 2 else { return "" }
        guard let payloadData = base64urlDecode(String(parts[1])) else { return "" }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return "" }
        // 形如 "https://api.openai.com/auth": {"chatgpt_account_id": "..."}
        if let auth = json["https://api.openai.com/auth"] as? [String: Any],
           let id = auth["chatgpt_account_id"] as? String {
            return id
        }
        return ""
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var t = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

// MARK: - 跟 ProviderManager 配合的 helper
//
// ProviderManager.apiKey(for:) 现在返回 String?（普通 key 直接是 key 字符串）。
// 我们用 JSON 字符串当 "key" 复用通道，但对 chatgptOAuth 类型卡的 value 是 JSON。
// 提供两个静态方法把这层 JSON 编解码做掉。

extension ProviderManager {
    /// 读 chatgptOAuth 卡的 token；不是 OAuth 类型或解析失败 → nil
    func oauthToken(for credentialId: String) -> OAuthTokenSet? {
        guard let raw = apiKey(for: credentialId), !raw.isEmpty else { return nil }
        return OAuthTokenSet.fromKeychainString(raw)
    }

    /// 存 chatgptOAuth 卡的 token（编码成 JSON 走普通 Keychain 通道）
    func setOAuthToken(_ token: OAuthTokenSet, for credentialId: String) {
        guard let s = token.toKeychainString() else { return }
        setApiKey(s, for: credentialId)
    }

    func clearOAuthToken(for credentialId: String) {
        setApiKey("", for: credentialId)
    }
}
