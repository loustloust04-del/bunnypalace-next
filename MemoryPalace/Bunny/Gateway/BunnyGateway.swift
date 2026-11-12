import Foundation

// MARK: - [Bunny] 兔兔网关连接
//
// 大肥兔的网关（药品柜、经期、纪念日、留言板、推特、Murmur……）统一入口。
// 沿用大肥兔的约定键名：UserDefaults「gatewayBaseURL」；口令存 Keychain（账号 bunny.gatewayAuthToken），
// 兼容读取大肥兔旧键 UserDefaults「gatewayAuthToken」。代码里不写任何地址或口令。

enum BunnyGateway {
    static let baseURLKey = "gatewayBaseURL"
    static let legacyTokenKey = "gatewayAuthToken"
    static let tokenAccount = "bunny.gatewayAuthToken"

    static var baseURL: String {
        (UserDefaults.standard.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var token: String {
        KeychainStore.get(account: tokenAccount) ?? UserDefaults.standard.string(forKey: legacyTokenKey) ?? ""
    }
    static var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    static func save(baseURL: String, token: String) {
        UserDefaults.standard.set(baseURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: baseURLKey)
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = KeychainStore.set(t.isEmpty ? nil : t, account: tokenAccount, sync: false)
    }

    enum GatewayError: LocalizedError {
        case notConfigured, badURL, http(Int), network(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没填网关地址和口令"
            case .badURL: return "网关地址不对"
            case .http(let c): return c == 401 || c == 403 ? "口令不对（\(c)）" : "网关返回 \(c)"
            case .network(let m): return "连不上网关：\(m)"
            }
        }
    }

    static func get(_ path: String, timeout: TimeInterval = 30) async throws -> Data {
        guard isConfigured else { throw GatewayError.notConfigured }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http" else { throw GatewayError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw GatewayError.http(h.statusCode) }
            return data
        } catch let e as GatewayError {
            throw e
        } catch {
            throw GatewayError.network(error.localizedDescription)
        }
    }

    /// JSON POST（返回响应体；非 2xx 抛错）
    static func post(_ path: String, json: [String: Any], timeout: TimeInterval = 30) async throws -> Data {
        guard isConfigured else { throw GatewayError.notConfigured }
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + path), url.scheme == "https" || url.scheme == "http" else { throw GatewayError.badURL }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw GatewayError.http(h.statusCode) }
            return data
        } catch let e as GatewayError {
            throw e
        } catch {
            throw GatewayError.network(error.localizedDescription)
        }
    }

    /// 测连通：拿最近 1 条推文（任何已登录口令都能读）
    static func ping() async throws {
        _ = try await get("/api/tweets?limit=1", timeout: 15)
    }
}
