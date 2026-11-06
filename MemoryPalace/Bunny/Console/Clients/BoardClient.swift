// [Bunny] 自大肥兔（提交 7f2c6c4df）原样移植；地址 / 口令改读 BunnyGateway（不再写死域名）。
import Foundation

/// 留言板 — 网关同一份数据（Caelum 的 board_* 工具读写的就是它）。
/// GET /api/board · POST /api/board · POST /:id/reply · DELETE /:id · DELETE /:id/reply/:rid
/// 复用控制台约定：UserDefaults "gatewayBaseURL" / "gatewayAuthToken"。
enum BoardClient {
    struct Reply: Codable, Identifiable, Hashable {
        let id: String
        let text: String
        let by: String            // "bunny" | "caelum"
        let ts: String
    }
    struct Post: Codable, Identifiable, Hashable, Equatable {
        let id: String
        let text: String
        let by: String
        let ts: String
        let replies: [Reply]
    }

    private static var baseURL: String {
        BunnyGateway.baseURL
    }
    private static var token: String {
        BunnyGateway.token
    }
    static var isConfigured: Bool { !token.isEmpty }

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard !token.isEmpty, let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static let cacheKey = "board-posts"

    /// 先给缓存（立刻），再给新的
    static func fetchCached(_ onValue: @MainActor @escaping ([Post], Bool) -> Void) async {
        await GatewayCache.fetch(key: cacheKey, remote: { await fetchRemote() }, onValue: onValue)
    }

    private static func fetchRemote() async -> [Post]? {
        guard let req = request("/api/board") else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["posts"],
              let d = try? JSONSerialization.data(withJSONObject: arr) else { return nil }
        return try? JSONDecoder().decode([Post].self, from: d)
    }

    static func fetch() async -> [Post] {
        if let fresh = await fetchRemote() { GatewayCache.save(cacheKey, fresh); return fresh }
        return GatewayCache.load(cacheKey, as: [Post].self) ?? []
    }

    private static func fetchLegacy() async -> [Post] {
        guard let req = request("/api/board") else { return [] }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["posts"] else { return [] }
        guard let d = try? JSONSerialization.data(withJSONObject: arr) else { return [] }
        return (try? JSONDecoder().decode([Post].self, from: d)) ?? []
    }

    @discardableResult
    static func post(text: String, by: String = "bunny") async -> Bool {
        guard let req = request("/api/board", method: "POST", body: ["text": text, "by": by]) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    static func reply(postId: String, text: String, by: String = "bunny") async -> Bool {
        guard let req = request("/api/board/\(postId)/reply", method: "POST", body: ["text": text, "by": by]) else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    static func deletePost(id: String) async -> Bool {
        guard let req = request("/api/board/\(id)", method: "DELETE") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    @discardableResult
    static func deleteReply(postId: String, replyId: String) async -> Bool {
        guard let req = request("/api/board/\(postId)/reply/\(replyId)", method: "DELETE") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}
