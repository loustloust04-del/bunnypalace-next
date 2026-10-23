import Foundation

// MARK: - ChatGPT OAuth Token 交换 / 刷新
//
// 两个动作走同一个 token endpoint，只是 grant_type 不同：
// - authorization_code：登录拿首套 token
// - refresh_token：access 过期续命
//
// 失败的话上游报错"需要重新登录"。

enum ChatGPTOAuthExchange {

    enum ExchangeError: Error, LocalizedError {
        case invalidResponse(String)
        case missingTokens
        case httpError(status: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let s): return "OAuth 响应解析失败: \(s)"
            case .missingTokens: return "OAuth 响应缺 access_token 或 refresh_token"
            case .httpError(let status, let body): return "OAuth 端点 \(status)：\(body.prefix(200))"
            }
        }
    }

    /// 用授权码 + verifier 换首套 token
    static func exchangeCode(
        _ code: String,
        codeVerifier: String,
        timeout: TimeInterval = 120
    ) async throws -> OAuthTokenSet {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": ChatGPTOAuthConfig.clientId,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": ChatGPTOAuthConfig.redirectURI,
        ]
        return try await postToken(body: body, fallbackRefreshToken: "", timeout: timeout)
    }

    /// 刷新 access_token（refresh_token 通常更长寿命，response 里若新发会替换）
    static func refresh(
        refreshToken: String,
        timeout: TimeInterval = 120
    ) async throws -> OAuthTokenSet {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": ChatGPTOAuthConfig.clientId,
            "refresh_token": refreshToken,
        ]
        return try await postToken(body: body, fallbackRefreshToken: refreshToken, timeout: timeout)
    }

    // MARK: - 私有：POST token endpoint

    private static func postToken(
        body: [String: String],
        fallbackRefreshToken: String,
        timeout: TimeInterval
    ) async throws -> OAuthTokenSet {
        guard let url = URL(string: ChatGPTOAuthConfig.tokenURL) else {
            throw ExchangeError.invalidResponse("token URL 无效")
        }
        let encoded = body
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .joined(separator: "&")
        guard let payload = encoded.data(using: .utf8) else {
            throw ExchangeError.invalidResponse("body 编码失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExchangeError.invalidResponse("response 不是 HTTPURLResponse")
        }
        if !(200..<300).contains(http.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw ExchangeError.httpError(status: http.statusCode, body: bodyStr)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExchangeError.invalidResponse("非 JSON 响应")
        }

        return try tokenFromPayload(json, fallbackRefreshToken: fallbackRefreshToken)
    }

    private static func tokenFromPayload(_ payload: [String: Any], fallbackRefreshToken: String) throws -> OAuthTokenSet {
        let access = (payload["access_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = (payload["refresh_token"] as? String ?? fallbackRefreshToken).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty, !refresh.isEmpty else { throw ExchangeError.missingTokens }
        let expiresIn = (payload["expires_in"] as? Double) ?? 3600
        return OAuthTokenSet(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().timeIntervalSince1970 + expiresIn
        )
    }

    private static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#%")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
